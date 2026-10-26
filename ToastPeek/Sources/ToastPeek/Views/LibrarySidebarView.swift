import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Library: the button at the sidebar's bottom-left turns the sidebar
/// into a category rail plus a list (Media, Downloads, Spaces,
/// Boosts, Archived Tabs); the back arrow turns it back.
enum LibraryCategory: String, CaseIterable, Identifiable {
    case media, downloads, spaces, boosts, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: return String(localized: "Media")
        case .downloads: return String(localized: "Downloads")
        case .spaces: return String(localized: "Spaces")
        case .boosts: return String(localized: "Boosts")
        case .archived: return String(localized: "Archived Tabs")
        }
    }

    var symbol: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .downloads: return "arrow.down.circle"
        case .spaces: return "square.stack"
        case .boosts: return "paintbrush.pointed"
        case .archived: return "archivebox"
        }
    }
}

extension BrowserStore {
    /// Opens the Library in the active window's sidebar.
    /// Opens the Library in the active window's sidebar, at `category` or
    /// wherever it was last left.
    func openLibrary(_ category: LibraryCategory? = nil) {
        guard let ws = activeWindowState else { return }
        if !isSidebarVisible { isSidebarVisible = true }
        ws.library = category ?? ws.lastLibrary
    }
    func closeLibrary() { activeWindowState?.library = nil }
    func toggleLibrary() {
        if activeWindowState?.library != nil { closeLibrary() } else { openLibrary() }
    }

    /// Sidebar width a window uses: the Library needs room for its rail.
    func effectiveSidebarWidth(_ ws: WindowTabState) -> CGFloat {
        ws.library == nil ? CGFloat(sidebarWidth) : max(CGFloat(sidebarWidth), 400)
    }
}

struct LibrarySidebarView: View {
    let category: LibraryCategory
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState
    @Environment(\.colorScheme) private var scheme
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 104)
            VStack(spacing: 10) {
                header
                LibraryContent(category: category, search: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 8)
        }
        .onChange(of: category) { search = "" }
    }

    private var rail: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 34)
            ForEach(LibraryCategory.allCases) { c in
                RailButton(category: c, selected: c == category) {
                    withAnimation(.easeOut(duration: 0.15)) { windowState.library = c }
                }
            }
            Spacer(minLength: 0)
            HStack {
                ChromeButton(symbol: "arrow.left", label: "Back to Sidebar", size: 30) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { windowState.library = nil }
                }
                Spacer()
            }
            .padding(.leading, 10)
            .frame(height: 40)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(SidebarStyle(scheme: scheme).fieldFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            headerAction
        }
        .padding(.trailing, 10)
    }

    @ViewBuilder private var headerAction: some View {
        switch category {
        case .spaces:
            ChromeButton(symbol: "plus", label: "New Space…", size: 32) { store.spaceEditor = SpaceEditorRequest(spaceID: nil) }
        case .boosts:
            ChromeButton(symbol: "plus", label: "New Boost", size: 32) { store.onOpenSettings?(.boosts) }
        case .downloads:
            ChromeButton(symbol: "folder", label: "Open Downloads Folder", size: 32) {
                NSWorkspace.shared.open(URL(fileURLWithPath: store.resolvedDownloadsFolder))
            }
        default:
            EmptyView()
        }
    }
}

private struct RailButton: View {
    let category: LibraryCategory
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: category.symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 24)
                Text(category.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(hovering ? 0.8 : 0.6))
            .frame(width: 88, height: 62)
            .background(selected ? SidebarStyle(scheme: scheme).selectedFill
                        : (hovering ? SidebarStyle(scheme: scheme).hoverFill : .clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(category.title)
    }
}

// MARK: - Category content

private struct LibraryContent: View {
    let category: LibraryCategory
    let search: String
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        switch category {
        case .media: MediaGrid(search: search)
        case .downloads: DownloadsList(search: search)
        case .spaces: SpacesList(search: search)
        case .boosts: BoostsList(search: search)
        case .archived: ArchivedList(search: search)
        }
    }
}

private func matches(_ q: String, _ fields: String...) -> Bool {
    let q = q.trimmingCharacters(in: .whitespaces).lowercased()
    return q.isEmpty || fields.contains { $0.lowercased().contains(q) }
}

/// Today / Yesterday / "3 days ago", grouped by day.
private func dayGroupTitle(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return String(localized: "Today") }
    if cal.isDateInYesterday(date) { return String(localized: "Yesterday") }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .named
    let start = cal.startOfDay(for: date)
    return f.localizedString(for: start, relativeTo: cal.startOfDay(for: Date()))
}

private func grouped<T>(_ items: [T], date: (T) -> Date) -> [(String, [T])] {
    var out: [(String, [T])] = []
    for item in items {
        let key = dayGroupTitle(date(item))
        if out.last?.0 == key { out[out.count - 1].1.append(item) } else { out.append((key, [item])) }
    }
    return out
}

