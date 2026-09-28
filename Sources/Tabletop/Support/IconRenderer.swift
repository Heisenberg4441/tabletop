//
//  IconRenderer.swift
//  `Tabletop --icon <path>` draws the app icon at 1024 pixels.
//
//  Drawn rather than shipped, so the icon always matches the cards, chips and
//  balls in the games, and the repository holds no binary assets at all.
//
//  It follows the macOS icon grid: an 824-pixel body centred on the 1024
//  canvas — a hundred pixels of margin all round — with continuous corners of
//  the standard radius and the standard soft shadow beneath it. Inside, a
//  still life of the collection: cloth stretched inside a walnut rim, the ace
//  of spades, a short stack of chips and the eight-ball, all lit from the
//  upper left like every table in the app.
//

import AppKit

@MainActor
enum IconRenderer {

    static func render(to path: String, size: Int = 1024) -> Int32 {
        let s = CGFloat(size)
        guard let image = ChipRenderer.render(size: CGSize(width: s, height: s), scale: 1, { ctx in
            draw(in: ctx, canvas: s)
        }), LayerSnapshot.writePNG(image, to: path) else { return 1 }
        return 0
    }

    /// Draws the icon into a top-left-origin context `canvas` points square.
    static func draw(in ctx: CGContext, canvas s: CGFloat) {
        let unit = s / 1024
        let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let bodyPath = ContinuousShape.roundedRect(body, radius: 185.4 * unit)

        // The grid's shadow: soft, straight down.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 22 * unit,
                      color: NSColor(white: 0, alpha: 0.32).cgColor)
        ctx.addPath(bodyPath)
        ctx.setFillColor(NSColor(srgbRed: 0.24, green: 0.14, blue: 0.08, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // The rim: walnut, grain running round, lit along the top.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        AppleStyle.fillVertical(body, context: ctx, [
            (NSColor(srgbRed: 0.43, green: 0.27, blue: 0.15, alpha: 1), 0),
            (NSColor(srgbRed: 0.30, green: 0.18, blue: 0.10, alpha: 1), 1),
        ])
        var rng = DeterministicRNG(seed: 0x1C0)
        let rings = 26
        for i in 0..<rings {
            let inset = CGFloat(i) * 2.4 * unit
            let dark = rng.next(upperBound: 100) < 55
            ctx.addPath(ContinuousShape.roundedRect(body.insetBy(dx: inset, dy: inset), radius: max(8, (185.4 - CGFloat(i) * 2.4) * unit)))
            ctx.setStrokeColor(NSColor(white: dark ? 0 : 1, alpha: CGFloat(rng.next(upperBound: 70)) / 1000 + 0.03).cgColor)
            ctx.setLineWidth((0.8 + CGFloat(rng.next(upperBound: 12)) / 10) * unit)
            ctx.strokePath()
        }
        AppleStyle.grain(in: body, context: ctx, alpha: 0.10, spread: 36, tile: 64 * unit)
        ctx.restoreGState()
        AppleStyle.bevel(bodyPath, in: body, context: ctx, width: 6 * unit,
                         top: NSColor(white: 1, alpha: 0.35), bottom: NSColor(white: 0, alpha: 0.35))

        // The cloth, set into the rim.
        let feltRect = body.insetBy(dx: 58 * unit, dy: 58 * unit)
        let felt = ContinuousShape.roundedRect(feltRect, radius: 132 * unit)
        let (center, edge) = TableColor.green.appleGradient
        ctx.saveGState()
        ctx.addPath(felt)
        ctx.clip()
        ctx.setFillColor(edge.cgColor)
        ctx.fill(feltRect)
        let lamp = CGPoint(x: feltRect.minX + feltRect.width * 0.36, y: feltRect.minY + feltRect.height * 0.30)
        if let g = AppleStyle.gradient([(center.blended(withFraction: 0.16, of: .white) ?? center, 0), (center, 0.34), (edge, 1)]) {
            ctx.drawRadialGradient(g, startCenter: lamp, startRadius: 0, endCenter: lamp,
                                   endRadius: feltRect.width * 0.92, options: [.drawsAfterEndLocation])
        }
        AppleStyle.grain(in: feltRect, context: ctx, alpha: 0.14, spread: 24, tile: 64 * unit)
        ctx.restoreGState()
        AppleStyle.innerShadow(felt, in: feltRect, context: ctx, color: NSColor(white: 0, alpha: 0.75),
                               radius: 26 * unit, offset: CGSize(width: 0, height: 10 * unit))
        ctx.addPath(felt)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.setLineWidth(2 * unit)
        ctx.strokePath()

        // The still life, back to front: the chips, the ace, the eight-ball.
        ctx.saveGState()
        ctx.addPath(felt)
        ctx.clip()
        ChipRenderer.drawStack([100, 25, 25, 5], base: CGPoint(x: feltRect.minX + feltRect.width * 0.76,
                                                              y: feltRect.minY + feltRect.height * 0.47),
                               radius: 96 * unit, context: ctx, seed: 3)
        ctx.restoreGState()

        let cardWidth = 318 * unit
        let renderer = CardRenderer(theme: Theme(), size: CGSize(width: cardWidth, height: (cardWidth / 0.70).rounded()),
                                    scale: 1)
        TableArt.card(Card(.spades, .ace), center: CGPoint(x: body.midX - 70 * unit, y: body.midY - 18 * unit),
                      angle: -0.17, renderer: renderer, context: ctx, lifted: true)

        // Clear of the ace's lower index: half an index peeping from behind
        // the ball reads as a stray letter.
        let ball = CGPoint(x: body.midX + 192 * unit, y: body.midY + 196 * unit)
        let radius = 118 * unit
        TableArt.poolBallShadow(center: ball, radius: radius, away: CGVector(dx: 0.30, dy: 0.20), squash: 0.5, context: ctx)
        TableArt.poolBall(8, center: ball, radius: radius, turn: 0.1, context: ctx)

        // A breath of light over the whole face, from the upper left.
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        if let g = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.10), 0), (NSColor(white: 1, alpha: 0), 1)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: body.minX, y: body.minY),
                                   end: CGPoint(x: body.midX, y: body.midY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(bodyPath)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.30).cgColor)
        ctx.setLineWidth(1.5 * unit)
        ctx.strokePath()
    }
}
