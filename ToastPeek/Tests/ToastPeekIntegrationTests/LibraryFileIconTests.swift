import XCTest
import ImageIO
import UniformTypeIdentifiers

final class LibraryFileIconTests: XCTestCase {
    @MainActor
    func testExistingMissingAndTypeIconsProduceBoundedPNGData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskImage = root.appendingPathComponent("fixture.dmg")
        try Data().write(to: diskImage)

        for (path, name) in [(diskImage.path, "fixture.dmg"),
                             (root.appendingPathComponent("missing.pdf").path, "missing.pdf"),
                             ("", "pending.txt")] {
            let result = await LibraryFileIcons.load(path: path, fileName: name)
            let data = try XCTUnwrap(result)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThanOrEqual(image.width, 64)
            XCTAssertLessThanOrEqual(image.height, 64)
        }
    }
}