private struct LibraryEmpty: View {
    let symbol: String
    let text: LocalizedStringKey
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light))
            Text(text).font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 4)
    }
}

/// One Library row: icon, title, secondary line; hover wash.
private struct LibraryRow<Icon: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    var dimmed = false
    let action: () -> Void
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .opacity(dimmed ? 0.5 : 1)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovering ? SidebarStyle(scheme: scheme).hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct FileIcon: View {
    let path: String
    let fileName: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .task(id: [path, fileName]) {
            icon = nil
            let loaded = await LibraryFileIcons.load(path: path, fileName: fileName)
            guard !Task.isCancelled else { return }
            icon = loaded
        }
    }
}

/// Icon Services may synchronously inspect a file or contact another process
/// (notably for disk images). Keep that work out of SwiftUI's render pass.
private enum LibraryFileIcons {
    private static let queue = DispatchQueue(label: "app.toastpeek.library-icons", qos: .utility)
    // Every cache access runs on queue; no mutable cache state escapes it.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func load(path: String, fileName: String) async -> NSImage {
        await withCheckedContinuation { continuation in
            queue.async {
                let ext = (fileName as NSString).pathExtension.lowercased()
                let key = (path.isEmpty ? "type:\(ext)" : "file:\(path)") as NSString
                if let cached = cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                let exists = !path.isEmpty && FileManager.default.fileExists(atPath: path)
                let icon = exists ? NSWorkspace.shared.icon(forFile: path)
                    : NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
                cache.setObject(icon, forKey: key)
                continuation.resume(returning: icon)
            }
        }
    }
}

// MARK: Downloads

private struct DownloadsList: View {
    let search: String
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        let active = store.downloads.filter { $0.state != "completed" && matches(search, $0.fileName) }
        let records = store.downloadRecords.filter { matches(search, $0.fileName, $0.sourceHost) }
        if active.isEmpty && records.isEmpty {
            LibraryEmpty(symbol: "arrow.down.circle", text: search.isEmpty ? "No downloads" : "No matches")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !active.isEmpty {
                        SectionTitle(text: String(localized: "Downloading"))
                        ForEach(active) { item in ActiveDownloadRow(item: item) }
                    }
                    ForEach(grouped(records, date: \.date), id: \.0) { day, items in
                        SectionTitle(text: day)
                        ForEach(items) { r in DownloadRecordRow(record: r) }
                    }
                }
                .padding(.trailing, 10).padding(.bottom, 16)
            }
        }
    }
}

private struct ActiveDownloadRow: View {
    let item: DownloadItemState
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        LibraryRow(title: item.fileName, subtitle: progressText, action: {}) {
            FileIcon(path: "", fileName: item.fileName)
        } trailing: {
            if item.state == "inProgress" {
                ProgressView(value: item.percent >= 0 ? Double(item.percent) : nil, total: 100)
                    .progressViewStyle(.circular).controlSize(.small)
            }
        }
        .contextMenu {
            if item.state == "inProgress" {
                Button("Cancel") { store.downloadManager.cancel(item.id) }
            } else {
                if store.downloadManager.canRetry(item.id) { Button("Try Again") { store.downloadManager.retry(item.id) } }
                Button("Remove from List") { store.downloadManager.removeRecord(item.id) }
            }
        }
    }
    private var progressText: String {
        if item.state == "cancelled" { return String(localized: "Download cancelled") }
        if item.state == "failed" { return item.errorDescription ?? String(localized: "Download failed") }
        func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return item.totalBytes > 0 ? "\(bytes(item.receivedBytes)) / \(bytes(item.totalBytes))" : bytes(item.receivedBytes)
    }
}

private struct DownloadRecordRow: View {
    let record: DownloadRecord
    @EnvironmentObject var store: BrowserStore
    @State private var fileExists: Bool?

    var body: some View {
        let exists = fileExists != false
        LibraryRow(title: record.fileName, subtitle: subtitle(exists: exists), dimmed: !exists,
                   action: { if exists { NSWorkspace.shared.open(record.fileURL) } }) {
            FileIcon(path: record.fullPath, fileName: record.fileName)
        } trailing: {
            EmptyView()
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(record.fileURL) }.disabled(!exists)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.fileURL]) }.disabled(!exists)
            Button("Copy Download Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.urlString, forType: .string)
            }
            Divider()
            Button("Remove from List") { store.removeDownloadRecord(record) }
        }
        .task(id: record.fullPath) {
            fileExists = nil
            let path = record.fullPath
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard !Task.isCancelled else { return }
            fileExists = exists
        }
    }

    private func subtitle(exists: Bool) -> String {
        if !exists { return String(localized: "Moved or deleted") }
        let kind = UTType(filenameExtension: (record.fileName as NSString).pathExtension)?.localizedDescription
            ?? String(localized: "Download")
        return record.sourceHost.isEmpty ? kind : String(localized: "\(kind) from \(record.sourceHost)")
    }
}

