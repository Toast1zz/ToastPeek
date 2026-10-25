import SwiftUI
import AppKit
import PDFKit
import WebKit
import CryptoKit

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
    WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
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
    var isBusy: Bool { isLoading || isCapturing || isPlayingMedia || isFullscreen || hasUnsubmittedInput || store?.downloadManager.hasActiveDownloads(for: tabID) == true }

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

    var pendingDownloadPanel: NSSavePanel? { store?.downloadManager.pendingPanel(for: tabID) }
    private var childConfiguration: WKWebViewConfiguration?
    private(set) var hasCommittedPage = false
    private var committedURL: String?
    private var navigationGeneration = 0
    private var findGeneration = 0
    private var faviconTask: Task<Void, Never>?
    private var extensionGeneration = 0
    private var printJobs: [UUID: NativePrintJob] = [:]
    private var certificateChallenges: [String: String] = [:]
    private var pendingCertificateOrigin: String?
    private var pendingCertificateKey: String?
    private var usedCertificateException = false
    var isSecureConnection: Bool {
        webView?.url?.scheme == "https" && webView?.hasOnlySecureContent == true && !usedCertificateException && loadError == nil
    }
    private var hasUnsubmittedInput = false
    private var playingFrames = Set<String>()
    private var knownFrames: [String: WKFrameInfo] = [:]
    private static let browserWorld = WKContentWorld.world(name: "ToastPeek.Browser")

    init(tab: BrowserTab, dataStoreID: UUID, store: BrowserStore, configuration: WKWebViewConfiguration? = nil) {
        self.childConfiguration = configuration
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
    func ensureBrowser(startNavigation: Bool = true) {
        guard webView == nil, store?.canLoadWebContent != false else { return }
        let contentController = WKUserContentController()
        contentController.add(self, contentWorld: Self.browserWorld, name: "toastpeekMedia")
        contentController.add(self, contentWorld: Self.browserWorld, name: "toastpeekContext")
        contentController.add(self, contentWorld: Self.browserWorld, name: "toastpeekHover")
        let config = childConfiguration ?? WKWebViewConfiguration()
        if childConfiguration == nil { config.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID) }
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
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
        childConfiguration = nil
        BrowserDiagnostics.record(["event": "browser-created", "tabID": tabID.uuidString, "startNavigation": startNavigation])
        rebuildUserScripts()
        if let rules = store?.boostRules { setBoostRules(rules) }
        observe(wv)
        refreshNativeExtensions { [weak self, weak wv] in
            guard let self, let wv, self.webView === wv else { return }
            BrowserDiagnostics.record(["event": "initial-policy-ready", "tabID": self.tabID.uuidString,
                                       "blockingApplied": self.contentBlockingApplied, "startNavigation": startNavigation])
            guard self.store?.isContentBlockingEnabled != true || self.contentBlockingApplied else { return }
            if startNavigation { self.loadInitial() }
        }
        if store?.isTabMuted(tabID) == true { setMuted(true) }
        if container.window != nil { focusPage() }
    }

    private func loadInitial() {
        guard let wv = webView else { return }
        let s = currentURLString
        BrowserDiagnostics.record(["event": "initial-navigation-request", "tabID": tabID.uuidString,
                                   "hasAddress": !s.isEmpty, "hasScheme": URL(string: s)?.scheme != nil])
        if s.isEmpty || s == "about:blank" {
            wv.loadHTMLString("", baseURL: nil)
        } else if let url = URL(string: s), url.scheme != nil {
            wv.load(URLRequest(url: url))
        }
    }

    private func observe(_ wv: WKWebView) {
        let update: @Sendable (@escaping @MainActor @Sendable (WebTabController, WKWebView) -> Void) -> Void = { [weak self, weak wv] body in
            Task { @MainActor [weak self, weak wv] in
                guard let self, let wv, self.webView === wv else { return }
                body(self, wv)
            }
        }
        observations = [
            wv.observe(\.title, options: [.new]) { _, _ in update { c, v in
                if let title = v.title, !title.isEmpty { c.store?.webTitleChanged(tabID: c.tabID, title: title) }
            } },
            wv.observe(\.estimatedProgress, options: [.new]) { _, _ in update { $0.progress = $1.estimatedProgress } },
            wv.observe(\.canGoBack, options: [.new]) { _, _ in update { $0.canGoBack = $1.canGoBack } },
            wv.observe(\.canGoForward, options: [.new]) { _, _ in update { $0.canGoForward = $1.canGoForward } },
            wv.observe(\.url, options: [.new]) { _, _ in update { c, v in
                guard let url = v.url?.absoluteString, c.currentURLString != url else { return }
                c.currentURLString = url
                c.store?.webAddressChanged(tabID: c.tabID, urlString: url)
            } },
            wv.observe(\.cameraCaptureState, options: [.new]) { _, _ in update { c, v in c.updateCaptureState(v) } },
            wv.observe(\.microphoneCaptureState, options: [.new]) { _, _ in update { c, v in c.updateCaptureState(v) } },
            wv.observe(\.fullscreenState, options: [.new]) { _, _ in update { c, v in c.isFullscreen = v.fullscreenState != .notInFullscreen } },
        ]
    }

    private func updateCaptureState(_ view: WKWebView) {
        isCapturing = view.cameraCaptureState != .none || view.microphoneCaptureState != .none
    }

    func stopCapture() {
        webView?.setCameraCaptureState(.none, completionHandler: nil)
        webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
    }

    var hasBrowser: Bool { webView != nil }

    func recordPresentationEvent(_ event: String) {
        let owner = container.superview
        let snapshot: [String: Any] = [
            "event": event, "pid": ProcessInfo.processInfo.processIdentifier,
            "tabID": tabID.uuidString, "profileID": dataStoreID.uuidString,
            "navigation": navigationGeneration, "hasWindow": container.window != nil,
            "hasOwner": owner != nil, "containerFrame": NSStringFromRect(container.frame),
            "ownerBounds": NSStringFromRect(owner?.bounds ?? .zero),
            "webFrame": NSStringFromRect(webView?.frame ?? .zero),
            "hidden": container.isHidden, "alpha": container.alphaValue,
            "loading": isLoading, "progress": progress, "terminated": contentProcessTerminated,
        ]
        BrowserDiagnostics.record(snapshot)
    }

    private func repairPresentation() {
        guard let host = container.superview as? PaneHostView, host.controller === self,
              let window = host.window, store?.mayPresent(tabID: tabID, in: window) != false,
              host.bounds.width > 0, host.bounds.height > 0 else { return }
        container.frame = host.bounds
        webView?.frame = container.bounds
        container.needsLayout = true
        container.needsDisplay = true
        webView?.needsDisplay = true
    }

    func close() {
        faviconTask?.cancel()
        faviconTask = nil
        pendingUploadPanel?.cancel(nil)
        pendingUploadPanel = nil
        observations = []
        if let wv = webView {
            if let responder = wv.window?.firstResponder as? NSView,
               responder === wv || responder.isDescendant(of: wv) {
                wv.window?.makeFirstResponder(nil)
            }
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekMedia", contentWorld: Self.browserWorld)
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekContext", contentWorld: Self.browserWorld)
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "toastpeekHover", contentWorld: Self.browserWorld)
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        webView = nil
        navigationGeneration += 1
        findGeneration += 1
        extensionGeneration += 1
        playingFrames = []
        knownFrames = [:]
        isPlayingMedia = false
        isCapturing = false
        container.removeFromSuperview()
        contentBlockingApplied = false
        isLoading = false
        progress = 0
    }

    // MARK: Commands (same names the store and menus already call)

    func load(_ urlString: String) {
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
        repairPresentation()
        if webView?.url == nil { load(currentURLString) } else { webView?.reload() }
    }
    func hardReload() {
        if contentProcessTerminated {
            contentProcessTerminated = false; load(currentURLString); return
        }
        webView?.reloadFromOrigin()
    }
    func stop() { webView?.stopLoading() }
    /// Testable paginated print output using WebKit's native print operation.
    /// Save asynchronously to a temporary PDF without a printer or print panel.
    @MainActor
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
        guard let wv = webView, let window = container.window else { completion(nil); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("toastpeek-print-\(UUID()).pdf")
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = wv.printOperation(with: info)
        // WKPrintingView computes its page range asynchronously. Running a
        // panel-less operation synchronously on main can yield NSIntegerMax
        // pages before that callback arrives. Let AppKit print on its worker.
        operation.canSpawnSeparateThread = true
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let id = UUID()
        let job = NativePrintJob { [weak self] success in
            defer {
                try? FileManager.default.removeItem(at: url)
                self?.printJobs.removeValue(forKey: id)
            }
            guard success, let data = try? Data(contentsOf: url),
                  let doc = PDFDocument(data: data), let first = doc.page(at: 0) else { completion(nil); return }
            completion(PrintPreparation(pdfData: data, pageCount: doc.pageCount,
                                        firstPageSize: first.bounds(for: .mediaBox).size))
        }
        printJobs[id] = job
        operation.runModal(for: window, delegate: job, didRun: #selector(NativePrintJob.didRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// The user path shows the native print panel. Tests exercise the same
    /// WebKit pagination through preparePrint without sending printer jobs.
    func printPage() {
        guard let wv = webView else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = true
        let operation = wv.printOperation(with: info)
        operation.canSpawnSeparateThread = true
        if let window = container.window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) }
    }

    func savePage() {
        guard let wv = webView else { return }
        wv.createWebArchiveData { [weak self] result in
            guard let self else { return }
            guard case .success(let data) = result else {
                self.store?.toast = String(localized: "This page could not be saved.")
                return
            }
            let panel = NSSavePanel()
            let title = (wv.title ?? "Page").replacingOccurrences(of: "/", with: "_")
            panel.nameFieldStringValue = String(title.prefix(120)) + ".webarchive"
            panel.canCreateDirectories = true
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                guard response == .OK, let url = panel.url else { return }
                do { try data.write(to: url, options: .atomic) }
                catch { self.store?.toast = error.localizedDescription }
            }
            if let window = self.container.window { panel.beginSheetModal(for: window, completionHandler: finish) }
            else { panel.begin(completionHandler: finish) }
        }
    }
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
        findGeneration += 1
        let generation = findGeneration
        // Count first (JS, case-insensitive), then move the native highlight.
        let escaped: String = {
            guard let data = try? JSONSerialization.data(withJSONObject: [text.lowercased()]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }()
        // `escaped` already includes its JSON quotes, like Boost.jsString.
        let countJS = "(document.body ? document.body.innerText.toLowerCase().split(\(escaped)).length - 1 : 0)"
        wv.evaluateJavaScript(countJS) { [weak self, weak wv] result, _ in
            guard let self, let wv, self.findGeneration == generation else { return }
            let count = (result as? Int) ?? (result as? Double).map(Int.init) ?? 0
            self.findCount = max(0, count)
            let config = WKFindConfiguration()
            config.backwards = !forward
            config.wraps = true
            wv.find(text, configuration: config) { [weak self] found in
                guard let self, self.findGeneration == generation, self.store?.activeController === self else { return }
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
        findGeneration += 1
        findOrdinal = 0
        webView?.find("", configuration: WKFindConfiguration()) { _ in }
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges();") { _, _ in }
    }
    func setMuted(_ muted: Bool) {
        let script = """
        window.__toastpeekMuted = \(muted ? "true" : "false");
        document.querySelectorAll('video,audio').forEach(e=>{e.muted=window.__toastpeekMuted;});
        (window.__toastpeekAudioBuses||[]).forEach(bus=>{bus.gain.value=window.__toastpeekMuted?0:1;});
        """
        webView?.evaluateJavaScript(script) { _, _ in }
        for frame in knownFrames.values where !frame.isMainFrame {
            webView?.evaluateJavaScript(script, in: frame, in: .page) { _ in }
        }
        rebuildUserScripts()
    }
    func setBoostRules(_ rules: [[String: String]]) {
        boostRules = rules
        rebuildUserScripts()
    }
    func applyBoostStyles(_ boosts: [Boost]) {
        guard let wv = webView else { return }
        let values = boosts.map { ["id": "toastpeek-boost-" + $0.id.uuidString, "pattern": $0.normalizedPattern, "css": $0.css] }
        guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
        let script = """
        (()=>{
          document.querySelectorAll('style[id^="toastpeek-boost-"]').forEach(e=>e.remove());
          const host=location.hostname.toLowerCase();
          for(const rule of \(json)){
            if(!rule.css||!rule.pattern||!(host===rule.pattern||host.endsWith('.'+rule.pattern)))continue;
            const style=document.createElement('style');style.id=rule.id;style.textContent=rule.css;
            (document.head||document.documentElement).appendChild(style);
          }
        })()
        """
        wv.evaluateJavaScript(script) { _, _ in }
        for frame in knownFrames.values where !frame.isMainFrame {
            wv.evaluateJavaScript(script, in: frame, in: .page) { _ in }
        }
    }

    /// Reapplies the native extensions (content blocking + dark mode) to
    /// this tab. Called when a toggle changes. Open pages pick the change
    /// up on their next navigation or reload; new navigations get it at once.
    func refreshNativeExtensions(completion: (() -> Void)? = nil) {
        guard let wv = webView else { completion?(); return }
        extensionGeneration += 1
        let generation = extensionGeneration
        rebuildUserScripts()
        ContentBlocker.remove(from: wv.configuration.userContentController)
        contentBlockingApplied = false
        if store?.isContentBlockingEnabled == true {
            ContentBlocker.prepare { [weak self, weak wv] list in
                guard let self, let wv, self.webView === wv else { completion?(); return }
                guard generation == self.extensionGeneration else {
                    self.refreshNativeExtensions(completion: completion)
                    return
                }
                if self.store?.isContentBlockingEnabled == true, let list {
                    ContentBlocker.install(list, to: wv.configuration.userContentController)
                    self.contentBlockingApplied = true
                } else if self.store?.isContentBlockingEnabled == true {
                    self.loadError = PageLoadError(code: NSURLErrorCannotLoadFromNetwork,
                        text: String(localized: "Content blocking could not be prepared. Try again."), urlString: self.currentURLString)
                }
                completion?()
            }
        } else { completion?() }
    }
    func focusPage() {
        // Never re-focus a dead web view: after a renderer crash this
        // undoes the terminate handler's resign and swallows menu
        // shortcuts (batch 3: Cmd+R dead after select). Focus returns on
        // the next select once the page reloads (didStart clears flag).
        guard !contentProcessTerminated, let wv = webView else { return }
        container.window?.makeFirstResponder(wv)
    }

    func canUnload(completion: @escaping (Bool) -> Void) {
        guard !isBusy, let wv = webView else { completion(!isBusy); return }
        wv.requestMediaPlaybackState { [weak self] state in
            guard let self else { completion(false); return }
            self.isPlayingMedia = state == .playing
            completion(!self.isBusy)
        }
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
    func evaluateJavaScript(_ script: String, completion: @escaping @MainActor @Sendable (Any?, Error?) -> Void) {
        guard let wv = webView else { completion(nil, nil); return }
        wv.evaluateJavaScript(script, completionHandler: completion)
    }
    func downloadURL(_ urlString: String) {
        guard let wv = webView, let url = URL(string: urlString) else { return }
        wv.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { download.cancel { _ in }; return }
            self.store?.downloadManager.adopt(download, from: self.tabID)
        }
    }

    // MARK: User scripts (media state + Boosts)

    /// Mute observer for muted tabs: mutes existing media and anything
    /// added later, while window.__toastpeekMuted stays true. Unmuting flips
    /// the flag (see setMuted), so the observer stops muting without needing
    /// to remove an already-injected script.
    private static let muteScriptSource = """
    (function(){
      if(window.__toastpeekMuteInstalled)return;window.__toastpeekMuteInstalled=true;
      window.__toastpeekAudioBuses=[];
      function enforce(){if(window.__toastpeekMuted)document.querySelectorAll('video,audio').forEach(e=>{if(!e.muted)e.muted=true;});}
      document.addEventListener('play',enforce,true);
      document.addEventListener('volumechange',enforce,true);
      new MutationObserver(enforce).observe(document,{childList:true,subtree:true});
      try{
        const buses=new WeakMap(),connect=AudioNode.prototype.connect,disconnect=AudioNode.prototype.disconnect;
        AudioNode.prototype.connect=function(target,...args){
          if(target===this.context.destination){
            let bus=buses.get(this.context);
            if(!bus){bus=this.context.createGain();bus.gain.value=window.__toastpeekMuted?0:1;
              connect.call(bus,target);buses.set(this.context,bus);window.__toastpeekAudioBuses.push(bus);}
            connect.call(this,bus,...args);return target;
          }
          return connect.call(this,target,...args);
        };
        AudioNode.prototype.disconnect=function(...args){
          if(args[0]===this.context.destination&&buses.has(this.context))args[0]=buses.get(this.context);
          return disconnect.apply(this,args);
        };
      }catch(e){}
    })();
    """
    private static let mediaScriptSource = """
    (function(){
      var id = String(Math.random()).slice(2), dirty = false;
      function report(){
        var playing = Array.from(document.querySelectorAll('video,audio')).some(e=>!e.paused&&!e.ended);
        try { window.webkit.messageHandlers.toastpeekMedia.postMessage({id:id, playing:playing, dirty:dirty}); } catch(e){}
      }
      document.addEventListener('play', report, true);
      document.addEventListener('pause', report, true);
      document.addEventListener('ended', report, true);
      document.addEventListener('DOMContentLoaded', report, true);
      document.addEventListener('input', function(e){ if(e.isTrusted){dirty=true;report();} }, true);
      document.addEventListener('submit', function(){dirty=false;report();}, true);
      window.addEventListener('pagehide', function(){dirty=false;try{window.webkit.messageHandlers.toastpeekMedia.postMessage({id:id,playing:false,dirty:false});}catch(e){}});
    })();
    """

    private func rebuildUserScripts() {
        guard let wv = webView else { return }
        let ucc = wv.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: Self.mediaScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.browserWorld))
        ucc.addUserScript(WKUserScript(source: Self.contextScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.browserWorld))
        ucc.addUserScript(WKUserScript(source: Self.hoverScriptSource,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.browserWorld))
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
        let muteSetup = "window.__toastpeekMuted=" + (store?.isTabMuted(tabID) == true ? "true;" : "false;") + Self.muteScriptSource
        ucc.addUserScript(WKUserScript(source: muteSetup, injectionTime: .atDocumentStart, forMainFrameOnly: false))
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
        guard let webView, message.webView === webView else { return }
        if message.name == "toastpeekHover" {
            let href = (message.body as? String) ?? ""
            if href != hoveredLink { hoveredLink = href }
            return
        }
        if message.name == "toastpeekContext" {
            handleContextMessage(message.body)
            return
        }
        guard message.name == "toastpeekMedia", let body = message.body as? [String: Any],
              let id = body["id"] as? String, let playing = body["playing"] as? Bool,
              let dirty = body["dirty"] as? Bool else { return }
        knownFrames[id] = message.frameInfo
        if playing { playingFrames.insert(id) } else { playingFrames.remove(id) }
        isPlayingMedia = !playingFrames.isEmpty
        webView.requestMediaPlaybackState { [weak self, weak webView] state in
            guard let self, let webView, self.webView === webView else { return }
            self.isPlayingMedia = state == .playing
        }
        if dirty { hasUnsubmittedInput = true }
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
      if (!e.isTrusted || !a || !a.href) return;
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
            if let callback = store?.onOpenPeekFromPage { callback(url, tabID) }
                else { store?.onOpenPeek?(url) }
        case "split":
            store?.openInSplit(urlString, sourceTabID: tabID)
        case "newtab":
            store?.openFromPage(urlString, sourceTabID: tabID, background: false)
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
        navigationGeneration += 1
        isLoading = true
        loadError = nil
        contentProcessTerminated = false
        usedCertificateException = false
        pendingCertificateKey = nil
        pendingCertificateOrigin = nil
        certificateChallenges = [:]
        recordPresentationEvent("navigation-start")
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hoveredLink = ""
        hasCommittedPage = true
        committedURL = webView.url?.absoluteString
        playingFrames = []
        knownFrames = [:]
        hasUnsubmittedInput = false
        isPlayingMedia = false
        if let url = committedURL { store?.webNavigationCommitted(tabID: tabID, urlString: url) }
        recordPresentationEvent("navigation-commit")
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
        repairPresentation()
        recordPresentationEvent("navigation-finish")
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
        let failedURL = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? URL(string: currentURLString)
        if (-1202 ... -1200).contains(ns.code), let failedURL {
            let origin = SiteOrigin.make(failedURL)
            pendingCertificateKey = certificateChallenges[origin]
            pendingCertificateOrigin = origin
        }
        loadError = PageLoadError(code: ns.code, text: ns.localizedDescription,
                                  urlString: failedURL?.absoluteString ?? currentURLString)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("ToastPeek web content process terminated for tab %@", tabID.uuidString)
        isCapturing = false
        isPlayingMedia = false
        contentProcessTerminated = true
        isLoading = false
        loadError = PageLoadError(code: WKError.webContentProcessTerminated.rawValue,
                                  text: String(localized: "The page process stopped. Reload to recover this page."), urlString: currentURLString)
        recordPresentationEvent("renderer-terminated")
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
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        // Modified link clicks (WebKit leaves these to the app): Shift opens
        // Peek; Cmd or the middle button opens a tab below this one, in the
        // background unless Shift is also held (Chrome).
        if navigationAction.navigationType == .linkActivated, scheme == "http" || scheme == "https" {
            let mods = navigationAction.modifierFlags
            let newTab = mods.contains(.command) || navigationAction.buttonNumber == 2
            if mods.contains(.shift), !newTab, store?.shiftClickPeek == true {
                if let callback = store?.onOpenPeekFromPage { callback(url, tabID) }
                else { store?.onOpenPeek?(url) }
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
        case "http", "https", "file", "about", "blob", "data":
            // Child views inherit a WebKit configuration and can start before
            // async rule compilation completes. Hold the first request until
            // this exact view's policy is ready.
            let allow = { [weak self, weak webView] in
                guard let self, let webView, self.webView === webView,
                      self.store?.canLoadWebContent != false else { decisionHandler(.cancel); return }
                guard self.store?.isContentBlockingEnabled != true || self.contentBlockingApplied else { decisionHandler(.cancel); return }
                decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
            }
            if store?.isContentBlockingEnabled == true, !contentBlockingApplied {
                refreshNativeExtensions(completion: allow)
            } else { allow() }
        case "mailto", "tel":
            if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.isMainFrame { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        default:
            if navigationAction.targetFrame?.isMainFrame == true {
                loadError = PageLoadError(code: NSURLErrorUnsupportedURL, text: String(localized: "This address type is not supported."), urlString: url.absoluteString)
            }
            decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
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
        store?.downloadManager.adopt(download, from: tabID)
        revertModelURLAfterDownload(downloadURL: navigationAction.request.url?.absoluteString)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        store?.downloadManager.adopt(download, from: tabID)
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
        let prev = committedURL
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
        // WebKit enforces gesture gating via javaScriptCanOpenWindowsAutomatically.
        // This callback has no public userGesture property; never invent one.
        guard openLimiter.allow() else {
            store?.notePopupBlocked(tabID: tabID)
            return nil
        }
        return store?.createChildWebView(from: tabID, urlString: urlString, configuration: configuration,
                                         background: navigationAction.modifierFlags.contains(.command))
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = store?.tab(tabID) { store?.close(tab) }
        else { webView.window?.performClose(nil) }
    }

    private var pendingUploadPanel: NSOpenPanel?
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard let window = container.window, window.attachedSheet == nil else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        pendingUploadPanel = panel
        let generation = navigationGeneration
        panel.beginSheetModal(for: window) { [weak self, weak webView] response in
            self?.pendingUploadPanel = nil
            guard let self, let webView, self.webView === webView,
                  self.navigationGeneration == generation, self.store?.canLoadWebContent == true else {
                completionHandler(nil); return
            }
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        present(alert, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
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
        } else { completion() }
    }
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = container.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else { completion(.alertSecondButtonReturn) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let originString = SiteOrigin.make(scheme: origin.protocol, host: origin.host, port: origin.port)
        var requested: UInt32 = 0
        switch type {
        case .camera: requested = MediaPermission.camera
        case .microphone: requested = MediaPermission.microphone
        case .cameraAndMicrophone: requested = MediaPermission.camera | MediaPermission.microphone
        @unknown default: break
        }
        guard self.webView === webView, let store, store.canLoadWebContent else { decisionHandler(.deny); return }
        switch store.sitePermissions.decision(origin: originString, profileID: dataStoreID, kind: .media, requested: requested) {
        case .allow: decisionHandler(.grant); return
        case .deny: decisionHandler(.deny); return
        case .ask: break
        }
        let names = SitePermission.featureNames(kind: .media, mask: requested)
        let features = ListFormatter.localizedString(byJoining: names.isEmpty ? ["device features"] : names)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Allow \(originString) to use your \(features)?")
        let canRemember = SitePermission.rememberable(kind: .media, requested: requested) != 0
        let remember = NSButton(checkboxWithTitle: String(localized: "Remember for this site"), target: nil, action: nil)
        remember.state = .on
        if canRemember { alert.accessoryView = remember }
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        let generation = navigationGeneration
        present(alert) { [weak self, weak webView] response in
            guard let self, let webView, self.webView === webView,
                  self.navigationGeneration == generation, self.store?.canLoadWebContent == true else {
                decisionHandler(.deny); return
            }
            let allow = response == .alertFirstButtonReturn
            if canRemember, remember.state == .on, let store = self.store {
                var perms = store.sitePermissions
                perms.remember(origin: originString, profileID: self.dataStoreID, kind: .media, requested: requested, allow: allow)
                store.sitePermissions = perms
                store.scheduleSave()
            }
            decisionHandler(allow ? .grant : .deny)
        }
    }

    // MARK: Certificate errors: session-scoped "Visit Anyway"

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificate.first else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        let origin = SiteOrigin.make(scheme: challenge.protectionSpace.protocol ?? "https",
                                     host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
        let key = dataStoreID.uuidString + "|" + origin + "|" + fingerprint
        if certificateChallenges.count < 8 { certificateChallenges[origin] = key }
        if let target = URL(string: currentURLString), SiteOrigin.make(target) == origin {
            pendingCertificateKey = key
            pendingCertificateOrigin = origin
        }
        if store?.certExceptions.contains(key) == true {
            usedCertificateException = true
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    /// Explicit user action from the cert error page: trust this host for the
    /// rest of the session (all tabs), then retry. Session-scoped only,
    /// host-exact, never persisted and never applied without the user
    /// pressing the button.
    func proceedAnyway() {
        let target = loadError?.urlString ?? currentURLString
        guard let key = pendingCertificateKey, let error = loadError,
              let targetURL = URL(string: target), SiteOrigin.make(targetURL) == pendingCertificateOrigin,
              (-1202 ... -1200).contains(error.code) else { return }
        store?.certExceptions.insert(key)
        loadError = nil
        load(target)
    }

    // MARK: Favicon (WKWebView reports none; fetch the page's icon link)

    private func fetchFavicon() {
        faviconTask?.cancel()
        guard let wv = webView, let pageURL = URL(string: currentURLString),
              let host = pageURL.host, ["http", "https"].contains(pageURL.scheme ?? "") else { return }
        let navigation = navigationGeneration
        let cacheGeneration = FaviconStore.shared.generation
        wv.evaluateJavaScript("(()=>{var l=document.querySelector('link[rel~=\"icon\"]');return l?l.href:'';})()") { [weak self] result, _ in
            guard let self, self.navigationGeneration == navigation else { return }
            var candidates: [URL] = []
            if let href = result as? String, let url = URL(string: href), ["http", "https"].contains(url.scheme ?? "") { candidates.append(url) }
            if let base = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL { candidates.append(base) }
            self.faviconTask = Task { @MainActor [weak self] in
                for url in candidates.prefix(2) {
                    guard !Task.isCancelled else { return }
                    if let data = await FaviconLoader.fetch(url), !Task.isCancelled {
                        guard let self, self.navigationGeneration == navigation else { return }
                        FaviconStore.shared.store(data, forHost: host, generation: cacheGeneration)
                        return
                    }
                }
            }
        }
    }

}

/// Thin Swift front for per-Space WebKit data (moved here from
/// BrowserStore so the WebKit import lives in the engine layer).
@MainActor
enum BrowserEngineBridge {
    static func clearBrowsingData(dataStoreID: UUID, completion: @escaping @MainActor @Sendable () -> Void = {}) {
        let store = WKWebsiteDataStore(forIdentifier: dataStoreID)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                         modifiedSince: .distantPast, completionHandler: completion)
    }
    static func deleteDataStore(dataStoreID: UUID) {
        WKWebsiteDataStore.remove(forIdentifier: dataStoreID) { error in
            if let error { NSLog("ToastPeek data store removal failed: %@", error.localizedDescription) }
        }
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

/// Retained by the controller until AppKit completes its asynchronous print job.
@MainActor
private final class NativePrintJob: NSObject {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        completion(success)
    }
}
