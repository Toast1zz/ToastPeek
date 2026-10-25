import SwiftUI
import AppKit

/// Space-tinted window background: one flat tint behind the sidebar and
/// around the page card. Tuned separately for light and dark.
struct SpaceBackdrop: View {
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemPurple
        let base: (Double, Double, Double) = scheme == .dark ? (0.075, 0.075, 0.095) : (0.965, 0.965, 0.975)
        let t = scheme == .dark ? 0.18 : 0.26
        return Color(red: base.0 * (1 - t) + Double(ns.redComponent) * t,
                     green: base.1 * (1 - t) + Double(ns.greenComponent) * t,
                     blue: base.2 * (1 - t) + Double(ns.blueComponent) * t)
    }
}

/// Window dragging on the exposed backdrop only (never over web content).
private struct WindowDragGestureModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// Hands the hosting NSWindow to the window state once it exists.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in if let w = v?.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState

    private let cardMargin: CGFloat = 8
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var peekingSidebar = false

    private var isFullscreenContent: Bool { windowState.fullscreenTabID != nil }
    private var sidebarWidth: CGFloat { store.effectiveSidebarWidth(windowState) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpaceBackdrop(color: windowState.space(in: store).color)
                .ignoresSafeArea()
                .modifier(WindowDragGestureModifier())
                .animation(.easeInOut(duration: 0.35), value: windowState.space(in: store).id)

            HStack(spacing: 0) {
                if store.isSidebarVisible && !isFullscreenContent {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                contentCard
            }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topLeading) {
                // The strip between the sidebar and the page card.
                if store.isSidebarVisible && !isFullscreenContent && windowState.library == nil {
                    SidebarResizeHandle(onBegin: beginSidebarResize, onDrag: dragSidebarResize, onEnd: endSidebarResize)
                        .frame(width: 11)
                        .frame(maxHeight: .infinity)
                        .offset(x: sidebarWidth - 8)
                        .ignoresSafeArea()
                }
            }
            .background(SidebarRevealTracker(isEnabled: !store.isSidebarVisible && !isFullscreenContent,
                                             isRevealed: peekingSidebar,
                                             sidebarWidth: sidebarWidth) { show in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { peekingSidebar = show }
            })

            // Hidden sidebar, revealed from the left edge: floats over the page.
            if !store.isSidebarVisible && !isFullscreenContent && peekingSidebar {
                SidebarView()
                    .frame(width: sidebarWidth)
                    .background(SpaceBackdrop(color: windowState.space(in: store).color))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 12, topTrailingRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 16, x: 3)
                    .ignoresSafeArea()
                    .transition(.move(edge: .leading))
                    .zIndex(2)
            }

            VStack(alignment: .trailing, spacing: 8) {
                if store.isFindBarVisible { FindBarView().transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, cardMargin + 10).padding(.trailing, cardMargin + 10)

            if let toast = store.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .floatingPanel(radius: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            if store.commandBarMode != nil, store.activeWindowState === windowState {
                Color.black.opacity(0.18).ignoresSafeArea()
                    .onTapGesture { store.commandBarMode = nil }
                    .transition(.opacity)
                CommandBarView()
                    .padding(.top, 90)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            if store.showOnboarding {
                OnboardingView(startStep: store.onboardingStartStep).transition(.opacity)
            }
        }
        .background(WindowAccessor { w in windowState.window = w })
        .sheet(item: Binding(get: { store.activeWindowState === windowState ? store.spaceEditor : nil },
                             set: { store.spaceEditor = $0 })) { request in
            SpaceEditorView(request: request).environmentObject(store)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: store.isSidebarVisible)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: windowState.library == nil)
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: store.commandBarMode)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.toast)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: store.isFindBarVisible)
        .animation(.easeInOut(duration: 0.2), value: isFullscreenContent)
        .onChange(of: store.isSidebarVisible) {
            if store.isSidebarVisible { peekingSidebar = false }
            updateWindowButtons()
        }
        .onChange(of: peekingSidebar) { updateWindowButtons() }
        .onChange(of: isFullscreenContent) { updateWindowButtons() }
        .onAppear { DispatchQueue.main.async { updateWindowButtons() } }
    }

    /// The window buttons hide along with the sidebar; they come back
    /// when the sidebar slides in on hover.
    private func updateWindowButtons() {
        guard let w = windowState.window else { return }
        let show = (store.isSidebarVisible || peekingSidebar) && !isFullscreenContent
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(kind)?.isHidden = !show
        }
        TrafficLights.place(in: w)
    }

    // MARK: Sidebar resize

    private func beginSidebarResize() {
        sidebarDragStartWidth = CGFloat(store.sidebarWidth)
    }

    /// Dragging well past the minimum hides the sidebar (it comes back from the left edge).
    private func dragSidebarResize(_ dx: CGFloat) {
        let proposed = Double((sidebarDragStartWidth ?? CGFloat(store.sidebarWidth)) + dx)
        if proposed < 140 {
            if store.isSidebarVisible { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { store.isSidebarVisible = false } }
        } else {
            if !store.isSidebarVisible { store.isSidebarVisible = true }
            store.sidebarWidth = min(max(proposed, BrowserStore.sidebarWidthRange.lowerBound),
                                     BrowserStore.sidebarWidthRange.upperBound)
        }
    }

    private func endSidebarResize() {
        sidebarDragStartWidth = nil
        store.scheduleSave()
    }

    // MARK: Content card

    private var contentCard: some View {
        let radius: CGFloat = isFullscreenContent ? 0 : 10
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(isFullscreenContent ? 0 : 0.16), radius: 6, y: 1)
            Group {
                if store.showHistory && store.activeWindowState === windowState {
                    HistoryView()
                } else {
                    mainPane
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .padding(.top, isFullscreenContent ? 0 : cardMargin)
        .padding(.bottom, isFullscreenContent ? 0 : cardMargin)
        .padding(.trailing, isFullscreenContent ? 0 : cardMargin)
        .padding(.leading, isFullscreenContent ? 0 : (store.isSidebarVisible ? 0 : cardMargin))
    }

    @ViewBuilder private var mainPane: some View {
        let panes = windowState.paneTabIDs.compactMap { id in store.tabs.first { $0.id == id && !$0.isArchived } }
        if let full = windowState.fullscreenTabID, let tab = store.tab(full) {
            BrowserPaneView(tab: tab)
        } else if panes.count == 1, let first = panes.first {
            BrowserPaneView(tab: first)
        } else if panes.count > 1 {
            SplitPanes(panes: panes)
        } else {
            EmptyWindowView()
        }
    }
}

