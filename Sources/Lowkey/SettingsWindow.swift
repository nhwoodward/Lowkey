import AppKit
import AVFoundation
import Combine
import SwiftUI

private enum SettingsPage: String, CaseIterable {
    case general = "General"
    case dictation = "Dictation"
    case vocabulary = "Vocabulary"
    case privacy = "Privacy"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "waveform"
        case .vocabulary: return "character.book.closed"
        case .privacy: return "hand.raised"
        }
    }
}

final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    var onApply: ((Config) -> Void)?
    private let model: SettingsModel
    private let content: SettingsContentController
    private var permissionTimer: Timer?

    init(config: Config, status: EngineStatus) {
        model = SettingsModel(config: config, status: status)
        content = SettingsContentController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsContentController.width, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "LowkeySettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.delegate = self
        window.contentViewController = content
        model.onApply = { [weak self] next in self?.onApply?(next) }
        #if DEBUG
        model.applyDemo()
        if ProcessInfo.processInfo.environment["LOWKEY_SETTINGS_DEMO"]?.contains("cycle") == true {
            Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let pages = SettingsPage.allCases
                    self.select(page: pages[((pages.firstIndex(of: self.model.page) ?? 0) + 1) % pages.count].rawValue)
                }
            }
        }
        #endif
        select(page: SettingsPage.general.rawValue)
        content.fitWindow(animated: false)
        window.center()
        window.setFrameAutosaveName("LowkeySettings")
        content.fitWindow(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    func update(config: Config) { model.sync(config) }

    func refreshStatus(_ status: EngineStatus) {
        model.setStatus(status)
        model.refreshPermissions()
        model.refreshDevices()
    }

    func select(page: String) {
        guard let page = SettingsPage(rawValue: page) else { return }
        model.page = page
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(page.rawValue)
        window?.title = page.rawValue
        model.refreshPermissions()
        updatePermissionPolling()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        updatePermissionPolling()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
        updatePermissionPolling()
    }

    func windowWillClose(_ notification: Notification) {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // Access is granted in System Settings, so poll only while the Privacy page is on screen.
    private func updatePermissionPolling() {
        let polling = model.page == .privacy && window?.isVisible == true
        if polling, permissionTimer == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(pollPermissions), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        } else if !polling {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    @objc private func pollPermissions() { model.refreshPermissions() }

    @objc private func selectPage(_ sender: NSToolbarItem) { select(page: sender.itemIdentifier.rawValue) }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let page = SettingsPage(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.rawValue
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.rawValue)
        item.target = self
        item.action = #selector(selectPage(_:))
        return item
    }
}

// Hosts the SwiftUI pages and gives the window each page's height, keeping the
// top edge in place and animating like the system Settings windows.
private final class SettingsContentController: NSViewController {
    static let width: CGFloat = 520
    private let model: SettingsModel
    private let hosting: NSHostingController<SettingsView>
    private var modelChanges: AnyCancellable?
    private var sampler: Timer?
    private var samplingUntil: CFTimeInterval = 0
    private var sampledHeight: CGFloat = 0

    init(model: SettingsModel) {
        self.model = model
        hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        super.init(nibName: nil, bundle: nil)
        modelChanges = model.objectWillChange.sink { [weak self] _ in self?.watchHeight() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        addChild(hosting)
        // Top-anchored at the height fitWindow sets, so the window animates around
        // still content and AppKit's own preferred-size constraints never jump it.
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .minYMargin]
        view.addSubview(hosting.view)
    }

    // Every page, engine, and status change goes through the model, and SwiftUI
    // settles the new ideal height over the next few frames without telling
    // AppKit, so sample it briefly and fit to each value it settles on.
    func watchHeight() {
        samplingUntil = CACurrentMediaTime() + 0.5
        guard sampler == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(sampleHeight), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    @objc private func sampleHeight() {
        let height = hosting.preferredContentSize.height
        if height != sampledHeight {
            sampledHeight = height
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fitAnimated), object: nil)
            perform(#selector(fitAnimated), with: nil, afterDelay: 0.03, inModes: [.common])
        }
        if CACurrentMediaTime() > samplingUntil {
            sampler?.invalidate()
            sampler = nil
        }
    }

    @objc private func fitAnimated() { fitWindow(animated: true) }

    func fitWindow(animated: Bool) {
        guard let window = view.window else { return }
        view.layoutSubtreeIfNeeded()
        let ideal = hosting.preferredContentSize.height
        guard ideal > 0 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: ideal))
        // Window frames are whole points; a fractional target would never match and refit forever.
        frame.size.height = ceil(frame.height)
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        // A page taller than the screen scrolls instead of running off it.
        var scrolls = false
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            if frame.height > screen.height {
                frame.size.height = screen.height
                scrolls = true
            }
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        if model.scrolls != scrolls { model.scrolls = scrolls }
        let height = window.contentRect(forFrameRect: frame).height
        if abs(hosting.view.frame.height - height) >= 0.5 {
            hosting.view.frame = NSRect(x: 0, y: view.bounds.height - height, width: Self.width, height: height)
        }
        guard abs(frame.height - window.frame.height) >= 1 || abs(frame.minY - window.frame.minY) >= 1 else { return }
        if animated && window.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = window.animationResizeTime(frame)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var config: Config {
        didSet { if config != oldValue && !syncing { onApply?(config) } }
    }
    @Published var page = SettingsPage.general
    @Published var scrolls = false
    @Published var confirmingClear = false
    @Published private(set) var status: EngineStatus
    @Published private(set) var microphoneAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var historyCount = HistoryStore.shared.items.count
    var onApply: ((Config) -> Void)?
    private var syncing = false
    private var historyObserver: UUID?
    private var deviceObservers: [NSObjectProtocol] = []

    init(config: Config, status: EngineStatus) {
        self.config = config
        self.status = status
        refreshPermissions()
        refreshDevices()
        historyObserver = HistoryStore.shared.observe { [weak self] in
            self?.historyCount = HistoryStore.shared.items.count
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    deinit {
        if let historyObserver { HistoryStore.shared.stopObserving(historyObserver) }
        for observer in deviceObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // External changes arrive here and must not echo back through onApply.
    func sync(_ next: Config) {
        guard next != config else { return }
        syncing = true
        config = next
        syncing = false
    }

    func setStatus(_ next: EngineStatus) {
        #if DEBUG
        if demoStatus != nil { return }
        #endif
        if status != next { status = next }
    }

    var showInDock: Bool {
        get { !config.hideFromDock }
        set { config.hideFromDock = !newValue }
    }

    var engine: TranscriptionEngineKind {
        get { config.engine }
        set {
            var next = config
            next.engine = newValue
            // Parakeet is English only, so never leave an invalid pair behind.
            if newValue == .parakeet { next.language = "en" }
            config = next
        }
    }

    func refreshPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = PasteService.isTrusted()
        if microphone != microphoneAllowed { microphoneAllowed = microphone }
        if accessibility != accessibilityAllowed { accessibilityAllowed = accessibility }
    }

    func refreshDevices() {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if found.map(\.uniqueID) != devices.map(\.uniqueID) { devices = found }
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAccessibility() {
        PasteService.promptAccessibilityIfNeeded()
        PasteService.openAccessibilitySettings()
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Whisper model"
        panel.message = "Choose a whisper.cpp GGML model (.bin). Use a multilingual model for languages other than English."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: config.modelPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { config.modelPath = url.path }
    }

    func clearHistory() { HistoryStore.shared.clearAll() }

    #if DEBUG
    private var demoStatus: EngineStatus?

    // Dev-only: LOWKEY_SETTINGS_DEMO=whisper,fn,command,preparing,downloading,failed,ready,clear,cycle
    // stages Settings states for screenshots without saving config or touching the engine.
    func applyDemo() {
        guard let raw = ProcessInfo.processInfo.environment["LOWKEY_SETTINGS_DEMO"] else { return }
        let flags = Set(raw.split(separator: ",").map(String.init))
        var next = config
        if flags.contains("whisper") { next.engine = .whisper }
        if flags.contains("fn") { next.hotkey = .function }
        if flags.contains("command") { next.hotkey = .rightCommand }
        sync(next)
        confirmingClear = flags.contains("clear")
        if flags.contains("preparing") { demoStatus = .preparing }
        if flags.contains("downloading") { demoStatus = .downloading }
        if flags.contains("ready") { demoStatus = .ready }
        if flags.contains("failed") {
            demoStatus = .failed("Whisper model not found at /Users/example/Library/Application Support/Lowkey/models/ggml-small.en-q5_1.bin")
        }
        if let demoStatus { status = demoStatus }
    }
    #endif
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch model.page {
            case .general: GeneralSettings(model: model)
            case .dictation: DictationSettings(model: model)
            case .vocabulary: VocabularySettings()
            case .privacy: PrivacySettings(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(!model.scrolls)
        .frame(width: SettingsContentController.width)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: SettingsModel
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $model.config.startAtLogin)
                Toggle("Show Lowkey in the Dock", isOn: $model.showInDock)
            }
            Section {
                Toggle("Play sounds", isOn: $model.config.playSounds)
                Toggle("Show microphone button when idle", isOn: $model.config.showBarAlways)
                Toggle("Pause music while dictating", isOn: $model.config.autoPauseAudio)
            } header: {
                Text("Feedback")
            } footer: {
                Text(["Lowkey", version].compactMap { $0 }.joined(separator: " "))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
    }
}

private struct DictationSettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Hold to talk", selection: $model.config.hotkey) {
                    ForEach(DictationHotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.config.hotkey == .function {
                    HStack(spacing: 12) {
                        Text("Set “Press \(Image(systemName: "globe")) key to” to “Do Nothing” in Keyboard settings so Fn only starts dictation.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Keyboard Settings…", action: model.openKeyboardSettings)
                    }
                }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold to talk and release to insert. Double-tap to keep listening hands-free, then press again to finish. Press Esc to cancel.")
            }

            Section {
                Picker("Input device", selection: $model.config.microphoneUID) {
                    Text("System Default").tag("")
                    if !model.devices.isEmpty { Divider() }
                    ForEach(model.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    if !model.config.microphoneUID.isEmpty && !model.devices.contains(where: { $0.uniqueID == model.config.microphoneUID }) {
                        Text("Unavailable Microphone").tag(model.config.microphoneUID)
                    }
                }
            } header: {
                Text("Microphone")
            }

            Section {
                Picker("Speech recognition", selection: $model.engine) {
                    engineOption("Parakeet", detail: "Fastest. English only. Runs on the Neural Engine.")
                        .tag(TranscriptionEngineKind.parakeet)
                    engineOption("Whisper", detail: "Multilingual. Runs on the GPU.")
                        .tag(TranscriptionEngineKind.whisper)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // An old config can pair Parakeet with another language; show the picker so it can be fixed.
                if model.config.engine == .whisper || model.config.language != "en" {
                    Picker("Language", selection: $model.config.language) {
                        ForEach(Config.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                if model.config.engine == .whisper {
                    LabeledContent("Model") {
                        HStack(spacing: 8) {
                            Text((model.config.modelPath as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .help(model.config.modelPath)
                            Button("Choose…", action: model.chooseModel)
                                .accessibilityLabel("Choose Whisper model")
                        }
                    }
                }
                EngineStatusRow(status: model.status)
            } header: {
                Text("Recognition")
            } footer: {
                Text("Only the selected engine is kept in memory.")
            }

            Section {
                Picker("Punctuation", selection: $model.config.punctuationMode) {
                    Text("Automatic").tag(PunctuationMode.automatic)
                    Text("Off").tag(PunctuationMode.none)
                }
                Picker("Copy to clipboard", selection: $model.config.clipboardBehavior) {
                    Text("Always").tag(ClipboardBehavior.always)
                    Text("Only if paste fails").tag(ClipboardBehavior.ifPasteFails)
                    Text("Never").tag(ClipboardBehavior.never)
                }
            } header: {
                Text("Text")
            } footer: {
                Text("Lowkey pastes into the app you are using. The clipboard keeps a copy when you choose.")
            }
        }
    }

    private func engineOption(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct EngineStatusRow: View {
    let status: EngineStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch status {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready")
            case .preparing:
                spinner
                Text("Loading speech model…")
            case .downloading:
                spinner
                Text("Downloading speech model (about 500 MB, one time)…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

private struct PrivacySettings: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                PermissionRow(symbol: "mic", title: "Microphone", detail: "Records your voice while you dictate.",
                              allowed: model.microphoneAllowed, action: model.requestMicrophone)
                PermissionRow(symbol: "accessibility", title: "Accessibility", detail: "Detects your shortcut and pastes into the app you are using.",
                              allowed: model.accessibilityAllowed, action: model.requestAccessibility)
            } header: {
                Text("Permissions")
            }

            Section {
                Text("Lowkey keeps your last 80 dictations and their audio on this Mac.")
                HStack(spacing: 8) {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.open(Config.supportDirectory) }
                    Button("Clear History…", role: .destructive) { model.confirmingClear = true }
                        .disabled(model.historyCount == 0)
                }
            } header: {
                Text("History")
            } footer: {
                Text("Audio and text never leave this Mac. Speech models download once from Hugging Face.")
            }
        }
        .alert("Clear all dictation history?", isPresented: $model.confirmingClear) {
            Button("Clear History", role: .destructive, action: model.clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.historyCount == 1
                ? "This deletes 1 transcript and its recording. This can’t be undone."
                : "This deletes \(model.historyCount) transcripts and their recordings. This can’t be undone.")
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let allowed: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if allowed {
                Label {
                    Text("Allowed").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Button("Allow…", action: action)
                    .accessibilityLabel("Allow \(title) access")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
