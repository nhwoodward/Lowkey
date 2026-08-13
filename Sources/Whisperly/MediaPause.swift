import Foundation
import AppKit

enum MediaPause {
    // Ordering lives on this serial queue so a resume enqueued while a pause
    // is still running always sees the final paused list. The AppleScripts
    // themselves run on the main thread; NSAppleScript is not safe elsewhere.
    private static let queue = DispatchQueue(label: "app.whisperly.media", qos: .userInitiated)
    private static var paused: [String] = []

    static func pauseIfNeeded(enabled: Bool) {
        guard enabled else { return }
        queue.async {
            DispatchQueue.main.sync {
                for app in ["Music", "Spotify", "TV"] where isPlaying(app) {
                    run("tell application \"\(app)\" to pause")
                    paused.append(app)
                }
            }
        }
    }

    static func resumeIfNeeded() {
        queue.async {
            DispatchQueue.main.sync {
                for app in paused {
                    run("tell application \"\(app)\" to play")
                }
                paused = []
            }
        }
    }

    private static func isPlaying(_ app: String) -> Bool {
        let script = """
        if application "\(app)" is running then
            tell application "\(app)" to player state as string
        else
            "stopped"
        end if
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return result?.stringValue?.lowercased() == "playing"
    }

    private static func run(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
