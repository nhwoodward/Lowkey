import AppKit

final class ListEditorController: NSWindowController, NSTextFieldDelegate {
    private let leftField = NSTextField(string: "")
    private let rightField = NSTextField(string: "")
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let termsList = FlippedStackView()
    private let recentsList = FlippedStackView()
    private let recentsHeader = NSTextField(labelWithString: "RECENT DICTATIONS")
    private let recentsEmpty = NSTextField(labelWithString: "No dictations yet. Hold your shortcut, then they will show up here.")
    private var recentsScroll: NSScrollView?
    private var historyObserver: UUID?
    private let mode: Mode
    private let onAdd: (String, String) -> Void
    private let onDelete: (UUID) -> Void

    enum Mode { case vocabulary, snippets }

    init(mode: Mode, onAdd: @escaping (String, String) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.mode = mode
        self.onAdd = onAdd
        self.onDelete = onDelete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = mode == .vocabulary ? "Custom Vocabulary" : "Dictation Snippets"
        window.minSize = NSSize(width: 480, height: 420)
        window.backgroundColor = Theme.paper
        super.init(window: window)
        configureForm()
        window.contentView = build()
        window.initialFirstResponder = leftField
        leftField.nextKeyView = rightField
        rightField.nextKeyView = addButton
        addButton.nextKeyView = leftField
        reload()
        refreshAddEnabled()
        historyObserver = HistoryStore.shared.observe { [weak self] in
            self?.reloadRecents()
        }
    }

    deinit {
        if let historyObserver {
            HistoryStore.shared.stopObserving(historyObserver)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusInput() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(leftField)
    }

    private func configureForm() {
        styleField(leftField, placeholder: mode == .vocabulary ? "Term or wrong spelling" : "Trigger")
        styleField(rightField, placeholder: mode == .vocabulary ? "Correct spelling (optional)" : "Expansion")
        addButton.bezelStyle = .rounded
        addButton.setButtonType(.momentaryPushIn)
        addButton.target = self
        addButton.action = #selector(addRow)
        addButton.keyEquivalent = "\r"
        addButton.translatesAutoresizingMaskIntoConstraints = false
    }

    private func styleField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = Theme.ink
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.isBordered = true
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func build() -> NSView {
        let root = NSView()

        let hint = NSTextField(wrappingLabelWithString: mode == .vocabulary
            ? "Add names Lowkey should keep. To fix a misspelling, type what it wrote and the correct spelling."
            : "Say the trigger and Lowkey expands it into the saved phrase.")
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = Theme.inkMuted
        hint.translatesAutoresizingMaskIntoConstraints = false

        let fields = NSStackView(views: [leftField, rightField, addButton])
        fields.orientation = .horizontal
        fields.alignment = .centerY
        fields.spacing = 8
        fields.translatesAutoresizingMaskIntoConstraints = false
        leftField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftField.widthAnchor.constraint(equalTo: rightField.widthAnchor).isActive = true

        let savedHeader = NSTextField(labelWithString: mode == .vocabulary ? "YOUR TERMS" : "YOUR SNIPPETS")
        savedHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        savedHeader.textColor = Theme.inkFaint
        savedHeader.translatesAutoresizingMaskIntoConstraints = false

        termsList.orientation = .vertical
        termsList.alignment = .leading
        termsList.spacing = 4
        termsList.translatesAutoresizingMaskIntoConstraints = false
        let termsScroll = wrapScroll(termsList)

        recentsHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        recentsHeader.textColor = Theme.inkFaint
        recentsHeader.translatesAutoresizingMaskIntoConstraints = false
        recentsHeader.isHidden = mode != .vocabulary

        recentsEmpty.font = NSFont.systemFont(ofSize: 12)
        recentsEmpty.textColor = Theme.inkMuted
        recentsEmpty.translatesAutoresizingMaskIntoConstraints = false
        recentsEmpty.isHidden = true

        recentsList.orientation = .vertical
        recentsList.alignment = .leading
        recentsList.spacing = 4
        recentsList.translatesAutoresizingMaskIntoConstraints = false
        let recentsScroll = wrapScroll(recentsList)
        recentsScroll.isHidden = mode != .vocabulary
        self.recentsScroll = recentsScroll

        root.addSubview(hint)
        root.addSubview(fields)
        root.addSubview(savedHeader)
        root.addSubview(termsScroll)
        root.addSubview(recentsHeader)
        root.addSubview(recentsEmpty)
        root.addSubview(recentsScroll)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: Theme.space4),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Theme.space4),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.space4),
            fields.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: Theme.space3),
            fields.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            fields.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            savedHeader.topAnchor.constraint(equalTo: fields.bottomAnchor, constant: Theme.space5),
            savedHeader.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            termsScroll.topAnchor.constraint(equalTo: savedHeader.bottomAnchor, constant: 8),
            termsScroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            termsScroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            termsScroll.heightAnchor.constraint(equalToConstant: 140),
            recentsHeader.topAnchor.constraint(equalTo: termsScroll.bottomAnchor, constant: Theme.space5),
            recentsHeader.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            recentsEmpty.topAnchor.constraint(equalTo: recentsHeader.bottomAnchor, constant: 8),
            recentsEmpty.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            recentsEmpty.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            recentsScroll.topAnchor.constraint(equalTo: recentsHeader.bottomAnchor, constant: 8),
            recentsScroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            recentsScroll.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            recentsScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.space4),
        ])
        return root
    }

    private func wrapScroll(_ stack: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshAddEnabled()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            addRow()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            window?.selectNextKeyView(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            window?.selectPreviousKeyView(nil)
            return true
        }
        return false
    }

    @objc private func addRow() {
        let left = leftField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else {
            window?.makeFirstResponder(leftField)
            return
        }
        onAdd(left, right)
        leftField.stringValue = ""
        rightField.stringValue = ""
        refreshAddEnabled()
        reload()
        window?.makeFirstResponder(leftField)
    }

    @objc private func removeRow(_ sender: AnyObject) {
        guard let raw = (sender as? NSView)?.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        onDelete(id)
        reload()
    }

    private func refreshAddEnabled() {
        let left = leftField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        addButton.isEnabled = !left.isEmpty
        addButton.toolTip = left.isEmpty ? "Enter a term first" : "Add"
    }

    private func reload() {
        reloadTerms()
        reloadRecents()
    }

    private func reloadTerms() {
        termsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows: [(UUID, String)]
        if mode == .vocabulary {
            let fixes = VocabularyStore.shared.fixes.map { ($0.id, "\($0.wrong)  →  \($0.right)  ·  \($0.count)x") }
            let terms = VocabularyStore.shared.terms.filter { term in
                !VocabularyStore.shared.fixes.contains { $0.right.compare(term.phrase, options: .caseInsensitive) == .orderedSame }
            }.map { ($0.id, $0.phrase) }
            rows = fixes + terms
        } else {
            rows = SnippetStore.shared.items.map { ($0.id, "\($0.trigger)  →  \($0.expansion)") }
        }
        if rows.isEmpty {
            let empty = PassthroughLabel(labelWithString: mode == .vocabulary
                ? "Nothing saved yet. Add a name or a spelling fix above."
                : "No snippets yet.")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = Theme.inkMuted
            termsList.addArrangedSubview(empty)
            return
        }
        for row in rows {
            let remove = InteractiveButton.destructiveIcon("trash", tooltip: "Remove", target: self, action: #selector(removeRow(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(row.0.uuidString)
            let line = ListRow(title: row.1, remove: remove)
            termsList.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: termsList.widthAnchor).isActive = true
        }
    }

    private func reloadRecents() {
        recentsList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard mode == .vocabulary else { return }
        let items = Array(HistoryStore.shared.items.prefix(12))
        recentsEmpty.isHidden = !items.isEmpty
        recentsScroll?.isHidden = items.isEmpty || mode != .vocabulary
        if items.isEmpty { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        for item in items {
            let row = RecentDictationRow(text: item.text, meta: formatter.string(from: item.createdAt)) { [weak self] in
                self?.useRecent(item)
            }
            recentsList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentsList.widthAnchor).isActive = true
        }
    }

    private func useRecent(_ item: HistoryItem) {
        leftField.stringValue = item.text
        rightField.stringValue = ""
        refreshAddEnabled()
        window?.makeFirstResponder(leftField)
        leftField.currentEditor()?.selectAll(nil)
    }
}

