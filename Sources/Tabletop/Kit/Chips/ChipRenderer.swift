//
//  ChipRenderer.swift
//  Clay casino chips, drawn by hand in the table's own light.
//
//  A chip is a disc of coloured clay with six contrasting inserts round its
//  edge, a printed ring, a paper inlay with the value on it and a satin
//  finish. Drawn here from nothing but arcs and gradients, in the same
//  vocabulary `AppleStyle` uses for cards and cloth: one light from above and
//  to the left, texture at a few percent, and a varnish that is satin rather
//  than glass.
//
//  Chips on the table are seen from slightly in front — the face a little
//  foreshortened (`squash`) and the edge showing below it — because that is
//  the only way a stack reads as a stack. Chips in flight or in a tray are
//  seen straight down.
//
//  Everything draws into a top-left-origin context, like `CardRenderer`. The
//  one image that gets reused a lot — a single chip seen from above — is
//  cached per denomination, size and scale; stacks are cached by the layer
//  that shows them. Main thread only, like everything that draws in this app
//  (the caches are plain statics).
//

import AppKit
import CoreText

enum ChipRenderer {

    /// How much a chip's face is foreshortened on the table: its height over
    /// its width.
    static let squash: CGFloat = 0.86

    /// How thick one chip is, as a fraction of its radius.
    static let thicknessRatio: CGFloat = 0.17

    // MARK: Face

