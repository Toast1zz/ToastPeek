import SwiftUI
import AppKit

/// Read-only page source, captured from the live page's DOM
/// (a "view-source:" load would run the page instead).
/// Nothing here executes page content.
struct ViewSourceView: View {
    let tab: BrowserTab
    @EnvironmentObject var store: BrowserStore

    private var originalURL: String { tab.viewSourceFor ?? "" }
    private var sourceText: String? { store.viewSourceTexts[tab.id] }
    private var fetchFailed: Bool { store.viewSourceFailed.contains(tab.id) }
    private var fetchRequested: Bool { store.viewSourceRequested.contains(tab.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(originalURL)
                .font(.callout).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Open Original Page") {
                store.newTab(urlString: originalURL, title: URL(string: originalURL)?.host ?? "")
            }
            .font(.caption)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if let sourceText {
            SourceTextView(text: sourceText)
        } else if fetchFailed {
            message(icon: "exclamationmark.triangle", title: "Couldn’t get the page source")
        } else if fetchRequested {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Restored from an earlier session: source is kept in memory only.
            message(icon: "clock.arrow.circlepath", title: "Open the original page to view its source again")
        }
    }

    private func message(icon: String, title: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// NSTextView lays out only what is on screen, so megabyte-sized sources
/// scroll smoothly (a SwiftUI Text would lay out the whole string).
private struct SourceTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.drawsBackground = false
            tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .textColor
            tv.textContainerInset = NSSize(width: 10, height: 10)
            // No wrapping: source lines keep their shape.
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
            tv.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }
}
