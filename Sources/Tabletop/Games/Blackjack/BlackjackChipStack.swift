//
//  BlackjackChipStack.swift
//  Chips on the blackjack cloth — a bet, a payout, an insurance — to the
//  half chip.
//
//  The kit's `ChipStackLayer` counts whole chips; this table pays three to
//  two exactly, so a 37½ payout has to be seen as well as said. This is the
//  same stack, drawn with the kit's chip renderer and anchored the same way
//  (`position` is where the chips meet the cloth), with three differences:
//
//    * An odd half chip is a silver half piece lying beside the chips — how
//      a casino pays a half it has no chip for.
//    * The chips are cut a little thicker. At the size this table draws
//      them the kit's edges are two points apart, and two chips of a kind
//      read as one.
//    * A stack can stand as one mixed column, the biggest chip at the
//      bottom, the way a player stacks a bet. Split hands' bets and payouts
//      stand like that, so four hands of them fit side by side.
//
//  The capsule under the chips says the amount, or for winnings the amount
//  won ("+150"), so a payout beside a bet cannot be misread as more of the bet.
//

import AppKit
import QuartzCore

final class BlackjackChipStack: CALayer {

    /// What the capsule under the chips says.
    enum Label: Equatable {
        case none
        /// The amount: a bet.
        case amount
        /// The amount as a gain, "+150": winnings.
        case gain
    }

    private(set) var amount = BlackjackAmount.zero

    var chipDiameter: CGFloat = 30 {
        didSet { if chipDiameter != oldValue { redraw() } }
    }

    var label = Label.amount {
        didSet { if label != oldValue { redraw() } }
    }

    /// One mixed column rather than a column per colour.
    var isMixed = false {
        didSet { if isMixed != oldValue { redraw() } }
    }

    /// A column's height before the next starts: how a dealer counts them.
    static let chipsPerColumn = 10
    static let maximumColumns = 6
    /// A chip's edge, as a share of its radius (the kit's is 0.17).
    private static let thickness: CGFloat = 0.23
    /// The half piece's radius, as a share of a chip's.
    private static let halfRadius: CGFloat = 0.62

    override init() {
        super.init()
        contentsGravity = .center
        needsDisplayOnBoundsChange = false
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        if let other = layer as? BlackjackChipStack {
            amount = other.amount
            chipDiameter = other.chipDiameter
            label = other.label
            isMixed = other.isMixed
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func action(forKey event: String) -> CAAction? { nil }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue, amount > .zero { redraw() } }
    }

