//
//  PoolPowerMeter.swift
//  How hard to hit: a tall glass capsule at the left of the table.
//
//  Press anywhere on it and pull down, the way the cue is drawn back — the
//  further, the harder — and let go to shoot. Pull back up to where you
//  started and let go, or press Escape, and nothing happens. At rest it
//  shows, faintly, the strength Shoot and Return will use: the last one
//  played, or one set with ↑ and ↓.
//

import AppKit

final class PoolPowerMeter: NSView {

    /// The strength at rest, 0…1.
    var armedPower: Double = 0.55 { didSet { if armedPower != oldValue { face.needsDisplay = true; updateAccessibility() } } }
    /// The strength being pulled right now, or nil when nobody is pulling.
    var chargingPower: Double? { didSet { if chargingPower != oldValue { face.needsDisplay = true; updateAccessibility() } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { face.needsDisplay = true; alphaValue = isEnabled ? 1 : 0.55 } } }

    /// VoiceOver moved the armed strength; returns whether the game took it
    /// (not while it is not the player's turn).
    var onArmedChange: ((Double) -> Bool)?
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    /// `true` to shoot at the strength reached, `false` when called off.
    var onEnd: ((Bool) -> Void)?

    static let size = CGSize(width: 50, height: 264)

    private let panel = GlassPanel(capsule: true)
    private let face = PoolPowerMeterFace()
    private var pressY: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: CGRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        panel.frame = bounds
        addSubview(panel)
        face.meter = self
        face.autoresizingMask = [.width, .height]
        face.frame = bounds
        addSubview(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(NSLocalizedString("Power", comment: "accessibility: pool shot strength"))
        updateAccessibility()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    /// The track the fill runs down, in the meter's coordinates.
    var track: CGRect { CGRect(x: (bounds.width - 12) / 2, y: 22, width: 12, height: bounds.height - 60) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressY = convert(event.locationInWindow, from: nil).y
        chargingPower = 0
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let pressY else { return }
        let y = convert(event.locationInWindow, from: nil).y
        // A pull a little longer than the track reaches full strength, so it
        // can be had from a press anywhere on the meter.
        let power = max(0, min(1, Double((y - pressY) / (track.height * 0.9))))
        chargingPower = power
        onChange?(power)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressY != nil else { return }
        pressY = nil
        let power = chargingPower ?? 0
        chargingPower = nil
        onEnd?(power > 0.02)
    }

    /// Calls a pull off from outside — Escape, a new game.
    func cancel() {
        guard pressY != nil || chargingPower != nil else { return }
        pressY = nil
        chargingPower = nil
    }

    private func updateAccessibility() {
        let value = Int(((chargingPower ?? armedPower) * 100).rounded())
        setAccessibilityValue(Plural.format(value, one: NSLocalizedString("%d percent", comment: "accessibility: pool power, one"),
                                            other: NSLocalizedString("%d percent", comment: "accessibility: pool power, many")))
    }

    override func accessibilityPerformIncrement() -> Bool { stepArmed(by: 0.05) }
    override func accessibilityPerformDecrement() -> Bool { stepArmed(by: -0.05) }

    /// VoiceOver's step: the shot's strength, not only what the meter shows.
    private func stepArmed(by step: Double) -> Bool {
        guard isEnabled, chargingPower == nil else { return false }
        let power = max(0.02, min(1, armedPower + step))
        guard onArmedChange?(power) == true else { return false }
        armedPower = power
        return true
    }
}

/// The meter's markings and fill, over its glass.
final class PoolPowerMeterFace: NSView {
    weak var meter: PoolPowerMeter?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let meter, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let track = meter.track
        // The groove.
        let groove = ContinuousShape.capsule(track)
        ctx.addPath(groove)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.30).cgColor)
        ctx.fillPath()
        AppleStyle.innerShadow(groove, in: track, context: ctx, color: NSColor(white: 0, alpha: 0.5),
                               radius: 2, offset: CGSize(width: 0, height: 1))
        // Quarter marks.
        for k in 1...3 {
            let y = track.minY + track.height * CGFloat(k) / 4
            ctx.setFillColor(Palette.textQuaternary.cgColor)
            ctx.fill(CGRect(x: track.maxX + 5, y: y - 0.5, width: 5, height: 1))
            ctx.fill(CGRect(x: track.minX - 10, y: y - 0.5, width: 5, height: 1))
        }
        // The fill runs down from the top as the cue is drawn back.
        let charging = meter.chargingPower
        let power = CGFloat(charging ?? meter.armedPower)
        if power > 0.001 {
            let fill = CGRect(x: track.minX, y: track.minY, width: track.width, height: max(track.width, track.height * power))
            let path = ContinuousShape.capsule(fill)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            // At rest the armed strength shows plainly but quietly; pulled,
            // it lights up.
            let strong = charging != nil
            AppleStyle.fillVertical(fill, context: ctx, [
                (NSColor(white: 1, alpha: strong ? 0.95 : 0.62), 0),
                (strong ? Palette.accentSoft.withAlphaComponent(0.95) : NSColor(white: 1, alpha: 0.46), 1),
            ])
            ctx.restoreGState()
        }
        // Which way to pull, over the track.
        if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
            let tinted = NSImage(size: arrow.size, flipped: false) { rect in
                arrow.draw(in: rect)
                (charging != nil ? Palette.textPrimary : Palette.textTertiary).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let size = arrow.size
            tinted.draw(in: CGRect(x: (bounds.width - size.width) / 2, y: (track.minY - size.height) / 2 + 1,
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // The number underneath.
        let text = "\(Int((power * 100).rounded()))" as NSString
        let attributes = Typography.attributes(Typography.number(12, weight: .semibold),
                                               charging != nil ? Palette.textPrimary : Palette.textSecondary,
                                               alignment: .center)
        let size = text.size(withAttributes: attributes)
        text.draw(in: CGRect(x: 0, y: bounds.height - 30, width: bounds.width, height: size.height),
                  withAttributes: attributes)
    }
}
