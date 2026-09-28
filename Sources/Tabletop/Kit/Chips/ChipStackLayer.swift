//
//  ChipStackLayer.swift
//  An amount of chips on the table: a bet in front of a seat, the pot, a
//  player's bankroll.
//
//  Give it an amount and it breaks it into the fewest chips, stands them in
//  neat stacks — biggest denomination on the left, at most
//  `maximumChipsPerStack` high before a second stack of the same colour
//  starts — and puts the amount itself in a small capsule underneath.
//
//  The layer's `position` is where the stacks meet the cloth, at their
//  centre: put it on a bet circle and the chips stand on the circle. The
//  capsule hangs below that point. Everything is drawn into one bitmap per
//  amount and size, so a stack costs one composited layer however many chips
//  are in it; a change of amount crossfades from the old picture to the new.
//
//  It is drawn at `contentsScale`, which starts at the main screen's backing
//  scale. Add it to a table with `CardTableView.addTableLayer(_:z:)`, which
//  sets the scale from the table's window and keeps it right when the window
//  moves to another display; z below zero puts it on the cloth under the
//  cards.
//

import AppKit
import QuartzCore

final class ChipStackLayer: CALayer {

    /// The amount shown. Set it through `setAmount(_:animated:)`.
    private(set) var amount: Int = 0

    /// One chip, across.
    var chipDiameter: CGFloat = 34 {
        didSet { if chipDiameter != oldValue { redraw() } }
    }

    /// The amount in a capsule under the chips.
    var showsLabel = true {
        didSet { if showsLabel != oldValue { redraw() } }
    }

    /// How high one stack goes before the next one starts. Ten is how a
    /// dealer counts them.
    var maximumChipsPerStack = 10 {
        didSet { if maximumChipsPerStack != oldValue { redraw() } }
    }

    /// Stacks side by side, never more: an amount that would need more is
    /// drawn with the smallest chips left off the right-hand end (the label
    /// still says the true amount).
    var maximumStacks = 6 {
        didSet { if maximumStacks != oldValue { redraw() } }
    }

    override init() {
        super.init()
        contentsGravity = .center
        needsDisplayOnBoundsChange = false
        // A new CALayer draws at 1×, which on a Retina display (and in every
        // @2x screenshot) turns the chips' printing to mush.
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        if let other = layer as? ChipStackLayer {
            amount = other.amount
            chipDiameter = other.chipDiameter
            showsLabel = other.showsLabel
            maximumChipsPerStack = other.maximumChipsPerStack
            maximumStacks = other.maximumStacks
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func action(forKey event: String) -> CAAction? { nil }

    /// Changes the amount. Animated, the new stacks crossfade in over the
    /// old ones; either way the layer resizes itself around them.
    func setAmount(_ newAmount: Int, animated: Bool = true) {
        let value = max(0, newAmount)
        guard value != amount || contents == nil else { return }
        amount = value
        if animated && MainActor.assumeIsolated({ Motion.isEnabled }) && contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.standard
            fade.timingFunction = Motion.easeOut
            add(fade, forKey: "amount")
        }
        redraw()
    }

    // MARK: Drawing

    /// The stacks an amount turns into, left to right, each listed bottom up.
    static func stacks(for amount: Int, maximumPerStack: Int, maximumStacks: Int) -> [[Int]] {
        var stacks: [[Int]] = []
        for count in Chips.breakdown(amount) {
            var left = count.count
            while left > 0 && stacks.count < maximumStacks {
                let n = min(left, maximumPerStack)
                stacks.append(Array(repeating: count.denomination, count: n))
                left -= n
            }
        }
        return stacks
    }

    private var drawScale: CGFloat {
        max(1, contentsScale)
    }

    private func redraw() {
        let d = chipDiameter
        let r = d / 2
        let stacks = Self.stacks(for: amount, maximumPerStack: maximumChipsPerStack, maximumStacks: maximumStacks)
        let gap = d * 0.10
        let chipsWidth = stacks.isEmpty ? 0 : CGFloat(stacks.count) * d + CGFloat(stacks.count - 1) * gap
        let tallest = stacks.map(\.count).max() ?? 0
        let chipsHeight = ChipRenderer.stackHeight(count: tallest, radius: r)
        let labelText = Chips.format(amount)
        let font = Typography.number(max(10, d * 0.34), weight: .semibold)
        let textSize = (labelText as NSString).size(withAttributes: [.font: font])
        let labelSize = CGSize(width: ceil(textSize.width + d * 0.55), height: ceil(textSize.height + d * 0.14))
        let labelGap = d * 0.16
        let shadowRoom = d * 0.25

        let width = max(chipsWidth + shadowRoom * 2, showsLabel && amount > 0 ? labelSize.width + 4 : 0, 1)
        let below = showsLabel && amount > 0 ? labelGap + labelSize.height + 2 : shadowRoom
        let height = max(1, chipsHeight + shadowRoom + below)
        let baseY = chipsHeight + shadowRoom * 0.6

        let scale = drawScale
        let image = ChipRenderer.render(size: CGSize(width: width, height: height), scale: scale) { ctx in
            var x = (width - chipsWidth) / 2 + r
            for (i, stack) in stacks.enumerated() {
                ChipRenderer.drawStack(stack, base: CGPoint(x: x, y: baseY), radius: r, context: ctx,
                                             seed: UInt64(i * 31 + stack.count))
                x += d + gap
            }
            guard showsLabel && amount > 0 else { return }
            let label = CGRect(x: (width - labelSize.width) / 2, y: baseY + labelGap,
                               width: labelSize.width, height: labelSize.height)
            let path = ContinuousShape.capsule(label)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 0.04, alpha: 0.62).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
            let attributes = Typography.attributes(font, Palette.textPrimary, alignment: .center)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (labelText as NSString).draw(in: CGRect(x: label.minX, y: label.midY - textSize.height / 2,
                                                    width: label.width, height: textSize.height),
                                         withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let oldPosition = position
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // The point where the stacks stand is the anchor, so `position` means
        // "the chips are on this spot" whatever the amount.
        anchorPoint = CGPoint(x: 0.5, y: baseY / height)
        position = oldPosition
        contents = image
        CATransaction.commit()
    }

    /// Redraws at a new backing scale — the window moved to another display.
    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue, amount > 0 { redraw() } }
    }
}

