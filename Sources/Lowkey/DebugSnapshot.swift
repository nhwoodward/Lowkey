#if DEBUG
import AppKit

// Dev-only: LOWKEY_SNAPSHOT_DIR=<dir> renders every visible window to PNG on
// a timer, so UI review works without Screen Recording permission.
// LOWKEY_SNAPSHOT_EVERY (seconds, default 1.5) and LOWKEY_SNAPSHOT_COUNT
// (default 8) bound the run. Glass and vibrancy render approximately.
enum DebugSnapshot {
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["LOWKEY_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let interval = env["LOWKEY_SNAPSHOT_EVERY"].flatMap(Double.init) ?? 1.5
        let count = env["LOWKEY_SNAPSHOT_COUNT"].flatMap(Int.init) ?? 8
        var shot = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            shot += 1
            capture(into: directory, index: shot)
            if shot >= count { timer.invalidate() }
        }
    }

    private static func capture(into directory: URL, index: Int) {
        for (number, window) in NSApp.windows.enumerated()
        where window.isVisible && !String(describing: type(of: window)).contains("StatusBar") {
            guard let frameView = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = frameView.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            frameView.cacheDisplay(in: bounds, to: rep)
            let title = window.title.isEmpty ? (window is NSPanel ? "panel" : "window\(number)") : window.title
            let name = String(format: "%02d-%@.png", index, title.replacingOccurrences(of: " ", with: "_"))
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        }
    }
}
#endif
