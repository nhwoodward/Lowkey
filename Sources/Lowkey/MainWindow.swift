import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class MainWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, AVAudioPlayerDelegate, NSToolbarDelegate {
    var onOpenSettings: (() -> Void)?
    var onLanguageChange: ((String) -> Void)?
    var onUpload: ((URL) -> Void)?
    var onPasteItem: ((HistoryItem) -> Void)?

    private var language = "en"
    private let table = HistoryTable()
    private let emptyLabel = NSTextField(labelWithString: "No transcriptions yet. Hold your shortcut to dictate.")
    private let languageButton = styledPopup()
    private var player: AVAudioPlayer?
    private var playingID: UUID?
    private var dictationItem: InteractiveButton?
    private var historyObserver: UUID?

    init(language: String) {
        self.language = language
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dictation History"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 420)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.center()
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("LowkeyHistory")
        let toolbar = NSToolbar(identifier: "LowkeyHistoryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        let root = build()
        window.contentView = root
        reload()
        historyObserver = HistoryStore.shared.observe { [weak self] in self?.reload() }
    }

    deinit {
        if let historyObserver {
            HistoryStore.shared.stopObserving(historyObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setLanguage(_ code: String) {
        language = code
        if let index = Config.languages.firstIndex(where: { $0.0 == code }) {
            languageButton.selectItem(at: index)
        }
    }

    func setBusy(_ busy: Bool) {
        window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "import" })?.isEnabled = !busy
    }

    private func build() -> NSView {
        let root = NSView()
        let heading = NSTextField(labelWithString: "Your words, on this Mac.")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let caption = NSTextField(labelWithString: "Hold your shortcut to dictate, or import an audio recording.")
        caption.font = .systemFont(ofSize: 13)
        caption.textColor = .secondaryLabelColor
        let intro = NSStackView(views: [heading, caption])
        intro.orientation = .vertical
        intro.alignment = .leading
        intro.spacing = 6
        intro.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")))
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 100
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(showSelectedTranscript)
        table.onDelete = { [weak self] in self?.deleteSelected() }
        table.onCopy = { [weak self] in self?.copySelected() }
        table.onPaste = { [weak self] in self?.pasteSelected() }
        table.onPlay = { [weak self] in self?.playSelected() }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.tableColumns.first?.resizingMask = .autoresizingMask
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.stringValue = "No transcriptions yet. Start with your voice."
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(intro)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            intro.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 22),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        return root
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["import", "vocabulary", "language", "settings"].map { NSToolbarItem.Identifier($0) } + [.flexibleSpace]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("import"), NSToolbarItem.Identifier("vocabulary"), .flexibleSpace,
         NSToolbarItem.Identifier("language"), NSToolbarItem.Identifier("settings")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "language" {
            Config.languages.forEach { languageButton.addItem(withTitle: $0.1) }
            setLanguage(language)
            languageButton.target = self
            languageButton.action = #selector(changeLanguage)
            languageButton.setAccessibilityLabel("Dictation language")
            item.view = languageButton
            item.label = "Language"
            return item
        }
        let symbol: String
        switch id.rawValue {
        case "import": item.label = "Import Audio"; symbol = "square.and.arrow.down"; item.action = #selector(uploadNote)
        case "vocabulary": item.label = "Vocabulary"; symbol = "character.book.closed"; item.action = #selector(addVocabulary)
        case "settings": item.label = "Settings"; symbol = "gearshape"; item.action = #selector(openSettings)
        default: return nil
        }
        item.autovalidates = false
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)
        item.toolTip = item.label
        item.target = self
        return item
    }

    @objc private func showSelectedTranscript() {
        guard let item = selectedItem(), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Transcription"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        let text = NSTextView(frame: scroll.bounds)
        text.string = item.text
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 14)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { self.copy(item) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        HistoryStore.shared.items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = HistoryStore.shared.items[row]
        let view = HistoryRowView(item: item, playing: playingID == item.id, target: self)
        view.isSelected = tableView.selectedRow == row
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        TransparentRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        syncSelection()
    }

    func windowDidResize(_ notification: Notification) {
        table.sizeLastColumnToFit()
    }

    func reload() {
        let selectedID = selectedItem()?.id
        table.reloadData()
        table.sizeLastColumnToFit()
        emptyLabel.isHidden = !HistoryStore.shared.items.isEmpty
        if let selectedID, let index = HistoryStore.shared.items.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        syncSelection()
    }

    private func syncSelection() {
        for index in 0..<table.numberOfRows {
            if let row = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? HistoryRowView {
                row.isSelected = index == table.selectedRow
            }
        }
    }

    private func selectedItem() -> HistoryItem? {
        let row = table.selectedRow
        guard row >= 0, row < HistoryStore.shared.items.count else { return nil }
        return HistoryStore.shared.items[row]
    }

    @objc private func selectDictation() {
        dictationItem?.isSelected = true
        window?.makeFirstResponder(table)
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func changeLanguage() {
        let index = max(0, languageButton.indexOfSelectedItem)
        language = Config.languages[index].0
        onLanguageChange?(language)
    }

    @objc private func addVocabulary() {
        VocabularySheet.present(from: window, seed: nil)
    }

    @objc private func uploadNote() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.title = "Import Audio"
        panel.message = "Transcribe up to two minutes of audio locally. Your original file stays where it is."
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            onUpload?(url)
        }
    }

    @objc func copyItem(_ sender: AnyObject) {
        guard let item = item(from: sender) else { return }
        copy(item)
        (sender as? InteractiveButton)?.flashSuccess()
    }

    @objc func pasteItem(_ sender: AnyObject) {
        guard let item = item(from: sender) else { return }
        onPasteItem?(item)
    }

    @objc func playItem(_ sender: AnyObject) {
        guard let item = item(from: sender) else { return }
        togglePlay(item)
    }

    @objc func vocabItem(_ sender: AnyObject) {
        guard let item = item(from: sender) else { return }
        VocabularySheet.present(from: window, seed: item.text)
    }

    @objc func deleteItem(_ sender: AnyObject) {
        guard let id = viewID(sender), let uuid = UUID(uuidString: id) else { return }
        if playingID == uuid {
            player?.stop()
            playingID = nil
        }
        HistoryStore.shared.delete(id: uuid)
    }

    @objc private func copySelected() {
        guard let item = selectedItem() else { return }
        copy(item)
    }

    @objc private func pasteSelected() {
        guard let item = selectedItem() else { return }
        onPasteItem?(item)
    }

    @objc private func playSelected() {
        guard let item = selectedItem() else { return }
        togglePlay(item)
    }

    private func deleteSelected() {
        guard let item = selectedItem() else { return }
        if playingID == item.id {
            player?.stop()
            playingID = nil
        }
        HistoryStore.shared.delete(id: item.id)
    }

    private func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    private func togglePlay(_ item: HistoryItem) {
        guard let url = item.audioURL else { return }
        if playingID == item.id, player?.isPlaying == true {
            player?.stop()
            playingID = nil
            reload()
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            playingID = player?.play() == true ? item.id : nil
        } catch {
            playingID = nil
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) }
        }
        reload()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingID = nil
        reload()
    }

    private func item(from sender: AnyObject) -> HistoryItem? {
        guard let id = viewID(sender) else { return nil }
        return HistoryStore.shared.items.first(where: { $0.id.uuidString == id })
    }

    private func viewID(_ sender: AnyObject) -> String? {
        (sender as? NSView)?.identifier?.rawValue
    }
}

