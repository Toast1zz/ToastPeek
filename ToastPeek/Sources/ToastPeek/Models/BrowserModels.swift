import SwiftUI
import AppKit
import Foundation

// MARK: - Space

struct BrowserSpace: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var icon: String // SF Symbol name
    var colorHex: String
    /// Names the Space's data-store folder (cookies, storage, cache).
    var dataStoreID: UUID = UUID()

    var color: Color { Color(hex: colorHex) }
    /// Space icons are SF Symbol names or a single emoji.
    var iconIsSymbol: Bool { NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil }

    /// Static lets are created once, so these ids are stable for a session.
    static let personal = BrowserSpace(name: "Personal", icon: "house", colorHex: "#7C6FF0")
    static let defaults: [BrowserSpace] = [
        personal,
        BrowserSpace(name: "Work", icon: "briefcase", colorHex: "#2F9E6E"),
        BrowserSpace(name: "Research", icon: "book", colorHex: "#E08A2E"),
    ]
}

extension BrowserSpace {
    // Hand-written Codable (batch 6): icon/colorHex were required keys
    // under the synthesized decoder, so a state file from before
    // per-Space theming (or a hand-trimmed one) missing them failed the
    // WHOLE state.json decode. Missing keys now fall back to defaults,
    // so an old file loads with its spaces, tabs and data intact.
    enum CodingKeys: String, CodingKey {
        case id, name, icon, colorHex, dataStoreID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Space"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "circle"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#7C6FF0"
        dataStoreID = try c.decodeIfPresent(UUID.self, forKey: .dataStoreID) ?? UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(dataStoreID, forKey: .dataStoreID)
    }
}

// MARK: - Tab

enum TabKind: String, Codable {
    case favorite, pinned, today

    /// A kind written by a newer build loads as a Today tab instead of
    /// failing the whole state file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TabKind(rawValue: raw) ?? .today
    }
}

struct BrowserTab: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var spaceID: UUID? // nil for favorites (global)
    var kind: TabKind
    var title: String
    var urlString: String
    var createdAt: Date = Date()
    var lastVisitedAt: Date = Date()
    var isArchived: Bool = false
    /// Pinned-folder membership (TabFolder.id); nil = ungrouped.
    var folderID: UUID? = nil
    /// Order inside the tab's sidebar group (kind + space + folder).
    var sortIndex: Double = 0
    /// Non-nil marks a source viewer for the page at this address. The
    /// address is never loaded: the old engine ran "view-source:" as a plain
    /// load, so ViewSourceView shows text captured from the live DOM.
    var viewSourceFor: String? = nil
    /// Pinned tabs and Favorites remember the address they were pinned at;
    /// closing one unloads it and returns it there (Chrome-style).
    var pinnedURLString: String? = nil
    /// Cookie identity is independent of sidebar grouping and Space ordering.
    var profileID: UUID? = nil
    var archivedAt: Date? = nil

    var url: URL { URL(string: urlString) ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/") }
    var host: String { url.host ?? "" }
    /// Host without a leading "www.", for display.
    var displayHost: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var displayTitle: String {
        if !title.isEmpty { return title }
        if url.isFileURL { return url.lastPathComponent }
        return displayHost.isEmpty ? String(localized: "New Tab") : displayHost
    }
    /// Navigated away from where it was pinned.
    var hasDriftedFromPin: Bool {
        guard let pinned = pinnedURLString else { return false }
        func norm(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return norm(pinned) != norm(urlString)
    }
}

/// A named group inside one Space's Pinned section.
struct TabFolder: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var spaceID: UUID
    var name: String
    var isCollapsed: Bool = false
}

extension BrowserTab {
    // Hand-written Codable (in an extension, so the memberwise init and
    // Hashable synthesis survive): fields added later fall back to defaults.
    enum CodingKeys: String, CodingKey {
        case id, spaceID, kind, title, urlString, createdAt, lastVisitedAt, isArchived, folderID, sortIndex, viewSourceFor, pinnedURLString, profileID, archivedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        spaceID = try c.decodeIfPresent(UUID.self, forKey: .spaceID)
        kind = try c.decode(TabKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        urlString = try c.decode(String.self, forKey: .urlString)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastVisitedAt = try c.decodeIfPresent(Date.self, forKey: .lastVisitedAt) ?? Date()
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        sortIndex = try c.decodeIfPresent(Double.self, forKey: .sortIndex) ?? 0
        viewSourceFor = try c.decodeIfPresent(String.self, forKey: .viewSourceFor)
        pinnedURLString = try c.decodeIfPresent(String.self, forKey: .pinnedURLString)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(spaceID, forKey: .spaceID)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(urlString, forKey: .urlString)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastVisitedAt, forKey: .lastVisitedAt)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(sortIndex, forKey: .sortIndex)
        try c.encodeIfPresent(viewSourceFor, forKey: .viewSourceFor)
        try c.encodeIfPresent(pinnedURLString, forKey: .pinnedURLString)
        try c.encodeIfPresent(profileID, forKey: .profileID)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
    }
}

