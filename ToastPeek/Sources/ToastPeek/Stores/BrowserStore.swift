import SwiftUI
import Foundation
import AppKit

/// Per-window view state: which tab a window shows, its split panes and
/// its command-focus pane. Windows are views onto ONE shared BrowserStore —
/// Spaces, tabs, history and Boosts are app-global — but selection is per
/// window, so two windows can show different pages.
@MainActor
final class WindowTabState: ObservableObject {
    @Published var selectedTabID: UUID?
    /// Secondary split panes; the selected tab is always pane 1 (max 4 total).
    @Published var splitTabIDs: [UUID] = []
    @Published var focusedPaneTabID: UUID?
    /// HTML5 fullscreen: the page takes the whole window.
    @Published var fullscreenTabID: UUID?
    /// Library shown in this window's sidebar (nil = the normal sidebar).
    @Published var library: LibraryCategory? { didSet { if let library { lastLibrary = library } } }
    var lastLibrary: LibraryCategory = .downloads
    /// Window is in macOS full screen (no traffic lights).
    @Published var isWindowFullscreen = false
    /// Direction of the last Space switch, for the sidebar slide.
    @Published var spaceSwitchForward = true
    weak var window: NSWindow?

    var paneTabIDs: [UUID] {
        var out: [UUID] = []
        if let s = selectedTabID { out.append(s) }
        for id in splitTabIDs where !out.contains(id) { out.append(id) }
        return out
    }
}

/// What the Command Bar is doing when open.
enum CommandBarMode: Equatable {
    /// Cmd+T: results open in a new tab.
    case newTab
    /// Cmd+L / clicking the address: results replace the current tab.
    case editCurrent
}

/// Single source of truth for browser state, persisted as JSON.
@MainActor
final class BrowserStore: ObservableObject {
    @Published var spaces: [BrowserSpace] = BrowserSpace.defaults
    @Published var currentSpaceID: UUID = BrowserSpace.personal.id
    @Published var tabs: [BrowserTab] = [] {
        didSet { derivedCache.removeAll(keepingCapacity: true) }
    }
    /// Sorted sidebar groups, rebuilt lazily after `tabs` changes. Views
    /// ask for these many times per render (hover, progress updates).
    private var derivedCache: [String: [BrowserTab]] = [:]

    private var bootstrapSelectedTabID: UUID?
    private(set) var windowStates: [WindowTabState] = []
    weak var activeWindowState: WindowTabState? {
        didSet { if oldValue !== activeWindowState { objectWillChange.send() } }
    }
    var selectedTabID: UUID? {
        get { activeWindowState.map { $0.selectedTabID } ?? bootstrapSelectedTabID }
        set {
            if let ws = activeWindowState { ws.selectedTabID = newValue }
            else { bootstrapSelectedTabID = newValue }
        }
    }
    var focusedPaneTabID: UUID? {
        get { activeWindowState.map { $0.focusedPaneTabID ?? $0.selectedTabID } ?? selectedTabID }
        set { activeWindowState?.focusedPaneTabID = newValue }
    }

    @Published var isSidebarVisible: Bool = true
    @Published var sidebarWidth: Double = 260
    static let sidebarWidthRange: ClosedRange<Double> = 200...420
    @Published var commandBarMode: CommandBarMode?
    @Published var boosts: [Boost] = []
    @Published var history: [HistoryEntry] = []
    @Published var folders: [TabFolder] = []
    @Published var extensions: [BrowserExtension] = []
    /// Dark Mode's per-site host list (empty = every site).
    @Published var darkModeHosts: [String] = []
    @Published var sitePermissions: [SitePermission] = []
    /// Session-scoped certificate exceptions ("Visit Anyway" hosts). Deliberately
    /// NOT persisted to state.json: a relaunch re-prompts. See WebTabController.
        var certExceptions: Set<String> = []
    @Published var mutedTabIDs: Set<UUID> = []
    @Published var showOnboarding: Bool = false
    @Published var showHistory: Bool = false
    /// Hours before an unvisited Today tab archives itself (default: 12).
    @Published var archiveAfterHours: Double = 12
    @Published var searchEngine: SearchEngine = .google
    /// Off by default: each keystroke would go to the search engine.
    @Published var searchSuggestionsEnabled = false
    /// Unload tabs that have been out of sight for an hour.
    @Published var memorySaverEnabled = true
    /// Show the save panel for every download (default: save straight to the folder).
    @Published var askDownloadLocation = false { didSet { applyDownloadPolicy() } }
    /// Confirm before Cmd+Q / Quit from the menu (default: on).
    @Published var warnBeforeQuitting = true
    /// nil = the system Downloads folder.
    @Published var downloadsFolder: String? { didSet { applyDownloadPolicy() } }
    /// Sheet for creating / editing a Space (nil = closed; id = edit).
    @Published var spaceEditor: SpaceEditorRequest?
    /// Pinned tab or Favorite waiting for delete confirmation.
    @Published var pendingDeleteTab: BrowserTab?

    @Published var isFindBarVisible: Bool = false
    @Published var findText: String = ""
    @Published var findMatchCount: Int = 0
    @Published var findActiveOrdinal: Int = 0

    /// This session's downloads (in progress and finished).
    @Published var downloads: [DownloadItemState] = []
    /// Finished downloads across sessions, newest first, for the Library.
    @Published var downloadRecords: [DownloadRecord] = []

    /// Site controls: per-site exceptions to the native extensions.
    @Published var blockerExemptHosts: [String] = []
    @Published var darkModeExcludedHosts: [String] = []
    /// Links settings.
    @Published var externalLinksInPeek = true
    @Published var shiftClickPeek = true
    @Published var peekHotkeyEnabled = true { didSet { onPeekHotkeyChanged?() } }
    /// Master switch for Boosts (Settings › Advanced).
    @Published var boostsEnabled = true { didSet { if oldValue != boostsEnabled { applyBoostsToOpenTabs() } } }
    var onPeekHotkeyChanged: (() -> Void)?

    /// Temporary tabs shown in Peek windows (not part of any Space).
    @Published var peekTabs: [UUID: BrowserTab] = [:]
    /// Live browsers by tab id.
    private(set) var controllers: [UUID: WebTabController] = [:]
    /// Last selected tab per Space, so switching back lands where you were.
    private var lastSelectedBySpace: [UUID: UUID] = [:]

    /// Opens a URL in a Peek window (installed by the app delegate).
    var onOpenPeek: ((URL?) -> Void)?
    var onTearOffTab: ((BrowserTab) -> Void)?
    /// Rebuild Space-dependent menus (installed by the app delegate).
    var onSpacesChanged: (() -> Void)?

    private let stateFile: StateFile
    var dataFileURL: URL { stateFile.primary }
    private var saveWorkItem: DispatchWorkItem?
    private var lastBackupAt = Date.distantPast
    /// The next write also replaces the backup (after clearing data).
    private var replaceBackupOnNextSave = false
    private var maintenanceTimer: Timer?
    private static let writeQueue = DispatchQueue(label: "app.toastpeek.state-write", qos: .utility)

    /// Set when state.json existed but couldn't be read. The app runs on
    /// defaults; `stateWritesAllowed` is false only if the unreadable file
    /// could not be moved aside, so it is never overwritten.
    private(set) var stateLoadProblem: StateLoadProblem?
    private var stateWritesAllowed = true

    struct StateLoadProblem {
        var keptCopies: [URL]
        var writesAllowed: Bool
    }

