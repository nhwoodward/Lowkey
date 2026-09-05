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
    private static let deliveryQueue = DispatchQueue(label: "app.lowkey.paste", qos: .userInitiated)
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

        deliveryQueue.async {
            let destination = target ?? DispatchQueue.main.sync { PasteTarget.capture() }
            log("insert len=\(text.count) app=\(destination.localizedName) pane=\(destination.weztermPaneID ?? "-") trusted=\(isTrusted()) clipboard=\(clipboard.rawValue)")

            // Always park the transcript on the clipboard first.
            let previous = DispatchQueue.main.sync { writeClipboard(text) }

            guard destination.pid > 0, destination.pid != getpid() else {
                finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .failed, completion: completion)
                return
            }
            if destination.isWezTerm {
                let routing = weztermRouting()
                if let routing, let pane = destination.weztermPaneID,
                   destination.weztermSocket == routing.socket,
                   sendViaWezterm(text, pane: pane, routing: routing) {
                    log("wezterm send-text pane=\(pane)")
                    finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .succeeded, completion: completion)
                    return
                }
                log("wezterm send-text failed, falling through to keystroke")
            }

            Thread.sleep(forTimeInterval: prePasteDelay)
            waitForModifiersToClear()

            // Probe only on the keystroke path, where the answer is actually
            // consumed, and only from this background thread. paste.log showed
            // 6-7s freezes when this ran under DispatchQueue.main.sync: the AX
            // round trip to WezTerm hit its 6s default timeout while the main
            // thread sat blocked.
            guard destinationStillFocused(destination) else {
                log("destination changed; preserving transcript without typing")
                finishOnMain(previous, clipboard: clipboard, expected: text, outcome: .failed, completion: completion)
                return
            }
            let focus = FocusedField.probe()

            // PASTE CONTRACT: never skip the keystroke because a probe
            // failed. AX lies for WezTerm, Zen, Notes, and Chromium.
            // Clipboard is already filled. Worst case the user Cmd+V.
            var outcome = PasteOutcome.failed
            if isTrusted() {
                let sent = DispatchQueue.main.sync { () -> Bool in
                    guard destinationStillFocused(destination),
                          NSPasteboard.general.changeCount == previous.writtenChangeCount else { return false }
                    pasteFromClipboardVoiceInk()
                    return true
                }
                if sent { outcome = detectKeystrokeOutcome(before: focus.value, text: text) }
            }

            finishOnMain(previous, clipboard: clipboard, expected: text, outcome: outcome, completion: completion)
        }
    }

    private static func destinationStillFocused(_ target: PasteTarget) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid
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
        let after = FocusedField.probe()
        guard after.hasFocus, let value = after.value else {
            // No readable field. The keystroke may still have landed
            // (terminal, Chromium). Keep the clipboard; do not alarm.
            return .unknown
        }
        if value.contains(text) { return .succeeded }
        return .failed
    }

    private static func finishOnMain(
        _ previous: ClipboardSnapshot,
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

    struct ClipboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let writtenChangeCount: Int
    }

    @discardableResult
    static func writeClipboard(_ text: String, board: NSPasteboard = .general) -> ClipboardSnapshot {
        let saved = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        board.declareTypes([.string, transient, concealed, autoGenerated], owner: nil)
        board.setString(text, forType: .string)
        for type in [transient, concealed, autoGenerated] { board.setString("", forType: type) }
        return ClipboardSnapshot(items: saved, writtenChangeCount: board.changeCount)
    }

    static func restoreClipboard(_ saved: ClipboardSnapshot, board: NSPasteboard = .general) {
        guard board.changeCount == saved.writtenChangeCount else { return }
        board.clearContents()
        let items = saved.items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    private static func finishRestore(
        _ previous: ClipboardSnapshot,
        enabled: Bool,
        expected: String,
        completion: ((PasteOutcome) -> Void)?,
        outcome: PasteOutcome
    ) {
        if enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                restoreClipboard(previous)
                completion?(outcome)
            }
        } else { completion?(outcome) }
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
            // Cap every AX round trip at half a second. The system default is
            // 6 seconds, and an app that ignores AX (WezTerm, Chromium) makes
            // the caller eat all of it. A lost answer is fine: unknown already
            // means "keep the clipboard, don't alarm".
            AXUIElementSetMessagingTimeout(system, 0.5)
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                system,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success, let focused else {
                return Probe(hasFocus: false, value: nil)
            }
            let element = focused as! AXUIElement
            AXUIElementSetMessagingTimeout(element, 0.5)
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
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: Data())
        }
        try? out.fileHandleForWriting.close()
        defer { try? out.fileHandleForReading.close(); try? input.fileHandleForWriting.close() }
        let readFD = out.fileHandleForReading.fileDescriptor
        let writeFD = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(readFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(writeFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        var offset = 0
        var inputClosed = stdin == nil
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while true {
            // Drain while the child runs. Waiting for termination first can
            // deadlock any CLI that fills its stdout pipe.
            while Date() < deadline {
                let count = Darwin.read(readFD, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
                if data.count > 8 * 1024 * 1024 { timedOut = true; break }
            }
            if !process.isRunning { break }
            if Date() >= deadline || timedOut { timedOut = true; break }
            if let stdin, !inputClosed {
                if offset < stdin.count {
                    let written = stdin.withUnsafeBytes { bytes in
                        Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), min(16384, stdin.count - offset))
                    }
                    if written > 0 { offset += written }
                    else if written < 0, errno != EAGAIN && errno != EINTR {
                        try? input.fileHandleForWriting.close()
                        inputClosed = true
                    }
                }
                if offset == stdin.count {
                    try? input.fileHandleForWriting.close()
                    inputClosed = true
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if timedOut {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.3)
            while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return Result(status: -1, stdout: Data())
        }
        while data.count <= 8 * 1024 * 1024 {
            let count = Darwin.read(readFD, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return Result(status: process.terminationStatus, stdout: data)
    }
}
