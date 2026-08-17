import AppKit

enum FlowBarMode: Equatable {
    case hidden
    case idle
    case listening
    case working
    case success
    case failed(String)
}

final class FlowBarController {
    var onIdleTap: (() -> Void)?
    // Where the bar settles after a run: .idle when the user keeps the widget
    // visible, .hidden otherwise.
    var restingMode: FlowBarMode = .hidden

    private var panel: NSPanel?
    private let chrome = FlowBarChrome()
    private(set) var mode: FlowBarMode = .hidden
    private var incoming: [CGFloat] = Array(repeating: 0, count: 18)
    private var bars: [CGFloat] = Array(repeating: 0, count: 18)
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var hugging = false
    private var pendingSuccess = false

    func setMode(_ mode: FlowBarMode) {
        hideWork?.cancel()
        let previous = self.mode
        self.mode = mode
        if mode == .hidden {
            cancelHug()
            stopTimer()
            chrome.resetTransition()
            panel?.orderOut(nil)
            return
        }
        if panel == nil { build() }
        panel?.ignoresMouseEvents = mode != .idle
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()

        switch mode {
        case .listening:
            hugging = false
            pendingSuccess = false
            chrome.freezeLayout = false
            startTimer()
            chrome.apply(mode: mode, bars: bars)
            place(size(for: mode), animated: false)
        case .working:
            stopTimer()
            chrome.beginMorph()
            hugIntoLoader()
        case .success:
            if hugging {
                pendingSuccess = true
            } else {
                finishWithCheck()
            }
        case .idle:
            cancelHug()
            stopTimer()
            chrome.resetTransition()
            chrome.apply(mode: mode, bars: bars)
            place(size(for: mode), animated: previous != .hidden && previous != .idle && previous != .working)
        case .failed(let message):
            cancelHug()
            stopTimer()
            chrome.showFailure(message)
            place(size(for: mode), animated: false)
            restSoon(after: 2.6)
        case .hidden:
            break
        }
    }

    func pushWave(_ samples: [CGFloat]) {
        guard mode == .listening, !samples.isEmpty else { return }
        if samples.count == incoming.count {
            incoming = samples.map { max(0, min(1, $0)) }
        } else {
            incoming = (0..<incoming.count).map { index in
                let mapped = Int(round(Double(index) * Double(samples.count - 1) / Double(incoming.count - 1)))
                return max(0, min(1, samples[mapped]))
            }
        }
    }

    func resetLevels() {
        incoming = Array(repeating: 0, count: 18)
        bars = Array(repeating: 0, count: 18)
        chrome.resetTransition()
    }

    // A quick swell of the working pill: feedback for a hotkey press that
    // arrived while the previous dictation is still transcribing, which used
    // to be swallowed silently.
    func nudge() {
        guard let panel, mode == .working, !hugging else { return }
        let resting = frame(for: size(for: mode))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(resting.insetBy(dx: -4, dy: -4), display: true)
        } completionHandler: { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(self.frame(for: self.size(for: self.mode)), display: true)
            }
        }
    }

    private func hugIntoLoader() {
        guard let panel else { return }
        hugging = true
        pendingSuccess = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.setFrame(frame(for: NSSize(width: 36, height: 36)), display: true, animate: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.hugging = false
            guard self.mode == .working || self.mode == .success || self.pendingSuccess else { return }
            if self.pendingSuccess || self.mode == .success {
                self.finishWithCheck()
            }
        }
    }

    private func cancelHug() {
        hugging = false
        pendingSuccess = false
        if let panel {
            panel.setFrame(panel.frame, display: false, animate: false)
        }
    }

    private func finishWithCheck() {
        pendingSuccess = false
        chrome.completeCheck()
        fadeOut(after: 0.68)
    }

    private func fadeOut(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                if self.mode == .success {
                    self.setMode(self.restingMode)
                    panel.alphaValue = 1
                    self.chrome.resetTransition()
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func restSoon(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setMode(self.restingMode)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard mode == .listening else { return }
        for index in 0..<bars.count {
            let target = incoming[index]
            let rising = target > bars[index]
            bars[index] += (target - bars[index]) * (rising ? 0.55 : 0.28)
            if target < 0.05 {
                bars[index] *= 0.82
            }
        }
        chrome.apply(mode: mode, bars: bars)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 118, height: 38),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        chrome.frame = NSRect(x: 0, y: 0, width: 118, height: 38)
        chrome.onIdleTap = { [weak self] in self?.onIdleTap?() }
        panel.contentView = chrome
        self.panel = panel
    }

    private func size(for mode: FlowBarMode) -> NSSize {
        switch mode {
        case .idle, .working, .success:
            return NSSize(width: 36, height: 36)
        case .failed(let message):
            return NSSize(width: FlowBarChrome.failureWidth(for: message), height: 38)
        default:
            return NSSize(width: 118, height: 38)
        }
    }

    private func frame(for size: NSSize) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + 22,
            width: size.width,
            height: size.height
        )
    }

    private func place(_ size: NSSize, animated: Bool) {
        panel?.setFrame(frame(for: size), display: true, animate: animated)
    }
}

