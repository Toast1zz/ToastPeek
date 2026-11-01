import SwiftUI
import AppKit
import ImageIO

/// Icons are session-only and scoped to the WebKit profile and complete origin.
struct FaviconKey: Hashable {
    let profileID: UUID
    let origin: String

    init?(url: URL?, profileID: UUID?) {
        guard let url, let profileID, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        self.profileID = profileID
        self.origin = SiteOrigin.make(url)
    }
}

@MainActor
final class FaviconStore {
    static let shared = FaviconStore()
    private let slots = NSCache<NSString, FaviconSlot>()
    private var liveSlots: [FaviconKey: NSHashTable<FaviconSlot>] = [:]
    private(set) var generation = 0

    private init() { slots.countLimit = 512 }

    private func cacheKey(_ key: FaviconKey) -> NSString {
        "\(key.profileID.uuidString)|\(key.origin)" as NSString
    }

    func slot(for key: FaviconKey?) -> FaviconSlot {
        guard let key else { return FaviconSlot() }
        let cacheKey = cacheKey(key)
        if let slot = slots.object(forKey: cacheKey) { return slot }
        let slot = FaviconSlot()
        if liveSlots.count >= 512 {
            liveSlots = liveSlots.filter { !$0.value.allObjects.isEmpty }
        }
        slots.setObject(slot, forKey: cacheKey)
        let table = liveSlots[key] ?? NSHashTable<FaviconSlot>.weakObjects()
        table.add(slot)
        liveSlots[key] = table
        return slot
    }

    func store(_ data: Data, for key: FaviconKey, generation expected: Int) {
        guard expected == generation, data.count <= 524_288,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024,
              let image = NSImage(data: data) else { return }
        slot(for: key).image = image
    }

    func removeProfile(_ profileID: UUID) {
        generation += 1
        for key in Array(liveSlots.keys) where key.profileID == profileID {
            liveSlots[key]?.allObjects.forEach { $0.image = nil }
            liveSlots.removeValue(forKey: key)
            slots.removeObject(forKey: cacheKey(key))
        }
    }

    func removeAll(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void = { _ in }) {
        generation += 1
        for table in liveSlots.values { table.allObjects.forEach { $0.image = nil } }
        liveSlots.removeAll()
        slots.removeAllObjects()
        // Remove legacy host-only icons as well; they must never be read by this cache.
        let directory = AppPaths.support.appendingPathComponent("Favicons", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            let result: Result<Void, Error> = Result {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
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

/// Unscoped consumers intentionally get a globe rather than another profile's icon.
struct FaviconView: View {
    var url: URL? = nil
    var profileID: UUID? = nil
    var size: CGFloat = 16

    var body: some View {
        let key = FaviconKey(url: url, profileID: profileID)
        FaviconImage(slot: FaviconStore.shared.slot(for: key), size: size)
            .id(key)
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
