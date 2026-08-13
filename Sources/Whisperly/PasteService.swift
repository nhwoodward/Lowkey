import AppKit
import ApplicationServices
import Carbon
import Darwin

struct PasteTarget {
    let pid: pid_t
    let bundleIdentifier: String
    let localizedName: String
    var weztermPaneID: String?

    // Deliberately cheap: no process spawns. This runs on the main thread the
    // instant recording starts. The wezterm pane, which needs a CLI call, is
    // resolved asynchronously afterwards or lazily at paste time.
    static func capture() -> PasteTarget {
        let front = NSWorkspace.shared.frontmostApplication
        return PasteTarget(
            pid: front?.processIdentifier ?? 0,
            bundleIdentifier: front?.bundleIdentifier ?? "",
            localizedName: front?.localizedName ?? "",
            weztermPaneID: nil
        )
    }

    var isWezTerm: Bool {
        weztermPaneID != nil || "\(bundleIdentifier) \(localizedName)".lowercased().contains("wezterm")
    }
}

enum PasteService {
    private static let logURL = Config.logsDirectory.appendingPathComponent("paste.log")
    private static let prePasteDelay: TimeInterval = 0.10
    private static let keyGap: useconds_t = 10_000

    static func promptAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func insert(
        _ text: String,
        into target: PasteTarget? = nil,
        clipboard: ClipboardBehavior,
        completion: ((PasteOutcome) -> Void)? = nil
    ) {
        guard !text.isEmpty else {
            completion?(.unknown)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let destination = target ?? DispatchQueue.main.sync { PasteTarget.capture() }
            log("insert len=\(text.count) app=\(destination.localizedName) pane=\(destination.weztermPaneID ?? "-") trusted=\(isTrusted()) clipboard=\(clipboard.rawValue)")

            // Always park the transcript on the clipboard first. That is the
            // failsafe when no field is focused or WezTerm swallows send-text.
            let focus = DispatchQueue.main.sync { FocusedField.probe() }
            let previous = DispatchQueue.main.sync { writeClipboard(text) }

            var outcome = PasteOutcome.unknown
            if destination.isWezTerm {
                let pane = destination.weztermPaneID ?? focusedWeztermPane()
                if let pane, sendViaWezterm(text, pane: pane) {
                    log("wezterm send-text pane=\(pane)")
                    // CLI 0 only means the pane accepted bytes, not that the
                    // user had a field. Keep the clipboard unless they chose Never.
                    finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .unknown, completion: completion)
                    return
                }
                log("wezterm send-text failed, falling through to keystroke")
            }

            Thread.sleep(forTimeInterval: prePasteDelay)
            waitForModifiersToClear()

            if !focus.hasFocus {
                log("no focused field, leaving clipboard")
                finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .failed, completion: completion)
                return
            }

            // VoiceInk default: CGEvent Cmd+V on the hid tap, only when trusted.
            // AppleScript reports success on macOS 27 without the keystroke landing
            // in Notes/Zen, so it is fallback only.
            if isTrusted() {
                DispatchQueue.main.sync { pasteFromClipboardVoiceInk() }
                log("voiceink hid tap posted")
                outcome = detectKeystrokeOutcome(before: focus.value, text: text)
            } else {
                let scriptOK = DispatchQueue.main.sync { pasteUsingAppleScript() }
                log("applescript=\(scriptOK) trusted=false")
                outcome = scriptOK ? detectKeystrokeOutcome(before: focus.value, text: text) : .failed
            }

