//
//  CardRenderer.swift
//  Draws card faces and backs into bitmaps, once each.
//
//  Cards are static images that move around; redrawing 52 of them every frame
//  during a drag would be pure waste. Each face is rasterised once per size,
//  scale factor and theme, then handed to a CALayer as its contents, where the
//  compositor moves it around for free.
//

import AppKit
import CoreText

final class CardRenderer {

    private(set) var theme: Theme
    private(set) var size: CGSize
    private(set) var scale: CGFloat

    private var faces: [UInt8: CGImage] = [:]
    private var back: CGImage?
    private var token: String = ""

    init(theme: Theme, size: CGSize, scale: CGFloat) {
        self.theme = theme
        self.size = size
        self.scale = scale
        self.token = theme.cardCacheToken
    }

    /// Throws away every cached bitmap if anything that affects how a card
    /// looks has changed. Cheap to call on every layout pass.
    func update(theme: Theme, size: CGSize, scale: CGFloat) {
        let sizeChanged = abs(size.width - self.size.width) > 0.5
            || abs(size.height - self.size.height) > 0.5
        let themeChanged = theme.cardCacheToken != token
        guard sizeChanged || themeChanged || scale != self.scale else { return }
        self.theme = theme
        self.size = size
        self.scale = scale
        self.token = theme.cardCacheToken
        faces.removeAll(keepingCapacity: true)
        back = nil
    }

    func faceImage(for card: Card) -> CGImage? {
        if let cached = faces[card.code] { return cached }
        guard let image = render({ ctx, rect in self.drawFace(card, in: rect, context: ctx) }) else { return nil }
        faces[card.code] = image
        return image
    }

    func backImage() -> CGImage? {
        if let back { return back }
        let image = render { ctx, rect in self.drawBack(in: rect, context: ctx) }
        back = image
        return image
    }

    /// Approximate memory held by the cache, for the debug overlay.
    var cacheBytes: Int {
        let per = Int(size.width * scale) * Int(size.height * scale) * 4
        return per * (faces.count + (back == nil ? 0 : 1))
    }

    // MARK: Bitmap plumbing

