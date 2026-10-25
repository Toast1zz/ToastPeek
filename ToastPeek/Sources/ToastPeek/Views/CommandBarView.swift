import SwiftUI
import AppKit

/// Subsequence fuzzy matcher: every query character must appear in order.
/// Contiguous runs, word starts and early matches score higher, so "gthb"
/// ranks GitHub above a page that merely contains those letters.
enum FuzzyMatch {
    static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        var score = 0, qi = 0, run = 0
        var prevWasSeparator = true
        for (i, ch) in c.enumerated() {
            if qi < q.count, ch == q[qi] {
                score += 10 + run * 4 + (prevWasSeparator ? 6 : 0) + max(0, 8 - i / 4)
                run += 1
                qi += 1
            } else {
                run = 0
            }
            prevWasSeparator = " -_/.:".contains(ch)
        }
        return qi == q.count ? score : nil
    }
}

/// Fetches search-engine suggestions for the Command Bar, debounced.
@MainActor
final class SearchSuggestions: ObservableObject {
    @Published private(set) var items: [String] = []
    private var task: Task<Void, Never>?

    func update(query: String, engine: SearchEngine, enabled: Bool) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard enabled, !q.isEmpty, !URLResolver.looksLikeURL(q), let template = engine.suggestTemplate,
              let url = URL(string: template.replacingOccurrences(of: "%@", with: URLResolver.encodeQueryValue(q))) else {
            items = []
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.httpShouldHandleCookies = false
            let result = try? await URLSession.shared.data(for: request)
            guard let (data, _) = result, !Task.isCancelled else { return }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
            guard let json, json.count > 1, let list = json[1] as? [String] else { return }
            self?.items = Array(list.filter { $0.lowercased() != q.lowercased() }.prefix(4))
        }
    }
}

/// The Command Bar. Cmd+T opens it for a new tab; Cmd+L (or clicking the
/// address) opens it on the current page's address. Open tabs, history,
/// search suggestions and app commands share one ranked list.
struct CommandBarView: View {
    @EnvironmentObject var store: BrowserStore
    @StateObject private var suggestions = SearchSuggestions()
    @State private var query = ""
    @State private var selectedIndex = 0
    /// Ranked results, rebuilt when the query or suggestions change, not
    /// on every redraw (hover and selection redraw the bar constantly).
    @State private var currentHits: [Hit] = []
    /// The query `currentHits` was built for. Return can arrive before the
    /// rebuild when keys come in faster than SwiftUI updates.
    @State private var hitsQuery = ""
    /// Pointer position when results last changed: rows that slide under a
    /// resting pointer must not steal the keyboard selection.
    @State private var hoverAnchor = NSEvent.mouseLocation
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private enum Icon { case favicon(String), symbol(String) }

    private struct Hit: Identifiable {
        let id: String
        var icon: Icon
        var title: String
        var subtitle: String
        var hint: String
        var action: () -> Void
    }

    private var mode: CommandBarMode { store.commandBarMode ?? .newTab }

    private func computeHits() -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || (mode == .editCurrent && q == store.commandTargetTab?.urlString) {
            return recentTabs()
        }
        var out: [Hit] = []
        out.append(primaryHit(for: q))

        var tabHits: [(Int, Hit)] = []
        for t in store.tabs where !t.isArchived && t.viewSourceFor == nil && t.id != store.focusedPaneTabID {
            let s = max(FuzzyMatch.score(query: q, candidate: t.displayTitle) ?? -1,
                        FuzzyMatch.score(query: q, candidate: t.displayHost) ?? -1)
            guard s >= 0 else { continue }
            let spaceName = t.kind == .favorite ? String(localized: "Favorite") : store.space(for: t).name
            tabHits.append((s + (t.kind == .today ? 0 : 6), Hit(
                id: "tab-\(t.id)", icon: .favicon(t.host), title: t.displayTitle,
                subtitle: t.displayHost, hint: String(localized: "Switch to Tab · \(spaceName)")) { store.select(t); dismiss() }))
        }
        out += tabHits.sorted { $0.0 > $1.0 }.prefix(4).map(\.1)

