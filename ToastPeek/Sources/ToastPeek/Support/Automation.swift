#if DEBUG
// Test driver for local UI checks. Compiled into Debug builds only.
import AppKit
import WebKit

/// Test driver, inert unless the app is launched with `--automation <dir>`.
/// Commands are appended to `<dir>/in.txt` (one per line) and results land
/// in `<dir>/out.txt`. Mouse and key commands are synthesized NSEvents fed
/// through NSApp.sendEvent — the same dispatch path as real input, so hit
/// testing, SwiftUI gestures, menus and the engine all see them normally.
///
///   click X Y [cmd|shift|opt|ctrl…]   left click at window point (top-left origin)
///   rclick X Y | dclick X Y
///   drag X1 Y1 X2 Y2
///   scroll X Y DX DY                 precise (trackpad-style) scroll
///   key COMBO                        e.g. cmd+t, down, return, esc, ctrl+tab
///   type TEXT
///   shot PATH                        window capture (screencapture -l)
///   state                            JSON summary of store state
///   wait SECONDS
@MainActor
final class Automation {
    static var shared: Automation?
    /// DEBUG-only temp content-rule list (blocktest probe).
    private static var testBlockList: WKContentRuleList?
    private let dir: URL
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var queue: [String] = []
    private var resumeAt = Date.distantPast
    weak var store: BrowserStore?

