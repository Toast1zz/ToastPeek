import XCTest
import AppKit
import WebKit

/// Uses only temporary state and fresh WebKit profiles. Real NSWindow containers
/// host WebKit, while an injected key-window environment routes test commands.
@MainActor
final class WindowCommandRegressionTests: XCTestCase {
    private var root: URL!
    private var store: BrowserStore!
    private var stores: [BrowserStore] = []
    private var windows: [NSWindow] = []
    private var profileIDs = Set<UUID>()
    private weak var testWindow: NSWindow?

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-window-commands-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BrowserStore(stateURL: root.appendingPathComponent("state.json"),
                             keyWindowProvider: { [weak self] in self?.testWindow })
        stores = [store]
        store.tabs = []
        store.spaces = [BrowserSpace(name: "Window fixture", icon: "house", colorHex: "#7C6FF0")]
        store.currentSpaceID = store.spaces[0].id
        store.showOnboarding = false
    }

    override func tearDown() async throws {
        for instance in stores {
            await withCheckedContinuation { continuation in
                instance.downloadManager.cancelAll(keepingResumeData: false) { continuation.resume() }
            }
            for id in Array(instance.peekTabs.keys) { instance.discardPeekTab(id) }
            for id in Array(instance.controllers.keys) { instance.unload(id) }
            for state in instance.windowStates { instance.removeWindowState(state) }
            _ = instance.flush()
        }
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows = []
        testWindow = nil
        store = nil
        stores = []
        for profileID in profileIDs {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: profileID) { _ in continuation.resume() }
            }
        }
        profileIDs = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 10, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                throw NSError(domain: "WindowCommandRegression", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: label])
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeWindow() -> NSWindow {
        // Keep fixture windows off the user's desktop and never activate NSApp.
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    private func makeBrowserWindow() -> (WindowTabState, WebTabController, NSWindow) {
        let tab = BrowserTab(spaceID: store.currentSpaceID, kind: .today, title: "Window fixture", urlString: "about:blank")
        store.tabs.append(tab)
        let state = store.makeWindowState(preferredTabID: tab.id)
        let window = makeWindow()
        state.window = window
        let controller = store.controller(for: tab)
        window.contentView = controller.container
        return (state, controller, window)
    }

    private func makePeek() -> (BrowserPageState, WebTabController, NSWindow) {
        let tab = BrowserTab(spaceID: store.currentSpaceID, kind: .today, title: "Peek fixture", urlString: "about:blank")
        let state = BrowserPageState()
        let window = makeWindow()
        state.window = window
        store.registerPeekTab(tab, pageState: state)
        let controller = store.controller(for: tab)
        window.contentView = controller.container
        return (state, controller, window)
    }

    private func makeKey(_ window: NSWindow) {
        testWindow = window
    }

    private func loadHTML(_ controller: WebTabController, text: String) async throws {
        profileIDs.insert(store.spaces[0].dataStoreID)
        controller.ensureBrowser(startNavigation: false)
        let view = try XCTUnwrap(controller.webView)
        view.loadHTMLString("<!doctype html><html><body><p>\(text)</p></body></html>", baseURL: nil)
        try await waitUntil("fixture HTML did not finish loading") { controller.hasCommittedPage && !view.isLoading }
        let actual = try await view.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertEqual(actual?.trimmingCharacters(in: .whitespacesAndNewlines), text)
    }

    func testAddressCommandTargetsOnlyKeyPeekAndNeverBackgroundWindows() async throws {
        let (firstWindowState, _, browserWindow) = makeBrowserWindow()
        let (secondWindowState, _, secondBrowserWindow) = makeBrowserWindow()
        let (first, firstController, firstWindow) = makePeek()
        let (second, _, secondWindow) = makePeek()
        store.activeWindowState = firstWindowState

        makeKey(firstWindow)
        XCTAssertTrue(store.focusPeekAddress())
        XCTAssertEqual(first.addressFocusRequest, 1)
        XCTAssertEqual(second.addressFocusRequest, 0)
        XCTAssertEqual(firstWindowState.pageState.addressFocusRequest, 0)
        XCTAssertEqual(secondWindowState.pageState.addressFocusRequest, 0)

        makeKey(secondWindow)
        XCTAssertTrue(store.focusPeekAddress())
        XCTAssertEqual(first.addressFocusRequest, 1)
        XCTAssertEqual(second.addressFocusRequest, 1)

        makeKey(browserWindow)
        XCTAssertFalse(store.focusPeekAddress())
        makeKey(secondBrowserWindow)
        XCTAssertFalse(store.focusPeekAddress())
        XCTAssertEqual(first.addressFocusRequest, 1)
        XCTAssertEqual(second.addressFocusRequest, 1)

        // An unregistered/closed Peek must stop receiving key-window commands.
        makeKey(firstWindow)
        store.discardPeekTab(firstController.tabID)
        XCTAssertFalse(store.focusPeekAddress())
        XCTAssertEqual(first.addressFocusRequest, 1)
    }

    func testTwoWindowsAndTwoPeeksKeepFindRoutingAndLateResultsSeparate() async throws {
        let (windowA, controllerA, nativeA) = makeBrowserWindow()
        let (windowB, controllerB, nativeB) = makeBrowserWindow()
        let (peekA, peekControllerA, nativePeekA) = makePeek()
        let (peekB, peekControllerB, nativePeekB) = makePeek()
        let fixtures: [(BrowserPageState, UUID, String)] = [
            (windowA.pageState, controllerA.tabID, "alpha"),
            (windowB.pageState, controllerB.tabID, "beta"),
            (peekA, peekControllerA.tabID, "gamma"),
            (peekB, peekControllerB.tabID, "delta")
        ]
        store.activeWindowState = windowA
        makeKey(nativeA)
        windowA.pageState.findText = "alpha"
        store.showFindBar()
        XCTAssertTrue(store.commandPageState === windowA.pageState)
        XCTAssertFalse(windowB.pageState.isFindBarVisible)
        XCTAssertFalse(peekA.isFindBarVisible)

        store.activeWindowState = windowB
        makeKey(nativeB)
        windowB.pageState.findText = "beta"
        store.showFindBar()
        XCTAssertTrue(store.commandPageState === windowB.pageState)
        makeKey(nativePeekA)
        peekA.findText = "gamma"
        store.showFindBar()
        XCTAssertTrue(store.commandPageState === peekA)
        XCTAssertEqual(peekA.findTabID, peekControllerA.tabID)
        makeKey(nativePeekB)
        peekB.findText = "delta"
        store.showFindBar()
        XCTAssertTrue(store.commandPageState === peekB)
        XCTAssertEqual(peekB.findTabID, peekControllerB.tabID)

        // Inject results after focus moved to another window. Each source must
        // update its owner, independent of whichever controller is active now.
        for (index, fixture) in fixtures.enumerated() {
            store.updateFindResult(tabID: fixture.1, count: index + 2, activeOrdinal: 1)
        }
        for (index, fixture) in fixtures.enumerated() {
            XCTAssertTrue(fixture.0.isFindBarVisible)
            XCTAssertEqual(fixture.0.findText, fixture.2)
            XCTAssertEqual(fixture.0.findMatchCount, index + 2)
            XCTAssertEqual(fixture.0.findFocusRequest, 1)
        }
        store.hideFindBar() // Escape in the key Peek affects that Peek alone.
        XCTAssertFalse(peekB.isFindBarVisible)
        XCTAssertNil(peekB.findTabID)
        store.updateFindResult(tabID: peekControllerB.tabID, count: 999, activeOrdinal: 999)
        XCTAssertEqual(peekB.findMatchCount, 0)
        XCTAssertTrue(peekA.isFindBarVisible)
        XCTAssertEqual(windowA.pageState.findMatchCount, 2)
        XCTAssertEqual(windowB.pageState.findMatchCount, 3)

        store.discardPeekTab(peekControllerA.tabID)
        store.updateFindResult(tabID: peekControllerA.tabID, count: 999, activeOrdinal: 999)
        XCTAssertFalse(peekA.isFindBarVisible)
        XCTAssertNil(peekA.findTabID)
        XCTAssertEqual(peekA.findMatchCount, 0)
        XCTAssertEqual(windowB.pageState.findMatchCount, 3)

        store.hideFindBar(in: windowA.pageState)
        store.updateFindResult(tabID: controllerA.tabID, count: 999, activeOrdinal: 999)
        XCTAssertEqual(windowA.pageState.findMatchCount, 0)
        XCTAssertEqual(windowB.pageState.findMatchCount, 3)
    }

    func testRealWebKitFindResultsReachBackgroundWindowAndPeekOwners() async throws {
        let (windowA, controllerA, nativeA) = makeBrowserWindow()
        let (windowB, controllerB, nativeB) = makeBrowserWindow()
        let (peekA, peekControllerA, nativePeekA) = makePeek()
        let (peekB, peekControllerB, nativePeekB) = makePeek()
        try await loadHTML(controllerA, text: "alpha alpha alpha")
        try await loadHTML(controllerB, text: "beta beta")
        try await loadHTML(peekControllerA, text: "gamma gamma gamma gamma")
        try await loadHTML(peekControllerB, text: "delta delta delta delta delta")
        let fixtures: [(BrowserPageState, WebTabController, String)] = [
            (windowA.pageState, controllerA, "alpha"),
            (windowB.pageState, controllerB, "beta"),
            (peekA, peekControllerA, "gamma"),
            (peekB, peekControllerB, "delta")
        ]
        for fixture in fixtures {
            fixture.0.isFindBarVisible = true
            fixture.0.findText = fixture.2
        }
        store.activeWindowState = windowA
        makeKey(nativeA)
        store.performFind(in: windowA.pageState, tabID: controllerA.tabID)
        // Switch synchronously, before either asynchronous WebKit find callback.
        store.activeWindowState = windowB
        makeKey(nativeB)
        store.performFind(in: windowB.pageState, tabID: controllerB.tabID)
        makeKey(nativePeekA)
        store.performFind(in: peekA, tabID: peekControllerA.tabID)
        makeKey(nativePeekB)
        store.performFind(in: peekB, tabID: peekControllerB.tabID)
        try await waitUntil("background find results were lost or routed to the foreground page") {
            fixtures.allSatisfy { $0.0.findMatchCount == -1 && $0.0.findActiveOrdinal == 0 }
        }
        store.findNext(in: windowA.pageState, forward: true)
        store.findNext(in: peekA, forward: false)
        // Navigation does not invent an ordinal when WebKit cannot report one.
        XCTAssertEqual(windowA.pageState.findMatchCount, -1)
        XCTAssertEqual(peekA.findMatchCount, -1)
        XCTAssertEqual(windowB.pageState.findActiveOrdinal, 0)
        XCTAssertEqual(peekB.findActiveOrdinal, 0)
    }

    func testRealFindGenerationRejectsSupersededQueryAndHiddenOrClosedPeek() async throws {
        let (window, controller, native) = makeBrowserWindow()
        let (peek, peekController, peekWindow) = makePeek()
        try await loadHTML(controller, text: "current current")
        try await loadHTML(peekController, text: "peek peek peek")
        store.activeWindowState = window
        makeKey(native)
        window.pageState.isFindBarVisible = true
        window.pageState.findText = "old"
        store.performFind(in: window.pageState, tabID: controller.tabID)
        window.pageState.findText = "current"
        store.performFind(in: window.pageState, tabID: controller.tabID)
        try await waitUntil("superseded find query overwrote the current result") { window.pageState.findMatchCount == -1 }
        XCTAssertEqual(window.pageState.findActiveOrdinal, 0)

        makeKey(peekWindow)
        peek.findText = "peek"
        store.showFindBar()
        store.hideFindBar(in: peek) // Invalidate the outstanding WebKit operation.
        // A JS round trip gives the outstanding WebKit operation time to complete.
        _ = try await XCTUnwrap(peekController.webView).evaluateJavaScript("document.body.innerText")
        XCTAssertFalse(peek.isFindBarVisible)
        XCTAssertEqual(peek.findMatchCount, 0)
        XCTAssertEqual(window.pageState.findMatchCount, -1)
        peek.isFindBarVisible = true
        store.performFind(in: peek, tabID: peekController.tabID)
        store.discardPeekTab(peekController.tabID)
        await Task.yield()
        store.updateFindResult(tabID: peekController.tabID, count: 3, activeOrdinal: 1)
        XCTAssertNil(store.controller(forTabID: peekController.tabID))
        XCTAssertFalse(peek.isFindBarVisible)
        XCTAssertEqual(peek.findMatchCount, 0)
        XCTAssertEqual(window.pageState.findMatchCount, -1)
    }

    func testAbortedOrCancelledMediaPromptDoesNotCreateOrOverwritePersistedPermission() throws {
        let profile = store.spaces[0].dataStoreID
        let origin = "https://permission.fixture:443"
        XCTAssertTrue(store.resolveMediaPermission(origin: origin, profileID: profile,
            requested: MediaPermission.microphone, response: .alertFirstButtonReturn, remember: true))
        XCTAssertTrue(store.flush())
        let baseline = store.sitePermissions
        for response in [NSApplication.ModalResponse.abort, .cancel, .stop, .alertThirdButtonReturn] {
            XCTAssertFalse(store.resolveMediaPermission(origin: origin, profileID: profile,
                requested: MediaPermission.camera, response: response, remember: true))
            XCTAssertFalse(store.resolveMediaPermission(origin: "https://new.fixture:443", profileID: profile,
                requested: MediaPermission.microphone, response: response, remember: true))
            XCTAssertEqual(store.sitePermissions, baseline)
            XCTAssertTrue(store.flush())
            let saved = try XCTUnwrap(StateFile.decode(Data(contentsOf: store.dataFileURL)))
            XCTAssertEqual(saved.sitePermissions, baseline)
        }
        XCTAssertEqual(store.sitePermissions.decision(origin: origin, profileID: profile,
            kind: .media, requested: MediaPermission.microphone), .allow)
        XCTAssertEqual(store.sitePermissions.decision(origin: origin, profileID: profile,
            kind: .media, requested: MediaPermission.camera), .ask)
    }

    func testExplicitMediaChoicesPersistOnlyWhenRememberedAndStayProfileScoped() throws {
        let profile = store.spaces[0].dataStoreID
        let otherProfile = UUID()
        let origin = "https://permission.fixture:443"
        XCTAssertTrue(store.resolveMediaPermission(origin: origin, profileID: profile,
            requested: MediaPermission.camera, response: .alertFirstButtonReturn, remember: false))
        XCTAssertFalse(store.resolveMediaPermission(origin: origin, profileID: profile,
            requested: MediaPermission.microphone, response: .alertSecondButtonReturn, remember: false))
        XCTAssertTrue(store.sitePermissions.isEmpty)
        XCTAssertTrue(store.resolveMediaPermission(origin: origin, profileID: profile,
            requested: MediaPermission.camera, response: .alertFirstButtonReturn, remember: true))
        XCTAssertFalse(store.resolveMediaPermission(origin: origin, profileID: profile,
            requested: MediaPermission.microphone, response: .alertSecondButtonReturn, remember: true))
        XCTAssertTrue(store.resolveMediaPermission(origin: origin, profileID: otherProfile,
            requested: MediaPermission.microphone, response: .alertFirstButtonReturn, remember: true))
        XCTAssertTrue(store.flush())
        let saved = try XCTUnwrap(StateFile.decode(Data(contentsOf: store.dataFileURL)))
        let permissions = try XCTUnwrap(saved.sitePermissions)
        XCTAssertEqual(permissions.decision(origin: origin, profileID: profile,
            kind: .media, requested: MediaPermission.camera), .allow)
        XCTAssertEqual(permissions.decision(origin: origin, profileID: profile,
            kind: .media, requested: MediaPermission.microphone), .deny)
        XCTAssertEqual(permissions.decision(origin: origin, profileID: otherProfile,
            kind: .media, requested: MediaPermission.microphone), .allow)
    }

    func testLeaseDeniedInstanceCannotCreateBrowserOrMutateSharedProfileCookies() async throws {
        let profile = store.spaces[0].dataStoreID
        let tab = BrowserTab(spaceID: store.currentSpaceID, kind: .today,
                             title: "Locked fixture", urlString: "https://locked.fixture/")
        store.tabs = [tab]
        try await loadHTML(store.controller(for: tab), text: "Cookie fixture")
        XCTAssertTrue(store.flush())
        let stateBefore = try Data(contentsOf: store.dataFileURL)
        let dataStore = WKWebsiteDataStore(forIdentifier: profile)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "locked.fixture", .path: "/", .name: "original_identity", .value: "keep",
            .expires: Date().addingTimeInterval(3600)
        ]))
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
        let before = await dataStore.httpCookieStore.allCookies()
        XCTAssertTrue(before.contains { $0.name == "original_identity" && $0.value == "keep" })
        let secondary = BrowserStore(stateURL: store.dataFileURL)
        stores.append(secondary)
        XCTAssertTrue(secondary.isReadOnly)
        XCTAssertFalse(secondary.canLoadWebContent)
        XCTAssertEqual(secondary.spaces[0].dataStoreID, profile)
        let loadedTab = try XCTUnwrap(secondary.tab(tab.id))
        let controller = secondary.controller(for: loadedTab)
        controller.ensureBrowser()
        controller.ensureBrowser(startNavigation: false)
        controller.load("https://locked.fixture/would-write-data")
        controller.reload()
        XCTAssertNil(controller.webView)
        XCTAssertTrue(controller.container.subviews.isEmpty)
        // Also exercise the child/popup configuration entry, which can otherwise
        // bypass the ordinary lazy-browser path.
        let childConfiguration = WKWebViewConfiguration()
        childConfiguration.websiteDataStore = dataStore
        let child = secondary.createChildWebView(from: tab.id, urlString: "about:blank",
                                                 configuration: childConfiguration, background: true)
        XCTAssertNil(child)
        XCTAssertTrue(secondary.controllers.values.allSatisfy { $0.webView == nil })
        XCTAssertFalse(secondary.resolveMediaPermission(origin: "https://locked.fixture:443", profileID: profile,
            requested: MediaPermission.camera, response: .alertSecondButtonReturn, remember: true))
        XCTAssertTrue(secondary.sitePermissions.isEmpty)
        XCTAssertFalse(secondary.flush())
        let after = await dataStore.httpCookieStore.allCookies()
        XCTAssertEqual(cookieSignatures(after), cookieSignatures(before))
        XCTAssertEqual(try Data(contentsOf: store.dataFileURL), stateBefore)
    }

    private func cookieSignatures(_ cookies: [HTTPCookie]) -> [String] {
        cookies.map { "\($0.domain)|\($0.path)|\($0.name)|\($0.value)" }.sorted()
    }
}
