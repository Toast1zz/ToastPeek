import SwiftUI
import AppKit

/// Settings pages, hosted by a native toolbar-style NSTabViewController
/// (see main.swift's menuSettings). Pages are drawn as rounded,
/// hairline-bordered cards on the window background, colored icon tiles on
/// rows, and an illustrated banner where a page introduces a feature.
enum SettingsPage: CaseIterable, Equatable {
    case general, spaces, links, shortcuts, extensions, boosts, privacy, advanced

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .spaces: return String(localized: "Spaces")
        case .links: return String(localized: "Links")
        case .shortcuts: return String(localized: "Shortcuts")
        case .extensions: return String(localized: "Extensions")
        case .boosts: return String(localized: "Boosts")
        case .privacy: return String(localized: "Privacy")
        case .advanced: return String(localized: "Advanced")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .spaces: return "square.stack"
        case .links: return "rectangle.on.rectangle"
        case .shortcuts: return "keyboard"
        case .extensions: return "puzzlepiece.extension"
        case .boosts: return "paintbrush.pointed"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .spaces: SpacesSettingsView()
        case .links: LinksSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .extensions: ExtensionsSettingsPage()
        case .boosts: BoostsSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        }
    }
}

/// Fixed page size plus autosave of the settings the pages edit.
struct SettingsPageContainer<Content: View>: View {
    @EnvironmentObject var store: BrowserStore
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: 700, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: store.archiveAfterHours) { store.scheduleSave() }
            .onChange(of: store.searchEngine) { store.scheduleSave() }
            .onChange(of: store.searchSuggestionsEnabled) { store.scheduleSave() }
            .onChange(of: store.memorySaverEnabled) { store.scheduleSave() }
            .onChange(of: store.askDownloadLocation) { store.scheduleSave() }
            .onChange(of: store.warnBeforeQuitting) { store.scheduleSave() }
            .onChange(of: store.downloadsFolder) { store.scheduleSave() }
            .onChange(of: store.externalLinksInPeek) { store.scheduleSave() }
            .onChange(of: store.shiftClickPeek) { store.scheduleSave() }
            .onChange(of: store.peekHotkeyEnabled) { store.scheduleSave() }
            .onChange(of: store.boostsEnabled) { store.scheduleSave() }
            .onChange(of: store.boosts) { store.scheduleSave(); store.scheduleBoostApply() }
    }
}

// MARK: - Building blocks

/// Scrolling page column.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, 36).padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Small grey caption above a card.
struct SettingsCaption: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.top, 6).padding(.bottom, -8)
    }
}

/// One settings row: optional icon tile, title, trailing control.
struct SettingsRow<Trailing: View>: View {
    var symbol: String? = nil
    var tint: Color = .gray
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let symbol { IconTile(symbol: symbol, tint: tint, size: 26) }
            Text(title).font(.system(size: 13.5))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }
}

struct SettingsToggle: View {
    var symbol: String? = nil
    var tint: Color = .gray
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(title)
        }
    }
}

/// Divider between rows of a card; indented past an icon tile when there is one.
struct RowDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, inset)
    }
}

/// Colored banner with a wavy lower edge, as at the top of the Links page.
struct SettingsBanner<Art: View>: View {
    let color: Color
    @ViewBuilder var art: Art
    var body: some View {
        ZStack {
            color
            art
        }
        .frame(height: 170)
        .clipShape(WavyBottom())
    }
}

private struct WavyBottom: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let wave: CGFloat = 5, step: CGFloat = 14
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: rect.maxX, y: 0))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - wave))
        var x = rect.maxX
        var up = true
        while x > 0 {
            let next = max(0, x - step)
            p.addQuadCurve(to: CGPoint(x: next, y: rect.maxY - wave),
                           control: CGPoint(x: (x + next) / 2, y: rect.maxY - wave + (up ? wave * 2 : -wave * 2)))
            up.toggle()
            x = next
        }
        p.closeSubpath()
        return p
    }
}

