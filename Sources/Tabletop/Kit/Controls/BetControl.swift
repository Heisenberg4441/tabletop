//
//  BetControl.swift
//  Choosing how much to bet: a row of quick amounts, a slider, and the amount
//  itself in large rounded figures.
//
//      [ Min ] [ ½ Pot ] [ Pot ] [ All-in ]
//      ━━━━━━━━●─────────────────   1,250
//
//  Built for the action bar's leading accessory, and fine on its own. The
//  amount moves in whole chips (`step`), except that the maximum is always
//  reachable even when it is not a whole number of chips — an all-in of 1,237
//  with 25-chip steps is still 1,237. The presets are the game's: poker wants
//  pot fractions, blackjack wants table limits; each is a title and an amount,
//  replaced whenever the pot changes.
//
//  Keyboard, once the slider has focus (a click on it gives it focus): ← and →
//  step one chip, ⇧← and ⇧→ ten, Home and End go to the ends. A game that
//  wants arrows to reach the bet without a click forwards them to `step(by:)`.
//

import AppKit

final class BetControl: NSView {

    struct Preset {
        var title: String
        var amount: Int
        init(_ title: String, _ amount: Int) {
            self.title = title
            self.amount = amount
        }
    }

    /// The smallest bet allowed. The amount never goes below it.
    var minimum: Int { didSet { clampAndRefresh() } }
    /// The largest — usually the player's whole stack.
    var maximum: Int { didSet { clampAndRefresh() } }
    /// One chip: the amount moves in multiples of this.
    var step: Int { didSet { step = max(1, step); clampAndRefresh() } }

    /// The amount chosen. Setting it does not call `onChange`; only the
    /// player's own changes do.
    var value: Int {
        get { storedValue }
        set { storedValue = snap(newValue); refresh() }
    }

    /// Called with the new amount whenever the player changes it.
    var onChange: ((Int) -> Void)?

    /// The quick amounts above the slider. Out-of-range amounts are clamped
    /// when chosen; a preset whose amount is below the minimum is shown
    /// disabled.
    var presets: [Preset] = [] {
        didSet { rebuildPresets() }
    }

    private var storedValue: Int
    private let slider = BetSlider()
    private let readout = Typography.label("", font: Typography.number(19, weight: .semibold))
    private var presetButtons: [CapsuleButton] = []

    static let width: CGFloat = 340
    static let height: CGFloat = 62

