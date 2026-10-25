import SwiftUI
import AppKit

/// The content area for one tab: the live page (or the source viewer), the
/// load-error card, the hovered-link pill and the load progress line.
struct BrowserPaneView: View {
    let tab: BrowserTab
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        if tab.viewSourceFor != nil {
            ViewSourceView(tab: tab)
        } else {
            LivePane(tab: tab, controller: store.controller(for: tab))
                .id(tab.id)
        }
    }
}

private struct LivePane: View {
    let tab: BrowserTab
    @ObservedObject var controller: WebTabController
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        WebContainerHost(controller: controller)
            .overlay {
                if let error = controller.loadError {
                    LoadErrorView(error: error, retry: { controller.reload() }, proceed: { controller.proceedAnyway() })
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !controller.hoveredLink.isEmpty && !controller.isFullscreen {
                    Text(controller.hoveredLink)
                        .font(.system(size: 11))
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(8)
                        .frame(maxWidth: 520, alignment: .leading)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                ProgressLine(isLoading: controller.isLoading, progress: controller.progress,
                             tint: store.space(for: tab).color)
            }
            .animation(.easeOut(duration: 0.12), value: controller.hoveredLink.isEmpty)
    }
}

/// Thin top-edge progress line, fading out when the load settles.
private struct ProgressLine: View {
    let isLoading: Bool
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(tint)
                .frame(width: geo.size.width * max(0.08, isLoading ? progress : 1), height: 2)
                .opacity(isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.25), value: progress)
                .animation(.easeOut(duration: 0.35).delay(isLoading ? 0 : 0.15), value: isLoading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

private struct LoadErrorView: View {
    let error: PageLoadError
    let retry: () -> Void
    var proceed: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 12) {
                Image(systemName: error.icon)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(error.title).font(.title3.weight(.semibold))
                Text(URL(string: error.urlString)?.host ?? error.urlString)
                    .font(.callout).foregroundStyle(.secondary)
                Text(error.text)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                Button("Try Again", action: retry)
                    .keyboardShortcut("r", modifiers: .command)
                    .controlSize(.large)
                    .padding(.top, 6)
                if proceed != nil, (-1202 ... -1200).contains(error.code) {
                    Button("Visit Anyway") { proceed?() }
                        .controlSize(.large)
                }
            }
            .padding(32)
        }
    }
}

/// Hosts a tab's persistent browser container. Attaching moves the
/// container here (out of whichever host had it); dismantling only detaches
/// it — the browser itself keeps running.
struct WebContainerHost: NSViewRepresentable {
    let controller: WebTabController

    func makeNSView(context: Context) -> PaneHostView {
        let host = PaneHostView()
        host.controller = controller
        return host
    }

    func updateNSView(_ host: PaneHostView, context: Context) {
        host.controller = controller
        host.attachIfPossible()
    }

    static func dismantleNSView(_ host: PaneHostView, coordinator: ()) {
        host.detach()
    }
}

final class PaneHostView: NSView {
    weak var controller: WebTabController?

    override var isFlipped: Bool { true }

    func attachIfPossible() {
        guard let controller, let window, bounds.width > 0, bounds.height > 0,
              controller.store?.mayPresent(tabID: controller.tabID, in: window) != false else { return }
        let container = controller.container
        // SwiftUI may reuse this host for a different tab: drop any other
        // tab's container still parked here.
        for sub in subviews where sub !== container { sub.removeFromSuperview() }
        if container.superview !== self {
            container.removeFromSuperview()
            container.frame = bounds
            container.autoresizingMask = [.width, .height]
            addSubview(container)
        }
        controller.lastShownAt = Date()
        controller.recordPresentationEvent("attach")
        // Create the web view only once the container sits in a window with
        // a real size, so it starts at the pane's actual size.
        if !controller.hasBrowser {
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller, controller.container.superview === self else { return }
                MainActor.assumeIsolated { controller.ensureBrowser() }
            }
        }
    }

    func detach() {
        guard let controller else { return }
        if controller.container.superview === self {
            controller.container.removeFromSuperview()
        }
        controller.lastShownAt = Date()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attachIfPossible() } else { detach() }
    }

    override func layout() {
        super.layout()
        // SwiftUI can insert this host at zero size, then lay it out without
        // another viewDidMoveToWindow. Positive layout must retry the mount.
        if controller?.container.superview !== self { attachIfPossible() }
        guard let controller, controller.container.superview === self,
              bounds.width > 0, bounds.height > 0 else { return }
        controller.container.frame = bounds
        if !controller.hasBrowser { attachIfPossible() }
    }
}
