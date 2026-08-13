import AppKit

final class InteractiveButton: NSView {
    enum Style {
        case nav
        case pill
        case icon
        case destructiveIcon
        case ghost
    }

    var style: Style
    var titleText: String { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    var symbolName: String? { didSet { refreshGlyph(); invalidateIntrinsicContentSize() } }
    var isSelected = false { didSet { applyChrome(animated: true) } }
    var isFocusable = true
    var isEnabled = true { didSet { applyChrome(animated: false) } }
    var target: AnyObject?
    var action: Selector?
    private var buttonTag = 0
    override var tag: Int { buttonTag }
    var keyEquivalentString = ""
    var toolTipText: String? {
        get { toolTip }
        set { toolTip = newValue }
    }

    private let hover = HoverEngine()
    private let iconView = NSImageView()
    private let label = PassthroughLabel(labelWithString: "")
    private var flashed = false
    private var storedSymbol: String?

    init(style: Style, title: String = "", symbol: String? = nil) {
        self.style = style
        self.titleText = title
        self.symbolName = symbol
        super.init(frame: .zero)
        hover.isEnabled = { [weak self] in self?.isEnabled ?? false }
        hover.onSync = { [weak self] in self?.applyChrome(animated: false) }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        focusRingType = .exterior
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.font = NSFont.systemFont(ofSize: style == .ghost ? 12 : 13, weight: .medium)
        addSubview(iconView)
        addSubview(label)
        refreshGlyph()
        applyChrome(animated: false)
        setAccessibilityRole(.button)
        setAccessibilityElement(true)
        setAccessibilityLabel(title.isEmpty ? (symbol ?? "Button") : title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func nav(_ symbol: String, _ title: String, tag: Int, target: AnyObject, action: Selector) -> InteractiveButton {
        let button = InteractiveButton(style: .nav, title: title, symbol: symbol)
        button.buttonTag = tag
        button.target = target
        button.action = action
        button.toolTip = title
        return button
    }

    static func pill(_ title: String, target: AnyObject, action: Selector) -> InteractiveButton {
        let button = InteractiveButton(style: .pill, title: title)
        button.target = target
        button.action = action
        button.toolTip = title
        return button
    }

    static func icon(_ symbol: String, tooltip: String, target: AnyObject, action: Selector) -> InteractiveButton {
        let button = InteractiveButton(style: .icon, symbol: symbol)
        button.target = target
        button.action = action
        button.toolTip = tooltip
        button.isFocusable = false
        button.setAccessibilityLabel(tooltip)
        return button
    }

    static func destructiveIcon(_ symbol: String, tooltip: String, target: AnyObject, action: Selector) -> InteractiveButton {
        let button = InteractiveButton(style: .destructiveIcon, symbol: symbol)
        button.target = target
        button.action = action
        button.toolTip = tooltip
        button.isFocusable = false
        button.setAccessibilityLabel(tooltip)
        return button
    }

    static func ghost(_ title: String, target: AnyObject, action: Selector) -> InteractiveButton {
        let button = InteractiveButton(style: .ghost, title: title)
        button.target = target
        button.action = action
        button.toolTip = title
        return button
    }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .icon, .destructiveIcon:
            return NSSize(width: Theme.iconHit, height: Theme.iconHit)
        case .nav:
            return NSSize(width: NSView.noIntrinsicMetric, height: Theme.navHeight)
        case .pill:
            // The extra 8pt covers NSTextField's internal cell padding, which
            // the raw string measurement misses; without it labels truncate.
            let width = labelSize().width + 32
            return NSSize(width: max(64, ceil(width)), height: Theme.pillHeight)
        case .ghost:
            let width = labelSize().width + 24
            return NSSize(width: max(52, ceil(width)), height: 24)
        }
    }

    override var acceptsFirstResponder: Bool { isEnabled && isFocusable }
    override var canBecomeKeyView: Bool { isEnabled && isFocusable }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func isAccessibilitySelected() -> Bool { isSelected }

    override func resetCursorRects() {
        discardCursorRects()
        if !isEnabled {
            addCursorRect(bounds, cursor: .operationNotAllowed)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.install(on: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome(animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.enter()
        applyChrome(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hover.exit()
        applyChrome(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        hover.beginPress()
        applyChrome(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hover.drag(inside: inside)
        applyChrome(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let shouldFire = hover.endPress(inside: inside)
        applyChrome(animated: true)
        if shouldFire { fire() }
    }

    func performClick(_ sender: Any? = nil) {
        fire()
    }

    override func accessibilityPerformPress() -> Bool {
        fire()
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !keyEquivalentString.isEmpty, isEnabled,
              event.charactersIgnoringModifiers == keyEquivalentString else {
            return super.performKeyEquivalent(with: event)
        }
        fire()
        return true
    }

    private func fire() {
        guard isEnabled, let action, let target else { return }
        _ = target.perform(action, with: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, frame.contains(point) else { return nil }
        return self
    }

    override func layout() {
        super.layout()
        label.stringValue = titleText
        switch style {
        case .icon, .destructiveIcon:
            iconView.isHidden = false
            label.isHidden = true
            iconView.frame = bounds.insetBy(dx: 6, dy: 6)
        case .nav:
            iconView.isHidden = symbolName == nil
            label.isHidden = false
            label.alignment = .left
            let icon: CGFloat = 16
            iconView.frame = NSRect(x: 10, y: ((bounds.height - icon) / 2).rounded(), width: icon, height: icon)
            let x = iconView.frame.maxX + 8
            placeLabel(x: x, width: max(0, bounds.width - x - 10))
        case .pill:
            iconView.isHidden = true
            label.isHidden = false
            label.alignment = .center
            placeLabel(x: 12, width: max(0, bounds.width - 24))
        case .ghost:
            iconView.isHidden = true
            label.isHidden = false
            label.alignment = .center
            placeLabel(x: 8, width: max(0, bounds.width - 16))
        }
        applyChrome(animated: false)
    }

    func flashSuccess() {
        storedSymbol = symbolName
        flashed = true
        symbolName = "checkmark"
        applyChrome(animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.flashed = false
            self.symbolName = self.storedSymbol
            self.applyChrome(animated: true)
        }
    }

    func applyChrome(animated: Bool) {
        let fill: NSColor
        let border: NSColor
        var tint = Theme.ink
        var text = Theme.ink
        let faded = !isEnabled

        switch style {
        case .nav:
            if isSelected {
                fill = hover.pressed ? Theme.fillSelectedPress : Theme.fillSelected
                border = Theme.ruleStrong
                tint = Theme.brand
            } else if hover.pressed {
                fill = Theme.fillPress
                border = NSColor.clear
            } else if hover.hovered {
                fill = Theme.fillHover
                border = NSColor.clear
            } else {
                fill = NSColor.clear
                border = NSColor.clear
            }
        case .pill:
            if hover.pressed {
                fill = Theme.brand.withAlphaComponent(0.16)
                border = Theme.brand.withAlphaComponent(0.55)
            } else if hover.hovered {
                fill = Theme.brand.withAlphaComponent(0.09)
                border = Theme.brand.withAlphaComponent(0.45)
            } else {
                fill = Theme.card
                border = Theme.rule
            }
        case .icon:
            if flashed {
                fill = Theme.success.withAlphaComponent(0.12)
                border = NSColor.clear
                tint = Theme.success
            } else if hover.pressed {
                fill = Theme.fillPress
                border = NSColor.clear
            } else if hover.hovered {
                fill = Theme.fillHover
                border = NSColor.clear
            } else {
                fill = NSColor.clear
                border = NSColor.clear
                tint = Theme.inkMuted
            }
        case .destructiveIcon:
            if hover.pressed {
                fill = Theme.danger.withAlphaComponent(0.16)
                border = NSColor.clear
                tint = Theme.danger
            } else if hover.hovered {
                fill = Theme.danger.withAlphaComponent(0.10)
                border = NSColor.clear
                tint = Theme.danger
            } else {
                fill = NSColor.clear
                border = NSColor.clear
                tint = Theme.inkMuted
            }
        case .ghost:
            if hover.pressed {
                fill = Theme.fillPress
                border = NSColor.clear
            } else if hover.hovered {
                fill = Theme.fillHover
                border = NSColor.clear
            } else {
                fill = NSColor.clear
                border = NSColor.clear
            }
            text = hover.hovered || hover.pressed ? Theme.ink : Theme.inkMuted
            tint = text
        }

        if faded {
            tint = tint.withAlphaComponent(0.38)
            text = text.withAlphaComponent(0.38)
        }

        let width: CGFloat = (style == .icon || style == .destructiveIcon || style == .ghost) ? 0 : 1
        Chrome.paint(self, fill: fill, border: border, radius: radius, borderWidth: width, animated: animated)
        if isSelected, style == .nav {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.06
            layer?.shadowRadius = 2
            layer?.shadowOffset = NSSize(width: 0, height: 0.5)
        } else {
            layer?.shadowOpacity = 0
        }
        iconView.contentTintColor = tint
        label.textColor = text
        alphaValue = 1
        setAccessibilityEnabled(isEnabled)
    }

    private var radius: CGFloat {
        switch style {
        case .nav: return Theme.radiusMd
        case .pill: return Theme.radiusMd
        case .icon, .destructiveIcon: return Theme.radiusSm
        case .ghost: return Theme.radiusSm
        }
    }

    private func placeLabel(x: CGFloat, width: CGFloat) {
        let height = max(16, ceil(label.intrinsicContentSize.height))
        label.frame = NSRect(
            x: x,
            y: ((bounds.height - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    private func refreshGlyph() {
        let size: CGFloat
        switch style {
        case .nav: size = 13
        case .icon, .destructiveIcon: size = 12
        default: size = 12
        }
        iconView.image = symbolName.flatMap { Theme.symbol($0, size: size) }
    }

    private func labelSize() -> NSSize {
        (titleText as NSString).size(withAttributes: [
            .font: label.font ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
    }
}

final class SettingsRow: NSView {
    private let hover = HoverEngine()
    private let separator = PassthroughView()
    private let accessory: NSView?
    var onActivate: (() -> Void)?
    var isInteractive = false

    init(symbol: String, color: NSColor, title: String, caption: String, accessory: NSView?) {
        self.accessory = accessory
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hover.isEnabled = { true }
        hover.onSync = { [weak self] in self?.applyChrome(animated: false) }

        let badge = PassthroughView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        badge.layer?.cornerRadius = Theme.radiusMd
        badge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = Theme.symbol(symbol, size: 12)
        icon.contentTintColor = color
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        let name = PassthroughLabel(labelWithString: title)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.textColor = Theme.ink
        name.translatesAutoresizingMaskIntoConstraints = false

        let note = PassthroughLabel(wrappingLabelWithString: caption)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = Theme.inkMuted
        note.preferredMaxLayoutWidth = 360
        note.maximumNumberOfLines = 2
        note.translatesAutoresizingMaskIntoConstraints = false

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.rule.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        // Separator is visual only. It must not steal clicks from the row or switch.

        addSubview(badge)
        addSubview(name)
        addSubview(note)
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.rowMinHeight),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.space3),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: Theme.space3),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            note.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -168),
            note.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            separator.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space3),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.space3),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: Theme.space3),
            ])
        }

        applyChrome(animated: false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        setAccessibilityHelp(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChrome(animated: false)
        separator.layer?.backgroundColor = Theme.cg(Theme.rule, in: self)
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

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        hover.beginPress()
        applyChrome(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hover.drag(inside: inside)
        applyChrome(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let shouldFire = hover.endPress(inside: inside)
        applyChrome(animated: true)
        if isInteractive, shouldFire { onActivate?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInteractive }

    override func hitTest(_ point: NSPoint) -> NSView? {
        HitTesting.deep(self, point: point, fallback: self)
    }

    private func applyChrome(animated: Bool) {
        let fill: NSColor
        if isInteractive, hover.pressed, hover.hovered {
            fill = Theme.fillPress
        } else if hover.hovered {
            fill = Theme.fillHover
        } else {
            fill = NSColor.clear
        }
        Chrome.paint(self, fill: fill, border: .clear, radius: Theme.radiusMd, borderWidth: 0, animated: animated)
        separator.alphaValue = hover.hovered || hover.pressed ? 0 : 1
    }
}

final class InputField: NSView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    var onChange: (() -> Void)?
    private let hover = HoverEngine()

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholder: String = "" {
        didSet {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: Theme.inkFaint,
                .font: NSFont.systemFont(ofSize: 13),
            ])
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        hover.onSync = { [weak self] in self?.paint() }
        field.isBezeled = false
        field.isBordered = false
        field.isEditable = true
        field.isSelectable = true
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = Theme.ink
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.fieldHeight),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.install(on: self)
    }

    override func mouseEntered(with event: NSEvent) {
        hover.enter()
        paint()
    }

    override func mouseExited(with event: NSEvent) {
        hover.exit()
        paint()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        let inField = convert(local, to: field)
        if field.bounds.contains(inField) { return field }
        return self
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        paint()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        paint()
    }

    private var focused: Bool {
        field.currentEditor() != nil || window?.firstResponder === field
    }

    private func paint() {
        let fill = focused ? Theme.paper : (hover.hovered ? Theme.card : Theme.paper)
        let border = focused ? Theme.accent : Theme.ruleStrong
        Chrome.paint(self, fill: fill, border: border, radius: Theme.radiusSm, borderWidth: 1, animated: false)
    }
}

final class ListRow: NSView {
    private let hover = HoverEngine()

    init(title: String, remove: InteractiveButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hover.onSync = { [weak self] in self?.applyChrome(animated: false) }

        let label = PassthroughLabel(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = Theme.ink
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(label)
        addSubview(remove)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -8),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: Theme.iconHit),
            remove.heightAnchor.constraint(equalToConstant: Theme.iconHit),
        ])
        applyChrome(animated: false)
        setAccessibilityRole(.row)
        setAccessibilityLabel(title)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        HitTesting.deep(self, point: point, fallback: self)
    }

    private func applyChrome(animated: Bool) {
        let fill = hover.hovered ? Theme.fillHover : NSColor.clear
        Chrome.paint(self, fill: fill, border: .clear, radius: Theme.radiusMd, borderWidth: 0, animated: animated)
    }
}

final class TransparentRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
}

func styledPopup() -> NSPopUpButton {
    let pop = NSPopUpButton(frame: .zero, pullsDown: false)
    pop.bezelStyle = .rounded
    pop.controlSize = .regular
    pop.font = NSFont.systemFont(ofSize: 13)
    pop.focusRingType = .default
    pop.translatesAutoresizingMaskIntoConstraints = false
    return pop
}

func styledSwitch() -> NSSwitch {
    let control = NSSwitch()
    control.controlSize = .regular
    control.focusRingType = .default
    control.translatesAutoresizingMaskIntoConstraints = false
    return control
}

final class Hairline: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        layer?.backgroundColor = Theme.cg(Theme.rule, in: self)
    }
}
