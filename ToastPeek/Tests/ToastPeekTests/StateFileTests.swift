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

    func testBackupRecoveryStaysReadOnlyWhenDamagedPrimaryCannotBePreserved() throws {
        try write("{ not json", to: file.primary)
        try XCTUnwrap(StateFile.encode(snapshot(tabTitle: "backup"))).write(to: file.backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        guard case .recoveredReadOnly(let recovered) = file.load() else { return XCTFail("expected read-only backup recovery") }
        XCTAssertEqual(recovered.tabs.first?.title, "backup")
        XCTAssertEqual(try String(contentsOf: file.primary), "{ not json")
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

    func testFutureSchemaIsPreservedWithoutFallbackOrRewrite() throws {
        var future = snapshot()
        future.schemaVersion = StateSnapshot.currentSchemaVersion + 1
        let data = try XCTUnwrap(StateFile.encode(future))
        try data.write(to: file.primary)
        guard case .unsupportedVersion = file.load() else { return XCTFail("future schema must not be overwritten") }
        XCTAssertEqual(try Data(contentsOf: file.primary), data)
        XCTAssertTrue(try leftovers().isEmpty)
    }

    func testSemanticRepairKeepsTabAndRepairsOrphanReferences() throws {
        var value = snapshot()
        value.tabs[0].spaceID = UUID()
        value.tabs[0].folderID = UUID()
        value.tabs[0].isArchived = true
        let repaired = try XCTUnwrap(StateFile.decode(XCTUnwrap(StateFile.encode(value))))
        XCTAssertEqual(repaired.tabs.count, 1)
        XCTAssertEqual(repaired.tabs[0].spaceID, repaired.currentSpaceID)
        XCTAssertNil(repaired.tabs[0].folderID)
        XCTAssertEqual(repaired.tabs[0].profileID, repaired.spaces[0].dataStoreID)
        XCTAssertNotNil(repaired.tabs[0].archivedAt)
    }

    func testAmbiguousSpaceAndCookieIdentitiesAreRejected() throws {
        var value = snapshot()
        value.spaces.append(value.spaces[0])
        XCTAssertNil(StateFile.decode(try XCTUnwrap(StateFile.encode(value))))
        value.spaces[1].id = UUID()
        XCTAssertNil(StateFile.decode(try XCTUnwrap(StateFile.encode(value))))
    }

    func testWritingIntoInvalidDirectoryReturnsFailure() throws {
        let invalidParent = dir.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidParent)
        let bad = StateFile(primary: invalidParent.appendingPathComponent("state.json"))
        guard case .failure = bad.write(try XCTUnwrap(StateFile.encode(snapshot())), rotateBackup: false) else {
            return XCTFail("write failure must reach caller")
        }
    }

    func testReadOnlyLoadNeverMovesCorruptState() throws {
        let bytes = Data("corrupt".utf8)
        try bytes.write(to: file.primary)
        guard case .unreadable(_, let preserved) = file.load(preserveOnly: true) else { return XCTFail("unreadable") }
        XCTAssertFalse(preserved)
        XCTAssertEqual(try Data(contentsOf: file.primary), bytes)
        XCTAssertTrue(try leftovers().isEmpty)
    }
}
