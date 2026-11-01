import XCTest
import AppKit
import SwiftUI

final class WindowLayoutRegressionTests: XCTestCase {
    @MainActor
    func testCommandBarFitsMinimumBrowserWindowAfterOuterPadding() async throws {
        try await withStore { store in
            // The 640pt browser window gives the command bar 600pt after the
            // ContentView overlay's 20pt horizontal inset on each side.
            try await assertCommandBarFrame(viewportWidth: 640, store: store)
        }
    }

    @MainActor
    func testCommandBarCompressesInNarrowViewportsAndCapsAt660() async throws {
        try await withStore { store in
            for width: CGFloat in [320, 420, 800, 1440] {
                try await assertCommandBarFrame(viewportWidth: width, store: store)
            }
        }
    }

    @MainActor
    private func assertCommandBarFrame(viewportWidth: CGFloat, store: BrowserStore,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let viewport = NSRect(x: 0, y: 0, width: viewportWidth, height: 500)
        let capture = LayoutFrameCapture()
        let measured = expectation(description: "Command bar laid out in \(viewportWidth)pt viewport")
        let fixture = CommandBarLayoutFixture { frame in
            capture.frame = frame
            if frame.width > 0, frame.height > 0, !capture.fulfilled {
                capture.fulfilled = true
                measured.fulfill()
            }
        }
        .environmentObject(store)
        .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: fixture)
        // Let this test control the viewport rather than allowing the hosting
        // view's preferred content size to grow the window to fit a bad child.
        host.sizingOptions = []
        host.frame = viewport
        let window = NSWindow(contentRect: viewport, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(viewport.size)
        defer {
            host.removeFromSuperview()
            window.close()
        }
        // The window is never ordered front, made key, or used to activate the
        // application. It only supplies AppKit's real hosting/layout lifecycle.
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [measured], timeout: 3)
        // Flush a subsequent layout pass after SwiftUI's preference delivery,
        // including the CommandBar's onAppear/focus-state invalidation.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                host.layoutSubtreeIfNeeded()
                continuation.resume()
            }
        }
        let frame = try XCTUnwrap(capture.frame, "Geometry preference was not delivered", file: file, line: line)
        let availableWidth = viewportWidth - 40
        let expectedWidth = min(660, availableWidth)
        XCTAssertEqual(host.bounds.width, viewportWidth, accuracy: 0.5, "Fixture viewport grew to accommodate overflow", file: file, line: line)
        XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.5, "Command bar did not accept the available parent width", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, 20 - 0.5, "Command bar crossed the leading inset", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, viewportWidth - 20 + 0.5, "Command bar crossed the trailing inset", file: file, line: line)
        XCTAssertEqual(frame.midX, viewportWidth / 2, accuracy: 0.5, "Command bar is not centered in its viewport", file: file, line: line)
        XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.height + 0.5, "Command bar overflowed vertically", file: file, line: line)
    }

    @MainActor
    private func withStore(_ test: (BrowserStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toastpeek-window-layout-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        defer {
            for id in Array(store.controllers.keys) { store.unload(id) }
            store.flush()
            try? FileManager.default.removeItem(at: root)
        }
        store.tabs = []
        store.showOnboarding = false
        store.searchSuggestionsEnabled = false
        let state = store.makeWindowState()
        store.activeWindowState = state
        store.commandBarMode = .newTab
        try await test(store)
    }
}

@MainActor
private final class LayoutFrameCapture {
    var frame: CGRect?
    var fulfilled = false
}

private struct CommandBarLayoutFixture: View {
    let measured: (CGRect) -> Void

    var body: some View {
        CommandBarView()
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: CommandBarFramePreference.self,
                        value: geometry.frame(in: .named("command-bar-viewport")))
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: "command-bar-viewport")
            .onPreferenceChange(CommandBarFramePreference.self) { frame in
                if let frame { measured(frame) }
            }
    }
}

private enum CommandBarFramePreference: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}
