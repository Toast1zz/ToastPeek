import Foundation

/// Everything persisted in state.json. Optional fields were added over time;
/// they stay optional so older files keep loading.
struct StateSnapshot: Codable {
    var spaces: [BrowserSpace]
    var currentSpaceID: UUID
    var tabs: [BrowserTab]
    var boosts: [Boost]
    var history: [HistoryEntry]
    var archiveAfterHours: Double
    var folders: [TabFolder]?
    var extensions: [BrowserExtension]?
    var sitePermissions: [SitePermission]?
    var mutedTabIDs: [UUID]?
    var sidebarWidth: Double?
    var searchEngine: SearchEngine?
    var searchSuggestionsEnabled: Bool?
    var memorySaverEnabled: Bool?
    var askDownloadLocation: Bool?
    var warnBeforeQuitting: Bool?
    var downloadsFolder: String?
    var lastSelectedBySpace: [String: UUID]?
    var isSidebarVisible: Bool?
    /// Bumped when a default changes for existing users (nil = before 1).
    var settingsVersion: Int?
    /// Dark Mode's per-site host list (nil = before this key existed).
    var darkModeHosts: [String]? = nil
    /// Library downloads, newest first (nil = before the Library).
    var downloadRecords: [DownloadRecord]? = nil
    /// Sites the Content Blocker leaves alone (site controls).
    var blockerExemptHosts: [String]? = nil
    /// Sites Dark Mode skips while it applies to every site.
    var darkModeExcludedHosts: [String]? = nil
    /// Links settings (nil = on).
    var externalLinksInPeek: Bool? = nil
    var shiftClickPeek: Bool? = nil
    var peekHotkeyEnabled: Bool? = nil
    var boostsEnabled: Bool? = nil

    static let currentSettingsVersion = 1
}

/// state.json plus its rolling backup. A file that exists but can't be read
/// is never overwritten: it is moved aside first, so the user's Spaces and
/// tabs survive a downgrade or a damaged write.
struct StateFile {
    let primary: URL
    var backup: URL { primary.appendingPathExtension("bak") }

    enum LoadResult {
        /// Nothing on disk yet (first launch).
        case fresh
        /// `unreadableCopies` lists any file that failed to decode and was kept aside.
        case loaded(StateSnapshot, fromBackup: Bool, unreadableCopies: [URL])
        /// Files existed but none could be read. `preserved` is false when a
        /// copy could not be moved aside, so nothing may be written.
        case unreadable(copies: [URL], preserved: Bool)
    }

    static func decode(_ data: Data) -> StateSnapshot? {
        guard let s = try? JSONDecoder().decode(StateSnapshot.self, from: data), !s.spaces.isEmpty else { return nil }
        return s
    }

    static func encode(_ snapshot: StateSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    func load(now: Date = Date()) -> LoadResult {
        let fm = FileManager.default
        var copies: [URL] = []
        var preserved = true
        for (index, url) in [primary, backup].enumerated() {
            guard fm.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url), let snapshot = Self.decode(data) {
                return .loaded(snapshot, fromBackup: index == 1, unreadableCopies: copies)
            }
            if let kept = moveAside(url, suffix: index == 0 ? "json" : "bak.json", now: now) {
                copies.append(kept)
            } else {
                preserved = false
            }
        }
        return copies.isEmpty && preserved ? .fresh : .unreadable(copies: copies, preserved: preserved)
    }

    /// Writes `data` atomically. With `rotateBackup`, the current file is
    /// copied to the backup first, but only if it still decodes. With
    /// `replaceBackup`, the backup gets `data` too (after clearing data).
    func write(_ data: Data, rotateBackup: Bool, replaceBackup: Bool = false) {
        if replaceBackup {
            try? data.write(to: backup, options: .atomic)
        } else if rotateBackup, let existing = try? Data(contentsOf: primary), Self.decode(existing) != nil {
            try? existing.write(to: backup, options: .atomic)
        }
        try? data.write(to: primary, options: .atomic)
    }

    private func moveAside(_ url: URL, suffix: String, now: Date) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent("state.unreadable-\(f.string(from: now)).\(suffix)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("state.unreadable-\(f.string(from: now))-\(n).\(suffix)")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
