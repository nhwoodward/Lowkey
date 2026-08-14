import AppKit
import ApplicationServices
import Darwin

struct PasteTarget {
    let pid: pid_t
    let bundleIdentifier: String
    let localizedName: String
    var weztermPaneID: String?
    var weztermSocket: String?

    // Deliberately cheap: no process spawns. This runs on the main thread the
    // instant recording starts. The wezterm pane, which needs a CLI call, is
    // resolved asynchronously afterwards or lazily at paste time.
    static func capture() -> PasteTarget {
        let front = NSWorkspace.shared.frontmostApplication
        return PasteTarget(
            pid: front?.processIdentifier ?? 0,
            bundleIdentifier: front?.bundleIdentifier ?? "",
            localizedName: front?.localizedName ?? "",
            weztermPaneID: nil,
            weztermSocket: nil
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

            // Always park the transcript on the clipboard first.
            let focus = DispatchQueue.main.sync { FocusedField.probe() }
            let previous = DispatchQueue.main.sync { writeClipboard(text) }

            if destination.isWezTerm {
                let routing = weztermRouting()
                let pane: String?
                if let capturedPane = destination.weztermPaneID,
                   let routing,
                   destination.weztermSocket == routing.socket {
                    pane = capturedPane
                } else {
                    pane = routing.flatMap { focusedWeztermPane(using: $0) }
                }

                if let routing, sendViaWezterm(text, pane: pane, routing: routing) {
                    log("wezterm send-text pane=\(pane ?? "active")")
                    finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .unknown, completion: completion)
                    return
                }

                if let routing,
                   let refreshed = weztermRouting(),
                   refreshed.socket != routing.socket,
                   let refreshedPane = focusedWeztermPane(using: refreshed),
                   sendViaWezterm(text, pane: refreshedPane, routing: refreshed) {
                    log("wezterm send-text pane=\(refreshedPane)")
                    finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .unknown, completion: completion)
                    return
                }
                log("wezterm send-text failed, falling through to keystroke")
            }

            Thread.sleep(forTimeInterval: prePasteDelay)
            waitForModifiersToClear()

            // PASTE CONTRACT: never skip the keystroke because a probe
            // failed. AX lies for WezTerm, Zen, Notes, and Chromium.
            // Clipboard is already filled. Worst case the user Cmd+V.
            var outcome = PasteOutcome.unknown
            if isTrusted() {
                DispatchQueue.main.sync { pasteFromClipboardVoiceInk() }
                log("voiceink hid tap posted")
                outcome = detectKeystrokeOutcome(before: focus.value, text: text)
            } else {
                let scriptOK = DispatchQueue.main.sync { pasteUsingAppleScript() }
                log("applescript=\(scriptOK) trusted=false")
                outcome = scriptOK ? detectKeystrokeOutcome(before: focus.value, text: text) : .unknown
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
        guard after.hasFocus, let value = after.value else {
            // No readable field. The keystroke may still have landed
            // (terminal, Chromium). Keep the clipboard; do not alarm.
            return .unknown
        }
        if value.contains(text) { return .succeeded }
        if let before, value.count > before.count { return .succeeded }
        return .failed
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

    private struct WeztermRouting {
        let binary: String
        let environment: [String: String]

        var socket: String? {
            environment["WEZTERM_UNIX_SOCKET"]
        }
    }

    private static func weztermRouting() -> WeztermRouting? {
        guard let binary = weztermBinary() else { return nil }
        return WeztermRouting(binary: binary, environment: weztermEnvironment())
    }

    static func focusedWeztermPane() -> String? {
        focusedWeztermPaneInfo()?.id
    }

    static func focusedWeztermPaneInfo() -> (id: String, socket: String?)? {
        guard let routing = weztermRouting(), let id = focusedWeztermPane(using: routing) else {
            return nil
        }
        return (id: id, socket: routing.socket)
    }

    private static func focusedWeztermPane(using routing: WeztermRouting) -> String? {
        guard let clients = runJSON(routing.binary, ["cli", "list-clients", "--format", "json"], timeout: 3.0, environment: routing.environment) as? [[String: Any]] else {
            log("wezterm list-clients failed")
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

    private static func runJSON(
        _ binary: String,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]
    ) -> Any? {
        let result = TimedProcess.run(
            executable: binary,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
        guard result.status == 0, !result.stdout.isEmpty else {
            log("wezterm cli status=\(result.status) bytes=\(result.stdout.count)")
            return nil
        }
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

    private static func sendViaWezterm(_ text: String, pane: String?, routing: WeztermRouting) -> Bool {
        var arguments = ["cli", "send-text"]
        if let pane {
            arguments += ["--pane-id", pane]
        }
        let result = TimedProcess.run(
            executable: routing.binary,
            arguments: arguments,
            stdin: Data(text.utf8),
            environment: routing.environment,
            timeout: 3.0
        )
        if result.status != 0 {
            log("wezterm send-text status=\(result.status) pane=\(pane ?? "-")")
        }
        return result.status == 0
    }

    private static func isLiveWeztermSocket(at path: String) -> Bool {
        let bytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return false }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        address.sun_family = sa_family_t(AF_UNIX)

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                Darwin.connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    private static func weztermEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "WEZTERM_PANE")

        if let inherited = env["WEZTERM_UNIX_SOCKET"], isLiveWeztermSocket(at: inherited) {
            return env
        }
        env.removeValue(forKey: "WEZTERM_UNIX_SOCKET")

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/wezterm", isDirectory: true)
        let socks = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let newest = socks
            .filter {
                $0.lastPathComponent.hasPrefix("gui-sock-") &&
                isLiveWeztermSocket(at: $0.path)
            }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }

        if let newest {
            env["WEZTERM_UNIX_SOCKET"] = newest.path
        }
        return env
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
        AppLog.write(to: logURL, line)
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
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
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
