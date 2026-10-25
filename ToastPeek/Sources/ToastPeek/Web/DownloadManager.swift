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

    func hasActiveDownloads(for tabID: UUID) -> Bool { tasks.values.contains { $0.tabID == tabID } }

    func cancel(_ id: UUID, keepingResumeData: Bool = true, completion: @escaping () -> Void = {}) {
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

    func cancelAll(keepingResumeData: Bool = true, completion: @escaping () -> Void = {}) {
        if !keepingResumeData { for id in Array(resumeData.keys) { discardResume(id) } }
        let group = DispatchGroup()
        for id in tasks.values.map(\.id) {
            group.enter()
            cancel(id, keepingResumeData: keepingResumeData) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func discardProfile(_ profileID: UUID, completion: @escaping @MainActor @Sendable () -> Void) {
        for id in resumeData.keys.filter({ resumeData[$0]?.profileID == profileID }) { discardResume(id) }
        let group = DispatchGroup()
        for id in tasks.values.filter({ $0.profileID == profileID }).map(\.id) {
            group.enter()
            cancel(id, keepingResumeData: false) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
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
        store?.downloads.removeAll { $0.id == id }
    }

    func canRetry(_ id: UUID) -> Bool { resumeData[id] != nil }

    func retry(_ id: UUID) {
        guard let record = resumeData[id], let store, store.canLoadWebContent,
              store.spaces.contains(where: { $0.dataStoreID == record.profileID }) else { return }
        resumeData.removeValue(forKey: id)
        resumeOrder.removeAll { $0 == id }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: record.profileID)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.resumeDownload(fromResumeData: record.data) { [weak self, view] download in
            _ = view // Retain the initiating view until WebKit transfers ownership.
            guard let self else { download.cancel { _ in }; return }
            self.adopt(download, from: record.tabID, profileID: record.profileID)
            guard let task = self.tasks[ObjectIdentifier(download)] else { return }
            // A resumed WKDownload already has its destination in the opaque
            // resume data; it need not ask the delegate to choose one again.
            task.destination = self.reserveDestination(folder: record.destination.deletingLastPathComponent(), suggestedFilename: record.destination.lastPathComponent)
            task.transferURL = record.transfer
            task.sourceURL = record.sourceURL
            task.inheritedPartials = record.partials.filter { $0 != record.transfer }
            self.observeProgress(task)
            self.publish(task, state: "inProgress")
        }
        store.downloads.removeAll { $0.id == id }
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

    private func finish(_ download: WKDownload, state: String, error: Error? = nil) {
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(download)) else { return }
        task.observation = nil
        if let dest = task.destination { reservedPaths.remove(pathKey(dest)) }
        var finalState = state, finalError = error
        if state == "completed", let source = task.transferURL, let destination = task.destination {
            do {
                if task.replaceExisting {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
                } else { try FileManager.default.moveItem(at: source, to: destination) }
            } catch { finalState = "failed"; finalError = error }
        }
        if resumeData[task.id] == nil {
            for source in task.inheritedPartials + (task.transferURL.map { [$0] } ?? []) {
                try? FileManager.default.removeItem(at: source)
            }
        }
        if finalState == "failed" { store?.toast = finalError?.localizedDescription ?? String(localized: "Download failed") }
        publish(task, state: finalState, error: finalError)
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
