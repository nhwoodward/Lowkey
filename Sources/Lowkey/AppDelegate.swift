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
    private var setup: SetupWindowController?
    private var statusItem: NSStatusItem?
    private var recordStartedAt: Date?
    private var recordClock: Timer?
    private var shownRemaining: Int?
    private var busy = false
    private var recording = false
    private var capture = CaptureMode.hold
    private var revealed = false
    private var revealWork: DispatchWorkItem?
    private var tapWork: DispatchWorkItem?
    private var blockedWork: DispatchWorkItem?
    private var ignoreNextRelease = false
    private var keyMonitors: [Any] = []
    private var pasteTarget: PasteTarget?
    private var demoTimer: Timer?
    private let transcriptionQueue = DispatchQueue(label: "app.lowkey.transcription", qos: .userInitiated)
    private var recordingConfig: Config?
    private var needsEngineRestart = false
    private var engineGeneration = 0
    private var engineSwitching = false
    private var lastExternalTarget: PasteTarget?
    private var activationObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var wasTrusted = PasteService.isTrusted()

    // How the current recording ends.
    private enum CaptureMode {
        case hold       // releasing the shortcut finishes
        case tap        // released quickly; a second press within the window locks hands-free
        case handsFree  // the shortcut, a bar click, or the length limit finishes
    }

    private static let maxRecordSeconds: TimeInterval = 120
    private static let countdownSeconds: TimeInterval = 10
    // The mic starts on press, but the bar and cue wait this long so that a
    // shortcut such as Right Command-C never flashes dictation UI.
    private static let revealDelay: TimeInterval = 0.15
    private static let tapThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.35
    private static let setupDismissedKey = "setupDismissed"

    func applicationDidFinishLaunching(_ notification: Notification) {
        captureExternalTarget()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastExternalTarget = PasteTarget(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier ?? "", localizedName: app.localizedName ?? "")
        }
        applyDockVisibility()
        applyLoginItem()
        buildApplicationMenu()
        buildStatusItem()
        #if DEBUG
        try? String(getpid()).write(to: Config.supportDirectory.appendingPathComponent("app.pid"), atomically: true, encoding: .utf8)
        #endif
        applyHotkey()
        restBar()
        flowBar.onIdleTap = { [weak self] in self?.startFromBar() }
        flowBar.onStop = { [weak self] in self?.finishRecording() }
        recorder.onWave = { [weak self] samples in
            self?.flowBar.pushWave(samples)
        }
        hotkey.onHoldStart = { [weak self] in self?.hotkeyPressed() }
        hotkey.onHoldEnd = { [weak self] in self?.hotkeyReleased() }
        hotkey.start()
        ParakeetEngine.shared.onStatusChange = { [weak self] in self?.refreshMenu() }
        startSelectedEngine()
        if !permissionsGranted && !UserDefaults.standard.bool(forKey: Self.setupDismissedKey) {
            openSetup()
        }
        setupDebugUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRecordingClock()
        hotkey.stop()
        recorder.releaseMic()
        MediaPause.resumeIfNeeded()
        engineGeneration += 1
        engine.stop()
        ParakeetEngine.shared.unload()
        watchKeys(false)
    }

    private func applyHotkey() {
        hotkey.hotkey = config.hotkey
    }

    private var engineStatus: EngineStatus {
        if let error = config.selectedEngineError { return .failed(error.localizedDescription) }
        let parakeet = config.engine == .parakeet
        if engineSwitching {
            return parakeet && ParakeetEngine.shared.downloading ? .downloading : .preparing
        }
        if parakeet ? ParakeetEngine.shared.ready : engine.isReady { return .ready }
        return (parakeet ? ParakeetEngine.shared.lastError : engine.lastError).map(EngineStatus.failed) ?? .preparing
    }

    private var microphoneAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private var permissionsGranted: Bool { microphoneAllowed && PasteService.isTrusted() }

    private func startSelectedEngine() {
        let snapshot = config
        engineGeneration += 1
        let ticket = engineGeneration
        engineSwitching = true
        AppLog.line("engine selected=\(snapshot.engine.rawValue) language=\(snapshot.language)")
        refreshMenu()
        let finished: (Bool) -> Void = { [weak self] ok in
            guard let self, self.engineGeneration == ticket else { return }
            self.engineSwitching = false
            if !ok && !self.recording && !self.busy, case .failed(let message) = self.engineStatus {
                self.flowBar.setMode(.failed(message)) { [weak self] in self?.showSettings(page: "Dictation") }
            }
            self.refreshMenu()
        }
        if snapshot.engine == .parakeet {
            engine.stop { [weak self] in
                guard let self, self.engineGeneration == ticket else { return }
                if snapshot.selectedEngineError != nil {
                    ParakeetEngine.shared.unload { finished(false) }
                } else {
                    ParakeetEngine.shared.start(completion: finished)
                }
            }
        } else {
            ParakeetEngine.shared.unload { [weak self] in
                guard let self, self.engineGeneration == ticket else { return }
                self.engine.start(config: snapshot.whisperConfig, completion: finished)
            }
        }
    }

    private func finishOperation() {
        busy = false
        pasteTarget = nil
        applyHotkey()
        if needsEngineRestart {
            needsEngineRestart = false
            startSelectedEngine()
        }
        refreshMenu()
    }

    private func restBar() {
        flowBar.restingMode = config.showBarAlways ? .idle : .hidden
        flowBar.setMode(flowBar.restingMode)
    }

    // MARK: - Recording

    private func hotkeyPressed() {
        if recording {
            switch capture {
            case .hold: break
            case .tap: lockHandsFree()
            case .handsFree:
                ignoreNextRelease = true
                finishRecording()
            }
            return
        }
        ignoreNextRelease = false
        watchKeys(true)
        if let blocked = startBlocker() {
            // Explain only once the press is clearly not part of a shortcut.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hotkey.isHolding, !self.recording else { return }
                blocked()
            }
            blockedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)
            return
        }
        beginRecording(.hold)
    }

    private func hotkeyReleased() {
        blockedWork?.cancel()
        blockedWork = nil
        if !recording { watchKeys(false) }
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard recording, capture == .hold else { return }
        if Date().timeIntervalSince(recordStartedAt ?? .distantPast) >= Self.tapThreshold {
            finishRecording()
            return
        }
        // A quick tap is either the first half of a double-tap or nothing.
        capture = .tap
        revealWork?.cancel()
        revealWork = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.recording, self.capture == .tap else { return }
            AppLog.line("hold tap discarded")
            self.cancelRecording()
        }
        tapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
    }

    private func startFromBar() {
        guard !recording else { return }
        if let blocked = startBlocker() {
            blocked()
            return
        }
        beginRecording(.handsFree)
    }

    private func lockHandsFree() {
        tapWork?.cancel()
        tapWork = nil
        capture = .handsFree
        ignoreNextRelease = true
        AppLog.line("hands-free on")
        if revealed {
            flowBar.setListeningAccessory(handsFree: true, remaining: shownRemaining)
        } else {
            reveal()
        }
    }

    // Why dictation cannot start right now, as the feedback that explains it.
    // Importing a file needs the engine but not the microphone.
    private func startBlocker(needsMicrophone: Bool = true) -> (() -> Void)? {
        if busy {
            return { [weak self] in
                guard let self else { return }
                if self.flowBar.mode == .working {
                    AppLog.line("hold ignored busy=working")
                    self.flowBar.nudge()
                } else {
                    AppLog.line("hold ignored busy")
                    self.flowBar.setMode(.notice("Finishing the last dictation", symbol: "hourglass"))
                }
            }
        }
        switch needsMicrophone ? AVCaptureDevice.authorizationStatus(for: .audio) : .authorized {
        case .authorized:
            break
        case .notDetermined:
            return { [weak self] in
                self?.requestMicrophone()
                self?.flowBar.setMode(.notice("Allow microphone access, then try again", symbol: "mic"))
            }
        default:
            return { [weak self] in
                self?.flowBar.setMode(.failed("Microphone access is off")) { Self.openPrivacyPane("Privacy_Microphone") }
            }
        }
        if let error = config.selectedEngineError {
            return { [weak self] in
                self?.flowBar.setMode(.failed(error.localizedDescription)) { [weak self] in self?.showSettings(page: "Dictation") }
            }
        }
        guard engineStatus != .ready else { return nil }
        return { [weak self] in
            guard let self else { return }
            if !self.engineSwitching { self.startSelectedEngine() }
            switch self.engineStatus {
            case .downloading:
                self.flowBar.setMode(.notice("Downloading speech model…", symbol: "arrow.down.circle")) { [weak self] in self?.openSetup() }
            case .failed(let message):
                self.flowBar.setMode(.failed(message)) { [weak self] in self?.showSettings(page: "Dictation") }
            case .preparing, .ready:
                self.flowBar.setMode(.notice("Loading speech model…", symbol: "hourglass"))
            }
        }
    }

    private func beginRecording(_ mode: CaptureMode) {
        guard !recording else { return }
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
            capture = mode
            revealed = false
            shownRemaining = nil
            watchKeys(true)
            startRecordingClock()
            if mode == .hold {
                let work = DispatchWorkItem { [weak self] in self?.reveal() }
                revealWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay, execute: work)
            } else {
                reveal()
            }
        } catch {
            pasteTarget = nil
            watchKeys(false)
            flowBar.setMode(.failed(error.localizedDescription))
        }
    }

    private func reveal() {
        revealWork?.cancel()
        revealWork = nil
        guard recording, !revealed else { return }
        revealed = true
        AppLog.line("dictation shown mode=\(capture)")
        flowBar.setMode(.listening)
        flowBar.setListeningAccessory(handsFree: capture == .handsFree, remaining: shownRemaining)
        mainWindow?.setBusy(true)
        playCue(.start)
        MediaPause.pauseIfNeeded(enabled: config.autoPauseAudio)
        resolveWeztermPane()
        // Heat the transcription path while the user is still speaking.
        Transcriber.warmUp(config: config)
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

    private func finishRecording() {
        guard recording else { return }
        // Nothing was shown, so nothing is expected: treat it as a tap.
        guard revealed else {
            cancelRecording()
            return
        }
        recording = false
        busy = true
        tapWork?.cancel()
        tapWork = nil
        stopRecordingClock()
        // Acknowledge release before microphone teardown and WAV/VAD work.
        flowBar.setMode(.working)
        watchKeys(false)
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
            do {
                let outcome = try self.transcribeWithRecovery(fileURL: url, config: snapshot)
                DispatchQueue.main.async {
                    switch outcome {
                    case .silence:
                        AppLog.line("release outcome=silence")
                        self.flowBar.setMode(.notice("Nothing heard", symbol: "waveform.slash"))
                    case .discardedNoise:
                        AppLog.line("release outcome=noise")
                        self.flowBar.setMode(.notice("Nothing heard", symbol: "waveform.slash"))
                    case .text(let text):
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

    // Recovery is limited to the selected engine. An error must never load
    // a second model behind the user's selection.
    private func transcribeWithRecovery(fileURL: URL, config: Config) throws -> TranscriptOutcome {
        if let error = config.selectedEngineError { throw error }
        if config.engine == .parakeet {
            return try Transcriber.transcribe(fileURL: fileURL, config: config)
        }
        let selected = config.whisperConfig
        guard engine.ensureReady(config: selected, timeout: 30) else {
            throw TranscriberError.server(engine.lastError ?? "Whisper is unavailable. Check Dictation settings.")
        }
        return try Transcriber.transcribe(fileURL: fileURL, config: selected)
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

    private func cancelRecording() {
        blockedWork?.cancel()
        blockedWork = nil
        guard recording else {
            if !busy { restBar() }
            return
        }
        AppLog.line("dictation cancelled mode=\(capture) shown=\(revealed)")
        recording = false
        busy = false
        pasteTarget = nil
        revealWork?.cancel()
        revealWork = nil
        tapWork?.cancel()
        tapWork = nil
        stopRecordingClock()
        watchKeys(false)
        MediaPause.resumeIfNeeded()
        if let url = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        restBar()
        finishOperation()
    }

    // Escape cancels. Any other key or a click while the shortcut is held
    // means it was a chord such as Right Command-C, so the take is dropped.
    private func watchKeys(_ on: Bool) {
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
        guard on else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            _ = self?.handleKey(event)
        }) {
            keyMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            // Clicking the bar is how a recording finishes, not a chord.
            if event.type != .keyDown, event.window is NSPanel { return event }
            return self?.handleKey(event) == true ? nil : event
        }) {
            keyMonitors.append(monitor)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
            guard recording else { return false }
            cancelRecording()
            return true
        }
        guard hotkey.isHolding else { return false }
        if !recording {
            blockedWork?.cancel()
            blockedWork = nil
        } else if capture == .hold {
            AppLog.line("hold chord discarded")
            cancelRecording()
        }
        return false
    }

    private func startRecordingClock() {
        stopRecordingClock()
        let started = recordStartedAt ?? Date()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.recording else { return }
            let left = Self.maxRecordSeconds - Date().timeIntervalSince(started)
            if left <= 0 {
                self.finishRecording()
                return
            }
            let remaining = left <= Self.countdownSeconds ? Int(left.rounded(.up)) : nil
            guard remaining != self.shownRemaining else { return }
            self.shownRemaining = remaining
            if self.revealed {
                self.flowBar.setListeningAccessory(handsFree: self.capture == .handsFree, remaining: remaining)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordClock = timer
    }

    private func stopRecordingClock() {
        recordClock?.invalidate()
        recordClock = nil
        shownRemaining = nil
    }

    private func reportPaste(_ outcome: PasteService.PasteOutcome) {
        guard outcome == .failed else { return }
        AppLog.line("paste failed")
        if config.clipboardBehavior == .never {
            flowBar.setMode(.failed("Couldn't paste. Your text is in History")) { [weak self] in self?.openMain() }
        } else if !PasteService.isTrusted() {
            flowBar.setMode(.notice("Copied. Allow Accessibility to paste", symbol: "doc.on.clipboard")) { [weak self] in self?.openSetup() }
        } else {
            flowBar.setMode(.notice("Copied. Press ⌘V to paste", symbol: "doc.on.clipboard"))
        }
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

    // MARK: - Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        mainWindow?.setBusy(busy || recording)
        let status = engineStatus
        settings?.refreshStatus(status)
        setup?.refresh(status: status)
        if !permissionsGranted { watchPermissions() }
        guard let item = statusItem, let menu = item.menu else { return }

        let attention = !permissionsGranted || { if case .failed = status { return true }; return false }()
        if let button = item.button {
            let symbol = attention ? "waveform.badge.exclamationmark" : "waveform"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lowkey")
                ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Lowkey")
            button.image?.isTemplate = true
            button.appearsDisabled = status == .preparing || status == .downloading
            button.toolTip = "Lowkey: \(status == .ready ? "Ready" : status.summary)"
        }

        menu.removeAllItems()
        let line = status == .ready ? "Hold \(config.hotkey.title) to dictate" : status.summary
        let statusLine = NSMenuItem(title: line, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if !permissionsGranted {
            menu.addItem(NSMenuItem(title: "Finish Setup…", action: #selector(openSetup), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let paste = NSMenuItem(title: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "")
        paste.isEnabled = !HistoryStore.shared.items.isEmpty && !busy && !recording
        menu.addItem(paste)
        menu.addItem(NSMenuItem(title: "History", action: #selector(openMain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Lowkey", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
    }

    // Key monitors installed before Accessibility is granted never receive
    // events, so the shortcut restarts as soon as trust arrives.
    private func watchPermissions() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let trusted = PasteService.isTrusted()
            if trusted != self.wasTrusted {
                self.wasTrusted = trusted
                if trusted {
                    AppLog.line("accessibility granted; restarting shortcut monitor")
                    self.hotkey.start()
                }
            }
            if self.permissionsGranted {
                timer.invalidate()
                self.permissionTimer = nil
            }
            self.refreshMenu()
        }
    }

    // MARK: - Windows

    @objc private func openSettings() {
        showSettings(page: nil)
    }

    private func showSettings(page: String?) {
        captureExternalTarget()
        if settings == nil {
            let controller = SettingsWindowController(config: config, status: engineStatus)
            controller.onApply = { [weak self] next in
                self?.applySettings(next)
            }
            settings = controller
        }
        if let page { settings?.select(page: page) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        settings?.refreshStatus(engineStatus)
    }

    @objc private func openMain() {
        captureExternalTarget()
        if mainWindow == nil {
            let window = MainWindowController(hotkeyTitle: config.hotkey.title)
            window.onOpenSettings = { [weak self] in self?.openSettings() }
            window.pasteTargetName = { [weak self] in
                self?.lastExternalTarget?.localizedName.nilIfEmpty
            }
            window.onUpload = { [weak self] url in self?.transcribeFile(url) }
            window.onPasteItem = { [weak self] item in
                guard let self else { return }
                self.pasteHistoryText(item.text)
            }
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSetup() {
        captureExternalTarget()
        if setup == nil {
            let controller = SetupWindowController(hotkeyTitle: config.hotkey.title, status: engineStatus)
            controller.onDone = {
                UserDefaults.standard.set(true, forKey: Self.setupDismissedKey)
            }
            setup = controller
        }
        setup?.refresh(status: engineStatus)
        NSApp.activate(ignoringOtherApps: true)
        setup?.showWindow(nil)
        setup?.window?.makeKeyAndOrderFront(nil)
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func transcribeFile(_ url: URL) {
        guard !busy, !recording else { flowBar.nudge(); return }
        if let blocked = startBlocker(needsMicrophone: false) {
            blocked()
            return
        }
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
                        HistoryStore.shared.add(text: text, duration: audio.duration, language: snapshot.language, audioURL: audio.url)
                        self.flowBar.setMode(.success)
                    case .discardedNoise, .silence:
                        self.flowBar.setMode(.notice("No speech found in this file", symbol: "waveform.slash"))
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
        applyDockVisibility()
        applyLoginItem()
        flowBar.restingMode = config.showBarAlways ? .idle : .hidden
        if !recording && !busy { restBar() }
        settings?.update(config: config)
        mainWindow?.setHotkeyTitle(config.hotkey.title)
        setup?.setHotkeyTitle(config.hotkey.title)
        if restart {
            if recording || busy { needsEngineRestart = true }
            else { startSelectedEngine() }
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
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(.separator())
        let history = windows.addItem(withTitle: "History", action: #selector(openMain), keyEquivalent: "")
        history.target = self
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(config.hideFromDock ? .accessory : .regular)
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
        guard let text = HistoryStore.shared.items.first?.text else { return }
        captureExternalTarget()
        pasteHistoryText(text)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func requestMicrophone() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshMenu() }
        }
    }

    // Dev-only hook: LOWKEY_UI=main|settings|settings:<Page>|setup|flow|flow-audit|fail
    // drives UI states without a mic or a menu click, for screenshots and animation checks.
    private func setupDebugUI() {
        #if !DEBUG
        return
        #else
        DebugSnapshot.startIfRequested()
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
        case let ui? where ui.hasPrefix("settings:"):
            showSettings(page: String(ui.dropFirst("settings:".count)))
        case "setup":
            openSetup()
        case "flow":
            startFlowDemo()
        case "flow-audit":
            startFlowAudit()
        case "gesture-audit":
            startGestureAudit()
        case "fail":
            flowBar.setMode(.failed("Whisper engine is not responding"))
        default:
            break
        }
        #endif
    }

    #if DEBUG
    // Drives the real shortcut handler, recorder and bar through each gesture.
    // It records the room, so it never pastes what it hears.
    private func startGestureAudit() {
        setenv("LOWKEY_NO_PASTE", "1", 1)
        let down: NSEvent.ModifierFlags
        switch config.hotkey {
        case .rightCommand: down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        case .leftCommand: down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
        case .rightOption: down = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        case .function: down = .function
        }
        let code = config.hotkey.keyCode
        func key(_ character: String, _ keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: down, timestamp: 0, windowNumber: 0,
                             context: nil, characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: keyCode)!
        }
        let steps: [(TimeInterval, String, () -> Void)] = [
            (4.0, "hold: press", { self.hotkey.handle(keyCode: code, flags: down) }),
            (5.2, "hold: release after 1.2 s", { self.hotkey.handle(keyCode: code, flags: []) }),
            (10.0, "chord: press", { self.hotkey.handle(keyCode: code, flags: down) }),
            (10.08, "chord: C key", { _ = self.handleKey(key("c", 8)) }),
            (10.3, "chord: release", { self.hotkey.handle(keyCode: code, flags: []) }),
            (12.0, "tap: press", { self.hotkey.handle(keyCode: code, flags: down) }),
            (12.1, "tap: release", { self.hotkey.handle(keyCode: code, flags: []) }),
            (14.0, "double-tap: press", { self.hotkey.handle(keyCode: code, flags: down) }),
            (14.1, "double-tap: release", { self.hotkey.handle(keyCode: code, flags: []) }),
            (14.25, "double-tap: press again", { self.hotkey.handle(keyCode: code, flags: down) }),
            (14.35, "double-tap: release again", { self.hotkey.handle(keyCode: code, flags: []) }),
            (17.0, "hands-free: press to finish", { self.hotkey.handle(keyCode: code, flags: down) }),
            (17.1, "hands-free: release", { self.hotkey.handle(keyCode: code, flags: []) }),
            (22.0, "escape: double-tap", { self.hotkey.handle(keyCode: code, flags: down) }),
            (22.1, "escape: release", { self.hotkey.handle(keyCode: code, flags: []) }),
            (22.2, "escape: press again", { self.hotkey.handle(keyCode: code, flags: down) }),
            (22.3, "escape: release again", { self.hotkey.handle(keyCode: code, flags: []) }),
            (23.5, "escape: Esc key", { _ = self.handleKey(key("\u{1b}", 53)) }),
        ]
        for (time, label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) {
                action()
                AppLog.line("audit \(label): recording=\(self.recording) mode=\(self.capture) shown=\(self.revealed) busy=\(self.busy) bar=\(self.flowBar.mode)")
            }
        }
    }

    private func startFlowAudit() {
        // Exercise real panel layout without forcing permission or engine failures.
        let states: [(FlowBarMode, Bool, Int?)] = [
            (.listening, false, nil), (.listening, true, nil), (.listening, true, 7), (.working, false, nil), (.success, false, nil),
            (.notice("Nothing heard", symbol: "waveform.slash"), false, nil),
            (.notice("Copied. Press ⌘V to paste", symbol: "doc.on.clipboard"), false, nil),
            (.notice("Copied. Allow Accessibility to paste", symbol: "doc.on.clipboard"), false, nil),
            (.notice("Downloading speech model…", symbol: "arrow.down.circle"), false, nil),
            (.notice("Allow microphone access, then try again", symbol: "mic"), false, nil),
            (.failed("Microphone access is off"), false, nil),
            (.failed("Couldn't save the recording"), false, nil),
            (.failed("Whisper engine is not responding"), false, nil),
            (.failed("Whisper model not found at\n/Users/example/" + String(repeating: "Long model folder/", count: 12)), false, nil),
        ]
        var step = 0
        func advance() {
            let (state, handsFree, remaining) = states[step % states.count]
            flowBar.setMode(state)
            if state == .listening {
                flowBar.setListeningAccessory(handsFree: handsFree, remaining: remaining)
                flowBar.pushWave((0..<18).map { CGFloat(($0 % 6) + 1) / 7 })
            }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
