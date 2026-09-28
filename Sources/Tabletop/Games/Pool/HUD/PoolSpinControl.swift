//
//  PoolSpinControl.swift
//  Where the tip meets the cue ball: the ball's face on a disc of glass at
//  the right of the table, with a chalk mark to put where you mean to hit.
//
//  Above centre is follow, below is draw, either side is english. The mark
//  keeps inside the dashed circle — half the ball's radius from the middle,
//  the furthest a tip can strike without miscuing — which is also the whole
//  range the engine's tip offsets describe. Double-click to hit the middle
//  again.
//

import AppKit

final class PoolSpinControl: NSView {

    /// Right english, −1…1.
    private(set) var side: Double = 0
    /// Follow (+) or draw (−), −1…1.
    private(set) var vertical: Double = 0
    var isEnabled = true { didSet { if isEnabled != oldValue { face.needsDisplay = true; alphaValue = isEnabled ? 1 : 0.55 } } }
    var onChange: ((Double, Double) -> Void)?

    static let size = CGSize(width: 108, height: 108)

    private let panel = GlassPanel(capsule: true)
    private let face = PoolSpinFace()

    override init(frame frameRect: NSRect) {
        super.init(frame: CGRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        panel.frame = bounds
        addSubview(panel)
        face.control = self
        face.autoresizingMask = [.width, .height]
        face.frame = bounds
        addSubview(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Spin", comment: "accessibility: where the cue tip hits the cue ball"))
        updateAccessibility()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    /// The drawn ball, and the circle the mark stays in.
    var ballRadius: CGFloat { bounds.width / 2 - 16 }
    var limitRadius: CGFloat { ballRadius * 0.5 }

    func set(side: Double, vertical: Double, notify: Bool = false) {
        var s = side, v = vertical
        let length = (s * s + v * v).squareRoot()
        if length > 1 { s /= length; v /= length }
        guard s != self.side || v != self.vertical else { return }
        self.side = s
        self.vertical = v
        face.needsDisplay = true
        updateAccessibility()
        if notify { onChange?(s, v) }
    }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = Double((p.x - bounds.midX) / limitRadius), dy = Double((bounds.midY - p.y) / limitRadius)
        set(side: dx, vertical: dy, notify: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 { set(side: 0, vertical: 0, notify: true); return }
        track(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        track(event)
    }

    private func updateAccessibility() {
        let value: String
        if abs(side) < 0.05 && abs(vertical) < 0.05 {
            value = NSLocalizedString("Centre ball", comment: "accessibility: no spin")
        } else {
            var parts: [String] = []
            if vertical > 0.05 { parts.append(NSLocalizedString("follow", comment: "accessibility: top spin")) }
            if vertical < -0.05 { parts.append(NSLocalizedString("draw", comment: "accessibility: back spin")) }
            if side > 0.05 { parts.append(NSLocalizedString("right english", comment: "accessibility: side spin")) }
            if side < -0.05 { parts.append(NSLocalizedString("left english", comment: "accessibility: side spin")) }
            value = parts.joined(separator: ", ")
        }
        setAccessibilityValue(value)
    }
}

final class PoolSpinFace: NSView {
    weak var control: PoolSpinControl?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let control, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = control.ballRadius
        // The cue ball, lit like every ball in the collection.
        TableArt.poolBallShadow(center: c, radius: r, away: CGVector(dx: 0.10, dy: 0.05), squash: 0.9, context: ctx)
        TableArt.poolBall(0, center: c, radius: r, context: ctx)
        // Cross hairs and the limit.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.16).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: c.x - r * 0.82, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + r * 0.82, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - r * 0.82))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.82))
        ctx.strokePath()
        let limit = control.limitRadius
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.30).cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - limit, y: c.y - limit, width: limit * 2, height: limit * 2))
        ctx.setLineDash(phase: 0, lengths: [])
        // The chalk mark.
        let m = CGPoint(x: c.x + CGFloat(control.side) * limit, y: c.y - CGFloat(control.vertical) * limit)
        let dot = CGRect(x: m.x - 6.5, y: m.y - 6.5, width: 13, height: 13)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor(white: 0, alpha: 0.4).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 0.22, green: 0.42, blue: 0.70, alpha: 1).cgColor)
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: dot.insetBy(dx: -0.5, dy: -0.5))
    }
}
