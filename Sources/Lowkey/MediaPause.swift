import Foundation
import AppKit

enum MediaPause {
    // Ordering lives on this serial queue so a resume enqueued while a pause
    // is still running always sees the final paused list. Scripts go through
    // osascript with a hard timeout: the old NSAppleScript path had to run on
    // the main thread, so a stalled player could freeze recording start for
    // seconds. A child process can simply be killed.
    private static let queue = DispatchQueue(label: "app.lowkey.media", qos: .userInitiated)
    private static var paused: [String] = []

    private static let players: [(name: String, bundleID: String)] = [
        ("Music", "com.apple.Music"),
        ("Spotify", "com.spotify.client"),
        ("TV", "com.apple.TV"),
    ]

    static func pauseIfNeeded(enabled: Bool) {
        guard enabled else { return }
        // Cheap local check first: only players that are actually running are
        // worth an osascript round trip, and scripting an app that is not
        // running would launch it.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = players.filter { running.contains($0.bundleID) }.map(\.name)
        guard !candidates.isEmpty else { return }
        queue.async {
            for app in candidates where isPlaying(app) {
                run("tell application \"\(app)\" to pause")
                paused.append(app)
            }
        }
    }

    static func resumeIfNeeded() {
        queue.async {
            for app in paused {
                run("tell application \"\(app)\" to play")
            }
            paused = []
        }
    }

    private static func isPlaying(_ app: String) -> Bool {
        let result = TimedProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "tell application \"\(app)\" to player state as string"],
            timeout: 2.0
        )
        guard result.status == 0 else { return false }
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "playing"
    }

    private static func run(_ source: String) {
        _ = TimedProcess.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", source],
            timeout: 2.0
        )
    }
}