    static func startIfRequested(store: BrowserStore) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--automation"), i + 1 < args.count else { return }
        let a = Automation(dir: URL(fileURLWithPath: args[i + 1]))
        a.store = store
        shared = a
    }

    private init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("in.txt").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent("out.txt").path, contents: Data())
        // Common modes: the tick must keep running while an NSMenu is
        // tracking (e.g. the page context menu), so a later `key esc` can
        // still be delivered and dismiss it. A default-mode timer stalls
        // for the whole menu session.
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        if let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent("in.txt")) {
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            try? h.close()
            if !data.isEmpty, let text = String(data: data, encoding: .utf8), let nl = text.lastIndex(of: "\n") {
                let complete = text[..<nl]
                offset += UInt64(complete.utf8.count + 1)
                queue += complete.split(separator: "\n").map(String.init)
            }
        }
        while Date() >= resumeAt, !queue.isEmpty {
            let line = queue.removeFirst()
            let result = run(line)
            write("\(line) => \(result)")
        }
    }

    private func write(_ s: String) {
        guard let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("out.txt")) else { return }
        h.seekToEndOfFile()
        h.write((s + "\n").data(using: .utf8) ?? Data())
        try? h.close()
    }

    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey }
    }

    /// Input commands need a key window, as real input does.
    private func ensureKey() {
        // If some window is already key (e.g. an open NSOpenPanel put key by
        // `panelkey`), keep it: re-keying the first ordered window would
        // steal key status back to the main window and misroute the key.
        if let kw = NSApp.keyWindow, kw.isVisible {
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        guard let w = NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func run(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return "empty" }
        let rest = parts.count > 1 ? parts[1] : ""
        let nums = rest.split(separator: " ").compactMap { Double($0) }
        let words = rest.split(separator: " ").map(String.init)
        if ["click", "rclick", "dclick", "key", "type", "drag"].contains(cmd) { ensureKey() }
        switch cmd {
        case "pageclick":
            // No WebKit equivalent: click injection is gone, and
            // synthetic clicks do not reach WKWebView in SSH sessions.
            // Click page elements with `js` instead (e.g. element.click()).
            return "unsupported-webkit"
        case "hit":
            guard nums.count >= 2, let w = window, let cv = w.contentView?.superview else { return "bad args" }
            let p = point(nums[0], nums[1], in: w)
            var v = cv.hitTest(cv.convert(p, from: nil))
            var chain: [String] = []
            while let cur = v, chain.count < 8 { chain.append(String(describing: type(of: cur))); v = cur.superview }
            return chain.joined(separator: " < ")
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            (NSApp.orderedWindows.first { $0.isVisible && $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
            return "key=\(NSApp.keyWindow != nil) active=\(NSApp.isActive)"
        case "panelcancel":
            // Programmatically press Cancel on a visible save/open panel.
            // If this yields importpanel-result but synthetic Esc does not,
            // the product path is fine and only Esc delivery is at fault.
            let pc = NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("Panel")
            }
            guard let p = pc as? NSSavePanel else { return "no panel" }
            p.cancel(nil)
            return "cancel sent"
        case "panelkey":
            // Make a visible save/open panel the key window so subsequent
            // `key` commands (e.g. esc, cmd+shift+g) reach the panel, not
            // the main window. Returns key status + panel title.
            let panel = NSApp.windows.first {
                $0.isVisible && String(describing: type(of: $0)).contains("Panel")
            }
            guard let p = panel else { return "no panel" }
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            return "key=\(p.isKeyWindow) title=\(p.title)"
        case "click", "rclick", "dclick":
            guard nums.count >= 2, let w = window else { return "bad args" }
            let mods = modifiers(words.dropFirst(2))
            let p = point(nums[0], nums[1], in: w)
            if cmd == "rclick" {
                post(.rightMouseDown, p, w, mods); post(.rightMouseUp, p, w, mods)
            } else {
                post(.mouseMoved, p, w, [])
                post(.leftMouseDown, p, w, mods, clicks: 1); post(.leftMouseUp, p, w, mods, clicks: 1)
                if cmd == "dclick" { post(.leftMouseDown, p, w, mods, clicks: 2); post(.leftMouseUp, p, w, mods, clicks: 2) }
            }
            return "ok"
        case "move":
            guard nums.count >= 2, let w = window else { return "bad args" }
            post(.mouseMoved, point(nums[0], nums[1], in: w), w, [])
            return "ok"
        case "drag":
            guard nums.count >= 4, let w = window else { return "bad args" }
            let a = point(nums[0], nums[1], in: w), b = point(nums[2], nums[3], in: w)
            post(.leftMouseDown, a, w, [], clicks: 1)
            for step in 1...12 {
                let t = CGFloat(step) / 12
                post(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), w, [])
            }
            post(.leftMouseUp, b, w, [], clicks: 1)
            return "ok"
        case "scroll":
            guard nums.count >= 4, let w = window else { return "bad args" }
            let p = point(nums[0], nums[1], in: w)
            let screen = w.convertPoint(toScreen: p)
            let flipped = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            for phase in [CGScrollPhase.began, .changed, .changed, .changed, .ended] {
                guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(nums[3] / 3), wheel2: Int32(nums[2] / 3), wheel3: 0) else { continue }
                e.location = flipped
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
                if let ns = NSEvent(cgEvent: e) { NSApp.sendEvent(ns) }
            }
            return "ok"
        case "key":
            guard let w = window else { return "no window" }
            return key(rest, w)
        case "type":
            guard let w = window else { return "no window" }
            for ch in rest { typeChar(String(ch), w) }
            return "ok"
        case "shot":
            guard let w = window else { return "no window" }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", rest]
            try? task.run()
            task.waitUntilExit()
            return "ok \(Int(w.frame.width))x\(Int(w.frame.height))"
        case "wait":
            resumeAt = Date().addingTimeInterval(nums.first ?? 0.5)
            return "ok"
        case "ageall":
            guard let store else { return "no store" }
            let past = Date().addingTimeInterval(-(nums.first ?? 13) * 3600)
            for i in store.tabs.indices where store.tabs[i].kind == .today {
                store.tabs[i].lastVisitedAt = past
            }
            return "ok aged"
        case "runarchive":
            guard let store else { return "no store" }
            store.runAutoArchive()
            return "archived=\(store.archived.count)"
        case "archived":
            guard let store else { return "no store" }
            return store.archived.map { $0.displayTitle }.joined(separator: ";")
        case "mutetab":
            guard let store, let t = store.selectedTab else { return "no tab" }
            store.toggleTabMuted(t)
            return "muted=\(store.isTabMuted(t))"
        case "mutestate":
            guard let store, let t = store.selectedTab else { return "no tab" }
            return "muted=\(store.isTabMuted(t))"
        case "dlpanel":
            // The download's controller is not necessarily the selected tab's
            // (a fresh newtab may not be selected yet), so scan all controllers.
            // Sheets must be ended via NSApp.endSheet, not the ok:/cancel:
            // actions (ok: on a sheet stalls the Automation tick).
            guard let store else { return "no store" }
            guard let panel = store.controllers.values.compactMap({ $0.pendingDownloadPanel }).first else { return "no panel" }
            let ok = words.first == "ok"
            if ok, words.count > 1 { panel.nameFieldStringValue = words.dropFirst().joined(separator: " ") }
            if panel.sheetParent != nil {
                NSApp.endSheet(panel, returnCode: (ok ? NSApplication.ModalResponse.OK : .cancel).rawValue)
            } else if ok {
                panel.ok(nil)
            } else {
                panel.cancel(nil)
            }
            return "ok"
        case "endsheet":
            // Scan all windows: once a sheet is up, the key window may be
            // the sheet itself, so keyWindow.attachedSheet is nil.
            guard let w = NSApp.windows.first(where: { $0.attachedSheet != nil }), let sheet = w.attachedSheet else { return "no sheet" }
            let code: NSApplication.ModalResponse
            switch words.first {
            case "ok": code = .OK
            case "cancel": code = .cancel
            case "first": code = .alertFirstButtonReturn
            default: code = .alertSecondButtonReturn
            }
            NSApp.endSheet(sheet, returnCode: code.rawValue)
            return "ok"
        case "clearall":
            guard let store else { return "no store" }
            let before = "history=\(store.history.count) archived=\(store.archived.count) downloads=\(store.downloads.count) perms=\(store.sitePermissions.count)"
            store.clearBrowsingData()
            let after = "history=\(store.history.count) archived=\(store.archived.count) downloads=\(store.downloads.count) perms=\(store.sitePermissions.count)"
            return "before \(before) after \(after)"
        case "permstate":
            guard let store else { return "no store" }
            guard let p = store.sitePermissions.first(where: { $0.origin == rest }) else { return "none" }
            return "mediaAllowed=\(p.mediaAllowed) mediaDenied=\(p.mediaDenied) promptAllowed=\(p.promptAllowed) promptDenied=\(p.promptDenied)"
        case "permset":
            guard let store, words.count >= 4 else { return "bad args" }
            let kind: PermissionKind = words[1] == "prompt" ? .prompt : .media
            let allow = words[2] == "allow"
            let mask = UInt32(words[3]) ?? 0
            store.sitePermissions.remember(origin: words[0], kind: kind, requested: mask, allow: allow)
            store.scheduleSave()
            return "ok"
        case "spaceswitch":
            guard let store, let sp = store.spaces.first(where: { $0.name == rest }) else { return "no space" }
            store.switchSpace(to: sp.id)
            return "ok current=\(sp.name)"
        case "spacenew":
            guard let store else { return "no store" }
            store.addSpace(name: rest, icon: "folder", colorHex: "#7C6FF0")
            let sp = store.spaces.last!
            return "ok id=\(sp.id.uuidString) dataStore=\(sp.dataStoreID.uuidString)"
        case "spacedel":
            guard let store, let sp = store.spaces.first(where: { $0.name == rest }) else { return "no space" }
            let ds = sp.dataStoreID
            store.deleteSpace(sp.id)
            return "ok dataStore=\(ds.uuidString)"
        case "spacestate":
            guard let store else { return "no store" }
            return store.spaces.map { sp in
                "\(sp.name)|\(sp.icon)|\(sp.colorHex)|current=\(sp.id == store.currentSpaceID)"
            }.joined(separator: "; ")
        case "spaceedit":
            guard let store, words.count >= 3 else { return "bad args" }
            guard let sp = store.spaces.first(where: { $0.name == words[0] }) else { return "no space" }
            store.updateSpace(sp.id, name: sp.name, icon: words[1], colorHex: words[2])
            return "ok \(sp.name)|\(words[1])|\(words[2])"
        case "oldcookies":
            guard let uuid = UUID(uuidString: rest) else { return "bad uuid" }
            WKWebsiteDataStore(forIdentifier: uuid).httpCookieStore.getAllCookies { [weak self] cookies in
                self?.write("oldcookies-result count=\(cookies.count)")
            }
            return "pending"
        case "certproceed":
            guard let c = store?.activeController else { return "no controller" }
            c.proceedAnyway()
            return "ok"
        case "setask":
            guard let store else { return "no store" }
            store.askDownloadLocation = (rest == "1")
            return "ask=\(store.askDownloadLocation)"
        case "setdlfolder":
            guard let store else { return "no store" }
            store.downloadsFolder = rest
            return "dlfolder=\(rest)"
        case "dlpanels":
            guard let store else { return "no store" }
            return store.controllers.map { (id, c) in
                let t = store.tabs.first(where: { $0.id == id })
                return "\(t?.displayTitle ?? "?")|panel=\(c.pendingDownloadPanel != nil)"
            }.joined(separator: "; ")
        case "tabs":
            guard let store else { return "no store" }
            return store.tabs.filter { !$0.isArchived }.map { t in
                "\(t.displayTitle)|\(t.kind.rawValue)|ctl=\(store.controllers[t.id] != nil)"
            }.joined(separator: "; ")
        case "stopmodal":
            // Dismiss a runModal (app-modal) alert, e.g. a permission prompt
            // whose tab had no window to attach a sheet to.
            NSApp.stopModal(withCode: words.first == "first" ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            return "ok"
        case "state":
            return stateJSON()
        case "viewsource":
            // DEBUG-only probe for the native source viewer (ViewSourceView):
            // selected tab's fetched source length + head, or its fetch state.
            guard let store else { return "no store" }
            guard let t = store.selectedTab else { return "no tab" }
            if let text = store.viewSourceTexts[t.id] {
                let head = text.prefix(160).replacingOccurrences(of: "\n", with: "\\n")
                return "ok len=\(text.count) head=\(head)"
            }
            if store.viewSourceFailed.contains(t.id) { return "fetch failed" }
            if store.viewSourceRequested.contains(t.id) { return "fetch pending" }
            return "not requested"
        case "sheets":
            // Attached sheets (print/save dialogs) per visible window.
            return NSApp.windows.filter(\.isVisible).map {
                "\($0.title) sheet=\($0.attachedSheet.map { String(describing: type(of: $0)) } ?? "-")"
            }.joined(separator: "; ")
        case "boostnew":
            guard let store else { return "no store" }
            let host = store.selectedTab?.displayHost ?? "127.0.0.1"
            store.boosts.append(Boost(name: "B13 Probe", hostPattern: host))
            return "ok boosts=\(store.boosts.count) host=\(host)"
        case "boostjs":
            guard let store, !store.boosts.isEmpty else { return "no boost" }
            var b = store.boosts[store.boosts.count - 1]; b.js = rest
            store.boosts[store.boosts.count - 1] = b
            return "ok"
        case "boostcss":
            guard let store, !store.boosts.isEmpty else { return "no boost" }
            var b = store.boosts[store.boosts.count - 1]; b.css = rest
            store.boosts[store.boosts.count - 1] = b
            return "ok"
        case "boosttoggle":
            guard let store, !store.boosts.isEmpty else { return "no boost" }
            var b = store.boosts[store.boosts.count - 1]; b.isEnabled.toggle()
            store.boosts[store.boosts.count - 1] = b
            return "ok enabled=\(b.isEnabled)"
        case "boostdel":
            guard let store, let b = store.boosts.last else { return "no boost" }
            store.boosts.removeAll { $0.id == b.id }
            store.applyBoostsToOpenTabs(extraReloadPatterns: [b.hostPattern])
            return "ok boosts=\(store.boosts.count)"
        case "adoptpeek":
            guard let store, let pt = store.peekTabs.values.first else { return "no peek" }
            guard let space = store.spaces.first(where: { $0.name == rest }) else { return "no space" }
            store.adoptPeekTab(pt, intoSpace: space.id)
            return "ok adopted into \(space.name)"
        case "engine":
            guard let store, let e = SearchEngine(rawValue: rest) else { return "bad engine" }
            store.searchEngine = e
            return "ok engine=\(e.rawValue)"
        case "select":
            guard let store, let t = store.tabs.first(where: { !$0.isArchived && $0.displayTitle.localizedCaseInsensitiveContains(rest) })
            else { return "no tab" }
            store.select(t)
            return "ok \(t.displayTitle)"
        case "js":
            store?.activeController?.executeJavaScript(rest)
            return "ok"
        case "wkstate":
            guard let store, let c = store.activeController else { return "no controller" }
            let wv = c.webView
            return "url=\(c.currentURLString) loading=\(c.isLoading) progress=\(c.progress) back=\(c.canGoBack) fwd=\(c.canGoForward) zoom=\(Int(c.zoomPercent.rounded())) inspectable=\(wv?.isInspectable ?? false) hasWebView=\(wv != nil) dataStore=\(c.dataStoreID.uuidString) error=\(c.loadError.map { String($0.code) } ?? "-")"
        case "jseval":
            guard let c = store?.activeController else { return "no controller" }
            c.evaluateJavaScript(rest) { [weak self] result, error in
                let s: String
                if let error { s = "error=\(error.localizedDescription)" }
                else if let result { s = "\(result)".replacingOccurrences(of: "\n", with: "\\n") }
                else { s = "nil" }
                self?.write("jseval-result \(s)")
            }
            return "pending"
        case "downloads":
            guard let store else { return "no store" }
            if store.downloads.isEmpty { return "none" }
            return store.downloads.map { "\($0.fileName)|\($0.state)|\($0.fullPath)" }.joined(separator: "; ")
        case "newtab":
            guard let store else { return "no store" }
            store.newTab(urlString: rest)
            return "ok \(rest)"
        case "nav":
            guard let store, let t = store.selectedTab else { return "no tab" }
            store.navigate(t.id, to: rest)
            return "ok \(rest)"
        case "find":
            guard let store else { return "no store" }
            store.findText = rest
            store.performFind()
            return "ok find=\(rest)"
        case "findstate":
            guard let store else { return "no store" }
            return "find=\(store.findText):\(store.findMatchCount)/\(store.findActiveOrdinal)"
        case "settings":
            guard let tabs = NSApp.windows.compactMap({ $0.contentViewController as? NSTabViewController }).first
            else { return "no settings" }
            tabs.selectedTabViewItemIndex = Int(nums.first ?? 0)
            return "ok \(tabs.view.window?.windowNumber ?? 0)"
        case "brief":
            guard let store else { return "" }
            let sel = store.selectedTab.map { "\($0.displayTitle.prefix(30))[\($0.kind.rawValue)]" } ?? "none"
            return "space=\(store.currentSpace.name) sel=\(sel) today=\(store.today(in: store.currentSpaceID).count) pinned=\(store.pinned(in: store.currentSpaceID).count) archived=\(store.archived.count) live=\(store.controllers.count) sidebar=\(store.isSidebarVisible) bar=\(store.commandBarMode.map { "\($0)" } ?? "-") split=\(store.activeWindowState?.splitTabIDs.count ?? 0) full=\(store.activeWindowState?.fullscreenTabID != nil) win=\(NSApp.windows.filter(\.isVisible).count) playing=\(store.activeController?.isPlayingMedia ?? false) find=\(store.findText):\(store.findMatchCount)/\(store.findActiveOrdinal)"
        case "windows":
            return NSApp.windows.filter(\.isVisible).map { "\($0.title)|\(Int($0.frame.width))x\(Int($0.frame.height))|key=\($0.isKeyWindow)" }
                .joined(separator: "; ")
        case "onboarding":
            store?.showOnboarding = true
            return "ok"
        case "importsources":
            return ImportSources.detect().map { "\($0.name)|hist=\($0.history != nil)|blocked=\($0.blocked)" }.joined(separator: "; ")
        case "importrun":
            // DEBUG-only: the onboarding import path, run inline. `importrun <bundle id>`.
            guard let store, let src = ImportSources.detect().first(where: { $0.id == rest }) else { return "no source" }
            let p = ImportSources.read(src)
            let h = store.importHistory(p.history)
            return "read hist=\(p.history.count) -> added hist=\(h)"
        case "edge":
            // DEBUG-only probe: `edge X Y` (top-left origin) as the hidden sidebar's tracker sees it.
            guard nums.count >= 2, let w = window else { return "bad args" }
            NotificationCenter.default.post(name: SidebarRevealTracker.TrackerView.probePoint, object: w,
                                            userInfo: ["point": point(nums[0], nums[1], in: w)])
            return "ok"
        case "reorder":
            // DEBUG-only probe: `reorder <today|pinned|favorite> <title> [| <before title>]`.
            // Drives the same store call as a sidebar drop.
            guard let store else { return "no store" }
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let kind = TabKind(rawValue: parts[0]) else { return "usage" }
            let titles = parts[1].components(separatedBy: " | ")
            guard let dragged = store.tabs.first(where: { !$0.isArchived && $0.displayTitle.localizedCaseInsensitiveContains(titles[0]) })
            else { return "no tab" }
            let before = titles.count > 1
                ? store.tabs.first(where: { !$0.isArchived && $0.displayTitle.localizedCaseInsensitiveContains(titles[1]) })?.id : nil
            store.reorderTab(dragged, targetKind: kind, folderID: nil, insertBefore: before)
            return "ok today=[\(store.today(in: store.currentSpaceID).map { $0.displayTitle }.joined(separator: ","))] pinned=[\(store.pinned(in: store.currentSpaceID, folderID: nil).map { $0.displayTitle }.joined(separator: ","))] fav=[\(store.favorites.map { $0.displayTitle }.joined(separator: ","))]"
        case "folders":
            // DEBUG-only probe: folders with space + member titles.
            guard let store else { return "no store" }
            return store.folders.map { f in
                let sp = store.spaces.first(where: { $0.id == f.spaceID })?.name ?? "?"
                let members = store.pinned(in: f.spaceID, folderID: f.id).map { $0.displayTitle }.joined(separator: ",")
                return "\(f.name)|\(sp)|collapsed=\(f.isCollapsed)|members=[\(members)]"
            }.joined(separator: "; ")
        case "foldernew":
            guard let store else { return "no store" }
            let f = store.createFolder(name: rest)
            return "ok folder=\(f.name)"
        case "folderrename":
            guard let store else { return "no store" }
            let pair = rest.split(separator: "|", maxSplits: 1).map(String.init)
            guard pair.count == 2, let f = store.folders.first(where: { $0.name.localizedCaseInsensitiveContains(pair[0]) })
            else { return "no folder" }
            store.renameFolder(f, to: pair[1])
            return "ok folder=\(pair[1])"
        case "foldermove":
            guard let store else { return "no store" }
            let pair = rest.split(separator: "|", maxSplits: 1).map(String.init)
            guard pair.count == 2,
                  let t = store.tabs.first(where: { !$0.isArchived && $0.displayTitle.localizedCaseInsensitiveContains(pair[0]) }),
                  let f = store.folders.first(where: { $0.name.localizedCaseInsensitiveContains(pair[1]) })
            else { return "no tab/folder" }
            store.moveTabToFolder(t, folderID: f.id)
            let kind = store.tabs.first(where: { $0.id == t.id })?.kind.rawValue ?? "?"
            return "ok tab=\(t.displayTitle) folder=\(f.name) kind=\(kind)"
        case "folderunmove":
            guard let store else { return "no store" }
            guard let t = store.tabs.first(where: { !$0.isArchived && $0.displayTitle.localizedCaseInsensitiveContains(rest) })
            else { return "no tab" }
            store.moveTabToFolder(t, folderID: nil)
            let kind = store.tabs.first(where: { $0.id == t.id })?.kind.rawValue ?? "?"
            return "ok tab=\(t.displayTitle) kind=\(kind)"
        case "foldercollapse":
            guard let store else { return "no store" }
            guard let f = store.folders.first(where: { $0.name.localizedCaseInsensitiveContains(rest) })
            else { return "no folder" }
            store.toggleFolderCollapse(f)
            let c = store.folders.first(where: { $0.id == f.id })?.isCollapsed ?? false
            return "ok folder=\(f.name) collapsed=\(c)"
        case "folderdel":
            guard let store else { return "no store" }
            guard let f = store.folders.first(where: { $0.name.localizedCaseInsensitiveContains(rest) })
            else { return "no folder" }
            store.deleteFolder(f)
            return "ok folders=\(store.folders.count)"
        case "printprep":
            // PDF artefacts only: never runs the print panel, never prints.
            guard let c = store?.activeController else { return "no controller" }
            c.preparePrint { [weak self] prep in
                let s: String
                if let prep {
                    s = "pdfBytes=\(prep.pdfData.count) pages=\(prep.pageCount) w=\(Int(prep.firstPageSize.width)) h=\(Int(prep.firstPageSize.height)) printOp=\(prep.printOperationReady ? "ready" : "nil")"
                } else { s = "nil" }
                self?.write("printprep-result \(s)")
            }
            return "pending"
        case "blocktoggle":
            guard let store, let ext = store.extensions.first(where: { $0.path == BrowserStore.contentBlockerBuiltinPath }) else { return "no blocker" }
            store.setExtensionEnabled(ext, rest == "on")
            return "ok blocking=\(rest == "on")"
        case "blockstate":
            guard let store else { return "no store" }
            return "blocking=\(store.isContentBlockingEnabled) compiled=\(ContentBlocker.isCompiled) applied=\(store.activeController?.contentBlockingApplied ?? false)"
        case "blocktest":
            // DEBUG-only temp rule: block /ads/* on the local probe host, to
            // prove the mechanism without depending on real ad domains.
            guard let ucc = store?.activeController?.webView?.configuration.userContentController else { return "no controller" }
            let json = "[{\"trigger\":{\"url-filter\":\".*://127\\\\.0\\\\.0\\\\.1:[0-9]+/ads/.*\"},\"action\":{\"type\":\"block\"}}]"
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "toastpeek-test-block", encodedContentRuleList: json) { [weak self] list, error in
                if let list {
                    Self.testBlockList = list
                    ucc.add(list)
                }
                self?.write("blocktest-result \(list != nil ? "applied" : "error=\(error?.localizedDescription ?? "?")")")
            }
            return "pending"
        case "blockdefault":
            // Compiles the DEFAULT rule set with doubleclick.net swapped for
            // the local probe host, proving the default rule structure
            // blocks (the real list only matches ad domains, which cannot
            // be served locally).
            guard let ucc = store?.activeController?.webView?.configuration.userContentController else { return "no controller" }
            let json = ContentBlocker.rulesJSON
                .replacingOccurrences(of: "doubleclick\\\\.net", with: "127\\\\.0\\\\.0\\\\.1:[0-9]+")
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "toastpeek-test-default", encodedContentRuleList: json) { [weak self] list, error in
                if let list {
                    Self.testBlockList = list
                    ucc.add(list)
                }
                self?.write("blockdefault-result \(list != nil ? "applied" : "error=\(error?.localizedDescription ?? "?")")")
            }
            return "pending"
        case "blocktestoff":
            guard let ucc = store?.activeController?.webView?.configuration.userContentController else { return "no controller" }
            if let list = Self.testBlockList { ucc.remove(list) }
            Self.testBlockList = nil
            return "ok"
        case "darktoggle":
            guard let store, let ext = store.extensions.first(where: { $0.path == BrowserStore.darkModeBuiltinPath }) else { return "no dark" }
            store.setExtensionEnabled(ext, rest == "on")
            return "ok dark=\(rest == "on")"
        case "darkhosts":
            guard let store else { return "no store" }
            if rest == "clear" { store.setDarkModeHosts([]) } else { store.setDarkModeHosts(rest.split(separator: ",").map(String.init)) }
            return "ok hosts=\(store.darkModeHosts.joined(separator: ","))"
        case "darkstate":
            guard let store else { return "no store" }
            return "dark=\(store.isDarkModeEnabled) hosts=[\(store.darkModeHosts.joined(separator: ","))]"
        case "openpage":
            guard let store else { return "no store" }
            switch rest {
            case "history": store.openHistoryPage()
            case "archive": store.openArchivePage()
            case "downloads": store.openLibrary(.downloads)
            default: return "bad args"
            }
            return "ok history=\(store.showHistory) library=\(store.activeWindowState?.library?.rawValue ?? "-")"
        case "ctxcapture":
            return store?.activeController?.lastContextLink ?? "none"
        case "ctxmenu":
            let pair = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard pair.count == 2, let c = store?.activeController else { return "bad args" }
            return c.contextMenuAction(pair[0], urlString: pair[1]) ? "ok \(pair[0])" : "rejected"
        case "termflag":
            guard let store, let c = store.activeController else { return "no controller" }
            return "termflag=\(c.terminatedFlagForDebug)"
        case "doreload":
            guard let store else { return "no store" }
            guard let c = store.activeController else { return "no active controller" }
            c.reload()
            return "reload called"
        case "importfile":
            // DEBUG-only: run the shared post-panel import path on a file
            // directly. The panel keyboard flow cannot be driven under SSH
            // (synthetic keys never reach a begin() modal panel), so this
            // verifies parse -> store -> persist; panel picking itself is
            // a GUI-session check.
            guard let store else { return "no store" }
            let pair = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return "bad args" }
            let url = URL(fileURLWithPath: pair[1])
            if pair[0] == "history" {
                let r = ImportPanels.importHistoryFile(at: url, into: store)
                return "importfile history added=\(r.0) found=\(r.1)"
            }
            return "bad args"
        case "importpanel":
            guard let store else { return "no store" }
            if rest == "history" {
                ImportPanels.beginImportHistory(into: store) { [weak self] result in
                    if let result {
                        self?.write("importpanel-result history added=\(result.0) found=\(result.1)")
                    } else {
                        self?.write("importpanel-result history added=nil")
                    }
                }
                return "panel open"
            }
            return "bad args"
        case "flush":
            // DEBUG-only: force state.json to disk now,
            // so a relaunch reread does not depend on the 0.6 s debounce.
            guard let store else { return "no store" }
            store.flush()
            return "ok"
        default:
            return "unknown"
        }
    }

    private func point(_ x: Double, _ y: Double, in w: NSWindow) -> NSPoint {
        NSPoint(x: x, y: (w.contentView?.bounds.height ?? w.frame.height) - y)
    }

    private func modifiers<S: Sequence>(_ words: S) -> NSEvent.ModifierFlags where S.Element == String {
        var m: NSEvent.ModifierFlags = []
        for w in words {
            switch w {
            case "cmd": m.insert(.command)
            case "shift": m.insert(.shift)
            case "opt", "alt": m.insert(.option)
            case "ctrl": m.insert(.control)
            default: break
            }
        }
        return m
    }

    private func post(_ type: NSEvent.EventType, _ p: NSPoint, _ w: NSWindow, _ mods: NSEvent.ModifierFlags, clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        NSApp.sendEvent(e)
    }

    private static let keyCodes: [String: (UInt16, String)] = [
        "return": (36, "\r"), "esc": (53, "\u{1b}"), "tab": (48, "\t"), "space": (49, " "),
        "delete": (51, "\u{7f}"),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey).map(Character.init)!)),
        "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey).map(Character.init)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey).map(Character.init)!)),
        "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey).map(Character.init)!)),
        "a": (0, "a"), "s": (1, "s"), "d": (2, "d"), "f": (3, "f"), "h": (4, "h"), "g": (5, "g"),
        "z": (6, "z"), "x": (7, "x"), "c": (8, "c"), "v": (9, "v"), "b": (11, "b"), "q": (12, "q"),
        "w": (13, "w"), "e": (14, "e"), "r": (15, "r"), "y": (16, "y"), "t": (17, "t"),
        "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "6": (22, "6"), "5": (23, "5"),
        "=": (24, "="), "9": (25, "9"), "7": (26, "7"), "-": (27, "-"), "8": (28, "8"), "0": (29, "0"),
        "]": (30, "]"), "o": (31, "o"), "u": (32, "u"), "[": (33, "["), "i": (34, "i"), "p": (35, "p"),
        "l": (37, "l"), "j": (38, "j"), "k": (40, "k"), "n": (45, "n"), "m": (46, "m"),
        "\\": (42, "\\"), ",": (43, ","), ".": (47, "."), "/": (44, "/"),
    ]

    private func key(_ combo: String, _ w: NSWindow) -> String {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last, let (code, chars) = Self.keyCodes[name] else { return "unknown key" }
        let mods = modifiers(parts.dropLast())
        var shown = chars
        let shifted: [String: String] = ["=": "+", "]": "}", "[": "{", "-": "_", "1": "!", "\t": "\u{19}"]
        if mods.contains(.shift) {
            if chars.count == 1, chars.first?.isLetter == true { shown = chars.uppercased() }
            else if let s = shifted[chars] { shown = s }
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil,
                                           characters: shown, charactersIgnoringModifiers: mods.contains(.shift) ? shown : chars,
                                           isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(e)
        }
        return "ok"
    }

    private func typeChar(_ ch: String, _ w: NSWindow) {
        if let target = w.firstResponder as? NSTextView {
            target.insertText(ch, replacementRange: target.selectedRange())
            return
        }
        let code = Self.keyCodes[ch.lowercased()]?.0 ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil,
                                        characters: ch, charactersIgnoringModifiers: ch,
                                        isARepeat: false, keyCode: code) {
                NSApp.sendEvent(e)
            }
        }
    }

    private func stateJSON() -> String {
        guard let store else { return "{}" }
        func tabInfo(_ t: BrowserTab) -> [String: Any] {
            ["title": t.displayTitle, "kind": t.kind.rawValue, "url": t.urlString,
             "archived": t.isArchived, "loaded": store.controller(forTabID: t.id)?.hasBrowser ?? false]
        }
        let dict: [String: Any] = [
            "space": store.currentSpace.name,
            "spaces": store.spaces.map(\.name),
            "selected": store.selectedTab.map(tabInfo) ?? [:],
            "split": store.activeWindowState?.splitTabIDs.compactMap { store.tab($0)?.displayTitle } ?? [],
            "commandBar": store.commandBarMode.map { "\($0)" } ?? "closed",
            "sidebar": store.isSidebarVisible,
            "sidebarWidth": Int(store.sidebarWidth),
            "library": store.activeWindowState?.library?.rawValue ?? "",
            "downloadRecords": store.downloadRecords.map(\.fileName),
            "blockerExempt": store.blockerExemptHosts,
            "favorites": store.favorites.map(\.displayTitle),
            "pinned": store.pinned(in: store.currentSpaceID).map(\.displayTitle),
            "today": store.today(in: store.currentSpaceID).map(\.displayTitle),
            "archivedCount": store.archived.count,
            "live": store.controllers.count,
            "fullscreen": store.activeWindowState?.fullscreenTabID != nil,
            "windows": NSApp.windows.filter(\.isVisible).count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
#endif
