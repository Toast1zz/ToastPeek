import AppKit
import SwiftUI
import CoreServices // AEEventClass / keyDirectObject for the GURL handler

// Custom entry point. The delegate hosts SwiftUI in AppKit windows because
// SwiftUI's generated App cannot do that.

// @objc name is load-bearing: Info.plist's NSPrincipalClass is looked up in
// the ObjC runtime by bare name.
@objc(ToastPeekApplication)
final class ToastPeekApplication: NSApplication {

    /// AppKit won't quit while a window shows a sheet, so Cmd+Q, `kill` and
    /// the installer's quit would do nothing behind an open prompt. Close
    /// open sheets first (a permission prompt then counts as a one-time deny).
    override func terminate(_ sender: Any?) {
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        }
        super.terminate(sender)
    }
}

let delegate = ToastPeekAppDelegate()
// Take the shared instance THROUGH the subclass so the singleton is a
// ToastPeekApplication regardless of Info.plist lookup timing.
let app = ToastPeekApplication.shared
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

final class ToastPeekAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var store: BrowserStore = MainActor.assumeIsolated { BrowserStore() }
    /// Main browser windows share ONE store; each has its own selection.
    private var browserWindows: [NSWindow] = []
    private var windowStatesByWindow: [ObjectIdentifier: WindowTabState] = [:]
    private var peekWindows: [NSWindow] = []
    private var settingsWindow: NSWindow?
    private var tearOffInFlight = false
    private var isTerminating = false
    private let spacesMenu = NSMenu(title: String(localized: "Spaces"))
    /// Links that arrived before the first window existed.
    private var pendingURLs: [URL] = []
    private var didFinishLaunching = false

    private func installFileLogging() {
        let logFile = AppPaths.logs.appendingPathComponent("toastpeek.log")
        // Keep the log bounded: start fresh once it passes 5 MB.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size]) as? Int,
           size > 5_000_000 {
            try? FileManager.default.removeItem(at: logFile)
        }
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        _ = freopen(logFile.path, "a", stderr)
        NSLog("ToastPeek session start")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        installFileLogging()
        let args = CommandLine.arguments
        if args.contains("--force-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--force-light") { NSApp.appearance = NSAppearance(named: .aqua) }

        // http/https links from other apps arrive as GURL Apple Events.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(0x4755524C), andEventID: AEEventID(0x4755524C))
        installTerminationSignalHandler()
    }

    /// `kill` / `pkill` (SIGTERM) quits like Cmd+Q, so state is saved and
    /// the engine shuts down cleanly instead of being cut off.
    private var termSource: DispatchSourceSignal?
    private func installTerminationSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source
    }

    @MainActor
    @discardableResult
    private func makeBrowserWindow(preferredTabID: UUID? = nil) -> NSWindow {
        let windowState = store.makeWindowState(preferredTabID: preferredTabID)
        let hosting = NSHostingController(rootView: ContentView()
            .environmentObject(store)
            .environmentObject(windowState))
        hosting.sizingOptions = []
        let w = NSWindow(contentViewController: hosting)
        // Owned by browserWindows; AppKit must not also release it on close.
        w.isReleasedWhenClosed = false
        windowState.window = w
        windowStatesByWindow[ObjectIdentifier(w)] = windowState
        store.activeWindowState = windowState
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "ToastPeek"
        w.minSize = NSSize(width: 640, height: 420)
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        w.delegate = self
        if browserWindows.isEmpty {
            w.setFrameAutosaveName("ToastPeekMainWindow")
            if !w.setFrameUsingName("ToastPeekMainWindow") {
                w.setContentSize(NSSize(width: 1320, height: 860))
                w.center()
            }
        } else if let last = browserWindows.last {
            w.setFrame(last.frame.offsetBy(dx: 28, dy: -28), display: false)
        }
        browserWindows.append(w)
        // Mouse-moved events drive the hidden sidebar's edge reveal.
        w.acceptsMouseMovedEvents = true
        w.makeKeyAndOrderFront(nil)
        TrafficLights.place(in: w)
        return w
    }

    /// Peek: a small window for links from other apps. Read it, close it,
    /// or move it into a Space with the page as it is.
    @MainActor
    private func presentPeek(url: URL?) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.delegate = self
        let view = PeekWindowView(url: url, onClose: { [weak self, weak w] in
            guard let w else { return }
            self?.closePeek(w)
        }, onMoveToSpace: { [weak self, weak w] tab, spaceID in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.store.adoptPeekTab(tab, intoSpace: spaceID)
                self.focusMainWindow()
            }
            if let w { self.closePeek(w, intoSidebar: true) }
        })
        let hosting = NSHostingController(rootView: view.environmentObject(store))
        hosting.sizingOptions = []
        w.contentViewController = hosting
        w.setContentSize(NSSize(width: 860, height: 620))
        w.minSize = NSSize(width: 420, height: 300)
        if let key = NSApp.keyWindow, browserWindows.contains(key) {
            w.setFrameOrigin(NSPoint(x: key.frame.midX - 430, y: key.frame.midY - 300))
        } else {
            w.center()
        }
        peekWindows.append(w)
        showPeekAnimated(w)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Peek open / close animation

    /// Peek rises into place: it starts a little smaller and lower, fades in,
    /// and settles with a soft ease-out. Closing reverses it, quicker.
    @MainActor
    private func showPeekAnimated(_ w: NSWindow) {
        let final = w.frame
        let scale: CGFloat = 0.94
        let start = NSRect(x: final.midX - final.width * scale / 2,
                           y: final.midY - final.height * scale / 2 - 14,
                           width: final.width * scale, height: final.height * scale)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.makeKeyAndOrderFront(nil)
            return
        }
        w.alphaValue = 0
        w.setFrame(start, display: false)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().alphaValue = 1
            w.animator().setFrame(final, display: true)
        }
    }

    private var closingPeeks = Set<ObjectIdentifier>()

    /// Animates a Peek window out, then closes it. Safe to call twice.
    /// A plain close rolls the window up into its title bar and fades the
    /// last of it; opening the page in a Space instead shrinks the window
    /// toward the sidebar, where the new tab appears.
    @MainActor
    func closePeek(_ w: NSWindow, intoSidebar: Bool = false) {
        let id = ObjectIdentifier(w)
        guard !closingPeeks.contains(id) else { return }
        closingPeeks.insert(id)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.close()
            return
        }
        let f = w.frame
        let end: NSRect
        if intoSidebar, let main = browserWindows.first(where: { $0.isVisible }) {
            let size = NSSize(width: 150, height: 34)
            end = NSRect(x: main.frame.minX + 14, y: main.frame.maxY - 150, width: size.width, height: size.height)
        } else {
            // Roll up: keep the top edge, drop the height to the bar.
            let height: CGFloat = 38
            end = NSRect(x: f.minX + f.width * 0.03, y: f.maxY - height, width: f.width * 0.94, height: height)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = intoSidebar ? 0.34 : 0.26
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)
            w.animator().setFrame(end, display: true)
        }, completionHandler: { [weak w] in
            w?.close()
        })
        // The fade only takes the last stretch, so the fold itself is what reads.
        DispatchQueue.main.asyncAfter(deadline: .now() + (intoSidebar ? 0.18 : 0.12)) { [weak w] in
            guard let w else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                w.animator().alphaValue = 0
            }
        }
    }

    /// The red button and ⌘W go through here: Peek windows fade out first.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard peekWindows.contains(where: { $0 === sender }) else { return true }
        if closingPeeks.contains(ObjectIdentifier(sender)) { return true }
        MainActor.assumeIsolated { closePeek(sender) }
        return false
    }

    @MainActor
    private func focusMainWindow() {
        let target = browserWindows.first { $0.isKeyWindow } ?? browserWindows.first
        if let target {
            target.makeKeyAndOrderFront(nil)
        } else {
            makeBrowserWindow()
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        openExternal(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openExternal(url) }
    }

    private func openExternal(_ url: URL) {
        guard didFinishLaunching else { pendingURLs.append(url); return }
        MainActor.assumeIsolated {
            guard url.isFileURL || url.scheme == "http" || url.scheme == "https" else { return }
            if store.externalLinksInPeek {
                presentPeek(url: url)
            } else {
                if browserWindows.isEmpty { _ = makeBrowserWindow() }
                (browserWindows.first { $0.isKeyWindow } ?? browserWindows.last)?.makeKeyAndOrderFront(nil)
                store.newTab(urlString: url.absoluteString)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let ws = windowStatesByWindow[ObjectIdentifier(w)] else { return }
        MainActor.assumeIsolated { store.activeWindowState = ws }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let ws = windowStatesByWindow[ObjectIdentifier(w)] else { return }
        MainActor.assumeIsolated {
            ws.isWindowFullscreen = false
            store.windowDidExitFullscreen(ws)
        }
        TrafficLights.place(in: w)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let w = notification.object as? NSWindow,
              let ws = windowStatesByWindow[ObjectIdentifier(w)] else { return }
        MainActor.assumeIsolated { ws.isWindowFullscreen = true }
    }

    // AppKit lays the window buttons out again on resize; keep them on the
    // sidebar's top row.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, windowStatesByWindow[ObjectIdentifier(w)] != nil else { return }
        TrafficLights.place(in: w)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        if let ws = windowStatesByWindow.removeValue(forKey: ObjectIdentifier(w)) {
            MainActor.assumeIsolated { store.removeWindowState(ws) }
        }
        closingPeeks.remove(ObjectIdentifier(w))
        if peekWindows.contains(where: { $0 === w }) {
            // Release on the next turn, not inside the close notification:
            // tearing down the hosting controller nested in the closer's
            // stack let engine callbacks land in a draining autorelease pool.
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w else { return }
                self.peekWindows.removeAll { $0 === w }
            }
        }
        browserWindows.removeAll { $0 === w }
        if w === settingsWindow { settingsWindow = nil }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if browserWindows.isEmpty { MainActor.assumeIsolated { _ = makeBrowserWindow() } }
        return true
    }

    // Like every Mac browser: closing the last window keeps the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var peekHotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Read the icon from the bundle itself: IconServices keeps showing
            // the previous artwork for a bundle id until its cache is rebuilt.
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = icon
            }
            makeBrowserWindow()
            let hotKey = GlobalHotKey { [weak self] in
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    self?.presentPeek(url: nil)
                }
            }
            hotKey.setEnabled(store.peekHotkeyEnabled)
            store.onPeekHotkeyChanged = { [weak self, weak hotKey] in
                MainActor.assumeIsolated { hotKey?.setEnabled(self?.store.peekHotkeyEnabled ?? false) }
            }
            peekHotKey = hotKey
            #if DEBUG
            Automation.startIfRequested(store: store)
            #endif
            store.onOpenSettings = { [weak self] page in self?.openSettings(page: page) }
            store.onOpenPeek = { [weak self] url in MainActor.assumeIsolated { self?.presentPeek(url: url) } }
            store.onSpacesChanged = { [weak self] in self?.rebuildSpacesMenu() }
            store.onTearOffTab = { [weak self] tab in
                guard let self, !self.tearOffInFlight else { return }
                self.tearOffInFlight = true
                // One runloop turn later: never mutate windows inside the
                // drag session's own teardown.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        defer { self.tearOffInFlight = false }
                        let sources = self.store.windowStates.filter { $0.paneTabIDs.contains(tab.id) }
                        for ws in sources {
                            ws.splitTabIDs.removeAll { $0 == tab.id }
                            if ws.selectedTabID == tab.id {
                                ws.selectedTabID = self.store.today(in: self.store.currentSpaceID).first { $0.id != tab.id }?.id
                                    ?? self.store.pinned(in: self.store.currentSpaceID).first { $0.id != tab.id }?.id
                                ws.focusedPaneTabID = ws.selectedTabID
                            }
                        }
                        let w = self.makeBrowserWindow(preferredTabID: tab.id)
                        if let mouse = Optional(NSEvent.mouseLocation) {
                            w.setFrameTopLeftPoint(NSPoint(x: mouse.x - 120, y: mouse.y + 20))
                        }
                    }
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        installMenus()
        didFinishLaunching = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.store.presentStateLoadProblemIfNeeded()
            }
        }
        let pending = pendingURLs
        pendingURLs = []
        for url in pending { openExternal(url) }

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--open-url"), i + 1 < args.count {
            let urlString = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self.store.open(urlString) }
            }
        }
        if let i = args.firstIndex(of: "--peek-test"), i + 1 < args.count, let u = URL(string: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.openExternal(u) }
        }

    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { store.flush() }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        MainActor.assumeIsolated {
            store.flush()
            for id in Array(store.controllers.keys) { store.unload(id) }
        }
        for w in browserWindows + peekWindows { w.close() }
        browserWindows.removeAll()
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector, _ key: String,
                      _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let (key, mods) = MainActor.assumeIsolated { ShortcutStore.shared.resolve(action, key: key, mods: mods) }
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func installMenus() {
        let mainMenu = NSMenu()

        let appMenu = submenu(String(localized: "ToastPeek"), in: mainMenu)
        appMenu.addItem(withTitle: String(localized: "About ToastPeek"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "Settings…"), #selector(menuSettings), ","))
        appMenu.addItem(item(String(localized: "Make ToastPeek Default Browser"), #selector(menuMakeDefault), ""))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: String(localized: "Services"))
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide ToastPeek"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "Hide Others"),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: String(localized: "Quit ToastPeek"), action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self

        let file = submenu(String(localized: "File"), in: mainMenu)
        file.addItem(item(String(localized: "New Tab"), #selector(menuCommandBar), "t"))
        file.addItem(item(String(localized: "New Window"), #selector(menuNewWindow), "n"))
        file.addItem(item(String(localized: "New Peek Window"), #selector(menuNewPeek), "n", [.command, .option]))
        file.addItem(item(String(localized: "New Space…"), #selector(menuNewSpace), ""))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Open Location…"), #selector(menuOpenLocation), "l"))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Close Tab"), #selector(menuCloseTab), "w"))
        file.addItem(item(String(localized: "Close Window"), #selector(menuCloseWindow), "W", [.command, .shift]))
        file.addItem(item(String(localized: "Reopen Closed Tab"), #selector(menuRestoreArchived), "T", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Save Page As…"), #selector(menuSavePage), "s", [.command, .option]))
        file.addItem(item(String(localized: "Print…"), #selector(menuPrint), "p"))
        file.addItem(.separator())
        file.addItem(item(String(localized: "Import History…"), #selector(menuImportHistory), ""))

        let edit = submenu(String(localized: "Edit"), in: mainMenu)
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = edit.addItem(withTitle: String(localized: "Paste and Match Style"),
                                      action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Copy URL"), #selector(menuCopyURL), "C", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(String(localized: "Find…"), #selector(menuFind), "f"))
        edit.addItem(item(String(localized: "Find Next"), #selector(menuFindNext), "g"))
        edit.addItem(item(String(localized: "Find Previous"), #selector(menuFindPrevious), "G", [.command, .shift]))

        let view = submenu(String(localized: "View"), in: mainMenu)
        view.addItem(item(String(localized: "Toggle Sidebar"), #selector(menuToggleSidebar), "s"))
        view.addItem(item(String(localized: "Add Split View"), #selector(menuToggleSplit), "+", [.control, .shift]))
        view.addItem(item(String(localized: "Close Split View"), #selector(menuCloseSplit), ""))
        view.addItem(.separator())
        view.addItem(item(String(localized: "Reload Page"), #selector(menuReload), "r"))
        view.addItem(item(String(localized: "Hard Reload"), #selector(menuHardReload), "R", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item(String(localized: "Actual Size"), #selector(menuZoomReset), "0"))
        view.addItem(item(String(localized: "Zoom In"), #selector(menuZoomIn), "="))
        let zoomInAlt = item(String(localized: "Zoom In"), #selector(menuZoomIn), "+")
        zoomInAlt.isAlternate = false
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlt)
        view.addItem(item(String(localized: "Zoom Out"), #selector(menuZoomOut), "-"))
        view.addItem(.separator())
        let fullScreen = NSMenuItem(title: String(localized: "Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        view.addItem(.separator())
        let developer = NSMenu(title: String(localized: "Developer"))
        let developerItem = NSMenuItem(title: String(localized: "Developer"), action: nil, keyEquivalent: "")
        developerItem.submenu = developer
        developer.addItem(item(String(localized: "Developer Tools"), #selector(menuDevTools), "i", [.command, .option]))
        developer.addItem(item(String(localized: "View Source"), #selector(menuViewSource), "u", [.command, .option]))
        view.addItem(developerItem)

        let spacesItem = NSMenuItem(title: String(localized: "Spaces"), action: nil, keyEquivalent: "")
        spacesItem.submenu = spacesMenu
        mainMenu.addItem(spacesItem)
        rebuildSpacesMenu()

        let tabs = submenu(String(localized: "Tabs"), in: mainMenu)
        tabs.addItem(item(String(localized: "Next Tab"), #selector(menuNextTab), "\t", [.control]))
        tabs.addItem(item(String(localized: "Previous Tab"), #selector(menuPreviousTab), String(Character(UnicodeScalar(NSBackTabCharacter)!)), [.control, .shift]))
        let nextAlt = item(String(localized: "Next Tab"), #selector(menuNextTab), "}", [.command, .shift])
        nextAlt.isHidden = true; nextAlt.allowsKeyEquivalentWhenHidden = true
        tabs.addItem(nextAlt)
        let prevAlt = item(String(localized: "Previous Tab"), #selector(menuPreviousTab), "{", [.command, .shift])
        prevAlt.isHidden = true; prevAlt.allowsKeyEquivalentWhenHidden = true
        tabs.addItem(prevAlt)
        tabs.addItem(.separator())
        tabs.addItem(item(String(localized: "Pin / Unpin Tab"), #selector(menuPinTab), "d"))
        tabs.addItem(item(String(localized: "Add to Favorites"), #selector(menuFavoriteTab), "D", [.command, .shift]))
        tabs.addItem(item(String(localized: "Duplicate Tab"), #selector(menuDuplicateTab), ""))
        tabs.addItem(item(String(localized: "Mute Tab"), #selector(menuMuteTab), "m", [.command, .control]))
        tabs.addItem(.separator())
        tabs.addItem(item(String(localized: "Back"), #selector(menuBack), "["))
        tabs.addItem(item(String(localized: "Forward"), #selector(menuForward), "]"))
        tabs.addItem(.separator())
        for n in 1...9 {
            let i = item(n == 9 ? String(localized: "Last Tab") : String(localized: "Tab \(n)"), #selector(menuSelectTabIndex(_:)), "\(n)")
            i.tag = n - 1
            i.isHidden = true
            i.allowsKeyEquivalentWhenHidden = true
            tabs.addItem(i)
        }
        tabs.addItem(.separator())
        tabs.addItem(item(String(localized: "History"), #selector(menuHistory), "y"))
        tabs.addItem(item(String(localized: "Library"), #selector(menuLibrary), ""))
        tabs.addItem(item(String(localized: "Archived Tabs"), #selector(menuArchive), ""))
        tabs.addItem(item(String(localized: "Downloads"), #selector(menuDownloads), "J", [.command, .shift]))
        tabs.addItem(item(String(localized: "Extensions"), #selector(menuExtensions), ""))

        let window = submenu(String(localized: "Window"), in: mainMenu)
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: String(localized: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        NSApp.mainMenu = mainMenu
    }

    private func submenu(_ title: String, in main: NSMenu) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func rebuildSpacesMenu() {
        spacesMenu.removeAllItems()
        spacesMenu.addItem(item(String(localized: "Next Space"), #selector(menuNextSpace), String(UnicodeScalar(NSRightArrowFunctionKey).map(Character.init) ?? " "), [.command, .option]))
        spacesMenu.addItem(item(String(localized: "Previous Space"), #selector(menuPreviousSpace), String(UnicodeScalar(NSLeftArrowFunctionKey).map(Character.init) ?? " "), [.command, .option]))
        spacesMenu.addItem(.separator())
        let spaces = MainActor.assumeIsolated { store.spaces }
        for (idx, space) in spaces.enumerated() {
            let i = item(space.name, #selector(menuSwitchSpace(_:)), idx < 9 ? "\(idx + 1)" : "", [.control])
            i.tag = idx
            spacesMenu.addItem(i)
        }
        spacesMenu.addItem(.separator())
        spacesMenu.addItem(item(String(localized: "New Space…"), #selector(menuNewSpace), ""))
        spacesMenu.addItem(item(String(localized: "Edit Current Space…"), #selector(menuEditSpace), ""))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch menuItem.action {
            case #selector(menuMuteTab):
                menuItem.title = store.selectedTab.map { store.isTabMuted($0) } == true ? String(localized: "Unmute Tab") : String(localized: "Mute Tab")
            case #selector(menuPinTab):
                menuItem.title = store.selectedTab?.kind == .pinned ? String(localized: "Unpin Tab") : String(localized: "Pin Tab")
            case #selector(menuFavoriteTab):
                menuItem.title = store.selectedTab?.kind == .favorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")
            case #selector(menuToggleSidebar):
                menuItem.title = store.isSidebarVisible ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
            case #selector(menuSwitchSpace(_:)):
                menuItem.state = store.spaces.indices.contains(menuItem.tag)
                    && store.spaces[menuItem.tag].id == store.currentSpaceID ? .on : .off
            default: break
            }
            return true
        }
    }

    /// True when a non-browser window (Settings, Peek, DevTools…) is key:
    /// Cmd+W then closes that window instead of a tab.
    private var keyWindowIsAuxiliary: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return !browserWindows.contains { $0 === key }
    }

    /// Cmd+Q and the menu's Quit. SIGTERM, the installer's Apple Event quit
    /// and the Dock's Quit call terminate directly and are never blocked.
    @objc private func menuQuit() {
        let warn = MainActor.assumeIsolated { store.warnBeforeQuitting }
        if warn {
            let alert = NSAlert()
            alert.messageText = String(localized: "Quit ToastPeek?")
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    @objc private func menuNewWindow() {
        MainActor.assumeIsolated { _ = makeBrowserWindow() }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func menuNewPeek() { MainActor.assumeIsolated { presentPeek(url: nil) } }
    @objc private func menuMakeDefault() { DefaultBrowser.request() }
    @objc private func menuCommandBar() {
        MainActor.assumeIsolated {
            if browserWindows.isEmpty { makeBrowserWindow() }
            if keyWindowIsAuxiliary { focusMainWindow() }
            store.commandBarMode = .newTab
        }
    }
    @objc private func menuOpenLocation() {
        MainActor.assumeIsolated {
            if keyWindowIsAuxiliary { return }
            store.commandBarMode = store.selectedTab == nil ? .newTab : .editCurrent
        }
    }
    @objc private func menuNewSpace() { MainActor.assumeIsolated { store.spaceEditor = SpaceEditorRequest(spaceID: nil) } }
    @objc private func menuEditSpace() {
        MainActor.assumeIsolated { store.spaceEditor = SpaceEditorRequest(spaceID: store.currentSpaceID) }
    }
    @objc private func menuToggleSidebar() { MainActor.assumeIsolated { store.isSidebarVisible.toggle(); store.scheduleSave() } }
    @objc private func menuToggleSplit() { MainActor.assumeIsolated { store.toggleSplit() } }
    @objc private func menuPrint() { MainActor.assumeIsolated { store.printPage() } }
    @objc private func menuSavePage() { MainActor.assumeIsolated { store.savePage() } }
    @objc private func menuViewSource() { MainActor.assumeIsolated { store.viewSourceOfSelectedTab() } }
    @objc private func menuCopyURL() { MainActor.assumeIsolated { store.copyCurrentURL() } }
    @objc private func menuCloseTab() {
        if keyWindowIsAuxiliary { NSApp.keyWindow?.performClose(nil); return }
        MainActor.assumeIsolated {
            if store.commandBarMode != nil { store.commandBarMode = nil; return }
            if let ws = store.activeWindowState, ws.splitTabIDs.count > 0, let f = ws.focusedPaneTabID {
                store.closeSplitPane(tabID: f)
                return
            }
            if let t = store.selectedTab { store.close(t) } else { NSApp.keyWindow?.performClose(nil) }
        }
    }
    @objc private func menuCloseWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func menuRestoreArchived() { MainActor.assumeIsolated { store.restoreMostRecentArchived() } }
    @objc private func menuBack() { MainActor.assumeIsolated { store.goBack() } }
    @objc private func menuForward() { MainActor.assumeIsolated { store.goForward() } }
    @objc private func menuReload() { MainActor.assumeIsolated { store.reload() } }
    @objc private func menuHardReload() { MainActor.assumeIsolated { store.hardReload() } }
    @objc private func menuFind() { MainActor.assumeIsolated { store.showFindBar() } }
    @objc private func menuFindNext() { MainActor.assumeIsolated { store.findNext(forward: true) } }
    @objc private func menuFindPrevious() { MainActor.assumeIsolated { store.findNext(forward: false) } }
    @objc private func menuZoomIn() { MainActor.assumeIsolated { store.zoomIn() } }
    @objc private func menuZoomOut() { MainActor.assumeIsolated { store.zoomOut() } }
    @objc private func menuZoomReset() { MainActor.assumeIsolated { store.zoomReset() } }
    @objc private func menuCloseSplit() { MainActor.assumeIsolated { store.closeSplit() } }
    @objc private func menuHistory() { MainActor.assumeIsolated { store.openHistoryPage() } }
    @objc private func menuArchive() { MainActor.assumeIsolated { store.openArchivePage() } }
    @objc private func menuDownloads() { MainActor.assumeIsolated { store.openLibrary(.downloads) } }
    @objc private func menuLibrary() { MainActor.assumeIsolated { store.toggleLibrary() } }
    @objc private func menuDevTools() { MainActor.assumeIsolated { store.showDevTools() } }
    @objc private func menuExtensions() { openSettings(page: .extensions) }
    @objc private func menuNextTab() { MainActor.assumeIsolated { store.selectAdjacentTab(forward: true) } }
    @objc private func menuPreviousTab() { MainActor.assumeIsolated { store.selectAdjacentTab(forward: false) } }
    @objc private func menuSelectTabIndex(_ sender: NSMenuItem) { MainActor.assumeIsolated { store.selectTab(atSidebarIndex: sender.tag) } }
    @objc private func menuPinTab() { MainActor.assumeIsolated { if let t = store.selectedTab { store.pin(t) } } }
    @objc private func menuFavoriteTab() { MainActor.assumeIsolated { if let t = store.selectedTab { store.toggleFavorite(t) } } }
    @objc private func menuDuplicateTab() { MainActor.assumeIsolated { if let t = store.selectedTab { store.duplicate(t) } } }
    @objc private func menuMuteTab() { MainActor.assumeIsolated { if let t = store.selectedTab { store.toggleTabMuted(t) } } }
    @objc private func menuNextSpace() { MainActor.assumeIsolated { store.switchSpaceRelative(1) } }
    @objc private func menuPreviousSpace() { MainActor.assumeIsolated { store.switchSpaceRelative(-1) } }
    @objc private func menuSwitchSpace(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard store.spaces.indices.contains(sender.tag) else { return }
            store.switchSpace(to: store.spaces[sender.tag].id)
        }
    }
    @objc private func menuImportHistory() {
        MainActor.assumeIsolated {
            guard let (added, found) = ImportPanels.importHistory(into: store) else { return }
            store.toast = found == 0 ? String(localized: "No history found in that file.")
                : String(localized: "History entries imported: \(added)")
        }
    }
    @objc private func menuSettings() { openSettings(page: nil) }

    private func openSettings(page: SettingsPage?) {
        if let w = settingsWindow {
            if let page, let tabs = w.contentViewController as? NSTabViewController,
               let index = SettingsPage.allCases.firstIndex(of: page) {
                tabs.selectedTabViewItemIndex = index
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        MainActor.assumeIsolated {
            for page in SettingsPage.allCases {
                let hosting = NSHostingController(rootView: SettingsPageContainer { page.view }.environmentObject(store))
                hosting.sizingOptions = [.preferredContentSize]
                hosting.title = page.title
                let item = NSTabViewItem(viewController: hosting)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
        }
        if let page, let index = SettingsPage.allCases.firstIndex(of: page) {
            tabs.selectedTabViewItemIndex = index
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