    private func render(_ body: (CGContext, CGRect) -> Void) -> CGImage? {
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        // Flip into top-left origin so the whole renderer can think the way the
        // layout does. Every y below grows downward.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        body(context, CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private var cornerRadius: CGFloat { max(3, size.width * 0.062) }

    private func cardShape(_ rect: CGRect) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    // MARK: Face

    private func drawFace(_ card: Card, in rect: CGRect, context ctx: CGContext) {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let shape = cardShape(inset)

        if theme.apple {
            AppleStyle.cardStock(shape, in: inset, context: ctx)
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(theme.faceColor.cgColor)
            ctx.fillPath()

            ctx.addPath(shape)
            ctx.setStrokeColor(theme.faceEdge.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        let color = theme.color(for: card.suit).cgColor
        let w = rect.width

        func printing() {
            drawCornerIndex(card, in: rect, context: ctx, color: color)

            if card.rank.isCourt {
                drawCourt(card, in: rect, context: ctx, color: color)
            } else if card.rank == .ace {
                let side = w * 0.46
                let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
                ctx.addPath(SuitPath.path(for: card.suit, in: box))
                ctx.setFillColor(color)
                ctx.fillPath()
            } else {
                drawPips(card, in: rect, context: ctx, color: color)
            }
        }

        // Apple mode presses the ink into the stock and then varnishes over the
        // top of it, in that order — a gloss under the printing would look like
        // the ink was floating above the card.
        if theme.apple {
            AppleStyle.inked(ctx, width: w) { _ in printing() }
            AppleStyle.gloss(shape, in: inset, context: ctx)
        } else {
            printing()
        }
    }

    /// The rank and a small pip in opposite corners, the second pair rotated so
    /// the card reads the same way up from either end.
    private func drawCornerIndex(_ card: Card, in rect: CGRect, context ctx: CGContext, color: CGColor) {
        let w = rect.width
        let fontSize = w * 0.215
        let font = indexFont(size: fontSize)
        let label = card.rank.label

        // The index lives in a narrow column down the left edge. Its width is
        // the constraint that sets where the pip field can start — on a real
        // card the two never touch, and the moment they do the card reads as
        // amateur work.
        let insetX = w * 0.068
        let insetY = w * 0.050
        let pipSide = w * 0.125
        let columnWidth = w * 0.165

        for rotated in [false, true] {
            ctx.saveGState()
            if rotated {
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -rect.midX, y: -rect.midY)
            }
            let textBox = CGRect(x: rect.minX + insetX, y: rect.minY + insetY,
                                 width: columnWidth, height: fontSize * 1.05)
            drawText(label, font: font, color: color, in: textBox, context: ctx)

            let pipBox = CGRect(x: rect.minX + insetX + (columnWidth - pipSide) / 2,
                                y: textBox.maxY + w * 0.018,
                                width: pipSide, height: pipSide)
            ctx.addPath(SuitPath.path(for: card.suit, in: pipBox))
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Pip positions for 2 through 10, as fractions of the card. These are the
    /// arrangements printed on a real deck; anything else looks subtly wrong
    /// even to players who have never thought about it.
    private static let pipLayouts: [Int: [CGPoint]] = [
        2:  [CGPoint(x: 0.500, y: 0.180), CGPoint(x: 0.500, y: 0.820)],
        3:  [CGPoint(x: 0.500, y: 0.180), CGPoint(x: 0.500, y: 0.500), CGPoint(x: 0.500, y: 0.820)],
        4:  [CGPoint(x: 0.345, y: 0.180), CGPoint(x: 0.655, y: 0.180),
             CGPoint(x: 0.345, y: 0.820), CGPoint(x: 0.655, y: 0.820)],
        5:  [CGPoint(x: 0.345, y: 0.180), CGPoint(x: 0.655, y: 0.180), CGPoint(x: 0.500, y: 0.500),
             CGPoint(x: 0.345, y: 0.820), CGPoint(x: 0.655, y: 0.820)],
        6:  [CGPoint(x: 0.345, y: 0.180), CGPoint(x: 0.655, y: 0.180),
             CGPoint(x: 0.345, y: 0.500), CGPoint(x: 0.655, y: 0.500),
             CGPoint(x: 0.345, y: 0.820), CGPoint(x: 0.655, y: 0.820)],
        7:  [CGPoint(x: 0.345, y: 0.180), CGPoint(x: 0.655, y: 0.180), CGPoint(x: 0.500, y: 0.340),
             CGPoint(x: 0.345, y: 0.500), CGPoint(x: 0.655, y: 0.500),
             CGPoint(x: 0.345, y: 0.820), CGPoint(x: 0.655, y: 0.820)],
        8:  [CGPoint(x: 0.345, y: 0.180), CGPoint(x: 0.655, y: 0.180), CGPoint(x: 0.500, y: 0.340),
             CGPoint(x: 0.345, y: 0.500), CGPoint(x: 0.655, y: 0.500), CGPoint(x: 0.500, y: 0.660),
             CGPoint(x: 0.345, y: 0.820), CGPoint(x: 0.655, y: 0.820)],
        9:  [CGPoint(x: 0.345, y: 0.172), CGPoint(x: 0.655, y: 0.172),
             CGPoint(x: 0.345, y: 0.391), CGPoint(x: 0.655, y: 0.391), CGPoint(x: 0.500, y: 0.500),
             CGPoint(x: 0.345, y: 0.609), CGPoint(x: 0.655, y: 0.609),
             CGPoint(x: 0.345, y: 0.828), CGPoint(x: 0.655, y: 0.828)],
        10: [CGPoint(x: 0.345, y: 0.172), CGPoint(x: 0.655, y: 0.172), CGPoint(x: 0.500, y: 0.282),
             CGPoint(x: 0.345, y: 0.391), CGPoint(x: 0.655, y: 0.391),
             CGPoint(x: 0.345, y: 0.609), CGPoint(x: 0.655, y: 0.609), CGPoint(x: 0.500, y: 0.718),
             CGPoint(x: 0.345, y: 0.828), CGPoint(x: 0.655, y: 0.828)],
    ]

    private func drawPips(_ card: Card, in rect: CGRect, context ctx: CGContext, color: CGColor) {
        guard let layout = Self.pipLayouts[card.value] else { return }
        let side = rect.width * 0.178
        ctx.setFillColor(color)
        for point in layout {
            let box = CGRect(x: rect.minX + point.x * rect.width - side / 2,
                             y: rect.minY + point.y * rect.height - side / 2,
                             width: side, height: side)
            // Everything below the middle is printed upside down on a real
            // card, so the card reads correctly from either end.
            let rotated = point.y > 0.55
            ctx.addPath(SuitPath.path(for: card.suit, in: box, rotated: rotated))
        }
        ctx.fillPath()
    }

    /// Court cards: a framed panel split through the middle, each half a
    /// rotation of the other, exactly as a real court card is. The figure is
    /// reduced to its rank letter, its suit and a small ornament — legible at
    /// 50 points wide, still deliberate-looking at 300.
    private func drawCourt(_ card: Card, in rect: CGRect, context ctx: CGContext, color: CGColor) {
        let w = rect.width
        let panel = rect.insetBy(dx: w * 0.135, dy: rect.height * 0.085)

        ctx.saveGState()
        let panelPath = CGPath(roundedRect: panel, cornerWidth: w * 0.045, cornerHeight: w * 0.045, transform: nil)
        ctx.addPath(panelPath)
        ctx.setFillColor(theme.color(for: card.suit).withAlphaComponent(0.042).cgColor)
        ctx.fillPath()

        // Apple mode doubles the frame — a heavy rule with a hairline just
        // inside it, which is the detail that separates a printed card from a
        // drawn rectangle.
        //
        // It does not engrave the panel. That was tried, and at the size a
        // court card is actually looked at, a rosette behind the letter is not
        // ornament, it is a grey smudge with a K on it. Restraint is the more
        // Apple answer and the more legible one.

        ctx.addPath(panelPath)
        ctx.setStrokeColor(theme.color(for: card.suit).withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(max(0.75, w * 0.010))
        ctx.strokePath()

        if theme.apple {
            let gap = w * 0.028
            ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: gap, dy: gap),
                               cornerWidth: w * 0.030, cornerHeight: w * 0.030, transform: nil))
            ctx.setStrokeColor(theme.color(for: card.suit).withAlphaComponent(0.30).cgColor)
            ctx.setLineWidth(max(0.4, w * 0.005))
            ctx.strokePath()
        }

        // The dividing line, drawn as a hairline pair for a printed feel.
        ctx.setStrokeColor(theme.color(for: card.suit).withAlphaComponent(0.38).cgColor)
        ctx.setLineWidth(max(0.5, w * 0.006))
        for dy in [-w * 0.011, w * 0.011] {
            ctx.move(to: CGPoint(x: panel.minX, y: panel.midY + dy))
            ctx.addLine(to: CGPoint(x: panel.maxX, y: panel.midY + dy))
        }
        ctx.strokePath()

        // Clip to the panel so the two halves cannot bleed past the frame.
        ctx.addPath(panelPath)
        ctx.clip()

        let half = CGRect(x: panel.minX, y: panel.minY, width: panel.width, height: panel.height / 2)
        for rotated in [false, true] {
            ctx.saveGState()
            if rotated {
                ctx.translateBy(x: panel.midX, y: panel.midY)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -panel.midX, y: -panel.midY)
            }
            drawCourtHalf(card, in: half, context: ctx, color: color)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawCourtHalf(_ card: Card, in rect: CGRect, context ctx: CGContext, color: CGColor) {
        // Three bands, stacked and never overlapping: ornament, rank, suit.
        // Each gets its own slice of the half so no two elements can collide
        // at any card size.
        let ornamentBand = CGRect(x: rect.minX, y: rect.minY + rect.height * 0.055,
                                  width: rect.width, height: rect.height * 0.185)
        let letterBand = CGRect(x: rect.minX, y: ornamentBand.maxY + rect.height * 0.03,
                                width: rect.width, height: rect.height * 0.40)
        let pipBand = CGRect(x: rect.minX, y: letterBand.maxY + rect.height * 0.02,
                             width: rect.width, height: rect.height * 0.24)

        if let ornament = CourtOrnament.path(for: card.rank, in: fit(
            aspect: card.rank == .jack ? 0.72 : 1.55, in: ornamentBand
        )) {
            ctx.addPath(ornament)
            ctx.setFillColor(color)
            ctx.fillPath()
        }

        drawText(card.rank.label, font: courtFont(size: letterBand.height),
                 color: color, in: letterBand, context: ctx, alignment: .center)

        let pip = fit(aspect: 1, in: pipBand)
        ctx.addPath(SuitPath.path(for: card.suit, in: pip))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    /// Largest box of the given width/height ratio that fits, centred.
    private func fit(aspect: CGFloat, in box: CGRect) -> CGRect {
        var size = CGSize(width: box.height * aspect, height: box.height)
        if size.width > box.width {
            size = CGSize(width: box.width, height: box.width / aspect)
        }
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Back

    private func drawBack(in rect: CGRect, context ctx: CGContext) {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let shape = cardShape(inset)

        if theme.apple {
            AppleStyle.cardStock(shape, in: inset, context: ctx)
        } else {
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
        }

        // Real cards leave a white margin around the printed pattern.
        let margin = rect.width * 0.055
        let field = inset.insetBy(dx: margin, dy: margin)
        let fieldPath = CGPath(roundedRect: field,
                               cornerWidth: cornerRadius * 0.62, cornerHeight: cornerRadius * 0.62,
                               transform: nil)
        ctx.saveGState()
        ctx.addPath(fieldPath)
        ctx.setFillColor(theme.backColor.base.cgColor)
        ctx.fillPath()
        ctx.addPath(fieldPath)
        ctx.clip()

        switch theme.backStyle {
        case .lattice: drawLattice(in: field, context: ctx)
        case .arcs: drawArcs(in: field, context: ctx)
        case .weave: drawWeave(in: field, context: ctx)
        case .plain: drawPlain(in: field, context: ctx)
        }
        if theme.apple { dressBackField(field, context: ctx) }
        ctx.restoreGState()

        ctx.addPath(fieldPath)
        ctx.setStrokeColor(theme.backColor.shade.cgColor)
        ctx.setLineWidth(max(0.75, rect.width * 0.009))
        ctx.strokePath()

        if theme.apple {
            // The printed field sits fractionally below the surface of the
            // stock it was pressed into, so it gets the recess treatment the
            // empty piles get — at a fraction of the depth.
            AppleStyle.innerShadow(fieldPath, in: field, context: ctx,
                                   color: NSColor(white: 0, alpha: 0.45),
                                   radius: rect.width * 0.030,
                                   offset: CGSize(width: 0, height: rect.width * 0.010))
            AppleStyle.gloss(shape, in: inset, context: ctx, strength: 0.85)
        }

        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// What Apple mode adds on top of whichever back pattern the player chose:
    /// engraving, a border rule, and a medallion in the middle.
    ///
    /// It goes over the pattern rather than replacing it so the four back
    /// styles still mean something in this mode — a lattice is still a lattice,
    /// it has simply been printed by someone with a better press. The caller
    /// has already clipped to the field.
    private func dressBackField(_ field: CGRect, context ctx: CGContext) {
        let w = size.width

        AppleStyle.guilloche(in: field, context: ctx,
                             color: theme.backColor.highlight.withAlphaComponent(0.30),
                             lineWidth: max(0.3, w * 0.0035))

        // A double rule inside the field, the way a back is bordered.
        for (inset, alpha) in [(w * 0.030, 0.45), (w * 0.052, 0.22)] {
            ctx.addPath(CGPath(roundedRect: field.insetBy(dx: inset, dy: inset),
                               cornerWidth: w * 0.030, cornerHeight: w * 0.030, transform: nil))
            ctx.setStrokeColor(theme.backColor.highlight.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(max(0.4, w * 0.006))
            ctx.strokePath()
        }

        // The medallion at the centre of the lace: a small struck disc, the
        // way a maker's mark sits on a real back. Small and hard-edged on
        // purpose — the first version was a third of the card wide and soft,
        // and at card size that is not a medallion, it is a smudge.
        let side = min(field.width, field.height) * 0.20
        let disc = CGRect(x: field.midX - side / 2, y: field.midY - side / 2, width: side, height: side)
        let discPath = CGPath(ellipseIn: disc, transform: nil)
        ctx.saveGState()
        ctx.addPath(discPath)
        ctx.clip()
        AppleStyle.fillVertical(disc, context: ctx, [
            (theme.backColor.highlight, 0),
            (theme.backColor.base, 0.55),
            (theme.backColor.shade, 1),
        ])
        ctx.restoreGState()

        ctx.addPath(discPath)
        ctx.setStrokeColor(theme.backColor.highlight.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(max(0.5, w * 0.008))
        ctx.strokePath()

        // A lozenge struck into it, dark side up so it reads as a hollow.
        let lozenge = CGMutablePath()
        let l = disc.insetBy(dx: side * 0.32, dy: side * 0.20)
        lozenge.move(to: CGPoint(x: l.midX, y: l.minY))
        lozenge.addLine(to: CGPoint(x: l.maxX, y: l.midY))
        lozenge.addLine(to: CGPoint(x: l.midX, y: l.maxY))
        lozenge.addLine(to: CGPoint(x: l.minX, y: l.midY))
        lozenge.closeSubpath()
        var down = CGAffineTransform(translationX: 0, y: max(0.5, w * 0.006))
        if let lit = lozenge.copy(using: &down) {
            ctx.addPath(lit)
            ctx.setFillColor(theme.backColor.highlight.withAlphaComponent(0.55).cgColor)
            ctx.fillPath()
        }
        ctx.addPath(lozenge)
        ctx.setFillColor(theme.backColor.shade.cgColor)
        ctx.fillPath()
    }

    private func drawLattice(in rect: CGRect, context ctx: CGContext) {
        let step = rect.width / 5.5
        ctx.setLineWidth(max(0.6, rect.width * 0.013))
        ctx.setStrokeColor(theme.backColor.highlight.withAlphaComponent(0.55).cgColor)
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            ctx.move(to: CGPoint(x: x, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        ctx.strokePath()

        // A small diamond at every crossing gives the lattice some depth.
        ctx.setFillColor(theme.backColor.highlight.withAlphaComponent(0.75).cgColor)
        let side = step * 0.22
        var gy = rect.minY
        var row = 0
        while gy < rect.maxY + step {
            var gx = rect.minX + (row % 2 == 0 ? 0 : step / 2)
            while gx < rect.maxX + step {
                ctx.saveGState()
                ctx.translateBy(x: gx, y: gy)
                ctx.rotate(by: .pi / 4)
                ctx.fill(CGRect(x: -side / 2, y: -side / 2, width: side, height: side))
                ctx.restoreGState()
                gx += step
            }
            gy += step / 2
            row += 1
        }
    }

    private func drawArcs(in rect: CGRect, context ctx: CGContext) {
        ctx.setLineWidth(max(0.6, rect.width * 0.016))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxR = hypot(rect.width, rect.height) / 2
        var r = rect.width * 0.09
        var light = true
        while r < maxR {
            ctx.setStrokeColor((light ? theme.backColor.highlight : theme.backColor.shade)
                .withAlphaComponent(0.55).cgColor)
            ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
            r += rect.width * 0.105
            light.toggle()
        }
    }

    private func drawWeave(in rect: CGRect, context ctx: CGContext) {
        let step = rect.width / 7
        ctx.setLineWidth(max(0.5, rect.width * 0.028))
        ctx.setStrokeColor(theme.backColor.highlight.withAlphaComponent(0.32).cgColor)
        var x = rect.minX
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += step
        }
        ctx.strokePath()
        ctx.setStrokeColor(theme.backColor.shade.withAlphaComponent(0.42).cgColor)
        var y = rect.minY
        while y < rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += step
        }
        ctx.strokePath()
    }

    private func drawPlain(in rect: CGRect, context ctx: CGContext) {
        let colors = [theme.backColor.highlight.cgColor, theme.backColor.shade.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.minY),
                               end: CGPoint(x: rect.maxX, y: rect.maxY),
                               options: [])
    }

    // MARK: Text

    private func indexFont(size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        // The rounded design is friendly, which is right for the flat deck and
        // wrong for this one: a printed index is a bold grotesque with square
        // terminals, and rounding them off is what makes a card look like a
        // toy instead of a card.
        if theme.apple { return base as CTFont }
        if let descriptor = base.fontDescriptor.withDesign(.rounded) {
            return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
        }
        return base as CTFont
    }

    private func courtFont(size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return CTFontCreateWithFontDescriptor(descriptor as CTFontDescriptor, size, nil)
        }
        return base as CTFont
    }

    private enum TextAlignment { case leading, center }

    /// Draws `string` centred on the cap height inside `box`.
    ///
    /// Centring on the glyph bounding box is the usual mistake: "10" and "J"
    /// have different descents, so they would sit at different heights. Cap
    /// height is what the eye actually lines up.
    private func drawText(_ string: String, font: CTFont, color: CGColor, in box: CGRect,
                          context ctx: CGContext, alignment: TextAlignment = .leading) {
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font as Any,
            .foregroundColor: NSColor(cgColor: color) ?? .black,
            .kern: 0,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let capHeight = CTFontGetCapHeight(font)

        var x = box.minX
        switch alignment {
        case .leading:
            x = box.minX + (box.width - width) / 2
        case .center:
            x = box.midX - width / 2
        }
        // Wide labels ("10") get squeezed rather than allowed to overflow.
        var horizontalScale: CGFloat = 1
        if width > box.width {
            horizontalScale = box.width / width
            x = box.minX
        }
        let y = box.midY + capHeight / 2

        ctx.saveGState()
        // Undo the top-left flip just for the text run, since Core Text draws
        // upward from a baseline.
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: horizontalScale, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
