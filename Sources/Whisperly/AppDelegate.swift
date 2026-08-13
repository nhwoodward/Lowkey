import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private let engine = Engine()
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private let flowBar = FlowBarController()
    private var settings: SettingsWindowController?
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var recordStartedAt: Date?
    private var busy = false
    private var recording = false
    private var lastTranscript = ""
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var pasteTarget: PasteTarget?
    private var accessTimer: Timer?
    private var demoTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyAppearance()
        applyLoginItem()
        buildStatusItem()
        requestMicrophone()
        applyHotkey()
        restBar()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshMenu()
        }
        flowBar.onIdleTap = { [weak self] in self?.beginHold() }
        recorder.onWave = { [weak self] samples in
            self?.flowBar.pushWave(samples)
        }
        hotkey.onHoldStart = { [weak self] in self?.beginHold() }
        hotkey.onHoldEnd = { [weak self] in self?.endHold() }
        hotkey.start()
        engine.start(config: config) { [weak self] ok in
            guard let self else { return }
            if !ok {
                self.flowBar.setMode(.failed(self.engine.lastError ?? "Engine failed"))
            }
            self.refreshMenu()
            self.settings?.refreshStatus(engineReady: ok, engineError: self.engine.lastError)
        }
        setupDebugUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessTimer?.invalidate()
        hotkey.stop()
        recorder.stop()
        engine.stop()
        listenForEscape(false)
    }

    private func applyHotkey() {
        hotkey.hotkey = config.hotkey
    }

    private func restBar() {
        flowBar.restingMode = config.showBarAlways ? .idle : .hidden
        flowBar.setMode(flowBar.restingMode)
    }

    private func beginHold() {
        if recording { return }
        if busy {
            if flowBar.mode == .working {
                AppLog.line("hold ignored busy=working")
            } else {
                AppLog.line("hold ignored busy")
                flowBar.setMode(.failed("Still working"))
            }
            return
        }
        do {
            flowBar.resetLevels()
            recordStartedAt = Date()
            // The mic starts before anything else so the first syllables are
            // never clipped. Everything below is off the critical path.
            try recorder.start(deviceUID: config.microphoneUID.isEmpty ? nil : config.microphoneUID)
            recording = true
            flowBar.setMode(.listening)
            listenForEscape(true)
            playCue(.start)
            pasteTarget = PasteTarget.capture()
            resolveWeztermPane()
            MediaPause.pauseIfNeeded(enabled: config.autoPauseAudio)
        } catch {
            pasteTarget = nil
            flowBar.setMode(.failed(error.localizedDescription))
        }
    }

    private func resolveWeztermPane() {
        guard pasteTarget?.isWezTerm == true else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let pane = PasteService.focusedWeztermPane()
            DispatchQueue.main.async {
                guard let self, self.pasteTarget?.isWezTerm == true else { return }
                self.pasteTarget?.weztermPaneID = pane
            }
        }
    }

    private func endHold() {
        guard recording else { return }
        recording = false
        busy = true
        listenForEscape(false)
        playCue(.stop)
        recorder.releaseMic()
        MediaPause.resumeIfNeeded()
        let duration = Date().timeIntervalSince(recordStartedAt ?? Date())
        let target = pasteTarget
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.finalizeOutput()
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.pasteTarget = nil
                    AppLog.line("release save-failed")
                    self.flowBar.setMode(.failed("Couldn't save the recording"))
                }
                return
            }
            let url = self.recorder.fileURL
            let speech = self.recorder.containsSpeech
            let energy = self.recorder.heardEnergy
            AppLog.line("release speech=\(speech) energy=\(energy) url=\(url?.lastPathComponent ?? "-")")
            // If the wave moved, send the clip. The old VAD gate dropped
            // real speech after the bars had already reacted, then the bar
            // vanished with no loader and no text.
            guard let url, speech || energy else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.pasteTarget = nil
                    self.restBar()
                    if let url { try? FileManager.default.removeItem(at: url) }
                }
                return
            }
            DispatchQueue.main.sync {
                self.flowBar.setMode(.working)
            }
            do {
                let outcome = try self.transcribeWithRecovery(fileURL: url)
                DispatchQueue.main.async {
                    self.busy = false
                    self.pasteTarget = nil
                    switch outcome {
                    case .silence:
                        AppLog.line("release outcome=silence")
                        self.flowBar.setMode(.failed("Nothing heard"))
                    case .discardedNoise:
                        AppLog.line("release outcome=noise")
                        self.flowBar.setMode(.failed("Discarded as noise"))
                    case .text(let text):
                        self.lastTranscript = text
                        HistoryStore.shared.add(
                            text: text,
                            duration: duration,
                            language: self.config.language,
                            audioURL: url
                        )
                        // Show the check as soon as text is ready. Paste used
                        // to hold the spinner open, which made translation
                        // look slower every time WezTerm CLI stalled.
                        self.flowBar.setMode(.success)
                        PasteService.insert(
                            text,
                            into: target,
                            clipboard: self.config.clipboardBehavior
                        ) { outcome in
                            self.reportPaste(outcome)
                        }
                    }
                    self.refreshMenu()
                    // Deleted here, after HistoryStore has copied or moved
                    // the file, so history playback keeps its audio.
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.pasteTarget = nil
                    self.flowBar.setMode(.failed(Self.friendlyMessage(for: error)))
                    self.refreshMenu()
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // If transcription fails, the engine may have died. Bring it back and try
    // once more before surfacing the error.
    private func transcribeWithRecovery(fileURL: URL) throws -> TranscriptOutcome {
        do {
            return try Transcriber.transcribe(fileURL: fileURL, config: config)
        } catch {
            guard engine.ensureReady(config: config, timeout: 30) else { throw error }
            return try Transcriber.transcribe(fileURL: fileURL, config: config)
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .timedOut:
                return "Whisper engine is not responding"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func cancelHold() {
        recording = false
        busy = false
        pasteTarget = nil
        listenForEscape(false)
        MediaPause.resumeIfNeeded()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        restBar()
    }

    private func listenForEscape(_ on: Bool) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        guard on else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelHold() }
        }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelHold() }
            return event
        }
    }

    private func reportPaste(_ outcome: PasteService.PasteOutcome) {
        guard outcome == .failed else { return }
        AppLog.line("paste failed")
        flowBar.setMode(.failed("Paste didn't land. It's on the clipboard."))
    }

    private enum RecordCue {
        case start
        case stop
    }

    private static var cuePlayer: NSSound?

    private func playCue(_ cue: RecordCue) {
        guard config.playSounds else { return }
        let name = cue == .start ? "Tink" : "Pop"
        guard let sound = NSSound(named: name) else { return }
        sound.volume = cue == .start ? 0.28 : 0.22
        Self.cuePlayer = sound
        sound.play()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisperly")
            button.image?.isTemplate = true
        }
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = engine.isReady ? "Engine ready" : "Engine starting"
        let header = NSMenuItem(title: "Whisperly", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(withTitle: "Hold \(config.hotkey.title) to dictate", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        let trusted = PasteService.isTrusted()
        if trusted {
            menu.addItem(withTitle: "Accessibility is active", action: nil, keyEquivalent: "")
        } else {
            menu.addItem(NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccess), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Relaunch", action: #selector(relaunch), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Whisperly", action: #selector(openMain), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let paste = NSMenuItem(title: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "v")
        paste.isEnabled = !lastTranscript.isEmpty
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whisperly", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        if settings == nil {
            let controller = SettingsWindowController(
                config: config,
                engineReady: engine.isReady,
                engineError: engine.lastError
            )
            controller.onApply = { [weak self] next in
                self?.applySettings(next)
            }
            settings = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        settings?.refreshStatus(engineReady: engine.isReady, engineError: engine.lastError)
    }

    @objc private func openMain() {
        if mainWindow == nil {
            let window = MainWindowController(language: config.language)
            window.onOpenSettings = { [weak self] in self?.openSettings() }
            window.onLanguageChange = { [weak self] code in
                guard let self else { return }
                self.config.language = code
                self.config.save()
            }
            window.onUpload = { [weak self] url in self?.transcribeFile(url) }
            window.onPasteItem = { [weak self] item in
                guard let self else { return }
                PasteService.insert(item.text, clipboard: self.config.clipboardBehavior) { [weak self] outcome in
                    self?.reportPaste(outcome)
                }
            }
            mainWindow = window
        }
        mainWindow?.setLanguage(config.language)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func transcribeFile(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let outcome = try self.transcribeWithRecovery(fileURL: url)
                DispatchQueue.main.async {
                    switch outcome {
                    case .text(let text) where !text.isEmpty:
                        self.lastTranscript = text
                        HistoryStore.shared.add(text: text, duration: 0, language: self.config.language, audioURL: url)
                        self.refreshMenu()
                    case .discardedNoise:
                        self.flowBar.setMode(.failed("Discarded as noise"))
                    default:
                        self.flowBar.setMode(.failed("Nothing heard"))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.flowBar.setMode(.failed(Self.friendlyMessage(for: error)))
                }
            }
        }
    }

    private func applySettings(_ next: Config) {
        let restart = next.engineIdentity != config.engineIdentity
        config = next
        config.save()
        applyHotkey()
        applyAppearance()
        applyLoginItem()
        restBar()
        refreshMenu()
        mainWindow?.setLanguage(config.language)
        guard restart else { return }
        engine.stop()
        engine.start(config: config) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.restBar()
            } else {
                self.flowBar.setMode(.failed(self.engine.lastError ?? "Engine failed"))
            }
            self.refreshMenu()
            self.settings?.refreshStatus(engineReady: ok, engineError: self.engine.lastError)
        }
    }

    private func applyAppearance() {
        NSApp.setActivationPolicy(config.hideFromDock ? .accessory : .regular)
        NSApp.appearance = config.appearance.nsAppearance
    }

    private func applyLoginItem() {
        do {
            if config.startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {}
    }

    @objc private func pasteLast() {
        guard !lastTranscript.isEmpty else { return }
        PasteService.insert(lastTranscript, clipboard: config.clipboardBehavior) { [weak self] outcome in
            self?.reportPaste(outcome)
        }
    }

    @objc private func testPaste() {
        let target = PasteTarget.capture()
        PasteService.insert("whisperly-test", into: target, clipboard: .always) { [weak self] outcome in
            self?.refreshMenu()
            self?.reportPaste(outcome)
        }
    }

    @objc private func grantAccess() {
        PasteService.promptAccessibilityIfNeeded()
        PasteService.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Turn on Accessibility for Whisperly"
            alert.informativeText = "In Device Control and Data Access, enable Whisperly, then relaunch.\n\nIf the switch is already on and paste still fails, remove Whisperly, add ~/Applications/Whisperly.app again, turn it on, and relaunch. macOS sometimes keeps a stale code hash from an older build."
            alert.addButton(withTitle: "Relaunch now")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                self?.relaunch()
            }
        }
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", "sleep 0.4; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // Dev-only hook: WHISPERLY_UI=main|settings|flow|fail drives UI states
    // without a mic or a menu click, for screenshots and animation checks.
    private func setupDebugUI() {
        #if !DEBUG
        return
        #else
        switch ProcessInfo.processInfo.environment["WHISPERLY_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        switch ProcessInfo.processInfo.environment["WHISPERLY_UI"] {
        case "main":
            openMain()
        case "settings":
            openSettings()
        case "flow":
            startFlowDemo()
        case "fail":
            flowBar.setMode(.failed("Whisper engine is not responding"))
        default:
            break
        }
        #endif
    }

    #if DEBUG
    private func startFlowDemo() {
        var step = 0
        func advance() {
            switch step % 3 {
            case 0:
                flowBar.resetLevels()
                flowBar.setMode(.listening)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { advance() }
            case 1:
                flowBar.setMode(.working)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { advance() }
            default:
                flowBar.setMode(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { advance() }
            }
            step += 1
        }
        advance()
        var phase = 0.0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            phase += 1.0 / 30.0
            let samples = (0..<18).map { index -> CGFloat in
                let wave = sin(phase * 6.2 + Double(index) * 0.72) * 0.5 + 0.5
                let swell = 0.45 + 0.55 * abs(sin(phase * 2.1 + Double(index) * 0.2))
                return CGFloat(0.12 + 0.8 * wave * swell)
            }
            self.flowBar.pushWave(samples)
        }
    }
    #endif
}
