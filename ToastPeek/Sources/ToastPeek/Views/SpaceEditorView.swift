import SwiftUI

/// Create or edit a Space: name, icon (symbol or emoji) and theme color.
struct SpaceEditorView: View {
    let request: SpaceEditorRequest
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "circle"
    @State private var colorHex = SpaceEditorView.palette[0]
    @State private var emoji = ""

    static let palette = ["#7C6FF0", "#5B8DEF", "#3BA4C9", "#2F9E6E", "#7AB55C", "#E0B43A",
                          "#E08A2E", "#E5644E", "#E05A8A", "#B062D9", "#8C8C99", "#4A4F5C"]
    static let symbols = ["house", "briefcase", "book", "graduationcap", "hammer", "paintbrush",
                          "music.note", "gamecontroller", "cart", "airplane", "heart", "star",
                          "bolt", "leaf", "flame", "moon", "sun.max", "cloud",
                          "camera", "film", "chart.bar", "dollarsign.circle", "terminal", "globe"]

    private var isNew: Bool { request.spaceID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                preview
                TextField("Space name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit(save)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Button { icon = symbol; emoji = "" } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                            .background(icon == symbol ? Color(hex: colorHex).opacity(0.25) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                }
            }
            HStack(spacing: 8) {
                TextField("Or an emoji", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .onChange(of: emoji) {
                        if let first = emoji.first { emoji = String(first); icon = emoji }
                    }
                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(Self.palette, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(colorHex == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Space" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: colorHex))
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear(perform: loadExisting)
    }

    private var preview: some View {
        let space = BrowserSpace(name: name, icon: icon, colorHex: colorHex)
        return SpaceIcon(space: space, size: 18)
            .foregroundStyle(Color(hex: colorHex))
            .frame(width: 40, height: 40)
            .background(Color(hex: colorHex).opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func loadExisting() {
        guard let id = request.spaceID, let s = store.spaces.first(where: { $0.id == id }) else {
            name = ""
            colorHex = Self.palette[store.spaces.count % Self.palette.count]
            icon = Self.symbols[(store.spaces.count + 3) % Self.symbols.count]
            return
        }
        name = s.name
        icon = s.icon
        colorHex = s.colorHex
        if !s.iconIsSymbol { emoji = s.icon }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName = trimmed.isEmpty ? "Space \(store.spaces.count + (isNew ? 1 : 0))" : trimmed
        if let id = request.spaceID {
            store.updateSpace(id, name: finalName, icon: icon, colorHex: colorHex)
        } else {
            store.addSpace(name: finalName, icon: icon, colorHex: colorHex)
        }
        dismiss()
    }
}
