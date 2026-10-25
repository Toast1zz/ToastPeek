import SwiftUI

/// Peek: a compact window for a quick look at a link. The page runs in a
/// temporary tab that isn't in any Space until you open it in one — then it
/// keeps going, unreloaded, as a Today tab.
struct PeekWindowView: View {
    let onClose: () -> Void
    let onMoveToSpace: (BrowserTab, UUID) -> Void
    @EnvironmentObject var store: BrowserStore
    @State private var tab: BrowserTab
    @State private var editing: Bool
    @State private var address = ""
    @State private var moved = false
    @State private var spaceMenuOpen = false
    @FocusState private var addressFocused: Bool

    init(url: URL?, profileSpace: BrowserSpace? = nil, onClose: @escaping () -> Void, onMoveToSpace: @escaping (BrowserTab, UUID) -> Void) {
        self.onClose = onClose
        self.onMoveToSpace = onMoveToSpace
        var initial = BrowserTab(spaceID: profileSpace?.id, kind: .today, title: "",
                                 urlString: url?.absoluteString ?? "about:blank")
        initial.profileID = profileSpace?.dataStoreID
        _tab = State(initialValue: initial)
        _editing = State(initialValue: url == nil)
    }

    private var liveTab: BrowserTab { store.peekTabs[tab.id] ?? tab }

    var body: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            BrowserPaneView(tab: liveTab)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    // Click the page to fold the Space list back up.
                    if spaceMenuOpen {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { withAnimation(Self.unfold) { spaceMenuOpen = false } }
                    }
                }
                .padding([.horizontal, .bottom], 6)
        }
        // One row with the traffic lights, like a compact bar, instead of a
        // title-bar row above the address bar.
        .ignoresSafeArea(.container, edges: .top)
        .background(SpaceBackdrop(color: store.currentSpace.color).ignoresSafeArea())
        .onAppear { store.registerPeekTab(tab) }
        .onDisappear { if !moved { store.discardPeekTab(tab.id) } }
    }

    static let unfold = Animation.spring(response: 0.28, dampingFraction: 0.9)

    private var otherSpaces: [BrowserSpace] { store.spaces.filter { $0.id != store.currentSpaceID } }

    private var header: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 64)
            NavigationButtons(controller: store.controller(forTabID: tab.id))
            ChromeButton(symbol: "arrow.clockwise", label: "Reload") { store.controller(forTabID: tab.id)?.reload() }
            Group {
                if editing {
                    TextField("Search or enter address", text: $address)
                        .textFieldStyle(.plain)
                        .focused($addressFocused)
                        .onSubmit {
                            if let url = URLResolver.resolve(address, engine: store.searchEngine) {
                                store.navigatePeek(tab.id, to: url.absoluteString)
                            }
                            editing = false
                        }
                        .onExitCommand { editing = false }
                        .onAppear { addressFocused = true }
                } else {
                    Text(liveTab.displayHost.isEmpty ? "Peek" : liveTab.displayHost)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { address = liveTab.urlString; editing = true }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            OpenInSpaceButton(current: store.currentSpace, others: otherSpaces,
                              expanded: spaceMenuOpen,
                              toggle: { withAnimation(Self.unfold) { spaceMenuOpen.toggle() } },
                              open: { spaceID in
                                  withAnimation(Self.unfold) { spaceMenuOpen = false }
                                  moved = true
                                  onMoveToSpace(liveTab, spaceID)
                              })
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

/// Opaque fill shared by the button and its unfolded list, so the two read
/// as one shape: the backdrop tint with the same wash the address field has.
private struct PillBackground: View {
    var bottomOnly = false
    var expandedAbove = false
    let color: Color
    var body: some View {
        let r: CGFloat = 7
        let shape = UnevenRoundedRectangle(topLeadingRadius: bottomOnly ? 0 : r,
                                           bottomLeadingRadius: expandedAbove ? 0 : r,
                                           bottomTrailingRadius: expandedAbove ? 0 : r,
                                           topTrailingRadius: bottomOnly ? 0 : r, style: .continuous)
        ZStack {
            SpaceBackdrop(color: color)
            Color.primary.opacity(0.07)
        }
        .clipShape(shape)
    }
}

private struct SpaceRow: View {
    let space: BrowserSpace
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                SpaceIcon(space: space, size: 11)
                Text("Open in \(space.name)").lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: OpenInSpaceButton.rowHeight)
            .background(hovering ? Color.primary.opacity(0.09) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Opens the page in the current Space with one click; the chevron unfolds
/// the other Spaces underneath, as rows the same size and style as the button.
private struct OpenInSpaceButton: View {
    static let rowHeight: CGFloat = 26
    let current: BrowserSpace
    let others: [BrowserSpace]
    let expanded: Bool
    let toggle: () -> Void
    let open: (UUID) -> Void
    @State private var hoverMain = false
    @State private var hoverMenu = false
    @State private var width: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Button { open(current.id) } label: {
                HStack(spacing: 6) {
                    SpaceIcon(space: current, size: 11)
                    Text("Open in \(current.name)").lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: Self.rowHeight)
                .background(hoverMain ? Color.primary.opacity(0.09) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverMain = $0 }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open in \(current.name)")

            if !others.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14)
                Button(action: toggle) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 24, height: Self.rowHeight)
                        .background(hoverMenu ? Color.primary.opacity(0.09) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverMenu = $0 }
                .accessibilityLabel("Choose a Space")
            }
        }
        .background(PillBackground(expandedAbove: expanded, color: current.color))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { width = geo.size.width }
        })
        .overlay(alignment: .topLeading) { list }
    }

    private var list: some View {
        ZStack(alignment: .top) {
            if expanded {
                VStack(spacing: 0) {
                    ForEach(others) { space in
                        SpaceRow(space: space) { open(space.id) }
                    }
                }
                .background(PillBackground(bottomOnly: true, color: current.color))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: width, height: CGFloat(others.count) * Self.rowHeight, alignment: .top)
        .clipped()
        .offset(y: Self.rowHeight)
        .allowsHitTesting(expanded)
    }
}
