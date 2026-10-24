import XCTest

final class SpaceThemeTests: XCTestCase {
    func testOldSpaceWithoutThemeKeysLoadsWithDefaults() throws {
        let spaceID = UUID()
        let json = """
        {"spaces":[{"id":"\(spaceID.uuidString)","name":"Personal"}],"currentSpaceID":"\(spaceID.uuidString)","tabs":[],"boosts":[],"history":[],"archiveAfterHours":12}
        """
        let back = try XCTUnwrap(StateFile.decode(Data(json.utf8)))
        let space = try XCTUnwrap(back.spaces.first)
        XCTAssertEqual(space.name, "Personal")
        XCTAssertEqual(space.icon, "circle")
        XCTAssertEqual(space.colorHex, "#7C6FF0")
    }

    func testOldSpaceWithoutThemeKeysKeepsItsTabs() throws {
        let spaceID = UUID()
        let tabID = UUID()
        let json = """
        {"spaces":[{"id":"\(spaceID.uuidString)","name":"Personal"}],"currentSpaceID":"\(spaceID.uuidString)","tabs":[{"id":"\(tabID.uuidString)","spaceID":"\(spaceID.uuidString)","kind":"today","title":"Kept Tab","urlString":"https://example.com"}],"boosts":[],"history":[],"archiveAfterHours":12}
        """
        let back = try XCTUnwrap(StateFile.decode(Data(json.utf8)))
        XCTAssertEqual(back.tabs.count, 1)
        XCTAssertEqual(back.tabs.first?.title, "Kept Tab")
    }

    func testCustomThemeRoundTripsThroughStateFile() throws {
        let space = BrowserSpace(name: "Themed", icon: "moon", colorHex: "#E05A8A")
        let snap = StateSnapshot(spaces: [space], currentSpaceID: space.id, tabs: [],
                                 boosts: [], history: [], archiveAfterHours: 12)
        let data = try XCTUnwrap(StateFile.encode(snap))
        let back = try XCTUnwrap(StateFile.decode(data))
        let restored = try XCTUnwrap(back.spaces.first)
        XCTAssertEqual(restored.icon, "moon")
        XCTAssertEqual(restored.colorHex, "#E05A8A")
        XCTAssertEqual(restored.id, space.id)
    }
}
