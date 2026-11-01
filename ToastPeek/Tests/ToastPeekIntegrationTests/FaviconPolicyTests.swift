import XCTest
import AppKit
import WebKit

@MainActor
final class FaviconPolicyTests: XCTestCase {
    func testKeysSeparateProfilesSchemesAndPortsAndRejectCredentials() throws {
        let a = UUID(), b = UUID()
        func key(_ url: String, _ profile: UUID) -> FaviconKey? {
            FaviconKey(url: URL(string: url), profileID: profile)
        }
        XCTAssertEqual(key("https://example.com/a", a), key("https://EXAMPLE.com:443/b", a))
        XCTAssertNotEqual(key("https://example.com", a), key("https://example.com", b))
        XCTAssertNotEqual(key("http://example.com", a), key("https://example.com", a))
        XCTAssertNotEqual(key("https://example.com:444", a), key("https://example.com", a))
        XCTAssertNil(key("https://user:secret@example.com", a))
        XCTAssertNil(FaviconKey(url: URL(string: "https://example.com"), profileID: nil))
    }

    func testProfileRemovalAndGenerationRejectStaleResults() throws {
        let store = FaviconStore.shared
        let a = try XCTUnwrap(FaviconKey(url: URL(string: "https://a.example"), profileID: UUID()))
        let b = try XCTUnwrap(FaviconKey(url: URL(string: "https://a.example"), profileID: UUID()))
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a3sAAAAASUVORK5CYII="))
        let old = store.generation
        store.store(png, for: a, generation: old)
        store.store(png, for: b, generation: old)
        let slotA = store.slot(for: a), slotB = store.slot(for: b)
        XCTAssertNotNil(slotA.image)
        XCTAssertNotNil(slotB.image)
        store.removeProfile(a.profileID)
        XCTAssertNil(slotA.image)
        XCTAssertNotNil(slotB.image)
        store.store(png, for: a, generation: old)
        XCTAssertNil(store.slot(for: a).image)
        store.removeProfile(b.profileID)
    }

    func testCSPBlockedCrossOriginIconDoesNotCauseApplicationRequest() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favicon-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/testing/browser_fixture.py")
        let portFile = root.appendingPathComponent("server.json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        var port: Int?
        let deadline = Date().addingTimeInterval(12)
        while port == nil && Date() < deadline {
            if let data = try? Data(contentsOf: portFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { port = json["port"] }
            if port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let base = "http://127.0.0.1:\(try XCTUnwrap(port))"
        func count() async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: try XCTUnwrap(URL(string: base + "/audit-icon-count")))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Int])
            return try XCTUnwrap(json["count"])
        }
        let before = try await count()
        let store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        let profileIDs = store.spaces.map(\.dataStoreID)
        addTeardownBlock {
            await MainActor.run { for id in Array(store.controllers.keys) { store.unload(id) } }
            for id in profileIDs {
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
                    }
                }
            }
        }
        let state = store.makeWindowState()
        store.activeWindowState = state
        store.newTab(urlString: base + "/audit-csp")
        let tab = try XCTUnwrap(store.selectedTab)
        let controller = store.controller(for: tab)
        controller.ensureBrowser()
        defer { store.unload(tab.id) }
        let loadDeadline = Date().addingTimeInterval(12)
        while !controller.hasCommittedPage || controller.isLoading {
            guard Date() < loadDeadline else { XCTFail("Page did not finish loading"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let view = try XCTUnwrap(controller.webView)
        let naturalWidth = try await view.evaluateJavaScript("document.images[0].naturalWidth") as? Int
        XCTAssertEqual(naturalWidth, 0)
        // Allow the asynchronous favicon callback to complete.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let after = try await count()
        XCTAssertEqual(after, before)
        let key = try XCTUnwrap(FaviconKey(url: view.url, profileID: controller.dataStoreID))
        XCTAssertNil(FaviconStore.shared.slot(for: key).image)
    }

    func testAuthenticatedPageImageUsesItsProfile() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("favicon-auth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/testing/browser_fixture.py")
        let portFile = root.appendingPathComponent("server.json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [fixture.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            try? FileManager.default.removeItem(at: root)
        }
        var port: Int?
        let deadline = Date().addingTimeInterval(12)
        while port == nil && Date() < deadline {
            if let data = try? Data(contentsOf: portFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] { port = json["port"] }
            if port == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))/audit-auth-page"))
        let store = BrowserStore(stateURL: root.appendingPathComponent("state.json"))
        let profileIDs = store.spaces.map(\.dataStoreID)
        addTeardownBlock {
            await MainActor.run { for id in Array(store.controllers.keys) { store.unload(id) } }
            for id in profileIDs {
                await MainActor.run { FaviconStore.shared.removeProfile(id) }
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        WKWebsiteDataStore.remove(forIdentifier: id) { _ in continuation.resume() }
                    }
                }
            }
        }
        let state = store.makeWindowState()
        store.activeWindowState = state
        store.newTab(urlString: url.absoluteString)
        let tab = try XCTUnwrap(store.selectedTab)
        let controller = store.controller(for: tab)
        controller.ensureBrowser()
        let key = try XCTUnwrap(FaviconKey(url: url, profileID: controller.dataStoreID))
        let slot = FaviconStore.shared.slot(for: key)
        let loadDeadline = Date().addingTimeInterval(12)
        while slot.image == nil {
            guard Date() < loadDeadline else { XCTFail("Authenticated favicon was not extracted"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let otherProfile = try XCTUnwrap(FaviconKey(url: url, profileID: UUID()))
        XCTAssertNil(FaviconStore.shared.slot(for: otherProfile).image)
    }
}
