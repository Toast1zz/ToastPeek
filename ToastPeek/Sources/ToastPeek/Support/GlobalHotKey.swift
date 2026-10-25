import Carbon.HIToolbox
import AppKit

/// System-wide ⌥⌘N for a new Peek window. Carbon hot keys need no Accessibility access.
@MainActor
final class GlobalHotKey {
    private let resources = HotKeyResources()
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func setEnabled(_ on: Bool) {
        if on { register() } else { unregister() }
    }

    private func register() {
        guard resources.ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &spec, me, &resources.handler)
        let id = EventHotKeyID(signature: OSType(0x54504B4E), id: 1) // 'TPKN'
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &resources.ref)
    }

    private func unregister() { resources.unregister() }
}

/// C handles own their cleanup. The enclosing MainActor object serializes
/// registration changes; destruction only calls Carbon's release functions.
private final class HotKeyResources {
    var ref: EventHotKeyRef?
    var handler: EventHandlerRef?
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        ref = nil; handler = nil
    }
    deinit { unregister() }
}
