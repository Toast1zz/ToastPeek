import XCTest
import AppKit

@MainActor
final class FaviconStoreTests: XCTestCase {
    private func png(_ rgb: (UInt8, UInt8, UInt8), width: Int = 1, height: Int = 1) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        pixels[0] = rgb.0; pixels[1] = rgb.1; pixels[2] = rgb.2; pixels[3] = 255
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "FaviconCacheTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testCacheSeparatesProfilesSchemesAndPortsOnDiskAndInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FaviconStore(directory: root)
        let profile = UUID()
        let original = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test/a")!, profileID: profile))
        let otherProfile = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test/a")!, profileID: UUID()))
        let otherPort = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test:444/a")!, profileID: profile))
        let otherScheme = try XCTUnwrap(FaviconKey(url: URL(string: "http://example.test/a")!, profileID: profile))
        XCTAssertEqual(original, FaviconKey(url: URL(string: "https://EXAMPLE.test:443/b?q=private")!, profileID: profile))
        XCTAssertTrue(cache.store(try png((255, 0, 0)), for: original, generation: cache.generation))
        XCTAssertTrue(cache.store(try png((0, 0, 255)), for: otherProfile, generation: cache.generation))
        XCTAssertNil(cache.slot(for: otherPort).image)
        XCTAssertNil(cache.slot(for: otherScheme).image)
        XCTAssertFalse(cache.slot(for: original) === cache.slot(for: otherProfile))
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: root.path).count) == 2 }
        let restored = FaviconStore(directory: root)
        let red = restored.slot(for: original), blue = restored.slot(for: otherProfile)
        try await waitUntil { red.image != nil && blue.image != nil }
        XCTAssertNotEqual(red.image?.tiffRepresentation, blue.image?.tiffRepresentation)
        XCTAssertNil(restored.slot(for: otherPort).image)
        await withCheckedContinuation { continuation in cache.removeAll { _ in continuation.resume() } }
    }

    func testClearInvalidatesRetainedSlotsAndRejectsLateResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FaviconStore(directory: root)
        let key = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test")!, profileID: UUID()))
        let slot = cache.slot(for: key), generation = cache.generation
        let data = try png((255, 0, 0))
        XCTAssertTrue(cache.store(data, for: key, generation: generation))
        await withCheckedContinuation { continuation in cache.removeAll { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            continuation.resume()
        } }
        XCTAssertNil(slot.image)
        XCTAssertFalse(cache.store(data, for: key, generation: generation))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testRemovingProfileKeepsOtherProfileIconsAndRejectsOldResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FaviconStore(directory: root)
        let first = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test")!, profileID: UUID()))
        let other = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test")!, profileID: UUID()))
        let oldGeneration = cache.generation, data = try png((255, 0, 0))
        XCTAssertTrue(cache.store(data, for: first, generation: oldGeneration))
        XCTAssertTrue(cache.store(try png((0, 0, 255)), for: other, generation: oldGeneration))
        let removed = cache.slot(for: first), retained = cache.slot(for: other)
        await withCheckedContinuation { continuation in cache.remove(profileID: first.profileID) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            continuation.resume()
        } }
        XCTAssertNil(removed.image)
        XCTAssertNotNil(retained.image)
        XCTAssertFalse(cache.store(data, for: first, generation: oldGeneration))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix(other.profileID.uuidString + "."))
        await withCheckedContinuation { continuation in cache.removeAll { _ in continuation.resume() } }
    }

    func testCachedImageActuallyUses64PixelThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FaviconStore(directory: root)
        let key = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test")!, profileID: UUID()))
        XCTAssertTrue(cache.store(try png((255, 0, 0), width: 1024, height: 512), for: key, generation: cache.generation))
        let image = try XCTUnwrap(cache.slot(for: key).image)
        let decoded = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertLessThanOrEqual(decoded.bytesPerRow * decoded.height, 64 * 32 * 4)
        await withCheckedContinuation { continuation in cache.removeAll { _ in continuation.resume() } }
    }

    func testDecoderRejectsInvalidAndExcessivePixelDimensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FaviconStore(directory: root)
        let key = try XCTUnwrap(FaviconKey(url: URL(string: "https://example.test")!, profileID: UUID()))
        XCTAssertFalse(cache.store(Data("not an image".utf8), for: key, generation: cache.generation))
        XCTAssertFalse(cache.store(try png((255, 0, 0), width: 1025), for: key, generation: cache.generation))
        XCTAssertNil(cache.slot(for: key).image)
        XCTAssertNil(FaviconKey(url: URL(string: "file:///tmp/icon")!, profileID: UUID()))
        XCTAssertNil(FaviconKey(url: URL(string: "https://example.test")!, profileID: nil))
    }
}
