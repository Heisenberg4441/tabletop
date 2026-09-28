//
//  AppleStyle.swift
//  The table surfaces every game in the collection is played on: the
//  skeuomorphic dressing, as Chess.app would have done it.
//
//  Flat design would draw a card table as flat colour, flat cards and one
//  hairline edge. This file is the other tradition: the one where a table is
//  cloth over wood, a card is printed stock with a varnish on it, and an empty
//  pile is a shape pressed into the felt. Everything here is procedural. The
//  app ships no image assets and this file does not change that; the
//  "photographs" are gradients, deterministic noise and a few hundred straight
//  lines.
//
//  It is one of the two layers of the collection's look. This is the surface —
//  the things on the table. The chrome floating above it (glass panels, SF
//  typography, capsule buttons) is the modern macOS layer and lives elsewhere;
//  the two meet at the window and never borrow each other's vocabulary.
//
//  Three rules hold the whole thing together, and every function below obeys
//  them:
//
//  * One light, from above and a little to the left. Every highlight is on a
//    top edge, every shadow under a bottom one. The moment two surfaces
//    disagree about where the light is, the illusion is over and the board
//    just looks dirty.
//  * Texture is felt, not seen. Grain and weave live between 2% and 6% alpha —
//    enough that the eye stops reading "flat fill", never enough to notice as
//    a pattern.
//  * Nothing here knows about any game. These are surface treatments taking a
//    rect and a context, so the layout, the rules and the hit testing never
//    have to know how the table they sit on is painted.
//
//  Cost is paid once. The noise tile is built one time and cached; card faces
//  are rasterised per deal by `CardRenderer` and composited from then on; the
//  table is only repainted when `BoardView` decides the background actually
//  changed. Nothing in here runs per frame.
//

import AppKit

enum AppleStyle {

    // MARK: Light

    /// Where the light comes from, as a fraction of the lit box. Used by every
    /// gradient below so that all of them agree.
    static let lightOrigin = CGPoint(x: 0.30, y: -0.05)

    // MARK: Noise

    /// A tile of deterministic speckle: white and black flecks on nothing,
    /// with the strength of each fleck in its alpha.
    ///
    /// Built this way so it can go down with an ordinary source-over blend.
    /// The obvious construction — an opaque mid-grey tile composited in
    /// `.overlay` — is the textbook one and it is four times slower, because
    /// `.overlay` has to read back every destination pixel it touches. Over a
    /// window-sized table that was 40ms an repaint on its own.
    ///
    /// Seeded rather than random: a screenshot taken twice has to come out
    /// byte-identical, or the preview tooling can never tell a real change
    /// from a reshuffle.
    ///
    /// 128 texels laid down over 64 points means one texel per device pixel on
    /// a Retina display — the finest grain that survives without shimmering.
    private static var tiles: [Int: CGImage] = [:]
    static let tilePoints: CGFloat = 64
    private static let tileTexels = 128

