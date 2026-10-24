import WebKit

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
                    "url-filter": ".*://([^/]*\\.)?\(escaped)/.*",
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
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static var compiled: WKContentRuleList?
    private static var compiling = false
    private static var pending: [(WKContentRuleList?) -> Void] = []

    /// True once the default list has compiled (first enable or first tab).
    static var isCompiled: Bool { compiled != nil }

    /// Compiles the default list (or returns the cached one) and runs the
    /// completion on the main thread.
    static func prepare(completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled {
            completion(compiled)
            return
        }
        pending.append(completion)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: rulesJSON
        ) { list, error in
            if let error {
                NSLog("ToastPeek content blocker compile failed: %@", error.localizedDescription)
            }
            self.compiled = list
            self.compiling = false
            let waiting = self.pending
            self.pending = []
            for c in waiting { c(list) }
        }
    }

    /// Adds the compiled list to a tab's content controller (no-op until
    /// compilation finishes, then applied via the pending queue).
    static func apply(to ucc: WKUserContentController, completion: ((Bool) -> Void)? = nil) {
        prepare { list in
            if let list { ucc.add(list) }
            completion?(list != nil)
        }
    }

    /// Lists compiled before the last exemption change; tabs still hold them.
    private static var superseded: [WKContentRuleList] = []

    /// Recompiles with new exemptions. Tabs swap lists on their next refresh.
    static func setExemptHosts(_ hosts: [String]) {
        guard hosts != exemptHosts else { return }
        exemptHosts = hosts
        if let compiled { superseded.append(compiled) }
        compiled = nil
    }

    /// Removes the list (current and superseded) from a tab's content
    /// controller. A no-op for lists never added.
    static func remove(from ucc: WKUserContentController) {
        if let compiled { ucc.remove(compiled) }
        for old in superseded { ucc.remove(old) }
    }
}
