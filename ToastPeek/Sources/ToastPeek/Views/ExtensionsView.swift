import SwiftUI
import AppKit

/// Quits and reopens the app once this process has fully exited (two
/// instances must never share the browser profile).
enum AppRelauncher {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open '\(bundle)'"]
        try? task.run()
        NSApp.terminate(nil)
    }
}
