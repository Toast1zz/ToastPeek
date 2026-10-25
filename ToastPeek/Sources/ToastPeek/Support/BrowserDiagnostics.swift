import Foundation

/// Geometry and lifecycle only. Never record URLs, page text, cookies or input.
enum BrowserDiagnostics {
    private static let queue = DispatchQueue(label: "app.toastpeek.diagnostics", qos: .utility)
    static func record(_ snapshot: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let entry = data
        let url = AppPaths.logs.appendingPathComponent("presentation.jsonl")
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: entry) } catch { }
        }
    }
}
