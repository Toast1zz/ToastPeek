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

/// Find in page (Cmd+F): typing restarts the search, Return / chevrons step
/// through matches, Esc closes.
struct FindBarView: View {
    @EnvironmentObject var store: BrowserStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            TextField("Find on page", text: $store.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit { store.findNext(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onChange(of: store.findText) { store.performFind() }
                .onKeyPress(.escape) { store.hideFindBar(); return .handled }
            Text(countText)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Color(nsColor: store.findMatchCount == 0 && !store.findText.isEmpty
                                       ? .systemRed : .secondaryLabelColor))
                .frame(minWidth: 54, alignment: .trailing)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 16)
            ChromeButton(symbol: "chevron.up", label: "Previous Match", enabled: store.findMatchCount > 0, size: 22) {
                store.findNext(forward: false)
            }
            ChromeButton(symbol: "chevron.down", label: "Next Match", enabled: store.findMatchCount > 0, size: 22) {
                store.findNext(forward: true)
            }
            ChromeButton(symbol: "xmark", label: "Close", size: 22) { store.hideFindBar() }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: 36)
        .floatingPanel()
        .onAppear { focused = true }
    }

    private var countText: String {
        if store.findText.isEmpty { return "" }
        if store.findMatchCount == 0 { return "No matches" }
        if store.findActiveOrdinal > 0 { return "\(store.findActiveOrdinal) of \(store.findMatchCount)" }
        return "\(store.findMatchCount)"
    }
}
