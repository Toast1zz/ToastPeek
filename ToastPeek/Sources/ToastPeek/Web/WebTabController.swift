import SwiftUI
import AppKit
import PDFKit
import WebKit

/// A main-frame load failure shown over the page.
/// Codes are NSURL errors now (the old -105/-106 family is gone):
/// -1003 cannot find host, -1009 offline, -1200…-1202 certificate.
struct PageLoadError: Equatable {
    var code: Int
    var text: String
    var urlString: String

    var title: String {
        switch code {
        case -1003: return String(localized: "Can’t find this site")
        case -1009: return String(localized: "You’re offline")
        case -1001, -1005, -1011: return String(localized: "This site can’t be reached")
        case -1202 ... -1200: return String(localized: "Your connection isn’t private")
        default: return String(localized: "This page couldn’t load")
        }
    }
    var icon: String {
        switch code {
        case -1009: return "wifi.slash"
        case -1202 ... -1200: return "lock.trianglebadge.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }
}

/// One tab's live WebKit page and everything the UI observes about it.
///
/// Controllers outlive the SwiftUI views that show them: switching tabs only
/// moves `container` between hosts, so pages keep their scroll position,
/// form state and media. A WKWebView is created on first display and closed
/// only when its tab is closed, archived or unloaded for memory.
///
/// WebKit notes (replacing the old bridge contract):
/// - One WKWebsiteDataStore per Space, keyed by the Space's `dataStoreID`
///   (WKWebsiteDataStore(forIdentifier:)). That is the cookie isolation.
/// - Find is WKWebView.find(_:configuration:) on macOS: it reports only
///   matchFound, no native count/ordinal (UIFindInteraction is iOS-only).
///   The count shown in the find bar comes from a JS count of the same
///   text, and the ordinal is this controller's own running index.
/// - The context menu is WKWebView's default menu for now; the old
///   custom menu (Open in Peek/Split, Copy Link, Inspect…) is not ported
///   in this batch.
/// - HTML5 fullscreen is handled inside WKWebView; `isFullscreen` here
///   only tracks the old store toggle and stays false unless a page
///   explicitly exits via exitFullscreen().
@MainActor
final class WebTabController: NSObject, ObservableObject,
    WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    let tabID: UUID
    weak var store: BrowserStore?

    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var hoveredLink = ""
    @Published var loadError: PageLoadError?
    /// Set when the web content process died; cleared on next navigation.
    private var contentProcessTerminated = false
    #if DEBUG
    var terminatedFlagForDebug: Bool { contentProcessTerminated }
    #endif
    @Published private(set) var isFullscreen = false
    /// Camera or microphone in use (reported by the page's media script).
    @Published private(set) var isCapturing = false
    /// Audio or video playing (reported by the page's media script).
    @Published private(set) var isPlayingMedia = false
    /// Never unload or archive a tab in this state.
    var isBusy: Bool { isLoading || isCapturing || isPlayingMedia || isFullscreen }

    /// Stable view the WKWebView lives in; moved between pane hosts.
    let container: NSView
    private(set) var webView: WKWebView?
    /// Compatibility alias: old callers used `controller.browser`.
    var browser: WKWebView? { webView }
    private(set) var currentURLString: String
    /// Last time this tab was on screen (memory-saver eviction).
    var lastShownAt = Date()
    private var openLimiter = OpenRateLimiter()
    /// The Space's data-store identity.
    let dataStoreID: UUID

    private var observations: [NSKeyValueObservation] = []
    private var boostRules: [[String: String]] = []
    private var findOrdinal = 0
    private var findCount = 0
    /// Whether the content-blocker list is currently applied to this tab.
    private(set) var contentBlockingApplied = false
    /// URL the tab showed before the current load started. WKWebView.url
    /// already reports the download URL by the time a navigation becomes
    /// a download, so the model revert cannot read it back from the view.
    private var urlBeforeLoad: String?

    private struct DownloadRecord {
        var id: UInt32
        var fileName: String
        var urlString: String
        var fullPath: String
    }
    private var downloadsByObject: [ObjectIdentifier: DownloadRecord] = [:]
    /// Pending ask-per-file save panel, so a DEBUG probe can act on it.
    var pendingDownloadPanel: NSSavePanel?
    private var downloadObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var nextDownloadID: UInt32 = 1

    init(tab: BrowserTab, dataStoreID: UUID, store: BrowserStore) {
        self.tabID = tab.id
        self.store = store
        self.dataStoreID = dataStoreID
        self.currentURLString = tab.urlString
        let view = PageContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoresizingMask = [.width, .height]
        self.container = view
        super.init()
    }

    /// Creates the WKWebView the first time the tab is shown in a window.
    func ensureBrowser() {
        guard webView == nil else { return }
        let contentController = WKUserContentController()
        contentController.add(self, name: "toastpeekMedia")
        contentController.add(self, name: "toastpeekContext")
        contentController.add(self, name: "toastpeekHover")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        config.userContentController = contentController
        // Safari-style UA token (Safari's major version tracks macOS), so sites
        // do not treat the embedded WebKit as an unknown browser.
        config.applicationNameForUserAgent = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
        // Back/forward swipe gestures, like Safari.
        let wv = WKWebView(frame: container.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        // Safari's Develop menu can inspect this page (macOS 13.3+).
        wv.isInspectable = true
        container.addSubview(wv)
        webView = wv
        rebuildUserScripts()
        if let rules = store?.boostRules { setBoostRules(rules) }
        if store?.isContentBlockingEnabled == true {
            ContentBlocker.apply(to: wv.configuration.userContentController) { [weak self] applied in
                self?.contentBlockingApplied = applied
            }
        }
        if store?.isTabMuted(tabID) == true { setMuted(true) }
        loadInitial()
        observe(wv)
        if container.window != nil { focusPage() }
    }

    private func loadInitial() {
        guard let wv = webView else { return }
        let s = currentURLString
        if s.isEmpty || s == "about:blank" {
            wv.loadHTMLString("", baseURL: nil)
        } else if let url = URL(string: s), url.scheme != nil {
            wv.load(URLRequest(url: url))
        }
    }

    private func observe(_ wv: WKWebView) {
        observations = [
            wv.observe(\.title, options: [.new]) { [weak self] _, _ in
                guard let self, let title = wv.title, !title.isEmpty else { return }
                self.store?.webTitleChanged(tabID: self.tabID, title: title)
            },
            wv.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.progress = wv.estimatedProgress
            },
            wv.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.canGoBack = wv.canGoBack
            },
            wv.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.canGoForward = wv.canGoForward
            },
            wv.observe(\.url, options: [.new]) { [weak self] _, _ in
                guard let self, let url = wv.url else { return }
                let s = url.absoluteString
                if self.currentURLString != s {
                    self.currentURLString = s
                    self.store?.webAddressChanged(tabID: self.tabID, urlString: s)
                }
            },
        ]
    }

    var hasBrowser: Bool { webView != nil }

    func close() {
        observations = []
        downloadObservations = [:]
        downloadsByObject = [:]
        if let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekMedia")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekContext")
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekHover")
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        webView = nil
        container.removeFromSuperview()
        contentBlockingApplied = false
        isLoading = false
        progress = 0
    }

    // MARK: Commands (same names the store and menus already call)

    func load(_ urlString: String) {
        urlBeforeLoad = currentURLString
        currentURLString = urlString
        loadError = nil
        guard let wv = webView else { return }
        if urlString.hasPrefix("view-source:") { return }
        if urlString.isEmpty || urlString == "about:blank" {
            wv.loadHTMLString("", baseURL: nil)
            return
        }
        guard let url = URL(string: urlString) else { return }
        wv.load(URLRequest(url: url))
    }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        if loadError != nil || contentProcessTerminated {
            loadError = nil; contentProcessTerminated = false; load(currentURLString); return
        }
        webView?.reload()
    }
    func hardReload() {
        if contentProcessTerminated {
            contentProcessTerminated = false; load(currentURLString); return
        }
        webView?.reloadFromOrigin()
    }
    func stop() { webView?.stopLoading() }
    /// Print artefacts for one page. Built without ever showing a panel:
    /// PDF data via WKWebView.createPDF, then an NSPrintOperation over a
    /// PDFView holding it. Running the operation (which shows the panel)
    /// is the caller's decision; tests only ever call preparePrint.
    struct PrintPreparation {
        var pdfData: Data
        var pageCount: Int
        var firstPageSize: CGSize
        /// Constructs (never runs) the print operation for this PDF.
        func makePrintOperation() -> NSPrintOperation? {
            guard let doc = PDFDocument(data: pdfData) else { return nil }
            let view = PDFView(frame: CGRect(origin: .zero, size: firstPageSize))
            view.document = doc
            return NSPrintOperation(view: view)
        }
        var printOperationReady: Bool { makePrintOperation() != nil }
    }

    func preparePrint(completion: @escaping (PrintPreparation?) -> Void) {
        guard let wv = webView else { completion(nil); return }
        // Full-content rect so the PDF paginates like a real printout.
        wv.evaluateJavaScript("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") { [weak self] result, _ in
            guard let self, let wv = self.webView else { completion(nil); return }
            var rect = CGRect(x: 0, y: 0, width: 800, height: 600)
            if let arr = result as? [Double], arr.count == 2, arr[0] > 0, arr[1] > 0 {
                rect = CGRect(x: 0, y: 0, width: arr[0], height: arr[1])
            }
            let config = WKPDFConfiguration()
            config.rect = rect
            wv.createPDF(configuration: config) { result in
                guard case .success(let data) = result, !data.isEmpty,
                      let doc = PDFDocument(data: data), doc.pageCount > 0,
                      let page = doc.page(at: 0) else { completion(nil); return }
                let size = page.bounds(for: .mediaBox).size
                completion(PrintPreparation(pdfData: data, pageCount: doc.pageCount, firstPageSize: size))
            }
        }
    }

    /// Real user path: prepare the PDF, then run the print operation,
    /// which shows the print panel. Never called by tests: a panel's
    /// "Print" would send a real job to the user's printer.
    func printPage() {
        preparePrint { [weak self] prep in
            guard let self, let prep, let op = prep.makePrintOperation() else {
                self?.store?.toast = String(localized: "Couldn’t prepare this page for printing")
                return
            }
            _ = op.run()
        }
    }
    /// Save = download the current URL straight to the downloads folder.
    func savePage() { downloadURL(currentURLString) }
    /// WKWebView cannot open its inspector programmatically; inspectability
    /// is the feature (Safari Develop menu). This only confirms it.
    func showDevTools() {
        if let wv = webView, wv.isInspectable {
            store?.toast = String(localized: "Inspectable — use Safari’s Develop menu")
        }
    }
    var zoomPercent: Double { (webView?.pageZoom ?? 1) * 100 }
    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    private func announceZoom() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.store?.toast = "\(Int(self.zoomPercent.rounded()))%"
        }
    }
    func zoomIn() {
        guard let wv = webView else { return }
        let cur = wv.pageZoom
        wv.pageZoom = Self.zoomSteps.first(where: { $0 > cur + 0.001 }) ?? Self.zoomSteps.last!
        announceZoom()
    }
    func zoomOut() {
        guard let wv = webView else { return }
        let cur = wv.pageZoom
        wv.pageZoom = Self.zoomSteps.last(where: { $0 < cur - 0.001 }) ?? Self.zoomSteps.first!
        announceZoom()
    }
    func zoomReset() {
        webView?.pageZoom = 1.0
        announceZoom()
    }
    func find(_ text: String, forward: Bool, findNext: Bool) {
        guard let wv = webView, !text.isEmpty else { return }
        // Count first (JS, case-insensitive), then move the native highlight.
        let escaped: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: [text.lowercased()]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }()
        // `escaped` already includes its JSON quotes, like Boost.jsString.
        let countJS = "(document.body ? document.body.innerText.toLowerCase().split(\(escaped)).length - 1 : 0)"
        wv.evaluateJavaScript(countJS) { [weak self, weak wv] result, _ in
            guard let self, let wv else { return }
            let count = (result as? Int) ?? (result as? Double).map(Int.init) ?? 0
            self.findCount = max(0, count)
            let config = WKFindConfiguration()
            config.backwards = !forward
            config.wraps = true
            wv.find(text, configuration: config) { [weak self] found in
                guard let self else { return }
                if found.matchFound, self.findCount > 0 {
                    if findNext {
                        self.findOrdinal = forward
                            ? (self.findOrdinal % self.findCount) + 1
                            : (self.findOrdinal <= 1 ? self.findCount : self.findOrdinal - 1)
                    } else {
                        self.findOrdinal = 1
                    }
                    self.store?.updateFindResult(count: self.findCount, activeOrdinal: self.findOrdinal)
                } else if found.matchFound {
                    self.store?.updateFindResult(count: 0, activeOrdinal: 0)
                } else {
                    self.findOrdinal = 0
                    self.store?.updateFindResult(count: 0, activeOrdinal: 0)
                }
            }
        }
    }
    func stopFinding() {
        findOrdinal = 0
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges();") { _, _ in }
    }
    func setMuted(_ muted: Bool) {
        // WKWebView has no per-view mute switch; mute via JS media elements.
        // Full semantics: the current page gets a sweep plus a MutationObserver
        // (so media added later is muted too), and rebuildUserScripts adds the
        // mute user script so future documents load muted. Unmuting flips the
        // flag so the already-injected observer stops, and rebuild drops the
        // script for future documents.
        let js = muted
            ? "(function(){ window.__toastpeekMuted = true; document.querySelectorAll('video,audio').forEach(function(e){ e.muted = true; }); try { if (!window.__toastpeekMuteObserver) { window.__toastpeekMuteObserver = new MutationObserver(function(){ if (window.__toastpeekMuted) document.querySelectorAll('video,audio').forEach(function(e){ e.muted = true; }); }); var t = document.documentElement || document; window.__toastpeekMuteObserver.observe(t, { childList: true, subtree: true }); } } catch(e){} })();"
            : "(function(){ window.__toastpeekMuted = false; document.querySelectorAll('video,audio').forEach(function(e){ e.muted = false; }); })();"
        webView?.evaluateJavaScript(js) { _, _ in }
        rebuildUserScripts()
    }
    func setBoostRules(_ rules: [[String: String]]) {
        boostRules = rules
        rebuildUserScripts()
    }

    /// Reapplies the native extensions (content blocking + dark mode) to
    /// this tab. Called when a toggle changes. Open pages pick the change
    /// up on their next navigation or reload; new navigations get it at once.
    func refreshNativeExtensions() {
        guard let wv = webView else { return }
        rebuildUserScripts()
        ContentBlocker.remove(from: wv.configuration.userContentController)
        if store?.isContentBlockingEnabled == true {
            ContentBlocker.apply(to: wv.configuration.userContentController) { [weak self] applied in
                self?.contentBlockingApplied = applied
            }
        } else {
            ContentBlocker.remove(from: wv.configuration.userContentController)
            contentBlockingApplied = false
        }
    }
    func focusPage() {
        // Never re-focus a dead web view: after a renderer crash this
        // undoes the terminate handler's resign and swallows menu
        // shortcuts (batch 3: Cmd+R dead after select). Focus returns on
        // the next select once the page reloads (didStart clears flag).
        guard !contentProcessTerminated, let wv = webView else { return }
        container.window?.makeFirstResponder(wv)
    }
    func exitFullscreen() {
        webView?.evaluateJavaScript("if (document.fullscreenElement) document.exitFullscreen();") { _, _ in }
    }
    func fetchSource(_ completion: @escaping (String?) -> Void) {
        guard let wv = webView else { completion(nil); return }
        // Serialized DOM, not the original bytes (the old GetSource differed).
        wv.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            completion(result as? String)
        }
    }

    // MARK: JS bridge (Automation + future Boost injection)

    func executeJavaScript(_ script: String) {
        webView?.evaluateJavaScript(script) { _, _ in }
    }
    func evaluateJavaScript(_ script: String, completion: @escaping (Any?, Error?) -> Void) {
        guard let wv = webView else { completion(nil, nil); return }
        wv.evaluateJavaScript(script, completionHandler: completion)
    }
    func downloadURL(_ urlString: String) {
        guard let wv = webView, let url = URL(string: urlString) else { return }
        wv.startDownload(using: URLRequest(url: url)) { [weak self] download in
            download.delegate = self
        }
    }

    // MARK: User scripts (media state + Boosts)

    /// Mute observer for muted tabs: mutes existing media and anything
    /// added later, while window.__toastpeekMuted stays true. Unmuting flips
    /// the flag (see setMuted), so the observer stops muting without needing
    /// to remove an already-injected script.
    private static let muteScriptSource = """
    (function(){
      window.__toastpeekMuted = true;
      function muteAll(){ document.querySelectorAll('video,audio').forEach(function(e){ e.muted = true; }); }
      muteAll();
      try {
        var t = document.documentElement || document;
        new MutationObserver(function(){ if (window.__toastpeekMuted) muteAll(); })
          .observe(t, { childList: true, subtree: true });
      } catch(e){}
    })();
    """
    private static let mediaScriptSource = """
    (function(){
      function report(){
        var playing=false;
        document.querySelectorAll('video,audio').forEach(function(e){ if(!e.paused && !e.ended) playing=true; });
        try { window.webkit.messageHandlers.toastpeekMedia.postMessage(playing ? 'playing' : 'idle'); } catch(e){}
      }
      document.addEventListener('play', report, true);
      document.addEventListener('pause', report, true);
      document.addEventListener('ended', report, true);
      try {
        var md = navigator.mediaDevices;
        if (md && md.getUserMedia) {
          var orig = md.getUserMedia.bind(md);
          md.getUserMedia = function(c){
            return orig(c).then(function(stream){
              try { window.webkit.messageHandlers.toastpeekMedia.postMessage('capturing'); } catch(e){}
              stream.getTracks().forEach(function(t){
                t.addEventListener('ended', function(){
                  var any=false;
                  stream.getTracks().forEach(function(x){ if(x.readyState==='live') any=true; });
                  if(!any){ try { window.webkit.messageHandlers.toastpeekMedia.postMessage('idle'); } catch(e){} }
                });
              });
              return stream;
            });
          };
        }
      } catch(e){}
    })();
    """

    private func rebuildUserScripts() {
        guard let wv = webView else { return }
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.mediaScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: Self.contextScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: Self.hoverScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for rule in boostRules {
            guard let pattern = rule["pattern"], let source = rule["source"],
                  !pattern.isEmpty, !source.isEmpty else { continue }
            let patternJSON: String = {
                guard let data = try? JSONSerialization.data(withJSONObject: [pattern]),
                      let json = String(data: data, encoding: .utf8) else { return "\"\"" }
                // Array JSON ["x"] -> string literal "x" (same trick as Boost.jsString).
                return String(json.dropFirst().dropLast())
            }()
            let wrapped = """
            (function(){ var h = location.hostname.toLowerCase(); var p = \(patternJSON);
              if (!(h === p || h.endsWith('.' + p))) return;
              \(source) })();
            """
            ucc.addUserScript(WKUserScript(source: wrapped,
                                           injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        if let store, store.isDarkModeEnabled {
            ucc.addUserScript(WKUserScript(source: Self.darkModeScript(hosts: store.darkModeHosts,
                                                                       excluded: store.darkModeExcludedHosts),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let store, store.isTabMuted(tabID) {
            ucc.addUserScript(WKUserScript(source: Self.muteScriptSource,
                                           injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    /// Basic dark-mode CSS (background/text inversion; images and video are
    /// explicitly NOT inverted). Empty `hosts` means every site; otherwise
    /// only the listed hosts (exact or suffix match, like Boost patterns).
    private static func darkModeScript(hosts: [String], excluded: [String]) -> String {
        func json(_ list: [String]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: list),
                  let json = String(data: data, encoding: .utf8) else { return "[]" }
            return json
        }
        return """
        (function(){ var allowed = \(json(hosts)), skipped = \(json(excluded));
          var h = location.hostname.toLowerCase();
          function on(list){ return list.some(function(a){ a = a.toLowerCase();
            return h === a || h.endsWith('.' + a); }); }
          if (allowed.length > 0 && !on(allowed)) return;
          if (allowed.length === 0 && on(skipped)) return;
          var css = 'html{background:#1c1c1e!important;color-scheme:dark}'
            + 'body{background:#1c1c1e!important;color:#e5e5ea!important}'
            + 'a{color:#8ab4f8!important}a:visited{color:#c4a5fd!important}'
            + 'input,textarea,select{background:#2c2c2e!important;color:#e5e5ea!important;border-color:#48484a!important}'
            + 'img,video,canvas,svg,picture{filter:none!important}';
          var s = document.createElement('style'); s.id = 'toastpeek-dark'; s.textContent = css;
          (document.head || document.documentElement).appendChild(s);
          try { document.documentElement.style.colorScheme = 'dark'; } catch(e){}
        })();
        """
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "toastpeekHover" {
            let href = (message.body as? String) ?? ""
            if href != hoveredLink { hoveredLink = href }
            return
        }
        if message.name == "toastpeekContext" {
            handleContextMessage(message.body)
            return
        }
        guard message.name == "toastpeekMedia", let body = message.body as? String else { return }
        switch body {
        case "playing": isPlayingMedia = true
        case "capturing": isCapturing = true
        case "idle": isPlayingMedia = false; isCapturing = false
        default: break
        }
    }

    /// Reports the link under the pointer so the pane can show its address,
    /// like the status bubble in Safari. WebKit has no public hover
    /// callback, so a capture-phase mouseover/mouseout script feeds it.
    private static let hoverScriptSource = """
    (function(){
      var last = '';
      function send(v){ if (v === last) return; last = v;
        try { window.webkit.messageHandlers.toastpeekHover.postMessage(v); } catch(e){} }
      document.addEventListener('mouseover', function(e){
        var t = e.target, a = (t && t.closest) ? t.closest('a[href]') : null;
        var h = a && a.href ? String(a.href) : '';
        send(/^(https?|file|mailto):/i.test(h) ? h : '');
      }, true);
      document.addEventListener('mouseleave', function(){ send(''); }, true);
      window.addEventListener('blur', function(){ send(''); });
    })();
    """

    // MARK: - Page context menu (link right-click)

    /// Last link URL captured by the context-menu user script (DEBUG probe).
    var lastContextLink: String?

    /// Reports link right-clicks to native code. Links only: non-link
    /// right-clicks fall through untouched, so the default WebKit menu
    /// (text selection, images, etc.) keeps working. The native menu is
    /// shown by handleContextMessage; Inspect is deliberately absent —
    /// WebKit offers no public API to open the inspector programmatically.
    private static let contextScriptSource = """
    document.addEventListener('contextmenu', function(e){
      var t = e.target;
      var a = (t && t.closest) ? t.closest('a[href]') : null;
      if (!a || !a.href) return;
      try { window.webkit.messageHandlers.toastpeekContext.postMessage({href: a.href, x: e.clientX, y: e.clientY}); } catch(err) { return; }
      e.preventDefault();
      e.stopPropagation();
    }, true);
    """

    private func handleContextMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let href = dict["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        lastContextLink = href
        guard let wv = webView else { return }
        let x = (dict["x"] as? Double) ?? 0
        let y = (dict["y"] as? Double) ?? 0
        let zoom = wv.pageZoom > 0 ? wv.pageZoom : 1
        let point = NSPoint(x: x * zoom, y: wv.bounds.height - y * zoom)
        let menu = NSMenu()
        func item(_ title: String.LocalizationValue, _ action: Selector) -> NSMenuItem {
            let m = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: "")
            m.target = self
            m.representedObject = href
            return m
        }
        menu.addItem(item("Open in Peek", #selector(contextPeek(_:))))
        menu.addItem(item("Open in Split View", #selector(contextSplit(_:))))
        menu.addItem(item("Open in New Tab", #selector(contextNewTab(_:))))
        menu.addItem(item("Copy Link", #selector(contextCopy(_:))))
        menu.popUp(positioning: nil, at: point, in: wv)
    }

    /// Runs one page-context-menu action for a URL. Same code the menu items
    /// call; the DEBUG `ctxmenu` probe drives it directly. Returns false
    /// when the URL is rejected (non-web scheme or blocked target).
    @discardableResult
    func contextMenuAction(_ action: String, urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              PageOpenPolicy.isAllowedTarget(urlString) else { return false }
        switch action {
        case "peek":
            store?.onOpenPeek?(url)
        case "split":
            store?.openInSplit(urlString)
        case "newtab":
            store?.newTab(urlString: urlString)
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urlString, forType: .string)
        default:
            return false
        }
        return true
    }

    @objc private func contextPeek(_ sender: NSMenuItem) {
        if let href = sender.representedObject as? String { contextMenuAction("peek", urlString: href) }
    }

    @objc private func contextSplit(_ sender: NSMenuItem) {
        if let href = sender.representedObject as? String { contextMenuAction("split", urlString: href) }
    }

    @objc private func contextNewTab(_ sender: NSMenuItem) {
        if let href = sender.representedObject as? String { contextMenuAction("newtab", urlString: href) }
    }

    @objc private func contextCopy(_ sender: NSMenuItem) {
        if let href = sender.representedObject as? String { contextMenuAction("copy", urlString: href) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        loadError = nil
        contentProcessTerminated = false
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hoveredLink = ""
        isLoading = true
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url?.absoluteString, currentURLString != url {
            currentURLString = url
            store?.webAddressChanged(tabID: tabID, urlString: url)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url?.absoluteString, currentURLString != url {
            currentURLString = url
            store?.webAddressChanged(tabID: tabID, urlString: url)
        }
        fetchFavicon()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(with: error)
    }
    /// URLs recently turned into downloads (their "failed load" is the
    /// download itself, not an error page).
    private var recentDownloadURLs: Set<String> = []
    private func fail(with error: Error) {
        isLoading = false
        let ns = error as NSError
        // -999 = cancelled (a newer navigation superseded this one): not an error page.
        guard ns.code != NSURLErrorCancelled else { return }
        if let failing = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           recentDownloadURLs.contains(failing) {
            recentDownloadURLs.remove(failing)
            return
        }
        if let failingURL = ns.userInfo["NSErrorFailingURLKey"] as? URL,
           recentDownloadURLs.contains(failingURL.absoluteString) {
            recentDownloadURLs.remove(failingURL.absoluteString)
            return
        }
        // WebKit 102 "Frame load interrupted": a load cut off by another
        // navigation or by a download decision. Not an error page; the
        // next load clears any stale state anyway (didStartProvisional).
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
        loadError = PageLoadError(code: ns.code, text: ns.localizedDescription,
                                  urlString: currentURLString)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("ToastPeek web content process terminated for tab %@", tabID.uuidString)
        isCapturing = false
        isPlayingMedia = false
        contentProcessTerminated = true
        // A dead web view holding first-responder status swallows
        // nil-targeted menu actions (batch 3: Cmd+T / Cmd+R dead after a
        // crash while Cmd+S still worked). Resign it so shortcuts route
        // to the window/app again. Only when the dead view itself is
        // focused; any other focus (e.g. address bar) is left alone.
        if let window = webView.window, let fr = window.firstResponder as? NSView,
           fr == webView || fr.isDescendant(of: webView) {
            window.makeFirstResponder(nil)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        // Modified link clicks (WebKit leaves these to the app): Shift opens
        // Peek; Cmd or the middle button opens a tab below this one, in the
        // background unless Shift is also held (Chrome).
        if navigationAction.navigationType == .linkActivated, scheme == "http" || scheme == "https" {
            let mods = navigationAction.modifierFlags
            let newTab = mods.contains(.command) || navigationAction.buttonNumber == 2
            if mods.contains(.shift), !newTab, store?.shiftClickPeek == true {
                store?.onOpenPeek?(url)
                decisionHandler(.cancel)
                return
            }
            if newTab {
                store?.openFromPage(url.absoluteString, sourceTabID: tabID, background: !mods.contains(.shift))
                decisionHandler(.cancel)
                return
            }
        }
        switch scheme {
        case "http", "https", "file", "about", "blob":
            decisionHandler(.allow)
        case "mailto", "tel":
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        default:
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disp = http.allHeaderFields["Content-Disposition"] as? String,
           disp.lowercased().contains("attachment") {
            decisionHandler(.download)
            return
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        revertModelURLAfterDownload(downloadURL: navigationAction.request.url?.absoluteString)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        revertModelURLAfterDownload(downloadURL: navigationResponse.response.url?.absoluteString)
    }
    /// A download never commits, so the page stays where it was — but
    /// store.navigate already wrote the file URL into the tab model.
    /// Put the model back to the committed page, or a restarted tab
    /// would re-download instead of reopening its page.
    private func revertModelURLAfterDownload(downloadURL: String? = nil) {
        if let downloadURL { recentDownloadURLs.insert(downloadURL) }
        // Prefer the pre-load URL: at didBecomeDownload time webView.url
        // already equals the download URL, so reading it back reverts
        // nothing and retireDownloadOnlyTab then eats a real page tab.
        let prev = urlBeforeLoad ?? webView?.url?.absoluteString
        guard let prev, prev != currentURLString, prev != downloadURL else { return }
        currentURLString = prev
        store?.webAddressChanged(tabID: tabID, urlString: prev)
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let urlString = url.absoluteString
        guard PageOpenPolicy.isAllowedTarget(urlString) else {
            store?.notePopupBlocked(tabID: tabID)
            return nil
        }
        let verdict = PageOpenPolicy.verdict(for: urlString, userGesture: true, limiter: &openLimiter)
        guard verdict == .allow else {
            NSLog("ToastPeekPopupBlocked reason=%@ url=%@", "\(verdict)", String(urlString.prefix(200)))
            store?.notePopupBlocked(tabID: tabID)
            return nil
        }
        let mods = navigationAction.modifierFlags
        if mods.contains(.shift), !mods.contains(.command), store?.shiftClickPeek == true {
            store?.onOpenPeek?(url)
        } else {
            store?.openFromPage(urlString, sourceTabID: tabID, background: mods.contains(.command))
        }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }
    private func present(_ alert: NSAlert, completion: @escaping () -> Void) {
        if let window = container.window {
            alert.beginSheetModal(for: window) { _ in completion() }
        } else {
            _ = alert.runModal()
            completion()
        }
    }
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = container.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let originString = "\(origin.protocol)://\(origin.host)"
        var requested: UInt32 = 0
        switch type {
        case .camera: requested = MediaPermission.camera
        case .microphone: requested = MediaPermission.microphone
        case .cameraAndMicrophone: requested = MediaPermission.camera | MediaPermission.microphone
        @unknown default: break
        }
        guard let store else { decisionHandler(.deny); return }
        switch store.sitePermissions.decision(origin: originString, kind: .media, requested: requested) {
        case .allow: decisionHandler(.grant); return
        case .deny: decisionHandler(.deny); return
        case .ask: break
        }
        let names = SitePermission.featureNames(kind: .media, mask: requested)
        let features = ListFormatter.localizedString(byJoining: names.isEmpty ? ["device features"] : names)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Allow \(origin.host) to use your \(features)?")
        let canRemember = SitePermission.rememberable(kind: .media, requested: requested) != 0
        let remember = NSButton(checkboxWithTitle: String(localized: "Remember for this site"), target: nil, action: nil)
        remember.state = .on
        if canRemember { alert.accessoryView = remember }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        present(alert) { [weak self] response in
            let allow = response == .alertFirstButtonReturn
            if canRemember, remember.state == .on, let store = self?.store {
                var perms = store.sitePermissions
                perms.remember(origin: originString, kind: .media, requested: requested, allow: allow)
                store.sitePermissions = perms
                store.scheduleSave()
            }
            decisionHandler(allow ? .grant : .deny)
        }
    }

    // MARK: WKDownloadDelegate (direct landing, or save panel when ask is on)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = store?.resolvedDownloadsFolder
            ?? (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let clean = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        let base = clean.isEmpty ? "download" : clean
        if store?.askDownloadLocation == true {
            // Ask FIRST, before any download record exists: creating the
            // record upserts into the store, and upsert retires a fresh
            // download-only tab (removing this controller from the store's
            // controllers dict) — presenting the panel afterwards would
            // orphan it from probe control and detach it from its window.
            let panel = NSSavePanel()
            panel.nameFieldStringValue = base
            panel.directoryURL = URL(fileURLWithPath: folder)
            panel.canCreateDirectories = true
            pendingDownloadPanel = panel
            let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                self.pendingDownloadPanel = nil
                if response == .OK, let url = panel.url {
                    self.registerDownload(download, dest: url)
                    completionHandler(url)
                } else {
                    // Cancelled before starting: no record, no file.
                    completionHandler(nil)
                }
            }
            if let window = container.window {
                panel.beginSheetModal(for: window, completionHandler: done)
            } else {
                panel.begin(completionHandler: done)
            }
            return
        }
        var dest = URL(fileURLWithPath: folder).appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            dest = URL(fileURLWithPath: folder).appendingPathComponent(name)
            n += 1
        }
        registerDownload(download, dest: dest)
        completionHandler(dest)
    }

    /// Creates the download record, progress observation and store entry.
    private func registerDownload(_ download: WKDownload, dest: URL) {
        let id = nextDownloadID
        nextDownloadID += 1
        let key = ObjectIdentifier(download)
        downloadsByObject[key] = DownloadRecord(id: id, fileName: dest.lastPathComponent,
                                                urlString: download.originalRequest?.url?.absoluteString ?? "",
                                                fullPath: dest.path)
        downloadObservations[key] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self, let rec = self.downloadsByObject[key] else { return }
            let total = progress.totalUnitCount
            let received = progress.completedUnitCount
            let percent = total > 0 ? Int(Double(received) / Double(total) * 100) : -1
            self.store?.upsertDownload(fromTab: self.tabID, DownloadItemState(
                id: rec.id, fileName: rec.fileName, urlString: rec.urlString, fullPath: rec.fullPath,
                percent: percent, receivedBytes: received, totalBytes: total, state: "inProgress"))
        }
        store?.upsertDownload(fromTab: tabID, DownloadItemState(
            id: id, fileName: dest.lastPathComponent,
            urlString: download.originalRequest?.url?.absoluteString ?? "", fullPath: dest.path,
            percent: -1, receivedBytes: 0, totalBytes: 0, state: "inProgress"))
    }
    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let rec = downloadsByObject[key] else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: rec.fullPath)[.size] as? Int64) ?? 0
        store?.upsertDownload(fromTab: tabID, DownloadItemState(
            id: rec.id, fileName: rec.fileName, urlString: rec.urlString, fullPath: rec.fullPath,
            percent: 100, receivedBytes: size, totalBytes: size, state: "completed"))
        downloadObservations[key] = nil
        downloadsByObject[key] = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let rec = downloadsByObject[key] else { return }
        store?.upsertDownload(fromTab: tabID, DownloadItemState(
            id: rec.id, fileName: rec.fileName, urlString: rec.urlString, fullPath: rec.fullPath,
            percent: -1, receivedBytes: 0, totalBytes: 0, state: "cancelled"))
        downloadObservations[key] = nil
        downloadsByObject[key] = nil
    }

    // MARK: Certificate errors: session-scoped "Visit Anyway"

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let host = challenge.protectionSpace.host as String?,
           store?.certExceptions.contains(host) == true,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Explicit user action from the cert error page: trust this host for the
    /// rest of the session (all tabs), then retry. Session-scoped only,
    /// host-exact, never persisted and never applied without the user
    /// pressing the button.
    func proceedAnyway() {
        let target = loadError?.urlString ?? currentURLString
        if let host = URL(string: target)?.host, !host.isEmpty {
            store?.certExceptions.insert(host)
        }
        loadError = nil
        load(target)
    }

    // MARK: Favicon (WKWebView reports none; fetch the page's icon link)

    private func fetchFavicon() {
        guard let wv = webView, let host = URL(string: currentURLString)?.host else { return }
        wv.evaluateJavaScript(
            "(()=>{var l=document.querySelector('link[rel~=\"icon\"]');return l?l.href:'';})()"
        ) { [weak self] result, _ in
            guard let self else { return }
            var candidates: [URL] = []
            if let href = result as? String, let u = URL(string: href) { candidates.append(u) }
            if let origin = URL(string: self.currentURLString),
               let base = URL(string: "/", relativeTo: origin)?.absoluteURL {
                candidates.append(base.appendingPathComponent("favicon.ico"))
            }
            self.fetchFaviconCandidate(candidates, host: host)
        }
    }
    private func fetchFaviconCandidate(_ candidates: [URL], host: String) {
        guard let url = candidates.first else { return }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            if let data, !data.isEmpty {
                DispatchQueue.main.async { FaviconStore.shared.store(data, forHost: host) }
            } else {
                self.fetchFaviconCandidate(Array(candidates.dropFirst()), host: host)
            }
        }.resume()
    }
}

/// Thin Swift front for per-Space WebKit data (moved here from
/// BrowserStore so the WebKit import lives in the engine layer).
enum BrowserEngineBridge {
    static func clearBrowsingData(dataStoreID: UUID) {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast) {}
    }
}

/// Page host view. Its color shows until the page paints, so it follows
/// the window appearance instead of flashing white in dark mode.
final class PageContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