/// Picker styled as a compact trailing control.
private struct TrailingPicker<V: Hashable, Content: View>: View {
    @Binding var selection: V
    @ViewBuilder var content: Content
    var body: some View {
        Picker("", selection: $selection) { content }
            .labelsHidden().pickerStyle(.menu).fixedSize()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var isDefault = DefaultBrowser.isDefault

    private static let archiveOptions: [(LocalizedStringKey, Double)] = [
        ("12 hours", 12), ("24 hours", 24), ("7 days", 168), ("30 days", 720),
    ]

    var body: some View {
        SettingsScroll {
            ControlCard {
                SettingsRow(symbol: "safari", tint: .blue, title: "Default browser") {
                    if isDefault {
                        Label("ToastPeek", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            DefaultBrowser.request()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isDefault = DefaultBrowser.isDefault }
                        }
                    }
                }
                RowDivider(inset: 54)
                SettingsToggle(symbol: "power", tint: .gray, title: "Warn before quitting", isOn: $store.warnBeforeQuitting)
            }

            SettingsCaption(text: "Search")
            ControlCard {
                SettingsRow(symbol: "magnifyingglass", tint: .indigo, title: "Search engine") {
                    TrailingPicker(selection: $store.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                }
                RowDivider(inset: 54)
                SettingsToggle(symbol: "text.magnifyingglass", tint: .indigo, title: "Include search engine suggestions",
                               isOn: $store.searchSuggestionsEnabled)
                    .disabled(store.searchEngine.suggestTemplate == nil)
            }

            SettingsCaption(text: "Tabs")
            ControlCard {
                SettingsRow(symbol: "archivebox.fill", tint: .orange, title: "Archive Today tabs after") {
                    TrailingPicker(selection: $store.archiveAfterHours) {
                        ForEach(Self.archiveOptions, id: \.1) { Text($0.0).tag($0.1) }
                        if !Self.archiveOptions.contains(where: { $0.1 == store.archiveAfterHours }) {
                            Text("\(Int(store.archiveAfterHours)) hours").tag(store.archiveAfterHours)
                        }
                    }
                }
                RowDivider(inset: 54)
                SettingsToggle(symbol: "leaf.fill", tint: .green, title: "Unload tabs you haven’t looked at for an hour",
                               isOn: $store.memorySaverEnabled)
            }

            SettingsCaption(text: "Downloads")
            ControlCard {
                SettingsRow(symbol: "arrow.down.circle.fill", tint: .teal, title: "Download location") {
                    Menu {
                        Button("Downloads") { store.downloadsFolder = nil }
                        Divider()
                        Button("Other…") { chooseDownloadsFolder() }
                    } label: {
                        Label((store.resolvedDownloadsFolder as NSString).lastPathComponent, systemImage: "folder.fill")
                    }
                    .fixedSize()
                }
                RowDivider(inset: 54)
                SettingsToggle(symbol: "questionmark.folder.fill", tint: .teal, title: "Ask where to save each file",
                               isOn: $store.askDownloadLocation)
            }

            SettingsCaption(text: "Import")
            ControlCard {
                SettingsRow(symbol: "square.and.arrow.down.fill", tint: .pink, title: "Import from another browser") {
                    Button("Import…") { store.beginOnboarding(at: 1) }
                }
            }
        }
        .onAppear { isDefault = DefaultBrowser.isDefault }
    }

    private func chooseDownloadsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.resolvedDownloadsFolder)
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { store.downloadsFolder = url.path }
    }
}

// MARK: - Spaces (list on the left, details on the right)

