import XCTest
import AppKit
import WebKit

final class BrowserRegressionTests: XCTestCase {
    @MainActor
    private func withStore(_ test: (BrowserStore, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        defer {
            for id in Array(store.controllers.keys) { store.unload(id) }
            store.flush()
            try? FileManager.default.removeItem(at: root)
        }
        store.tabs = []
        let state = store.makeWindowState()
        store.activeWindowState = state
        try test(store, root)
    }

    @MainActor
    func testEquivalentContentRulesHaveStableSerialization() {
        ContentBlocker.setExemptHosts(["a.example", "b.example"])
        let expected = ContentBlocker.rulesJSON
        for _ in 0..<100 { XCTAssertEqual(ContentBlocker.rulesJSON, expected) }
        ContentBlocker.setExemptHosts([])
    }

    @MainActor
    func testSessionSnapshotsAtDifferentSizesKeepAllRecords() throws {
        try withStore { store, root in
            for count in [100, 1000, 5000] {
                store.tabs = (0..<count).map { BrowserTab(spaceID: store.currentSpaceID, kind: .today,
                    title: "Fixture \($0)", urlString: "https://fixture.example/\($0)") }
                store.history = (0..<count).map { HistoryEntry(title: "Fixture \($0)", urlString: "https://fixture.example/\($0)") }
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertTrue(store.flush())
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
                let saved = try XCTUnwrap(StateFile.decode(data))
                XCTAssertEqual(saved.tabs.count, count)
                XCTAssertEqual(saved.history.count, count)
                print("SESSION_BENCHMARK count=\(count) save_ms=\(elapsed * 1000) bytes=\(data.count)")
            }
        }
    }

    @MainActor
    func testWindowsKeepIndependentSpacesAndNewTabContext() throws {
        try withStore { store, _ in
            let first = try XCTUnwrap(store.activeWindowState)
            let alpha = store.spaces[0].id, beta = store.spaces[1].id
            store.switchSpace(to: alpha)
            store.newTab(urlString: "https://alpha.example")
            let firstTab = first.selectedTabID
            let second = store.makeWindowState()
            store.activeWindowState = second
            store.switchSpace(to: beta)
            store.newTab(urlString: "https://beta.example")
            let betaTab = second.selectedTabID
            XCTAssertEqual(first.spaceID, alpha)
            XCTAssertEqual(first.selectedTabID, firstTab)
            XCTAssertEqual(second.spaceID, beta)
            store.activeWindowState = first
            XCTAssertEqual(store.currentSpaceID, alpha)
            store.newTab(urlString: "https://new-alpha.example")
            XCTAssertEqual(store.selectedTab?.spaceID, alpha)
            store.switchSpace(to: beta)
            XCTAssertNotEqual(first.selectedTabID, betaTab, "Switching Space stole a tab from another window")
            XCTAssertEqual(second.selectedTabID, betaTab)
            store.activeWindowState = second
            XCTAssertEqual(store.currentSpaceID, beta)
        }
    }

    @MainActor
    func testAddressEditNavigatesFocusedSplitWithoutCollapsingIt() throws {
        try withStore { store, _ in
            store.newTab(urlString: "https://alpha.example")
            let alpha = try XCTUnwrap(store.selectedTabID)
            store.openInSplit("https://beta.example")
            let beta = try XCTUnwrap(store.focusedPaneTabID)
            store.open("https://edited.example", mode: .editCurrent)
            XCTAssertEqual(store.tab(alpha)?.urlString, "https://alpha.example")
            XCTAssertEqual(store.tab(beta)?.urlString, "https://edited.example")
            XCTAssertEqual(store.activeWindowState?.splitTabIDs, [beta])
        }
    }

    @MainActor
    func testFavoriteAndSpaceReorderingKeepLiveCookieIdentity() throws {
        try withStore { store, _ in
            store.switchSpace(to: store.spaces[1].id)
            store.newTab(urlString: "https://account.example")
            let tab = try XCTUnwrap(store.selectedTab)
            let live = store.controller(for: tab)
            store.toggleFavorite(tab)
            let favorite = try XCTUnwrap(store.tab(tab.id))
            XCTAssertEqual(store.profileSpace(for: favorite).dataStoreID, live.dataStoreID)
            XCTAssertTrue(store.controller(for: favorite) === live)
            store.moveSpace(store.spaces[1].id, by: -1)
            XCTAssertEqual(store.profileSpace(for: favorite).dataStoreID, live.dataStoreID)
        }
    }

    @MainActor
    func testTabTransferRevokesPreviousWindowAndOldHostCannotLayoutNewOwner() throws {
        try withStore { store, _ in
            store.newTab(urlString: "https://shared.example")
            let tab = try XCTUnwrap(store.selectedTab)
            let first = try XCTUnwrap(store.activeWindowState)
            let window1 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            let window2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            first.window = window1
            let controller = store.controller(for: tab)
            let host1 = PaneHostView(), host2 = PaneHostView()
            host1.controller = controller; host2.controller = controller
            window1.contentView = host1
            host1.attachIfPossible()
            let second = store.makeWindowState(preferredTabID: tab.id)
            second.window = window2
            window2.contentView = host2
            host2.attachIfPossible()
            XCTAssertNil(first.selectedTabID)
            XCTAssertEqual(second.selectedTabID, tab.id)
            XCTAssertTrue(controller.container.superview === host2)
            host1.frame = .zero
            host1.layout(); host1.attachIfPossible(); host1.detach()
            XCTAssertTrue(controller.container.superview === host2)
            XCTAssertEqual(controller.container.bounds.size, host2.bounds.size)
            XCTAssertGreaterThan(controller.container.bounds.width, 0)
        }
    }

    @MainActor
    func testDownloadIDsAndDestinationsDoNotCollide() throws {
        try withStore { store, root in
            for name in ["one", "two"] {
                store.upsertDownload(fromTab: UUID(), DownloadItemState(id: UUID(), fileName: name,
                    urlString: "https://download.example/\(name)", fullPath: root.appendingPathComponent(name).path,
                    percent: 0, receivedBytes: 0, totalBytes: 100, state: "inProgress"))
            }
            XCTAssertEqual(store.downloads.count, 2)
            let first = store.downloadManager.reserveDestination(folder: root, suggestedFilename: "same.txt")
            let second = store.downloadManager.reserveDestination(folder: root, suggestedFilename: "same.txt")
            XCTAssertNotEqual(first, second)
            let escaped = store.downloadManager.reserveDestination(folder: root, suggestedFilename: "../../outside.txt")
            XCTAssertEqual(escaped.deletingLastPathComponent().path, root.path)
        }
    }

    @MainActor
    func testFirstArchiveOfOldTabRetainsFullRetentionWindow() throws {
        try withStore { store, _ in
            let old = BrowserTab(spaceID: store.currentSpaceID, kind: .today, title: "Old", urlString: "https://old.example",
                                 lastVisitedAt: Date().addingTimeInterval(-31 * 86400))
            store.tabs.append(old)
            store.runAutoArchive()
            let archived = try XCTUnwrap(store.tab(old.id))
            XCTAssertTrue(archived.isArchived)
            XCTAssertLessThan(abs(try XCTUnwrap(archived.archivedAt).timeIntervalSinceNow), 2)
        }
    }

    @MainActor
    func testClearingHistoryReplacesBackupBeforeReportingSuccess() throws {
        try withStore { store, root in
            store.history = [HistoryEntry(title: "Private marker", urlString: "https://private.example")]
            XCTAssertTrue(store.flush())
            store.clearHistory()
            XCTAssertTrue(store.flush())
            for url in [root.appendingPathComponent("state.json"), root.appendingPathComponent("state.json.bak")] {
                let decoded = try XCTUnwrap(StateFile.decode(Data(contentsOf: url)))
                XCTAssertTrue(decoded.history.isEmpty)
            }
        }
    }

    @MainActor
    func testSecondStateWriterCannotOverwriteFirstSnapshot() throws {
        try withStore { first, root in
            XCTAssertTrue(first.flush())
            let second = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
            XCTAssertTrue(second.isReadOnly)
            first.history.append(HistoryEntry(title: "A", urlString: "https://a.example"))
            XCTAssertTrue(first.flush())
            second.spaces[0].name = "Stale writer"
            XCTAssertFalse(second.flush())
            let disk = try XCTUnwrap(StateFile.decode(Data(contentsOf: root.appendingPathComponent("state.json"))))
            XCTAssertEqual(disk.history.count, 1)
            XCTAssertNotEqual(disk.spaces[0].name, "Stale writer")
        }
    }

    func testPermissionsKeepPortAndProfileBoundaries() {
        let a = UUID(), b = UUID()
        let origin = SiteOrigin.make(scheme: "HTTPS", host: "EXAMPLE.COM", port: 8443)
        var permissions: [SitePermission] = []
        permissions.remember(origin: origin, profileID: a, kind: .media, requested: MediaPermission.camera, allow: true)
        XCTAssertEqual(permissions.decision(origin: origin, profileID: a, kind: .media, requested: MediaPermission.camera), .allow)
        XCTAssertEqual(permissions.decision(origin: origin, profileID: b, kind: .media, requested: MediaPermission.camera), .ask)
        XCTAssertEqual(permissions.decision(origin: SiteOrigin.make(scheme: "https", host: "example.com"), profileID: a,
                                            kind: .media, requested: MediaPermission.camera), .ask)
        XCTAssertEqual(SiteOrigin.make(scheme: "http", host: "::1", port: 8080), "http://[::1]:8080")
    }
}
