import AppKit

enum FlowBarMode: Equatable {
    case hidden, idle, listening, working, success
    // Neutral information, such as text waiting on the clipboard.
    case notice(String, symbol: String)
    case failed(String)
}

// A nonactivating panel keeps the insertion point in the app being dictated to.
// AppKit owns the glass and controls; this controller owns only dictation state.
final class FlowBarController {
    var onIdleTap: (() -> Void)?
    var onStop: (() -> Void)?
    var restingMode: FlowBarMode = .hidden
    private(set) var mode: FlowBarMode = .hidden
    private var panel: NSPanel?
    private let chrome = FlowBarContent()
    private var glass: NSView?
    private var dismissWork: DispatchWorkItem?
    private var messageAction: (() -> Void)?
    private var timer: Timer?
    private var levels = Array(repeating: CGFloat.zero, count: 18)
    private var incoming = Array(repeating: CGFloat.zero, count: 18)
    private var lastWaveTime: CFTimeInterval = 0
    private var screen: NSScreen?
    private var generation = 0
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Clicking a notice or failure runs `action`, if any, and dismisses it.
    func setMode(_ next: FlowBarMode, action: (() -> Void)? = nil) {
        generation += 1
        dismissWork?.cancel()
        dismissWork = nil
        messageAction = action
        let previous = mode
        mode = next
        if next != .listening { chrome.setListeningAccessory(handsFree: false, remaining: nil) }
        if next == .hidden {
            chrome.apply(.hidden)
            stopTimer()
            panel?.orderOut(nil)
            return
        }
        if panel == nil { build() }
        if previous == .hidden || next == .listening {
            screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        }
        chrome.apply(next, animated: previous != .hidden && !reducedMotion)
        if next == .listening { startTimer() } else { stopTimer() }
        panel?.ignoresMouseEvents = next == .working || next == .success
        updateFrame(animated: previous != .hidden)
        panel?.orderFrontRegardless()
        switch next {
        case .success: rest(after: 1.0)
        case .notice: rest(after: 4)
        case .failed: rest(after: 6)
        default: break
        }
    }

    // Hands-free shows a stop control; the final seconds before the length
    // limit replace it with a countdown.
    func setListeningAccessory(handsFree: Bool, remaining: Int?) {
        guard mode == .listening else { return }
        let before = chrome.preferredSize
        chrome.setListeningAccessory(handsFree: handsFree, remaining: remaining)
        if chrome.preferredSize != before { updateFrame(animated: true) }
    }

    private func messageClicked() {
        let action = messageAction
        setMode(restingMode)
        action?()
    }

    private func updateFrame(animated: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        chrome.fitMessageWidth(visible.width - 36)
        let rect = Self.panelFrame(for: chrome.preferredSize, in: visible)
        if reducedMotion || !animated {
            panel?.setFrame(rect, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                panel?.animator().setFrame(rect, display: true)
            }
        }
    }