struct SpacesSettingsView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var selection: UUID?
    @State private var confirmDelete: BrowserSpace?
    @State private var confirmClear: BrowserSpace?

    private var selected: BrowserSpace? {
        store.spaces.first { $0.id == (selection ?? store.currentSpaceID) } ?? store.spaces.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Text("Your Spaces")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).frame(height: 36)
                RowDivider(inset: 0)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.spaces) { space in spaceRow(space) }
                    }
                    .padding(6)
                }
                RowDivider(inset: 0)
                HStack(spacing: 0) {
                    ChromeButton(symbol: "plus", label: "New Space…", size: 30) {
                        store.spaceEditor = SpaceEditorRequest(spaceID: nil); focusBrowser()
                    }
                    ChromeButton(symbol: "minus", label: "Delete Space…", enabled: store.spaces.count > 1, size: 30) {
                        confirmDelete = selected
                    }
                    ChromeButton(symbol: "pencil", label: "Edit Space…", size: 30) {
                        if let s = selected { store.spaceEditor = SpaceEditorRequest(spaceID: s.id); focusBrowser() }
                    }
                    Spacer()
                }
                .padding(.horizontal, 6).frame(height: 38)
            }
            .frame(width: 220)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))

            if let space = selected { detail(space) }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Space", role: .destructive) {
                if let s = confirmDelete { store.deleteSpace(s.id); selection = nil }
                confirmDelete = nil
            }
        } message: {
            Text("Its pinned tabs, folders, open tabs and site logins will be removed.")
        }
        .confirmationDialog("Clear site data for “\(confirmClear?.name ?? "")”?",
                            isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } }),
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                if let s = confirmClear { BrowserEngineBridge.clearBrowsingData(dataStoreID: s.dataStoreID) }
                confirmClear = nil
            }
        } message: {
            Text("You’ll be signed out of websites in this Space.")
        }
    }

    private func spaceRow(_ space: BrowserSpace) -> some View {
        let isSelected = space.id == selected?.id
        let count = store.pinned(in: space.id).count + store.today(in: space.id).count
        return HStack(spacing: 10) {
            SpaceIcon(space: space, size: 13).frame(width: 18)
            Text(space.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count) tabs").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(isSelected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selection = space.id }
        .accessibilityAddTraits(.isButton)
    }

    private func detail(_ space: BrowserSpace) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                SpaceIcon(space: space, size: 22)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(space.color.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(space.name).font(.system(size: 20, weight: .semibold))
                    Text("\(store.pinned(in: space.id).count) pinned · \(store.today(in: space.id).count) today")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit…") { store.spaceEditor = SpaceEditorRequest(spaceID: space.id); focusBrowser() }
            }
            ControlCard {
                SettingsRow(symbol: "arrow.right.circle.fill", tint: .blue, title: "Switch to This Space") {
                    Button("Switch") { store.switchSpace(to: space.id); focusBrowser() }
                        .disabled(space.id == store.currentSpaceID)
                }
                RowDivider(inset: 54)
                SettingsRow(symbol: "trash.fill", tint: .red, title: "Cookies and site data") {
                    Button("Clear…") { confirmClear = space }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// The Space editor is a sheet on the browser window.
    private func focusBrowser() {
        store.activeWindowState?.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Links (Peek)

struct LinksSettingsView: View {
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsBanner(color: Color(red: 0.88, green: 0.50, blue: 0.53)) { PeekMock() }
                VStack(alignment: .leading, spacing: 16) {
                    ControlCard {
                        SettingsToggle(title: "Links from other apps open in Peek", isOn: $store.externalLinksInPeek)
                        RowDivider()
                        SettingsToggle(title: "Open Peek when I press ⌥⌘N in any app", isOn: $store.peekHotkeyEnabled)
                        RowDivider()
                        SettingsToggle(title: "Open a Peek window when clicking on links with Shift held", isOn: $store.shiftClickPeek)
                    }
                }
                .padding(.horizontal, 36).padding(.bottom, 26)
            }
        }
    }
}

/// Miniature Peek window for the Links banner.
private struct PeekMock: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3) { _ in Circle().fill(Color.black.opacity(0.18)).frame(width: 9, height: 9) }
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.75))
                    .frame(height: 18)
                    .overlay(Text("toastpeek.app").font(.system(size: 10, weight: .medium)).foregroundStyle(.black.opacity(0.6)))
                Text("Open in Work").font(.system(size: 10, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                    .padding(.horizontal, 8).frame(height: 18)
                    .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 10).frame(height: 32)
            Rectangle().fill(Color.white.opacity(0.35))
        }
        .frame(width: 460, height: 120)
        .background(Color(red: 0.94, green: 0.82, blue: 0.84), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .offset(y: 26)
    }
}

// MARK: - Extensions

struct ExtensionsSettingsPage: View {
    @EnvironmentObject var store: BrowserStore
    @State private var darkHostsText = ""

    var body: some View {
        SettingsScroll {
            ControlCard {
                builtinRow(path: BrowserStore.contentBlockerBuiltinPath, symbol: "hand.raised.fill", tint: .blue, title: "Content Blocker")
                RowDivider(inset: 54)
                builtinRow(path: BrowserStore.darkModeBuiltinPath, symbol: "moon.fill", tint: .indigo, title: "Dark Mode")
                RowDivider(inset: 54)
                SettingsRow(symbol: "list.bullet", tint: .indigo, title: "Dark Mode sites") {
                    TextField("All sites", text: $darkHostsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { store.setDarkModeHosts(darkHostsText.split(separator: ",").map(String.init)) }
                }
            }
            .onAppear { darkHostsText = store.darkModeHosts.joined(separator: ", ") }
        }
    }

    private func builtinRow(path: String, symbol: String, tint: Color, title: LocalizedStringKey) -> some View {
        SettingsToggle(symbol: symbol, tint: tint, title: title, isOn: Binding(
            get: { store.extensions.first { $0.path == path }?.isEnabled ?? false },
            set: { on in if let ext = store.extensions.first(where: { $0.path == path }) { store.setExtensionEnabled(ext, on) } }))
    }
}

// MARK: - Boosts

struct BoostsSettingsView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var expanded: UUID?

