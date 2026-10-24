import SwiftUI

/// History takes over the content card while the sidebar stays put.

private struct LibraryHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @Binding var search: String
    let onClose: () -> Void
    @ViewBuilder var trailing: Trailing
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 22, weight: .bold))
            Spacer()
            trailing
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 200)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ChromeButton(symbol: "xmark", label: "Close", action: onClose)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
        .onAppear { searchFocused = true }
    }
}

private let dayTitleFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    f.timeStyle = .none
    return f
}()

private func dayTitle(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return String(localized: "Today") }
    if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
    return dayTitleFormatter.string(from: date)
}

private struct LibraryRow<Accessory: View>: View {
    let host: String
    let title: String
    let subtitle: String
    let time: Date
    let action: () -> Void
    @ViewBuilder var accessory: Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            FaviconView(host: host, size: 16)
            Text(title).font(.system(size: 13)).lineLimit(1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1)
            Spacer(minLength: 12)
            if hovering { accessory } else {
                Text(time, style: .time).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: BrowserStore
    @State private var search = ""
    @State private var confirmClear = false

    private var groups: [(String, [HistoryEntry])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = q.isEmpty ? Array(store.history.prefix(1500)) : store.history.filter {
            $0.title.lowercased().contains(q) || $0.urlString.lowercased().contains(q)
        }
        var out: [(String, [HistoryEntry])] = []
        for e in entries {
            let key = dayTitle(e.visitedAt)
            if out.last?.0 == key { out[out.count - 1].1.append(e) } else { out.append((key, [e])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(title: "History", search: $search, onClose: { store.showHistory = false }) {
                Button("Clear History…") { confirmClear = true }
                    .disabled(store.history.isEmpty)
            }
            let g = groups
            if g.isEmpty {
                EmptyLibrary(icon: "clock", text: search.isEmpty ? "No history" : "No matches")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                        ForEach(g, id: \.0) { day, entries in
                            Section {
                                ForEach(entries) { entry in
                                    let url = URL(string: entry.urlString)
                                    LibraryRow(host: url?.host ?? "", title: entry.title.isEmpty ? entry.urlString : entry.title,
                                               subtitle: url?.host ?? "", time: entry.visitedAt) {
                                        store.open(entry.urlString)
                                    } accessory: {
                                        ChromeButton(symbol: "xmark", label: "Remove from History", size: 22) {
                                            store.deleteHistoryEntry(entry)
                                        }
                                    }
                                }
                            } header: {
                                Text(day)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.secondary)
                                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 20)
                }
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        }
    }
}

private struct EmptyLibrary: View {
    let icon: String
    let text: LocalizedStringKey
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28, weight: .light))
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(Color.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