final class HistoryTable: NSTableView {
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onPlay: (() -> Void)?
    private var trackingButton: InteractiveButton?

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let button = interactiveButton(at: local) {
            trackingButton = button
            button.mouseDown(with: event)
            return
        }
        trackingButton = nil
        super.mouseDown(with: event)
    }

    private func interactiveButton(at point: NSPoint) -> InteractiveButton? {
        func search(_ view: NSView, _ pointInTable: NSPoint) -> InteractiveButton? {
            let local = view.convert(pointInTable, from: self)
            guard view.bounds.contains(local) else { return nil }
            if let button = view as? InteractiveButton { return button }
            for sub in view.subviews.reversed() {
                if let found = search(sub, pointInTable) { return found }
            }
            return nil
        }
        return search(self, point)
    }

    override func mouseDragged(with event: NSEvent) {
        if let button = trackingButton {
            button.mouseDragged(with: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let button = trackingButton {
            button.mouseUp(with: event)
            trackingButton = nil
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            onDelete?()
        case 36, 76:
            onPaste?()
        case 49:
            onPlay?()
        default:
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                onCopy?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

private final class HistoryRowView: NSTableCellView {
    private let hover = HoverEngine()
    private let tile = PassthroughView()
    private let tileIcon = NSImageView()
    private let text: PassthroughLabel
    private let meta: PassthroughLabel
    private let actions: NSStackView
    var isSelected = false {
        didSet { applyChrome(animated: true) }
    }

    private static let metaFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    init(item: HistoryItem, playing: Bool, target: AnyObject) {
        text = PassthroughLabel(wrappingLabelWithString: item.text)
        let seconds = max(0, Int(item.duration.rounded()))
        meta = PassthroughLabel(labelWithString: "\(Self.metaFormatter.string(from: item.createdAt))  ·  \(seconds)s  ·  \(item.language.uppercased())")

        let copy = InteractiveButton.icon("doc.on.doc", tooltip: "Copy", target: target, action: #selector(MainWindowController.copyItem(_:)))
        let paste = InteractiveButton.icon("arrow.uturn.forward", tooltip: "Paste", target: target, action: #selector(MainWindowController.pasteItem(_:)))
        let play = InteractiveButton.icon(playing ? "stop.fill" : "play.fill", tooltip: playing ? "Stop" : "Play", target: target, action: #selector(MainWindowController.playItem(_:)))
        play.isEnabled = item.audioURL != nil
        play.toolTip = item.audioURL == nil ? "No audio for this transcription" : (playing ? "Stop" : "Play")
        let vocab = InteractiveButton.icon("character.book.closed", tooltip: "Add to vocabulary", target: target, action: #selector(MainWindowController.vocabItem(_:)))
        let trash = InteractiveButton.destructiveIcon("trash", tooltip: "Delete", target: target, action: #selector(MainWindowController.deleteItem(_:)))
        for button in [copy, paste, play, vocab, trash] {
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        }
        actions = NSStackView(views: [copy, paste, play, vocab, trash])
        actions.orientation = .horizontal
        actions.spacing = 2

        super.init(frame: .zero)
        wantsLayer = true
        hover.onSync = { [weak self] in self?.applyChrome(animated: false) }

        tile.wantsLayer = true
        tile.layer?.cornerRadius = 9
        tileIcon.image = Theme.symbol("waveform", size: 13, weight: .semibold)
        tileIcon.contentTintColor = Theme.brand
        tileIcon.imageScaling = .scaleNone
        tile.addSubview(tileIcon)

        text.font = NSFont.systemFont(ofSize: 13)
        text.textColor = Theme.ink
        text.maximumNumberOfLines = 2
        text.cell?.truncatesLastVisibleLine = true

        meta.font = NSFont.systemFont(ofSize: 11)
        meta.textColor = Theme.inkMuted
        meta.lineBreakMode = .byTruncatingTail

        addSubview(tile)
        addSubview(text)
        addSubview(meta)
        addSubview(actions)
        applyChrome(animated: false)
        setAccessibilityRole(.row)
        setAccessibilityLabel(item.text)
    }

    // Fixed-height row: manual frames keep the geometry deterministic where
    // autolayout was resolving short rows unpredictably.
    override func layout() {
        super.layout()
        let inset = Theme.space3
        let actionsSize = actions.fittingSize
        let actionsX = bounds.width - inset - actionsSize.width
        actions.frame = NSRect(
            x: actionsX,
            y: ((bounds.height - actionsSize.height) / 2).rounded(),
            width: actionsSize.width,
            height: actionsSize.height
        )
        tile.frame = NSRect(x: inset, y: ((bounds.height - 32) / 2).rounded(), width: 32, height: 32)
        tileIcon.frame = tile.bounds
        let textX = tile.frame.maxX + inset
        let textW = max(0, actionsX - inset - textX)
        text.preferredMaxLayoutWidth = textW
        let textH = min(ceil(text.sizeThatFits(NSSize(width: textW, height: 60)).height), 38)
        let metaH = ceil(meta.intrinsicContentSize.height)
        let blockH = textH + 5 + metaH
        let blockY = ((bounds.height - blockH) / 2).rounded()
        meta.frame = NSRect(x: textX, y: blockY, width: textW, height: metaH)
        text.frame = NSRect(x: textX, y: blockY + metaH + 5, width: textW, height: textH)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.install(on: self)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.enter()
        applyChrome(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hover.exit()
        applyChrome(animated: true)
    }

    private func applyChrome(animated: Bool) {
        let fill: NSColor
        let border: NSColor
        if isSelected {
            fill = Theme.cardSelected
            border = Theme.brand.withAlphaComponent(0.5)
        } else if hover.hovered {
            fill = Theme.cardHover
            border = Theme.ruleStrong
        } else {
            fill = Theme.card
            border = Theme.rule
        }
        Chrome.paint(self, fill: fill, border: border, radius: Theme.radiusLg, borderWidth: 1, animated: animated)
        tile.layer?.backgroundColor = Theme.cg(Theme.brand.withAlphaComponent(0.13), in: self)
        let lifted = isSelected || hover.hovered
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = lifted ? 0.08 : 0
        layer?.shadowRadius = 7
        layer?.shadowOffset = .zero
    }
}

// Menu-bar apps stay inactive until something calls activate. Hover still
// works because tracking areas use .activeAlways; clicks do not, unless
// the window takes key and the click is delivered.
final class ChromeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            if !isKeyWindow {
                makeKeyAndOrderFront(nil)
            }
        default:
            break
        }
        super.sendEvent(event)
    }
}

final class BrandMark: NSView {
    private let gradient = CAGradientLayer()
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.insertSublayer(gradient, at: 0)
        icon.image = Theme.symbol("waveform", size: 12, weight: .bold)
        icon.contentTintColor = Theme.paper
        icon.imageScaling = .scaleNone
        addSubview(icon)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        layer?.cornerRadius = bounds.height * 0.3
        CATransaction.commit()
        icon.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.masksToBounds = true
        gradient.colors = [Theme.cg(Theme.brand, in: self), Theme.cg(Theme.brandDeep, in: self)]
    }
}

enum VocabularySheet {
    static func present(from window: NSWindow?, seed: String?) {
        let alert = NSAlert()
        alert.messageText = seed == nil ? "Add custom vocabulary" : "Fix a spelling"
        alert.informativeText = seed == nil
            ? "Add a name or term Lowkey should keep."
            : "If Lowkey misspelled something, type the wrong form and the correct one. It will start preferring the correct spelling."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let wrong = NSTextField(string: seed ?? "")
        wrong.placeholderString = seed == nil ? "Term, like WezTerm" : "What it typed"
        let right = NSTextField(string: "")
        right.placeholderString = "Correct spelling"
        stack.addArrangedSubview(wrong)
        if seed != nil { stack.addArrangedSubview(right) }
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: seed == nil ? 24 : 56)
        alert.accessoryView = stack
        if alert.runModal() == .alertFirstButtonReturn {
            if seed == nil {
                VocabularyStore.shared.addTerm(wrong.stringValue)
            } else {
                let from = wrong.stringValue.isEmpty ? (seed ?? "") : wrong.stringValue
                let to = right.stringValue.isEmpty ? wrong.stringValue : right.stringValue
                if right.stringValue.isEmpty {
                    VocabularyStore.shared.addTerm(to)
                } else {
                    VocabularyStore.shared.learn(wrong: from, right: to)
                }
            }
        }
    }
}
