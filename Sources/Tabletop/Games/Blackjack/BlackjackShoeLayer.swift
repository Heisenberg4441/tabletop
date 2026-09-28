//
//  BlackjackShoeLayer.swift
//  The dealing shoe at the dealer's left and the discard holder at the
//  dealer's right — the two pieces of casino furniture that say how far
//  through the shoe the table is.
//
//  Both are drawn, not built from card sprites: a six-deck shoe is 312
//  cards, and all the player needs to see of them is how many are left.
//  The shoe is smoked acrylic, seen from above, its cards a block of
//  cream edges that shortens as the round goes on, the top card's back
//  showing in the mouth, and the yellow cut card a sliver in the block
//  until it comes out — then it lies on the cloth beside the shoe until
//  the shuffle. The discard holder is clear acrylic with the played cards
//  squared up inside it, their edges thickening round by round.
//
//  Each is one bitmap, redrawn only when its count changes, lit like
//  everything else from above-left, and each knows the points the table
//  needs: where a card leaves the shoe, where a swept card lands.
//

import AppKit
import QuartzCore

/// The shoe.
final class BlackjackShoeLayer: CALayer {

    /// The shoe's turn on the cloth: its mouth faces down and left, towards
    /// the dealer's hands.
    static let angle: CGFloat = -0.22

    private var key = ""

    override init() {
        super.init()
        contentsGravity = .center
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override func action(forKey event: String) -> CAAction? { nil }

    private var cardSize = CGSize(width: 80, height: 114)

    /// The shoe's length along its axis and its width.
    private var bodySize: CGSize { Self.bodySize(cardSize) }

    static func bodySize(_ cardSize: CGSize) -> CGSize {
        CGSize(width: cardSize.height * 1.52, height: cardSize.width * 1.22)
    }

    /// Where the top card sits, in the shoe's own frame (x along the axis,
    /// the mouth at the negative end): mostly inside, its end showing.
    private var topCardCenter: CGPoint { Self.topCardCenter(cardSize) }

    private static func topCardCenter(_ cardSize: CGSize) -> CGPoint {
        CGPoint(x: -bodySize(cardSize).width / 2 - cardSize.height * 0.06 + cardSize.height / 2, y: 0)
    }

    /// A card's pose as it leaves the shoe: lying along the shoe's axis.
    var dealPose: CardPose {
        let c = cos(Self.angle), s = sin(Self.angle)
        let p = topCardCenter
        return CardPose(position: CGPoint(x: position.x + p.x * c - p.y * s, y: position.y + p.x * s + p.y * c),
                        rotation: Self.angle + .pi / 2, z: 900)
    }

    /// Redraws for `remaining` of the shoe left, the cut card `cut` of the
    /// way up from the back (or out on the cloth).
    func update(remaining: Double, cut: Double, cutCardOut: Bool, cardSize: CGSize, back: CGImage?, scale: CGFloat) {
        // Keyed on what can be seen — the block's length and the cut card's
        // place in whole points — so a card dealt from a six-deck shoe
        // redraws it only every third card or so.
        self.cardSize = cardSize
        let body = bodySize
        let blockLength = Int((body.width * 0.55 * CGFloat(max(0, min(1, remaining)))).rounded())
        let cutPoint = Int((body.width * 0.55 * CGFloat(max(0, remaining - cut))).rounded())
        let newKey = "\(blockLength)|\(cutPoint)|\(remaining > 0)|\(cutCardOut)|\(cardSize)|\(scale)|\(back.map { ObjectIdentifier($0) }.map(String.init(describing:)) ?? "")"
        guard newKey != key else { return }
        key = newKey
        let side = ceil(hypot(body.width, body.height) * 1.12 + cardSize.width * 0.9)
        let size = CGSize(width: side, height: side)
        let image = ChipRenderer.render(size: size, scale: scale) { ctx in
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.rotate(by: Self.angle)
            Self.draw(ctx, cardSize: cardSize, remaining: remaining, cut: cut, cutCardOut: cutCardOut, back: back)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: size)
        contentsScale = scale
        contents = image
        CATransaction.commit()
    }

    /// The shoe (and the cut card, once it is out) centred on the origin of
    /// `ctx`, lying along x with its mouth towards −x — turn the context
    /// first. For the table's layer and for the library's cover.
    static func draw(_ ctx: CGContext, cardSize: CGSize, remaining: Double, cut: Double, cutCardOut: Bool, back: CGImage?) {
        if cutCardOut { drawCutCard(ctx, cardSize: cardSize) }
        drawShoe(ctx, cardSize: cardSize, remaining: remaining, cut: cut, cutCardOut: cutCardOut, back: back)
    }

    private static func drawShoe(_ ctx: CGContext, cardSize: CGSize, remaining: Double, cut: Double, cutCardOut: Bool,
                                 back: CGImage?) {
        let b = bodySize(cardSize)
        let bodyRect = CGRect(x: -b.width / 2, y: -b.height / 2, width: b.width, height: b.height)
        let body = ContinuousShape.roundedRect(bodyRect, radius: b.height * 0.13)
        let wall = b.height * 0.10

        // Its shadow on the cloth, away from the lamp.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: b.height * 0.05, height: b.height * 0.11), blur: b.height * 0.22,
                      color: NSColor(white: 0, alpha: 0.60).cgColor)
        ctx.addPath(body)
        ctx.setFillColor(NSColor(white: 0.03, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // The top card, its end out of the mouth.
        let top = topCardCenter(cardSize)
        let card = CGRect(x: top.x - cardSize.height / 2, y: -cardSize.width / 2,
                          width: cardSize.height, height: cardSize.width)
        if remaining > 0 { drawCardBack(back, in: card, ctx) }

        // The body: smoked acrylic, with a window in its front plate where
        // the top card waits to be slid out.
        let front = b.width * 0.36
        let window = CGRect(x: bodyRect.minX + b.width * 0.045, y: bodyRect.minY + wall * 1.25,
                            width: front - b.width * 0.075, height: b.height - wall * 2.5)
        let windowPath = ContinuousShape.roundedRect(window, radius: wall * 0.9)
        let shell = CGMutablePath()
        shell.addPath(body)
        if remaining > 0 { shell.addPath(windowPath) }
        ctx.saveGState()
        ctx.addPath(shell)
        ctx.clip(using: .evenOdd)
        if let g = AppleStyle.gradient([
            (NSColor(srgbRed: 0.24, green: 0.25, blue: 0.27, alpha: 1), 0),
            (NSColor(srgbRed: 0.10, green: 0.105, blue: 0.115, alpha: 1), 0.45),
            (NSColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1), 1),
        ]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY), options: [])
        }

