import XCTest
import AppKit
import WebKit

@MainActor
final class FindFrameRegressionTests: XCTestCase {
    private var root: URL?
    private var store: BrowserStore?
    private var tabID: UUID?
    private var state: WindowTabState?
    private var window: NSWindow?
    private var profileID: UUID?

    override func tearDown() async throws {
        if let store {
            await withCheckedContinuation { continuation in
                store.downloadManager.cancelAll(keepingResumeData: false) { continuation.resume() }
            }
            if let tabID { store.unload(tabID) }
            if let state { store.removeWindowState(state) }
            _ = store.flush()
        }
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        state = nil
        window = nil
        store = nil
        if let profileID {
            await withCheckedContinuation { continuation in
                WKWebsiteDataStore.remove(forIdentifier: profileID) { _ in continuation.resume() }
            }
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNativeFrameMatchRemainsNavigableWithUnknownCount() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-find-frame-\(UUID())")
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        self.store = store
        store.tabs = []
        store.spaces = [BrowserSpace(name: "Find fixture", icon: "house", colorHex: "#7C6FF0")]
        store.currentSpaceID = store.spaces[0].id
        let profileID = store.spaces[0].dataStoreID
        self.profileID = profileID
        store.showOnboarding = false
        let tab = BrowserTab(spaceID: store.currentSpaceID, kind: .today, title: "Find fixture", urlString: "about:blank")
        store.tabs.append(tab)
        self.tabID = tab.id
        let state = store.makeWindowState(preferredTabID: tab.id)
        self.state = state
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.window = window
        state.window = window
        let controller = store.controller(for: tab)
        window.contentView = controller.container
        controller.ensureBrowser(startNavigation: false)
        let view = try XCTUnwrap(controller.webView)
        view.loadHTMLString("<html><body><iframe srcdoc='<p>UniqueNeedle UniqueNeedle</p>'></iframe></body></html>", baseURL: nil)

        func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate() {
                if Date() >= deadline {
                    throw NSError(domain: "FindFrameRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await waitUntil("Page did not load") { controller.hasCommittedPage && !view.isLoading }
        let frameText = try await view.evaluateJavaScript("document.querySelector('iframe').contentDocument.body.innerText") as? String
        XCTAssertEqual(frameText?.trimmingCharacters(in: .whitespacesAndNewlines), "UniqueNeedle UniqueNeedle")
        state.pageState.isFindBarVisible = true
        state.pageState.findText = "UniqueNeedle"
        store.performFind(in: state.pageState, tabID: tab.id)
        try await waitUntil("Frame match was not reported") { state.pageState.findMatchCount == -1 }
        XCTAssertEqual(state.pageState.findActiveOrdinal, 0)
        for forward in [true, false] {
            state.pageState.findMatchCount = 0
            store.findNext(in: state.pageState, forward: forward)
            try await waitUntil("Frame match could not be navigated") { state.pageState.findMatchCount == -1 }
        }
        state.pageState.findText = "NotInEitherFrame"
        store.performFind(in: state.pageState, tabID: tab.id)
        state.pageState.findMatchCount = -1
        try await waitUntil("Missing text was not reported") { state.pageState.findMatchCount == 0 }

    }
}