            finishOnMain(previous, clipboard: clipboard, expected: text, outcome: outcome, completion: completion)
        }
    }

    enum PasteOutcome: String {
        case succeeded
        case failed
        case unknown
    }

    private static func shouldRestore(_ behavior: ClipboardBehavior, outcome: PasteOutcome) -> Bool {
        switch behavior {
        case .always:
            return false
        case .never:
            return true
        case .ifPasteFails:
            return outcome == .succeeded
        }
    }

    private static func detectKeystrokeOutcome(before: String?, text: String) -> PasteOutcome {
        Thread.sleep(forTimeInterval: 0.08)
        let after = DispatchQueue.main.sync { FocusedField.probe() }
        if !after.hasFocus { return .failed }
        if let value = after.value {
            if value.contains(text) { return .succeeded }
            if let before, value.count > before.count { return .succeeded }
            return .failed
        }
        // Focused but unreadable (typical Chromium). Do not pretend it worked.
        return .unknown
    }

    private static func finishOnMain(
        _ previous: String?,
        clipboard: ClipboardBehavior,
        expected: String,
        outcome: PasteOutcome,
        completion: ((PasteOutcome) -> Void)?
    ) {
        let restore = shouldRestore(clipboard, outcome: outcome)
        log("paste outcome=\(outcome.rawValue) restore=\(restore)")
        DispatchQueue.main.async {
            finishRestore(previous, enabled: restore, expected: expected, completion: completion, outcome: outcome)
        }
    }

    static func focusedWeztermPane() -> String? {
        guard let binary = weztermBinary() else { return nil }
        guard let clients = runJSON(binary, ["cli", "list-clients", "--format", "json"], timeout: 1.2) as? [[String: Any]] else {
            return nil
        }
        let ranked = clients.compactMap { row -> (id: String, idle: Double)? in
            guard let id = row["focused_pane_id"] else { return nil }
            let idle = idleSeconds(row["idle_time"])
            return (id: String(describing: id), idle: idle)
        }
        .sorted { $0.idle < $1.idle }
        if let best = ranked.first {
            log("focused wezterm pane=\(best.id) idle=\(best.idle)")
            return best.id
        }
        return nil
    }

    private static func idleSeconds(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let dict = value as? [String: Any] {
            let secs = (dict["secs"] as? Double) ?? Double(dict["secs"] as? Int ?? 0)
            let nanos = (dict["nanos"] as? Double) ?? Double(dict["nanos"] as? Int ?? 0)
            return secs + nanos / 1_000_000_000
        }
        return Double.greatestFiniteMagnitude
    }

    private static func runJSON(_ binary: String, _ arguments: [String], timeout: TimeInterval) -> Any? {
        let result = TimedProcess.run(executable: binary, arguments: arguments, timeout: timeout)
        guard result.status == 0, !result.stdout.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: result.stdout)
    }

    @discardableResult
    private static func writeClipboard(_ text: String) -> String? {
        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        board.declareTypes([.string, transient, concealed, autoGenerated], owner: nil)
        board.setString(text, forType: .string)
        board.setString("", forType: transient)
        board.setString("", forType: concealed)
        board.setString("", forType: autoGenerated)
        return previous
    }

    private static func finishRestore(
        _ previous: String?,
        enabled: Bool,
        expected: String,
        completion: ((PasteOutcome) -> Void)?,
        outcome: PasteOutcome
    ) {
        if enabled, let previous {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let board = NSPasteboard.general
                if board.string(forType: .string) == expected {
                    board.clearContents()
                    board.setString(previous, forType: .string)
                }
                completion?(outcome)
            }
        } else {
            completion?(outcome)
        }
    }

    private static func waitForModifiersToClear() {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let ns = NSEvent.modifierFlags.intersection([.command, .option, .shift, .control])
            let cg = CGEventSource.flagsState(.combinedSessionState)
                .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
            if ns.isEmpty && cg.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    @discardableResult
    private static func pasteUsingAppleScript() -> Bool {
        let source = "tell application \"System Events\" to key code 9 using command down"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            log("applescript error=\(error)")
            return false
        }
        return true
    }

    private static func pasteFromClipboardVoiceInk() {
        let source = CGEventSource(stateID: .privateState)
        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else { return }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for event in [cmdDown, vDown, vUp, cmdUp] {
            event.post(tap: .cghidEventTap)
            usleep(keyGap)
        }
    }

    private static func weztermBinary() -> String? {
        let paths = [
            "/opt/homebrew/bin/wezterm",
            "/Applications/WezTerm.app/Contents/MacOS/wezterm",
            "/usr/local/bin/wezterm",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func sendViaWezterm(_ text: String, pane: String) -> Bool {
        guard let binary = weztermBinary() else { return false }
        let result = TimedProcess.run(
            executable: binary,
            arguments: ["cli", "send-text", "--pane-id", pane],
            stdin: Data(text.utf8),
            timeout: 1.5
        )
        return result.status == 0
    }

    private enum FocusedField {
        struct Probe {
            var hasFocus: Bool
            var value: String?
        }

        static func probe() -> Probe {
            let system = AXUIElementCreateSystemWide()
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                system,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success, let focused else {
                return Probe(hasFocus: false, value: nil)
            }
            let element = focused as! AXUIElement
            var role: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let roleName = role as? String ?? ""
            if Self.nonEditableRoles.contains(roleName) {
                return Probe(hasFocus: false, value: nil)
            }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String {
                return Probe(hasFocus: true, value: text)
            }
            return Probe(hasFocus: true, value: nil)
        }

        private static let nonEditableRoles: Set<String> = [
            "AXWindow", "AXApplication", "AXToolbar", "AXMenuBar", "AXMenu",
            "AXMenuItem", "AXButton", "AXImage", "AXSplitter", "AXScrollBar",
            "AXTabGroup", "AXRadioButton", "AXCheckBox", "AXSlider",
        ]
    }

    static func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

enum TimedProcess {
    struct Result {
        var status: Int32
        var stdout: Data
    }

    static func run(
        executable: String,
        arguments: [String],
        stdin: Data? = nil,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        if stdin != nil {
            process.standardInput = input
        }
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: Data())
        }
        if let stdin {
            try? input.fileHandleForWriting.write(contentsOf: stdin)
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.3)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.03)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return Result(status: -1, stdout: Data())
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return Result(status: process.terminationStatus, stdout: data)
    }
}
