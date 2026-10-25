import SwiftUI
import AppKit

/// Shared look of sidebar rows and tiles, tuned per appearance: the selected item is lifted
/// with a bright translucent fill and a hairline shadow.
struct SidebarStyle {
    let scheme: ColorScheme
    var selectedFill: Color { scheme == .dark ? Color.white.opacity(0.13) : Color.white.opacity(0.78) }
    var hoverFill: Color { scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045) }
    var tileFill: Color { scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.42) }
    var fieldFill: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.55) }
    var hairline: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }
    var selectedShadow: Color { scheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.10) }
}

struct SidebarView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme

    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var pendingMoveTab: BrowserTab?
    @State private var showRenamePrompt = false
    @State private var renamingFolderID: UUID?
    @State private var renameText = ""
    @State private var confirmDeleteSpace: BrowserSpace?

    private var style: SidebarStyle { SidebarStyle(scheme: scheme) }

    var body: some View {
        Group {
            if let category = windowState.library {
                LibrarySidebarView(category: category)
                    .transition(.opacity)
            } else {
                mainSidebar
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: windowState.library == nil)
    }

    private var mainSidebar: some View {
        VStack(spacing: 0) {
            SidebarTopBar()
                // Clear of the traffic lights, which are hidden in full screen.
                .padding(.leading, windowState.isWindowFullscreen ? 8 : 78)
                .padding(.trailing, 6)
                .frame(height: SidebarMetrics.topBarHeight)
            AddressPill()
                .padding(.horizontal, 8)
                .padding(.bottom, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    FavoritesGrid(handleDrop: handleDrop)
                        .padding(.bottom, store.favorites.isEmpty ? 0 : 12)
                    spaceSection
                        .id(windowState.space(in: store).id)
                        .transition(.asymmetric(
                            insertion: .move(edge: windowState.spaceSwitchForward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: windowState.spaceSwitchForward ? .leading : .trailing).combined(with: .opacity)))
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: windowState.space(in: store).id)
            }
            .background(SpaceSwipeDetector())

            SpaceBar(confirmDelete: $confirmDeleteSpace)
        }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                let folder = store.createFolder(name: name.isEmpty ? String(localized: "New Folder") : name)
                if let t = pendingMoveTab { store.moveTabToFolder(t, folderID: folder.id) }
                pendingMoveTab = nil
            }
            Button("Cancel", role: .cancel) { pendingMoveTab = nil }
        }
        .alert("Rename Folder", isPresented: $showRenamePrompt) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = renamingFolderID, let folder = store.folders.first(where: { $0.id == id }) {
                    store.renameFolder(folder, to: renameText)
                }
                renamingFolderID = nil
            }
            Button("Cancel", role: .cancel) { renamingFolderID = nil }
        }
        .confirmationDialog(String(localized: "Delete “\(confirmDeleteSpace?.name ?? "")”?"),
                            isPresented: Binding(get: { confirmDeleteSpace != nil },
                                                 set: { if !$0 { confirmDeleteSpace = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Space", role: .destructive) {
                if let s = confirmDeleteSpace { store.deleteSpace(s.id) }
                confirmDeleteSpace = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteSpace = nil }
        } message: {
            Text("Its pinned tabs, folders, open tabs and site logins will be removed.")
        }
        .confirmationDialog(deleteTabTitle,
                            isPresented: Binding(get: { store.pendingDeleteTab != nil },
                                                 set: { if !$0 { store.pendingDeleteTab = nil } }),
                            titleVisibility: .visible) {
            Button(store.pendingDeleteTab?.kind == .favorite ? "Delete Favorite" : "Delete Pinned Tab",
                   role: .destructive) {
                if let t = store.pendingDeleteTab { store.delete(t) }
                store.pendingDeleteTab = nil
            }
            Button("Cancel", role: .cancel) { store.pendingDeleteTab = nil }
        }
    }

    private var deleteTabTitle: String {
        let name = store.pendingDeleteTab?.displayTitle ?? ""
        return String(localized: "Delete “\(name)”?")
    }

    // MARK: Space section: header, pinned, folders, new tab, today

    private var spaceSection: some View {
        let spaceID = windowState.space(in: store).id
        let ungrouped = store.pinned(in: spaceID, folderID: nil)
        let folders = store.folders(in: spaceID)
        let today = store.today(in: spaceID)
        return VStack(alignment: .leading, spacing: 2) {
            SpaceHeader(onNewFolder: { pendingMoveTab = nil; newFolderName = ""; showNewFolderPrompt = true },
                        onDelete: { confirmDeleteSpace = windowState.space(in: store) })
                .padding(.bottom, 4)

            ForEach(ungrouped) { tab in tabRow(tab) }
            ForEach(folders) { folder in folderGroup(folder) }
            DropStrip { handleDrop($0, kind: .pinned, folderID: nil, before: nil) }

            TodayDivider(hasTabs: !today.isEmpty)
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, kind: .today, folderID: nil, before: today.first?.id)
                }

            NewTabRow()
            ForEach(today) { tab in tabRow(tab) }
            Color.clear
                .frame(height: 80)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, kind: .today, folderID: nil, before: nil)
                }
        }
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        TabRowView(tab: tab, menu: { tabMenu(tab) },
                   onDrop: { items in
                       handleDrop(items, kind: tab.kind,
                                  folderID: tab.kind == .pinned ? tab.folderID : nil, before: tab.id)
                   })
    }

    private func folderGroup(_ folder: TabFolder) -> some View {
        let tabs = store.pinned(in: windowState.space(in: store).id, folderID: folder.id)
        return VStack(alignment: .leading, spacing: 2) {
            FolderRow(folder: folder, count: tabs.count) { folderMenu(folder) }
                .dropDestination(for: String.self) { items, _ in
                    handleDrop(items, kind: .pinned, folderID: folder.id, before: nil)
                }
            Collapsible(expanded: !folder.isCollapsed) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(tabs) { tab in tabRow(tab) }
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder private func folderMenu(_ folder: TabFolder) -> some View {
        Button("Rename…") { renamingFolderID = folder.id; renameText = folder.name; showRenamePrompt = true }
        Button(folder.isCollapsed ? "Expand" : "Collapse") { store.toggleFolderCollapse(folder) }
        Divider()
        Button("Delete Folder", role: .destructive) { store.deleteFolder(folder) }
    }

    private func handleDrop(_ items: [String], kind: TabKind, folderID: UUID?, before: UUID?) -> Bool {
        guard let raw = items.first, let id = UUID(uuidString: raw),
              let dragged = store.tab(id), !dragged.isArchived, dragged.id != before else { return false }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            store.reorderTab(dragged, targetKind: kind, folderID: folderID, insertBefore: before)
        }
        return true
    }

    @ViewBuilder func tabMenu(_ tab: BrowserTab) -> some View {
        TabContextMenu(tab: tab, onNewFolder: {
            pendingMoveTab = tab; newFolderName = ""; showNewFolderPrompt = true
        })
    }
}