    static func noiseTile(spread: Int) -> CGImage? {
        if let cached = tiles[spread] { return cached }
        let side = tileTexels
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var rng = DeterministicRNG(seed: 0xA99_1E5E_ED &+ UInt64(spread))
        for i in 0..<(side * side) {
            // How strong this fleck is, and which way it goes.
            let a = UInt8(clamping: Int(rng.next(upperBound: UInt64(spread) + 1)))
            let light = rng.next(upperBound: 2) == 0
            // Premultiplied ARGB, byte order little: B, G, R, A. Getting this
            // order wrong does not fail, it just quietly tints — which is
            // exactly what the first version of this tile did.
            let v = light ? a : 0
            pixels[i * 4 + 0] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        tiles[spread] = image
        return image
    }

    /// Lays the noise over whatever has already been painted into `rect`.
    /// The caller is expected to have clipped to the shape being textured.
    static func grain(in rect: CGRect, context ctx: CGContext,
                      alpha: CGFloat, spread: Int = 26, tile: CGFloat = tilePoints) {
        guard let image = noiseTile(spread: spread), alpha > 0 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .none
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX {
                ctx.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        ctx.restoreGState()
    }

    // MARK: Gradient plumbing

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func gradient(_ stops: [(NSColor, CGFloat)]) -> CGGradient? {
        CGGradient(colorsSpace: space,
                   colors: stops.map(\.0.cgColor) as CFArray,
                   locations: stops.map(\.1))
    }

    /// Fills the current clip with a gradient running down `rect`.
    static func fillVertical(_ rect: CGRect, context ctx: CGContext, _ stops: [(NSColor, CGFloat)]) {
        guard let g = gradient(stops) else { return }
        ctx.drawLinearGradient(g,
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: Surfaces

    /// The rim that gives a flat shape a thickness: light caught along the top
    /// edge, the same light lost along the bottom one.
    ///
    /// Drawn by clipping twice — once to the shape, once to a stroke of it —
    /// which leaves exactly the inner rim exposed and lets a plain vertical
    /// gradient do the work. Stroking with a gradient is not something Core
    /// Graphics offers, and faking it with two offset strokes leaves a seam at
    /// the corners where the top and bottom halves meet.
    static func bevel(_ path: CGPath, in rect: CGRect, context ctx: CGContext,
                      width: CGFloat, top: NSColor, bottom: NSColor) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.addPath(path)
        ctx.setLineWidth(width * 2)          // half of it lands outside and is clipped away
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        fillVertical(rect, context: ctx, [
            (top, 0),
            (top.withAlphaComponent(0), 0.42),
            (bottom.withAlphaComponent(0), 0.58),
            (bottom, 1),
        ])
        ctx.restoreGState()
    }

    /// The varnish. A broad specular sweep off the top-left corner and a much
    /// weaker bounce off the surface the card is lying on, which is what stops
    /// the bottom edge going dead.
    ///
    /// Deliberately weak — a card is satin, not glass. Anything stronger reads
    /// as a plastic toy, which is the exact failure mode of every skeuomorphic
    /// design that went too far.
    static func gloss(_ path: CGPath, in rect: CGRect, context ctx: CGContext, strength: CGFloat = 1) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let g = gradient([
            (NSColor(white: 1, alpha: 0.17 * strength), 0),
            (NSColor(white: 1, alpha: 0.07 * strength), 0.16),
            (NSColor(white: 1, alpha: 0), 0.46),
            (NSColor(white: 1, alpha: 0), 0.88),
            (NSColor(white: 1, alpha: 0.05 * strength), 1),
        ]) {
            let light = CGPoint(x: rect.minX + rect.width * lightOrigin.x,
                                y: rect.minY + rect.height * lightOrigin.y)
            ctx.drawLinearGradient(
                g, start: light,
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    /// A shadow cast *into* a shape, for anything that should read as pressed
    /// in rather than sitting on top: the empty piles, the well the stock sits
    /// in. Core Graphics only casts shadows outward, so the shape is punched
    /// out of a much larger rectangle and that is what gets the shadow — the
    /// clip then throws away everything except the part that fell inside.
    static func innerShadow(_ path: CGPath, in rect: CGRect, context ctx: CGContext,
                            color: NSColor, radius: CGFloat, offset: CGSize) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let outer = CGMutablePath()
        outer.addRect(rect.insetBy(dx: -radius * 6 - abs(offset.width),
                                   dy: -radius * 6 - abs(offset.height)))
        outer.addPath(path)
        ctx.setShadow(offset: offset, blur: radius, color: color.cgColor)
        ctx.addPath(outer)
        ctx.setFillColor(NSColor.black.cgColor)   // never visible; only its shadow is
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    // MARK: Guilloché

    /// The engraved lace on a card back, drawn the way an engine-turning lathe
    /// actually draws it: not as one ornamental outline but as a few hundred
    /// straight chords across a circle, each one joining point `i` to point
    /// `i * factor`. The curve nobody drew — the envelope the chords leave
    /// between them — is what the eye reads, and it is the same cardioid family
    /// that has been printed on banknotes and card backs for two centuries.
    ///
    /// Chords rather than a plotted outline for a practical reason too: the
    /// lace comes out dense and even at any size, where a single ornamental
    /// curve scaled down to a 60-point card reads as a scribbled star.
    static func guilloche(in rect: CGRect, context ctx: CGContext,
                          color: NSColor, lineWidth: CGFloat, factors: [Int] = [2, 3, 5]) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.46
        let points = 144

        func at(_ i: Int, _ r: CGFloat) -> CGPoint {
            let a = CGFloat(i % points) / CGFloat(points) * 2 * .pi - .pi / 2
            return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        }

        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)

        // Each multiplier leaves an envelope with one more lobe than the last,
        // so three of them nest into a lace instead of stacking into a blur.
        for (n, factor) in factors.enumerated() {
            let r = radius * (1 - CGFloat(n) * 0.14)
            ctx.setStrokeColor(color.withAlphaComponent(
                color.alphaComponent * (0.85 - CGFloat(n) * 0.16)).cgColor)
            for i in 0..<points {
                ctx.move(to: at(i, r))
                ctx.addLine(to: at(i * factor, r))
            }
            ctx.strokePath()
        }

        // Two turned rings to close the figure off, which is what stops the
        // lace looking like it was cropped out of something larger.
        ctx.setStrokeColor(color.cgColor)
        for scale in [CGFloat(1.0), 0.985] {
            ctx.addEllipse(in: CGRect(x: center.x - radius * scale, y: center.y - radius * scale,
                                      width: radius * 2 * scale, height: radius * 2 * scale))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Card stock

    /// Paper. A card is not white and it is not flat: the stock is warm, it is
    /// lighter where the light falls on it, and it has a tooth.
    static func cardStock(_ path: CGPath, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fillVertical(rect, context: ctx, [
            (NSColor(srgbRed: 1.000, green: 0.999, blue: 0.992, alpha: 1), 0),
            (NSColor(srgbRed: 0.988, green: 0.984, blue: 0.971, alpha: 1), 0.55),
            (NSColor(srgbRed: 0.945, green: 0.937, blue: 0.918, alpha: 1), 1),
        ])
        grain(in: rect, context: ctx, alpha: 0.26, spread: 30)
        ctx.restoreGState()

        // The cut edge, then the thickness of the stock just inside it.
        bevel(path, in: rect, context: ctx, width: max(0.75, rect.width * 0.011),
              top: NSColor(white: 1, alpha: 0.95),
              bottom: NSColor(srgbRed: 0.42, green: 0.40, blue: 0.36, alpha: 0.30))
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(srgbRed: 0.58, green: 0.56, blue: 0.52, alpha: 0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Ink sitting on paper rather than replacing it: a whisper of a shadow
    /// under the shape, which is what a letterpress impression actually looks
    /// like from straight on.
    static func inked(_ context: CGContext, width: CGFloat, _ body: (CGContext) -> Void) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: width * 0.004),
                          blur: width * 0.008,
                          color: NSColor(white: 0, alpha: 0.28).cgColor)
        body(context)
        context.restoreGState()
    }

    // MARK: Table

    /// The table, from cache wherever possible.
    ///
    /// Painting it costs the better part of a tenth of a second across a
    /// window, and the board repaints its background every time a pile empties
    /// or fills — which is an ordinary move, several times a game. So it is
    /// painted once into an image and blitted from then on.
    ///
    /// The size is rounded up to a 32-point bucket before it becomes the cache
    /// key, and the image is then drawn into whatever the real bounds are. A
    /// window being dragged wider would otherwise miss the cache on every
    /// single frame, which is the one case where this cost actually hurts; at
    /// a bucket wide it misses once every 32 points instead. The cost of that
    /// is up to 32 points of downscale on a surface made of gradients and
    /// noise, which is not a thing an eye can find.
    static func drawTable(_ table: TableColor, in rect: CGRect, context ctx: CGContext,
                          cardWidth: CGFloat) {
        let scale = max(1, abs(ctx.ctm.a))
        let bucket = CGSize(width: ceil(rect.width / 32) * 32, height: ceil(rect.height / 32) * 32)
        let key = "\(table.rawValue)|\(Int(bucket.width))x\(Int(bucket.height))|\(Int(railWidth(cardWidth)))|\(scale)"

        var image = tableCache?.key == key ? tableCache?.image : nil
        if image == nil, bucket.width * scale * bucket.height * scale * 4 <= maximumTableCacheBytes {
            image = renderTable(table, size: bucket, cardWidth: cardWidth, scale: scale)
            if let image { tableCache = (key, image) }
        }
        guard let image else {
            // Too large to be worth holding on to — a full-screen table on a
            // very large display. Straight to the context, and slowly.
            paintTable(table, in: rect, context: ctx, cardWidth: cardWidth)
            return
        }

        ctx.saveGState()
        // The caller's context has y growing downward; an image does not.
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .low
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private static var tableCache: (key: String, image: CGImage)?

    /// One table's worth of pixels, and no more. A cached table costs about
    /// what the window's own backing store costs, which is a fair price on an
    /// ordinary display and not one worth paying twice over on a very large
    /// one.
    private static let maximumTableCacheBytes: CGFloat = 48 * 1024 * 1024

    static func railWidth(_ cardWidth: CGFloat) -> CGFloat {
        min(max(cardWidth * 0.15, 9), 20)
    }

    private static func renderTable(_ table: TableColor, size: CGSize,
                                    cardWidth: CGFloat, scale: CGFloat) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: max(1, Int(size.width * scale)), height: max(1, Int(size.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Same top-left origin the board draws in, so `paintTable` does not
        // have to know it is being rendered off-screen.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        paintTable(table, in: CGRect(origin: .zero, size: size), context: ctx, cardWidth: cardWidth)
        return ctx.makeImage()
    }

    /// Cloth over a board, with a mitred frame around the outside.
    ///
    /// Four passes, in the order a table is actually made: the dye, the weave,
    /// the light falling on it, and the frame it is stretched over. The
    /// vignette is doing most of the work — a lit pool in the middle going to
    /// near-black in the corners is the single strongest cue that a surface is
    /// a physical thing under a lamp rather than a fill colour.
    ///
    /// Uncached, which is what a small one-off picture — a library tile — wants:
    /// going through `drawTable` would evict the one table image the cache
    /// holds and make the next ordinary move on a real table pay to paint it
    /// again.
    static func paintTable(_ table: TableColor, in rect: CGRect, context ctx: CGContext,
                           cardWidth: CGFloat) {
        let (center, edge) = table.appleGradient

        ctx.setFillColor(edge.cgColor)
        ctx.fill(rect)
        let pool = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.30)
        if let g = gradient([
            (center, 0),
            (center.blended(withFraction: 0.40, of: edge) ?? edge, 0.48),
            (edge, 1),
        ]) {
            ctx.drawRadialGradient(g, startCenter: pool, startRadius: 0,
                                   endCenter: pool, endRadius: max(rect.width, rect.height) * 0.72,
                                   options: [.drawsAfterEndLocation])
        }

        drawWeave(in: rect, context: ctx)
        grain(in: rect, context: ctx, alpha: 0.22, spread: 24)

        // The corners go right down. Deliberately heavy: this is what makes
        // the middle of the table read as lit rather than merely lighter.
        if let g = gradient([
            (NSColor(white: 0, alpha: 0), 0.16),
            (NSColor(white: 0, alpha: 0.16), 0.52),
            (NSColor(white: 0, alpha: 0.44), 0.80),
            (NSColor(white: 0, alpha: 0.72), 1),
        ]) {
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawRadialGradient(g, startCenter: mid, startRadius: 0,
                                   endCenter: mid, endRadius: hypot(rect.width, rect.height) * 0.54,
                                   options: [.drawsAfterEndLocation])
        }
        // And a sheen down the top of the cloth, where it faces the light.
        // Plain alpha rather than soft light: over a mid-tone the two are
        // within a shade of each other, and soft light costs 30ms a repaint
        // across a window this size.
        if let g = gradient([(NSColor(white: 1, alpha: 0.10), 0), (NSColor(white: 1, alpha: 0), 0.58)]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY),
                                   end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }

        drawRail(in: rect, context: ctx, width: railWidth(cardWidth))
    }

    /// Baize is a woven cloth, so it has a direction: a fine warp one way and a
    /// slightly heavier weft the other.
    ///
    /// Kept far below the threshold where the two sets of lines resolve into a
    /// grid. The first attempt at this was twice as strong and looked like a
    /// window screen laid over the table — fabric is something the eye should
    /// notice only when it goes looking.
    static func drawWeave(in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(1)

        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.030).cgColor)
        var x = rect.minX
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += 4
        }
        ctx.strokePath()

        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.055).cgColor)
        var y = rect.minY + 2
        while y < rect.maxY {
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += 4
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The frame the cloth is stretched over: four lengths of walnut, mitred at
    /// the corners, each with its grain running along its own length.
    ///
    /// Drawn as four separate pieces rather than one band with a hole in it,
    /// because that is the only way the joinery reads. A single band has to
    /// pick one grain direction, which comes out as stripes crossing the short
    /// sides, and it has to pick one lighting, which leaves the bottom rail lit
    /// from underneath. Four mitres cost four clips and fix both.
    ///
    /// Sized from the card so it cannot eat the table: the board's own side
    /// margin is 0.35 of a card and this takes at most 0.15 of one.
    private static func drawRail(in rect: CGRect, context ctx: CGContext, width w: CGFloat) {
        let inner = rect.insetBy(dx: w, dy: w)
        guard inner.width > 0, inner.height > 0 else { return }

        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        let mitres = [
            CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
            CGPoint(x: inner.maxX, y: inner.maxY), CGPoint(x: inner.minX, y: inner.maxY),
        ]

        // Top, right, bottom, left — each lit for its angle to the lamp. The
        // top rail faces it, the bottom rail is turned away from it.
        let faces: [(CGFloat, Bool)] = [(1.00, true), (0.82, false), (0.64, true), (0.88, false)]

        for side in 0..<4 {
            let (light, horizontal) = faces[side]
            let piece = CGMutablePath()
            piece.move(to: corners[side])
            piece.addLine(to: corners[(side + 1) % 4])
            piece.addLine(to: mitres[(side + 1) % 4])
            piece.addLine(to: mitres[side])
            piece.closeSubpath()
            let box = piece.boundingBox

            ctx.saveGState()
            ctx.addPath(piece)
            ctx.clip()

            let base = NSColor(srgbRed: 0.376, green: 0.251, blue: 0.149, alpha: 1)
            ctx.setFillColor((base.blended(withFraction: 1 - light, of: .black) ?? base).cgColor)
            ctx.fill(box)

            drawWoodGrain(in: box, context: ctx, horizontal: horizontal, seed: UInt64(side))
            grain(in: box, context: ctx, alpha: 0.14, spread: 36)

            // Across the width of the piece: lighter at the outside edge where
            // the rail is rounded over, darker where it meets the felt.
            if let g = gradient([
                (NSColor(white: 1, alpha: 0.12), 0),
                (NSColor(white: 1, alpha: 0), 0.35),
                (NSColor(white: 0, alpha: 0.18), 1),
            ]) {
                let across: (CGPoint, CGPoint) = {
                    switch side {
                    case 0: return (CGPoint(x: box.midX, y: rect.minY), CGPoint(x: box.midX, y: inner.minY))
                    case 1: return (CGPoint(x: rect.maxX, y: box.midY), CGPoint(x: inner.maxX, y: box.midY))
                    case 2: return (CGPoint(x: box.midX, y: rect.maxY), CGPoint(x: box.midX, y: inner.maxY))
                    default: return (CGPoint(x: rect.minX, y: box.midY), CGPoint(x: inner.minX, y: box.midY))
                    }
                }()
                ctx.drawLinearGradient(g, start: across.0, end: across.1,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()

            // The mitre itself, as a hairline so the joint is visible.
            ctx.move(to: corners[side])
            ctx.addLine(to: mitres[side])
            ctx.setStrokeColor(NSColor(white: 0, alpha: 0.28).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // The rounded-over outer edge, and the shadow the frame drops onto the
        // cloth it surrounds.
        bevel(CGPath(rect: rect, transform: nil), in: rect, context: ctx, width: 1.5,
              top: NSColor(white: 1, alpha: 0.20), bottom: NSColor(white: 0, alpha: 0.45))
        innerShadow(CGPath(rect: inner, transform: nil), in: inner, context: ctx,
                    color: NSColor(white: 0, alpha: 0.70),
                    radius: w * 0.9, offset: CGSize(width: 0, height: w * 0.22))
        ctx.addPath(CGPath(rect: inner, transform: nil))
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.45).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// Figure in the wood: bands of varying width running the length of the
    /// piece, a few of them dark enough to read as the edge of a growth ring.
    static func drawWoodGrain(in box: CGRect, context ctx: CGContext,
                                      horizontal: Bool, seed: UInt64) {
        var rng = DeterministicRNG(seed: 0x574F_4F44 &+ seed)
        let span = horizontal ? box.height : box.width
        ctx.saveGState()
        var t: CGFloat = 0
        while t < span {
            let dark = rng.next(upperBound: 100) < 58
            let strength = CGFloat(rng.next(upperBound: 90)) / 1000 + 0.02
            let thickness = 0.6 + CGFloat(rng.next(upperBound: 12)) / 8
            ctx.setStrokeColor(NSColor(white: dark ? 0 : 1, alpha: strength).cgColor)
            ctx.setLineWidth(thickness)
            if horizontal {
                ctx.move(to: CGPoint(x: box.minX, y: box.minY + t))
                ctx.addLine(to: CGPoint(x: box.maxX, y: box.minY + t))
            } else {
                ctx.move(to: CGPoint(x: box.minX + t, y: box.minY))
                ctx.addLine(to: CGPoint(x: box.minX + t, y: box.maxY))
            }
            ctx.strokePath()
            t += thickness + CGFloat(rng.next(upperBound: 4)) * 0.5 + 0.5
        }
        ctx.restoreGState()
    }

    // MARK: Empty piles

    /// An empty pile, pressed into the cloth instead of drawn onto it.
    ///
    /// The whole effect is two shadows disagreeing: a dark one falling from the
    /// top edge inward, and a light one from the bottom edge. That pair is what
    /// the eye reads as a recess, and getting them the wrong way round is the
    /// classic way to make a hole look like a button.
    static func drawSlot(_ path: CGPath, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fillVertical(rect, context: ctx, [
            (NSColor(white: 0, alpha: 0.26), 0),
            (NSColor(white: 0, alpha: 0.14), 1),
        ])
        ctx.restoreGState()

        innerShadow(path, in: rect, context: ctx, color: NSColor(white: 0, alpha: 0.60),
                    radius: rect.width * 0.07, offset: CGSize(width: 0, height: rect.width * 0.028))
        innerShadow(path, in: rect, context: ctx, color: NSColor(white: 1, alpha: 0.16),
                    radius: rect.width * 0.05, offset: CGSize(width: 0, height: -rect.width * 0.030))

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// The suit ghost and the stock arrow, engraved rather than printed: cut
    /// into the felt with a highlight on the far side of the cut.
    static func engrave(_ glyph: CGPath, in rect: CGRect, context ctx: CGContext,
                        stroke: CGFloat? = nil) {
        let lift = max(0.5, rect.width * 0.012)

        func lay(_ dy: CGFloat, _ color: NSColor) {
            var t = CGAffineTransform(translationX: 0, y: dy)
            guard let moved = glyph.copy(using: &t) else { return }
            ctx.addPath(moved)
            if let stroke {
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(stroke)
                ctx.setLineCap(.round)
                ctx.strokePath()
            } else {
                ctx.setFillColor(color.cgColor)
                ctx.fillPath()
            }
        }

        lay(lift, NSColor(white: 1, alpha: 0.13))          // light on the lower lip of the cut
        lay(0, NSColor(white: 0, alpha: 0.26))             // the cut itself
    }
}