    init(stateURL: URL = AppPaths.support.appendingPathComponent("state.json")) {
        stateFile = StateFile(primary: stateURL)
        var isFirstLaunch = false
        switch stateFile.load() {
        case .fresh:
            isFirstLaunch = true
            seed()
        case .loaded(let snapshot, let fromBackup, let copies):
            apply(snapshot)
            if fromBackup || !copies.isEmpty {
                NSLog("ToastPeekState loaded %@; unreadable copies kept: %@",
                      fromBackup ? "backup" : "state.json", copies.map(\.lastPathComponent).joined(separator: ", "))
            }
        case .unreadable(let copies, let preserved):
            NSLog("ToastPeekState unreadable; kept: %@ preserved=%d",
                  copies.map(\.lastPathComponent).joined(separator: ", "), preserved ? 1 : 0)
            stateLoadProblem = StateLoadProblem(keptCopies: copies, writesAllowed: preserved)
            stateWritesAllowed = preserved
            seed()
        }
        showOnboarding = isFirstLaunch
            && !UserDefaults.standard.bool(forKey: Self.onboardingDefaultsKey)
        runAutoArchive()
        prefetchIcons()
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runAutoArchive()
                self?.unloadIdleTabs()
            }
        }
    }

    /// Icons for Favorites and Pinned tabs that never loaded in a browser.
    func prefetchIcons() {
        let hosts = tabs.filter { $0.kind != .today && !$0.isArchived }.map(\.host)
        FaviconStore.shared.prefetch(hosts: Array(Set(hosts)).sorted())
    }

    var resolvedDownloadsFolder: String {
        if let f = downloadsFolder, FileManager.default.fileExists(atPath: f) { return f }
        return (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).path
    }
    func applyDownloadPolicy() {
        // The download destination policy lives in WebTabController's
        // WKDownloadDelegate: direct landing in resolvedDownloadsFolder, or
        // an NSSavePanel per file when askDownloadLocation is on.
    }

    private static let onboardingDefaultsKey = "toastpeek.onboardingCompleted"

    /// First step to show when the guide opens (Settings jumps straight to Import).
    var onboardingStartStep = 0

    func beginOnboarding(at step: Int = 0) {
        onboardingStartStep = step
        showOnboarding = true
    }

    func dismissOnboarding() {
        showOnboarding = false
        UserDefaults.standard.set(true, forKey: Self.onboardingDefaultsKey)
    }

    // MARK: Derived

    var currentSpace: BrowserSpace {
        spaces.first(where: { $0.id == currentSpaceID })
            ?? spaces.first
            ?? BrowserSpace(name: String(localized: "Personal"), icon: "house", colorHex: "#7C6FF0")
    }
    /// The Space whose look a tab takes (Favorites follow the current Space).
    func space(for tab: BrowserTab) -> BrowserSpace {
        if let id = tab.spaceID, let s = spaces.first(where: { $0.id == id }) { return s }
        return currentSpace
    }
    /// The Space whose cookies and logins a tab uses. Favorites always use
    /// the first Space, so a Favorite's login doesn't depend on which Space
    /// was showing when it first loaded. Peek pages use the current Space.
    func profileSpace(for tab: BrowserTab) -> BrowserSpace {
        if let id = tab.spaceID, let s = spaces.first(where: { $0.id == id }) { return s }
        if tab.kind == .favorite, peekTabs[tab.id] == nil, let first = spaces.first { return first }
        return currentSpace
    }

    private func cached(_ key: String, _ build: () -> [BrowserTab]) -> [BrowserTab] {
        if let hit = derivedCache[key] { return hit }
        let value = build()
        derivedCache[key] = value
        return value
    }
    var favorites: [BrowserTab] {
        cached("favorites") {
            tabs.filter { $0.kind == .favorite && !$0.isArchived }.sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    func pinned(in spaceID: UUID) -> [BrowserTab] {
        cached("pinned|\(spaceID)") {
            tabs.filter { $0.kind == .pinned && $0.spaceID == spaceID && !$0.isArchived }
                .sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    func pinned(in spaceID: UUID, folderID: UUID?) -> [BrowserTab] {
        pinned(in: spaceID).filter { $0.folderID == folderID }
    }
    func today(in spaceID: UUID) -> [BrowserTab] {
        cached("today|\(spaceID)") {
            tabs.filter { $0.kind == .today && $0.spaceID == spaceID && !$0.isArchived }
                .sorted { $0.sortIndex < $1.sortIndex }
        }
    }
    func folders(in spaceID: UUID) -> [TabFolder] {
        folders.filter { $0.spaceID == spaceID }
    }
    var archived: [BrowserTab] {
        cached("archived") { tabs.filter(\.isArchived).sorted { $0.lastVisitedAt > $1.lastVisitedAt } }
    }
    var selectedTab: BrowserTab? { tabs.first(where: { $0.id == selectedTabID }) }
    func tab(_ id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Sidebar order of the current Space: Favorites, Pinned (folder order),
    /// Today. Drives Ctrl+Tab style cycling and selection fallback.
    func visibleOrder(in spaceID: UUID) -> [BrowserTab] {
        var out = favorites
        out += pinned(in: spaceID, folderID: nil)
        for f in folders(in: spaceID) { out += pinned(in: spaceID, folderID: f.id) }
        out += today(in: spaceID)
        return out
    }

    // MARK: Window states

    func makeWindowState(preferredTabID: UUID? = nil) -> WindowTabState {
        let ws = WindowTabState()
        let shown = Set(windowStates.flatMap(\.paneTabIDs))
        if let preferredTabID, tabs.contains(where: { $0.id == preferredTabID && !$0.isArchived }) {
            ws.selectedTabID = preferredTabID
        } else if windowStates.isEmpty, let sel = bootstrapSelectedTabID {
            ws.selectedTabID = sel
        } else if let candidate = (today(in: currentSpaceID) + pinned(in: currentSpaceID))
            .first(where: { !shown.contains($0.id) }) {
            ws.selectedTabID = candidate.id
        }
        ws.focusedPaneTabID = ws.selectedTabID
        windowStates.append(ws)
        if activeWindowState == nil { activeWindowState = ws }
        return ws
    }

    func removeWindowState(_ ws: WindowTabState) {
        windowStates.removeAll { $0 === ws }
        if activeWindowState === ws { activeWindowState = windowStates.last }
    }

    /// After a tab leaves the visible set: drop it from panes and pick a
    /// neighbour (the next tab in sidebar order) where it was selected.
    private func repairWindowStates(afterRemoving tabID: UUID, spaceID: UUID, neighbour: UUID?) {
        for ws in windowStates {
            ws.splitTabIDs.removeAll { $0 == tabID }
            if ws.selectedTabID == tabID { ws.selectedTabID = neighbour }
            if ws.focusedPaneTabID == tabID { ws.focusedPaneTabID = ws.selectedTabID }
            if ws.fullscreenTabID == tabID { ws.fullscreenTabID = nil }
        }
        if bootstrapSelectedTabID == tabID { bootstrapSelectedTabID = nil }
        lastSelectedBySpace = lastSelectedBySpace.filter { $0.value != tabID }
    }

    /// The tab that should take a closing tab's place: the one below it in
    /// its group, else above, else the Space's first Today/Pinned tab.
    private func neighbour(of tab: BrowserTab) -> UUID? {
        let spaceID = tab.spaceID ?? currentSpaceID
        let order = visibleOrder(in: spaceID).filter { $0.kind != .favorite || tab.kind == .favorite }
        if let i = order.firstIndex(where: { $0.id == tab.id }) {
            if i + 1 < order.count { return order[i + 1].id }
            if i > 0 { return order[i - 1].id }
        }
        return (today(in: spaceID).first { $0.id != tab.id } ?? pinned(in: spaceID).first { $0.id != tab.id })?.id
    }

    // MARK: Sidebar ordering

    private func group(of tab: BrowserTab) -> [BrowserTab] {
        tabs.filter {
            $0.kind == tab.kind && !$0.isArchived
                && (tab.kind == .favorite || $0.spaceID == tab.spaceID)
                && (tab.kind != .pinned || $0.folderID == tab.folderID)
        }
    }
    private func topIndex(for tab: BrowserTab) -> Double {
        (group(of: tab).filter { $0.id != tab.id }.map(\.sortIndex).min() ?? 0) - 1
    }
    private func endIndex(for tab: BrowserTab) -> Double {
        (group(of: tab).filter { $0.id != tab.id }.map(\.sortIndex).max() ?? -1) + 1
    }
    private func applyOrder(_ ordered: [BrowserTab]) {
        for (pos, t) in ordered.enumerated() {
            if let i = tabs.firstIndex(where: { $0.id == t.id }) { tabs[i].sortIndex = Double(pos) }
        }
    }
    private func normalizeSortIndices() {
        var groups: [String: [BrowserTab]] = [:]
        for t in tabs where !t.isArchived {
            let space = t.kind == .favorite ? "-" : (t.spaceID?.uuidString ?? "-")
            let key = "\(t.kind.rawValue)|\(space)|\(t.folderID?.uuidString ?? "-")"
            groups[key, default: []].append(t)
        }
        for (_, members) in groups {
            applyOrder(members.sorted { a, b in
                if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
                if a.kind == .today { return a.lastVisitedAt > b.lastVisitedAt }
                return a.createdAt < b.createdAt
            })
        }
    }

    // MARK: Opening and navigating

    /// Opens typed text (URL or search) — in a new Today tab, or in the
    /// current tab when the Command Bar was editing it.
    func open(_ raw: String, mode: CommandBarMode = .newTab) {
        guard let url = URLResolver.resolve(raw, engine: searchEngine) else { return }
        if mode == .editCurrent, let current = selectedTab, current.viewSourceFor == nil {
            navigate(current.id, to: url.absoluteString)
            select(current)
        } else {
            newTab(urlString: url.absoluteString, title: "")
        }
    }

    func newTab(urlString: String, title: String = "", kind: TabKind = .today, select shouldSelect: Bool = true) {
        var t = BrowserTab(spaceID: kind == .favorite ? nil : currentSpaceID, kind: kind,
                           title: title, urlString: urlString)
        t.sortIndex = topIndex(for: t)
        if kind != .today { t.pinnedURLString = urlString }
        tabs.append(t)
        if shouldSelect { select(t) } else { scheduleSave() }
    }

    /// Link opened by a page (target=_blank, Cmd-click, context menu).
    /// Background tabs land right below their opener.
    func openFromPage(_ urlString: String, sourceTabID: UUID, background: Bool) {
        guard PageOpenPolicy.isAllowedTarget(urlString) else {
            NSLog("ToastPeekPopupBlocked reason=scheme url=%@", String(urlString.prefix(200)))
            notePopupBlocked(tabID: sourceTabID)
            return
        }
        var t = BrowserTab(spaceID: currentSpaceID, kind: .today, title: "", urlString: urlString)
        if let source = tab(sourceTabID), source.kind == .today {
            t.sortIndex = source.sortIndex + 0.5
            tabs.append(t)
            applyOrder(today(in: currentSpaceID))
        } else {
            t.sortIndex = topIndex(for: t)
            tabs.append(t)
        }
        if background { scheduleSave() } else { select(t) }
    }

    func navigate(_ tabID: UUID, to urlString: String) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].urlString = urlString
        controllers[tabID]?.load(urlString)
        scheduleSave()
    }

    func select(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tabs[i].isArchived {
            restore(tabs[i])
        }
        // Selecting a tab of another Space (Command Bar, Favorites keep
        // the current Space) brings that Space forward.
        if let spaceID = tabs[i].spaceID, spaceID != currentSpaceID, tabs[i].kind != .favorite {
            setCurrentSpace(spaceID)
        }
        selectedTabID = tab.id
        focusedPaneTabID = tab.id
        tabs[i].lastVisitedAt = Date()
        lastSelectedBySpace[currentSpaceID] = tab.id
        showHistory = false
        scheduleSave()
        // Give the page keyboard focus once it is on screen.
        DispatchQueue.main.async { [weak self] in self?.controllers[tab.id]?.focusPage() }
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab through the sidebar order.
    func selectAdjacentTab(forward: Bool) {
        let order = visibleOrder(in: currentSpaceID)
        guard !order.isEmpty else { return }
        let i = order.firstIndex { $0.id == selectedTabID } ?? -1
        let next = forward ? (i + 1) % order.count : (i - 1 + order.count) % order.count
        select(order[next])
    }

    /// Cmd+1…8 select the nth sidebar tab, Cmd+9 the last (Chrome).
    func selectTab(atSidebarIndex index: Int) {
        let order = visibleOrder(in: currentSpaceID)
        guard !order.isEmpty else { return }
        select(index >= 8 ? order[order.count - 1] : order[min(index, order.count - 1)])
    }

    // MARK: Engine → model

    func webTitleChanged(tabID: UUID, title: String) {
        if peekTabs[tabID] != nil { peekTabs[tabID]?.title = title; return }
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), !title.isEmpty, tabs[i].title != title else { return }
        tabs[i].title = title
        if let h = history.firstIndex(where: { $0.urlString == tabs[i].urlString }), h < 20 {
            history[h].title = title
        }
        scheduleSave()
    }

    func webAddressChanged(tabID: UUID, urlString: String) {
        if peekTabs[tabID] != nil {
            peekTabs[tabID]?.urlString = urlString
            recordHistory(urlString: urlString, title: peekTabs[tabID]?.title ?? "")
            return
        }
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabs[i].urlString != urlString { tabs[i].urlString = urlString }
        recordHistory(urlString: urlString, title: tabs[i].title)
        scheduleSave()
    }

    private func recordHistory(urlString: String, title: String) {
        guard let url = URL(string: urlString), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else { return }
        if let first = history.first, first.urlString == urlString {
            history[0].visitedAt = Date()
            return
        }
        history.removeAll { $0.urlString == urlString }
        history.insert(HistoryEntry(title: title, urlString: urlString), at: 0)
        if history.count > 5000 { history.removeLast(history.count - 5000) }
    }

    // MARK: Closing (Chrome-style)

    /// Today tabs archive; Pinned tabs and Favorites unload and return to
    /// their pinned address — they stay in the sidebar.
    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let spaceID = tabs[i].spaceID ?? currentSpaceID
        let next = neighbour(of: tabs[i])
        if tabs[i].kind == .today {
            tabs[i].isArchived = true
            tabs[i].lastVisitedAt = Date()
        } else if let pinnedURL = tabs[i].pinnedURLString {
            tabs[i].urlString = pinnedURL
        }
        unload(tab.id)
        repairWindowStates(afterRemoving: tab.id, spaceID: spaceID, neighbour: next)
        scheduleSave()
    }

    /// Asks before removing a Pinned tab or Favorite (it has no Archive copy).
    func requestDelete(_ tab: BrowserTab) {
        pendingDeleteTab = tab
    }

    /// Permanently removes a Pinned tab or Favorite from the sidebar.
    func delete(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let next = neighbour(of: tabs[i])
        let spaceID = tabs[i].spaceID ?? currentSpaceID
        tabs.remove(at: i)
        unload(tab.id)
        repairWindowStates(afterRemoving: tab.id, spaceID: spaceID, neighbour: next)
        scheduleSave()
    }

    /// Unload a tab's browser (frees its memory; it reloads when shown).
    func unload(_ tabID: UUID) {
        guard let c = controllers.removeValue(forKey: tabID) else { return }
        c.close()
        objectWillChange.send()
    }

    func resetToPinnedURL(_ tab: BrowserTab) {
        guard let url = tab.pinnedURLString else { return }
        navigate(tab.id, to: url)
    }

    func updatePinnedURL(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[i].pinnedURLString = tabs[i].urlString
        scheduleSave()
    }

    func duplicate(_ tab: BrowserTab) {
        var t = BrowserTab(spaceID: currentSpaceID, kind: .today, title: tab.title, urlString: tab.urlString)
        t.sortIndex = topIndex(for: t)
        tabs.append(t)
        select(t)
    }

    /// Today "Clear": archive every Today tab of the Space.
    func clearToday() {
        let ids = today(in: currentSpaceID).map(\.id)
        guard !ids.isEmpty else { return }
        let fallback = pinned(in: currentSpaceID).first?.id ?? favorites.first?.id
        for id in ids {
            if let i = tabs.firstIndex(where: { $0.id == id }) {
                tabs[i].isArchived = true
                tabs[i].lastVisitedAt = Date()
            }
            unload(id)
            repairWindowStates(afterRemoving: id, spaceID: currentSpaceID, neighbour: fallback)
        }
        scheduleSave()
    }

    func pin(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tabs[i].kind == .pinned {
            tabs[i].kind = .today; tabs[i].folderID = nil; tabs[i].pinnedURLString = nil
            tabs[i].sortIndex = topIndex(for: tabs[i])
        } else {
            if tabs[i].kind == .favorite { tabs[i].spaceID = currentSpaceID }
            tabs[i].kind = .pinned; tabs[i].folderID = nil
            tabs[i].pinnedURLString = tabs[i].urlString
            tabs[i].sortIndex = endIndex(for: tabs[i])
        }
        scheduleSave()
    }
    func toggleFavorite(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tabs[i].kind == .favorite {
            tabs[i].kind = .today; tabs[i].spaceID = currentSpaceID; tabs[i].folderID = nil
            tabs[i].pinnedURLString = nil
            tabs[i].sortIndex = topIndex(for: tabs[i])
        } else {
            tabs[i].kind = .favorite; tabs[i].spaceID = nil; tabs[i].folderID = nil
            tabs[i].pinnedURLString = tabs[i].urlString
            tabs[i].sortIndex = endIndex(for: tabs[i])
        }
        scheduleSave()
    }
    /// Restore an archived tab. Restoring routes back to the Space the tab
    /// came from. No archive path clears spaceID (close, clearToday,
    /// archiveInPlace, runAutoArchive all only set isArchived), so the origin
    /// Space is already recorded on the archived tab; route back there and
    /// bring that Space forward so the restored tab is visible. Fall back to
    /// the current Space when the origin Space is gone (deleted, or an
    /// archive predating origin recording).
    func restore(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let target: UUID
        if let origin = tabs[i].spaceID, spaces.contains(where: { $0.id == origin }) {
            target = origin
        } else {
            target = currentSpaceID
        }
        tabs[i].isArchived = false; tabs[i].kind = .today; tabs[i].spaceID = target
        tabs[i].folderID = nil; tabs[i].lastVisitedAt = Date()
        tabs[i].sortIndex = topIndex(for: tabs[i])
        if target != currentSpaceID { setCurrentSpace(target) }
        scheduleSave()
    }

    /// Move a tab to another Space (Today section there).
    func move(_ tab: BrowserTab, toSpace spaceID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }), tabs[i].spaceID != spaceID else { return }
        let next = neighbour(of: tabs[i])
        let oldSpace = tabs[i].spaceID ?? currentSpaceID
        tabs[i].spaceID = spaceID
        if tabs[i].kind == .favorite { tabs[i].kind = .today }
        tabs[i].folderID = nil
        tabs[i].sortIndex = topIndex(for: tabs[i])
        // Different profile: the page must reload under the new Space's cookies.
        unload(tab.id)
        repairWindowStates(afterRemoving: tab.id, spaceID: oldSpace, neighbour: next)
        scheduleSave()
    }

    // MARK: Folders

    @discardableResult
    func createFolder(name: String, in spaceID: UUID? = nil) -> TabFolder {
        let f = TabFolder(spaceID: spaceID ?? currentSpaceID, name: name)
        folders.append(f); scheduleSave()
        return f
    }
    func renameFolder(_ folder: TabFolder, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        folders[i].name = name; scheduleSave()
    }
    func deleteFolder(_ folder: TabFolder) {
        let evictedIDs = Set(tabs.filter { $0.folderID == folder.id }.map(\.id))
        let evicted = tabs.filter { evictedIDs.contains($0.id) }.sorted { $0.sortIndex < $1.sortIndex }
        for i in tabs.indices where evictedIDs.contains(tabs[i].id) { tabs[i].folderID = nil }
        folders.removeAll { $0.id == folder.id }
        let existing = pinned(in: folder.spaceID, folderID: nil).filter { !evictedIDs.contains($0.id) }
        applyOrder(existing + evicted)
        scheduleSave()
    }
    func toggleFolderCollapse(_ folder: TabFolder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].isCollapsed.toggle(); scheduleSave()
    }
    func moveTabToFolder(_ tab: BrowserTab, folderID: UUID?) {
        reorderTab(tab, targetKind: .pinned, folderID: folderID, insertBefore: nil)
    }

    // MARK: Drag out to a new window

    /// NSDraggingSource endedAt entry point (TabDragHandleView). Only an
    /// unconsumed release outside every app window is a tear-off.
    func tabDragSessionEnded(tabID: UUID, screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation == [], onTearOffTab != nil else { return }
        if NSApp.orderedWindows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) }) { return }
        guard let t = tab(tabID), !t.isArchived else { return }
        onTearOffTab?(t)
    }

    // MARK: Drag & drop reordering

    /// Retarget the dragged tab to a group (kind + folder, current Space)
    /// and place it before `insertBefore` (nil = end of group).
    func reorderTab(_ dragged: BrowserTab, targetKind: TabKind, folderID: UUID?, insertBefore targetID: UUID?) {
        guard !dragged.isArchived, let di = tabs.firstIndex(where: { $0.id == dragged.id }) else { return }
        let wasKind = tabs[di].kind
        tabs[di].kind = targetKind
        tabs[di].spaceID = targetKind == .favorite ? nil : currentSpaceID
        tabs[di].folderID = targetKind == .pinned ? folderID : nil
        if targetKind == .today {
            tabs[di].pinnedURLString = nil
        } else if wasKind == .today || tabs[di].pinnedURLString == nil {
            tabs[di].pinnedURLString = tabs[di].urlString
        }
        let moved = tabs[di]
        var ordered = group(of: moved).filter { $0.id != moved.id }.sorted { $0.sortIndex < $1.sortIndex }
        if let targetID, let pos = ordered.firstIndex(where: { $0.id == targetID }) {
            ordered.insert(moved, at: pos)
        } else {
            ordered.append(moved)
        }
        applyOrder(ordered)
        scheduleSave()
    }

    func importHistory(_ rows: [ImportedHistoryRow]) -> Int {
        var known = Set(history.map(\.urlString))
        var added = 0
        for row in rows where !row.urlString.isEmpty && !known.contains(row.urlString) {
            history.append(HistoryEntry(title: row.title.isEmpty ? row.urlString : row.title,
                                        urlString: row.urlString, visitedAt: row.visitedAt))
            known.insert(row.urlString)
            added += 1
        }
        if added > 0 {
            history.sort { $0.visitedAt > $1.visitedAt }
            history = Array(history.prefix(5000))
            scheduleSave()
        }
        return added
    }

    // MARK: Extensions

    func setExtensionEnabled(_ ext: BrowserExtension, _ enabled: Bool) {
        guard let i = extensions.firstIndex(where: { $0.id == ext.id }) else { return }
        extensions[i].isEnabled = enabled
        scheduleSave()
        if ext.path.hasPrefix("builtin:") { applyNativeExtensionsToOpenTabs() }
    }
    /// The built-in extensions: Content Blocker and Dark Mode.
    static let contentBlockerBuiltinPath = "builtin:content-blocker"
    static let darkModeBuiltinPath = "builtin:dark-mode"
    var isContentBlockingEnabled: Bool {
        extensions.first(where: { $0.path == Self.contentBlockerBuiltinPath })?.isEnabled ?? false
    }
    var isDarkModeEnabled: Bool {
        extensions.first(where: { $0.path == Self.darkModeBuiltinPath })?.isEnabled ?? false
    }
    // MARK: History / Archive pages

    func openHistoryPage() { showHistory = true }
    /// Archived tabs live in the Library.
    func openArchivePage() { openLibrary(.archived) }
    func clearHistory() { history = []; scheduleSave() }
    func deleteHistoryEntry(_ entry: HistoryEntry) {
        history.removeAll { $0.id == entry.id }
        scheduleSave()
    }
    /// Clears history, the Archive, favicons, downloads list, cookies,
    /// saved logins and caches of every Space. Remaining site storage is
    /// deleted at the next launch; the state backup is replaced too.
    func clearBrowsingData() {
        history = []
        sitePermissions = []
        let archivedIDs = Set(tabs.filter(\.isArchived).map(\.id))
        tabs.removeAll { archivedIDs.contains($0.id) }
        downloads.removeAll { $0.state != "inProgress" }
        FaviconStore.shared.removeAll()
        for space in spaces { BrowserEngineBridge.clearBrowsingData(dataStoreID: space.dataStoreID) }
        replaceBackupOnNextSave = true
        save()
        promptRestartAfterClearing()
    }

    private func promptRestartAfterClearing() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart ToastPeek to finish clearing?")
        alert.informativeText = String(localized: "Site storage is removed when ToastPeek starts again. Open tabs stay.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { AppRelauncher.relaunch() }
        }
        if let window = activeWindowState?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
    func deletePermanently(_ tab: BrowserTab) {
        tabs.removeAll { $0.id == tab.id }
        scheduleSave()
    }
    func restoreMostRecentArchived() {
        guard let mostRecent = archived.first else { return }
        restore(mostRecent)
        if let fresh = tab(mostRecent.id) { select(fresh) }
    }

    // MARK: Bulk close (archive in place — recoverable from the Archive)

    private func archiveInPlace(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }), !tabs[i].isArchived else { return }
        let spaceID = tabs[i].spaceID ?? currentSpaceID
        if tabs[i].kind == .today {
            tabs[i].isArchived = true
            tabs[i].lastVisitedAt = Date()
        }
        unload(tab.id)
        repairWindowStates(afterRemoving: tab.id, spaceID: spaceID, neighbour: nil)
    }
    func closeOtherTabs(keeping tab: BrowserTab) {
        for t in today(in: tab.spaceID ?? currentSpaceID) where t.id != tab.id { archiveInPlace(t) }
        select(tab)
    }
    func closeTabsBelow(_ tab: BrowserTab) {
        let below = group(of: tab).filter { $0.id != tab.id && $0.sortIndex > tab.sortIndex }
        for t in below { archiveInPlace(t) }
        scheduleSave()
    }

    // MARK: Tab mute

    func isTabMuted(_ tab: BrowserTab) -> Bool { mutedTabIDs.contains(tab.id) }
    func isTabMuted(_ tabID: UUID) -> Bool { mutedTabIDs.contains(tabID) }
    func toggleTabMuted(_ tab: BrowserTab) {
        let muted = !mutedTabIDs.contains(tab.id)
        if muted { mutedTabIDs.insert(tab.id) } else { mutedTabIDs.remove(tab.id) }
        controllers[tab.id]?.setMuted(muted)
        scheduleSave()
    }

    // MARK: Site permissions

    /// WebKit media-permission mapping lives in WebTabController.
    private enum PromptResult { static let accept = 0; static let deny = 1 }

    func clearSitePermission(_ permission: SitePermission) {
        sitePermissions.removeAll { $0.origin == permission.origin }
        scheduleSave()
    }
    // MARK: Web controllers

    func controller(for tab: BrowserTab) -> WebTabController {
        if let c = controllers[tab.id] { return c }
        let c = WebTabController(tab: tab, dataStoreID: profileSpace(for: tab).dataStoreID, store: self)
        controllers[tab.id] = c
        // Views that looked the controller up before it existed (navigation
        // buttons, address progress) refresh on the next turn.
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        return c
    }
    func controller(forTabID id: UUID?) -> WebTabController? {
        guard let id else { return nil }
        return controllers[id]
    }

    /// Enabled Boosts for the bridge, which matches each against the
    /// document actually loading (redirects, in-page navigations).
    var boostRules: [[String: String]] {
        guard boostsEnabled else { return [] }
        return boosts.compactMap { boost in
            guard boost.isEnabled, !boost.normalizedPattern.isEmpty else { return nil }
            let source = boost.combinedSource
            return source.isEmpty ? nil : ["pattern": boost.normalizedPattern, "source": source]
        }
    }
    /// Boost edits apply right away to open pages of matching sites.
    /// `extraReloadPatterns`: hosts whose Boost was just deleted — the rule
    /// is already gone from `boosts`, but its pages still need a refresh.
    func applyBoostsToOpenTabs(extraReloadPatterns: [String] = []) {
        let rules = boostRules
        for (id, c) in controllers {
            c.setBoostRules(rules)
            let host = tab(id)?.host ?? peekTabs[id]?.host ?? ""
            let hit = boosts.contains { $0.matchesHostIgnoringEnabled(host: host) }
                || extraReloadPatterns.contains { Boost.patternMatches($0, host: host) }
            if hit { c.reload() }
        }
        scheduleSave()
    }

    private var boostApplyWork: DispatchWorkItem?
    /// The Boosts editor mutates `boosts` on every keystroke; refresh the
    /// affected pages once edits settle instead of reloading per keystroke.
    func scheduleBoostApply() {
        boostApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyBoostsToOpenTabs() }
        }
        boostApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Native extensions apply to every live tab at once (content rules +
    /// dark script). Pages already loaded pick the change up on their next
    /// navigation or reload; new navigations get it immediately.
    func applyNativeExtensionsToOpenTabs() {
        for (_, c) in controllers { c.refreshNativeExtensions() }
        scheduleSave()
    }

    /// Dark Mode's per-site list (lowercased hosts, deduped). Empty means
    /// Dark Mode applies to every site when its toggle is on.
    func setDarkModeHosts(_ hosts: [String]) {
        let cleaned = hosts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        darkModeHosts = cleaned.filter { seen.insert($0).inserted }
        scheduleSave()
        applyNativeExtensionsToOpenTabs()
    }

    // MARK: Engine updates

    /// WebKit follows macOS: there is no engine release to track, so there
    /// is no update check. The Settings engine row states this directly.

    /// Opens Settings, optionally at one page (installed by the app delegate).
    var onOpenSettings: ((SettingsPage?) -> Void)?

    /// A page tried to open a popup or tab and was blocked.
    func notePopupBlocked(tabID: UUID) {
        toast = String(localized: "Pop-up blocked")
    }

    /// Memory saver: unload browsers out of sight for an hour. Tabs that
    /// are loading, playing media, recording or fullscreen stay.
    func unloadIdleTabs() {
        guard memorySaverEnabled else { return }
        let visible = Set(windowStates.flatMap(\.paneTabIDs))
        let cutoff = Date().addingTimeInterval(-3600)
        for (id, c) in controllers where !visible.contains(id) && c.lastShownAt < cutoff && !c.isBusy {
            unload(id)
        }
    }

    var activeController: WebTabController? {
        if let ws = activeWindowState {
            if let f = ws.focusedPaneTabID, ws.paneTabIDs.contains(f), let c = controllers[f] { return c }
            if let id = ws.selectedTabID, let c = controllers[id] { return c }
        }
        return controller(forTabID: selectedTabID)
    }
    func notePaneFocused(_ tabID: UUID) {
        if focusedPaneTabID != tabID { focusedPaneTabID = tabID }
    }

    func goBack() { activeController?.goBack() }
    func goForward() { activeController?.goForward() }
    func reload() { activeController?.reload() }
    func hardReload() { activeController?.hardReload() }
    func printPage() { activeController?.printPage() }
    func savePage() { activeController?.savePage() }
    func showDevTools() { activeController?.showDevTools() }
    func zoomIn() { activeController?.zoomIn() }
    func zoomOut() { activeController?.zoomOut() }
    func zoomReset() { activeController?.zoomReset() }

    func copyCurrentURL() {
        guard let t = selectedTab else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t.urlString, forType: .string)
        toast = String(localized: "Copied link")
    }
    /// Short-lived confirmation pill.
    @Published var toast: String? {
        didSet {
            guard toast != nil else { return }
            let current = toast
            // Longer messages stay up long enough to read.
            let seconds = max(1.6, min(6, Double(current?.count ?? 0) * 0.07))
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                if self?.toast == current { self?.toast = nil }
            }
        }
    }

    /// The window left macOS fullscreen (green button / Esc): leave HTML5
    /// fullscreen too.
    func windowDidExitFullscreen(_ ws: WindowTabState) {
        guard let id = ws.fullscreenTabID else { return }
        ws.fullscreenTabID = nil
        controllers[id]?.exitFullscreen()
    }

    // MARK: View Source

    @Published var viewSourceTexts: [UUID: String] = [:]
    @Published var viewSourceFailed: Set<UUID> = []
    var viewSourceRequested: Set<UUID> = []

    func viewSourceOfSelectedTab() {
        guard let id = selectedTabID else { return }
        viewSource(of: id)
    }
    func viewSource(of tabID: UUID) {
        guard let source = tab(tabID), source.viewSourceFor == nil else { return }
        var viewer = BrowserTab(spaceID: currentSpaceID, kind: .today,
                                title: String(localized: "Source of \(source.displayHost)"),
                                urlString: "view-source:" + source.urlString)
        viewer.viewSourceFor = source.urlString
        viewer.sortIndex = topIndex(for: viewer)
        tabs.append(viewer)
        select(viewer)
        let viewerID = viewer.id
        viewSourceRequested.insert(viewerID)
        guard let c = controllers[tabID] else { viewSourceFailed.insert(viewerID); return }
        c.fetchSource { [weak self] text in
            guard let self else { return }
            if let text, !text.isEmpty { self.viewSourceTexts[viewerID] = text }
            else { self.viewSourceFailed.insert(viewerID) }
        }
    }

    // MARK: Find in page

    func showFindBar() {
        isFindBarVisible = true
        if !findText.isEmpty { performFind() }
    }
    func hideFindBar() {
        isFindBarVisible = false
        activeController?.stopFinding()
        findMatchCount = 0
        findActiveOrdinal = 0
    }
    func performFind() {
        guard !findText.isEmpty else {
            activeController?.stopFinding()
            findMatchCount = 0
            findActiveOrdinal = 0
            return
        }
        activeController?.find(findText, forward: true, findNext: false)
    }
    func findNext(forward: Bool) {
        guard !findText.isEmpty else { return }
        activeController?.find(findText, forward: forward, findNext: true)
    }
    func updateFindResult(count: Int, activeOrdinal: Int) {
        findMatchCount = count
        findActiveOrdinal = activeOrdinal
    }

    // MARK: Downloads

    /// Browsers kept alive only to finish a download whose tab went away.
    private var downloadHosts: [UInt32: WebTabController] = [:]

    func upsertDownload(fromTab tabID: UUID, _ item: DownloadItemState) {
        if let i = downloads.firstIndex(where: { $0.id == item.id }) {
            let wasDone = downloads[i].isComplete
            downloads[i] = item
            if item.isComplete && !wasDone { recordFinishedDownload(item) }
        } else {
            downloads.insert(item, at: 0)
            if item.isComplete { recordFinishedDownload(item) }
            else { toast = String(localized: "Downloading \(item.fileName)") }
            retireDownloadOnlyTab(tabID, downloadID: item.id, downloadURL: item.urlString)
        }
        if item.state != "inProgress", let host = downloadHosts.removeValue(forKey: item.id) {
            host.close()
        }
    }

    private func recordFinishedDownload(_ item: DownloadItemState) {
        toast = String(localized: "Downloaded \(item.fileName)")
        downloadRecords.removeAll { $0.fullPath == item.fullPath }
        downloadRecords.insert(DownloadRecord(fileName: item.fileName, urlString: item.urlString,
                                              fullPath: item.fullPath), at: 0)
        if downloadRecords.count > 500 { downloadRecords.removeLast(downloadRecords.count - 500) }
        scheduleSave()
    }

    func removeDownloadRecord(_ record: DownloadRecord) {
        downloadRecords.removeAll { $0.id == record.id }
        scheduleSave()
    }

    /// A fresh tab that only produced a download (no page of its own) leaves
    /// the sidebar, like Chrome; its browser lives on off-screen
    /// until the download ends so progress keeps arriving.
    private func retireDownloadOnlyTab(_ tabID: UUID, downloadID: UInt32, downloadURL: String) {
        // Only a tab whose own address is the download: a page that merely
        // links to a file (even an untitled one) keeps its tab.
        guard let i = tabs.firstIndex(where: { $0.id == tabID }), tabs[i].kind == .today,
              let c = controllers[tabID], !c.canGoBack,
              tabs[i].urlString == downloadURL || c.currentURLString == downloadURL
                || (tabs[i].title.isEmpty && c.currentURLString.isEmpty) else { return }
        let next = neighbour(of: tabs[i])
        let spaceID = tabs[i].spaceID ?? currentSpaceID
        controllers.removeValue(forKey: tabID)
        c.container.removeFromSuperview()
        downloadHosts[downloadID] = c
        tabs.remove(at: i)
        repairWindowStates(afterRemoving: tabID, spaceID: spaceID, neighbour: next)
        scheduleSave()
    }
    var activeDownloadProgress: Double? {
        let active = downloads.filter { $0.state == "inProgress" }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 + max($1.totalBytes, 0) }
        let received = active.reduce(Int64(0)) { $0 + $1.receivedBytes }
        return total > 0 ? Double(received) / Double(total) : 0.1
    }

    // MARK: Spaces

    func addSpace(name: String, icon: String, colorHex: String) {
        let s = BrowserSpace(name: name, icon: icon, colorHex: colorHex)
        spaces.append(s)
        switchSpace(to: s.id)
        onSpacesChanged?()
    }
    func updateSpace(_ id: UUID, name: String, icon: String, colorHex: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].name = name
        spaces[i].icon = icon
        spaces[i].colorHex = colorHex
        scheduleSave()
        onSpacesChanged?()
    }
    /// Deletes a Space with its tabs and folders. The last Space stays.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        for t in tabs where t.spaceID == id { unload(t.id) }
        tabs.removeAll { $0.spaceID == id }
        folders.removeAll { $0.spaceID == id }
        BrowserEngineBridge.clearBrowsingData(dataStoreID: spaces[i].dataStoreID)
        spaces.remove(at: i)
        if currentSpaceID == id { switchSpace(to: spaces[max(0, i - 1)].id) }
        scheduleSave()
        onSpacesChanged?()
    }
    func moveSpace(_ id: UUID, by offset: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard spaces.indices.contains(j) else { return }
        spaces.swapAt(i, j)
        scheduleSave()
        onSpacesChanged?()
    }

    private func setCurrentSpace(_ id: UUID) {
        guard id != currentSpaceID else { return }
        let from = spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let to = spaces.firstIndex { $0.id == id } ?? 0
        for ws in windowStates where ws === activeWindowState { ws.spaceSwitchForward = to >= from }
        currentSpaceID = id
    }

    func switchSpace(to id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        if let sel = selectedTabID { lastSelectedBySpace[currentSpaceID] = sel }
        setCurrentSpace(id)
        let remembered = lastSelectedBySpace[id].flatMap { tid in
            tabs.first { $0.id == tid && !$0.isArchived && ($0.spaceID == id || $0.kind == .favorite) }
        }
        let next = remembered ?? today(in: id).first ?? pinned(in: id).first
        selectedTabID = next?.id
        focusedPaneTabID = next?.id
        activeWindowState?.splitTabIDs = []
        showHistory = false
        scheduleSave()
    }

    func switchSpaceRelative(_ offset: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let j = i + offset
        guard spaces.indices.contains(j) else { return }
        switchSpace(to: spaces[j].id)
    }

    // MARK: Split view

    func toggleSplit(with tab: BrowserTab? = nil) {
        guard let ws = activeWindowState else { return }
        if let tab {
            if tab.id != ws.selectedTabID {
                if !ws.splitTabIDs.contains(tab.id) {
                    if ws.paneTabIDs.count >= 4 { ws.splitTabIDs.removeLast() }
                    ws.splitTabIDs.append(tab.id)
                }
                ws.focusedPaneTabID = tab.id
            }
        } else if !ws.splitTabIDs.isEmpty {
            closeSplit()
        } else if let other = today(in: currentSpaceID).first(where: { $0.id != ws.selectedTabID }) {
            ws.splitTabIDs = [other.id]
        } else {
            openInSplit(nil)
        }
    }

    /// New tab opened straight into a split pane next to the current one.
    func openInSplit(_ urlString: String?) {
        guard let ws = activeWindowState, ws.selectedTabID != nil else {
            if let urlString { newTab(urlString: urlString) }
            return
        }
        var t = BrowserTab(spaceID: currentSpaceID, kind: .today, title: "",
                           urlString: urlString ?? "about:blank")
        t.sortIndex = topIndex(for: t)
        tabs.append(t)
        if ws.paneTabIDs.count >= 4 { ws.splitTabIDs.removeLast() }
        ws.splitTabIDs.append(t.id)
        ws.focusedPaneTabID = t.id
        scheduleSave()
        if urlString == nil { commandBarMode = .editCurrent }
    }

    @discardableResult
    func closeSplit() {
        guard let ws = activeWindowState else { return }
        ws.splitTabIDs = []
        ws.focusedPaneTabID = ws.selectedTabID
    }

    func closeSplitPane(tabID: UUID) {
        guard let ws = activeWindowState else { return }
        if ws.splitTabIDs.contains(tabID) {
            ws.splitTabIDs.removeAll { $0 == tabID }
        } else if tabID == ws.selectedTabID, let first = ws.splitTabIDs.first {
            ws.selectedTabID = first
            ws.splitTabIDs.removeFirst()
        }
        if ws.focusedPaneTabID == tabID { ws.focusedPaneTabID = ws.selectedTabID }
    }

    // MARK: Auto-archive

    func runAutoArchive() {
        let cutoff = Date().addingTimeInterval(-archiveAfterHours * 3600)
        let visible = Set(windowStates.flatMap(\.paneTabIDs))
        var changed = false
        for i in tabs.indices where tabs[i].kind == .today && !tabs[i].isArchived
            && tabs[i].lastVisitedAt < cutoff && !visible.contains(tabs[i].id)
            && controllers[tabs[i].id]?.isBusy != true {
            tabs[i].isArchived = true
            unload(tabs[i].id)
            changed = true
        }
        // The Archive keeps 30 days.
        let purge = Date().addingTimeInterval(-30 * 86_400)
        let before = tabs.count
        tabs.removeAll { $0.isArchived && $0.lastVisitedAt < purge }
        if changed || tabs.count != before { scheduleSave() }
    }

    private func seed() {
        let p = spaces.first?.id ?? currentSpaceID
        func t(_ kind: TabKind, _ title: String, _ url: String, space: UUID?) -> BrowserTab {
            var tab = BrowserTab(spaceID: space, kind: kind, title: title, urlString: url)
            if kind != .today { tab.pinnedURLString = url }
            return tab
        }
        tabs = [
            t(.favorite, "Google", "https://www.google.com", space: nil),
            t(.favorite, "YouTube", "https://www.youtube.com", space: nil),
            t(.favorite, "GitHub", "https://github.com", space: nil),
            t(.favorite, "Wikipedia", "https://www.wikipedia.org", space: nil),
            t(.today, "", "https://www.apple.com", space: p),
        ]
        selectedTabID = tabs.last?.id
        normalizeSortIndices()
        seedNativeExtensions()
    }

    /// The two native WebKit replacements, seeded once on first launch and
    /// on every load of an older state file (idempotent: existing entries
    /// are never duplicated or re-enabled). Legacy Chrome-extension entries
    /// stay listed but can no longer load (see ExtensionsView).
    private func seedNativeExtensions() {
        if !extensions.contains(where: { $0.path == Self.contentBlockerBuiltinPath }) {
            extensions.append(BrowserExtension(name: "Content Blocker", version: "Built-in", path: Self.contentBlockerBuiltinPath, isEnabled: true))
        }
        if !extensions.contains(where: { $0.path == Self.darkModeBuiltinPath }) {
            extensions.append(BrowserExtension(name: "Dark Mode", version: "Built-in", path: Self.darkModeBuiltinPath, isEnabled: false))
        }
    }

    // MARK: Persistence

    /// Coalesces bursts of changes (title updates, typing) into one write.
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    /// Writes immediately (used on quit and by tests).
    func save() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        if let sel = selectedTabID { lastSelectedBySpace[currentSpaceID] = sel }
        guard stateWritesAllowed else { return }
        let s = StateSnapshot(spaces: spaces, currentSpaceID: currentSpaceID, tabs: tabs,
                         boosts: boosts, history: history, archiveAfterHours: archiveAfterHours,
                         folders: folders, extensions: extensions,
                         sitePermissions: sitePermissions, mutedTabIDs: Array(mutedTabIDs),
                         sidebarWidth: sidebarWidth, searchEngine: searchEngine,
                         searchSuggestionsEnabled: searchSuggestionsEnabled,
                         memorySaverEnabled: memorySaverEnabled,
                         askDownloadLocation: askDownloadLocation,
                         warnBeforeQuitting: warnBeforeQuitting,
                         downloadsFolder: downloadsFolder,
                         lastSelectedBySpace: Dictionary(uniqueKeysWithValues:
                            lastSelectedBySpace.map { ($0.key.uuidString, $0.value) }),
                         isSidebarVisible: isSidebarVisible,
                         settingsVersion: StateSnapshot.currentSettingsVersion,
                         darkModeHosts: darkModeHosts,
                         downloadRecords: downloadRecords,
                         blockerExemptHosts: blockerExemptHosts,
                         darkModeExcludedHosts: darkModeExcludedHosts,
                         externalLinksInPeek: externalLinksInPeek,
                         shiftClickPeek: shiftClickPeek,
                         peekHotkeyEnabled: peekHotkeyEnabled,
                         boostsEnabled: boostsEnabled)
        guard let data = StateFile.encode(s) else { return }
        let file = stateFile
        // Rotate the last-known-good copy at most every 10 minutes.
        let rotate = Date().timeIntervalSince(lastBackupAt) > 600
        if rotate { lastBackupAt = Date() }
        let replaceBackup = replaceBackupOnNextSave
        replaceBackupOnNextSave = false
        Self.writeQueue.async {
            file.write(data, rotateBackup: rotate, replaceBackup: replaceBackup)
        }
    }

    /// Blocks until pending writes are on disk (quit).
    func flush() {
        save()
        Self.writeQueue.sync {}
    }

    private func apply(_ s: StateSnapshot) {
        spaces = s.spaces; currentSpaceID = s.currentSpaceID; tabs = s.tabs
        if !spaces.contains(where: { $0.id == currentSpaceID }), let first = spaces.first {
            currentSpaceID = first.id
        }
        boosts = s.boosts; history = s.history; archiveAfterHours = s.archiveAfterHours
        downloadRecords = s.downloadRecords ?? []
        blockerExemptHosts = s.blockerExemptHosts ?? []
        ContentBlocker.setExemptHosts(blockerExemptHosts)
        darkModeExcludedHosts = s.darkModeExcludedHosts ?? []
        externalLinksInPeek = s.externalLinksInPeek ?? true
        shiftClickPeek = s.shiftClickPeek ?? true
        peekHotkeyEnabled = s.peekHotkeyEnabled ?? true
        boostsEnabled = s.boostsEnabled ?? true
        folders = s.folders ?? []
        // Only the built-in extensions exist now; folders from older versions can never load.
        extensions = (s.extensions ?? []).filter { $0.path.hasPrefix("builtin:") }
        seedNativeExtensions()
        darkModeHosts = s.darkModeHosts ?? []
        sitePermissions = (s.sitePermissions ?? []).filter { !$0.isEmpty }
        mutedTabIDs = Set(s.mutedTabIDs ?? [])
        sidebarWidth = (s.sidebarWidth.map {
            min(max($0, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
        }) ?? 260
        searchEngine = s.searchEngine ?? .google
        // Settings version 1 turned suggestions off by default. Older files
        // stored the old default (on), so they switch off once.
        let version = s.settingsVersion ?? 0
        searchSuggestionsEnabled = version >= 1 ? (s.searchSuggestionsEnabled ?? false) : false
        memorySaverEnabled = s.memorySaverEnabled ?? true
        askDownloadLocation = s.askDownloadLocation ?? false
        warnBeforeQuitting = s.warnBeforeQuitting ?? true
        downloadsFolder = s.downloadsFolder
        isSidebarVisible = s.isSidebarVisible ?? true
        for (k, v) in s.lastSelectedBySpace ?? [:] {
            if let id = UUID(uuidString: k) { lastSelectedBySpace[id] = v }
        }
        // Older state never recorded pin addresses.
        for i in tabs.indices where tabs[i].kind != .today && tabs[i].pinnedURLString == nil {
            tabs[i].pinnedURLString = tabs[i].urlString
        }
        // View Source tabs hold no persisted text; they would only show an error.
        // Tabs of the removed Easels/Notes pages have nothing left to show.
        tabs.removeAll { $0.viewSourceFor != nil || $0.urlString.hasPrefix("toastpeek://") }
        normalizeSortIndices()
        let remembered = lastSelectedBySpace[currentSpaceID].flatMap { id in
            tabs.first { $0.id == id && !$0.isArchived && ($0.spaceID == currentSpaceID || $0.kind == .favorite) }
        }
        selectedTabID = (remembered ?? today(in: currentSpaceID).first ?? pinned(in: currentSpaceID).first)?.id
    }

    /// Explains an unreadable state file once the first window is up.
    func presentStateLoadProblemIfNeeded() {
        guard let problem = stateLoadProblem else { return }
        stateLoadProblem = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Your Spaces and tabs couldn’t be loaded")
        if problem.writesAllowed {
            alert.informativeText = String(localized: "The saved file was kept unchanged next to the new one. ToastPeek started with default tabs.")
        } else {
            alert.informativeText = String(localized: "The saved file couldn’t be moved aside, so ToastPeek won’t save anything this session.")
        }
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        alert.addButton(withTitle: String(localized: "Quit"))
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            let files = problem.keptCopies.isEmpty ? [dataFileURL] : problem.keptCopies
            NSWorkspace.shared.activateFileViewerSelecting(files)
        case .alertThirdButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

/// Request to open the Space editor sheet.
struct SpaceEditorRequest: Identifiable, Equatable {
    let id = UUID()
    /// nil = create a new Space.
    var spaceID: UUID?
}

// MARK: - Peek windows

extension BrowserStore {
    func registerPeekTab(_ tab: BrowserTab) {
        peekTabs[tab.id] = tab
    }

    func discardPeekTab(_ id: UUID) {
        peekTabs.removeValue(forKey: id)
        unload(id)
    }

    func navigatePeek(_ id: UUID, to urlString: String) {
        peekTabs[id]?.urlString = urlString
        controller(forTabID: id)?.load(urlString)
    }

    /// Moves a Peek page into a Space as a Today tab, keeping its live browser.
    func adoptPeekTab(_ tab: BrowserTab, intoSpace spaceID: UUID) {
        var t = peekTabs.removeValue(forKey: tab.id) ?? tab
        if let live = controller(forTabID: tab.id) { t.urlString = live.currentURLString }
        if spaceID != currentSpaceID { switchSpace(to: spaceID) }
        t.spaceID = spaceID
        // A live browser keeps the data store it was created with. If the
        // target Space uses another one, reload there under its cookies.
        if let live = controller(forTabID: tab.id),
           live.dataStoreID != profileSpace(for: t).dataStoreID {
            unload(tab.id)
        }
        t.kind = .today
        t.lastVisitedAt = Date()
        t.sortIndex = (today(in: spaceID).map(\.sortIndex).min() ?? 0) - 1
        tabs.append(t)
        select(t)
    }
}
