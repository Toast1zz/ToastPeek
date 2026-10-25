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
    var schemaVersion: Int? = nil
    var revision: Int? = nil
    var pendingCleanup: Bool? = nil
    var pendingDataStoreDeletions: [UUID]? = nil

    static let currentSettingsVersion = 1
    static let currentSchemaVersion = 1
}

/// state.json plus its rolling backup. A file that exists but can't be read
/// is never overwritten: it is moved aside first, so the user's Spaces and
/// tabs survive a downgrade or a damaged write.
struct StateFile {
    let primary: URL
    var backup: URL { primary.appendingPathExtension("bak") }
    var cleanupMarker: URL { primary.appendingPathExtension("cleanup-pending") }

    enum LoadResult {
        /// Nothing on disk yet (first launch).
        case fresh
        /// `unreadableCopies` lists any file that failed to decode and was kept aside.
        case loaded(StateSnapshot, fromBackup: Bool, unreadableCopies: [URL])
        case recoveredReadOnly(StateSnapshot)
        /// Files existed but none could be read. `preserved` is false when a
        /// copy could not be moved aside, so nothing may be written.
        case unreadable(copies: [URL], preserved: Bool)
        case unsupportedVersion
    }

    static func decode(_ data: Data) -> StateSnapshot? {
        guard var s = try? JSONDecoder().decode(StateSnapshot.self, from: data), !s.spaces.isEmpty,
              (s.schemaVersion ?? 0) <= StateSnapshot.currentSchemaVersion else { return nil }
        // Keep valid records, repair dangling UI references, and reject ambiguous
        // identities rather than silently merging two accounts' data stores.
        guard Set(s.spaces.map(\.id)).count == s.spaces.count,
              Set(s.spaces.map(\.dataStoreID)).count == s.spaces.count else { return nil }
        let spaceIDs = Set(s.spaces.map(\.id)), profileIDs = Set(s.spaces.map(\.dataStoreID))
        if !spaceIDs.contains(s.currentSpaceID) { s.currentSpaceID = s.spaces[0].id }
        var seen = Set<UUID>()
        s.folders = (s.folders ?? []).filter { spaceIDs.contains($0.spaceID) && seen.insert($0.id).inserted }
        let folderSpaces = Dictionary(uniqueKeysWithValues: (s.folders ?? []).map { ($0.id, $0.spaceID) })
        seen = []
        s.tabs = s.tabs.filter { seen.insert($0.id).inserted }
        for i in s.tabs.indices {
            if s.tabs[i].kind != .favorite, !spaceIDs.contains(s.tabs[i].spaceID ?? UUID()) {
                s.tabs[i].spaceID = s.currentSpaceID
            }
            if let folder = s.tabs[i].folderID,
               s.tabs[i].kind != .pinned || folderSpaces[folder] != s.tabs[i].spaceID {
                s.tabs[i].folderID = nil
            }
            if !profileIDs.contains(s.tabs[i].profileID ?? UUID()) {
                s.tabs[i].profileID = s.spaces.first { $0.id == s.tabs[i].spaceID }?.dataStoreID ?? s.spaces[0].dataStoreID
            }
            // Legacy archives get a full retention window after migration.
            if s.tabs[i].isArchived, s.tabs[i].archivedAt == nil { s.tabs[i].archivedAt = Date() }
            if !s.tabs[i].sortIndex.isFinite { s.tabs[i].sortIndex = Double(i) }
        }
        if !s.archiveAfterHours.isFinite { s.archiveAfterHours = 12 }
        s.archiveAfterHours = min(max(s.archiveAfterHours, 1), 8760)
        s.schemaVersion = StateSnapshot.currentSchemaVersion
        return s
    }

    static func encode(_ snapshot: StateSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    func load(now: Date = Date(), preserveOnly: Bool = false) -> LoadResult {
        let fm = FileManager.default
        var copies: [URL] = []
        var preserved = true
        for (index, url) in [primary, backup].enumerated() {
            guard fm.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["schemaVersion"] as? Int, version > StateSnapshot.currentSchemaVersion {
                return .unsupportedVersion
            }
            if let data = try? Data(contentsOf: url), let snapshot = Self.decode(data) {
                if !preserved { return .recoveredReadOnly(snapshot) }
                return .loaded(snapshot, fromBackup: index == 1, unreadableCopies: copies)
            }
            if preserveOnly {
                copies.append(url); preserved = false
            } else if let kept = moveAside(url, suffix: index == 0 ? "json" : "bak.json", now: now) {
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
    @discardableResult
    func write(_ data: Data, rotateBackup: Bool, replaceBackup: Bool = false) -> Result<Void, Error> {
        do {
            if !replaceBackup, rotateBackup, let existing = try? Data(contentsOf: primary), Self.decode(existing) != nil {
                try existing.write(to: backup, options: .atomic)
            }
            try data.write(to: primary, options: .atomic)
            if replaceBackup { try data.write(to: backup, options: .atomic) }
            return .success(())
        } catch {
            return .failure(error)
        }
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
