//
//  ChipRackView.swift
//  A row of chips to bet with: click a chip to put one on the table.
//
//  How a blackjack bet is built — a 100, a 25, another 25 — rather than
//  dialled in with a slider. One chip of each denomination the table uses,
//  lying side by side; each is a button. A click picks one (`onPick`), an
//  Option-click or a right-click takes one back (`onRemove`), and chips worth
//  more than the player has left (`available`) grey out and stop answering.
//
//  It is made to ride in an `ActionBar` as its `leadingAccessory` during the
//  betting, with Deal as the bar's primary button — the chips on glass, in
//  the same capsule as every other choice the player makes. It is 44 points
//  tall, taller than a row of buttons, so a bar that carries it only some of
//  the time sets `minimumContentHeight = ChipRackView.height` and the table
//  does not change size as it comes and goes.
//
//  Each chip is a layer holding `ChipRenderer`'s picture, lifted a little
//  under the pointer on a quick spring (and simply lit under Reduce Motion).
//  No sound: the table's chips make the noise, if anything does.
//

import AppKit
import QuartzCore

final class ChipRackView: NSView {

    /// The chips on offer, smallest first.
    let denominations: [Int]

    /// Called with a chip's value when the player clicks it.
    var onPick: ((Int) -> Void)?

    /// Called with a chip's value on an Option-click or a right-click: take
    /// one of those back. Nil to ignore both.
    var onRemove: ((Int) -> Void)?

    /// Chips worth more than this are shown greyed and do nothing — the
    /// player cannot afford them. `Int.max` (the default) for no limit.
    var available: Int = .max {
        didSet { if available != oldValue { refreshStates() } }
    }

    /// The whole rack, on or off — off between hands.
    var isEnabled = true {
        didSet { if isEnabled != oldValue { refreshStates() } }
    }

    static let height: CGFloat = 44
    static let chipDiameter: CGFloat = 34
    private static let gap: CGFloat = 8
    private static let inset: CGFloat = 5

    private var chipLayers: [CALayer] = []
    private var hovered: Int?
    private var pressed: Int?
    private var elements: [ChipRackAccessibilityElement] = []

    init(denominations: [Int] = [5, 25, 100, 500, 1_000]) {
        self.denominations = denominations.sorted()
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 10, height: Self.height)))
        wantsLayer = true
        for _ in self.denominations {
            let chip = CALayer()
            chip.contentsGravity = .resizeAspect
            layer?.addSublayer(chip)
            chipLayers.append(chip)
        }
        frame.size = intrinsicContentSize
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Chips", comment: "accessibility: the rack of chips to bet with"))
        elements = self.denominations.enumerated().map { i, value in
            let element = ChipRackAccessibilityElement()
            element.rack = self
            element.index = i
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(String(format: NSLocalizedString("%@ chip", comment: "accessibility: a chip of this value"),
                                                 Chips.format(value)))
            return element
        }
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(denominations.count)
        return NSSize(width: ceil(n * Self.chipDiameter + max(0, n - 1) * Self.gap + Self.inset * 2),
                      height: Self.height)
    }

    /// Where the chip for `denomination` sits, in the rack's coordinates —
    /// convert it to the table's for a `ChipFlight` from the rack to the
    /// betting circle.
    func chipFrame(for denomination: Int) -> CGRect? {
        guard let i = denominations.firstIndex(of: denomination) else { return nil }
        return frame(ofChip: i)
    }

    /// Whether a chip can be picked right now.
    func isChipEnabled(_ denomination: Int) -> Bool {
        isEnabled && denomination <= available
    }

    /// Picks a chip as if it had been clicked. For keys and tests.
    func pick(_ denomination: Int) {
        guard isChipEnabled(denomination) else { return }
        Haptics.levelChange()
        onPick?(denomination)
    }

    // MARK: Layout and drawing

    private func frame(ofChip i: Int) -> CGRect {
        let d = Self.chipDiameter
        let totalWidth = CGFloat(denominations.count) * d + CGFloat(max(0, denominations.count - 1)) * Self.gap
        let x = (bounds.width - totalWidth) / 2 + CGFloat(i) * (d + Self.gap)
        return CGRect(x: x.rounded(), y: ((bounds.height - d) / 2).rounded(), width: d, height: d)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, chip) in chipLayers.enumerated() {
            let face = frame(ofChip: i)
            // The picture has room round the chip for its shadow.
            let side = face.width * 1.3
            chip.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            chip.position = CGPoint(x: face.midX, y: face.midY)
            if chip.contentsScale != scale || chip.contents == nil {
                chip.contentsScale = scale
                chip.contents = ChipRenderer.chipImage(denominations[i], diameter: face.width, scale: scale)
            }
        }
        CATransaction.commit()
        for (i, element) in elements.enumerated() {
            element.setAccessibilityFrameInParentSpace(frame(ofChip: i))
        }
        refreshStates(animated: false)
    }

    private func refreshStates(animated: Bool = true) {
        for (i, chip) in chipLayers.enumerated() {
            let enabled = isChipEnabled(denominations[i])
            let lifted = enabled && hovered == i && pressed == nil
            let down = enabled && pressed == i
            let dy: CGFloat = lifted ? -2.5 : (down ? 1 : 0)
            let scale: CGFloat = down ? 0.96 : 1
            var transform = CATransform3DMakeTranslation(0, dy, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chip.opacity = enabled ? 1 : 0.32
            CATransaction.commit()
            if animated && Motion.isEnabled {
                Motion.spring(chip, "transform", to: NSValue(caTransform3D: transform), spring: .snappy)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                chip.transform = transform
                CATransaction.commit()
            }
        }
        for (i, element) in elements.enumerated() {
            element.setAccessibilityEnabled(isChipEnabled(denominations[i]))
        }
    }

    // MARK: Mouse

    private func chipIndex(at point: CGPoint) -> Int? {
        for i in denominations.indices {
            let face = frame(ofChip: i)
            let dx = point.x - face.midX, dy = point.y - face.midY
            if dx * dx + dy * dy <= (face.width / 2 + 2) * (face.width / 2 + 2) { return i }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited,
                                                               .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = chipIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hovered else { return }
        hovered = index
        refreshStates()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        pressed = nil
        refreshStates()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = nil; pressed = nil }
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = chipIndex(at: convert(event.locationInWindow, from: nil)),
              isChipEnabled(denominations[i]) else { return }
        pressed = i
        refreshStates()
    }

    override func mouseUp(with event: NSEvent) {
        let released = chipIndex(at: convert(event.locationInWindow, from: nil))
        let was = pressed
        pressed = nil
        refreshStates()
        guard let i = was, released == i else { return }
        if event.modifierFlags.contains(.option), let onRemove {
            onRemove(denominations[i])
        } else {
            pick(denominations[i])
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRemove, let i = chipIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onRemove(denominations[i])
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { elements }

    fileprivate func accessibilityPick(_ index: Int) -> Bool {
        guard let value = denominations[safe: index], isChipEnabled(value) else { return false }
        pick(value)
        return true
    }
}

/// One chip in the rack, for VoiceOver.
final class ChipRackAccessibilityElement: NSAccessibilityElement {
    weak var rack: ChipRackView?
    var index = 0
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { rack?.accessibilityPick(index) ?? false }
    }
}
