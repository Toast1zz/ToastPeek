import SwiftUI
import AppKit

/// Solid floating surface for panels that sit over web content. Vibrant
/// materials with hierarchical styles blend into the page underneath and
/// can vanish on white sites, so panels use an opaque fill instead.
struct FloatingPanelBackground: ViewModifier {
    var radius: CGFloat = 10
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: scheme == .dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.995, alpha: 1)),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }
}

extension View {
    func floatingPanel(radius: CGFloat = 10) -> some View { modifier(FloatingPanelBackground(radius: radius)) }
}

/// A small observer avoids forwarding one window's transient find state through
/// the application-wide store (and consequently every other window).
struct PageFindOverlay: View {
    @ObservedObject var state: BrowserPageState
    let tabID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if state.isFindBarVisible {
                FindBarView(state: state, tabID: tabID)
                    .frame(maxWidth: 390)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.isFindBarVisible)
    }
}

/// Find in page (Cmd+F): typing restarts the search, Return / chevrons step
/// through matches, Esc closes.
struct FindBarView: View {
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var state: BrowserPageState
    let tabID: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            TextField("Find on page", text: $state.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 70, idealWidth: 180, maxWidth: 180)
                .focused($focused)
                .onSubmit { store.findNext(in: state, forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: state.findText) { store.performFind(in: state, tabID: tabID) }
                .onKeyPress(.escape) { store.hideFindBar(in: state); return .handled }
            Text(countText)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: state.findMatchCount == 0 && !state.findText.isEmpty
                                       ? .systemRed : .secondaryLabelColor))
                .frame(minWidth: 54, alignment: .trailing)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
            ChromeButton(symbol: "chevron.up", label: "Previous Match", enabled: state.findMatchCount != 0, size: 22) {
                store.findNext(in: state, forward: false)
            }
            ChromeButton(symbol: "chevron.down", label: "Next Match", enabled: state.findMatchCount != 0, size: 22) {
                store.findNext(in: state, forward: true)
            }
            ChromeButton(symbol: "xmark", label: "Close", size: 22) { store.hideFindBar(in: state) }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 36)
        .floatingPanel()
        .onAppear { focused = true }
        .onChange(of: state.findFocusRequest) { focused = true }
        .onChange(of: tabID) { store.performFind(in: state, tabID: tabID) }
    }

    private var countText: String {
        if state.findText.isEmpty { return "" }
        if state.findMatchCount == 0 { return String(localized: "No matches") }
        if state.findMatchCount < 0 { return String(localized: "Match found") }
        if state.findActiveOrdinal > 0 { return String(localized: "\(state.findActiveOrdinal) of \(state.findMatchCount)") }
        return "\(state.findMatchCount)"
    }
}
