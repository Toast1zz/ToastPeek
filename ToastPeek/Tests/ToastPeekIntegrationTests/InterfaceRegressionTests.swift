import XCTest
import AppKit
import Combine

final class InterfaceRegressionTests: XCTestCase {
    @MainActor
    func testAllThemeSelectionsMeetBodyTextContrast() {
        for hex in SpaceEditorView.palette {
            XCTAssertGreaterThanOrEqual(ThemeContrast.selectedContrast(hex: hex), 4.5, hex)
        }
        // Exercise the threshold and arbitrary custom colors, not just today's palette.
        for value in stride(from: 0, through: 0xFFFFFF, by: 7919) {
            let hex = String(format: "%06X", value)
            XCTAssertGreaterThanOrEqual(ThemeContrast.selectedContrast(hex: hex), 4.5, hex)
        }
        XCTAssertTrue(ThemeContrast.usesDarkForeground(hex: "#E0B43A"))
        XCTAssertFalse(ThemeContrast.usesDarkForeground(hex: "#000000"))
    }

    @MainActor
    func testConflictChecksResponderCommandsHiddenTabsAndAbsentSpaces() {
        _ = NSApplication.shared
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let menu = NSMenu(title: "Fixture")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Redo", action: #selector(InterfaceMenuFixture.redo(_:)), keyEquivalent: "Z")
        let hidden = NSMenuItem(title: "Last Tab", action: #selector(InterfaceMenuFixture.menuSelectTabIndex(_:)), keyEquivalent: "9")
        hidden.isHidden = true
        hidden.allowsKeyEquivalentWhenHidden = true
        menu.addItem(hidden)
        NSApp.mainMenu = menu
        let shortcuts = ShortcutStore.shared
        for key in ["c", "9"] {
            XCTAssertNotNil(shortcuts.conflict(.init(key: key, mods: NSEvent.ModifierFlags.command.rawValue), excluding: "menuCloseTab"))
        }
        XCTAssertNotNil(shortcuts.conflict(.init(key: "z", mods: NSEvent.ModifierFlags([.command, .shift]).rawValue), excluding: "menuCloseTab"))
        for n in 1...9 {
            XCTAssertNotNil(shortcuts.conflict(.init(key: "\(n)", mods: NSEvent.ModifierFlags.control.rawValue), excluding: "menuCloseTab"))
        }
        XCTAssertNil(shortcuts.conflict(.init(key: "k", mods: NSEvent.ModifierFlags.command.rawValue), excluding: "menuCloseTab"))
        XCTAssertEqual(ShortcutStore.display(action: "copy:"), "⌘C")
        XCTAssertEqual(ShortcutStore.display(action: "redo:"), "⇧⌘Z")
        menu.items[0].keyEquivalent = ""
        XCTAssertEqual(ShortcutStore.display(action: "copy:"), "")
    }

    @MainActor
    func testSuggestionFailureClearsPreviouslyActionableResults() async {
        let source = SuggestionTransport()
        let suggestions = SearchSuggestions(debounceNanoseconds: 0, transport: { try await source.request($0) })
        let alphaRequested = expectation(description: "alpha requested")
        await source.observe("alpha", expectation: alphaRequested)
        suggestions.update(query: "alpha", engine: .google, enabled: true)
        await fulfillment(of: [alphaRequested], timeout: 2)
        let alphaPublished = expectation(description: "alpha published")
        let subscription = suggestions.$items.sink { if $0 == ["alpha result"] { alphaPublished.fulfill() } }
        await source.complete("alpha", result: .success(payload("alpha", ["alpha result"])))
        await fulfillment(of: [alphaPublished], timeout: 2)
        XCTAssertEqual(suggestions.items(for: "alpha"), ["alpha result"])
        XCTAssertEqual(suggestions.items(for: "beta"), [])
        let betaRequested = expectation(description: "beta requested")
        await source.observe("beta", expectation: betaRequested)
        suggestions.update(query: "beta", engine: .google, enabled: true)
        XCTAssertEqual(suggestions.items, [], "Old suggestions remained clickable during a new request")
        await fulfillment(of: [betaRequested], timeout: 2)
        await source.complete("beta", result: .failure(URLError(.notConnectedToInternet)))
        XCTAssertEqual(suggestions.items, [])
        suggestions.cancel()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testLateTransportCannotReplaceNewQueryOrDisabledResults() async {
        let source = SuggestionTransport()
        let suggestions = SearchSuggestions(debounceNanoseconds: 0, transport: { try await source.request($0) })
        let alpha = expectation(description: "alpha requested")
        let beta = expectation(description: "beta requested")
        await source.observe("alpha", expectation: alpha)
        await source.observe("beta", expectation: beta)
        suggestions.update(query: "alpha", engine: .google, enabled: true)
        await fulfillment(of: [alpha], timeout: 2)
        suggestions.update(query: "beta", engine: .google, enabled: true)
        await fulfillment(of: [beta], timeout: 2)
        let betaPublished = expectation(description: "beta published")
        let stalePublished = expectation(description: "stale alpha was published")
        stalePublished.isInverted = true
        let subscription = suggestions.$items.sink {
            if $0 == ["beta result"] { betaPublished.fulfill() }
            if $0 == ["alpha result"] { stalePublished.fulfill() }
        }
        await source.complete("beta", result: .success(payload("beta", ["beta result"])))
        await fulfillment(of: [betaPublished], timeout: 2)
        await source.complete("alpha", result: .success(payload("alpha", ["alpha result"])))
        await fulfillment(of: [stalePublished], timeout: 0.1)
        XCTAssertEqual(suggestions.items(for: "beta"), ["beta result"])
        suggestions.update(query: "beta", engine: .google, enabled: false)
        XCTAssertTrue(suggestions.items.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func testMediaIndexCachesBatchAndExpiresMissingFiles() async throws {
        let probes = LockedProbes()
        let index = MediaFileIndex(lifetime: 15, probe: { probes.probe($0) })
        let now = Date()
        let paths = (0..<1000).map { "fixture-\($0)" }
        let first = try await index.existingPaths(paths, now: now)
        XCTAssertEqual(first.count, 500)
        XCTAssertEqual(probes.count, 1000)
        _ = try await index.existingPaths(paths, now: now.addingTimeInterval(1))
        XCTAssertEqual(probes.count, 1000, "A redraw rescanned every file")
        _ = try await index.existingPaths(paths, now: now.addingTimeInterval(16))
        XCTAssertEqual(probes.count, 2000, "Missing paths were cached forever")
    }

    func testCancelledMediaScanStopsBeforeProbing() async throws {
        let probes = LockedProbes()
        let index = MediaFileIndex(probe: { probes.probe($0) })
        let scan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.existingPaths(["fixture-0", "fixture-1"])
        }
        do {
            _ = try await scan.value
            XCTFail("Cancelled scan completed")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probes.count, 0)
    }

    private func payload(_ query: String, _ suggestions: [String]) -> Data {
        try! JSONSerialization.data(withJSONObject: [query, suggestions])
    }
}

@MainActor
private final class InterfaceMenuFixture: NSObject {
    @objc func redo(_ sender: Any?) {}
    @objc func menuSelectTabIndex(_ sender: NSMenuItem) {}
}

/// Deliberately ignores cancellation, reproducing a transport completion racing
/// with a newer query. Each test explicitly releases every pending request.
private actor SuggestionTransport {
    private var pending: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var notices: [String: XCTestExpectation] = [:]
    func observe(_ query: String, expectation: XCTestExpectation) { notices[query] = expectation }
    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }!.value!
        return try await withCheckedThrowingContinuation { continuation in
            pending[query] = continuation
            notices.removeValue(forKey: query)?.fulfill()
        }
    }
    func complete(_ query: String, result: Result<Data, Error>) {
        let continuation = pending.removeValue(forKey: query)!
        continuation.resume(with: result.map { data in
            (data, HTTPURLResponse(url: URL(string: "https://suggest.example")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
}

private final class LockedProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func probe(_ path: String) -> Bool {
        XCTAssertFalse(Thread.isMainThread, "Media filesystem probe ran on the main thread")
        lock.lock(); calls += 1; lock.unlock()
        return Int(path.split(separator: "-").last!)! % 2 == 0
    }
}
