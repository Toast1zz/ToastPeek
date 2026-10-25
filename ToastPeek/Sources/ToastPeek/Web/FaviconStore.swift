import SwiftUI
import AppKit
import CryptoKit
import ImageIO

/// A bounded, anonymous fetch. Stream limits apply before image decoding.
enum FaviconLoader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()
    nonisolated static func fetch(_ url: URL) async -> Data? {
        guard ["http", "https"].contains(url.scheme ?? "") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  ["http", "https"].contains(response.url?.scheme ?? ""),
                  response.expectedContentLength <= 524_288 else { return nil }
            var data = Data()
            for try await byte in bytes {
                if Task.isCancelled || data.count >= 524_288 { return nil }
                data.append(byte)
            }
            return data.isEmpty ? nil : data
        } catch { return nil }
    }
}

@MainActor
final class FaviconStore {
    static let shared = FaviconStore()
    private let liveSlots = NSHashTable<FaviconSlot>.weakObjects()
    private let slots = NSCache<NSString, FaviconSlot>()
    private let directory: URL
    private static let diskQueue = DispatchQueue(label: "app.toastpeek.favicons", qos: .utility)
    private(set) var generation = 0

    private init() {
        slots.countLimit = 512
        directory = AppPaths.support.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(forHost host: String) -> URL {
        let key = SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".png")
    }

    private static func image(_ data: Data) -> NSImage? {
        guard data.count <= 524_288,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024 else { return nil }
        return NSImage(data: data)
    }

    func slot(forHost host: String) -> FaviconSlot {
        let key = host.lowercased() as NSString
        if let slot = slots.object(forKey: key) { return slot }
        let slot = FaviconSlot()
        slots.setObject(slot, forKey: key)
        liveSlots.add(slot)
        guard !host.isEmpty else { return slot }
        let url = fileURL(forHost: host), expected = generation
        Self.diskQueue.async { [weak self, weak slot] in
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                  size <= 524_288, let data = try? Data(contentsOf: url) else { return }
            DispatchQueue.main.async { [weak self, weak slot] in
                guard let self, self.generation == expected, let slot, slot.image == nil else { return }
                slot.image = Self.image(data)
            }
        }
        return slot
    }

    func store(_ data: Data, forHost host: String, generation expected: Int? = nil) {
        guard !host.isEmpty, expected == nil || expected == generation, let image = Self.image(data) else { return }
        slot(forHost: host).image = image
        let url = fileURL(forHost: host), dir = directory
        Self.diskQueue.async {
            try? data.write(to: url, options: .atomic)
            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            let ordered = entries.compactMap { file -> (URL, Int, Date)? in
                guard let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                return (file, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var total = ordered.reduce(0) { $0 + $1.1 }, count = ordered.count
            for (file, bytes, _) in ordered where total > 25_000_000 || count > 512 {
                try? fm.removeItem(at: file)
                total -= bytes; count -= 1
            }
        }
    }

    func prefetch(hosts: [String]) { }

    func removeAll(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void = { _ in }) {
        generation += 1
        // Existing views retain their slots; clear those before evicting.
        for slot in liveSlots.allObjects { slot.image = nil }
        slots.removeAllObjects()
        let dir = directory
        Self.diskQueue.async {
            let fm = FileManager.default
            let result: Result<Void, Error> = Result {
                guard fm.fileExists(atPath: dir.path) else { return }
                for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    try fm.removeItem(at: file)
                }
            }
            DispatchQueue.main.async { completion(result) }
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
