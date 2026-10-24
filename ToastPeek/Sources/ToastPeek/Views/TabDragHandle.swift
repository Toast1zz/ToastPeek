import SwiftUI
import AppKit

/// AppKit drag source laid over a sidebar row.
///
/// SwiftUI's `.onDrag` never reports how a drag ended, which is what a
/// tear-off (drop outside every window → new window) needs. An
/// NSDraggingSource gets that answer from
/// `draggingSession(_:endedAt:operation:)`.
///
/// The handle must never take clicks from the row underneath: it is
/// invisible to hit-testing, so clicks, hover, the close button and the
/// context menu all reach SwiftUI untouched. A single app-wide event
/// monitor watches for a press inside a registered handle followed by a
/// drag past 4 pt, and only then starts the dragging session.
/// (The first version overrode mouseDown and forwarded it up the responder
/// chain — SwiftUI never sees events delivered that way, so sidebar rows
/// could not be clicked at all.)
struct TabDragHandle: NSViewRepresentable {
    let tabID: UUID
    let title: String
    @EnvironmentObject var store: BrowserStore

    func makeNSView(context: Context) -> TabDragHandleView {
        let v = TabDragHandleView()
        v.tabID = tabID
        v.tabTitle = title
        v.store = store
        return v
    }

    func updateNSView(_ v: TabDragHandleView, context: Context) {
        v.tabID = tabID
        v.tabTitle = title
        v.store = store
    }
}

final class TabDragHandleView: NSView, NSDraggingSource {
    var tabID: UUID?
    var tabTitle: String = ""
    weak var store: BrowserStore?

    private static let handles = NSHashTable<TabDragHandleView>.weakObjects()
    private static var monitor: Any?
    private static var pressed: (view: TabDragHandleView, point: NSPoint)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            Self.handles.add(self)
            Self.installMonitor()
        } else {
            Self.handles.remove(self)
        }
    }

    private static func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDown:
                pressed = nil
                guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let window = event.window else { break }
                for handle in handles.allObjects where handle.window === window && !handle.isHiddenOrHasHiddenAncestor {
                    let p = handle.convert(event.locationInWindow, from: nil)
                    if handle.visibleRect.contains(p) {
                        pressed = (handle, event.locationInWindow)
                        break
                    }
                }
            case .leftMouseDragged:
                if let (handle, start) = pressed {
                    let p = event.locationInWindow
                    if hypot(p.x - start.x, p.y - start.y) > 4 {
                        pressed = nil
                        handle.beginTabDrag(with: event)
                    }
                }
            default:
                pressed = nil
            }
            return event
        }
    }

    private func beginTabDrag(with event: NSEvent) {
        guard let tabID else { return }
        let item = NSDraggingItem(pasteboardWriter: tabID.uuidString as NSString)
        item.setDraggingFrame(bounds, contents: dragImage())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let tabID else { return }
        store?.tabDragSessionEnded(tabID: tabID, screenPoint: screenPoint, operation: operation)
    }

    /// Snapshot of the row as rendered, falling back to a drawn capsule.
    private func dragImage() -> NSImage {
        if let host = superview {
            let rectInHost = convert(bounds, to: host)
            if let rep = host.bitmapImageRepForCachingDisplay(in: rectInHost) {
                host.cacheDisplay(in: rectInHost, to: rep)
                let img = NSImage(size: bounds.size)
                img.addRepresentation(rep)
                return img
            }
        }
        let size = NSSize(width: max(bounds.width, 120), height: max(bounds.height, 28))
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            (self.tabTitle as NSString).draw(at: NSPoint(x: 10, y: (rect.height - 15) / 2),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                                              .foregroundColor: NSColor.labelColor])
            return true
        }
    }
}