// MARK: - Top bar: navigation buttons beside the traffic lights

private struct SidebarTopBar: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            NavigationButtons(controller: store.controller(forTabID: windowState.focusedPaneTabID ?? windowState.selectedTabID))
            SidebarMoreMenu(controller: store.controller(forTabID: windowState.focusedPaneTabID ?? windowState.selectedTabID))
        }
    }
}

/// Layout constants shared with the window chrome.
enum SidebarMetrics {
    /// Row the traffic lights sit in; the nav buttons are centered on it.
    static let topBarHeight: CGFloat = 40
    /// Where AppKit is asked to center the traffic lights (from the top).
    static let trafficLightCenterY: CGFloat = topBarHeight / 2
}

/// The "⋯" beside the arrows: a small panel with Reload and Show/Hide
/// Sidebar, each row an icon, a title and its shortcut.
private struct SidebarMoreMenu: View {
    let controller: WebTabController?
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.72))
                .frame(width: 26, height: 26)
                .background(hovering || open ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("More")
        .accessibilityLabel("More")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                if let controller, controller.isLoading {
                    MoreRow(symbol: "xmark", title: "Stop Loading", shortcut: "") {
                        controller.stop(); open = false
                    }
                } else {
                    MoreRow(symbol: "arrow.clockwise", title: "Reload",
                            shortcut: Self.shortcut("menuReload"), enabled: controller != nil) {
                        controller?.reload(); open = false
                    }
                }
                MoreRow(symbol: "sidebar.left", title: "Toggle Sidebar", shortcut: Self.shortcut("menuToggleSidebar")) {
                    open = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { store.isSidebarVisible.toggle() }
                    store.scheduleSave()
                }
            }
            .padding(6)
            .frame(width: 236)
            .environmentObject(store)
        }
    }

    /// Current (possibly rebound) shortcut of a menu command, e.g. "⌘R".
    private static func shortcut(_ id: String) -> String {
        guard let row = ShortcutStore.shared.rows().first(where: { $0.id == id }) else { return "" }
        return ShortcutStore.display(row.binding)
    }
}