    /// The top of one chip, centred on `center`, `radius` across, squashed to
    /// `squash` of its height. `turn` rotates the inserts, so the chips in a
    /// stack do not all line up like a printing error.
    static func drawFace(_ denomination: Int, center c: CGPoint, radius r: CGFloat, squash k: CGFloat = 1,
                         turn: CGFloat = 0, context ctx: CGContext) {
        let style = ChipStyle.of(denomination)
        ctx.saveGState()
        // Foreshortening is a vertical scale about the centre: the print is
        // foreshortened with the chip, which is what makes it lie flat.
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: k)
        let disc = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)

        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.setFillColor(style.body.cgColor)
        ctx.fill(disc)

        // Six edge inserts, as annular sectors from the rim inward.
        ctx.setFillColor(style.insert.cgColor)
        for i in 0..<6 {
            let mid = turn + CGFloat(i) * .pi / 3
            let half: CGFloat = .pi / 18                   // 20° each
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: r * 1.02, startAngle: mid - half, endAngle: mid + half, clockwise: false)
            path.addArc(center: .zero, radius: r * 0.73, startAngle: mid + half, endAngle: mid - half, clockwise: true)
            path.closeSubpath()
            ctx.addPath(path)
        }
        ctx.fillPath()

        // The printed rings: a solid one at the edge of the inlay and a
        // dotted one outside it — the detail that makes clay read as a chip
        // rather than a coloured disc.
        ctx.setStrokeColor(style.insert.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(max(0.5, r * 0.045))
        ctx.strokeEllipse(in: disc.insetBy(dx: r * 0.36, dy: r * 0.36))
        ctx.saveGState()
        ctx.setLineWidth(max(0.4, r * 0.035))
        ctx.setLineDash(phase: 0, lengths: [r * 0.07, r * 0.09])
        ctx.setStrokeColor(style.insert.withAlphaComponent(0.55).cgColor)
        ctx.strokeEllipse(in: disc.insetBy(dx: r * 0.285, dy: r * 0.285))
        ctx.restoreGState()

        // The inlay: a paper disc laid into the clay, a touch lighter and
        // very slightly sunk.
        let inlay = disc.insetBy(dx: r * 0.40, dy: r * 0.40)
        ctx.setFillColor((style.body.blended(withFraction: 0.10, of: .white) ?? style.body).cgColor)
        ctx.fillEllipse(in: inlay)
        AppleStyle.innerShadow(CGPath(ellipseIn: inlay, transform: nil), in: inlay, context: ctx,
                               color: NSColor(white: 0, alpha: 0.30), radius: r * 0.05,
                               offset: CGSize(width: 0, height: r * 0.025))

        // The value, in SF Pro Rounded, fitted to the inlay.
        let text = Chips.faceLabel(denomination)
        var fontSize = r * (text.count <= 2 ? 0.52 : text.count == 3 ? 0.40 : 0.34)
        var line = valueLine(text, size: fontSize, color: style.label)
        var bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let limit = inlay.width * 0.78
        if bounds.width > limit {
            fontSize *= limit / bounds.width
            line = valueLine(text, size: fontSize, color: style.label)
            bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: -bounds.midX, y: bounds.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()

        // Clay has a tooth.
        AppleStyle.grain(in: disc, context: ctx, alpha: 0.10, spread: 30, tile: max(8, r * 1.2))

        // Satin: the lamp's highlight up and to the left, the far side
        // turning away from it.
        if let g = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.26), 0), (NSColor(white: 1, alpha: 0.06), 0.45),
                                        (NSColor(white: 1, alpha: 0), 0.7)]) {
            let light = CGPoint(x: -r * 0.38, y: -r * 0.48)
            ctx.drawRadialGradient(g, startCenter: light, startRadius: 0, endCenter: light, endRadius: r * 1.25, options: [])
        }
        AppleStyle.fillVertical(disc, context: ctx, [(NSColor(white: 0, alpha: 0), 0.55), (NSColor(white: 0, alpha: 0.16), 1)])
        ctx.restoreGState()

        // The rim: light along the top, a hairline of dark along the bottom.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: k)
        AppleStyle.bevel(CGPath(ellipseIn: disc, transform: nil), in: disc, context: ctx, width: max(0.5, r * 0.035),
                         top: NSColor(white: 1, alpha: 0.35), bottom: NSColor(white: 0, alpha: 0.30))
        ctx.restoreGState()
    }

    private static func valueLine(_ text: String, size: CGFloat, color: NSColor) -> CTLine {
        let font = Typography.rounded(size, weight: .heavy)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color.cgColor, .kern: -size * 0.02,
        ]))
    }

    // MARK: Edge

    /// The edge of a chip whose face is centred on `center`: the band of clay
    /// between that face and the one under it, with the inserts showing as
    /// stripes where they come round the front.
    static func drawEdge(_ denomination: Int, center c: CGPoint, radius r: CGFloat, squash k: CGFloat,
                         thickness t: CGFloat, turn: CGFloat, context ctx: CGContext) {
        let style = ChipStyle.of(denomination)
        let band = CGMutablePath()
        band.move(to: CGPoint(x: c.x - r, y: c.y))
        band.addLine(to: CGPoint(x: c.x - r, y: c.y + t))
        // The lower half of the bottom ellipse, left to right through the
        // front.
        let steps = 24
        for i in 0...steps {
            let a = CGFloat.pi - CGFloat.pi * CGFloat(i) / CGFloat(steps)
            band.addLine(to: CGPoint(x: c.x + r * cos(a), y: c.y + t + k * r * sin(a)))
        }
        band.addLine(to: CGPoint(x: c.x + r, y: c.y))
        band.closeSubpath()

        ctx.saveGState()
        ctx.addPath(band)
        ctx.clip()
        ctx.setFillColor((style.body.blended(withFraction: 0.12, of: .black) ?? style.body).cgColor)
        ctx.fill(band.boundingBox)

        // The inserts, where they wrap round the visible (front) half.
        ctx.setFillColor((style.insert.blended(withFraction: 0.08, of: .black) ?? style.insert).cgColor)
        for i in 0..<6 {
            let mid = turn + CGFloat(i) * .pi / 3
            let half: CGFloat = .pi / 18
            let a1 = mid - half, a2 = mid + half
            // Only the half of the edge facing the viewer shows.
            guard sin(mid) > -0.2 else { continue }
            let p1 = CGPoint(x: c.x + r * cos(a1), y: c.y + k * r * sin(a1))
            let p2 = CGPoint(x: c.x + r * cos(a2), y: c.y + k * r * sin(a2))
            let stripe = CGMutablePath()
            stripe.move(to: p1)
            stripe.addLine(to: p2)
            stripe.addLine(to: CGPoint(x: p2.x, y: p2.y + t))
            stripe.addLine(to: CGPoint(x: p1.x, y: p1.y + t))
            stripe.closeSubpath()
            ctx.addPath(stripe)
        }
        ctx.fillPath()

        // Round, lit from the left: bright on the left shoulder, going dark
        // round the right.
        if let g = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.16), 0), (NSColor(white: 1, alpha: 0.02), 0.35),
                                        (NSColor(white: 0, alpha: 0.10), 0.6), (NSColor(white: 0, alpha: 0.38), 1)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y), end: CGPoint(x: c.x + r, y: c.y), options: [])
        }
        // A seam of shadow along the bottom where it sits on the next chip.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor)
        ctx.setLineWidth(max(0.5, t * 0.16))
        let seam = CGMutablePath()
        for i in 0...steps {
            let a = CGFloat.pi - CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: c.x + r * cos(a), y: c.y + t + k * r * sin(a) - t * 0.06)
            if i == 0 { seam.move(to: p) } else { seam.addLine(to: p) }
        }
        ctx.addPath(seam)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Stacks

    /// A stack of chips standing on the cloth, `denominations` listed from
    /// the bottom up, the bottom chip's face centred `radius · squash` above
    /// `base` (so `base` is where the stack meets the table). Drops its own
    /// soft shadow down and to the right, away from the lamp.
    static func drawStack(_ denominations: [Int], base: CGPoint, radius r: CGFloat, context ctx: CGContext,
                          seed: UInt64 = 1) {
        guard !denominations.isEmpty else { return }
        let k = squash
        let t = r * thicknessRatio
        // Its shadow on the cloth: a soft pool under the base, pushed a
        // little down and to the right, away from the lamp. A radial fade
        // rather than a blurred disc, which would read as a hole.
        ctx.saveGState()
        let pool = CGPoint(x: base.x + r * 0.10, y: base.y - k * r + r * 0.10)
        ctx.translateBy(x: pool.x, y: pool.y)
        ctx.scaleBy(x: 1, y: k)
        if let g = AppleStyle.gradient([(NSColor(white: 0, alpha: 0.55), 0), (NSColor(white: 0, alpha: 0.30), 0.62),
                                        (NSColor(white: 0, alpha: 0), 1)]) {
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 1.28, options: [])
        }
        ctx.restoreGState()

        var rng = DeterministicRNG(seed: 0xC41B_5EED &+ seed)
        for (i, denomination) in denominations.enumerated() {
            let jitter = (CGFloat(rng.next(upperBound: 100)) / 100 - 0.5) * r * 0.05
            let turn = CGFloat(rng.next(upperBound: 628)) / 100
            let center = CGPoint(x: base.x + jitter, y: base.y - k * r - t - CGFloat(i) * t)
            drawEdge(denomination, center: center, radius: r, squash: k, thickness: t, turn: turn, context: ctx)
            drawFace(denomination, center: center, radius: r, squash: k, turn: turn, context: ctx)
        }
    }

    /// How tall a stack of `count` chips stands, from where it meets the
    /// cloth to the top of its face.
    static func stackHeight(count: Int, radius r: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return 2 * squash * r + CGFloat(count) * r * thicknessRatio
    }

    // MARK: Cached single chips

    private static var faces: [String: CGImage] = [:]

    /// One chip seen from straight above, `diameter` points across at
    /// `scale`, with room for its shadow. For chips in flight and for a
    /// game's own drawing. Cached.
    static func chipImage(_ denomination: Int, diameter: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(denomination)|\(Int(diameter * 4))|\(scale)"
        if let cached = faces[key] { return cached }
        let side = diameter * 1.3
        let image = render(size: CGSize(width: side, height: side), scale: scale) { ctx in
            let c = CGPoint(x: side / 2, y: side / 2)
            let r = diameter / 2
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: r * 0.06, height: r * 0.14), blur: r * 0.30,
                          color: NSColor(white: 0, alpha: 0.5).cgColor)
            ctx.setFillColor(ChipStyle.of(denomination).body.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
            drawFace(denomination, center: c, radius: r, context: ctx)
        }
        if let image {
            if faces.count > 96 { faces.removeAll() }
            faces[key] = image
        }
        return image
    }

    /// A bitmap of `size` points at `scale`, drawn by `body` in top-left
    /// coordinates.
    static func render(size: CGSize, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: max(1, Int((size.width * scale).rounded(.up))),
                                  height: max(1, Int((size.height * scale).rounded(.up))),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        body(ctx)
        return ctx.makeImage()
    }
}