private final class FlowBarChrome: NSView {
    var onIdleTap: (() -> Void)?
    var freezeLayout = false

    static let failureFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    private let idleIcon = NSImageView()
    private let idleWell = NSView()
    private let progress = ProgressGlyphView()
    private let waveform = WaveformView()
    private let failIcon = NSImageView()
    private let failLabel = PassthroughLabel(labelWithString: "")
    private let hover = HoverEngine()
    private var idle = true

    static func failureWidth(for message: String) -> CGFloat {
        let text = (message as NSString).size(withAttributes: [.font: failureFont]).width
        return min(340, max(150, ceil(text) + 62))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hover.onSync = { [weak self] in self?.applyIdleChrome() }
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.overlay.cgColor

        idleWell.wantsLayer = true
        idleIcon.image = Theme.symbol("mic.fill", size: 11)
        idleIcon.contentTintColor = Theme.flowAccent.withAlphaComponent(0.92)
        idleIcon.imageScaling = .scaleNone
        idleWell.addSubview(idleIcon)

        failIcon.image = Theme.symbol("exclamationmark.triangle.fill", size: 11)
        failIcon.contentTintColor = Theme.flowWarn
        failIcon.imageScaling = .scaleNone
        failIcon.isHidden = true
        failLabel.font = Self.failureFont
        failLabel.textColor = Theme.flowAccent.withAlphaComponent(0.92)
        failLabel.lineBreakMode = .byTruncatingTail
        failLabel.isHidden = true

        addSubview(idleWell)
        addSubview(waveform)
        addSubview(progress)
        addSubview(failIcon)
        addSubview(failLabel)
        toolTip = "Start dictation"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Start dictation")

        progress.alphaValue = 0
        waveform.wantsLayer = true
        progress.wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        hover.install(on: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyIdleChrome()
        waveform.needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        guard idle else { return }
        hover.enter()
        applyIdleChrome()
    }

    override func mouseExited(with event: NSEvent) {
        hover.exit()
        applyIdleChrome()
    }

    override func mouseDown(with event: NSEvent) {
        guard idle else { return }
        hover.beginPress()
        applyIdleChrome()
        onIdleTap?()
    }

    override func mouseUp(with event: NSEvent) {
        hover.endPress(inside: true)
        applyIdleChrome()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { idle }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard idle, bounds.contains(point) else { return super.hitTest(point) }
        return self
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        idleWell.frame = bounds.insetBy(dx: 6, dy: 6)
        idleWell.layer?.cornerRadius = min(idleWell.bounds.width, idleWell.bounds.height) / 2
        idleIcon.frame = idleWell.bounds
        positionGlyphs()
        if !freezeLayout {
            waveform.frame = bounds.insetBy(dx: 11, dy: 8)
        }
        failIcon.frame = NSRect(x: 13, y: ((bounds.height - 14) / 2).rounded(), width: 16, height: 14)
        let labelX = failIcon.frame.maxX + 7
        let labelHeight = ceil(failLabel.intrinsicContentSize.height)
        failLabel.frame = NSRect(
            x: labelX,
            y: ((bounds.height - labelHeight) / 2).rounded(),
            width: max(0, bounds.width - labelX - 14),
            height: labelHeight
        )
        applyIdleChrome()
    }

    private func positionGlyphs() {
        let size: CGFloat = 18
        progress.frame = NSRect(
            x: ((bounds.width - size) / 2).rounded(),
            y: ((bounds.height - size) / 2).rounded(),
            width: size,
            height: size
        )
    }

    func apply(mode: FlowBarMode, bars: [CGFloat]) {
        waveform.bars = bars
        switch mode {
        case .hidden, .working, .success, .failed:
            break
        case .idle:
            idle = true
            waveform.alphaValue = 0
            progress.alphaValue = 0
            hideFailure()
            idleWell.isHidden = false
            idleWell.alphaValue = 1
            applyIdleChrome()
        case .listening:
            idle = false
            hover.reset()
            hideFailure()
            idleWell.isHidden = true
            waveform.isHidden = false
            waveform.alphaValue = 1
            progress.alphaValue = 0
            waveform.needsDisplay = true
            applyIdleChrome()
        }
        needsLayout = true
    }

    // The wave dissolves into the spinning ring while the pill contracts
    // around it: one continuous gesture instead of a hard swap.
    func beginMorph() {
        freezeLayout = true
        idle = false
        hover.reset()
        hideFailure()
        idleWell.isHidden = true
        idleWell.alphaValue = 0
        positionGlyphs()
        progress.beginSpinning()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            waveform.animator().alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progress.animator().alphaValue = 1
        }
        applyIdleChrome()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func completeCheck() {
        progress.completeIntoCheck()
    }

    func showFailure(_ message: String) {
        freezeLayout = false
        idle = false
        hover.reset()
        idleWell.isHidden = true
        idleWell.alphaValue = 0
        waveform.alphaValue = 0
        progress.alphaValue = 0
        progress.reset()
        failLabel.stringValue = message
        failIcon.isHidden = false
        failLabel.isHidden = false
        applyIdleChrome()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func hideFailure() {
        failIcon.isHidden = true
        failLabel.isHidden = true
    }

    func resetTransition() {
        freezeLayout = false
        hideFailure()
        waveform.isHidden = false
        waveform.alphaValue = 1
        progress.alphaValue = 0
        progress.reset()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func applyIdleChrome() {
        let fill: NSColor
        let well: CGFloat
        if !idle {
            fill = Theme.overlay
            well = 0.09
        } else if hover.pressed, hover.hovered {
            fill = Theme.overlayPress
            well = 0.22
        } else if hover.hovered {
            fill = Theme.overlayHover
            well = 0.16
        } else {
            fill = Theme.overlay
            well = 0.09
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.chromeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.backgroundColor = Theme.cg(fill, in: self)
        idleWell.layer?.backgroundColor = Theme.cg(Theme.flowAccent.withAlphaComponent(well), in: self)
        idleIcon.contentTintColor = idle && hover.hovered
            ? Theme.flowAccent
            : Theme.flowAccent.withAlphaComponent(0.92)
        CATransaction.commit()
        toolTip = idle ? "Start dictation" : nil
    }
}

private final class WaveformView: NSView {
    var bars: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty else { return }
        let count = bars.count
        let gap: CGFloat = 2.0
        let barW = max(1.8, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        var x: CGFloat = 0
        for raw in bars {
            let h = max(3, bounds.height * raw)
            let y = (bounds.height - h) / 2
            // Louder bars warm up toward the accent; quiet ones stay pale.
            let heat = max(0, min(1, (raw - 0.18) / 0.6))
            let color = Theme.flowWave.blended(withFraction: heat, of: Theme.flowAccent) ?? Theme.flowWave
            color.setFill()
            let path = NSBezierPath(
                roundedRect: NSRect(x: x.rounded(), y: y, width: barW, height: h),
                xRadius: barW / 2,
                yRadius: barW / 2
            )
            path.fill()
            x += barW + gap
        }
    }
}

// A ring that spins while whisper works, closes into a full circle, then
// strokes a checkmark: the tail end of the wave-to-done morph.
private final class ProgressGlyphView: NSView {
    private let ring = CAShapeLayer()
    private let check = CAShapeLayer()
    private var spinning = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [ring, check] {
            shape.fillColor = nil
            shape.strokeColor = Theme.flowAccent.cgColor
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
        let stroke = Theme.cg(Theme.flowAccent, in: self)
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

    func beginSpinning() {
        spinning = true
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
        ring.add(grow, forKey: "grow")

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 0.7
        spin.repeatCount = .infinity
        ring.add(spin, forKey: "spin")
    }

    func completeIntoCheck() {
        // Freeze the spin exactly where it is so the ring closes from its
        // current gap with no visual jump.
        let angle = (ring.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
        let partial = ring.presentation()?.strokeEnd ?? ring.strokeEnd
        ring.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        spinning = false

        let close = CABasicAnimation(keyPath: "strokeEnd")
        close.fromValue = partial
        close.toValue = 1
        close.duration = 0.2
        close.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.strokeEnd = 1
        ring.add(close, forKey: "close")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.26
        draw.beginTime = CACurrentMediaTime() + 0.14
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        draw.fillMode = .backwards
        check.strokeEnd = 1
        check.add(draw, forKey: "draw")
    }

    func reset() {
        spinning = false
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