struct HistoryEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var visitedAt: Date = Date()
}

/// A built-in extension (Content Blocker, Dark Mode) and whether it is on.
struct BrowserExtension: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var version: String
    var path: String
    var isEnabled: Bool = true
}


// MARK: - Downloads (live state from the download handler; not persisted)

struct DownloadItemState: Identifiable, Equatable {
    /// Download id (unique per download, stable across its updates).
    var id: UUID
    var fileName: String
    var urlString: String
    var fullPath: String
    /// -1 when the total size is unknown.
    var percent: Int
    var receivedBytes: Int64
    var totalBytes: Int64
    /// "inProgress" / "completed" / "cancelled" — raw strings across the bridge.
    var state: String
    var errorDescription: String? = nil

    var isComplete: Bool { state == "completed" }
    var fileURL: URL { URL(fileURLWithPath: fullPath) }
}

/// A finished download, kept for the Library (the live list above is
/// per session and also carries in-progress items).
struct DownloadRecord: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var urlString: String
    var fullPath: String
    var date: Date = Date()

    var fileURL: URL { URL(fileURLWithPath: fullPath) }
    var sourceHost: String {
        let h = URL(string: urlString)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    var isMedia: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "bmp", "tiff", "svg",
         "mp4", "mov", "m4v", "webm"].contains((fileName as NSString).pathExtension.lowercased())
    }
}

// MARK: - Color hex helper (Foundation + SwiftUI only)

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0; Scanner(string: h).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Search engines

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, kagi, ecosia, baidu
    var id: String { rawValue }

    /// An engine written by a newer build falls back to Google instead of
    /// failing the whole state file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SearchEngine(rawValue: raw) ?? .google
    }
    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .ecosia: return "Ecosia"
        case .baidu: return "Baidu"
        }
    }
    var searchTemplate: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%@"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%@"
        case .bing: return "https://www.bing.com/search?q=%@"
        case .kagi: return "https://kagi.com/search?q=%@"
        case .ecosia: return "https://www.ecosia.org/search?q=%@"
        case .baidu: return "https://www.baidu.com/s?wd=%@"
        }
    }
    /// OpenSearch-style suggestion endpoint returning ["query", [suggestions]].
    var suggestTemplate: String? {
        switch self {
        case .google: return "https://suggestqueries.google.com/complete/search?client=firefox&q=%@"
        case .duckDuckGo: return "https://duckduckgo.com/ac/?type=list&q=%@"
        case .bing: return "https://api.bing.com/osjson.aspx?query=%@"
        case .ecosia: return "https://ac.ecosia.org/autocomplete?type=list&q=%@"
        case .kagi, .baidu: return nil
        }
    }
}

// MARK: - URL normalisation (Command Bar / address field share this)

enum URLResolver {
    private static let schemes: Set<String> = ["http", "https", "file", "about", "chrome", "data", "view-source"]

    /// Percent-encodes text for one query-string value (& + = ? # escaped).
    static func encodeQueryValue(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func searchURL(for query: String, engine: SearchEngine) -> URL? {
        URL(string: engine.searchTemplate.replacingOccurrences(of: "%@", with: encodeQueryValue(query)))
    }

    /// True when the text should be treated as an address, not a search.
    static func looksLikeURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if let scheme = URL(string: s)?.scheme?.lowercased(), schemes.contains(scheme) || s.contains("://") { return true }
        guard !s.contains(where: { $0.isWhitespace }) else { return false }
        guard let host = URLComponents(string: "http://" + s)?.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasPrefix("["), host.hasSuffix("]"), host.contains(":") { return true }
        let octets = host.split(separator: ".")
        if octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } == true }) { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        let tld = host.split(separator: ".").last.map(String.init) ?? ""
        return tld.count >= 2 && tld.allSatisfy { $0.isLetter }
    }

    static func resolve(_ raw: String, engine: SearchEngine = .google) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if looksLikeURL(s) {
            if let u = URL(string: s), let scheme = u.scheme?.lowercased(), schemes.contains(scheme) || s.contains("://") { return u }
            let host = URLComponents(string: "http://" + s)?.host?.lowercased() ?? ""
            let isLocal = host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("[")
                || (host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." })
            let prefix = isLocal ? "http://" : "https://"
            return URL(string: prefix + s)
        }
        return searchURL(for: s, engine: engine)
    }
}
