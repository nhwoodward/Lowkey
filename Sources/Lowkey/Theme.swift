import AppKit

enum AppAppearance: String, CaseIterable, Codable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum Theme {
    // Warm cream and near-black palette. Neutrals stay tinted so nothing
    // reads as flat grey, without a colored brand accent.
    static let paper = dynamic("paper") { dark in
        dark
            ? NSColor(calibratedRed: 0.075, green: 0.070, blue: 0.064, alpha: 1)
            : NSColor(calibratedRed: 0.985, green: 0.973, blue: 0.958, alpha: 1)
    }
    static let sidebar = dynamic("sidebar") { dark in
        dark
            ? NSColor(calibratedRed: 0.098, green: 0.091, blue: 0.084, alpha: 1)
            : NSColor(calibratedRed: 0.962, green: 0.946, blue: 0.926, alpha: 1)
    }
    static let ink = NSColor.labelColor
    static let inkMuted = NSColor.secondaryLabelColor
    static let inkFaint = NSColor.tertiaryLabelColor
    static let fillHover = dynamic("fillHover") { dark in
        dark
            ? NSColor(calibratedRed: 1, green: 0.94, blue: 0.9, alpha: 0.08)
            : NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.09, alpha: 0.06)
    }
    static let fillPress = dynamic("fillPress") { dark in
        dark
            ? NSColor(calibratedRed: 1, green: 0.94, blue: 0.9, alpha: 0.14)
            : NSColor(calibratedRed: 0.28, green: 0.16, blue: 0.09, alpha: 0.11)
    }
    static let fillSelected = dynamic("fillSelected") { dark in
        dark
            ? NSColor(calibratedRed: 0.168, green: 0.155, blue: 0.143, alpha: 1)
            : NSColor(calibratedRed: 0.999, green: 0.995, blue: 0.988, alpha: 1)
    }
    static let fillSelectedPress = dynamic("fillSelectedPress") { dark in
        dark
            ? NSColor(calibratedRed: 0.138, green: 0.127, blue: 0.117, alpha: 1)
            : NSColor(calibratedRed: 0.955, green: 0.938, blue: 0.915, alpha: 1)
    }
    static let card = dynamic("card") { dark in
        dark
            ? NSColor(calibratedRed: 0.118, green: 0.109, blue: 0.100, alpha: 1)
            : NSColor(calibratedRed: 0.998, green: 0.993, blue: 0.985, alpha: 1)
    }
    static let cardHover = dynamic("cardHover") { dark in
        dark
            ? NSColor(calibratedRed: 0.148, green: 0.137, blue: 0.126, alpha: 1)
            : NSColor(calibratedRed: 0.992, green: 0.981, blue: 0.964, alpha: 1)
    }
    static let cardSelected = dynamic("cardSelected") { dark in
        dark
            ? NSColor(calibratedRed: 0.178, green: 0.165, blue: 0.152, alpha: 1)
            : NSColor(calibratedRed: 0.958, green: 0.946, blue: 0.928, alpha: 1)
    }
    static let rule = dynamic("rule") { dark in
        dark
            ? NSColor(calibratedRed: 1, green: 0.93, blue: 0.88, alpha: 0.10)
            : NSColor(calibratedRed: 0.3, green: 0.18, blue: 0.1, alpha: 0.09)
    }
    static let ruleStrong = dynamic("ruleStrong") { dark in
        dark
            ? NSColor(calibratedRed: 1, green: 0.93, blue: 0.88, alpha: 0.17)
            : NSColor(calibratedRed: 0.3, green: 0.18, blue: 0.1, alpha: 0.16)
    }
    // Monochrome "brand": ink-leaning in light mode, cream-leaning in dark.
    // Everything custom-drawn stays in the black-and-cream family; native
    // controls keep the system accent.
    static let brand = dynamic("brand") { dark in
        dark
            ? NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.89, alpha: 1)
            : NSColor(calibratedRed: 0.30, green: 0.27, blue: 0.24, alpha: 1)
    }
    static let brandDeep = dynamic("brandDeep") { dark in
        dark
            ? NSColor(calibratedRed: 0.82, green: 0.79, blue: 0.75, alpha: 1)
            : NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.12, alpha: 1)
    }
    static let heroTop = dynamic("heroTop") { dark in
        dark
            ? NSColor(calibratedRed: 0.128, green: 0.119, blue: 0.110, alpha: 1)
            : NSColor(calibratedRed: 0.992, green: 0.985, blue: 0.974, alpha: 1)
    }
    static let heroBottom = dynamic("heroBottom") { dark in
        dark
            ? NSColor(calibratedRed: 0.168, green: 0.156, blue: 0.143, alpha: 1)
            : NSColor(calibratedRed: 0.962, green: 0.946, blue: 0.922, alpha: 1)
    }
    static let accent = NSColor.controlAccentColor
    static let danger = NSColor.systemRed
    static let success = NSColor.systemGreen
    // Flow bar glass follows the active appearance: cream glass in light,
    // near-black glass in dark.
    static let overlay = dynamic("overlay") { dark in
        dark
            ? NSColor(calibratedRed: 0.075, green: 0.068, blue: 0.061, alpha: 0.95)
            : NSColor(calibratedRed: 0.99, green: 0.984, blue: 0.972, alpha: 0.97)
    }
    static let overlayHover = dynamic("overlayHover") { dark in
        dark
            ? NSColor(calibratedRed: 0.13, green: 0.118, blue: 0.107, alpha: 0.96)
            : NSColor(calibratedRed: 0.955, green: 0.945, blue: 0.928, alpha: 0.98)
    }
    static let overlayPress = dynamic("overlayPress") { dark in
        dark
            ? NSColor(calibratedRed: 0.19, green: 0.172, blue: 0.156, alpha: 0.98)
            : NSColor(calibratedRed: 0.918, green: 0.905, blue: 0.885, alpha: 0.98)
    }
    static let flowAccent = dynamic("flowAccent") { dark in
        dark
            ? NSColor(calibratedRed: 0.97, green: 0.955, blue: 0.93, alpha: 1)
            : NSColor(calibratedRed: 0.24, green: 0.215, blue: 0.19, alpha: 1)
    }
    static let flowWave = dynamic("flowWave") { dark in
        dark
            ? NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.94, alpha: 0.8)
            : NSColor(calibratedRed: 0.30, green: 0.27, blue: 0.24, alpha: 0.85)
    }
    static let flowWarn = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.35, alpha: 1)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space7: CGFloat = 28

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12
    static let radiusXl: CGFloat = 16

    static let navHeight: CGFloat = 34
    static let iconHit: CGFloat = 28
    static let pillHeight: CGFloat = 28
    static let fieldHeight: CGFloat = 28
    static let rowMinHeight: CGFloat = 60
    static let historyRowHeight: CGFloat = 90
    static let sidebarWidth: CGFloat = 188
    static let mainSidebarWidth: CGFloat = 212

    static let chromeDuration: CFTimeInterval = 0.12

    static func cg(_ color: NSColor, in view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // SF Rounded for brand and headings: friendly without being childish.
    static func display(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return rounded
    }

    private static func dynamic(_ name: String, _ pick: @escaping (Bool) -> NSColor) -> NSColor {
        NSColor(name: "lowkey.\(name)") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? pick(true)
                : pick(false)
        }
    }
}