private struct MoreRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let shortcut: String
    var enabled = true
    let action: () -> Void
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hovering ? Color.white.opacity(0.65) : Color.secondary)
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 42)
            // The system popover's corner is ~18pt and the panel pads 6pt, so
            // 12pt keeps the highlight concentric with it.
            .background(hovering ? windowState.space(in: store).color.opacity(0.85) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
    }
}

struct NavigationButtons: View {
    let controller: WebTabController?
    var body: some View {
        if let controller {
            LiveNavigationButtons(controller: controller)
        } else {
            HStack(spacing: 2) {
                ChromeButton(symbol: "arrow.left", label: "Back", enabled: false) {}
                ChromeButton(symbol: "arrow.right", label: "Forward", enabled: false) {}
            }
        }
    }
}

private struct LiveNavigationButtons: View {
    @ObservedObject var controller: WebTabController
    var body: some View {
        HStack(spacing: 2) {
            ChromeButton(symbol: "arrow.left", label: "Back", enabled: controller.canGoBack) { controller.goBack() }
            ChromeButton(symbol: "arrow.right", label: "Forward", enabled: controller.canGoForward) { controller.goForward() }
        }
    }
}

/// Small borderless glyph button with a hover wash.
struct ChromeButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var enabled: Bool = true
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(enabled ? Color.primary.opacity(0.72) : Color.primary.opacity(0.25))
                .background(hovering && enabled ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Address pill

private struct AddressPill: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var showSiteControls = false
    @State private var copied = false

    private var tab: BrowserTab? { store.tab(windowState.focusedPaneTabID ?? windowState.selectedTabID) }

    var body: some View {
        HStack(spacing: 6) {
            if let tab, tab.url.scheme == "http" {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Not secure")
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(tab == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let tab, tab.url.scheme != "about" {
                HStack(spacing: 0) {
                    PillButton(symbol: copied ? "checkmark" : "link", label: "Copy Link") {
                        store.copyCurrentURL()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    if tab.url.scheme == "http" || tab.url.scheme == "https" {
                        PillButton(symbol: "slider.horizontal.3", label: "Site Controls") { showSiteControls.toggle() }
                            .popover(isPresented: $showSiteControls, arrowEdge: .bottom) {
                                SiteControlsView(tab: tab).environmentObject(store)
                            }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 36)
        .background(SidebarStyle(scheme: scheme).fieldFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            if let c = store.controller(forTabID: tab?.id) { PillProgress(controller: c) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.commandBarMode = .editCurrent }
        .accessibilityAddTraits(.isButton)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var label: String {
        guard let tab else { return String(localized: "Search or enter address") }
        if tab.viewSourceFor != nil { return String(localized: "Source of \(URL(string: tab.viewSourceFor ?? "")?.host ?? "")") }
        if tab.url.scheme == "about" { return String(localized: "New Tab") }
        if tab.url.isFileURL { return tab.url.lastPathComponent }
        return tab.displayHost.isEmpty ? tab.urlString : tab.displayHost
    }
}

/// Icon button inside the address pill (Copy Link, Site Controls).
private struct PillButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.85 : 0.6))
                .frame(width: 26, height: 26)
                .background(hovering ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct PillProgress: View {
    @ObservedObject var controller: WebTabController
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(windowState.space(in: store).color.opacity(0.55))
                .frame(width: geo.size.width * (controller.isLoading ? max(0.05, controller.progress) : 1), height: 2)
                .opacity(controller.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: controller.progress)
                .animation(.easeOut(duration: 0.4), value: controller.isLoading)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @EnvironmentObject var store: BrowserStore
    let handleDrop: ([String], TabKind, UUID?, UUID?) -> Bool

    var body: some View {
        let favorites = store.favorites
        if !favorites.isEmpty {
            let columns = max(2, min(5, Int((store.sidebarWidth - 16) / 58)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(favorites) { tab in
                    FavoriteTile(tab: tab)
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(items, .favorite, nil, tab.id)
                        }
                }
            }
            .dropDestination(for: String.self) { items, _ in handleDrop(items, .favorite, nil, nil) }
        }
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let selected = windowState.selectedTabID == tab.id
        let style = SidebarStyle(scheme: scheme)
        let loaded = store.controller(forTabID: tab.id)?.hasBrowser == true
        FaviconView(host: tab.host, size: 20)
            .opacity(loaded || selected ? 1 : 0.85)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(selected ? style.selectedFill : (hovering ? style.tileFill.opacity(1.6) : style.tileFill),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: selected ? style.selectedShadow : .clear, radius: 1.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture { store.select(tab) }
            .accessibilityAddTraits(.isButton)
            .onHover { hovering = $0 }
            .overlay { TabDragHandle(tabID: tab.id, title: tab.displayTitle) }
            .contextMenu { TabContextMenu(tab: tab, onNewFolder: {}) }
            .help(tab.displayTitle)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Space header

private struct SpaceHeader: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    let onNewFolder: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let space = windowState.space(in: store)
        HStack(spacing: 6) {
            SpaceIcon(space: space, size: 13)
                .foregroundStyle(space.color)
            Text(space.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("New Folder") { onNewFolder() }
                Button("Edit Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
                Divider()
                Button("Delete Space…", role: .destructive) { onDelete() }
                    .disabled(store.spaces.count < 2)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .accessibilityLabel("Space Options")
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
    }
}

/// A Space's icon: an SF Symbol name or an emoji.
struct SpaceIcon: View {
    let space: BrowserSpace
    var size: CGFloat = 14
    var body: some View {
        if space.iconIsSymbol {
            Image(systemName: space.icon).font(.system(size: size, weight: .medium))
        } else {
            Text(space.icon).font(.system(size: size))
        }
    }
}

// MARK: - Rows

private struct TodayDivider: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    let hasTabs: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(SidebarStyle(scheme: scheme).hairline).frame(height: 1)
            if hasTabs && hovering {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { store.clearToday() }
                } label: {
                    Label("Clear", systemImage: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Archive all Today tabs")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

private struct NewTabRow: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(hovering ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.commandBarMode = .newTab }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

private struct FolderRow<MenuItems: View>: View {
    let folder: TabFolder
    let count: Int
    @ViewBuilder let menu: () -> MenuItems
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: folder.isCollapsed ? "folder" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            Text(folder.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                .opacity(hovering || folder.isCollapsed ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(hovering ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.toggleFolderCollapse(folder) }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .contextMenu { menu() }
    }
}

/// Thin drop target that appends to a group.
private struct DropStrip: View {
    let onDrop: ([String]) -> Bool
    @State private var targeted = false
    var body: some View {
        Rectangle()
            .fill(targeted ? Color.accentColor : .clear)
            .frame(height: 2)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { targeted = $0 }
    }
}

/// Favicon that dims behind a small spinner while the tab loads.
private struct RowIcon: View {
    let tab: BrowserTab
    let controller: WebTabController?
    var body: some View {
        if let controller { Live(host: tab.host, controller: controller) } else { FaviconView(host: tab.host, size: 16) }
    }
    private struct Live: View {
        let host: String
        @ObservedObject var controller: WebTabController
        var body: some View {
            ZStack {
                FaviconView(host: host, size: 16).opacity(controller.isLoading ? 0.3 : 1)
                if controller.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.65).transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
            .animation(.easeOut(duration: 0.15), value: controller.isLoading)
        }
    }
}

/// Speaker on tabs that are playing or muted; click toggles mute.
private struct RowAudio: View {
    let tab: BrowserTab
    let controller: WebTabController?
    var body: some View {
        if let controller { Live(tab: tab, controller: controller) } else { Muted(tab: tab) }
    }
    private struct Muted: View {
        let tab: BrowserTab
        @EnvironmentObject var store: BrowserStore
        var body: some View {
            if store.isTabMuted(tab) { SpeakerButton(tab: tab, muted: true) }
        }
    }
    private struct Live: View {
        let tab: BrowserTab
        @ObservedObject var controller: WebTabController
        @EnvironmentObject var store: BrowserStore
        var body: some View {
            let muted = store.isTabMuted(tab)
            if controller.isPlayingMedia || muted { SpeakerButton(tab: tab, muted: muted) }
        }
    }
    private struct SpeakerButton: View {
        let tab: BrowserTab
        let muted: Bool
        @EnvironmentObject var store: BrowserStore
        var body: some View {
            Button { store.toggleTabMuted(tab) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Unmute Tab" : "Mute Tab")
            .accessibilityLabel(muted ? "Unmute Tab" : "Mute Tab")
            .accessibilityLabel(muted ? "Unmute Tab" : "Mute Tab")
        }
    }
}

/// One tab row: favicon, title, hover close. The selected row gets a
/// bright lift; an insertion line shows where a drag will land.
struct TabRowView<MenuItems: View>: View {
    let tab: BrowserTab
    @ViewBuilder let menu: () -> MenuItems
    let onDrop: ([String]) -> Bool
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var dropTargeted = false

    private var isSelected: Bool { windowState.selectedTabID == tab.id }
    private var isInSplit: Bool { windowState.splitTabIDs.contains(tab.id) }

    var body: some View {
        let style = SidebarStyle(scheme: scheme)
        HStack(spacing: 9) {
            RowIcon(tab: tab, controller: store.controller(forTabID: tab.id))
            Text(tab.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))
            Spacer(minLength: 0)
            RowAudio(tab: tab, controller: store.controller(forTabID: tab.id))
            if isInSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if hovering {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.close(tab) }
                } label: {
                    Image(systemName: tab.kind == .today ? "xmark" : "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(style.hoverFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(tab.kind == .today ? "Close Tab" : "Unload Tab")
                .accessibilityLabel(tab.kind == .today ? "Close Tab" : "Unload Tab")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? style.selectedFill : (hovering ? style.hoverFill : .clear))
                .shadow(color: isSelected ? style.selectedShadow : .clear, radius: 1.5, y: 1)
        )
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -2).padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { store.select(tab) }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .overlay { TabDragHandle(tabID: tab.id, title: tab.displayTitle) }
        .contextMenu { menu() }
        .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { dropTargeted = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Tab context menu

struct TabContextMenu: View {
    let tab: BrowserTab
    let onNewFolder: () -> Void
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState

    var body: some View {
        if tab.kind == .favorite {
            Button("Remove from Favorites") { store.toggleFavorite(tab) }
            Button("Pin to Space") { store.pin(tab) }
        } else {
            Button(tab.kind == .pinned ? "Unpin" : "Pin") { store.pin(tab) }
            Button("Add to Favorites") { store.toggleFavorite(tab) }
        }
        if tab.hasDriftedFromPin {
            Button("Back to Pinned Page") { store.resetToPinnedURL(tab) }
            Button("Pin Current Page Instead") { store.updatePinnedURL(tab) }
        }
        if tab.kind != .favorite {
            Menu("Move to Folder") {
                if tab.kind == .pinned && tab.folderID != nil {
                    Button("No Folder") { store.moveTabToFolder(tab, folderID: nil) }
                    Divider()
                }
                ForEach(store.folders(in: windowState.space(in: store).id)) { folder in
                    Button(folder.name) { store.moveTabToFolder(tab, folderID: folder.id) }
                }
                Divider()
                Button("New Folder…") { onNewFolder() }
            }
        }
        if store.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != tab.spaceID }) { space in
                    Button(space.name) { store.move(tab, toSpace: space.id) }
                }
            }
        }
        Divider()
        Button("Open in Split View") { store.toggleSplit(with: tab) }
        Button("Duplicate") { store.duplicate(tab) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.urlString, forType: .string)
        }
        Button(store.isTabMuted(tab) ? "Unmute" : "Mute") { store.toggleTabMuted(tab) }
        Divider()
        if tab.kind == .today {
            Button("Close Tabs Below") { store.closeTabsBelow(tab) }
            Button("Close Other Tabs") { store.closeOtherTabs(keeping: tab) }
            Button("Close Tab") { store.close(tab) }
        } else {
            Button("Unload") { store.close(tab) }
            Button(tab.kind == .favorite ? "Delete Favorite" : "Delete Pinned Tab", role: .destructive) {
                store.requestDelete(tab)
            }
        }
    }
}

// MARK: - Space bar (bottom)

private struct SpaceBar: View {
    @EnvironmentObject var store: BrowserStore
    @Binding var confirmDelete: BrowserSpace?

    var body: some View {
        HStack(spacing: 0) {
            LibraryButton()
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                ForEach(store.spaces) { space in
                    SpaceDot(space: space, confirmDelete: $confirmDelete)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("New Tab") { store.commandBarMode = .newTab }
                Button("New Split View") { store.openInSplit(nil) }
                Divider()
                Button("New Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: nil) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("New")
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

private struct SpaceDot: View {
    let space: BrowserSpace
    @Binding var confirmDelete: BrowserSpace?
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let active = windowState.space(in: store).id == space.id
        let index = (store.spaces.firstIndex(of: space) ?? 0) + 1
        Group {
            if store.spaces.count > 6 && !active {
                Circle().fill(Color.primary.opacity(hovering ? 0.5 : 0.3)).frame(width: 6, height: 6)
            } else {
                SpaceIcon(space: space, size: 13)
                    .foregroundStyle(Color.primary.opacity(active ? 0.85 : (hovering ? 0.6 : 0.38)))
            }
        }
        .frame(width: 26, height: 26)
        .background(active ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { store.switchSpace(to: space.id) }
        .onHover { hovering = $0 }
        .help(index <= 9 ? "\(space.name)  ⌃\(index)" : space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Edit Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
            Button("Move Left") { store.moveSpace(space.id, by: -1) }
                .disabled(store.spaces.first == space)
            Button("Move Right") { store.moveSpace(space.id, by: 1) }
                .disabled(store.spaces.last == space)
            Divider()
            Button("Delete Space…", role: .destructive) { confirmDelete = space }
                .disabled(store.spaces.count < 2)
        }
    }
}

/// Opens the Library (the bottom-left button). While something is
/// downloading, a thin ring around it shows the progress.
private struct LibraryButton: View {
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        ZStack {
            ChromeButton(symbol: "archivebox", label: "Library") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { store.openLibrary() }
            }
            if let p = store.activeDownloadProgress {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(Color.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.3), value: p)
            }
        }
    }
}

// MARK: - Two-finger swipe between Spaces

/// Watches horizontal trackpad scrolls over the sidebar and switches Space
/// once per gesture.
struct SpaceSwipeDetector: NSViewRepresentable {
    @EnvironmentObject var store: BrowserStore

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        v.onSwipe = { [weak store] dir in MainActor.assumeIsolated { store?.switchSpaceRelative(dir) } }
        return v
    }
    func updateNSView(_ nsView: SwipeView, context: Context) {}

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        deinit { MainActor.assumeIsolated { if let monitor { NSEvent.removeMonitor(monitor) } } }

        private func handle(_ event: NSEvent) {
            guard event.window === window, event.hasPreciseScrollingDeltas else { return }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return }
            if event.phase == .began { accumulated = 0; fired = false }
            if event.phase == .ended || event.phase == .cancelled { accumulated = 0; fired = false; return }
            guard event.phase == .changed, !fired else { return }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            accumulated += event.scrollingDeltaX
            if abs(accumulated) > 60 {
                fired = true
                // Natural scrolling: fingers moving left (negative delta) go forward.
                onSwipe?(accumulated < 0 ? 1 : -1)
            }
        }
    }
}

/// Height-animated disclosure: the content keeps its natural height while
/// the container grows or shrinks around it, clipped, with a short fade.
/// (Inserting and removing the content instead makes the rows below jump
/// and the folder's rows overlap them mid-animation.)
struct Collapsible<Content: View>: View {
    let expanded: Bool
    @ViewBuilder var content: Content
    @State private var height: CGFloat?

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { height = geo.size.height }
                    .onChange(of: geo.size.height) { height = geo.size.height }
            })
            .frame(height: expanded ? height : 0, alignment: .top)
            .clipped()
            .opacity(expanded ? 1 : 0)
            .allowsHitTesting(expanded)
            .animation(.spring(response: 0.34, dampingFraction: 0.9), value: expanded)
    }
}
