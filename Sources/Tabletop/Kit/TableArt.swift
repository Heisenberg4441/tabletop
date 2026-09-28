//
//  TableArt.swift
//  Small pieces for drawing a still life of a table: the library's tiles.
//
//  Every game draws its own cover art (`TabletopGame.drawArtwork`), and most of
//  them want the same few things in it — cloth, a card lying at an angle, a
//  stack of chips, a pool ball — lit the way the real tables are. These are
//  those things, in the same top-left-origin convention as `AppleStyle` and
//  `CardRenderer`, so a picture of a table and the table itself agree about
//  where the light is. The chips are `ChipRenderer`'s and the tables
//  `TableSurface`'s, so the covers and the games cannot drift apart. The app
//  icon draws from here too.
//

import AppKit
import CoreText

enum TableArt {

    /// Draws `image` into `rect` of a top-left-origin context the right way up.
    /// Core Graphics draws images bottom-up, so in a flipped context a plain
    /// `ctx.draw` would put every card on its head.
    static func draw(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// A renderer for cards `width` points wide at the context's own pixel
    /// density, in the table's current look.
    static func cardRenderer(width: CGFloat, context ctx: CGContext,
                             theme: Theme = TablePreferences.current.theme) -> CardRenderer {
        let scale = max(1, (ctx.ctm.a * ctx.ctm.a + ctx.ctm.b * ctx.ctm.b).squareRoot())
        return CardRenderer(theme: theme, size: CGSize(width: width, height: (width / 0.70).rounded()),
                            scale: min(scale, 3))
    }

    /// One card lying on the cloth: centred on `center`, turned by `angle`
    /// radians (positive is clockwise, since y grows downward), with the soft
    /// offset shadow the Apple table gives a card at rest. A nil `card` is a
    /// face-down one.
    static func card(_ card: Card?, center: CGPoint, angle: CGFloat = 0,
                     renderer: CardRenderer, context ctx: CGContext, lifted: Bool = false) {
        guard let image = card.map({ renderer.faceImage(for: $0) }) ?? renderer.backImage() else { return }
        let size = renderer.size
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let blur = size.width * (lifted ? 0.16 : 0.06)
        let drop = size.width * (lifted ? 0.09 : 0.025)
        ctx.setShadow(offset: CGSize(width: 0, height: drop), blur: blur,
                      color: NSColor.black.withAlphaComponent(lifted ? 0.50 : 0.38).cgColor)
        draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2,
                               width: size.width, height: size.height), context: ctx)
        ctx.restoreGState()
    }

    /// A casino chip seen from straight above: `ChipRenderer`'s chip, with
    /// its shadow, for a still life.
    static func chip(_ denomination: Int, center: CGPoint, radius r: CGFloat, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: r * 0.06, height: r * 0.14), blur: r * 0.35,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(ChipStyle.of(denomination).body.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        ChipRenderer.drawFace(denomination, center: center, radius: r, context: ctx)
    }

    /// A stack of chips standing on the cloth, `denominations` listed from
    /// the bottom up; `base` is where it meets the table.
    static func chipStack(_ denominations: [Int], base: CGPoint, radius r: CGFloat, context ctx: CGContext,
                          seed: UInt64 = 1) {
        ChipRenderer.drawStack(denominations, base: base, radius: r, context: ctx, seed: seed)
    }

    // MARK: Pool balls

    /// The colour of pool ball `number` (0 is the cue ball; 9–15 share 1–7's).
    static func poolBallColor(_ number: Int) -> NSColor {
        switch number > 8 ? number - 8 : number {
        case 1: return NSColor(srgbRed: 0.97, green: 0.74, blue: 0.10, alpha: 1)
        case 2: return NSColor(srgbRed: 0.10, green: 0.25, blue: 0.64, alpha: 1)
        case 3: return NSColor(srgbRed: 0.80, green: 0.12, blue: 0.11, alpha: 1)
        case 4: return NSColor(srgbRed: 0.34, green: 0.16, blue: 0.54, alpha: 1)
        case 5: return NSColor(srgbRed: 0.95, green: 0.44, blue: 0.09, alpha: 1)
        case 6: return NSColor(srgbRed: 0.05, green: 0.44, blue: 0.24, alpha: 1)
        case 7: return NSColor(srgbRed: 0.50, green: 0.11, blue: 0.10, alpha: 1)
        case 8: return NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        default: return NSColor(srgbRed: 0.965, green: 0.955, blue: 0.915, alpha: 1)
        }
    }

    /// A pool ball seen from above and a little in front: phenolic resin, a
    /// stripe or a solid colour, the number on its white spot, and the lamp
    /// caught sharp in the upper left — the one light every table shares.
    /// `turn` rolls the ball so a rack does not look stamped out. The ball's
    /// shadow on the cloth is the caller's (it depends on where the lamp is).
    static func poolBall(_ number: Int, center c: CGPoint, radius r: CGFloat, turn: CGFloat = 0,
                         context ctx: CGContext) {
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let ivory = poolBallColor(0)
        let color = poolBallColor(number)
        let striped = number > 8

        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.setFillColor((striped ? ivory : color).cgColor)
        ctx.fill(disc)
        if striped {
            // The band round the ball's equator, seen at an angle: straight
            // across the middle, curving at the ends where the ball turns away.
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: turn)
            let band = CGMutablePath()
            band.addEllipse(in: CGRect(x: -r * 1.5, y: -r * 0.60, width: r * 3.0, height: r * 1.20))
            ctx.addPath(band)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        if number > 0 {
            // The number spot, facing up and towards the viewer — small
            // enough, and far enough forward, that the lamp's glint above it
            // lands on the lacquer with a gap between them rather than
            // bulging out of the spot's edge.
            let spotCenter = CGPoint(x: c.x + sin(turn) * r * 0.12, y: c.y + r * 0.04)
            let spot = r * 0.38
            ctx.setFillColor(NSColor(srgbRed: 0.98, green: 0.975, blue: 0.95, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: spotCenter.x - spot, y: spotCenter.y - spot, width: spot * 2, height: spot * 2))
            if r >= 7 {
                let text = String(number)
                let font = Typography.rounded(r * (text.count > 1 ? 0.40 : 0.48), weight: .bold)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    .font: font, .foregroundColor: NSColor(white: 0.08, alpha: 1).cgColor,
                ]))
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                ctx.saveGState()
                ctx.textMatrix = .identity
                ctx.translateBy(x: spotCenter.x - bounds.midX, y: spotCenter.y + bounds.midY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
        // Form: the lamp's side lit, the far side turning away into shade.
        let light = CGPoint(x: c.x - r * 0.36, y: c.y - r * 0.42)
        if let shade = AppleStyle.gradient([
            (NSColor(white: 0, alpha: 0), 0), (NSColor(white: 0, alpha: 0.06), 0.45),
            (NSColor(white: 0, alpha: 0.34), 0.85), (NSColor(white: 0, alpha: 0.58), 1.0),
        ]) {
            ctx.drawRadialGradient(shade, startCenter: light, startRadius: 0, endCenter: light, endRadius: r * 1.62,
                                   options: [.drawsAfterEndLocation])
        }
        // A little of the cloth bounced up into the lower rim.
        if let bounce = AppleStyle.gradient([(NSColor(white: 1, alpha: 0), 0.72), (NSColor(white: 1, alpha: 0.10), 1)]) {
            ctx.drawRadialGradient(bounce, startCenter: CGPoint(x: c.x, y: c.y - r * 0.2), startRadius: 0,
                                   endCenter: CGPoint(x: c.x, y: c.y - r * 0.2), endRadius: r * 1.2, options: [])
        }
        // The lamp itself, reflected: a soft glow and a hard point inside it.
        if let glow = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.55), 0), (NSColor(white: 1, alpha: 0), 1)]) {
            ctx.drawRadialGradient(glow, startCenter: light, startRadius: 0, endCenter: light, endRadius: r * 0.55, options: [])
        }
        let glint = CGPoint(x: c.x - r * 0.46, y: c.y - r * 0.52)
        let point = CGRect(x: glint.x - r * 0.10, y: glint.y - r * 0.075, width: r * 0.20, height: r * 0.15)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
        ctx.fillEllipse(in: point)
        ctx.restoreGState()

        ctx.addEllipse(in: disc.insetBy(dx: 0.25, dy: 0.25))
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.30).cgColor)
        ctx.setLineWidth(max(0.5, r * 0.03))
        ctx.strokePath()
    }

    /// A ball's shadow on the cloth: soft, and pushed away from the lamp.
    static func poolBallShadow(center c: CGPoint, radius r: CGFloat, away: CGVector = CGVector(dx: 0.30, dy: 0.55),
                               squash: CGFloat = 0.55, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: c.x + away.dx * r, y: c.y + away.dy * r + r * 0.55)
        ctx.scaleBy(x: 1, y: squash)
        if let g = AppleStyle.gradient([(NSColor(white: 0, alpha: 0.62), 0), (NSColor(white: 0, alpha: 0.28), 0.55),
                                        (NSColor(white: 0, alpha: 0), 1)]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 1.35, options: [])
        }
        ctx.restoreGState()
    }

    /// The whole tile's worth of cloth, lit and woven like the real tables,
    /// with a thin rail around the edge.
    static func felt(_ table: TableColor, in rect: CGRect, context ctx: CGContext) {
        AppleStyle.paintTable(table, in: rect, context: ctx, cardWidth: rect.width * 0.12)
    }

    /// Cloth to the very edge, no rail: the close-up of a table. Lit from a
    /// lamp at `lamp` (a fraction of `rect`), grained, and falling off into
    /// shadow at the corners.
    static func cloth(_ table: TableColor, in rect: CGRect, lamp: CGPoint = CGPoint(x: 0.5, y: 0.38),
                      context ctx: CGContext) {
        let center = CGPoint(x: rect.minX + rect.width * lamp.x, y: rect.minY + rect.height * lamp.y)
        TableSurface.paintCloth(CGPath(rect: rect, transform: nil), box: rect, lamp: center, cloth: table, context: ctx)
        ctx.saveGState()
        ctx.clip(to: rect)
        if let g = AppleStyle.gradient([(NSColor(white: 0, alpha: 0), 0.35), (NSColor(white: 0, alpha: 0.50), 1)]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: hypot(rect.width, rect.height) * 0.62, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}
