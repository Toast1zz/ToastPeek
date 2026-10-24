import XCTest

final class StateFileTests: XCTestCase {
    private var dir: URL!
    private var file: StateFile!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = StateFile(primary: dir.appendingPathComponent("state.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snapshot(tabTitle: String = "A") -> StateSnapshot {
        let space = BrowserSpace(name: "Personal", icon: "house", colorHex: "#7C6FF0")
        let tab = BrowserTab(spaceID: space.id, kind: .today, title: tabTitle, urlString: "https://example.com")
        return StateSnapshot(spaces: [space], currentSpaceID: space.id, tabs: [tab], boosts: [], history: [],
                             archiveAfterHours: 12, settingsVersion: StateSnapshot.currentSettingsVersion)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("state.unreadable-") }
    }

    func testNoFilesIsFresh() {
        guard case .fresh = file.load() else { return XCTFail("expected fresh") }
    }

    func testLoadsPrimary() throws {
        let data = try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "primary")))
        file.write(data, rotateBackup: false)
        guard case .loaded(let s, let fromBackup, let copies) = file.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(s.tabs.first?.title, "primary")
        XCTAssertFalse(fromBackup)
        XCTAssertTrue(copies.isEmpty)
    }

    func testCorruptPrimaryFallsBackToBackupAndKeepsTheCorruptFile() throws {
        try write("{ not json", to: file.primary)
        try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "backup"))).write(to: file.backup)
        guard case .loaded(let s, let fromBackup, let copies) = file.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(s.tabs.first?.title, "backup")
        XCTAssertTrue(fromBackup)
        XCTAssertEqual(copies.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.primary.path))
        let kept = try XCTUnwrap(copies.first)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "{ not json")
    }

    func testBothUnreadableAreMovedAsideNotDeleted() throws {
        try write("garbage-1", to: file.primary)
        try write("garbage-2", to: file.backup)
        guard case .unreadable(let copies, let preserved) = file.load() else { return XCTFail("expected unreadable") }
        XCTAssertTrue(preserved)
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(try leftovers().count, 2)
        let contents = try copies.map { try String(contentsOf: $0, encoding: .utf8) }.sorted()
        XCTAssertEqual(contents, ["garbage-1", "garbage-2"])
    }

    func testFileFromANewerBuildStillLoads() throws {
        let data = try XCTUnwrap(StateFile.encode(snapshot()))
        var json = try XCTUnwrap(String(data: data, encoding: .utf8))
        json = json.replacingOccurrences(of: "\"kind\":\"today\"", with: "\"kind\":\"sticky\"")
        json = json.replacingOccurrences(of: "\"archiveAfterHours\":12",
                                         with: "\"archiveAfterHours\":12,\"searchEngine\":\"startpage\",\"futureField\":true")
        XCTAssertTrue(json.contains("sticky"))
        try write(json, to: file.primary)
        guard case .loaded(let s, _, _) = file.load() else { return XCTFail("expected loaded") }
        XCTAssertEqual(s.tabs.first?.kind, .today)
        XCTAssertEqual(s.searchEngine, .google)
    }

    func testRotationCopiesOnlyADecodableFile() throws {
        try write("broken", to: file.primary)
        let good = try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "new")))
        file.write(good, rotateBackup: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.backup.path))

        let newer = try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "newer")))
        file.write(newer, rotateBackup: true)
        let backup = try XCTUnwrap(StateFile.decode(Data(contentsOf: file.backup)))
        XCTAssertEqual(backup.tabs.first?.title, "new")
    }

    func testReplaceBackupDropsOldData() throws {
        try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "old"))).write(to: file.backup)
        let cleared = try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "cleared")))
        file.write(cleared, rotateBackup: false, replaceBackup: true)
        let backup = try XCTUnwrap(StateFile.decode(Data(contentsOf: file.backup)))
        XCTAssertEqual(backup.tabs.first?.title, "cleared")
    }

    func testOldFilesHaveNoSettingsVersion() throws {
        var s = snapshot()
        s.settingsVersion = nil
        s.searchSuggestionsEnabled = true
        let decoded = try XCTUnwrap(StateFile.decode(XCTUnwrap(StateFile.encode(s))))
        XCTAssertNil(decoded.settingsVersion)
    }
}
