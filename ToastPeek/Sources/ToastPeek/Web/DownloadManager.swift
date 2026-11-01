import AppKit
import WebKit

/// Downloads belong to the application, not to the lifetime of a tab/view.
@MainActor
final class DownloadManager: NSObject, WKDownloadDelegate {
    @MainActor private final class Task {
        let id = UUID()
        let tabID: UUID
        let download: WKDownload
        let profileID: UUID
        var sourceURL: String
        var keepResumeData = true
        var cancellationPending = false
        var cancelWaiters: [() -> Void] = []
        var inheritedPartials: [URL] = []
        var destination: URL?
        var transferURL: URL?
        var replaceExisting = false
        var observation: NSKeyValueObservation?
        var panel: NSSavePanel?
        init(_ download: WKDownload, tabID: UUID, profileID: UUID) {
            self.download = download; self.tabID = tabID; self.profileID = profileID
            sourceURL = download.originalRequest?.url?.absoluteString ?? ""
        }
    }
    private weak var store: BrowserStore?
    private var tasks: [ObjectIdentifier: Task] = [:]
    private var reservedPaths = Set<String>()
    private struct ResumeRecord {
        let data: Data
        let tabID: UUID
        let profileID: UUID
        let sourceURL: String
        let destination: URL
        let transfer: URL
        let partials: [URL]
    }
    private var resumeData: [UUID: ResumeRecord] = [:]
    private var resumeOrder: [UUID] = []
    private struct CommitInput: Sendable {
        let id: UUID
        let source: URL
        let destination: URL
        let replaceExisting: Bool
    }
    private let commitQueue = DispatchQueue(label: "com.toastpeek.download-commit", qos: .utility)
    private var commitGroup = DispatchGroup()
    private var committing: [UUID: Task] = [:]
    private var completedFiles: [UUID: Task] = [:]
    private var removedWhileCommitting = Set<UUID>()
    private final class PendingResume {
        enum Phase { case awaitingDownload, cancelling }
        let id: UUID
        let record: ResumeRecord
        var phase = Phase.awaitingDownload
        var cancellationRequested = false
        var keepResumeData = true
        var waiters: [() -> Void] = []
        init(id: UUID, record: ResumeRecord) { self.id = id; self.record = record }
    }
    private var pendingResumes: [UUID: PendingResume] = [:]

    // Narrow fault-injection seams: production still uses real WebKit and filesystem I/O.
    var resumeCompletionGate: ((@escaping () -> Void) -> Void)?
    var commitFile: @Sendable (URL, URL, Bool) throws -> Void = { source, destination, replace in
        if replace { _ = try FileManager.default.replaceItemAt(destination, withItemAt: source) }
        else { try FileManager.default.moveItem(at: source, to: destination) }
    }

    private func enqueueCommit(_ task: Task, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        guard committing[task.id] == nil else { completion(CocoaError(.fileWriteFileExists)); return }
        guard let source = task.transferURL, let destination = task.destination,
              source.standardizedFileURL != destination.standardizedFileURL else {
            completion(CocoaError(.fileNoSuchFile)); return
        }
        let input = CommitInput(id: task.id, source: source, destination: destination, replaceExisting: task.replaceExisting)
        let commit = commitFile
        committing[task.id] = task
        commitGroup.enter()
        commitQueue.async { [weak self] in
            let staging = input.destination.deletingLastPathComponent().appendingPathComponent(".toastpeek-save-\(UUID()).partial")
            let commitError: Error? = {
                do {
                    try FileManager.default.copyItem(at: input.source, to: staging)
                    try commit(staging, input.destination, input.replaceExisting)
                    return nil
                } catch {
                    return error
                }
            }()
            try? FileManager.default.removeItem(at: staging)
            DispatchQueue.main.async { [weak self, commitError] in
                self?.committing.removeValue(forKey: input.id)
                self?.commitGroup.leave()
                completion(commitError)
            }
        }
    }

    private func awaitCommits(_ completion: @escaping @MainActor @Sendable () -> Void) {
        commitGroup.notify(queue: .main, execute: completion)
    }

    init(store: BrowserStore) { self.store = store }

    func adopt(_ download: WKDownload, from tabID: UUID, profileID: UUID? = nil) {
        let key = ObjectIdentifier(download)
        guard tasks[key] == nil else { return }
        guard let profile = profileID ?? store?.controller(forTabID: tabID)?.dataStoreID else {
            download.cancel { _ in }; return
        }
        tasks[key] = Task(download, tabID: tabID, profileID: profile)
        download.delegate = self
    }

    func pendingPanel(for tabID: UUID) -> NSSavePanel? {
        tasks.values.first { $0.tabID == tabID && $0.panel != nil }?.panel
    }

