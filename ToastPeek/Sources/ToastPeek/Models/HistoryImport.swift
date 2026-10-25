import Foundation
import SQLite3

/// One row parsed out of a Chrome-family `History` file (Chrome / Edge / Brave
/// all share this schema): the `urls` table's url / title /
/// last_visit_time columns.
struct ImportedHistoryRow {
    var urlString: String
    var title: String
    var visitedAt: Date
}

/// Browser-history reader with schema detection: Chrome-family `History`
/// (a `urls` table) and Safari's `History.db` (`history_items` joined with
/// `history_visits`). The source is copied to a temp file first, so the
/// user's real profile is never written to.
enum HistoryImport {
    /// Chrome-family timestamps are microseconds since 1601-01-01 UTC;
    /// Unix epoch starts 11_644_473_600 seconds later.
    static func chromeFamilyTimeToDate(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000 - 11_644_473_600)
    }

    /// Safari (Core Data) timestamps are seconds since 2001-01-01 UTC;
    /// Unix epoch starts 978_307_200 seconds earlier.
    static func cocoaTimeToDate(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value + 978_307_200)
    }

    /// Which schema a database turned out to have (evidence/logging).
    enum DetectedSchema { case chromeFamily, safari, firefox, unknown }

    static func schemaName(_ schema: DetectedSchema) -> String {
        switch schema {
        case .chromeFamily: return "chrome-family"
        case .safari: return "safari"
        case .firefox: return "firefox"
        case .unknown: return "unknown"
        }
    }

    struct ImportFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func readHistoryFile(at source: URL) -> [ImportedHistoryRow] {
        (try? readHistoryResult(at: source).get()) ?? []
    }

    static func readHistoryResult(at source: URL) -> Result<[ImportedHistoryRow], ImportFailure> {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("toastpeek-history-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] { try? fm.removeItem(atPath: temp.path + suffix) }
        }
        var src: OpaquePointer?, dest: OpaquePointer?
        defer { if let src { sqlite3_close(src) }; if let dest { sqlite3_close(dest) } }
        guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB = src else {
            return .failure(ImportFailure(message: String(localized: "The selected history database could not be opened. Check file access permissions.")))
        }
        sqlite3_busy_timeout(sourceDB, 2000)
        guard sqlite3_open_v2(temp.path, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = dest, let backup = sqlite3_backup_init(db, "main", sourceDB, "main") else {
            return .failure(ImportFailure(message: String(localized: "A consistent history snapshot could not be created.")))
        }
        var status: Int32 = SQLITE_OK
        var retries = 0
        let deadline = Date().addingTimeInterval(5)
        repeat {
            status = sqlite3_backup_step(backup, 256)
            if status == SQLITE_BUSY || status == SQLITE_LOCKED { retries += 1; Thread.sleep(forTimeInterval: 0.05) }
        } while Date() < deadline && (status == SQLITE_OK || ((status == SQLITE_BUSY || status == SQLITE_LOCKED) && retries < 20))
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            return .failure(ImportFailure(message: String(localized: "The source browser is busy. Close it and try importing again.")))
        }
        let schema: DetectedSchema = tableExists(db, "urls") ? .chromeFamily
            : tableExists(db, "history_items") ? .safari
            : tableExists(db, "moz_places") ? .firefox : .unknown
        let rows: [ImportedHistoryRow]
        switch schema {
        case .chromeFamily: rows = readChromeFamily(db)
        case .safari: rows = readSafari(db)
        case .firefox: rows = readFirefox(db)
        case .unknown: return .failure(ImportFailure(message: String(localized: "This file does not contain a supported browser history database.")))
        }
        let code = sqlite3_errcode(db)
        guard code == SQLITE_OK || code == SQLITE_DONE || code == SQLITE_ROW else {
            return .failure(ImportFailure(message: String(localized: "The history database is damaged or uses an unsupported schema.")))
        }
        return .success(rows)
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return false }
        defer { sqlite3_finalize(stmt) }
        // NOTE: must be TRANSIENT, not nil (= STATIC): Swift bridges `name`
        // to a temporary buffer valid only for this call, and step() runs
        // after it is freed. STATIC here made Chrome history import
        // intermittently return 0 rows (found 2026-10-24 via histdiag).
        _ = name.withCString { ptr in
            sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func readChromeFamily(_ db: OpaquePointer) -> [ImportedHistoryRow] {
        let sql = "SELECT url, title, last_visit_time FROM urls ORDER BY last_visit_time DESC LIMIT 5000"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [ImportedHistoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlPtr = sqlite3_column_text(stmt, 0) else { continue }
            let urlString = String(cString: urlPtr)
            guard !urlString.isEmpty else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let stamp = sqlite3_column_int64(stmt, 2)
            rows.append(ImportedHistoryRow(
                urlString: urlString,
                title: title,
                visitedAt: stamp > 0 ? chromeFamilyTimeToDate(stamp) : Date(timeIntervalSince1970: 0)))
        }
        return rows
    }

    /// Safari: one row per VISIT (a page appears once per visit, not once
    /// per item) — history_visits carries the per-visit title and the
    /// visit_time, history_items the URL it points at. Very old Safari
    /// schemas lack history_visits.title; the fallback query drops it.
    private static func readSafari(_ db: OpaquePointer) -> [ImportedHistoryRow] {
        let withTitle = """
            SELECT hi.url, hv.title, hv.visit_time
            FROM history_visits hv
            JOIN history_items hi ON hi.id = hv.history_item
            ORDER BY hv.visit_time DESC LIMIT 5000
            """
        let withoutTitle = """
            SELECT hi.url, NULL, hv.visit_time
            FROM history_visits hv
            JOIN history_items hi ON hi.id = hv.history_item
            ORDER BY hv.visit_time DESC LIMIT 5000
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, withTitle, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            stmt = nil
            guard sqlite3_prepare_v2(db, withoutTitle, -1, &stmt, nil) == SQLITE_OK else { return [] }
        }
        guard let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [ImportedHistoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlPtr = sqlite3_column_text(stmt, 0) else { continue }
            let urlString = String(cString: urlPtr)
            guard !urlString.isEmpty else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let stamp = sqlite3_column_double(stmt, 2)
            rows.append(ImportedHistoryRow(
                urlString: urlString,
                title: title,
                visitedAt: stamp > 0 ? cocoaTimeToDate(stamp) : Date(timeIntervalSince1970: 0)))
        }
        return rows
    }
}

/// Firefox `places.sqlite`: history from `moz_places`.
extension HistoryImport {
    static func readFirefoxHistory(at source: URL) -> [ImportedHistoryRow] { readHistoryFile(at: source) }
    private static func readFirefox(_ db: OpaquePointer) -> [ImportedHistoryRow] {
            let sql = "SELECT url, title, last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL AND url LIKE 'http%' ORDER BY last_visit_date DESC LIMIT 5000"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [ImportedHistoryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let u = sqlite3_column_text(stmt, 0) else { continue }
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let micros = sqlite3_column_int64(stmt, 2)
                rows.append(ImportedHistoryRow(urlString: String(cString: u), title: title,
                                               visitedAt: Date(timeIntervalSince1970: Double(micros) / 1_000_000)))
            }
            return rows
    }
}
