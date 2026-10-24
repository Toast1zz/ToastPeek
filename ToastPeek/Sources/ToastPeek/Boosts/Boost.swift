import Foundation

/// Boost: per-site CSS/JS. The engine matches each rule
/// against the URL of the document actually loading, at load start and end.
struct Boost: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Suffix match on host, e.g. "github.com" matches www.github.com too
    var hostPattern: String
    var css: String = ""
    var js: String = ""
    var isEnabled: Bool = true

    /// Lowercased site without spaces or a trailing dot. WebTabController
    /// wraps each rule in a host check before running it in the page.
    var normalizedPattern: String {
        hostPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    func matches(host: String) -> Bool {
        isEnabled && Self.patternMatches(hostPattern, host: host)
    }

    /// Pattern match ignoring the enabled flag. Reload decisions use this:
    /// turning a Boost off must refresh its pages just like editing it.
    func matchesHostIgnoringEnabled(host: String) -> Bool {
        Self.patternMatches(hostPattern, host: host)
    }

    static func patternMatches(_ pattern: String, host: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let h = host.lowercased()
        return !p.isEmpty && (h == p || h.hasSuffix("." + p))
    }

    /// One script carrying both parts. It runs at load start and load end,
    /// so the CSS block replaces itself instead of stacking, and the user's
    /// JS runs once per document.
    var combinedSource: String {
        let key = id.uuidString
        var parts: [String] = []
        if !css.isEmpty {
            parts.append("""
            (() => { const id = 'toastpeek-boost-\(key)';
              let s = document.getElementById(id);
              if (!s) { s = document.createElement('style'); s.id = id;
                (document.head || document.documentElement).appendChild(s); }
              s.textContent = \(Self.jsString(css)); })();
            """)
        }
        if !js.isEmpty {
            parts.append("""
            (() => { const k = '__toastpeekBoost_\(key.replacingOccurrences(of: "-", with: ""))';
              if (window[k] || !document.body) return; window[k] = true;
              try { \(js) } catch (e) { console.error('Boost failed', e); } })();
            """)
        }
        return parts.joined(separator: "\n")
    }

    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "''" }
        return String(json.dropFirst().dropLast())
    }
}
