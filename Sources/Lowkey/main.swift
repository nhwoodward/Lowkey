import AppKit

enum LowkeyMain {
    static func main() {
        // Headless engine test: transcribe the given clips and exit.
        if let clips = ProcessInfo.processInfo.environment["LOWKEY_TEST_PARAKEET"] {
            ParakeetTestHarness.run(
                paths: clips.split(separator: ",").map(String.init))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

LowkeyMain.main()
