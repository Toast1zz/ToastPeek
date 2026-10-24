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
    enum DetectedSchema { case chromeFamily, safari, unknown }

    static func schemaName(_ schema: DetectedSchema) -> String {
        switch schema {
        case .chromeFamily: return "chrome-family"
        case .safari: return "safari"
        case .unknown: return "unknown"
        }
    }

    /// Returns up to 5000 rows, newest first. Any failure (not a SQLite
    /// file, no `urls`/`history_items` table, unreadable copy) yields an
    /// empty array — the caller reports "0 imported" rather than crashing
    /// on a file the user picked by mistake.
    static func readHistoryFile(at source: URL) -> [ImportedHistoryRow] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("toastpeek-history-import-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let tmpWAL = URL(fileURLWithPath: tmp.path + "-wal")
        defer {
            for url in [tmp, tmpWAL, URL(fileURLWithPath: tmp.path + "-shm")] { try? fm.removeItem(at: url) }
        }
        // A live browser keeps its newest rows in the "-wal" sidecar. Copy it
        // next to the temp copy and open that copy read-write, so SQLite can
        // replay the WAL. The original files are only ever read.
        let copied = (try? fm.copyItem(at: source, to: tmp)) != nil
        if copied { try? fm.copyItem(at: URL(fileURLWithPath: source.path + "-wal"), to: tmpWAL) }
        let target = copied ? tmp : source
        let flags = copied ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY

        var db: OpaquePointer?
        guard sqlite3_open_v2(target.path, &db, flags, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        // Schema auto-detection by table presence: `urls` = Chrome-family,
        // `history_items` = Safari. (A file with neither is not a history
        // database we understand → empty, reported as "0 imported".)
        let schema: DetectedSchema = tableExists(db, "urls") ? .chromeFamily
            : tableExists(db, "history_items") ? .safari
            : .unknown
        NSLog("ToastPeekHistoryImport schema=%@", schemaName(schema))
        switch schema {
        case .chromeFamily: return readChromeFamily(db)
        case .safari: return readSafari(db)
        case .unknown: return []
        }
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
        name.withCString { ptr in
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
    private static func withCopy<T>(of source: URL, _ body: (OpaquePointer) -> T) -> T? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("toastpeek-places-\(UUID().uuidString).sqlite")
        let wal = URL(fileURLWithPath: tmp.path + "-wal")
        defer { for u in [tmp, wal, URL(fileURLWithPath: tmp.path + "-shm")] { try? fm.removeItem(at: u) } }
        guard (try? fm.copyItem(at: source, to: tmp)) != nil else { return nil }
        try? fm.copyItem(at: URL(fileURLWithPath: source.path + "-wal"), to: wal)
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    static func readFirefoxHistory(at source: URL) -> [ImportedHistoryRow] {
        withCopy(of: source) { db in
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
        } ?? []
    }
}