/// Window with no tab: a calm start surface.
private struct EmptyWindowView: View {
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    var body: some View {
        VStack(spacing: 14) {
            SpaceIcon(space: windowState.space(in: store), size: 30)
                .foregroundStyle(windowState.space(in: store).color)
                .frame(width: 64, height: 64)
                .background(windowState.space(in: store).color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(windowState.space(in: store).name).font(.title2.weight(.semibold))
            Button {
                store.commandBarMode = .newTab
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Search or enter address")
                    Spacer(minLength: 24)
                    Text("⌘T").foregroundStyle(.tertiary)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).frame(width: 320, height: 36)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Split view: separate cards with draggable gutters

private struct SplitPanes: View {
    let panes: [BrowserTab]
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    /// Relative widths, one per pane (reset when the pane count changes).
    @State private var fractions: [CGFloat] = []
    @State private var dragStart: [CGFloat]?
    private let gutter: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let widths = paneWidths(total: geo.size.width)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, tab in
                    paneCard(tab)
                        .frame(width: widths[index])
                    if index < panes.count - 1 {
                        gutterHandle(index: index, total: geo.size.width)
                    }
                }
            }
        }
        .padding(-0.5)
        .background(SpaceBackdrop(color: windowState.space(in: store).color))
        .onAppear { resetFractions() }
        .onChange(of: panes.count) { resetFractions() }
    }

