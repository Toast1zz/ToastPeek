import AppKit
import SwiftUI

/// User-chosen key equivalents for the app's own menu commands. Menu items are
/// keyed by their action selector; an override replaces the default that
/// `installMenus` registered. Stored in `shortcuts.json` next to the state file.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    struct Binding: Codable, Equatable {
        var key: String
        var mods: UInt
        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }
    }

    struct Row: Identifiable {
        let id: String
        let title: String
        let binding: Binding
        let isCustom: Bool
    }

    @Published private(set) var overrides: [String: Binding] = [:]
    private var defaults: [String: Binding] = [:]
    /// Menu items that share one action across many entries (Space 1…9) are not rebindable here.
    private static let excluded: Set<String> = ["menuSwitchSpace:", "menuSelectTabIndex:"]
    private let fileURL = AppPaths.support.appendingPathComponent("shortcuts.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Binding].self, from: data) {
            overrides = decoded
        }
    }

    /// Called for every menu item `installMenus` builds; returns what the item should use.
    func resolve(_ action: Selector, key: String, mods: NSEvent.ModifierFlags) -> (String, NSEvent.ModifierFlags) {
        let id = NSStringFromSelector(action)
        if let primary = defaults[id], primary != Binding(key: key, mods: mods.rawValue) {
            return (key, mods)
        }
        defaults[id] = Binding(key: key, mods: mods.rawValue)
        if let o = overrides[id] { return (o.key, o.flags) }
        return (key, mods)
    }

    func set(_ binding: Binding?, for id: String) {
        let value = binding ?? Binding(key: "", mods: 0)
        if value == defaults[id] { overrides.removeValue(forKey: id) } else { overrides[id] = value }
        persist()
        apply()
    }

    func reset(_ id: String) {
        overrides.removeValue(forKey: id)
        persist()
        apply()
    }

    func resetAll() {
        overrides = [:]
        persist()
        apply()
    }

    /// The customizable commands, read from the live main menu.
    func rows() -> [Row] {
        var out: [Row] = []
        var seen = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub); continue }
                guard let action = item.action, !item.isHidden, item.tag == 0 else { continue }
                let id = NSStringFromSelector(action)
                guard defaults[id] != nil, !Self.excluded.contains(id), !seen.contains(id) else { continue }
                seen.insert(id)
                let b = overrides[id] ?? defaults[id]!
                out.append(Row(id: id, title: item.title, binding: b, isCustom: overrides[id] != nil))
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        return out
    }

    /// Row that already uses this combination, if any.
    func conflict(_ binding: Binding, excluding id: String) -> Row? {
        rows().first { $0.id != id && $0.binding == binding && !binding.key.isEmpty }
    }

    func apply() {
        var seen = Set<String>()
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub); continue }
                guard let action = item.action, !item.isHidden, item.tag == 0 else { continue }
                let id = NSStringFromSelector(action)
                guard seen.insert(id).inserted else { continue }
                guard let base = defaults[id], !Self.excluded.contains(id) else { continue }
                let b = overrides[id] ?? base
                item.keyEquivalent = b.key
                item.keyEquivalentModifierMask = b.flags
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) { try? data.write(to: fileURL, options: .atomic) }
    }

    static func display(_ b: Binding) -> String {
        guard !b.key.isEmpty else { return "" }
        let f = b.flags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        let special: [String: String] = [
            "\t": "⇥", "\r": "↩", " ": "Space",
            String(UnicodeScalar(NSRightArrowFunctionKey)!): "→",
            String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←",
            String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑",
            String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓",
            String(Character(UnicodeScalar(NSBackTabCharacter)!)): "⇥",
        ]
        return s + (special[b.key] ?? b.key.uppercased())
    }
}

/// Settings page, a searchable list of commands with
/// keycap buttons on the left (click one, then press the new shortcut),
/// a key illustration and Reset All on the right.
struct ShortcutsSettingsView: View {
    @StateObject private var shortcuts = ShortcutStore.shared
    @State private var recording: String?
    @State private var rejected: String?
    @State private var search = ""

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).frame(height: 42)
                RowDivider(inset: 0)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let rows = filteredRows
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { RowDivider() }
                            rowView(row)
                        }
                    }
                }
            }
            .frame(width: 380)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    BigKey(text: "⌘")
                    BigKey(text: "T")
                }
                Text("Custom Shortcuts").font(.system(size: 17, weight: .semibold))
                if let rejected {
                    Text(rejected).font(.system(size: 12)).foregroundStyle(.red)
                }
                Spacer()
                Button("Reset All Shortcuts") { shortcuts.resetAll() }
                    .disabled(shortcuts.overrides.isEmpty)
            }
            .padding(.top, 4)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(28)
    }

    private var filteredRows: [ShortcutStore.Row] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = shortcuts.rows()
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.lowercased().contains(q) || ShortcutStore.display($0.binding).lowercased().contains(q) }
    }

    private func rowView(_ row: ShortcutStore.Row) -> some View {
        HStack(spacing: 8) {
            Text(row.title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            if row.isCustom {
                Button { shortcuts.reset(row.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Reset")
                    .accessibilityLabel("Reset")
            }
            Button {
                rejected = nil
                recording = recording == row.id ? nil : row.id
            } label: {
                KeyCap(text: recording == row.id ? String(localized: "Type shortcut…") : label(row),
                       active: recording == row.id)
            }
            .buttonStyle(.plain)
            .overlay {
                if recording == row.id {
                    KeyCaptureView { event in capture(event, for: row) }
                        .frame(width: 0, height: 0)
                }
            }
        }
        .padding(.horizontal, 16).frame(height: 46)
    }

    private func label(_ row: ShortcutStore.Row) -> String {
        let s = ShortcutStore.display(row.binding)
        return s.isEmpty ? "–––" : s
    }

    /// Returns true when the event was consumed.
    private func capture(_ event: NSEvent, for row: ShortcutStore.Row) -> Bool {
        guard recording == row.id else { return false }
        if event.keyCode == 53 { recording = nil; return true }                  // Esc cancels
        if event.keyCode == 51 || event.keyCode == 117 {                          // Delete clears
            shortcuts.set(nil, for: row.id); recording = nil; return true
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              var key = event.charactersIgnoringModifiers, !key.isEmpty else {
            rejected = String(localized: "Use ⌘, ⌃ or ⌥ with a key")
            return true
        }
        if flags.contains(.shift), key.count == 1, key.first!.isLetter { key = key.uppercased() }
        else if key.count == 1 { key = key.lowercased() }
        let binding = ShortcutStore.Binding(key: key, mods: flags.rawValue)
        if let other = shortcuts.conflict(binding, excluding: row.id) {
            rejected = String(localized: "Already used by \(other.title)")
            return true
        }
        rejected = nil
        shortcuts.set(binding, for: row.id)
        recording = nil
        return true
    }
}

/// Light keycap holding a shortcut.
private struct KeyCap: View {
    let text: String
    var active = false
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .foregroundStyle(active ? Color.white : Color.black.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(minWidth: 84, minHeight: 28)
            .background(active ? Color.accentColor : Color.white.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
    }
}

/// Big blue key for the page illustration.
private struct BigKey: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: 70, height: 70)
            .background(Color.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(4)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

/// Invisible view that swallows key equivalents while a shortcut is being recorded,
/// so the menu bar does not fire the command being rebound.
private struct KeyCaptureView: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        v.handler = handler
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: CaptureNSView, context: Context) { v.handler = handler }

    final class CaptureNSView: NSView {
        var handler: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { handler?(event) ?? false }
        override func keyDown(with event: NSEvent) { _ = handler?(event) }
    }
}
