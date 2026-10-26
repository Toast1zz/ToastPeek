import XCTest
import AppKit
import WebKit

/// Exercises the real engine without constructing or ordering an NSWindow.
@MainActor
final class FaviconHeadlessTests: XCTestCase {
    private var root: URL!
    private var server: Process!
    private var base: String!
    private var views: [WKWebView] = []
    private var probes: [NavigationProbe] = []
    private var stores: [BrowserStore] = []
    private var profileIDs = Set<UUID>()
    private var initiallyVisible = Set<ObjectIdentifier>()

    private final class NavigationProbe: NSObject, WKNavigationDelegate {
        var finished = false
        var error: Error?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.error = error }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { self.error = error }
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        initiallyVisible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-headless-" + UUID().uuidString)
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
        try await waitUntil { FileManager.default.fileExists(atPath: portFile.path) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: portFile)) as? [String: Int])
        base = "http://127.0.0.1:\(try XCTUnwrap(json["port"]))"
    }

    override func tearDown() async throws {
        for store in stores {
            for id in Array(store.controllers.keys) { store.unload(id) }
            store.flush()
        }
        stores = []
        for id in profileIDs {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
            }
        }
        profileIDs = []
        for view in views { view.stopLoading(); view.navigationDelegate = nil }
        views = []; probes = []
        XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), initiallyVisible,
                       "Headless tests must never show a window")
        if server?.isRunning == true { server.terminate() }
        server = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "HeadlessTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func show(_ path: String, dataStore: WKWebsiteDataStore? = nil) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .nonPersistent()
        configuration.userContentController.addUserScript(FaviconLoader.userScript)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let probe = NavigationProbe()
        view.navigationDelegate = probe
        views.append(view); probes.append(probe)
        view.load(URLRequest(url: try XCTUnwrap(URL(string: base + path))))
        try await waitUntil { probe.finished || probe.error != nil }
        if let error = probe.error { throw error }
        XCTAssertNil(view.window)
        return view
    }

    private func requests() throws -> [[String: String]] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
            }
    }

    private func icon(_ path: String, in view: WKWebView) async throws -> Data? {
        await FaviconLoader.fetch(try XCTUnwrap(URL(string: base + path)), in: view)
    }

    func testPageCSPBlocksIconFetch() async throws {
        let view = try await show("/icon-csp-page")
        let data = try await icon("/icon/csp-blocked", in: view)
        XCTAssertNil(data, "Favicon requests must respect the document connect-src")
        XCTAssertFalse(try requests().contains { $0["path"] == "/icon/csp-blocked" })
    }

    func testOwningCookiesAndPageOverridesWithoutWindows() async throws {
        let a = try await show("/page")
        _ = try await a.evaluateJavaScript("document.cookie='identity=alpha;path=/';window.fetch=()=>Promise.reject('override');window.btoa=()=>'';true")
        let red = try await icon("/icon/authenticated", in: a)
        let b = try await show("/page")
        let blue = try await icon("/icon/authenticated", in: b)
        XCTAssertNotNil(red); XCTAssertNotNil(blue)
        XCTAssertNotEqual(red, blue)
        let hits = try requests().filter { $0["path"] == "/icon/authenticated" }
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.first?["cookie"]?.contains("identity=alpha") == true)
        XCTAssertFalse(hits.last?["cookie"]?.contains("identity=alpha") == true)
    }

    func testContentRuleBlocksActualNetworkRequestWithoutWindows() async throws {
        let view = try await show("/page")
        let identifier = "headless-icon-" + UUID().uuidString
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier,
                encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\"/icon/blocked\",\"resource-type\":[\"raw\"]},\"action\":{\"type\":\"block\"}}]") { list, error in
                    if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "HeadlessRule", code: 1)) }
                }
        }
        view.configuration.userContentController.add(list)
        defer { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in } }
        let data = try await icon("/icon/blocked", in: view)
        XCTAssertNil(data)
        XCTAssertFalse(try requests().contains { $0["path"] == "/icon/blocked" })
    }

    func testCrossOriginAndRedirectMakeNoDestinationRequest() async throws {
        let view = try await show("/page")
        let target = try XCTUnwrap(URL(string: base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/icon/cross-origin"))
        let direct = await FaviconLoader.fetch(target, in: view)
        let redirect = try await icon("/icon/redirect", in: view)
        XCTAssertNil(direct); XCTAssertNil(redirect)
        let paths = try requests().compactMap { $0["path"] }
        XCTAssertTrue(paths.contains("/icon/redirect"))
        XCTAssertFalse(paths.contains("/icon/redirect-target"))
        XCTAssertFalse(paths.contains("/icon/cross-origin"))
    }

    func testResponseByteLimitIncludesExactBoundary() async throws {
        let view = try await show("/page")
        let valid = try await icon("/icon/exact-size", in: view)
        let oversized = try await icon("/icon/oversized", in: view)
        XCTAssertEqual(valid?.count, 524288)
        XCTAssertNil(oversized)
    }

    func testNativeDeadlineSurvivesPageTimerOverrides() async throws {
        let view = try await show("/page")
        _ = try await view.evaluateJavaScript("window.setTimeout=()=>0;AbortController.prototype.abort=()=>{};true")
        let start = ProcessInfo.processInfo.systemUptime
        let data = try await icon("/icon/stalled", in: view)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertNil(data)
        XCTAssertGreaterThanOrEqual(elapsed, 5)
        XCTAssertLessThan(elapsed, 11)
    }

    private func loadedController(_ path: String) async throws -> (BrowserStore, WebTabController, FaviconSlot) {
        let stateURL = root.appendingPathComponent("controller/state.json")
        let store = BrowserStore(stateURL: stateURL)
        store.spaces = [BrowserSpace(name: "Icon owner", icon: "house", colorHex: "#7C6FF0"),
                        BrowserSpace(name: "Surviving profile", icon: "house", colorHex: "#7C6FF0")]
        store.currentSpaceID = store.spaces[0].id
        profileIDs.formUnion(store.spaces.map(\.dataStoreID))
        stores.append(store)
        var tab = BrowserTab(spaceID: store.currentSpaceID, kind: .today, title: "Fixture", urlString: base + path)
        tab.profileID = store.currentSpace.dataStoreID
        store.tabs = [tab]
        let controller = store.controller(for: tab)
        controller.ensureBrowser()
        let key = try XCTUnwrap(store.faviconKey(for: tab))
        let slot = store.faviconStore.slot(for: key)
        try await waitUntil { slot.image != nil }
        XCTAssertNil(controller.container.window)
        XCTAssertNil(controller.webView?.window)
        return (store, controller, slot)
    }

    func testControllerFallbackRunsWithoutMountingAWindow() async throws {
        _ = try await loadedController("/favicon-page")
        let paths = try requests().compactMap { $0["path"] }
        XCTAssertTrue(paths.contains("/icon/invalid"))
        XCTAssertTrue(paths.contains("/favicon.ico"))
    }

    func testDeletingSpaceWaitsForItsIconFilesToBeRemoved() async throws {
        let (store, _, slot) = try await loadedController("/page")
        let profile = store.currentSpace
        store.deleteSpace(profile.id)
        try await waitUntil { store.pendingDataStoreDeletions.isEmpty }
        XCTAssertNil(slot.image)
        let icons = root.appendingPathComponent("controller/Favicons")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: icons.path).contains { $0.hasPrefix(profile.dataStoreID.uuidString + ".") })
        XCTAssertTrue(store.flush())
        let saved = try XCTUnwrap(StateFile.decode(Data(contentsOf: store.dataFileURL)))
        XCTAssertTrue(saved.pendingDataStoreDeletions?.isEmpty == true)
    }

    func testClearingBrowsingDataClearsIconsAndRejectsLateResults() async throws {
        let (store, _, slot) = try await loadedController("/page")
        let key = try XCTUnwrap(slot.key), generation = store.faviconStore.generation
        let data = try XCTUnwrap(slot.image?.tiffRepresentation)
        store.clearBrowsingData()
        try await waitUntil { !store.isClearingData }
        XCTAssertNil(slot.image)
        XCTAssertFalse(store.faviconStore.store(data, for: key, generation: generation))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("controller/Favicons").path).isEmpty)
        for name in ["state.json", "state.json.bak"] {
            let saved = try XCTUnwrap(StateFile.decode(Data(contentsOf: root.appendingPathComponent("controller/" + name))))
            XCTAssertTrue(saved.history.isEmpty)
        }
    }
}
