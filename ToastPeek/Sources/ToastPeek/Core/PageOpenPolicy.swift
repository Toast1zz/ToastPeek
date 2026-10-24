import Foundation

/// What a page may open in a new tab or popup. Pages may only open web
/// addresses, never local files, data: documents or browser-internal pages,
/// and only in response to a click or key press.
enum PageOpenPolicy {
    enum Verdict: Equatable {
        case allow
        case blockedScheme
        case blockedNoGesture
        case blockedRateLimit
    }

    static func isAllowedTarget(_ urlString: String) -> Bool {
        let s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.lowercased() == "about:blank" { return true }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return url.host?.isEmpty == false
        case "blob":
            // blob:https://site/uuid renders content of the page's own origin.
            let inner = s.dropFirst("blob:".count).lowercased()
            return inner.hasPrefix("https://") || inner.hasPrefix("http://")
        default:
            return false
        }
    }

    static func verdict(for urlString: String, userGesture: Bool, limiter: inout OpenRateLimiter,
                        now: Date = Date()) -> Verdict {
        guard isAllowedTarget(urlString) else { return .blockedScheme }
        guard userGesture else { return .blockedNoGesture }
        guard limiter.allow(now: now) else { return .blockedRateLimit }
        return .allow
    }
}

/// At most `limit` opens per `window` seconds from one page.
struct OpenRateLimiter {
    var limit = 5
    var window: TimeInterval = 10
    private var stamps: [Date] = []

    init(limit: Int = 5, window: TimeInterval = 10) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(now: Date = Date()) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}
