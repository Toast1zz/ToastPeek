import XCTest
import AppKit
import SwiftUI
import WebKit
import PDFKit

/// Tests the actual system WebKit, not stand-ins for navigation/download delegates.
@MainActor
final class WebKitRuntimeTests: XCTestCase {
    private var root: URL!
    private var server: Process!
    private var base: String!
    private var store: BrowserStore!
    private var windows: [NSWindow] = []
    private final class WeakView {
        weak var value: WKWebView?
        init(_ value: WKWebView?) { self.value = value }
    }
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
        func set() { lock.lock(); storage = true; lock.unlock() }
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-webkit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/testing/browser_fixture.py")
        let portFile = root.appendingPathComponent("server.json")
        server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        let port = try await waitForFixturePort(at: portFile)
        base = "http://127.0.0.1:\(port)"
        store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        store.tabs = []
        store.spaces = [BrowserSpace(name: "Runtime test", icon: "house", colorHex: "#7C6FF0")]
        store.currentSpaceID = store.spaces[0].id
        store.askDownloadLocation = false
        store.downloadsFolder = root.appendingPathComponent("downloads").path
        try FileManager.default.createDirectory(atPath: store.downloadsFolder!, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let profileIDs = store?.spaces.map(\.dataStoreID) ?? []
        if let store {
            await withCheckedContinuation { continuation in
                store.downloadManager.cancelAll(keepingResumeData: false) { continuation.resume() }
            }
        }
        for id in Array(store?.controllers.keys ?? [:].keys) { store?.unload(id) }
        for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
        windows = []
        store?.flush()
        store = nil
        for id in profileIDs {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
            }
        }
        if server?.isRunning == true { server.terminate() }
        server = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitForFixturePort(at url: URL) async throws -> Int {
        let deadline = Date().addingTimeInterval(12)
        var lastData = Data()
        while Date() < deadline {
            // Python's write_text creates/truncates the file before writing.
            // Existence, or one successful read, does not mean JSON is complete.
            if let data = try? Data(contentsOf: url) {
                lastData = data
                if let object = try? JSONSerialization.jsonObject(with: data),
                   let json = object as? [String: Int], let port = json["port"],
                   (1...65535).contains(port) { return port }
            }
            guard server.isRunning else {
                throw NSError(domain: "RuntimeFixtureStartup", code: Int(server.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Fixture exited before publishing a complete port record"])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "RuntimeFixtureStartup", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Timed out waiting for complete fixture port JSON; received \(String(decoding: lastData, as: UTF8.self))"])
    }

    private func waitUntil(timeout: TimeInterval = 12, label: String = "condition", _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { throw NSError(domain: "RuntimeTestTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func show(_ path: String) async throws -> WebTabController {
        let state = store.makeWindowState()
        store.activeWindowState = state
        store.newTab(urlString: base + path)
        let tab = try XCTUnwrap(store.selectedTab)
        let controller = store.controller(for: tab)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        state.window = window
        windows.append(window)
        let host = PaneHostView()
        host.controller = controller
        window.contentView = host
        window.orderFront(nil)
        host.attachIfPossible()
        controller.ensureBrowser()
        do {
            try await waitUntil(label: "page did not finish: " + path) { controller.hasCommittedPage && !controller.isLoading }
        } catch {
            controller.recordPresentationEvent("runtime-test-timeout")
            let view = controller.webView
            throw NSError(domain: "RuntimePage", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(path) browser=\(view != nil) committed=\(controller.hasCommittedPage) loading=\(controller.isLoading) nativeLoading=\(view?.isLoading ?? false) policy=\(controller.contentBlockingApplied) canLoad=\(self.store.canLoadWebContent) requested=\(controller.currentURLString) url=\(view?.url?.absoluteString ?? "nil") frame=\(controller.container.frame) mounted=\(controller.container.window != nil) loadError=\(String(describing: controller.loadError))"])
        }
        XCTAssertNil(controller.loadError)
        return controller
    }

    private func js(_ controller: WebTabController, _ source: String) async throws -> Any? {
        let view = try XCTUnwrap(controller.webView)
        return try await view.evaluateJavaScript(source)
    }

    func testRealPageRendersAndBrowserBridgeIsIsolated() async throws {
        let c = try await show("/page")
        let jsResult1 = try await js(c, "document.getElementById('marker').textContent")
        XCTAssertEqual(jsResult1 as? String, "Visible fixture page")
        let jsResult2 = try await js(c, "typeof window.webkit?.messageHandlers?.toastpeekContext")
        XCTAssertEqual(jsResult2 as? String, "undefined")
        XCTAssertTrue(c.contentBlockingApplied)
        let snapshot = try await XCTUnwrap(c.webView).takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(snapshot.tiffRepresentation)))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).usingColorSpace(.deviceRGB)
        XCTAssertEqual(try XCTUnwrap(pixel).redComponent, 216.0 / 255, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(pixel).blueComponent, 250.0 / 255, accuracy: 0.04)
        XCTAssertGreaterThan(c.container.bounds.width, 700)
        XCTAssertEqual(store.history.first?.urlString, base + "/page")
    }

    func testAutomaticPopupIsBlockedByWebKit() async throws {
        let c = try await show("/auto-popup")
        let jsResult3 = try await js(c, "window.result")
        XCTAssertEqual(jsResult3 as? Bool, true)
        XCTAssertEqual(store.tabs.count, 1)
    }

    func testConcurrentDownloadsSurviveClosingSourceTabs() async throws {
        let a = try await show("/page?a")
        let b = try await show("/page?b")
        a.downloadURL(base + "/download/a")
        b.downloadURL(base + "/download/b")
        try await waitUntil(label: "two download tasks did not start") { self.store.downloads.count == 2 }
        let sourceA = try XCTUnwrap(store.tab(a.tabID)), sourceB = try XCTUnwrap(store.tab(b.tabID))
        store.close(sourceA); store.close(sourceB)
        try await waitUntil(label: "two downloads did not finish") { self.store.downloads.filter { $0.state == "completed" }.count == 2 }
        let downloads = store.downloads
        XCTAssertNotEqual(downloads[0].fullPath, downloads[1].fullPath)
        let contents = try downloads.map { try String(contentsOfFile: $0.fullPath, encoding: .utf8) }
        XCTAssertTrue(contents.contains { $0.hasPrefix("a\n") })
        XCTAssertTrue(contents.contains { $0.hasPrefix("b\n") })
    }

    func testCancelledDownloadCleansPartialAfterDiscard() async throws {
        let c = try await show("/page")
        c.downloadURL(base + "/download/slow")
        try await waitUntil(label: "slow download did not start") { self.store.downloads.contains { $0.state == "inProgress" } }
        let item = try XCTUnwrap(store.downloads.first)
        await withCheckedContinuation { continuation in
            store.downloadManager.cancel(item.id) { continuation.resume() }
        }
        XCTAssertEqual(store.downloads.first?.state, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fullPath))
        store.downloadManager.removeRecord(item.id)
        let files = try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!)
        XCTAssertTrue(files.isEmpty, "Discarded download left partial files: \(files)")
    }