    func pushWave(_ samples: [CGFloat]) {
        guard mode == .listening, !samples.isEmpty else { return }
        incoming = (0..<18).map { index in
            let mapped = min(samples.count - 1, index * samples.count / 18)
            return max(0, min(1, samples[mapped]))
        }
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: 18)
        incoming = levels
        chrome.waveform.bars = levels
    }

    func nudge() {
        guard mode == .working else { return }
        chrome.showWorkingMessage("Finishing dictation…", animated: !reducedMotion)
        updateFrame(animated: true)
        NSAccessibility.post(element: chrome, notification: .announcementRequested,
                             userInfo: [.announcement: "Finishing dictation", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func rest(after delay: TimeInterval) {
        let ticket = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == ticket else { return }
            self.setMode(self.restingMode)
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastWaveTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, self.mode == .listening else { return }
            let now = CACurrentMediaTime()
            let elapsed = now - self.lastWaveTime
            self.lastWaveTime = now
            for i in self.levels.indices {
                // Fast attack, gentle release. Use elapsed time so delayed frames
                // catch up instead of adding another frame's worth of lag.
                let response = self.incoming[i] > self.levels[i] ? 0.012 : 0.060
                let blend = CGFloat(1 - exp(-elapsed / response))
                self.levels[i] += (self.incoming[i] - self.levels[i]) * blend
            }
            self.chrome.waveform.bars = self.levels
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func build() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Lowkey dictation")
        chrome.onStart = { [weak self] in self?.onIdleTap?() }
        chrome.onStop = { [weak self] in self?.onStop?() }
        chrome.onMessageClick = { [weak self] in self?.messageClicked() }
        // Leave enough transparent space for the system's optical edge.
        let root = NSView()
        let material: NSView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = FlowBarContent.height / 2
            glass.contentView = chrome
            material = glass
        } else {
            material = legacyMaterial()
        }
        #else
        material = legacyMaterial()
        #endif
        material.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(material)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            material.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            material.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            material.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        self.glass = material
        panel.contentView = root
        self.panel = panel
    }

    private func legacyMaterial() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = FlowBarContent.height / 2
        effect.layer?.masksToBounds = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: effect.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    static func panelFrame(for size: NSSize, in visible: NSRect) -> NSRect {
        let width = min(size.width + 12, max(0, visible.width - 24))
        return NSRect(x: visible.midX - width / 2, y: visible.minY + 18,
                      width: width, height: FlowBarContent.height + 12)
    }
}

final class FlowBarContent: NSView {
    static let height: CGFloat = 36
    private static let padding: CGFloat = 14
    private static let indicatorSize: CGFloat = 16
    private static let spacing: CGFloat = 8
    private static let maximumWidth: CGFloat = 480
    private static let listeningWidth: CGFloat = 132
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onMessageClick: (() -> Void)?
    fileprivate let waveform = WaveformView()
    let label = NSTextField(labelWithString: "")
    private let start = NSButton()
    private let recordingSurface = NSButton()
    private let messageSurface = NSButton()
    private let status = NSImageView()
    private let progress = ProgressGlyphView()
    private let stopGlyph = NSImageView()
    private let countdown = NSTextField(labelWithString: "")
    private var mode: FlowBarMode = .idle
    private var handsFree = false
    private var remaining: Int?

    private var showsListeningAccessory: Bool { handsFree || remaining != nil }

    var preferredSize: NSSize {
        let width: CGFloat
        switch mode {
        case .hidden, .idle, .success: width = Self.height
        case .listening:
            width = Self.listeningWidth + (showsListeningAccessory ? Self.indicatorSize + Self.spacing : 0)
        case .working, .notice, .failed:
            width = label.isHidden ? Self.height : 2 * Self.padding + Self.indicatorSize + Self.spacing + ceil(label.cell?.cellSize.width ?? 0)
        }
        return NSSize(width: width, height: Self.height)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        start.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Start dictation")
        start.imagePosition = .imageOnly
        start.bezelStyle = .circular
        start.isBordered = false
        start.imageScaling = .scaleNone
        start.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        start.target = self
        start.action = #selector(startAction)
        start.toolTip = "Start dictation"
        start.setAccessibilityLabel("Start dictation")
        addSubview(start)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byClipping
        stopGlyph.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
        stopGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        stopGlyph.contentTintColor = .labelColor
        countdown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        countdown.textColor = .systemOrange
        countdown.alignment = .center
        for view in [waveform, label, status, progress, stopGlyph, countdown] {
            view.wantsLayer = true
            addSubview(view)
        }
        // The waveform capsule is one click target, without extra visible controls.
        recordingSurface.title = ""
        recordingSurface.isBordered = false
        recordingSurface.target = self
        recordingSurface.action = #selector(stopAction)
        recordingSurface.toolTip = "Click to finish dictation. Press Escape to cancel."
        recordingSurface.setAccessibilityLabel("Finish dictation")
        recordingSurface.setAccessibilityHelp("Click the voice bar to finish. Press Escape to cancel.")
        addSubview(recordingSurface)
        messageSurface.title = ""
        messageSurface.isBordered = false
        messageSurface.target = self
        messageSurface.action = #selector(messageAction)
        addSubview(messageSurface)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func startAction() { onStart?() }
    @objc private func stopAction() { onStop?() }
    @objc private func messageAction() { onMessageClick?() }

    func setListeningAccessory(handsFree: Bool, remaining: Int?) {
        self.handsFree = handsFree
        self.remaining = remaining
        guard mode == .listening else { return }
        stopGlyph.isHidden = !handsFree || remaining != nil
        countdown.isHidden = remaining == nil
        countdown.stringValue = remaining.map(String.init) ?? ""
        let listening = handsFree ? "Listening hands-free" : "Listening"
        setAccessibilityLabel(remaining.map { "\(listening), \($0) seconds left" } ?? listening)
        recordingSurface.setAccessibilityHelp(remaining.map { "\($0) seconds left. Click the voice bar to finish." }
            ?? "Click the voice bar to finish. Press Escape to cancel.")
        needsLayout = true
    }

    func apply(_ mode: FlowBarMode, animated: Bool = false) {
        let previous = self.mode
        self.mode = mode
        for view in subviews {
            // Completion can arrive during the spinner's entrance. Keep its
            // visibility and opacity continuous while the ring becomes a check.
            if view === progress, previous == .working, mode == .success { continue }
            view.layer?.removeAllAnimations()
            view.alphaValue = 1
            view.isHidden = true
        }
        if mode != .success { progress.reset() }
        toolTip = nil
        setAccessibilityHelp(nil)
        switch mode {
        case .idle, .hidden:
            start.isHidden = false
            setAccessibilityLabel("Start dictation")
        case .listening:
            waveform.isHidden = false
            recordingSurface.isHidden = false
            setListeningAccessory(handsFree: handsFree, remaining: remaining)
            if animated { fadeIn(waveform) }
        case .working:
            progress.isHidden = false
            progress.beginSpinning(animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            setAccessibilityLabel("Transcribing")
            if animated {
                if previous == .listening {
                    waveform.isHidden = false
                    waveform.alphaValue = 0
                    let dissolve = CABasicAnimation(keyPath: "opacity")
                    dissolve.fromValue = 1
                    dissolve.toValue = 0
                    dissolve.duration = 0.12
                    waveform.layer?.add(dissolve, forKey: "dissolve")
                }
                fadeIn(progress)
            }
        case .success:
            progress.isHidden = false
            progress.completeIntoCheck(animated: animated)
            setAccessibilityLabel("Dictation complete")
        case .notice(let message, let symbol):
            status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            status.contentTintColor = .secondaryLabelColor
            showStatusMessage(message, animated: animated)
        case .failed(let message):
            status.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            status.contentTintColor = .systemOrange
            showStatusMessage(message, animated: animated)
        }
        needsLayout = true
    }

    private func showStatusMessage(_ message: String, animated: Bool) {
        status.isHidden = false
        messageSurface.isHidden = false
        messageSurface.setAccessibilityLabel(message)
        showMessage(message)
        if animated {
            fadeIn(status)
            fadeIn(label, delay: 0.18)
        }
    }

    func showWorkingMessage(_ message: String, animated: Bool = false) {
        guard mode == .working else { return }
        showMessage(message)
        if animated { fadeIn(label, delay: 0.18) }
    }

    private func showMessage(_ message: String) {
        let singleLine = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        label.stringValue = singleLine.isEmpty ? "Something went wrong" : singleLine
        let fullMessage = label.stringValue
        // Technical diagnostics belong in the tooltip, not a screen-wide capsule.
        label.isHidden = false
        label.toolTip = fullMessage
        toolTip = fullMessage
        setAccessibilityLabel(label.stringValue)
        setAccessibilityHelp(fullMessage)
        fitMessageWidth(Self.maximumWidth)
        needsLayout = true
    }

    func fitMessageWidth(_ maximumWidth: CGFloat) {
        guard !label.isHidden, preferredSize.width > maximumWidth else { return }
        let message = label.toolTip ?? label.stringValue
        if message.contains("multilingual Whisper model") {
            label.stringValue = "Choose a multilingual model in Settings"
        } else if message.hasPrefix("Whisper model not found") {
            label.stringValue = "Whisper model not found"
        } else if message.hasPrefix("whisper-server not found") {
            label.stringValue = "Whisper is not installed"
        } else {
            label.stringValue = "Dictation couldn't finish"
        }
        setAccessibilityLabel(label.stringValue)
        messageSurface.setAccessibilityLabel(label.stringValue)
        needsLayout = true
    }

    private func fadeIn(_ view: NSView, delay: TimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        view.layer?.add(fade, forKey: "appear")
    }

    override func layout() {
        super.layout()
        start.frame = bounds
        recordingSurface.frame = bounds
        messageSurface.frame = bounds
        let accessoryWidth = showsListeningAccessory ? Self.indicatorSize + Self.spacing : 0
        waveform.frame = NSRect(x: Self.padding, y: 9, width: max(0, bounds.width - 2 * Self.padding - accessoryWidth), height: max(0, bounds.height - 18))
        let accessoryFrame = NSRect(x: bounds.width - Self.padding - Self.indicatorSize, y: (bounds.height - Self.indicatorSize) / 2,
                                    width: Self.indicatorSize, height: Self.indicatorSize)
        stopGlyph.frame = accessoryFrame
        let countdownHeight = ceil(countdown.intrinsicContentSize.height)
        countdown.frame = NSRect(x: accessoryFrame.minX - 4, y: (bounds.height - countdownHeight) / 2,
                                 width: accessoryFrame.width + 8, height: countdownHeight)
        let indicatorFrame = NSRect(x: Self.padding, y: (bounds.height - Self.indicatorSize) / 2,
                                    width: Self.indicatorSize, height: Self.indicatorSize)
        progress.frame = label.isHidden
            ? NSRect(x: (bounds.width - Self.indicatorSize) / 2, y: (bounds.height - Self.indicatorSize) / 2,
                     width: Self.indicatorSize, height: Self.indicatorSize)
            : indicatorFrame
        status.frame = indicatorFrame
        let labelX = indicatorFrame.maxX + Self.spacing
        let height = min(bounds.height, ceil(label.intrinsicContentSize.height))
        label.frame = NSRect(x: labelX, y: (bounds.height - height) / 2,
                             width: max(0, bounds.width - labelX - Self.padding), height: height)
    }
}

private final class WaveformView: NSView {
    var bars: [CGFloat] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty else { return }
        NSColor.labelColor.setFill()
        let step = bounds.width / CGFloat(bars.count)
        let width = max(1, step - 2.5)
        for (index, value) in bars.enumerated() {
            let height = max(3, bounds.height * value)
            NSBezierPath(roundedRect: NSRect(x: CGFloat(index) * step, y: (bounds.height - height) / 2, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

// A ring that spins while whisper works, closes into a full circle, then
// strokes a checkmark: the tail end of the wave-to-done morph.
final class ProgressGlyphView: NSView {
    private let ring = CAShapeLayer()
    private let check = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        for shape in [ring, check] {
            shape.actions = ["strokeEnd": NSNull(), "strokeColor": NSNull(), "transform": NSNull()]
            shape.fillColor = nil
            shape.strokeColor = NSColor.labelColor.cgColor
            shape.lineCap = .round
            shape.strokeStart = 0
            shape.strokeEnd = 0
        }
        ring.lineWidth = 1.7
        check.lineWidth = 1.8
        check.lineJoin = .round
        layer?.addSublayer(ring)
        layer?.addSublayer(check)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        var stroke = NSColor.labelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { stroke = NSColor.labelColor.cgColor }
        ring.strokeColor = stroke
        check.strokeColor = stroke
    }

    override func layout() {
        super.layout()
        applyColors()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A rotated layer's frame is its transformed bounding box. Setting it
        // would distort bounds when completion freezes the spinner mid-turn.
        ring.bounds = bounds
        check.bounds = bounds
        check.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.width * 0.28, y: bounds.height * 0.50))
        path.addLine(to: CGPoint(x: bounds.width * 0.44, y: bounds.height * 0.34))
        path.addLine(to: CGPoint(x: bounds.width * 0.73, y: bounds.height * 0.66))
        check.path = path
        CATransaction.commit()
    }

    func beginSpinning(animated: Bool) {
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Transcribing")
        check.removeAllAnimations()
        ring.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        check.strokeEnd = 0
        ring.setValue(0.0, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        let grow = CABasicAnimation(keyPath: "strokeEnd")
        grow.fromValue = 0
        grow.toValue = 0.72
        grow.duration = 0.16
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 0.72
        if animated { ring.add(grow, forKey: "grow") }

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 0.7
        spin.repeatCount = .infinity
        if animated { ring.add(spin, forKey: "spin") }
    }

    func completeIntoCheck(animated: Bool) {
        setAccessibilityRole(.image)
        setAccessibilityLabel("Dictation complete")
        // Freeze the spin exactly where it is so the ring closes from its
        // current gap with no visual jump.
        let rotation = ring.presentation()?.transform ?? ring.transform
        let partial = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAllAnimations()
        check.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.transform = rotation
        CATransaction.commit()

        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = partial
        close.toValue = 1
        close.duration = 0.16
        close.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 1
        if animated { ring.add(close, forKey: "close") }

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.2
        draw.beginTime = check.convertTime(CACurrentMediaTime(), from: nil) + 0.06
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        draw.fillMode = .backwards
        check.strokeEnd = 1
        if animated { check.add(draw, forKey: "draw") }
    }

    func reset() {
        ring.removeAllAnimations()
        check.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.strokeEnd = 0
        check.strokeEnd = 0
        ring.setValue(0.0, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }
}
