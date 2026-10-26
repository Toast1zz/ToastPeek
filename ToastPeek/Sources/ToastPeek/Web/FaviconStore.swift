import SwiftUI
import AppKit
import CryptoKit
import ImageIO
import WebKit

/// The cache never shares an authenticated icon across profiles or origins.
struct FaviconKey: Hashable {
    let profileID: UUID
    let origin: String

    init?(url: URL, profileID: UUID?) {
        guard let profileID, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty else { return nil }
        self.profileID = profileID
        origin = SiteOrigin.make(url)
    }

    var cacheID: String { profileID.uuidString + "|" + origin }
}

/// Capture native APIs before site scripts run. Requests execute in the page
/// world, where WebKit enforces the document's CSP as well as content rules.
@MainActor
enum FaviconLoader {
    static var userScript: WKUserScript {
        WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    private static let bootstrap = """
    (() => {
        const apply = Reflect.apply;
        const nativeFetch = window.fetch.bind(window);
        const encode = window.btoa.bind(window);
        const setTimer = window.setTimeout.bind(window);
        const clearTimer = window.clearTimeout.bind(window);
        const Abort = window.AbortController;
        const abort = Abort.prototype.abort;
        const signal = Object.getOwnPropertyDescriptor(Abort.prototype, 'signal').get;
        const status = Object.getOwnPropertyDescriptor(Response.prototype, 'status').get;
        const headers = Object.getOwnPropertyDescriptor(Response.prototype, 'headers').get;
        const body = Object.getOwnPropertyDescriptor(Response.prototype, 'body').get;
        const getHeader = Headers.prototype.get;
        const getReader = ReadableStream.prototype.getReader;
        const read = ReadableStreamDefaultReader.prototype.read;
        const cancel = ReadableStreamDefaultReader.prototype.cancel;
        const length = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), 'length').get;
        const char = String.fromCharCode;
        const request = async function(url) {
            if (typeof url !== 'string') return null;
            const controller = new Abort();
            const timer = setTimer(() => apply(abort, controller, []), 6000);
            let reader;
            try {
                // WebKit enforces same-origin and CSP even if page code calls this helper.
                const response = await nativeFetch(url, {credentials: 'same-origin',
                    mode: 'same-origin', redirect: 'error', signal: apply(signal, controller, [])});
                const declaredLength = apply(getHeader, apply(headers, response, []), ['Content-Length']);
                if (apply(status, response, []) !== 200 || +declaredLength > 524288) return null;
                reader = apply(getReader, apply(body, response, []), []);
                let binary = '', size = 0;
                while (true) {
                    const part = await apply(read, reader, []);
                    if (part.done) break;
                    const count = apply(length, part.value, []);
                    size += count;
                    if (size > 524288) return null;
                    for (let i = 0; i < count; i++) binary += char(part.value[i]);
                }
                return size ? encode(binary) : null;
            } catch (_) { return null; }
            finally {
                clearTimer(timer);
                apply(abort, controller, []);
                if (reader) { try { await apply(cancel, reader, []); } catch (_) {} }
            }
        };
        Object.defineProperty(window, '__toastpeekFaviconRequest', {
            value: request, writable: false, configurable: false
        });
    })();
    """

    static func fetch(_ url: URL, in view: WKWebView) async -> Data? {
        guard let page = view.url, ["http", "https"].contains(page.scheme ?? ""),
              SiteOrigin.make(url) == SiteOrigin.make(page), url.user == nil, url.password == nil,
              !Task.isCancelled else { return nil }
        // Never fall back to an isolated-world or URLSession request: either
        // would bypass the page's connect-src policy.
        guard let result = try? await view.callAsyncJavaScript(
            "return window.__toastpeekFaviconRequest(url);", arguments: ["url": url.absoluteString],
            in: nil, contentWorld: .page),
              !Task.isCancelled, let encoded = result as? String,
              encoded.utf8.count <= 699052 else { return nil }
        return Data(base64Encoded: encoded)
    }
}

@MainActor
final class FaviconStore {
    private let liveSlots = NSHashTable<FaviconSlot>.weakObjects()
    private let slots = NSCache<NSString, FaviconSlot>()
    private let directory: URL
    private static let diskQueue = DispatchQueue(label: "app.toastpeek.favicons", qos: .utility)
    private(set) var generation = 0

    init(directory: URL = AppPaths.support.appendingPathComponent("Favicons", isDirectory: true)) {
        slots.countLimit = 512
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: FaviconKey) -> URL {
        let digest = SHA256.hash(data: Data(key.cacheID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key.profileID.uuidString + "." + digest + ".png")
    }

    private static func image(_ data: Data) -> NSImage? {
        guard data.count <= 524_288,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 1024, height <= 1024 else { return nil }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }

    func slot(for key: FaviconKey) -> FaviconSlot {
        let cacheID = key.cacheID as NSString
        if let slot = slots.object(forKey: cacheID) { return slot }
        // A visible view can retain its slot after NSCache evicts it.
        if let retained = liveSlots.allObjects.first(where: { $0.key == key }) {
            slots.setObject(retained, forKey: cacheID)
            return retained
        }
        let slot = FaviconSlot(key: key)
        slots.setObject(slot, forKey: cacheID)
        liveSlots.add(slot)
        let url = fileURL(for: key), expected = generation
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

    @discardableResult
    func store(_ data: Data, for key: FaviconKey, generation expected: Int) -> Bool {
        guard expected == generation, let image = Self.image(data) else { return false }
        slot(for: key).image = image
        let url = fileURL(for: key), dir = directory
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
        return true
    }

    func remove(profileID: UUID, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        generation += 1
        for slot in liveSlots.allObjects where slot.key?.profileID == profileID {
            slot.image = nil
            if let key = slot.key { slots.removeObject(forKey: key.cacheID as NSString) }
        }
        let dir = directory, prefix = profileID.uuidString + "."
        Self.diskQueue.async {
            let result = Result<Void, Error> {
                guard FileManager.default.fileExists(atPath: dir.path) else { return }
                for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    where file.lastPathComponent.hasPrefix(prefix) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

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
    let key: FaviconKey?
    @Published var image: NSImage?
    init(key: FaviconKey? = nil) { self.key = key }
}

/// A tab's favicon, with a quiet globe placeholder.
struct FaviconView: View {
    @EnvironmentObject var store: BrowserStore
    let key: FaviconKey?
    var size: CGFloat = 16

    var body: some View {
        FaviconImage(slot: key.map { store.faviconStore.slot(for: $0) } ?? FaviconSlot(), size: size)
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

@MainActor
extension BrowserStore {
    func faviconKey(for tab: BrowserTab) -> FaviconKey? {
        FaviconKey(url: tab.url, profileID: controller(forTabID: tab.id)?.dataStoreID ?? profileSpace(for: tab).dataStoreID)
    }
}
