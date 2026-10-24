import AppKit

/// A browser whose history can be imported in one step,
/// found by looking for its profile data in the usual places.
struct ImportSource: Identifiable, Hashable {
    enum Kind: Hashable { case chromium, safari, firefox }

    let id: String
    let name: String
    let bundleID: String
    let kind: Kind
    let history: URL?
    /// The data exists but macOS blocks reading it (Safari without Full Disk Access).
    let blocked: Bool

    /// The app's own icon, if it is installed.
    @MainActor var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var hasData: Bool { history != nil }
}

enum ImportSources {
    private static let chromium: [(String, String, String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi"),
        ("Chromium", "org.chromium.Chromium", "Chromium"),
    ]

    /// Browsers with importable data, in a stable order. `home` is injectable for tests.
    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportSource] {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support")
        var out: [ImportSource] = []

        if let safari = safariSource(home: home) { out.append(safari) }

        for (name, bundleID, path) in chromium {
            let root = support.appendingPathComponent(path)
            guard let profile = newestProfile(in: root) else { continue }
            let history = profile.appendingPathComponent("History")
            let h = fm.isReadableFile(atPath: history.path) ? history : nil
            guard let h else { continue }
            out.append(ImportSource(id: bundleID, name: name, bundleID: bundleID, kind: .chromium,
                                    history: h, blocked: false))
        }

        let profiles = support.appendingPathComponent("Firefox/Profiles")
        if let dirs = try? fm.contentsOfDirectory(at: profiles, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let places = dirs.map { $0.appendingPathComponent("places.sqlite") }
                .filter { fm.isReadableFile(atPath: $0.path) }
                .max { modified($0) < modified($1) }
            if let places {
                out.append(ImportSource(id: "org.mozilla.firefox", name: "Firefox", bundleID: "org.mozilla.firefox",
                                        kind: .firefox, history: places, blocked: false))
            }
        }
        return out
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The profile folder (Default, Profile 1…) whose History was touched last.
    private static func newestProfile(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return dirs.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("History").path) }
            .max { modified($0.appendingPathComponent("History")) < modified($1.appendingPathComponent("History")) }
    }

    private static func safariSource(home: URL) -> ImportSource? {
        let fm = FileManager.default
        let dir = home.appendingPathComponent("Library/Safari")
        let history = dir.appendingPathComponent("History.db")
        guard fm.fileExists(atPath: dir.path) || fm.fileExists(atPath: history.path) else { return nil }
        let h = fm.isReadableFile(atPath: history.path) ? history : nil
        // The folder is listed, but its files can't be opened: Full Disk Access is off.
        let blocked = h == nil
        return ImportSource(id: "com.apple.Safari", name: "Safari", bundleID: "com.apple.Safari", kind: .safari,
                            history: h, blocked: blocked)
    }

    struct Payload {
        var history: [ImportedHistoryRow] = []
    }

    /// Reads a source's data. Blocking: call off the main thread.
    static func read(_ source: ImportSource) -> Payload {
        var p = Payload()
        switch source.kind {
        case .chromium:
            if let h = source.history { p.history = HistoryImport.readHistoryFile(at: h) }
        case .safari:
            if let h = source.history { p.history = HistoryImport.readHistoryFile(at: h) }
        case .firefox:
            if let f = source.history { p.history = HistoryImport.readFirefoxHistory(at: f) }
        }
        return p
    }
}
