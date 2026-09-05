import AppKit

enum FlowBarMode: Equatable {
    case hidden, idle, listening, working, success
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
    private var timer: Timer?
    private var levels = Array(repeating: CGFloat.zero, count: 18)
    private var incoming = Array(repeating: CGFloat.zero, count: 18)
    private var screen: NSScreen?
    private var generation = 0
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func setMode(_ next: FlowBarMode) {
        generation += 1
        dismissWork?.cancel()
        dismissWork = nil
        let previous = mode
        mode = next
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
        case .failed: rest(after: 6)
        default: break
        }
    }

    private func updateFrame(animated: Bool) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        chrome.fitMessageWidth(visible.width - 36)
        let rect = Self.panelFrame(for: chrome.preferredSize, in: visible)
        if reducedMotion || !animated {
            panel?.setFrame(rect, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
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
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.mode == .listening else { return }
            for i in self.levels.indices {
                self.levels[i] += (self.incoming[i] - self.levels[i]) * (self.incoming[i] > self.levels[i] ? 0.65 : 0.3)
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
        // Leave enough transparent space for the system's optical edge.
        let root = NSView()
        let material: NSView
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 24
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
        effect.layer?.cornerRadius = 24
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
    static let height: CGFloat = 48
    private static let padding: CGFloat = 18
    private static let indicatorSize: CGFloat = 16
    private static let spacing: CGFloat = 8
    private static let maximumWidth: CGFloat = 480
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    fileprivate let waveform = WaveformView()
    let label = NSTextField(labelWithString: "")
    private let start = NSButton()
    private let recordingSurface = NSButton()
    private let status = NSImageView()
    private let progress = ProgressGlyphView()
    private var mode: FlowBarMode = .idle

    var preferredSize: NSSize {
        let width: CGFloat
        switch mode {
        case .hidden, .idle, .success: width = Self.height
        case .listening: width = 152
        case .working, .failed:
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
        for view in [waveform, label, status, progress] {
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
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func startAction() { onStart?() }
    @objc private func stopAction() { onStop?() }

    func apply(_ mode: FlowBarMode, animated: Bool = false) {
        let previous = self.mode
        self.mode = mode
        for view in subviews {
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
            setAccessibilityLabel("Listening")
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
                    dissolve.duration = 0.22
                    waveform.layer?.add(dissolve, forKey: "dissolve")
                }
                fadeIn(progress, delay: 0.08)
            }
        case .success:
            progress.isHidden = false
            progress.completeIntoCheck(animated: animated)
            setAccessibilityLabel("Dictation complete")
        case .failed(let message):
            status.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)
            status.contentTintColor = .systemOrange
            status.isHidden = false
            showMessage(message)
            if animated {
                fadeIn(status, delay: 0.24)
                fadeIn(label, delay: 0.32)
            }
        }
        needsLayout = true
    }

    func showWorkingMessage(_ message: String, animated: Bool = false) {
        guard mode == .working else { return }
        showMessage(message)
        if animated { fadeIn(label, delay: 0.32) }
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
        needsLayout = true
    }

    private func fadeIn(_ view: NSView, delay: TimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        view.layer?.add(fade, forKey: "appear")
    }

    override func layout() {
        super.layout()
        start.frame = NSRect(x: (bounds.width - 36) / 2, y: (bounds.height - 36) / 2, width: 36, height: 36)
        recordingSurface.frame = bounds
        waveform.frame = NSRect(x: 18, y: 12, width: max(0, bounds.width - 36), height: bounds.height - 24)
        let indicatorFrame = NSRect(x: Self.padding, y: (bounds.height - Self.indicatorSize) / 2,
                                    width: Self.indicatorSize, height: Self.indicatorSize)
        progress.frame = label.isHidden
            ? NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
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
        ring.frame = bounds
        check.frame = bounds
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
        grow.duration = 0.3
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
        let angle = (ring.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let partial = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAllAnimations()
        check.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = partial
        close.toValue = 1
        close.duration = 0.2
        close.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 1
        if animated { ring.add(close, forKey: "close") }

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.26
        draw.beginTime = CACurrentMediaTime() + 0.14
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