    func hasActiveDownloads(for tabID: UUID) -> Bool {
        tasks.values.contains { $0.tabID == tabID } || pendingResumes.values.contains { $0.record.tabID == tabID }
    }

    private func cancelPending(_ pending: PendingResume, keepingResumeData: Bool, completion: @escaping () -> Void) {
        pending.cancellationRequested = true
        pending.keepResumeData = pending.keepResumeData && keepingResumeData
        pending.waiters.append(completion)
    }

    func cancel(_ id: UUID, keepingResumeData: Bool = true, completion: @escaping () -> Void = {}) {
        if let pending = pendingResumes[id] {
            cancelPending(pending, keepingResumeData: keepingResumeData, completion: completion)
            return
        }
        guard let task = tasks.values.first(where: { $0.id == id }) else { completion(); return }
        task.keepResumeData = task.keepResumeData && keepingResumeData
        task.cancelWaiters.append(completion)
        guard !task.cancellationPending else { return }
        task.cancellationPending = true
        task.panel?.cancel(nil)
        task.download.cancel { [weak self] data in
            _Concurrency.Task { @MainActor in
                if let self {
                    if task.keepResumeData, let data { self.remember(data, task: task) }
                    self.finish(task.download, state: "cancelled")
                }
                let waiters = task.cancelWaiters
                task.cancelWaiters = []
                waiters.forEach { $0() }
            }
        }
    }

    func cancelAll(keepingResumeData: Bool = true, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        if !keepingResumeData { for id in Array(resumeData.keys) { discardResume(id) } }
        let group = DispatchGroup()
        for pending in pendingResumes.values {
            group.enter()
            cancelPending(pending, keepingResumeData: keepingResumeData) { group.leave() }
        }
        for id in tasks.values.map(\.id) {
            group.enter()
            cancel(id, keepingResumeData: keepingResumeData) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { completion(); return }
            self.awaitCommits { [weak self] in
                guard let self else { completion(); return }
                if !keepingResumeData {
                    for task in self.completedFiles.values { self.removePartials(task) }
                    self.completedFiles.removeAll()
                }
                completion()
            }
        }
    }

    func discardProfile(_ profileID: UUID, completion: @escaping @MainActor @Sendable () -> Void) {
        for id in resumeData.keys.filter({ resumeData[$0]?.profileID == profileID }) { discardResume(id) }
        let group = DispatchGroup()
        for pending in pendingResumes.values where pending.record.profileID == profileID {
            group.enter()
            cancelPending(pending, keepingResumeData: false) { group.leave() }
        }
        for id in tasks.values.filter({ $0.profileID == profileID }).map(\.id) {
            group.enter()
            cancel(id, keepingResumeData: false) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { completion(); return }
            self.awaitCommits { [weak self] in
                guard let self else { completion(); return }
                for task in self.completedFiles.values.filter({ $0.profileID == profileID }) {
                    self.removePartials(task)
                    self.completedFiles.removeValue(forKey: task.id)
                }
                completion()
            }
        }
    }

    private func remember(_ data: Data, task: Task) {
        guard data.count <= 2_000_000, let destination = task.destination, let transfer = task.transferURL else { return }
        resumeData[task.id] = ResumeRecord(data: data, tabID: task.tabID, profileID: task.profileID,
            sourceURL: task.sourceURL,
            destination: destination, transfer: transfer,
            partials: task.inheritedPartials + (task.transferURL.map { [$0] } ?? []))
        resumeOrder.removeAll { $0 == task.id }
        resumeOrder.append(task.id)
        while resumeOrder.count > 8 { discardResume(resumeOrder[0]) }
    }

    private func discardResume(_ id: UUID) {
        if let record = resumeData.removeValue(forKey: id) {
            for url in record.partials { try? FileManager.default.removeItem(at: url) }
        }
        resumeOrder.removeAll { $0 == id }
    }

    func removeRecord(_ id: UUID) {
        discardResume(id)
        if let pending = pendingResumes[id] { cancelPending(pending, keepingResumeData: false, completion: {}) }
        if committing[id] != nil { removedWhileCommitting.insert(id) }
        else if let task = completedFiles.removeValue(forKey: id) { removePartials(task) }
        store?.downloads.removeAll { $0.id == id }
    }

    func canRetry(_ id: UUID) -> Bool { resumeData[id] != nil || completedFiles[id] != nil }
    func canSaveCompleted(_ id: UUID) -> Bool { completedFiles[id] != nil }