final class HoverEngine {
    private weak var view: NSView?
    private var area: NSTrackingArea?
    private(set) var hovered = false
    private(set) var pressed = false
    var isEnabled: () -> Bool = { true }
    // Fired when install() corrects a hover state that no longer matches the
    // real pointer position (e.g. tracking established before a window moved).
    var onSync: (() -> Void)?

    func install(on view: NSView) {
        if let area { view.removeTrackingArea(area) }
        self.view = view
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: view,
            userInfo: nil
        )
        area = next
        view.addTrackingArea(next)
        let inside: Bool
        if let window = view.window, window.isVisible {
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            inside = view.bounds.contains(point) && isEnabled()
        } else {
            inside = false
        }
        if hovered != inside {
            hovered = inside
            if !inside { pressed = false }
            onSync?()
        }
    }

    func enter() {
        guard isEnabled() else { return }
        hovered = true
    }

    func exit() {
        hovered = false
    }

    func beginPress() {
        guard isEnabled() else { return }
        pressed = true
        hovered = true
    }

    func drag(inside: Bool) {
        hovered = inside
    }

    @discardableResult
    func endPress(inside: Bool) -> Bool {
        pressed = false
        hovered = inside
        return inside && isEnabled()
    }

    func reset() {
        hovered = false
        pressed = false
    }
}

enum Chrome {
    static func paint(_ view: NSView, fill: NSColor, border: NSColor, radius: CGFloat, borderWidth: CGFloat = 1, animated: Bool) {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.borderWidth = borderWidth
        let fillColor = Theme.cg(fill, in: view)
        let borderColor = Theme.cg(border, in: view)
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Theme.chromeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            view.layer?.backgroundColor = fillColor
            view.layer?.borderColor = borderColor
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.backgroundColor = fillColor
            view.layer?.borderColor = borderColor
            CATransaction.commit()
        }
    }

}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// Apple's hitTest contract: `point` is in the receiver's superview.
// Several views used to convert into the child's space and then call
// hitTest, so clicks missed while tracking-area hover still fired.
enum HitTesting {
    static func deep(_ view: NSView, point: NSPoint, fallback: NSView?) -> NSView? {
        guard !view.isHidden, view.alphaValue > 0.01, view.frame.contains(point) else { return nil }
        let local = view.convert(point, from: view.superview)
        for sub in view.subviews.reversed() {
            if let hit = sub.hitTest(local) {
                return hit
            }
        }
        return fallback
    }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        HitTesting.deep(self, point: point, fallback: self)
    }
}

final class ThemedCard: NSView {
    var radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        Chrome.paint(self, fill: Theme.card, border: Theme.rule, radius: radius, borderWidth: 1, animated: false)
    }
}

final class GradientCard: NSView {
    var radius: CGFloat
    private let gradient = CAGradientLayer()

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        layer?.insertSublayer(gradient, at: 0)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.cg(Theme.rule, in: self)
        gradient.colors = [Theme.cg(Theme.heroTop, in: self), Theme.cg(Theme.heroBottom, in: self)]
    }
}

// Decorative, non-interactive waveform in the brand tint.
final class WaveMotifView: NSView {
    private let heights: [CGFloat] = [0.30, 0.52, 0.78, 1.0, 0.68, 0.44, 0.62, 0.88, 0.56, 0.34, 0.5, 0.26]

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let count = heights.count
        let gap: CGFloat = 5
        let barW = max(3, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        var x: CGFloat = 0
        for h in heights {
            let height = max(4, bounds.height * h)
            let y = (bounds.height - height) / 2
            Theme.brand.withAlphaComponent(0.14 + 0.3 * h).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barW, height: height),
                xRadius: barW / 2,
                yRadius: barW / 2
            ).fill()
            x += barW + gap
        }
    }
}

final class ThemedFillView: NSView {
    var fill: NSColor {
        didSet { paint() }
    }

    init(fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func updateLayer() {
        paint()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        HitTesting.deep(self, point: point, fallback: self)
    }

    private func paint() {
        wantsLayer = true
        layer?.backgroundColor = Theme.cg(fill, in: self)
    }
}

final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