    var body: some View {
        SettingsScroll {
            HStack {
                SettingsCaption(text: "Your Boosts")
                Spacer()
                Button("New Boost") {
                    let host = store.selectedTab?.displayHost ?? ""
                    let boost = Boost(name: host.isEmpty ? String(localized: "New Boost") : host, hostPattern: host)
                    store.boosts.append(boost)
                    expanded = boost.id
                }
                .padding(.bottom, -8)
            }
            if store.boosts.isEmpty {
                ControlCard {
                    Text("No Boosts").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 64)
                }
            }
            ForEach($store.boosts) { $boost in
                ControlCard {
                    HStack(spacing: 12) {
                        FaviconView(host: boost.normalizedPattern, size: 20)
                            .frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("", text: $boost.name, prompt: Text("Name"))
                                .textFieldStyle(.plain).font(.system(size: 13.5, weight: .semibold))
                            TextField("", text: $boost.hostPattern, prompt: Text("example.com"))
                                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ChromeButton(symbol: expanded == boost.id ? "chevron.up" : "chevron.down",
                                     label: expanded == boost.id ? "Collapse" : "Edit Code", size: 26) {
                            withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == boost.id ? nil : boost.id }
                        }
                        Toggle("", isOn: $boost.isEnabled).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel(boost.name)
                        Button(role: .destructive) {
                            let pattern = boost.hostPattern
                            store.boosts.removeAll { $0.id == boost.id }
                            store.applyBoostsToOpenTabs(extraReloadPatterns: [pattern])
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete Boost")
                    }
                    .padding(.horizontal, 16).frame(minHeight: 56)
                    if expanded == boost.id {
                        RowDivider(inset: 0)
                        VStack(alignment: .leading, spacing: 12) {
                            CodeField(label: "CSS", text: $boost.css)
                            CodeField(label: "JavaScript", text: $boost.js)
                        }
                        .padding(16)
                    }
                }
            }
        }
    }
}

/// Monospaced multi-line editor with its label above it.
private struct CodeField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 90)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .autocorrectionDisabled()
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var confirmClear = false

    var body: some View {
        SettingsScroll {
            SettingsCaption(text: "Site Permissions")
            ControlCard {
                if store.sitePermissions.isEmpty {
                    Text("No saved permissions").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 56)
                }
                ForEach(Array(store.sitePermissions.enumerated()), id: \.element.id) { index, perm in
                    if index > 0 { RowDivider(inset: 54) }
                    HStack(spacing: 12) {
                        FaviconView(host: URL(string: perm.origin)?.host ?? "", size: 18).frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(string: perm.origin)?.host ?? perm.origin).font(.system(size: 13.5)).lineLimit(1)
                            Text(Self.summary(perm)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Remove") { store.clearSitePermission(perm) }
                    }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                }
            }

            SettingsCaption(text: "Your Data")
            ControlCard {
                SettingsRow(symbol: "trash.fill", tint: .red, title: "Clear Browsing Data") {
                    Button("Clear…") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear browsing data?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { store.clearBrowsingData() }
        } message: {
            Text("History, the Archive, cookies and site data of every Space are deleted. You’ll be signed out of websites.")
        }
    }

    /// "Allowed: camera, location · Blocked: notifications"
    static func summary(_ perm: SitePermission) -> String {
        func names(_ media: UInt32, _ prompt: UInt32) -> [String] {
            var out = SitePermission.featureNames(kind: .media, mask: media)
            for n in SitePermission.featureNames(kind: .prompt, mask: prompt) where !out.contains(n) { out.append(n) }
            return out
        }
        let allowed = names(perm.mediaAllowed, perm.promptAllowed)
        let blocked = names(perm.mediaDenied, perm.promptDenied)
        var parts: [String] = []
        if !allowed.isEmpty {
            parts.append(String(localized: "Allowed: \(ListFormatter.localizedString(byJoining: allowed))"))
        }
        if !blocked.isEmpty {
            parts.append(String(localized: "Blocked: \(ListFormatter.localizedString(byJoining: blocked))"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject var store: BrowserStore

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        SettingsScroll {
            ControlCard {
                SettingsToggle(symbol: "paintbrush.pointed.fill", tint: .pink, title: "Enable Boosts on websites you visit",
                               isOn: $store.boostsEnabled)
            }

            ControlCard {
                SettingsRow(symbol: "folder.fill", tint: .blue, title: "Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.dataFileURL]) }
                }
                RowDivider(inset: 54)
                SettingsRow(symbol: "doc.text.fill", tint: .gray, title: "Logs") {
                    Button("Show") { NSWorkspace.shared.open(AppPaths.logs) }
                }
            }

            ControlCard {
                SettingsRow(symbol: "info.circle.fill", tint: .gray, title: "ToastPeek") {
                    Text(version).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                }
                RowDivider(inset: 54)
                SettingsRow(symbol: "safari.fill", tint: .gray, title: "Engine") {
                    Text("WebKit").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
