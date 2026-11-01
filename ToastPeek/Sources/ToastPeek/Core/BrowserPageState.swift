import AppKit
import Combine

/// Ephemeral interaction state belongs to a browser window, including a Peek.
/// Keeping it outside the shared store prevents a background window from
/// receiving another window's find field or an address-focus request.
@MainActor
final class BrowserPageState: ObservableObject {
    weak var window: NSWindow?
    @Published var isFindBarVisible = false
    @Published var findText = ""
    /// -1 means WebKit found a match but does not expose a total; 0 means none.
    @Published var findMatchCount = 0
    @Published var findActiveOrdinal = 0
    @Published var findFocusRequest = 0
    @Published var addressFocusRequest = 0
    var findTabID: UUID?

    func requestAddressFocus() { addressFocusRequest &+= 1 }
    func requestFindFocus() {
        isFindBarVisible = true
        findFocusRequest &+= 1
    }
    func resetFindResult() {
        findMatchCount = 0
        findActiveOrdinal = 0
    }
}