private final class RecentDictationRow: NSView {
    private let hover = HoverEngine()
    private let onSelect: () -> Void

    init(text: String, meta: String, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hover.onSync = { [weak self] in self?.applyChrome() }

        let body = PassthroughLabel(wrappingLabelWithString: text)
        body.font = NSFont.systemFont(ofSize: 13)
        body.textColor = Theme.ink
        body.maximumNumberOfLines = 2
        body.translatesAutoresizingMaskIntoConstraints = false

        let stamp = PassthroughLabel(labelWithString: meta)
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = Theme.inkMuted
        stamp.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        addSubview(stamp)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            body.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stamp.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 4),
            stamp.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            stamp.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        applyChrome()
        setAccessibilityRole(.button)
        setAccessibilityLabel("Use dictation")
        setAccessibilityHelp(text)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.install(on: self)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.enter()
        applyChrome()
    }

    override func mouseExited(with event: NSEvent) {
        hover.exit()
        applyChrome()
    }

    override func mouseDown(with event: NSEvent) {
        hover.beginPress()
        applyChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hover.drag(inside: inside)
        applyChrome()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let shouldFire = hover.endPress(inside: inside)
        applyChrome()
        if shouldFire { onSelect() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func applyChrome() {
        let fill = hover.pressed ? Theme.fillPress : (hover.hovered ? Theme.fillHover : Theme.card)
        Chrome.paint(self, fill: fill, border: Theme.rule, radius: Theme.radiusMd, borderWidth: 1, animated: true)
    }
}