    private func resetFractions() {
        fractions = Array(repeating: 1 / CGFloat(max(panes.count, 1)), count: panes.count)
    }

    private func paneWidths(total: CGFloat) -> [CGFloat] {
        let usable = total - gutter * CGFloat(panes.count - 1)
        let f = fractions.count == panes.count ? fractions : Array(repeating: 1 / CGFloat(panes.count), count: panes.count)
        return f.map { max(200, $0 * usable) }
    }

    private func paneCard(_ tab: BrowserTab) -> some View {
        let focused = (windowState.focusedPaneTabID ?? windowState.selectedTabID) == tab.id
        return BrowserPaneView(tab: tab)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(focused ? windowState.space(in: store).color.opacity(0.85) : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .topTrailing) {
                SplitPaneCloseButton { store.closeSplitPane(tabID: tab.id) }
                    .padding(6)
            }
            .simultaneousGesture(TapGesture().onEnded { store.notePaneFocused(tab.id) })
    }

    private func gutterHandle(index: Int, total: CGFloat) -> some View {
        Color.clear
            .frame(width: gutter)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = fractions }
                    guard var f = dragStart, f.indices.contains(index + 1) else { return }
                    let usable = total - gutter * CGFloat(panes.count - 1)
                    let delta = value.translation.width / max(usable, 1)
                    let pair = f[index] + f[index + 1]
                    let minF = 200 / max(usable, 1)
                    f[index] = min(max(f[index] + delta, minF), pair - minF)
                    f[index + 1] = pair - f[index]
                    fractions = f
                }
                .onEnded { _ in dragStart = nil })
    }
}

private struct SplitPaneCloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0.55)
        .onHover { hovering = $0 }
        .help("Close Pane")
        .accessibilityLabel("Close Pane")
    }
}

/// The app's mark, drawn (no bitmap): a peeking toast slice.
struct AppGlyph: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .frame(width: size, height: size)
    }
}

// MARK: - Import panels (menu + onboarding share these)

@MainActor
enum ImportPanels {
    static func importHistory(into store: BrowserStore) -> (Int, Int)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose “History” from a Chrome, Edge or Brave profile, or Safari’s “History.db”")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        switch HistoryImport.readHistoryResult(at: url) {
        case .success(let rows): return (store.importHistory(rows), rows.count)
        case .failure(let error): store.toast = error.localizedDescription; return (0, 0)
        }
    }

    /// Post-selection history import, shared by the panel callback and
    /// the DEBUG `importfile` probe (same code path, panel or no panel).
    static func importHistoryFile(at url: URL, into store: BrowserStore) -> (Int, Int) {
        switch HistoryImport.readHistoryResult(at: url) {
        case .success(let rows): return (store.importHistory(rows), rows.count)
        case .failure(let error): store.toast = error.localizedDescription; return (0, 0)
        }
    }

    /// Non-blocking variant of importHistory .
    static func beginImportHistory(into store: BrowserStore, completion: @escaping @MainActor @Sendable ((Int, Int)?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import")
        panel.message = String(localized: "Choose \u{201c}History\u{201d} from a Chrome, Edge or Brave profile, or Safari\u{2019}s \u{201c}History.db\u{201d}")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = HistoryImport.readHistoryResult(at: url)
                DispatchQueue.main.async {
                    switch result {
                    case .success(let rows): completion((store.importHistory(rows), rows.count))
                    case .failure(let error): store.toast = error.localizedDescription; completion(nil)
                    }
                }
            }
        }
    }
}

/// Default-browser request: macOS asks the user to confirm.
enum DefaultBrowser {
    static var isDefault: Bool {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    static func request() {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in }
        }
    }
}