    /// Re-save a complete transfer; copy and commit run on the serial utility queue.
    @discardableResult
    func saveCompleted(_ id: UUID, to destination: URL, replacingExisting: Bool = false) -> Bool {
        guard committing[id] == nil, !reservedPaths.contains(pathKey(destination)),
              let task = completedFiles.removeValue(forKey: id) else { return false }
        reservedPaths.insert(pathKey(destination))
        task.destination = destination
        task.replaceExisting = replacingExisting
        enqueueCommit(task) { [weak self] error in
            guard let self else { return }
            self.reservedPaths.remove(self.pathKey(destination))
            if self.removedWhileCommitting.remove(id) != nil {
                self.removePartials(task)
                return
            }
            if let error {
                self.completedFiles[id] = task
                self.publish(task, state: "failed", error: error)
                self.store?.toast = error.localizedDescription
            } else {
                self.removePartials(task)
                self.publish(task, state: "completed")
            }
        }
        return true
    }

    func retry(_ id: UUID) {
        if let task = completedFiles[id], committing[id] == nil, let destination = task.destination {
            let target = reserveDestination(folder: destination.deletingLastPathComponent(), suggestedFilename: destination.lastPathComponent)
            reservedPaths.remove(pathKey(target))
            _ = saveCompleted(id, to: target)
            return
        }
        guard let record = resumeData[id], let store, store.canLoadWebContent,
              store.spaces.contains(where: { $0.dataStoreID == record.profileID }) else { return }
        resumeData.removeValue(forKey: id)
        resumeOrder.removeAll { $0 == id }
        let pending = PendingResume(id: id, record: record)
        pendingResumes[id] = pending
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: record.profileID)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.resumeDownload(fromResumeData: record.data) { [self, view] download in
            _ = view // Keep both manager and view alive until the cancellation barrier settles.
            let receive = { [self] in self.receiveResumed(download, pending: pending) }
            if let gate = resumeCompletionGate { gate(receive) } else { receive() }
        }
        store.downloads.removeAll { $0.id == id }
    }

    private func receiveResumed(_ download: WKDownload, pending: PendingResume) {
        let record = pending.record
        guard pendingResumes[pending.id] === pending, pending.phase == .awaitingDownload else {
            download.cancel { _ in }; return
        }
        let profileUsable = store?.canLoadWebContent == true &&
            store?.spaces.contains(where: { $0.dataStoreID == record.profileID }) == true
        if pending.cancellationRequested || !profileUsable {
            pending.phase = .cancelling
            download.cancel { [self] data in
                _Concurrency.Task { @MainActor in
                    if pending.keepResumeData, profileUsable, let data, data.count <= 2_000_000 {
                        self.resumeData[pending.id] = ResumeRecord(data: data, tabID: record.tabID,
                            profileID: record.profileID, sourceURL: record.sourceURL,
                            destination: record.destination, transfer: record.transfer, partials: record.partials)
                        self.resumeOrder.removeAll { $0 == pending.id }
                        self.resumeOrder.append(pending.id)
                        while self.resumeOrder.count > 8 { self.discardResume(self.resumeOrder[0]) }
                        self.store?.upsertDownload(fromTab: record.tabID, DownloadItemState(id: pending.id,
                            fileName: record.destination.lastPathComponent, urlString: record.sourceURL,
                            fullPath: record.destination.path, percent: -1,
                            receivedBytes: max(0, download.progress.completedUnitCount),
                            totalBytes: max(0, download.progress.totalUnitCount), state: "cancelled"))
                    } else {
                        for url in record.partials { try? FileManager.default.removeItem(at: url) }
                    }
                    self.pendingResumes.removeValue(forKey: pending.id)
                    pending.waiters.forEach { $0() }
                    pending.waiters = []
                }
            }
            return
        }
        // Removing the pending operation and adopting happen in one MainActor turn.
        pendingResumes.removeValue(forKey: pending.id)
        adopt(download, from: record.tabID, profileID: record.profileID)
        guard let task = tasks[ObjectIdentifier(download)] else { return }
        task.destination = reserveDestination(folder: record.destination.deletingLastPathComponent(), suggestedFilename: record.destination.lastPathComponent)
        task.transferURL = record.transfer
        task.sourceURL = record.sourceURL
        task.inheritedPartials = record.partials.filter { $0 != record.transfer }
        observeProgress(task)
        publish(task, state: "inProgress")
    }

    private func pathKey(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// Reserve before calling WebKit; concurrent downloads cannot pick the
    /// same not-yet-created path. Never create a placeholder WebKit must overwrite.
    func reserveDestination(folder: URL, suggestedFilename: String) -> URL {
        let clean = (suggestedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "_")
        let base = clean.isEmpty || clean == "." || clean == ".." ? "download" : clean
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidate = folder.appendingPathComponent(base)
        var n = 1
        while reservedPaths.contains(pathKey(candidate)) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)")
            n += 1
        }
        reservedPaths.insert(pathKey(candidate))
        return candidate
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let task = tasks[ObjectIdentifier(download)], let store else { completionHandler(nil); return }
        let folder = URL(fileURLWithPath: store.resolvedDownloadsFolder, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { store.toast = error.localizedDescription; finish(download, state: "failed", error: error); completionHandler(nil); return }
        let accept: (URL?) -> Void = { [weak self] url in
            guard let self, self.tasks[ObjectIdentifier(download)] === task else { completionHandler(nil); return }
            task.panel = nil
            guard let url else {
                self.tasks.removeValue(forKey: ObjectIdentifier(download))
                completionHandler(nil)
                return
            }
            // Only a completed transfer replaces an existing file the save
            // panel approved. Failed downloads leave that original intact.
            task.destination = url
            task.replaceExisting = store.askDownloadLocation && FileManager.default.fileExists(atPath: url.path)
            let transfer = url.deletingLastPathComponent().appendingPathComponent(".toastpeek-\(task.id).partial")
            task.transferURL = transfer
            self.reservedPaths.insert(self.pathKey(url))
            self.observeProgress(task)
            self.publish(task, state: "inProgress")
            completionHandler(transfer)
        }
        if store.askDownloadLocation {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
            panel.directoryURL = folder
            panel.canCreateDirectories = true
            task.panel = panel
            let complete: (NSApplication.ModalResponse) -> Void = { result in
                guard result == .OK, let url = panel.url else { accept(nil); return }
                if self.reservedPaths.contains(self.pathKey(url)) {
                    accept(self.reserveDestination(folder: url.deletingLastPathComponent(), suggestedFilename: url.lastPathComponent))
                } else { accept(url) }
            }
            if let window = store.controller(forTabID: task.tabID)?.container.window {
                panel.beginSheetModal(for: window, completionHandler: complete)
            } else { panel.begin(completionHandler: complete) }
        } else {
            accept(reserveDestination(folder: folder, suggestedFilename: suggestedFilename))
        }
    }

    private func observeProgress(_ task: Task) {
        let key = ObjectIdentifier(task.download)
        task.observation = task.download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            _Concurrency.Task { @MainActor in
                guard let self, let active = self.tasks[key] else { return }
                self.publish(active, state: "inProgress")
            }
        }
    }

    private func publish(_ task: Task, state: String, error: Error? = nil) {
        guard let dest = task.destination else { return }
        let progress = task.download.progress
        let received = max(0, progress.completedUnitCount), total = max(0, progress.totalUnitCount)
        store?.upsertDownload(fromTab: task.tabID, DownloadItemState(id: task.id,
            fileName: dest.lastPathComponent, urlString: task.sourceURL,
            fullPath: dest.path, percent: state == "completed" ? 100 : total > 0 ? min(100, Int(Double(received) / Double(total) * 100)) : -1,
            receivedBytes: received, totalBytes: total, state: state, errorDescription: error?.localizedDescription))
    }

    private func removePartials(_ task: Task) {
        for source in task.inheritedPartials + (task.transferURL.map { [$0] } ?? []) {
            try? FileManager.default.removeItem(at: source)
        }
    }


    private func finish(_ download: WKDownload, state: String, error: Error? = nil) {
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(download)) else { return }
        task.observation = nil
        if state == "completed", task.transferURL != nil, task.destination != nil {
            enqueueCommit(task) { [weak self] commitError in
                guard let self else { return }
                if let destination = task.destination { self.reservedPaths.remove(self.pathKey(destination)) }
                if self.removedWhileCommitting.remove(task.id) != nil {
                    self.removePartials(task)
                    return
                }
                if let commitError {
                    self.completedFiles[task.id] = task
                    self.publish(task, state: "failed", error: commitError)
                    self.store?.toast = commitError.localizedDescription
                } else {
                    self.removePartials(task)
                    self.publish(task, state: "completed")
                }
            }
            return
        }
        if let dest = task.destination { reservedPaths.remove(pathKey(dest)) }
        if resumeData[task.id] == nil { removePartials(task) }
        if state == "failed" { store?.toast = error?.localizedDescription ?? String(localized: "Download failed") }
        publish(task, state: state, error: error)
    }

    func downloadDidFinish(_ download: WKDownload) { finish(download, state: "completed") }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData data: Data?) {
        // cancel's completion owns its resume data. A delegate callback can
        // arrive first; deleting the partial here would invalidate that data.
        if tasks[ObjectIdentifier(download)]?.cancellationPending == true { return }
        if let task = tasks[ObjectIdentifier(download)], task.keepResumeData, let data { remember(data, task: task) }
        finish(download, state: (error as NSError).code == NSURLErrorCancelled ? "cancelled" : "failed", error: error)
    }
}
