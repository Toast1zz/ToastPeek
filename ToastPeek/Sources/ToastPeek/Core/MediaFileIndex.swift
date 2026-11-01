import Foundation

/// A single worker bounds filesystem concurrency. Cache lives across media view
/// recreation, while a cancelled view stops the scan between individual probes.
actor MediaFileIndex {
    static let shared = MediaFileIndex()
    typealias Probe = @Sendable (String) -> Bool
    private struct Entry { let exists: Bool; let checked: Date }
    private var cache: [String: Entry] = [:]
    private let probe: Probe
    private let lifetime: TimeInterval

    init(lifetime: TimeInterval = 15, probe: @escaping Probe = { FileManager.default.fileExists(atPath: $0) }) {
        self.lifetime = lifetime
        self.probe = probe
    }

    func existingPaths(_ paths: [String], now: Date = Date()) throws -> Set<String> {
        var existing = Set<String>()
        let wanted = Set(paths)
        // Bound memory to the current library, rather than every historical path.
        cache = cache.filter { wanted.contains($0.key) }
        for path in paths {
            try Task.checkCancellation()
            let exists: Bool
            if let entry = cache[path], now.timeIntervalSince(entry.checked) < lifetime {
                exists = entry.exists
            } else {
                exists = probe(path)
                cache[path] = Entry(exists: exists, checked: now)
            }
            if exists { existing.insert(path) }
        }
        try Task.checkCancellation()
        return existing
    }
}
