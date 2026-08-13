import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onApply: ((Config) -> Void)?

    private var draft: Config
    private var page = 0
    private let content = FlippedStackView()
    private var navButtons: [InteractiveButton] = []
    private var engineReady = false
    private var engineError: String?
    private var vocabEditor: ListEditorController?
    private var snippetEditor: ListEditorController?

    init(config: Config, engineReady: Bool, engineError: String?) {
        self.draft = config
        self.engineReady = engineReady
        self.engineError = engineError
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.paper
        window.center()
        super.init(window: window)
        window.delegate = self
        let root = build()
        window.contentView = root
        showPage(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshStatus(engineReady: Bool, engineError: String?) {
        self.engineReady = engineReady
        self.engineError = engineError
        if page == 0 { showPage(0) }
    }

    func windowWillClose(_ notification: Notification) {
        collect()
        draft.save()
        onApply?(draft)
    }

    private func build() -> NSView {
        let root = NSView()
        let sidebar = ThemedFillView(fill: Theme.sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "SETTINGS")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.inkFaint
        label.translatesAutoresizingMaskIntoConstraints = false

        let general = InteractiveButton.nav("gearshape", "General", tag: 0, target: self, action: #selector(switchPage(_:)))
        let dictation = InteractiveButton.nav("mic.fill", "Dictation", tag: 1, target: self, action: #selector(switchPage(_:)))
        navButtons = [general, dictation]

        let rule = Hairline()

        sidebar.addSubview(label)
        sidebar.addSubview(general)
        sidebar.addSubview(dictation)
        sidebar.addSubview(rule)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false

        let scroller = NSScrollView()
        scroller.drawsBackground = false
        scroller.backgroundColor = Theme.paper
        scroller.contentView.drawsBackground = false
        scroller.borderType = .noBorder
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = true
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.documentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroller.contentView.widthAnchor),
        ])

        root.addSubview(sidebar)
        root.addSubview(scroller)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Theme.sidebarWidth),
            label.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 22),
            label.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            general.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Theme.space3),
            general.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            general.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            general.heightAnchor.constraint(equalToConstant: Theme.navHeight),
            dictation.topAnchor.constraint(equalTo: general.bottomAnchor, constant: 4),
            dictation.leadingAnchor.constraint(equalTo: general.leadingAnchor),
            dictation.trailingAnchor.constraint(equalTo: general.trailingAnchor),
            dictation.heightAnchor.constraint(equalToConstant: Theme.navHeight),
            rule.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            rule.topAnchor.constraint(equalTo: sidebar.topAnchor),
            rule.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            rule.widthAnchor.constraint(equalToConstant: 1),
            scroller.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroller.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroller.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc private func switchPage(_ sender: AnyObject) {
        collect()
        showPage((sender as? NSView)?.tag ?? 0)
    }

    private func showPage(_ index: Int) {
        page = index
        for button in navButtons {
            button.isSelected = button.tag == index
        }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 28, right: 16)
        if index == 0 {
            renderGeneral()
        } else {
            renderDictation()
        }
    }

    private func renderGeneral() {
        addHeading("General")
        addSection("FEATURES")
        addToggle("speaker.wave.2.fill", NSColor.systemBlue, "Dictation sound", "Play a sound when you start and stop recording", draft.playSounds, #selector(toggleSounds))
        addToggle("rectangle.bottomthird.inset.filled", NSColor.systemPurple, "Floating widget", "Show the Flow Bar when you are not dictating", draft.showBarAlways, #selector(toggleBar))
        addToggle("dock.rectangle", NSColor.systemGreen, "Hide from dock", "Keep Lowkey in the menu bar only", draft.hideFromDock, #selector(toggleDock))
        addSection("SYSTEM")
        addMenuRow("circle.lefthalf.filled", NSColor.systemIndigo, "Appearance", "Follow the Mac, or lock light or dark", AppAppearance.allCases.map(\.title), AppAppearance.allCases.firstIndex(of: draft.appearance) ?? 0, #selector(changeAppearance(_:)))
        addMicRow()
        addActionRow("viewfinder", NSColor.systemPink, "Permissions", "Manage microphone and Accessibility", "Configure", #selector(openPermissions))
        addInfoRow("info.circle.fill", NSColor.systemBlue, "Version", "Lowkey 1.0.0  ·  local Whisper")
        addToggle("power", NSColor.systemMint, "Start at Login", "Open Lowkey when you log in", draft.startAtLogin, #selector(toggleLogin))
        addStatus()
    }

    private func renderDictation() {
        addHeading("Dictation")
        addSection("CONFIGURATION")
        addMenuRow("globe", NSColor.systemBlue, "Dictation language", "Language used for transcription", Config.languages.map(\.1), selectedLanguageIndex(), #selector(changeLanguage(_:)))
        addActionRow("character.book.closed.fill", NSColor.systemPurple, "Custom Vocabulary", "Names and terms to keep, plus spelling fixes", "Configure", #selector(openVocabulary))
        addActionRow("textformat", NSColor.systemGreen, "Dictation Snippets", "Spoken shortcuts that expand into saved phrases", "Configure", #selector(openSnippets))
        addMenuRow("text.quote", NSColor.systemOrange, "Punctuation behaviour", "Let Lowkey keep punctuation in the transcript", PunctuationMode.allCases.map(\.title), PunctuationMode.allCases.firstIndex(of: draft.punctuationMode) ?? 0, #selector(changePunctuation(_:)))
        addMenuRow("doc.on.clipboard", NSColor.systemPink, "Clipboard behavior", "When to leave the transcript on the clipboard", ClipboardBehavior.allCases.map(\.title), ClipboardBehavior.allCases.firstIndex(of: draft.clipboardBehavior) ?? 1, #selector(changeClipboard(_:)))
        addSection("SOUND")
        addToggle("speaker.slash.fill", NSColor.systemBlue, "Auto-Pause Audio", "Pause Music or Spotify while you dictate", draft.autoPauseAudio, #selector(togglePause))
        addSection("SHORTCUTS")
        addMenuRow("keyboard", NSColor.systemPurple, "Start/Stop dictation", "Hold this key to record", DictationHotkey.allCases.map(\.title), DictationHotkey.allCases.firstIndex(of: draft.hotkey) ?? 0, #selector(changeHotkey(_:)))
        addInfoRow("xmark", NSColor.systemMint, "Cancel Recording", "Press Esc to discard the current recording")
    }

    private func addHeading(_ title: String) {
        let field = NSTextField(labelWithString: title)
        field.font = Theme.display(21, weight: .bold)
        field.textColor = Theme.ink
        field.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(field)
        content.setCustomSpacing(16, after: field)
    }

    private func addSection(_ title: String) {
        if let last = content.arrangedSubviews.last {
            content.setCustomSpacing(20, after: last)
        }
        let field = NSTextField(labelWithString: title)
        field.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        field.textColor = Theme.inkFaint
        content.addArrangedSubview(field)
        content.setCustomSpacing(6, after: field)
    }

    private func addToggle(_ symbol: String, _ color: NSColor, _ title: String, _ caption: String, _ on: Bool, _ action: Selector) {
        let control = styledSwitch()
        control.state = on ? .on : .off
        control.target = self
        control.action = action
        control.setAccessibilityLabel(title)
        let row = SettingsRow(symbol: symbol, color: color, title: title, caption: caption, accessory: control)
        row.isInteractive = true
        row.onActivate = { [weak control] in
            guard let control else { return }
            control.state = control.state == .on ? .off : .on
            if let action = control.action {
                _ = control.sendAction(action, to: control.target)
            }
        }
        pin(row)
    }

    private func addMenuRow(_ symbol: String, _ color: NSColor, _ title: String, _ caption: String, _ items: [String], _ selected: Int, _ action: Selector) {
        let pop = styledPopup()
        items.forEach { pop.addItem(withTitle: $0) }
        pop.selectItem(at: selected)
        pop.target = self
        pop.action = action
        pop.setAccessibilityLabel(title)
        let row = SettingsRow(symbol: symbol, color: color, title: title, caption: caption, accessory: pop)
        row.isInteractive = true
        row.onActivate = { [weak pop] in
            pop?.performClick(nil)
        }
        pin(row)
    }

    private func addActionRow(_ symbol: String, _ color: NSColor, _ title: String, _ caption: String, _ buttonTitle: String, _ action: Selector) {
        let button = InteractiveButton.pill(buttonTitle, target: self, action: action)
        let row = SettingsRow(symbol: symbol, color: color, title: title, caption: caption, accessory: button)
        row.isInteractive = true
        row.onActivate = { [weak button] in
            button?.performClick(nil)
        }
        pin(row)
    }

    private func addInfoRow(_ symbol: String, _ color: NSColor, _ title: String, _ caption: String) {
        let row = SettingsRow(symbol: symbol, color: color, title: title, caption: caption, accessory: nil)
        row.isInteractive = false
        pin(row)
    }

    private func addMicRow() {
        let pop = styledPopup()
        pop.addItem(withTitle: "Auto (Default)")
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
        var selected = 0
        for (index, device) in devices.enumerated() {
            pop.addItem(withTitle: device.localizedName)
            if device.uniqueID == draft.microphoneUID { selected = index + 1 }
        }
        pop.selectItem(at: selected)
        pop.target = self
        pop.action = #selector(changeMic(_:))
        pop.identifier = NSUserInterfaceItemIdentifier(devices.map(\.uniqueID).joined(separator: "\u{1e}"))
        pop.setAccessibilityLabel("Microphone")
        let row = SettingsRow(symbol: "mic.fill", color: .systemOrange, title: "Microphone", caption: "Choose the microphone Lowkey should use", accessory: pop)
        row.isInteractive = true
        row.onActivate = { [weak pop] in
            pop?.performClick(nil)
        }
        pin(row)
    }

    private func addStatus() {
        if let last = content.arrangedSubviews.last {
            content.setCustomSpacing(16, after: last)
        }
        let text = engineReady
            ? "Engine ready on \(draft.bindHost):\(draft.bindPort)"
            : (engineError ?? "Engine is not running")
        let access = PasteService.isTrusted() ? "Accessibility is active." : "Accessibility still needs a grant."
        let field = NSTextField(wrappingLabelWithString: "\(text)  \(access)")
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = engineReady ? Theme.inkMuted : .systemOrange
        content.addArrangedSubview(field)
    }

    private func pin(_ row: NSView) {
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -content.edgeInsets.left - content.edgeInsets.right).isActive = true
    }

    private func selectedLanguageIndex() -> Int {
        Config.languages.firstIndex(where: { $0.0 == draft.language }) ?? 0
    }

    private func collect() {}

    @objc private func toggleSounds(_ sender: NSSwitch) { draft.playSounds = sender.state == .on; save() }
    @objc private func toggleBar(_ sender: NSSwitch) { draft.showBarAlways = sender.state == .on; save() }
    @objc private func toggleDock(_ sender: NSSwitch) { draft.hideFromDock = sender.state == .on; save() }
    @objc private func toggleLogin(_ sender: NSSwitch) { draft.startAtLogin = sender.state == .on; save() }
    @objc private func togglePause(_ sender: NSSwitch) { draft.autoPauseAudio = sender.state == .on; save() }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        draft.language = Config.languages[max(0, sender.indexOfSelectedItem)].0
        save()
    }

    @objc private func changePunctuation(_ sender: NSPopUpButton) {
        draft.punctuationMode = PunctuationMode.allCases[max(0, sender.indexOfSelectedItem)]
        save()
    }

    @objc private func changeClipboard(_ sender: NSPopUpButton) {
        draft.clipboardBehavior = ClipboardBehavior.allCases[max(0, sender.indexOfSelectedItem)]
        save()
    }

    @objc private func changeHotkey(_ sender: NSPopUpButton) {
        draft.hotkey = DictationHotkey.allCases[max(0, sender.indexOfSelectedItem)]
        save()
    }

    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        draft.appearance = AppAppearance.allCases[max(0, sender.indexOfSelectedItem)]
        save()
    }

    @objc private func changeMic(_ sender: NSPopUpButton) {
        let ids = (sender.identifier?.rawValue ?? "").split(separator: "\u{1e}").map(String.init)
        let index = sender.indexOfSelectedItem
        draft.microphoneUID = index <= 0 ? "" : ids[safe: index - 1] ?? ""
        save()
    }

    @objc private func openPermissions() {
        PasteService.promptAccessibilityIfNeeded()
        PasteService.openAccessibilitySettings()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openVocabulary() {
        let editor = ListEditorController(mode: .vocabulary, onAdd: { left, right in
            if right.isEmpty {
                VocabularyStore.shared.addTerm(left)
            } else {
                VocabularyStore.shared.learn(wrong: left, right: right)
            }
        }, onDelete: { id in
            VocabularyStore.shared.removeFix(id: id)
            VocabularyStore.shared.removeTerm(id: id)
        })
        vocabEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focusInput()
    }

    @objc private func openSnippets() {
        let editor = ListEditorController(mode: .snippets, onAdd: { left, right in
            SnippetStore.shared.add(trigger: left, expansion: right)
        }, onDelete: { id in
            SnippetStore.shared.remove(id: id)
        })
        snippetEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        editor.focusInput()
    }

    private func save() {
        draft.save()
        onApply?(draft)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