// MARK: - Flights

/// Chips sliding across the table: bets pushed into the pot, the pot pushed
/// to the winner, a payout counted out to a blackjack player.
@MainActor
enum ChipFlight {

    /// Flies `amount`, as up to `maximumChips` real chips, from `from` to `to`
    /// inside `layer` (both points in its coordinates), along a gentle arc,
    /// each chip a beat behind the last. `completion` runs once the last one
    /// has landed and been taken away — which is when the game should update
    /// the stacks at either end. Under Reduce Motion nothing flies and
    /// `completion` runs at once.
    ///
    /// On a `CardTableView`, `layer` is its `tableLayer`; the default
    /// `zPosition` of 5 000 flies the chips over the resting cards and under
    /// any card in flight (see `CardTableView.tableLayer` for the ranges).
    static func fly(amount: Int, from: CGPoint, to: CGPoint, in layer: CALayer, chipDiameter: CGFloat = 30,
                    duration: CFTimeInterval = Motion.chipFlight, stagger: CFTimeInterval = 0.045,
                    maximumChips: Int = 6, zPosition: CGFloat = 5_000, completion: (() -> Void)? = nil) {
        var chips: [Int] = []
        for count in Chips.breakdown(amount) {
            chips.append(contentsOf: Array(repeating: count.denomination, count: count.count))
            if chips.count >= maximumChips { break }
        }
        chips = Array(chips.prefix(maximumChips))
        guard Motion.isEnabled, !chips.isEmpty, hypot(to.x - from.x, to.y - from.y) > 1 else {
            completion?()
            return
        }

        let scale = layer.contentsScale > 0 ? max(layer.contentsScale, 2) : 2
        // The arc bows away from the straight line by a fraction of its
        // length, towards the top of the table: chips are lifted, not dragged.
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let length = hypot(to.x - from.x, to.y - from.y)
        let control = CGPoint(x: mid.x, y: mid.y - length * 0.18)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var flying: [CALayer] = []
        CATransaction.setCompletionBlock {
            flying.forEach { $0.removeFromSuperlayer() }
            completion?()
        }
        let now = CACurrentMediaTime()
        for (i, denomination) in chips.enumerated() {
            guard let image = ChipRenderer.chipImage(denomination, diameter: chipDiameter, scale: scale) else { continue }
            let chip = CALayer()
            chip.contents = image
            chip.contentsScale = scale
            chip.bounds = CGRect(x: 0, y: 0, width: chipDiameter * 1.3, height: chipDiameter * 1.3)
            // Each chip leaves from a slightly different place in the stack.
            let offset = CGFloat(i) * chipDiameter * 0.06
            chip.position = CGPoint(x: to.x, y: to.y - offset)
            chip.zPosition = zPosition + CGFloat(i)
            chip.opacity = 0
            layer.addSublayer(chip)
            flying.append(chip)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: from.x, y: from.y - offset))
            path.addQuadCurve(to: CGPoint(x: to.x, y: to.y - offset), control: control)
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.calculationMode = .paced
            move.timingFunction = Motion.easeInOut

            let appear = CAKeyframeAnimation(keyPath: "opacity")
            appear.values = [0, 1, 1, 0]
            appear.keyTimes = [0, 0.08, 0.9, 1]

            let group = CAAnimationGroup()
            group.animations = [move, appear]
            group.duration = duration
            group.beginTime = now + Double(i) * stagger
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            chip.add(group, forKey: "flight")
        }
        CATransaction.commit()
    }
}
