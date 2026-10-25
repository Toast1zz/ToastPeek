import XCTest
import SQLite3

final class ImportRegressionTests: XCTestCase {
    func testActiveWALIsIncludedWithoutCopyingSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-wal-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("History")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let connection = try XCTUnwrap(db)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE urls (url TEXT, title TEXT, last_visit_time INTEGER);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "INSERT INTO urls VALUES ('https://wal.example','WAL marker',13300000000000000);", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        let rows = try HistoryImport.readHistoryResult(at: url).get()
        XCTAssertEqual(rows.map(\.title), ["WAL marker"])
        XCTAssertEqual(rows.map(\.urlString), ["https://wal.example"])
        // The original connection remains usable and the source was not checkpointed.
        XCTAssertEqual(sqlite3_exec(connection, "INSERT INTO urls VALUES ('https://second.example','Second',13300000000000001);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try HistoryImport.readHistoryResult(at: url).get().count, 2)
    }

    func testInvalidSourceIsAnErrorRatherThanAnEmptyHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-invalid-\(UUID())")
        try Data("not sqlite".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        guard case .failure = HistoryImport.readHistoryResult(at: url) else { return XCTFail("invalid source must fail") }
    }
}
