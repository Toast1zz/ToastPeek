import Foundation

/// On-disk locations, plus the one-time move from the app's old name.
enum AppPaths {
    static let support: URL = {
        #if DEBUG
        // Test builds can run hermetically against a scratch data dir
        // (e.g. alongside the user's real instance) via this env var.
        // Release builds always use the real location.
        if let override = ProcessInfo.processInfo.environment["TOASTPEEK_SUPPORT_DIR"], !override.isEmpty {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ToastPeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logs: URL = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["TOASTPEEK_SUPPORT_DIR"], !override.isEmpty {
            let dir = support.appendingPathComponent("Logs", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        #endif
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/ToastPeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