        // The well the cards lie in, and the cards: a block of edges from
        // the mouth back, as long as the shoe is full.
        let well = CGRect(x: bodyRect.minX + front, y: bodyRect.minY + wall,
                          width: b.width - front - wall * 0.9, height: b.height - wall * 2)
        let wellPath = ContinuousShape.roundedRect(well, radius: wall * 0.5)
        ctx.addPath(wellPath)
        ctx.setFillColor(NSColor(white: 0.02, alpha: 0.9).cgColor)
        ctx.fillPath()
        let length = well.width * 0.88 * CGFloat(max(0, min(1, remaining)))
        if length > 0.5 {
            let block = CGRect(x: well.minX, y: well.minY + wall * 0.25, width: length, height: well.height - wall * 0.5)
            ctx.saveGState()
            ctx.clip(to: block)
            AppleStyle.fillVertical(block, context: ctx, [
                (NSColor(srgbRed: 0.95, green: 0.93, blue: 0.88, alpha: 1), 0),
                (NSColor(srgbRed: 0.84, green: 0.82, blue: 0.76, alpha: 1), 1),
            ])
            // Card edges: fine lines across the block, unevenly dark.
            var rng = DeterministicRNG(seed: 0x5_40E)
            var x = block.minX + 0.6
            while x < block.maxX {
                let alpha = CGFloat(rng.next(upperBound: 12)) / 100 + 0.05
                ctx.setFillColor(NSColor(srgbRed: 0.35, green: 0.30, blue: 0.24, alpha: alpha).cgColor)
                ctx.fill(CGRect(x: x, y: block.minY, width: 0.5, height: block.height))
                x += 1.1
            }
            ctx.restoreGState()
            // The cut card, a sliver of yellow plastic standing proud of the
            // cards, `cut` of the shoe from the back.
            if !cutCardOut {
                let cutX = block.minX + well.width * 0.88 * CGFloat(max(0, remaining - cut))
                if cutX < block.maxX - 1 {
                    let sliver = CGRect(x: cutX - 1, y: block.minY - wall * 0.35, width: 2.2, height: block.height + wall * 0.7)
                    ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.80, blue: 0.20, alpha: 1).cgColor)
                    ctx.fill(sliver)
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
                    ctx.fill(CGRect(x: sliver.minX, y: sliver.minY, width: 0.7, height: sliver.height))
                }
            }
            // The weight that keeps the cards pressed to the mouth.
            let weight = CGRect(x: block.maxX, y: block.minY - wall * 0.1, width: max(4, b.width * 0.07),
                                height: block.height + wall * 0.2)
            let weightPath = ContinuousShape.roundedRect(weight, radius: 2)
            ctx.addPath(weightPath)
            ctx.setFillColor(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1).cgColor)
            ctx.fillPath()
            AppleStyle.bevel(weightPath, in: weight, context: ctx, width: 1,
                             top: NSColor(white: 1, alpha: 0.30), bottom: NSColor(white: 0, alpha: 0.4))
        }
        AppleStyle.innerShadow(wellPath, in: well, context: ctx, color: NSColor(white: 0, alpha: 0.85),
                               radius: wall * 0.6, offset: CGSize(width: 0, height: wall * 0.2))
        // The acrylic's gloss, from the lamp.
        AppleStyle.gloss(body, in: bodyRect, context: ctx, strength: 1.2)
        ctx.restoreGState()

        // The rim: light along the top, shade along the bottom, and a thread
        // of brass where the front plate meets the well.
        AppleStyle.bevel(body, in: bodyRect, context: ctx, width: 1.6,
                         top: NSColor(white: 1, alpha: 0.32), bottom: NSColor(white: 0, alpha: 0.55))
        // The window's edge, cut and polished.
        if remaining > 0 {
            AppleStyle.innerShadow(windowPath, in: window, context: ctx, color: NSColor(white: 0, alpha: 0.7),
                                   radius: 3, offset: CGSize(width: 0, height: 1.5))
            ctx.addPath(windowPath)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        ctx.move(to: CGPoint(x: well.minX - 1.5, y: well.minY + 2))
        ctx.addLine(to: CGPoint(x: well.minX - 1.5, y: well.maxY - 2))
        ctx.setStrokeColor(NSColor(srgbRed: 0.86, green: 0.70, blue: 0.40, alpha: 0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// The cut card once it has come out: lying on the cloth below the
    /// mouth, where the dealer set it down.
    private static func drawCutCard(_ ctx: CGContext, cardSize: CGSize) {
        let b = bodySize(cardSize)
        ctx.saveGState()
        ctx.translateBy(x: -b.width * 0.22, y: b.height * 0.5 + cardSize.width * 0.38)
        ctx.rotate(by: 0.12)
        let rect = CGRect(x: -cardSize.height / 2, y: -cardSize.width * 0.36, width: cardSize.height, height: cardSize.width * 0.72)
        let path = ContinuousShape.roundedRect(rect, radius: cardSize.width * 0.07)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.78, blue: 0.20, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        AppleStyle.gloss(path, in: rect, context: ctx, strength: 1.4)
        AppleStyle.bevel(path, in: rect, context: ctx, width: 1, top: NSColor(white: 1, alpha: 0.45),
                         bottom: NSColor(srgbRed: 0.5, green: 0.35, blue: 0, alpha: 0.5))
        ctx.restoreGState()
    }

    private static func drawCardBack(_ back: CGImage?, in rect: CGRect, _ ctx: CGContext) {
        // The back is drawn upright and turned a quarter: the card lies
        // along the shoe.
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: .pi / 2)
        let upright = CGRect(x: -rect.height / 2, y: -rect.width / 2, width: rect.height, height: rect.width)
        let path = ContinuousShape.roundedRect(upright, radius: rect.height * 0.06)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(white: 0.95, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        if let back {
            ctx.addPath(path)
            ctx.clip()
            TableArt.draw(back, in: upright, context: ctx)
        }
        ctx.restoreGState()
    }
}

/// The discard holder.
final class BlackjackDiscardLayer: CALayer {

    /// The holder is set square to the table edge, give or take.
    static let angle: CGFloat = 0.10

    private var key = ""

    override init() {
        super.init()
        contentsGravity = .center
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override func action(forKey event: String) -> CAAction? { nil }

    /// Where a swept card lands: squared on the pile.
    var landingPose: CardPose {
        CardPose(position: position, rotation: Self.angle, z: 900)
    }

    /// Redraws for `count` cards of a `shoeSize`-card shoe in the holder.
    func update(count: Int, shoeSize: Int, cardSize: CGSize, back: CGImage?, scale: CGFloat) {
        let thickness = count == 0 ? 0 : max(2, 26 * CGFloat(count) / CGFloat(max(1, shoeSize)))
        let newKey = "\(Int(thickness * 4))|\(count > 0)|\(cardSize)|\(scale)|\(back.map { ObjectIdentifier($0) }.map(String.init(describing:)) ?? "")"
        guard newKey != key else { return }
        key = newKey
        let side = ceil(hypot(cardSize.width, cardSize.height) * 1.25 + 24)
        let size = CGSize(width: side, height: side)
        let image = ChipRenderer.render(size: size, scale: scale) { ctx in
            ctx.translateBy(x: side / 2, y: side / 2)
            ctx.rotate(by: Self.angle)
            Self.draw(thickness: thickness, cardSize: cardSize, back: back, context: ctx)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bounds = CGRect(origin: .zero, size: size)
        contentsScale = scale
        contents = image
        CATransaction.commit()
    }

    private static func draw(thickness: CGFloat, cardSize: CGSize, back: CGImage?, context ctx: CGContext) {
        let w = cardSize.width, h = cardSize.height
        // The holder: a clear acrylic tray a little bigger than a card, its
        // walls catching the light.
        let tray = CGRect(x: -w / 2 - 7, y: -h / 2 - 7, width: w + 14 + 4, height: h + 14 + 4)
        let trayPath = ContinuousShape.roundedRect(tray, radius: 7)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1.5, height: 3), blur: 7, color: NSColor(white: 0, alpha: 0.40).cgColor)
        ctx.addPath(trayPath)
        ctx.setFillColor(NSColor(white: 0.0, alpha: 0.16).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(trayPath)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.05).cgColor)
        ctx.fillPath()
        AppleStyle.bevel(trayPath, in: tray, context: ctx, width: 2.5,
                         top: NSColor(white: 1, alpha: 0.30), bottom: NSColor(white: 1, alpha: 0.10))
        ctx.addPath(trayPath)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        guard thickness > 0 else { return }

        // The pile: its edges stepping down and right, away from the lamp,
        // one line per few cards, then the top card's back.
        let card = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let radius = w * 0.062
        let steps = Int(thickness.rounded(.up))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0.5, height: 1.5), blur: 3, color: NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.addPath(ContinuousShape.roundedRect(card.offsetBy(dx: thickness * 0.45, dy: thickness * 0.75), radius: radius))
        ctx.setFillColor(NSColor(srgbRed: 0.80, green: 0.78, blue: 0.72, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        for i in stride(from: steps, through: 1, by: -1) {
            let d = CGFloat(i) * thickness / CGFloat(steps)
            let slice = ContinuousShape.roundedRect(card.offsetBy(dx: d * 0.45, dy: d * 0.75), radius: radius)
            // Deeper slices sit further from the lamp and a shade darker.
            let shade = 0.86 - 0.10 * d / max(1, thickness)
            ctx.addPath(slice)
            ctx.setFillColor(NSColor(srgbRed: shade, green: shade * 0.98, blue: shade * 0.92, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.addPath(slice)
            ctx.setStrokeColor(NSColor(srgbRed: 0.40, green: 0.35, blue: 0.28, alpha: 0.45).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
        }
        let topPath = ContinuousShape.roundedRect(card, radius: radius)
        ctx.saveGState()
        ctx.addPath(topPath)
        ctx.clip()
        if let back { TableArt.draw(back, in: card, context: ctx) } else {
            ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1).cgColor)
            ctx.fill(card)
        }
        ctx.restoreGState()
    }
}
