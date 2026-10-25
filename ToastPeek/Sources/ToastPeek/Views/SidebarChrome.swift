import SwiftUI
import AppKit

/// Sidebar resize region, as an AppKit view .
/// A SwiftUI overlay can't own this strip: the page's WKWebView is an
/// NSView, so over it the overlay never sees the pointer and the cursor
/// flickers between the page's and ours. A real view with a cursor rect
/// and its own mouse handling gets both right.
struct SidebarResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        update(v)
        return v
    }

    func updateNSView(_ v: HandleView, context: Context) { update(v) }

    private func update(_ v: HandleView) {
        v.onBegin = onBegin
        v.onDrag = onDrag
        v.onEnd = onEnd
    }

    final class HandleView: NSView {
        var onBegin: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var startX: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        // `point` is in the superview's coordinates.
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            NSCursor.resizeLeftRight.push()
            onBegin?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag?(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            NSCursor.pop()
            onEnd?()
            window?.invalidateCursorRects(for: self)
        }
    }
}

/// Shows the hidden sidebar when the pointer reaches the window's left
/// edge or the traffic-light corner, and hides it again once the pointer
/// has clearly left it . Window-level
/// mouse tracking, so it works over web content and in full screen.
struct SidebarRevealTracker: NSViewRepresentable {
    let isEnabled: Bool
    let isRevealed: Bool
    let sidebarWidth: CGFloat
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        update(v)
        return v
    }

    func updateNSView(_ v: TrackerView, context: Context) { update(v) }

    private func update(_ v: TrackerView) {
        v.isEnabled = isEnabled
        v.isRevealed = isRevealed
        v.sidebarWidth = sidebarWidth
        v.onChange = onChange
        if !isEnabled { v.cancelHide() }
    }

    final class TrackerView: NSView {
        var isEnabled = false
        var isRevealed = false
        var sidebarWidth: CGFloat = 260
        var onChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var hideWork: DispatchWorkItem?

        /// Pointer this close to the left edge reveals the sidebar.
        private let edge: CGFloat = 6
        /// Extra room past the sidebar before it slides away.
        private let slack: CGFloat = 28

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] event in
                if let self, event.window === self.window { self.evaluate(event.locationInWindow) }
                return event
            }
            #if DEBUG
            probeObserver = NotificationCenter.default.addObserver(forName: Self.probePoint, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? NSWindow
                let point = note.userInfo?["point"] as? NSPoint
                MainActor.assumeIsolated {
                    guard let self, let w = self.window, source === w, let point else { return }
                    self.evaluate(point)
                }
            }
            #endif
        }

        #if DEBUG
        /// DEBUG probe: feeds a window point (bottom-left origin) to the tracker,
        /// since synthesized events bypass local monitors.
        static let probePoint = Notification.Name("ToastPeekSidebarRevealProbe")
        private var probeObserver: Any?
        #endif

        deinit {
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
                #if DEBUG
                if let probeObserver { NotificationCenter.default.removeObserver(probeObserver) }
                #endif
            }
        }

        func cancelHide() {
            hideWork?.cancel()
            hideWork = nil
        }

        func evaluate(_ p: NSPoint) {
            guard isEnabled, let window else { return }
            let fromTop = window.frame.height - p.y
            if !isRevealed {
                let atEdge = p.x <= edge && p.x >= -1
                let inLights = p.x < 80 && fromTop < SidebarMetrics.topBarHeight && fromTop >= 0
                if atEdge || inLights { cancelHide(); onChange?(true) }
                return
            }
            if p.x > sidebarWidth + slack {
                guard hideWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isRevealed else { return }
                    self.hideWork = nil
                    // A menu or popover opened from the sidebar keeps it up.
                    if NSApp.windows.contains(where: { $0.isVisible && $0.className.contains("Popover") }) { return }
                    self.onChange?(false)
                }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else {
                cancelHide()
            }
        }
    }
}

/// Puts the window's traffic lights on the sidebar's top row, centered on
/// the same line as the navigation buttons (AppKit's
/// default sits a few points higher). Re-applied after AppKit relayouts.
@MainActor
enum TrafficLights {
    static func place(in window: NSWindow) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton),
              let container = close.superview else { return }
        let containerHeight = container.frame.height
        let centerFromTop = SidebarMetrics.trafficLightCenterY
        var x: CGFloat = 16
        for kind in kinds {
            guard let b = window.standardWindowButton(kind) else { continue }
            let size = b.frame.size
            let y = container.isFlipped ? centerFromTop - size.height / 2
                : containerHeight - centerFromTop - size.height / 2
            b.setFrameOrigin(NSPoint(x: x, y: max(0, y)))
            x += size.width + 6
        }
    }
}
