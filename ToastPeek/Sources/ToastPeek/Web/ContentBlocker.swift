import WebKit
import CryptoKit

/// Native content blocking: the WebKit-era replacement for uBlock-style
/// Chrome extensions, which cannot load in WKWebView. Behaviour is
/// reimplemented with Safari content-blocker rules.
///
/// Semantics (documented, not assumed):
/// - Rules block third-party subresources only (never a top-level document:
///   navigating directly to a listed host still loads the page).
/// - A toggle applies to every live tab's user content controller at once;
///   pages already loaded pick it up on their next navigation or reload.
/// - The compiled list is cached by WebKit under `identifier`; compilation
///   is async, so the first enable applies as soon as it completes.
@MainActor
enum ContentBlocker {
    static let identifier = "toastpeek-content-blocker"

    /// Ad/tracker hosts blocked as subresources. Deliberately conservative:
    /// only hosts whose primary purpose is advertising or tracking, so
    /// blocking cannot break a site's own functionality.
    static let blockedHosts = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "googletagmanager.com",
        "google-analytics.com",
        "facebook.net",
        "connect.facebook.net",
        "scorecardresearch.com",
        "ads.yahoo.com",
        "amazon-adsystem.com",
        "adsrvr.org",
        "criteo.com",
        "outbrain.com",
        "taboola.com",
    ]

    /// Safari content-blocker JSON: one `block` rule per host, subresource
    /// types only (document/svg-document excluded on purpose).
    /// Sites the user turned blocking off for (site controls). Their pages
    /// load every subresource: a final ignore-previous-rules rule scoped to
    /// those top-level domains.
    static var exemptHosts: [String] = []

    static var rulesJSON: String {
        // Safari vocabulary: XHR/fetch is "raw"; xmlhttprequest,
        // websocket and other are not valid here and fail compilation.
        let resourceTypes = ["image", "style-sheet", "script", "font",
                             "media", "raw"]
        var rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": [
                    "url-filter": "^https?://([^/:]*\\.)?\(escaped)(:[0-9]+)?/.*",
                    "load-type": ["third-party"],
                    "resource-type": resourceTypes,
                ],
                "action": ["type": "block"],
            ]
        }
        if !exemptHosts.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-top-url": exemptHosts.map { host in
                    ".*://([^/]*\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[/:].*"
                }],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static var cache: [String: WKContentRuleList] = [:]
    private static let compiler = WKContentRuleListStore.default()!
    private static var cacheOrder: [String] = []
    private static var pending: [String: [(WKContentRuleList?) -> Void]] = [:]
    private static var requestIDs: [String: UUID] = [:]
    private static let installed = NSMapTable<WKUserContentController, WKContentRuleList>.weakToStrongObjects()
    private static let generations = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()
    static var isCompiled: Bool { cache[rulesJSON] != nil }

    static func prepare(completion: @escaping (WKContentRuleList?) -> Void) {
        let json = rulesJSON
        if let list = cache[json] { completion(list); return }
        if pending[json] != nil { pending[json]?.append(completion); return }
        pending[json] = [completion]
        let requestID = UUID()
        requestIDs[json] = requestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard requestIDs[json] == requestID else { return }
            requestIDs.removeValue(forKey: json)
            let callbacks = pending.removeValue(forKey: json) ?? []
            BrowserDiagnostics.record(["event": "content-blocker-timeout"])
            callbacks.forEach { $0(nil) }
        }
        let digest = SHA256.hash(data: Data(json.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        compiler.compileContentRuleList(forIdentifier: identifier + "." + digest,
                                                               encodedContentRuleList: json) { list, error in
            guard requestIDs[json] == requestID else { return }
            requestIDs.removeValue(forKey: json)
            if let list {
                cache[json] = list
                cacheOrder.removeAll { $0 == json }
                cacheOrder.append(json)
                while cacheOrder.count > 4 {
                    let old = cacheOrder.removeFirst()
                    if let evicted = cache.removeValue(forKey: old) {
                        compiler.removeContentRuleList(forIdentifier: evicted.identifier) { _ in }
                    }
                }
            }
            if let error { NSLog("ToastPeek content blocker compile failed: %@", error.localizedDescription) }
            let callbacks = pending.removeValue(forKey: json) ?? []
            if json != rulesJSON { for callback in callbacks { prepare(completion: callback) } }
            else { for callback in callbacks { callback(list) } }
        }
    }

    static func install(_ list: WKContentRuleList, to ucc: WKUserContentController) {
        if let old = installed.object(forKey: ucc) { ucc.remove(old) }
        ucc.add(list)
        installed.setObject(list, forKey: ucc)
    }

    static func apply(to ucc: WKUserContentController, completion: ((Bool) -> Void)? = nil) {
        remove(from: ucc)
        let generation = (generations.object(forKey: ucc)?.intValue ?? 0) + 1
        generations.setObject(NSNumber(value: generation), forKey: ucc)
        prepare { [weak ucc] list in
            guard let ucc, generations.object(forKey: ucc)?.intValue == generation else { completion?(false); return }
            if let list { install(list, to: ucc) }
            completion?(list != nil)
        }
    }

    static func setExemptHosts(_ hosts: [String]) {
        exemptHosts = Array(Set(hosts.map { $0.lowercased() })).sorted()
    }

    static func remove(from ucc: WKUserContentController) {
        let generation = (generations.object(forKey: ucc)?.intValue ?? 0) + 1
        generations.setObject(NSNumber(value: generation), forKey: ucc)
        if let old = installed.object(forKey: ucc) { ucc.remove(old) }
        installed.removeObject(forKey: ucc)
    }
}
