import SwiftUI
import AppKit

/// Favicons by host, as the engine reports them for loaded pages, cached on
/// disk so unloaded tabs, Favorites and history rows show real icons after
/// a relaunch. Nothing is fetched from the network here.
///
/// Each host has its own observable slot, so a new icon redraws only the
/// views showing that host, not every row of the sidebar and history.
@MainActor
final class FaviconStore {
    static let shared = FaviconStore()

    private var slots: [String: FaviconSlot] = [:]
    private let directory: URL
    private static let diskQueue = DispatchQueue(label: "app.toastpeek.favicons", qos: .utility)

    private init() {
        directory = AppPaths.support.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(forHost host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// The slot for a host; its first use loads the disk copy off the main thread.
    func slot(forHost host: String) -> FaviconSlot {
        if let slot = slots[host] { return slot }
        let slot = FaviconSlot()
        slots[host] = slot
        guard !host.isEmpty else { return slot }
        let url = fileURL(forHost: host)
        Self.diskQueue.async {
            guard let data = try? Data(contentsOf: url) else { return }
            DispatchQueue.main.async {
                if slot.image == nil { slot.image = NSImage(data: data) }
            }
        }
        return slot
    }

    func store(_ png: Data, forHost host: String) {
        guard !host.isEmpty, let image = NSImage(data: png) else { return }
        slot(forHost: host).image = image
        let url = fileURL(forHost: host)
        Self.diskQueue.async { try? png.write(to: url, options: .atomic) }
    }

    // MARK: Prefetch (default Favorites, imported bookmarks)

    private var prefetchQueue: [String] = []
    private var prefetching = 0
    private var prefetched: Set<String> = []

    /// Fetches `/favicon.ico` for hosts that have no icon yet — tabs that
    /// were never opened (seeded Favorites, imported bookmarks) would
    /// otherwise show a globe until first visit. Four at a time, one try
    /// per host per launch, no cookies.
    func prefetch(hosts: [String]) {
        for host in hosts where !host.isEmpty && !prefetched.contains(host) {
            prefetched.insert(host)
            let slot = slot(forHost: host)
            // Give the disk copy a moment to land before deciding it's missing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard slot.image == nil, let self else { return }
                self.prefetchQueue.append(host)
                self.pumpPrefetch()
            }
        }
    }

    private func pumpPrefetch() {
        while prefetching < 4, !prefetchQueue.isEmpty {
            let host = prefetchQueue.removeFirst()
            guard let url = URL(string: "https://\(host)/favicon.ico") else { continue }
            prefetching += 1
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.httpShouldHandleCookies = false
            URLSession.shared.dataTask(with: request) { data, response, _ in
                var png: Data?
                if let data, (response as? HTTPURLResponse)?.statusCode == 200,
                   let image = NSImage(data: data), image.isValid, image.size.width >= 8,
                   let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    png = rep.representation(using: .png, properties: [:])
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let png { self.store(png, forHost: host) }
                        self.prefetching -= 1
                        self.pumpPrefetch()
                    }
                }
            }.resume()
        }
    }

    /// Clear browsing data: forget every icon, in memory and on disk.
    func removeAll() {
        for slot in slots.values { slot.image = nil }
        let dir = directory
        Self.diskQueue.async {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".png") {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}

@MainActor
final class FaviconSlot: ObservableObject {
    @Published var image: NSImage?
}

/// A tab's favicon, with a quiet globe placeholder.
struct FaviconView: View {
    let host: String
    var size: CGFloat = 16

    var body: some View {
        FaviconImage(slot: FaviconStore.shared.slot(forHost: host), size: size)
            .id(host)
    }
}

private struct FaviconImage: View {
    @ObservedObject var slot: FaviconSlot
    let size: CGFloat

    var body: some View {
        Group {
            if let image = slot.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "globe")
                    .resizable().scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}
