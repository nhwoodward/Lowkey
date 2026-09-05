import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let engine = Engine()
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private let flowBar = FlowBarController()
    private var settings: SettingsWindowController?
    private var mainWindow: MainWindowController?
    private var statusItem: NSStatusItem?
    private var recordStartedAt: Date?
    private var recordLimitWork: DispatchWorkItem?
    private var busy = false
    private var recording = false
    private var lastTranscript = ""
    private var escapeMonitor: Any?
    private var localEscapeMonitor: Any?
    private var pasteTarget: PasteTarget?
    private var demoTimer: Timer?
    private let transcriptionQueue = DispatchQueue(label: "app.lowkey.transcription", qos: .userInitiated)
    private var recordingConfig: Config?
    private var widgetRecording = false
    private var needsEngineRestart = false
    private var lastExternalTarget: PasteTarget?
    private var activationObserver: NSObjectProtocol?


    private static let maxRecordSeconds: TimeInterval = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureExternalTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastExternalTarget = PasteTarget(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier ?? "", localizedName: app.localizedName ?? "")
        }
        applyAppearance()
        applyLoginItem()
        buildApplicationMenu()
        buildStatusItem()
        #if DEBUG
        try? String(getpid()).write(to: Config.supportDirectory.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        #endif
        applyHotkey()
        restBar()
        flowBar.onIdleTap = { [weak self] in
            self?.widgetRecording = true
            self?.beginHold()
        }
        flowBar.onStop = { [weak self] in self?.endHold() }
        recorder.onWave = { [weak self] samples in
            self?.flowBar.pushWave(samples)
        }
        hotkey.onHoldStart = { [weak self] in
            guard let self, !self.recording else { return }
            self.widgetRecording = false
            self.beginHold()
        }
        hotkey.onHoldEnd = { [weak self] in
            guard let self, !self.widgetRecording else { return }
            self.endHold()
        }
        hotkey.start()
        startEngines()
        setupDebugUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recordLimitWork?.cancel()
        hotkey.stop()
        recorder.releaseMic()
        MediaPause.resumeIfNeeded()
        engine.stop()
        listenForEscape(false)
    }

    private func applyHotkey() {
        hotkey.hotkey = config.hotkey
    }

    private var activeEngineReady: Bool {
        (config.prefersParakeet && ParakeetEngine.shared.ready) || engine.isReady
    }

    private func startEngines() {
        let snapshot = config
        let identity = snapshot.engineIdentity
        if !snapshot.prefersParakeet || !ParakeetEngine.shared.ready {
            engine.start(config: snapshot.whisperConfig) { [weak self] ok in
                guard let self, self.config.engineIdentity == identity else { return }
                if !ok && !self.activeEngineReady && !self.recording && !self.busy {
                    self.flowBar.setMode(.failed(self.engine.lastError ?? "Speech recognition could not start"))
                }
                self.refreshMenu()
            }
        }
        guard snapshot.prefersParakeet else { return }
        ParakeetEngine.shared.start { [weak self] ok in
            guard let self, self.config.engineIdentity == identity else { return }
            if ok {
                // Wait for any in-flight Whisper inference before retiring it.
                self.transcriptionQueue.async {
                    DispatchQueue.main.async {
                        guard self.config.engineIdentity == identity, self.config.prefersParakeet else { return }
                        self.engine.retire()
                    }
                }
            }
            self.refreshMenu()
        }
    }

    private func finishOperation() {
        busy = false
        pasteTarget = nil
        applyHotkey()
        if needsEngineRestart {
            needsEngineRestart = false
            startEngines()
        }
        refreshMenu()
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
                flowBar.nudge()
            } else {
                AppLog.line("hold ignored busy")
                flowBar.setMode(.failed("Still working"))
            }
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestMicrophone()
            flowBar.setMode(.failed("Enable Microphone in Settings > Privacy, then try again."))
            return
        }
        do {
            recordingConfig = config
            let focused = PasteTarget.capture()
            pasteTarget = focused.pid == getpid() ? lastExternalTarget : focused
            flowBar.resetLevels()
            recordStartedAt = Date()
            // The mic starts before anything else so the first syllables are
            // never clipped. Everything below is off the critical path.
            try recorder.start(deviceUID: config.microphoneUID.isEmpty ? nil : config.microphoneUID)
            recording = true
            mainWindow?.setBusy(true)
            flowBar.setMode(.listening)
            listenForEscape(true)
            scheduleRecordLimit()
            playCue(.start)
            resolveWeztermPane()
            MediaPause.pauseIfNeeded(enabled: config.autoPauseAudio)
            // Heat the transcription path while the user is still speaking.
            Transcriber.warmUp(config: config)
        } catch {
            pasteTarget = nil
            flowBar.setMode(.failed(error.localizedDescription))
        }
    }

    private func resolveWeztermPane() {
        guard pasteTarget?.isWezTerm == true else { return }
        let started = recordStartedAt
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = PasteService.focusedWeztermPaneInfo()
            DispatchQueue.main.async {
                guard let self, self.recording, self.recordStartedAt == started, self.pasteTarget?.isWezTerm == true else { return }
                self.pasteTarget?.weztermPaneID = info?.id
                self.pasteTarget?.weztermSocket = info?.socket
            }
        }
    }

    private func endHold() {
        guard recording else { return }
        recording = false
        busy = true
        listenForEscape(false)
        recordLimitWork?.cancel()
        recordLimitWork = nil
        playCue(.stop)
        recorder.releaseMic()
        MediaPause.resumeIfNeeded()
        let duration = Date().timeIntervalSince(recordStartedAt ?? Date())
        let target = pasteTarget
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
           let target, target.pid != getpid() {
            NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
        }
        let snapshot = recordingConfig ?? config
        widgetRecording = false
        transcriptionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.recorder.finalizeOutput()
            } catch {
                DispatchQueue.main.async {
                    self.finishOperation()
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
                    self.finishOperation()
                    self.restBar()
                    if let url { try? FileManager.default.removeItem(at: url) }
                }
                return
            }
            DispatchQueue.main.sync {
                self.flowBar.setMode(.working)
            }
            do {
                let outcome = try self.transcribeWithRecovery(fileURL: url, config: snapshot)
                DispatchQueue.main.async {
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
                            language: snapshot.language,
                            audioURL: url
                        )
                        // Show the check as soon as text is ready. Paste used
                        // to hold the spinner open, which made translation
                        // look slower every time WezTerm CLI stalled.
                        self.flowBar.setMode(.success)
                        PasteService.insert(
                            text,
                            into: target,
                            clipboard: snapshot.clipboardBehavior
                        ) { outcome in
                            self.reportPaste(outcome)
                            self.finishOperation()
                        }
                    }
                    if case .text = outcome {} else { self.finishOperation() }
                    self.refreshMenu()
                    // Deleted here, after HistoryStore has copied
                    // the file, so history playback keeps its audio.
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                DispatchQueue.main.async {
                    self.finishOperation()
                    self.flowBar.setMode(.failed(Self.friendlyMessage(for: error)))
                    self.refreshMenu()
                    AppLog.line("recording retained after transcription failure: \(url.lastPathComponent)")
                }
            }
        }
    }

    // If transcription fails, the engine may have died. Bring it back and try
    // once more before surfacing the error.
    private func transcribeWithRecovery(fileURL: URL, config: Config) throws -> TranscriptOutcome {
        let fallback = config.whisperConfig
        if config.prefersParakeet && ParakeetEngine.shared.ready {
            do { return try Transcriber.transcribe(fileURL: fileURL, config: config) }
            catch { AppLog.line("primary transcription failed; recovering Whisper") }
        }
        guard engine.ensureReady(config: fallback, timeout: 30) else {
            throw TranscriberError.server(engine.lastError ?? "Whisper is unavailable. Check Dictation settings.")
        }
        return try Transcriber.transcribe(fileURL: fileURL, config: fallback)
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
        guard recording else {
            if !busy { restBar() }
            return
        }
        recording = false
        widgetRecording = false
        busy = false
        pasteTarget = nil
        listenForEscape(false)
        recordLimitWork?.cancel()
        recordLimitWork = nil
        MediaPause.resumeIfNeeded()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        restBar()
        finishOperation()
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
            if event.keyCode == 53 {
                self?.cancelHold()
                return nil
            }
            return event
        }
    }

    private func scheduleRecordLimit() {
        recordLimitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endHold()
        }
        recordLimitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecordSeconds, execute: work)
    }

    private func reportPaste(_ outcome: PasteService.PasteOutcome) {
        guard outcome == .failed else { return }
        AppLog.line("paste failed")
        let message = config.clipboardBehavior == .never
            ? "Paste couldn't finish. Your text is saved in History."
            : "Paste couldn't finish. Your text is on the clipboard."
        flowBar.setMode(.failed(message))
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
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Lowkey")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        mainWindow?.setBusy(busy || recording)
        let status = activeEngineReady ? "Ready to dictate" : "Preparing speech recognition…"
        settings?.refreshStatus(engineReady: activeEngineReady, engineError: engine.lastError)
        let header = NSMenuItem(title: "Lowkey", action: nil, keyEquivalent: "")
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
        menu.addItem(NSMenuItem(title: "Open Lowkey", action: #selector(openMain), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let paste = NSMenuItem(title: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "")
        paste.isEnabled = !lastTranscript.isEmpty
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lowkey", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }

    @objc private func openSettings() {
        captureExternalTarget()
        if settings == nil {
            let controller = SettingsWindowController(
                config: config,
                engineReady: activeEngineReady,
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
        settings?.refreshStatus(engineReady: activeEngineReady, engineError: engine.lastError)
    }

    @objc private func openMain() {
        captureExternalTarget()
        if mainWindow == nil {
            let window = MainWindowController(language: config.language)
            window.onOpenSettings = { [weak self] in self?.openSettings() }
            window.onLanguageChange = { [weak self] code in
                guard let self else { return }
                var next = self.config
                next.language = code
                self.applySettings(next)
            }
            window.onUpload = { [weak self] url in self?.transcribeFile(url) }
            window.onPasteItem = { [weak self] item in
                guard let self else { return }
                self.pasteHistoryText(item.text)
            }
            mainWindow = window
        }
        mainWindow?.setLanguage(config.language)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func transcribeFile(_ url: URL) {
        guard !busy, !recording else { flowBar.nudge(); return }
        busy = true
        mainWindow?.setBusy(true)
        let snapshot = config
        flowBar.setMode(.working)
        transcriptionQueue.async { [weak self] in
            guard let self else { return }
            var prepared: ImportedAudio?
            do {
                let audio = try ImportedAudio.prepare(url)
                prepared = audio
                let outcome = try self.transcribeWithRecovery(fileURL: audio.url, config: snapshot)
                DispatchQueue.main.async {
                    switch outcome {
                    case .text(let text):
                        self.lastTranscript = text
                        HistoryStore.shared.add(text: text, duration: audio.duration, language: snapshot.language, audioURL: audio.url)
                        self.flowBar.setMode(.success)
                    case .discardedNoise: self.flowBar.setMode(.failed("Discarded as noise"))
                    case .silence: self.flowBar.setMode(.failed("Nothing heard"))
                    }
                    try? FileManager.default.removeItem(at: audio.url)
                    self.finishOperation()
                }
            } catch {
                if let prepared { try? FileManager.default.removeItem(at: prepared.url) }
                DispatchQueue.main.async {
                    self.flowBar.setMode(.failed(Self.friendlyMessage(for: error)))
                    self.finishOperation()
                }
            }
        }
    }

    private func applySettings(_ next: Config) {
        guard next != config else { return }
        let restart = next.engineIdentity != config.engineIdentity
        config = next
        config.save()
        if !recording { applyHotkey() }
        applyAppearance()
        applyLoginItem()
        flowBar.restingMode = config.showBarAlways ? .idle : .hidden
        if !recording && !busy { restBar() }
        settings?.update(config: config)
        mainWindow?.setLanguage(config.language)
        if restart {
            if recording || busy { needsEngineRestart = true }
            else { startEngines() }
        }
        refreshMenu()
    }

    private func captureExternalTarget() {
        let target = PasteTarget.capture()
        if target.pid != getpid(), target.pid > 0 { lastExternalTarget = target }
    }

    private func pasteHistoryText(_ text: String) {
        guard !busy, !recording else { return }
        busy = true
        if let target = lastExternalTarget, let app = NSRunningApplication(processIdentifier: target.pid) {
            app.activate(options: [])
        }
        PasteService.insert(text, into: lastExternalTarget, clipboard: config.clipboardBehavior) { [weak self] outcome in
            self?.reportPaste(outcome)
            self?.finishOperation()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openMain()
        return true
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Lowkey")
        appMenu.addItem(withTitle: "About Lowkey", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Lowkey", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Lowkey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Window")
        let open = windows.addItem(withTitle: "Dictation History", action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func applyAppearance() {
        NSApp.setActivationPolicy(config.hideFromDock ? .accessory : .regular)
        NSApp.appearance = config.appearance.nsAppearance
    }

    private func applyLoginItem() {
        let service = SMAppService.mainApp
        do {
            if config.startAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            AppLog.line("login item error=\(error.localizedDescription)")
        }
    }

    @objc private func pasteLast() {
        guard !lastTranscript.isEmpty else { return }
        captureExternalTarget()
        pasteHistoryText(lastTranscript)
    }

    @objc private func grantAccess() {
        PasteService.promptAccessibilityIfNeeded()
        PasteService.openAccessibilitySettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Turn on Accessibility for Lowkey"
            alert.informativeText = "In Device Control and Data Access, enable Lowkey, then relaunch.\n\nIf the switch is already on and paste still fails, remove Lowkey, add ~/Applications/Lowkey.app again, turn it on, and relaunch. macOS sometimes keeps a stale code hash from an older build."
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
        task.arguments = ["-c", "sleep 0.4; /usr/bin/open \"$1\"", "relaunch", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshMenu() }
            }
        } else { openSettings() }
    }

    // Dev-only hook: LOWKEY_UI=main|settings|flow|flow-audit|fail drives UI states
    // without a mic or a menu click, for screenshots and animation checks.
    private func setupDebugUI() {
        #if !DEBUG
        return
        #else
        switch ProcessInfo.processInfo.environment["LOWKEY_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        switch ProcessInfo.processInfo.environment["LOWKEY_UI"] {
        case "main":
            openMain()
        case "settings":
            openSettings()
        case "flow":
            startFlowDemo()
        case "flow-audit":
            startFlowAudit()
        case "fail":
            flowBar.setMode(.failed("Whisper engine is not responding"))
        default:
            break
        }
        #endif
    }

    #if DEBUG
    private func startFlowAudit() {
        // Exercise real panel layout without forcing permission or engine failures.
        let states: [FlowBarMode] = [
            .listening, .working, .success,
            .failed("Nothing heard"), .failed("Discarded as noise"),
            .failed("Still working"), .failed("Couldn't save the recording"),
            .failed("Whisper engine is not responding"),
            .failed("Enable Microphone in Settings > Privacy, then try again."),
            .failed("Paste couldn't finish. Your text is on the clipboard."),
            .failed("Whisper model not found at\n/Users/example/" + String(repeating: "Long model folder/", count: 12)),
        ]
        var step = 0
        func advance() {
            let state = states[step % states.count]
            flowBar.setMode(state)
            if state == .listening { flowBar.pushWave((0..<18).map { CGFloat(($0 % 6) + 1) / 7 }) }
            if state == .working {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.flowBar.nudge() }
            }
            step += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { advance() }
        }
        advance()
    }

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