// MARK: Media

private struct MediaGrid: View {
    let search: String
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        let media = store.downloadRecords.filter {
            $0.isMedia && FileManager.default.fileExists(atPath: $0.fullPath) && matches(search, $0.fileName)
        }
        if media.isEmpty {
            LibraryEmpty(symbol: "photo.on.rectangle", text: search.isEmpty ? "Downloaded images and videos appear here" : "No matches")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(media) { r in MediaTile(record: r) }
                }
                .padding(.trailing, 10).padding(.vertical, 8)
            }
        }
    }
}

private struct MediaTile: View {
    let record: DownloadRecord
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                FileIcon(path: record.fullPath, fileName: record.fileName).padding(24)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.25 : 0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(record.fileURL) }
        .help(record.fileName)
        .accessibilityLabel(record.fileName)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.fileURL]) }
        }
        .task(id: record.fullPath) { image = await Self.thumbnail(record.fileURL) }
    }

    /// Decode a bounded thumbnail off the main actor; create AppKit objects on it.
    @MainActor
    static func thumbnail(_ url: URL) async -> NSImage? {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360,
                  ] as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, cg, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        }.value
        return data.flatMap { NSImage(data: $0) }
    }
}

// MARK: Spaces

private struct SpacesList: View {
    let search: String
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(store.spaces.filter { matches(search, $0.name) }) { space in
                    let count = store.pinned(in: space.id).count + store.today(in: space.id).count
                    LibraryRow(title: space.name, subtitle: String(localized: "\(count) tabs"),
                               action: { store.switchSpace(to: space.id); windowState.library = nil }) {
                        SpaceIcon(space: space, size: 15)
                            .foregroundStyle(.primary.opacity(0.75))
                            .frame(width: 30, height: 30)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } trailing: {
                        if space.id == store.currentSpaceID {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Edit Space…") { store.spaceEditor = SpaceEditorRequest(spaceID: space.id) }
                    }
                }
            }
            .padding(.trailing, 10).padding(.top, 6)
        }
    }
}

// MARK: Boosts

private struct BoostsList: View {
    let search: String
    @EnvironmentObject var store: BrowserStore

    var body: some View {
        let indices = store.boosts.indices.filter { matches(search, store.boosts[$0].name, store.boosts[$0].hostPattern) }
        if indices.isEmpty {
            LibraryEmpty(symbol: "paintbrush.pointed", text: search.isEmpty ? "No Boosts" : "No matches")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(indices, id: \.self) { i in
                        let boost = store.boosts[i]
                        LibraryRow(title: boost.name.isEmpty ? boost.hostPattern : boost.name,
                                   subtitle: boost.hostPattern, action: { store.onOpenSettings?(.boosts) }) {
                            FaviconView(key: nil, size: 18)
                                .frame(width: 30, height: 30)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } trailing: {
                            Toggle("", isOn: Binding(get: { store.boosts[i].isEnabled },
                                                     set: { store.boosts[i].isEnabled = $0; store.scheduleSave(); store.scheduleBoostApply() }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                .accessibilityLabel(boost.name)
                        }
                    }
                }
                .padding(.trailing, 10).padding(.top, 6)
            }
        }
    }
}

// MARK: Archived tabs

private struct ArchivedList: View {
    let search: String
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var windowState: WindowTabState

    var body: some View {
        let tabs = store.archived.filter { matches(search, $0.displayTitle, $0.urlString) }
        if tabs.isEmpty {
            LibraryEmpty(symbol: "archivebox", text: search.isEmpty ? "Closed tabs appear here for 30 days" : "No matches")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(grouped(tabs, date: \.lastVisitedAt), id: \.0) { day, group in
                        SectionTitle(text: day)
                        ForEach(group) { tab in
                            LibraryRow(title: tab.displayTitle, subtitle: tab.displayHost,
                                       action: { restore(tab) }) {
                                FaviconView(key: store.faviconKey(for: tab), size: 18).frame(width: 30, height: 30)
                            } trailing: {
                                EmptyView()
                            }
                            .contextMenu {
                                Button("Restore") { restore(tab) }
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(tab.urlString, forType: .string)
                                }
                                Divider()
                                Button("Delete", role: .destructive) { store.deletePermanently(tab) }
                            }
                        }
                    }
                }
                .padding(.trailing, 10).padding(.bottom, 16)
            }
        }
    }

    private func restore(_ tab: BrowserTab) {
        store.restore(tab)
        if let fresh = store.tab(tab.id) { store.select(fresh) }
        windowState.library = nil
    }
}