    func testCancelledDownloadCanResumeToCompleteFile() async throws {
        let c = try await show("/page")
        c.downloadURL(base + "/download/slow")
        try await waitUntil(label: "resumable download did not start") { self.store.downloads.contains { $0.state == "inProgress" } }
        let item = try XCTUnwrap(store.downloads.first)
        try await Task.sleep(nanoseconds: 150_000_000)
        await withCheckedContinuation { continuation in
            store.downloadManager.cancel(item.id) { continuation.resume() }
        }
        XCTAssertTrue(store.downloadManager.canRetry(item.id))
        store.downloadManager.retry(item.id)
        try await waitUntil(label: "resumed transfer did not complete") { self.store.downloads.contains { $0.state == "completed" } }
        let complete = try XCTUnwrap(store.downloads.first { $0.state == "completed" })
        XCTAssertEqual(complete.urlString, base + "/download/slow")
        let data = try Data(contentsOf: URL(fileURLWithPath: complete.fullPath))
        XCTAssertEqual(data, Data(String(repeating: "slow\n", count: 262144).utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!)
        XCTAssertEqual(files, [complete.fileName])
    }

    func testFinalMoveCollisionKeepsCompleteTransferAndRetriesOffline() async throws {
        let c = try await show("/page")
        let manager = store.downloadManager
        let commit = manager.commitFile
        let foreign = Data("created by another process".utf8)
        manager.commitFile = { source, destination, replace in
            try foreign.write(to: destination)
            try commit(source, destination, replace)
        }
        c.downloadURL(base + "/download/a")
        try await waitUntil { self.store.downloads.contains { $0.state == "failed" } }
        let item = try XCTUnwrap(store.downloads.first)
        XCTAssertTrue(manager.canSaveCompleted(item.id))
        XCTAssertTrue(manager.canRetry(item.id))
        XCTAssertEqual(try Data(contentsOf: item.fileURL), foreign)
        let partials = try FileManager.default.contentsOfDirectory(at: item.fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "partial" }
        XCTAssertEqual(partials.count, 1)
        let partial = try XCTUnwrap(partials.first)
        let completeBytes = try Data(contentsOf: partial)
        XCTAssertEqual(completeBytes, Data(String(repeating: "a\n", count: 32768).utf8))
        server.terminate() // Recovery must work after the source disappears.
        manager.commitFile = commit
        manager.retry(item.id)
        try await waitUntil { self.store.downloads.first { $0.id == item.id }?.state == "completed" }
        let saved = try XCTUnwrap(store.downloads.first { $0.id == item.id })
        XCTAssertEqual(saved.state, "completed")
        XCTAssertNotEqual(saved.fullPath, item.fullPath)
        XCTAssertEqual(try Data(contentsOf: saved.fileURL), completeBytes)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(manager.canRetry(item.id))
    }

    func testCancelAllWaitsForPendingCommitBeforeDiscardingSource() async throws {
        let c = try await show("/page")
        let manager = store.downloadManager
        let entered = LockedFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        manager.commitFile = { _, _, _ in
            entered.set()
            release.wait()
            throw CocoaError(.fileWriteNoPermission)
        }
        c.downloadURL(base + "/download/a")
        try await waitUntil(label: "commit did not start") { entered.value }
        var finished = false
        manager.cancelAll(keepingResumeData: false) { finished = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished, "cleanup must wait for the background commit")
        release.signal()
        try await waitUntil(label: "cleanup did not finish") { finished }
        let partials = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: store.resolvedDownloadsFolder), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "partial" }
        XCTAssertTrue(partials.isEmpty)
        for item in store.downloads { XCTAssertFalse(manager.canSaveCompleted(item.id)) }
    }

    func testFailedReplaceConsumesOnlyStagingCopyAndCanSaveAsOffline() async throws {
        let c = try await show("/page")
        let manager = store.downloadManager
        let commit = manager.commitFile
        manager.commitFile = { source, _, _ in
            // Model a replace implementation that consumes its input before failing.
            try FileManager.default.removeItem(at: source)
            throw CocoaError(.fileWriteNoPermission)
        }
        c.downloadURL(base + "/download/b")
        try await waitUntil { self.store.downloads.contains { $0.state == "failed" } }
        let item = try XCTUnwrap(store.downloads.first)
        let target = root.appendingPathComponent("save-again.txt")
        let existing = Data("existing document".utf8)
        try existing.write(to: target)
        XCTAssertTrue(manager.saveCompleted(item.id, to: target, replacingExisting: true))
        await withCheckedContinuation { continuation in
            manager.cancelAll { continuation.resume() }
        }
        XCTAssertEqual(try Data(contentsOf: target), existing)
        XCTAssertTrue(manager.canSaveCompleted(item.id))
        server.terminate()
        manager.commitFile = commit
        let alternate = root.appendingPathComponent("saved-elsewhere.txt")
        XCTAssertTrue(manager.saveCompleted(item.id, to: alternate))
        try await waitUntil { self.store.downloads.first { $0.id == item.id }?.state == "completed" }
        XCTAssertEqual(try Data(contentsOf: alternate), Data(String(repeating: "b\n", count: 32768).utf8))
        XCTAssertEqual(store.downloads.first?.state, "completed")
        XCTAssertFalse(manager.canSaveCompleted(item.id))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!)
        XCTAssertTrue(files.isEmpty, "Successful recovery left transfer/staging files: \(files)")
    }

    func testRemovingRecordDuringSaveDoesNotDeleteSourceOrRepublish() async throws {
        let c = try await show("/page")
        let manager = store.downloadManager
        let commit = manager.commitFile
        manager.commitFile = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        c.downloadURL(base + "/download/a")
        try await waitUntil { self.store.downloads.contains { $0.state == "failed" } }
        let item = try XCTUnwrap(store.downloads.first)
        let entered = LockedFlag()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        manager.commitFile = { source, destination, replace in
            entered.set()
            release.wait()
            try commit(source, destination, replace)
        }
        let target = root.appendingPathComponent("saved.txt")
        XCTAssertTrue(manager.saveCompleted(item.id, to: target))
        try await waitUntil(label: "save did not start") { entered.value }
        XCTAssertFalse(manager.saveCompleted(item.id, to: root.appendingPathComponent("second.txt")))
        manager.removeRecord(item.id)
        XCTAssertFalse(store.downloads.contains { $0.id == item.id })
        release.signal()
        await withCheckedContinuation { continuation in manager.cancelAll { continuation.resume() } }
        XCTAssertEqual(try Data(contentsOf: target), Data(String(repeating: "a\n", count: 32768).utf8))
        XCTAssertFalse(store.downloads.contains { $0.id == item.id })
        XCTAssertFalse(manager.canSaveCompleted(item.id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testDiscardCompleteTransferAfterCommitFailureRemovesPartial() async throws {
        let c = try await show("/page")
        store.downloadManager.commitFile = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        c.downloadURL(base + "/download/a")
        try await waitUntil { self.store.downloads.contains { $0.state == "failed" } }
        let item = try XCTUnwrap(store.downloads.first)
        XCTAssertTrue(store.downloadManager.canSaveCompleted(item.id))
        store.downloadManager.removeRecord(item.id)
        XCTAssertFalse(store.downloadManager.canRetry(item.id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testClearingDataDiscardsFailedCompletedTransferButPreservesSavedFile() async throws {
        let c = try await show("/page")
        let saved = root.appendingPathComponent("already-saved.txt")
        let savedBytes = Data("saved document".utf8)
        try savedBytes.write(to: saved)
        store.downloadManager.commitFile = { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        c.downloadURL(base + "/download/a")
        try await waitUntil { self.store.downloads.contains { $0.state == "failed" } }
        let id = try XCTUnwrap(store.downloads.first?.id)
        XCTAssertTrue(store.downloadManager.canSaveCompleted(id))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).filter { $0.hasSuffix(".partial") }.count, 1)
        store.clearBrowsingData()
        try await waitUntil { !self.store.isClearingData }
        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertFalse(store.downloadManager.canSaveCompleted(id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).filter { $0.hasSuffix(".partial") }.isEmpty)
        XCTAssertEqual(try Data(contentsOf: saved), savedBytes)
    }

    func testReadOnlyStoreCannotClearActiveProfileCookies() async throws {
        let c = try await show("/page")
        _ = try await js(c, "document.cookie='audit=present;path=/'")
        let initial = try await js(c, "document.cookie") as? String ?? ""
        XCTAssertTrue(initial.contains("audit=present"))
        XCTAssertTrue(store.flush())
        let second = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        XCTAssertTrue(second.isReadOnly)
        let tab = try XCTUnwrap(store.tab(c.tabID))
        await withCheckedContinuation { continuation in
            second.clearSiteData(for: tab) { success in XCTAssertFalse(success); continuation.resume() }
        }
        second.clearSpaceData(try XCTUnwrap(second.spaces.first { $0.id == tab.spaceID }))
        XCTAssertFalse(second.isClearingData)
        let cookies = try await js(c, "document.cookie") as? String ?? ""
        XCTAssertTrue(cookies.contains("audit=present"))
    }

    private func suspendedResume() async throws -> (WebTabController, UUID, () -> Void) {
        let c = try await show("/page")
        c.downloadURL(base + "/download/slow")
        try await waitUntil { self.store.downloads.contains { $0.state == "inProgress" && $0.receivedBytes > 0 } }
        let item = try XCTUnwrap(store.downloads.first)
        await withCheckedContinuation { continuation in
            store.downloadManager.cancel(item.id) { continuation.resume() }
        }
        XCTAssertTrue(store.downloadManager.canRetry(item.id))
        var release: (() -> Void)?
        store.downloadManager.resumeCompletionGate = { release = $0 }
        store.downloadManager.retry(item.id)
        // Pending ownership is visible even before WebKit's callback arrives.
        XCTAssertTrue(store.downloadManager.hasActiveDownloads(for: c.tabID))
        try await waitUntil { release != nil }
        store.downloadManager.resumeCompletionGate = nil
        return (c, item.id, try XCTUnwrap(release))
    }

    func testCancelAllWaitsForLateResumeCancellationAndEscalatesDiscard() async throws {
        let (c, id, release) = try await suspendedResume()
        var firstCompleted = false, discarded = false
        store.downloadManager.cancelAll { firstCompleted = true }
        store.downloadManager.cancelAll(keepingResumeData: false) { discarded = true }
        await Task.yield()
        XCTAssertFalse(firstCompleted)
        XCTAssertFalse(discarded)
        release()
        try await waitUntil { firstCompleted && discarded }
        XCTAssertFalse(store.downloadManager.hasActiveDownloads(for: c.tabID))
        XCTAssertFalse(store.downloadManager.canRetry(id))
        XCTAssertFalse(store.downloads.contains { $0.state == "inProgress" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testProfileDiscardWaitsForLateResumeBeforeAllowingDeletion() async throws {
        let (c, id, release) = try await suspendedResume()
        var discarded = false
        store.downloadManager.discardProfile(store.spaces[0].dataStoreID) { discarded = true }
        await Task.yield()
        XCTAssertFalse(discarded)
        release()
        try await waitUntil { discarded }
        XCTAssertFalse(store.downloadManager.hasActiveDownloads(for: c.tabID))
        XCTAssertFalse(store.downloadManager.canRetry(id))
        XCTAssertFalse(store.downloads.contains { $0.state == "inProgress" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testDeleteSpaceWaitsForPendingResumeAndDoesNotRecreateProfile() async throws {
        let (c, id, release) = try await suspendedResume()
        let original = store.spaces[0]
        store.spaces.append(BrowserSpace(name: "Survivor", icon: "house", colorHex: "#7C6FF0"))
        store.deleteSpace(original.id)
        await Task.yield()
        XCTAssertTrue(store.pendingDataStoreDeletions.contains(original.dataStoreID))
        release()
        try await waitUntil { self.store.pendingDataStoreDeletions.isEmpty }
        XCTAssertFalse(store.downloadManager.hasActiveDownloads(for: c.tabID))
        XCTAssertFalse(store.downloadManager.canRetry(id))
        XCTAssertFalse(store.spaces.contains { $0.dataStoreID == original.dataStoreID })
        XCTAssertFalse(store.downloads.contains { $0.state == "inProgress" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testClearBrowsingDataWaitsForPendingResumeAndDoesNotAdoptIt() async throws {
        let (c, id, release) = try await suspendedResume()
        store.clearBrowsingData()
        await Task.yield()
        XCTAssertTrue(store.isClearingData)
        XCTAssertFalse(store.canLoadWebContent)
        release()
        try await waitUntil { !self.store.isClearingData }
        XCTAssertFalse(store.downloadManager.hasActiveDownloads(for: c.tabID))
        XCTAssertFalse(store.downloadManager.canRetry(id))
        XCTAssertFalse(store.downloads.contains { $0.state == "inProgress" })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.downloadsFolder!).isEmpty)
    }

    func testDeleteSpaceRemovesItsCookieStoreAndPersistsCompletion() async throws {
        var c: WebTabController? = try await show("/page")
        _ = try await js(try XCTUnwrap(c), "document.cookie='deleted_identity=yes;path=/'")
        let oldSpace = store.spaces[0]
        let second = BrowserSpace(name: "Surviving identity", icon: "house", colorHex: "#7C6FF0")
        store.spaces.append(second)
        let releasedView = WeakView(c?.webView)
        store.deleteSpace(oldSpace.id)
        c = nil
        try await waitUntil(label: "deleted space retained its web view") { releasedView.value == nil }
        do { try await waitUntil(label: "deleted profile was not removed") {
            self.store.pendingDataStoreDeletions.isEmpty
        } } catch {
            XCTFail("Profile cleanup: " + (store.toast ?? "no error") + "; " + (store.persistenceError ?? "no persistence error"))
            throw error
        }
        XCTAssertTrue(store.flush())
        let saved = try XCTUnwrap(StateFile.decode(Data(contentsOf: root.appendingPathComponent("state.json"))))
        XCTAssertTrue(saved.pendingDataStoreDeletions?.isEmpty == true)
        let cookies = await WKWebsiteDataStore(forIdentifier: oldSpace.dataStoreID).httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name == "deleted_identity" })
        XCTAssertFalse(store.spaces.contains { $0.id == oldSpace.id })
        // Reading a removed identity recreates an empty store; remove this test's probe.
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.remove(forIdentifier: oldSpace.dataStoreID) { _ in continuation.resume() }
        }
    }

    func testWebArchiveContainsLoadedDocumentAndPrintHasPaperPages() async throws {
        let c = try await show("/long")
        let view = try XCTUnwrap(c.webView)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            view.createWebArchiveData { continuation.resume(with: $0) }
        }
        let archive = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let resource = try XCTUnwrap(archive["WebMainResource"] as? [String: Any])
        let html = try XCTUnwrap(resource["WebResourceData"] as? Data)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("Printed paragraph 34"))
        let prep: WebTabController.PrintPreparation? = await withCheckedContinuation { continuation in
            c.preparePrint { continuation.resume(returning: $0) }
        }
        let result = try XCTUnwrap(prep)
        XCTAssertGreaterThan(result.pageCount, 3)
        XCTAssertEqual(result.firstPageSize.width, 612, accuracy: 1)
        XCTAssertEqual(result.firstPageSize.height, 792, accuracy: 1)
        XCTAssertTrue(result.printOperationReady)
        XCTAssertTrue(PDFDocument(data: result.pdfData)?.string?.contains("Printed paragraph 34") == true)
    }

    func testMutePreservesOfflineWebAudioSignalAndDisconnectSemantics() async throws {
        let c = try await show("/page")
        let view = try XCTUnwrap(c.webView)
        let render = """
        const ctx = new OfflineAudioContext(1, 256, 44100);
        const source = ctx.createConstantSource(); source.offset.value = 0.25;
        const target = source.connect(ctx.destination);
        source.disconnect(ctx.destination);
        source.connect(ctx.destination); source.start();
        const audio = await ctx.startRendering();
        return {sample: audio.getChannelData(0)[200], returnsDestination: target === ctx.destination};
        """
        for muted in [false, true, false] {
            c.setMuted(muted)
            let result = try await view.callAsyncJavaScript(render, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(try XCTUnwrap(result?["sample"] as? Double), muted ? 0 : 0.25, accuracy: 0.001)
            XCTAssertEqual(result?["returnsDestination"] as? Bool, true)
        }
    }

    func testBoostStyleEditPreservesDocumentAndFormState() async throws {
        let c = try await show("/page")
        _ = try await js(c, "document.getElementById('text').value='unsent draft';window.sessionMarker=123")
        store.boosts = [Boost(name: "Fixture", hostPattern: "127.0.0.1", css: "body{color:rgb(1,2,3)}", js: "")]
        store.applyBoostsToOpenTabs()
        try await Task.sleep(nanoseconds: 150_000_000)
        let jsResult4 = try await js(c, "document.getElementById('text').value")
        XCTAssertEqual(jsResult4 as? String, "unsent draft")
        let jsResult5 = try await js(c, "window.sessionMarker")
        XCTAssertEqual(jsResult5 as? Int, 123)
        let jsResult6 = try await js(c, "getComputedStyle(document.body).color")
        XCTAssertEqual(jsResult6 as? String, "rgb(1, 2, 3)")
        store.boosts = []
        store.applyBoostsToOpenTabs()
        try await Task.sleep(nanoseconds: 150_000_000)
        let jsResult7 = try await js(c, "getComputedStyle(document.body).color")
        XCTAssertNotEqual(jsResult7 as? String, "rgb(1, 2, 3)")
    }
    func testLiveCookieIdentitySurvivesFavoriteAndSpaceReordering() async throws {
        let c = try await show("/page")
        _ = try await js(c, "document.cookie='identity=alpha;path=/'")
        let original = try XCTUnwrap(store.tab(c.tabID))
        store.toggleFavorite(original)
        let other = BrowserSpace(name: "Other identity", icon: "house", colorHex: "#7C6FF0")
        store.spaces.insert(other, at: 0)
        store.currentSpaceID = other.id
        let otherPage = try await show("/page")
        let isolatedCookie = try await js(otherPage, "document.cookie") as? String
        XCTAssertFalse(isolatedCookie?.contains("identity=alpha") == true)
        let favorite = try XCTUnwrap(store.tab(c.tabID))
        XCTAssertTrue(store.controller(for: favorite) === c)
        let originalCookie = try await js(c, "document.cookie") as? String
        XCTAssertTrue(originalCookie?.contains("identity=alpha") == true)
    }

    func testLoadedViewTransferCannotBeZeroedByRetiredHost() async throws {
        let c = try await show("/page")
        let oldHost = try XCTUnwrap(c.container.superview as? PaneHostView)
        let newState = store.makeWindowState(preferredTabID: c.tabID)
        let newWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 520),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        newWindow.isReleasedWhenClosed = false
        newState.window = newWindow
        windows.append(newWindow)
        let newHost = PaneHostView()
        newHost.controller = c
        newWindow.contentView = newHost
        newWindow.orderFront(nil)
        newHost.attachIfPossible()
        oldHost.frame = .zero
        oldHost.layout(); oldHost.attachIfPossible(); oldHost.detach()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(c.container.superview === newHost)
        XCTAssertEqual(c.webView?.bounds.width ?? 0, 740, accuracy: 1)
        let marker = try await js(c, "document.getElementById('marker').textContent") as? String
        XCTAssertEqual(marker, "Visible fixture page")
        let image = try await XCTUnwrap(c.webView).takeSnapshot(configuration: nil)
        XCTAssertGreaterThan(try XCTUnwrap(image.tiffRepresentation).count, 2000)
    }

    func testClearBrowsingDataWaitsForCookiesAndSanitizesBothSnapshots() async throws {
        let c = try await show("/page")
        _ = try await js(c, "document.cookie='private_marker=secret;path=/'")
        XCTAssertTrue(store.flush())
        store.clearBrowsingData()
        XCTAssertFalse(store.canLoadWebContent)
        try await waitUntil(label: "site-data cleanup did not complete") { !self.store.isClearingData }
        XCTAssertTrue(store.canLoadWebContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json.cleanup-pending").path))
        XCTAssertTrue(store.history.isEmpty)
        for path in ["state.json", "state.json.bak"] {
            XCTAssertTrue(try XCTUnwrap(StateFile.decode(Data(contentsOf: root.appendingPathComponent(path)))).history.isEmpty)
        }
        let restored = try await show("/page")
        let cookies = try await js(restored, "document.cookie") as? String
        XCTAssertFalse(cookies?.contains("private_marker") == true)
    }

    func testDurableCleanupIntentResumesBeforeNextPageCanLoad() async throws {
        var c: WebTabController? = try await show("/page")
        _ = try await js(try XCTUnwrap(c), "document.cookie='restart_cleanup=yes;path=/'")
        XCTAssertTrue(store.flush())
        try Data().write(to: root.appendingPathComponent("state.json.cleanup-pending"))
        for id in Array(store.controllers.keys) { store.unload(id) }
        c = nil
        store = nil
        store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        XCTAssertFalse(store.canLoadWebContent)
        try await waitUntil(label: "restart cleanup did not finish") { !self.store.isClearingData }
        XCTAssertTrue(store.canLoadWebContent)
        let loaded = try await show("/page")
        let cookies = try await js(loaded, "document.cookie") as? String
        XCTAssertFalse(cookies?.contains("restart_cleanup") == true)
    }

    func testRapidContentRuleChangesSettleWithoutReloadingThePage() async throws {
        let c = try await show("/page")
        var completions = 0
        for index in 0..<6 {
            ContentBlocker.setExemptHosts(["fixture-\(index).example"])
            c.refreshNativeExtensions { completions += 1 }
        }
        ContentBlocker.setExemptHosts([])
        c.refreshNativeExtensions { completions += 1 }
        try await waitUntil(label: "content-rule changes did not settle") { completions == 7 }
        XCTAssertTrue(c.contentBlockingApplied)
        let marker = try await js(c, "document.getElementById('marker').textContent") as? String
        XCTAssertEqual(marker, "Visible fixture page")
    }

    func testRealSwiftUIWindowStartsAfterOwnershipRegistration() async throws {
        store.showOnboarding = false
        store.newTab(urlString: base + "/page")
        let state = store.makeWindowState()
        store.activeWindowState = state
        let tab = try XCTUnwrap(store.tab(state.selectedTabID))
        let hosting = NSHostingController(rootView: ContentView().environmentObject(store).environmentObject(state))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        // Match production: the host's first viewDidMoveToWindow can precede this.
        state.window = window
        window.setContentSize(NSSize(width: 1000, height: 700))
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        let c = store.controller(for: tab)
        try await waitUntil { c.hasCommittedPage && !c.isLoading }
        XCTAssertTrue(c.container.window === window)
        XCTAssertGreaterThan(c.webView?.bounds.width ?? 0, 500)
        let marker = try await js(c, "document.getElementById('marker').textContent") as? String
        XCTAssertEqual(marker, "Visible fixture page")
    }

}