    /// Stands the chips in one mixed column or a column per colour;
    /// animated, the one crossfades into the other.
    func setMixed(_ mixed: Bool, animated: Bool) {
        guard mixed != isMixed else { return }
        if animated && MainActor.assumeIsolated({ Motion.isEnabled }) && contents != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.standard
            fade.timingFunction = Motion.easeOut
            add(fade, forKey: "arrangement")
        }
        isMixed = mixed
    }

    /// Changes the amount; animated, the new chips crossfade in.
    func setAmount(_ newAmount: BlackjackAmount, animated: Bool) {
        let value = max(.zero, newAmount)
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

    // MARK: Measuring

    /// The columns `amount` stands in, left to right, each listed bottom up.
    static func columns(for amount: BlackjackAmount, mixed: Bool) -> [[Int]] {
        let breakdown = Chips.breakdown(amount.wholeChips)
        var columns: [[Int]] = []
        if mixed {
            // Biggest at the bottom, as a bet is stacked.
            let chips = breakdown.flatMap { Array(repeating: $0.denomination, count: $0.count) }
            var start = 0
            while start < chips.count && columns.count < maximumColumns {
                columns.append(Array(chips[start ..< min(chips.count, start + chipsPerColumn)]))
                start += chipsPerColumn
            }
        } else {
            for count in breakdown {
                var left = count.count
                while left > 0 && columns.count < maximumColumns {
                    let n = min(left, chipsPerColumn)
                    columns.append(Array(repeating: count.denomination, count: n))
                    left -= n
                }
            }
        }
        return columns
    }

    /// How wide `amount`'s chips stand, the half piece included.
    static func chipsWidth(of amount: BlackjackAmount, diameter d: CGFloat, mixed: Bool) -> CGFloat {
        let n = CGFloat(columns(for: amount, mixed: mixed).count)
        var width = n > 0 ? n * d + (n - 1) * d * 0.10 : 0
        if amount.hasHalf { width += (n > 0 ? d * 0.10 : 0) + d * halfRadius }
        return width
    }

    /// How wide the capsule under `amount` is.
    static func labelWidth(of amount: BlackjackAmount, diameter d: CGFloat, label: Label) -> CGFloat {
        guard label != .none, amount > .zero else { return 0 }
        return labelSize(text(of: amount, label: label), diameter: d).width
    }

    /// How far below `position` the capsule's bottom edge is.
    static func labelDrop(diameter d: CGFloat) -> CGFloat {
        d * 0.16 + labelSize("0", diameter: d).height + 2
    }

    private static func text(of amount: BlackjackAmount, label: Label) -> String {
        label == .gain ? amount.formattedChange : amount.formatted
    }

    private static func font(_ d: CGFloat) -> NSFont {
        Typography.number(max(10, d * 0.34), weight: .semibold)
    }

    private static func labelSize(_ text: String, diameter d: CGFloat) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font(d)])
        return CGSize(width: ceil(size.width + d * 0.55), height: ceil(size.height + d * 0.14))
    }

    // MARK: Drawing

    private func redraw() {
        let d = chipDiameter
        let r = d / 2
        let k = ChipRenderer.squash
        let t = r * Self.thickness
        let columns = Self.columns(for: amount, mixed: isMixed)
        let gap = d * 0.10
        let chipsWidth = Self.chipsWidth(of: amount, diameter: d, mixed: isMixed)
        let tallest = columns.map(\.count).max() ?? 0
        let chipsHeight = max(tallest > 0 ? 2 * k * r + CGFloat(tallest) * t : 0,
                              amount.hasHalf ? 2 * k * r * Self.halfRadius + t : 0)
        let shows = label != .none && amount > .zero
        let text = Self.text(of: amount, label: label)
        let labelSize = Self.labelSize(text, diameter: d)
        let labelGap = d * 0.16
        let shadowRoom = d * 0.25

        let width = max(chipsWidth + shadowRoom * 2, shows ? labelSize.width + 4 : 0, 1)
        let below = shows ? labelGap + labelSize.height + 2 : shadowRoom
        let height = max(1, chipsHeight + shadowRoom + below)
        let baseY = chipsHeight + shadowRoom * 0.6
        let hasHalf = amount.hasHalf

        let image = ChipRenderer.render(size: CGSize(width: width, height: height), scale: max(1, contentsScale)) { ctx in
            var x = (width - chipsWidth) / 2 + r
            for (i, column) in columns.enumerated() {
                Self.drawColumn(column, base: CGPoint(x: x, y: baseY), radius: r, thickness: t, context: ctx,
                                seed: UInt64(i * 31 + column.count))
                x += d + gap
            }
            if hasHalf {
                let rc = r * Self.halfRadius
                let cx = columns.isEmpty ? width / 2 : x - d - gap + r + gap + rc
                Self.drawHalf(base: CGPoint(x: cx, y: baseY), radius: rc, context: ctx)
            }
            guard shows else { return }
            let capsule = CGRect(x: (width - labelSize.width) / 2, y: baseY + labelGap,
                                 width: labelSize.width, height: labelSize.height)
            let path = ContinuousShape.capsule(capsule)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 0.04, alpha: 0.62).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
            let font = Self.font(d)
            let textHeight = (text as NSString).size(withAttributes: [.font: font]).height
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (text as NSString).draw(in: CGRect(x: capsule.minX, y: capsule.midY - textHeight / 2,
                                               width: capsule.width, height: textHeight),
                                    withAttributes: Typography.attributes(font, Palette.textPrimary, alignment: .center))
            NSGraphicsContext.restoreGraphicsState()
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let oldPosition = position
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // `position` stays "the chips are on this spot", whatever the amount.
        anchorPoint = CGPoint(x: 0.5, y: baseY / height)
        position = oldPosition
        contents = image
        CATransaction.commit()
    }

    /// One column standing on `base`, drawn chip by chip with the kit's
    /// renderer: its shadow, then each chip's edge and face, bottom up.
    private static func drawColumn(_ chips: [Int], base: CGPoint, radius r: CGFloat, thickness t: CGFloat,
                                   context ctx: CGContext, seed: UInt64) {
        let k = ChipRenderer.squash
        drawPool(under: base, radius: r, context: ctx)
        var rng = DeterministicRNG(seed: 0xC41B_5EED &+ seed)
        for (i, denomination) in chips.enumerated() {
            // Stacked by hand: never quite true, which also shows each rim.
            let jitter = (CGFloat(rng.next(upperBound: 100)) / 100 - 0.5) * r * 0.08
            let turn = CGFloat(rng.next(upperBound: 628)) / 100
            let center = CGPoint(x: base.x + jitter, y: base.y - k * r - t - CGFloat(i) * t)
            ChipRenderer.drawEdge(denomination, center: center, radius: r, squash: k, thickness: t, turn: turn, context: ctx)
            ChipRenderer.drawFace(denomination, center: center, radius: r, squash: k, turn: turn, context: ctx)
        }
    }

    /// A soft pool of shadow under something standing on the cloth, pushed
    /// down and right, away from the lamp.
    private static func drawPool(under base: CGPoint, radius r: CGFloat, context ctx: CGContext) {
        let k = ChipRenderer.squash
        ctx.saveGState()
        ctx.translateBy(x: base.x + r * 0.10, y: base.y - k * r + r * 0.10)
        ctx.scaleBy(x: 1, y: k)
        if let g = AppleStyle.gradient([(NSColor(white: 0, alpha: 0.55), 0), (NSColor(white: 0, alpha: 0.30), 0.62),
                                        (NSColor(white: 0, alpha: 0), 1)]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 1.28, options: [])
        }
        ctx.restoreGState()
    }

    /// The half piece: a silver coin lying flat, lit from above left, "½"
    /// struck in the middle.
    private static func drawHalf(base: CGPoint, radius r: CGFloat, context ctx: CGContext) {
        let k = ChipRenderer.squash
        let t = r * 0.16
        drawPool(under: base, radius: r, context: ctx)
        let center = CGPoint(x: base.x, y: base.y - k * r - t)
        let face = CGRect(x: center.x - r, y: center.y - k * r, width: r * 2, height: r * 2 * k)

        // The milled edge, below the face.
        let edge = CGMutablePath()
        edge.addEllipse(in: face.offsetBy(dx: 0, dy: t))
        edge.addRect(CGRect(x: face.minX, y: center.y, width: face.width, height: t))
        ctx.saveGState()
        ctx.addPath(edge)
        ctx.clip()
        if let g = AppleStyle.gradient([(NSColor(white: 0.78, alpha: 1), 0), (NSColor(white: 0.52, alpha: 1), 0.55),
                                        (NSColor(white: 0.30, alpha: 1), 1)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: face.minX, y: 0), end: CGPoint(x: face.maxX, y: 0), options: [])
        }
        ctx.restoreGState()

        // The face: bright where the lamp catches it, greyer away from it.
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        if let g = AppleStyle.gradient([(NSColor(white: 0.98, alpha: 1), 0), (NSColor(white: 0.82, alpha: 1), 0.45),
                                        (NSColor(white: 0.60, alpha: 1), 1)]) {
            let light = CGPoint(x: center.x - r * 0.40, y: center.y - k * r * 0.45)
            ctx.drawRadialGradient(g, startCenter: light, startRadius: 0, endCenter: light, endRadius: r * 1.7,
                                   options: [.drawsAfterEndLocation])
        }
        // The raised rim.
        let rim = face.insetBy(dx: r * 0.13, dy: r * 0.13 * k)
        ctx.addEllipse(in: rim.offsetBy(dx: 0, dy: 0.5))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokePath()
        ctx.addEllipse(in: rim)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.22).cgColor)
        ctx.setLineWidth(0.7)
        ctx.strokePath()

        // "½", struck: foreshortened with the face so it lies flat.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: k)
        let font = Typography.rounded(r * 1.02, weight: .bold)
        let glyph = "\u{00BD}" as NSString
        let size = glyph.size(withAttributes: [.font: font])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        glyph.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2 + 0.6),
                   withAttributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.6)])
        glyph.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2),
                   withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.30, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        ctx.addEllipse(in: face)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.setLineWidth(0.6)
        ctx.strokePath()
    }
}