    init(minimum: Int, maximum: Int, step: Int = 1, value: Int? = nil) {
        self.minimum = minimum
        self.maximum = max(minimum, maximum)
        self.step = max(1, step)
        self.storedValue = minimum
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        storedValue = snap(value ?? minimum)

        readout.alignment = .right
        readout.textColor = Palette.textPrimary
        addSubview(slider)
        addSubview(readout)
        slider.control = self
        setAccessibilityElement(false)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    // MARK: Values

    /// The nearest whole-chip amount to `amount`, within the limits — or the
    /// maximum itself, if that is nearer than any whole-chip amount below it.
    func snap(_ amount: Int) -> Int {
        let clamped = min(max(amount, minimum), maximum)
        if clamped == maximum || clamped == minimum { return clamped }
        let stepped = Int((Double(clamped) / Double(step)).rounded()) * step
        return min(max(stepped, minimum), maximum)
    }

    /// Moves the amount by `chips` steps and tells `onChange`. For a game
    /// forwarding arrow keys, and for the slider's own keyboard.
    func step(by chips: Int) {
        guard chips != 0 else { return }
        // From an odd amount (an all-in, a blind), a step goes to the next
        // whole chip in that direction rather than a whole chip further.
        let whole = chips > 0
            ? (storedValue / step) * step
            : ((storedValue + step - 1) / step) * step
        userSet(whole + chips * step)
    }

    fileprivate func userSet(_ amount: Int) {
        let snapped = snap(amount)
        guard snapped != storedValue else { return }
        storedValue = snapped
        refresh()
        Haptics.levelChange()
        onChange?(snapped)
    }

    /// The slider's position, 0...1, for an amount.
    fileprivate func fraction(for amount: Int) -> CGFloat {
        guard maximum > minimum else { return 1 }
        return CGFloat(amount - minimum) / CGFloat(maximum - minimum)
    }

    fileprivate func amount(for fraction: CGFloat) -> Int {
        minimum + Int((CGFloat(maximum - minimum) * min(max(fraction, 0), 1)).rounded())
    }

    private func clampAndRefresh() {
        if maximum < minimum { maximum = minimum }
        storedValue = snap(storedValue)
        rebuildPresets()
        refresh()
    }

    private func refresh() {
        readout.stringValue = Chips.format(storedValue)
        slider.needsDisplay = true
        slider.setAccessibilityValue(Chips.format(storedValue))
        for (button, preset) in zip(presetButtons, presets) {
            button.isEnabled = preset.amount >= minimum || preset.amount >= maximum
        }
    }

    private func rebuildPresets() {
        presetButtons.forEach { $0.removeFromSuperview() }
        presetButtons = presets.map { preset in
            let button = CapsuleButton(title: preset.title, style: .secondary, size: .small) { [weak self] in
                self?.userSet(preset.amount)
            }
            button.isEnabled = preset.amount >= minimum || preset.amount >= maximum
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let readoutWidth: CGFloat = 86
        let presetHeight: CGFloat = 24
        if presetButtons.isEmpty {
            slider.frame = CGRect(x: 0, y: (bounds.height - 28) / 2, width: bounds.width - readoutWidth - 8, height: 28)
        } else {
            // The presets share the width evenly; small words, equal pills.
            let gap: CGFloat = 6
            let count = CGFloat(presetButtons.count)
            let width = ((bounds.width - readoutWidth - 8) - gap * (count - 1)) / count
            for (i, button) in presetButtons.enumerated() {
                button.frame = CGRect(x: (CGFloat(i) * (width + gap)).rounded(), y: 0,
                                      width: width.rounded(.down), height: presetHeight)
            }
            slider.frame = CGRect(x: 0, y: presetHeight + 6, width: bounds.width - readoutWidth - 8,
                                  height: bounds.height - presetHeight - 6)
        }
        let size = readout.intrinsicContentSize
        readout.frame = CGRect(x: bounds.width - readoutWidth, y: slider.frame.midY - size.height / 2,
                               width: readoutWidth, height: size.height)
    }
}

/// The track and the knob. Drawn by hand so it matches the capsules around
/// it: a porcelain fill up to the knob, a quiet track beyond it.
final class BetSlider: NSControl {

    fileprivate weak var control: BetControl?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(NSLocalizedString("Bet", comment: "accessibility: the bet slider"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let knob: CGFloat = 20

    private var track: CGRect {
        let inset = Self.knob / 2
        return CGRect(x: inset, y: bounds.midY - 2, width: max(1, bounds.width - inset * 2), height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let control, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let track = self.track
        let fraction = control.fraction(for: control.value)
        let knobX = track.minX + track.width * fraction

        ctx.addPath(ContinuousShape.capsule(track))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.18).cgColor)
        ctx.fillPath()
        let filled = CGRect(x: track.minX, y: track.minY, width: max(track.height, knobX - track.minX),
                            height: track.height)
        ctx.addPath(ContinuousShape.capsule(filled))
        ctx.setFillColor(Palette.primaryFill.withAlphaComponent(0.92).cgColor)
        ctx.fillPath()

        let knob = CGRect(x: knobX - Self.knob / 2, y: bounds.midY - Self.knob / 2, width: Self.knob, height: Self.knob)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.setFillColor(Palette.primaryFill.cgColor)
        ctx.fillEllipse(in: knob)
        ctx.restoreGState()
        // The lamp on top of the knob.
        ctx.saveGState()
        ctx.addEllipse(in: knob)
        ctx.clip()
        AppleStyle.fillVertical(knob, context: ctx, [(NSColor(white: 1, alpha: 0.6), 0), (NSColor(white: 0, alpha: 0.10), 1)])
        ctx.restoreGState()

        // Focus, the macOS way: a ring round the knob in the system accent.
        if window?.firstResponder === self && window?.isKeyWindow == true {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: knob.insetBy(dx: -2.5, dy: -2.5))
        }
    }

    private func set(from event: NSEvent) {
        guard let control else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let track = self.track
        control.userSet(control.amount(for: (x - track.minX) / track.width))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        set(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        set(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let control else { return super.keyDown(with: event) }
        let big = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 123, 125: control.step(by: -big)          // left, down
        case 124, 126: control.step(by: big)           // right, up
        case 115: control.userSet(control.minimum)     // home
        case 119: control.userSet(control.maximum)     // end
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        control?.step(by: 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        control?.step(by: -1)
        return true
    }
}