        for (i, s) in suggestions.items.enumerated() {
            out.append(Hit(id: "sug-\(i)-\(s)", icon: .symbol("magnifyingglass"), title: s,
                           subtitle: "", hint: "") { run(s) })
        }

        var historyHits: [(Int, Hit)] = []
        var seen = Set(out.map(\.subtitle))
        for h in store.history.prefix(2000) {
            let host = URL(string: h.urlString)?.host ?? ""
            let s = max(FuzzyMatch.score(query: q, candidate: h.title) ?? -1,
                        FuzzyMatch.score(query: q, candidate: h.urlString) ?? -1)
            guard s >= 0, !seen.contains(h.urlString) else { continue }
            seen.insert(h.urlString)
            historyHits.append((s, Hit(id: "hist-\(h.id)", icon: .favicon(host),
                                       title: h.title.isEmpty ? h.urlString : h.title,
                                       subtitle: h.urlString, hint: "") { run(h.urlString) }))
        }
        out += historyHits.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)

        let commandHits = commands.compactMap { c -> (Int, Hit)? in
            guard let s = FuzzyMatch.score(query: q, candidate: c.title), s > q.count * 14 else { return nil }
            return (s, Hit(id: "cmd-\(c.title)", icon: .symbol(c.symbol), title: c.title,
                           subtitle: "", hint: c.shortcut) { c.action(); dismiss() })
        }
        out += commandHits.sorted { $0.0 > $1.0 }.prefix(3).map(\.1)
        return Array(out.prefix(14))
    }

    private func primaryHit(for q: String) -> Hit {
        if URLResolver.looksLikeURL(q), let url = URLResolver.resolve(q, engine: store.searchEngine) {
            return Hit(id: "primary", icon: .favicon(url.host ?? ""), title: url.absoluteString
                .replacingOccurrences(of: "https://", with: ""),
                       subtitle: "", hint: mode == .editCurrent ? String(localized: "Open") : String(localized: "Open in New Tab")) { run(q) }
        }
        return Hit(id: "primary", icon: .symbol("magnifyingglass"), title: q,
                   subtitle: "", hint: String(localized: "Search \(store.searchEngine.name)")) { run(q) }
    }

    private func recentTabs() -> [Hit] {
        store.tabs.filter { !$0.isArchived && $0.viewSourceFor == nil && $0.id != store.focusedPaneTabID }
            .sorted { $0.lastVisitedAt > $1.lastVisitedAt }
            .prefix(7)
            .map { t in
                Hit(id: "recent-\(t.id)", icon: .favicon(t.host), title: t.displayTitle,
                    subtitle: t.displayHost,
                    hint: t.kind == .favorite ? String(localized: "Favorite") : store.space(for: t).name) { store.select(t); dismiss() }
            }
    }

    private struct Command {
        var title: String; var symbol: String; var shortcut: String = ""; var action: () -> Void
    }
    private var commands: [Command] {
        var list: [Command] = [
            Command(title: String(localized: "New Space"), symbol: "square.stack", action: { store.spaceEditor = SpaceEditorRequest(spaceID: nil) }),
            Command(title: String(localized: "Toggle Sidebar"), symbol: "sidebar.left", shortcut: "⌘S") { store.isSidebarVisible.toggle() },
            Command(title: String(localized: "Split View"), symbol: "rectangle.split.2x1", shortcut: "⌃⇧=") { store.toggleSplit() },
            Command(title: String(localized: "Copy URL"), symbol: "link", shortcut: "⇧⌘C") { store.copyCurrentURL() },
            Command(title: String(localized: "History"), symbol: "clock", shortcut: "⌘Y") { store.openHistoryPage() },
            Command(title: String(localized: "Library"), symbol: "archivebox") { store.openLibrary() },
            Command(title: String(localized: "Archived Tabs"), symbol: "archivebox") { store.openLibrary(.archived) },
            Command(title: String(localized: "Downloads"), symbol: "arrow.down.circle", shortcut: "⇧⌘J") { store.openLibrary(.downloads) },
            Command(title: String(localized: "Clear Today Tabs"), symbol: "arrow.down.to.line") { store.clearToday() },
            Command(title: String(localized: "Developer Tools"), symbol: "hammer", shortcut: "⌥⌘I") { store.showDevTools() },
            Command(title: String(localized: "Extensions"), symbol: "puzzlepiece.extension") { store.onOpenSettings?(.extensions) },
            Command(title: String(localized: "Reload Page"), symbol: "arrow.clockwise", shortcut: "⌘R") { store.reload() },
        ]
        for space in store.spaces where space.id != store.currentSpaceID {
            list.append(Command(title: String(localized: "Go to \(space.name)"), symbol: "square.on.square") { store.switchSpace(to: space.id) })
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: mode == .editCurrent ? "arrow.turn.down.right" : "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                TextField(mode == .editCurrent ? String(localized: "Search or enter address") : String(localized: "Search or open a new tab"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, max(0, currentHits.count - 1)); return .handled
                    }
                    .onKeyPress(.upArrow) { selectedIndex = max(selectedIndex - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onKeyPress(.tab) {
                        if currentHits.indices.contains(selectedIndex) {
                            let hit = currentHits[selectedIndex]
                            query = hit.subtitle.isEmpty ? hit.title : hit.subtitle
                        }
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            if !currentHits.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(currentHits.enumerated()), id: \.element.id) { index, hit in
                                row(hit, selected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture { hit.action() }
                                    .accessibilityAddTraits(.isButton)
                                    .onHover { inside in
                                        guard inside, NSEvent.mouseLocation != hoverAnchor else { return }
                                        selectedIndex = index
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selectedIndex) { proxy.scrollTo(selectedIndex) }
                }
            }
        }
        .frame(width: 660)
        .background(Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.82 : 0.86),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.06), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 16)
        .onAppear {
            if mode == .editCurrent, let t = store.commandTargetTab, t.viewSourceFor == nil, t.url.scheme != "about" {
                query = t.urlString
            }
            refreshHits()
            focused = true
        }
        .onChange(of: query) {
            selectedIndex = 0
            hoverAnchor = NSEvent.mouseLocation
            refreshHits()
            suggestions.update(query: query, engine: store.searchEngine, enabled: store.searchSuggestionsEnabled)
        }
        .onChange(of: suggestions.items) { refreshHits() }
    }

    private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                switch hit.icon {
                case .favicon(let host): FaviconView(host: host, size: 16)
                case .symbol(let name):
                    Image(systemName: name).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(hit.title)
                .font(.system(size: 13.5))
                .lineLimit(1)
            if !hit.subtitle.isEmpty && hit.subtitle != hit.title {
                Text("— \(hit.subtitle)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !hit.hint.isEmpty {
                Text(hit.hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(selected ? store.currentSpace.color.opacity(0.92) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func run(_ text: String) {
        let m = NSEvent.modifierFlags.contains(.command) ? CommandBarMode.newTab : mode
        store.open(text, mode: m)
        dismiss()
    }

    private func refreshHits() {
        currentHits = computeHits()
        hitsQuery = query
    }

    private func runSelected() {
        let fresh = hitsQuery == query
        let hits = fresh ? currentHits : computeHits()
        let index = fresh ? selectedIndex : 0
        if hits.indices.contains(index) {
            hits[index].action()
        } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            run(query)
        }
    }

    private func dismiss() {
        store.commandBarMode = nil
        query = ""
        selectedIndex = 0
    }
}
