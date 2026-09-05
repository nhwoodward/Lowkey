import AppKit
import AVFoundation
import SwiftUI
import Combine
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    var onApply: ((Config) -> Void)?
    private let model: SettingsModel
    private var vocabularyEditor: ListEditorController?
    private var snippetEditor: ListEditorController?
    private let pages = ["General", "Dictation", "Privacy"]

    init(config: Config, engineReady: Bool, engineError: String?) {
        model = SettingsModel(config: config, engineReady: engineReady, engineError: engineError)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "General"
        window.minSize = NSSize(width: 540, height: 530)
        window.maxSize = NSSize(width: 900, height: 1000)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LowkeySettings")
        window.center()
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "LowkeySettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier("General")
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        model.onApply = { [weak self] next in self?.onApply?(next) }
        model.onVocabulary = { [weak self] in self?.openVocabulary() }
        model.onSnippets = { [weak self] in self?.openSnippets() }
        window.contentView = NSHostingView(rootView: NativeSettingsView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    func update(config: Config) { if model.config != config { model.config = config } }
    func refreshStatus(engineReady: Bool, engineError: String?) {
        model.engineReady = engineReady
        model.engineError = engineError
        model.refreshPermissions()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { pages.map { NSToolbarItem.Identifier($0) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        guard let index = pages.firstIndex(of: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = id.rawValue
        item.image = NSImage(systemSymbolName: ["gearshape", "waveform", "hand.raised"][index], accessibilityDescription: id.rawValue)
        item.target = self
        item.action = #selector(selectPage(_:))
        return item
    }

    @objc private func selectPage(_ sender: NSToolbarItem) {
        model.page = sender.itemIdentifier.rawValue
        window?.toolbar?.selectedItemIdentifier = sender.itemIdentifier
        window?.title = model.page
        model.refreshPermissions()
    }

    private func openVocabulary() {
        let editor = ListEditorController(mode: .vocabulary, onAdd: { left, right in
            if right.isEmpty { VocabularyStore.shared.addTerm(left) }
            else { VocabularyStore.shared.learn(wrong: left, right: right) }
        }, onDelete: { id in
            VocabularyStore.shared.removeFix(id: id)
            VocabularyStore.shared.removeTerm(id: id)
        })
        vocabularyEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        editor.focusInput()
    }

    private func openSnippets() {
        let editor = ListEditorController(mode: .snippets, onAdd: { SnippetStore.shared.add(trigger: $0, expansion: $1) },
                                          onDelete: { SnippetStore.shared.remove(id: $0) })
        snippetEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        editor.focusInput()
    }
}

@MainActor
private final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var page = "General"
    @Published var engineReady: Bool
    @Published var engineError: String?
    @Published var microphoneAllowed = false
    @Published var accessibilityAllowed = false
    @Published var devices: [AVCaptureDevice] = []
    var onApply: ((Config) -> Void)?
    var onVocabulary: (() -> Void)?
    var onSnippets: (() -> Void)?

    init(config: Config, engineReady: Bool, engineError: String?) {
        self.config = config
        self.engineReady = engineReady
        self.engineError = engineError
        refreshPermissions()
    }
    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = PasteService.isTrusted()
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }
    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
    func chooseModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Whisper model"
        panel.message = "Choose a whisper.cpp GGML model (.bin). Use a multilingual model for languages other than English."
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { config.modelPath = url.path }
    }
}

private struct NativeSettingsView: View {
    @ObservedObject var model: SettingsModel
    private let permissionRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            switch model.page {
            case "Dictation": dictation
            case "Privacy": privacy
            default: general
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.config) { _, next in model.onApply?(next) }
        .onReceive(permissionRefresh) { _ in
            if model.page == "Privacy" { model.refreshPermissions() }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("Show Lowkey in the Dock", isOn: Binding(get: { !model.config.hideFromDock }, set: { model.config.hideFromDock = !$0 }))
            Toggle("Open at login", isOn: $model.config.startAtLogin)
            Picker("Appearance", selection: $model.config.appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } header: { Text("Application") }
        Section {
            Toggle("Keep the floating bar visible", isOn: $model.config.showBarAlways)
            Toggle("Play recording sounds", isOn: $model.config.playSounds)
            Toggle("Pause media while recording", isOn: $model.config.autoPauseAudio)
        } header: { Text("Recording") } footer: {
            Text("Hold your shortcut to talk, then release to transcribe. Or click the microphone to start and the voice bar to finish. Press Escape to cancel.")
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        Section {
            LabeledContent("Lowkey", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.0")
            Label("Audio is transcribed on this Mac", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var dictation: some View {
        Section("Input") {
            Picker("Microphone", selection: $model.config.microphoneUID) {
                Text("System default").tag("")
                ForEach(model.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                if !model.config.microphoneUID.isEmpty && !model.devices.contains(where: { $0.uniqueID == model.config.microphoneUID }) {
                    Text("Selected microphone unavailable").tag(model.config.microphoneUID)
                }
            }
            Picker("Hold to talk", selection: $model.config.hotkey) {
                ForEach(DictationHotkey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Cancel recording", value: "Escape")
        }
        Section {
            Picker("Speech recognition", selection: $model.config.engine) {
                ForEach(TranscriptionEngineKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Language", selection: $model.config.language) {
                ForEach(Config.languages, id: \.0) { Text($0.1).tag($0.0) }
            }
            HStack {
                Text(model.engineReady ? "Ready to transcribe" : model.engineError ?? "Preparing speech recognition…")
                    .foregroundStyle(model.engineReady ? Color.secondary : Color.orange)
                Spacer()
            }
            HStack { Text("Whisper model"); Spacer(); Button("Choose…", action: model.chooseModel).accessibilityLabel("Choose Whisper model") }
            Text((model.config.modelPath as NSString).lastPathComponent)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } header: { Text("Transcription") } footer: {
            Text("Parakeet uses an English-only model on Apple silicon. Whisper provides fallback recognition. Auto detect and other languages require a multilingual Whisper model.")
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        Section("Text") {
            Picker("Punctuation", selection: $model.config.punctuationMode) {
                ForEach(PunctuationMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Keep text on clipboard", selection: $model.config.clipboardBehavior) {
                ForEach(ClipboardBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack { Text("Custom vocabulary"); Spacer(); Button("Edit…") { model.onVocabulary?() }.accessibilityLabel("Edit custom vocabulary") }
            HStack { Text("Spoken snippets"); Spacer(); Button("Edit…") { model.onSnippets?() }.accessibilityLabel("Edit spoken snippets") }
        }
    }

    @ViewBuilder private var privacy: some View {
        Section {
            permission("Microphone", symbol: "mic", allowed: model.microphoneAllowed, action: model.requestMicrophone)
            Text("Required to record your voice. Audio remains on your Mac.").font(.caption).foregroundStyle(.secondary)
            permission("Accessibility", symbol: "accessibility", allowed: model.accessibilityAllowed) {
                PasteService.promptAccessibilityIfNeeded()
                PasteService.openAccessibilitySettings()
            }
            Text("Required to insert text into other apps. You can still copy transcripts without this permission.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Permissions") }
        Section {
            Label("No account, analytics, or cloud transcription", systemImage: "lock.shield")
            Text("Lowkey stores up to 80 recent transcripts and their audio locally. Deleting an entry removes its saved recording, while imported originals remain untouched.")
                .foregroundStyle(.secondary)
            Button("Show Local Data in Finder") { NSWorkspace.shared.open(Config.supportDirectory) }
        } header: { Text("Local data") } footer: {
            Text("Speech models download when needed. Recordings are never uploaded for transcription.")
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permission(_ name: String, symbol: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: symbol)
            Spacer()
            Text(allowed ? "Allowed" : "Not allowed").foregroundStyle(allowed ? Color.secondary : Color.orange)
            Button(allowed ? "Manage…" : "Enable…", action: action)
                .accessibilityLabel(allowed ? "Manage \(name) access" : "Enable \(name) access")
        }
        .accessibilityElement(children: .contain)
    }
}
