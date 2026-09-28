//
//  TableSurface.swift
//  The three tables the card games are played on, and where things go on
//  each: a rectangle of cloth in a wooden frame, a poker oval, and a
//  blackjack half-moon.
//
//  The rectangle is Solitaire's table. The other two stand in a dark room
//  under a lamp, the way a real card room is lit: a padded leather rail with
//  a stitched seam, a band of walnut inside it, and the cloth — in whatever
//  colour the player chose in the View menu — with the markings each game
//  prints on it. The poker oval has its betting line; the half-moon has its
//  arcs of lettering and its betting circles, and the dealer's chip tray
//  along the straight edge.
//
//  `TableGeometry` is the part a game reads: where the cloth is, where its
//  middle is, where a seat on the rail goes, where the betting circles are —
//  and, on the half-moon, where the printing is and where the player's cards
//  go so that they never cover it.
//  `TableSurface.paint` is the part `CardTableView` calls, once per size and
//  cloth, into a cached bitmap. Everything obeys `AppleStyle`'s three rules:
//  one light from above-left, texture felt rather than seen, and no knowledge
//  of any game's rules.
//

import AppKit
import CoreText

/// The shape of a card table.
enum TableShape: Equatable {
    /// Cloth edge to edge in a mitred walnut frame — Solitaire's table.
    case rectangular
    /// A poker table: a long oval with a padded rail, in a dark room.
    case oval
    /// A blackjack table: straight along the dealer's side at the top,
    /// curved along the players' side, with its markings printed on.
    case halfMoon(HalfMoonPrint = HalfMoonPrint())
}

/// What is printed on a blackjack table.
struct HalfMoonPrint: Equatable {
    /// The largest arc of lettering, nearest the dealer.
    var headline = NSLocalizedString("BLACKJACK PAYS 3 TO 2", comment: "printed on the blackjack table")
    /// The smaller arc under it.
    var rule = NSLocalizedString("DEALER MUST STAND ON 17 AND DRAW TO 16", comment: "printed on the blackjack table")
    /// Inside the insurance band. Empty for no band.
    var insurance = NSLocalizedString("INSURANCE PAYS 2 TO 1", comment: "printed on the blackjack table")
    /// Betting circles along the players' rail, one per hand the player may
    /// play.
    var betSpots = 1
    /// The dealer's tray of chips along the straight edge.
    var showsChipTray = true

    init(betSpots: Int = 1, showsChipTray: Bool = true) {
        self.betSpots = max(0, betSpots)
        self.showsChipTray = showsChipTray
    }
}

/// Where the half-moon's printing goes, as radii from `TableGeometry.arcCenter`
/// — a larger radius is nearer the player. Worked out with the table so the
/// lettering always keeps clear of the dealer's cards and of the band where
/// the player's cards lie above the betting circles; when a window is too
/// short for all of it, the small rule line goes first and then the
/// lettering shrinks.
struct HalfMoonMarkings: Equatable {
    /// The headline's letter size, in points (the rule and the insurance
    /// lettering are set smaller, in proportion).
    var size: CGFloat
    /// The baseline of "BLACKJACK PAYS 3 TO 2".
    var headlineRadius: CGFloat
    /// The baseline of "DEALER MUST STAND…", or nil when there was no room
    /// for it (or it is empty).
    var ruleRadius: CGFloat?
    /// The insurance band's inner and outer edges, or nil for no band.
    var insuranceBand: ClosedRange<CGFloat>?
    /// The band the player's cards lie in, just above the betting circles:
    /// nothing is printed here.
    var handBand: ClosedRange<CGFloat>
}

/// Where everything is on a table of a given shape and size.
struct TableGeometry {
    let shape: TableShape
    /// The whole view.
    let bounds: CGRect
    /// The table's outer edge: the frame's outside for the rectangle, the
    /// rail's outside for the oval, the half-moon's bounding box (which may
    /// run past the view's sides — the half-moon is wider than the window).
    let tableRect: CGRect
    /// The cloth's bounding box, inside the rail.
    let feltRect: CGRect
    /// The cloth's exact outline.
    let feltPath: CGPath
    /// The rail's width, frame or padding.
    let railWidth: CGFloat
    /// The middle of the play: the pot, the community cards, the fight.
    let center: CGPoint

    // Oval and half-moon.

    /// Oval: half the length of the straight sides; the ends are semicircles
    /// of radius `tableRect.height / 2`.
    let straight: CGFloat
    /// Half-moon: the centre and outer radius of the curved edge.
    let arcCenter: CGPoint
    let arcRadius: CGFloat
    /// Half-moon: where the straight dealer's edge is.
    let dealerEdgeY: CGFloat
    /// Half-moon: the betting circles, left to right, and their radius.
    let betSpots: [CGPoint]
    let betSpotRadius: CGFloat
    /// Half-moon: the dealer's chip tray, if there is one.
    let chipTray: CGRect?
    /// Half-moon: where the dealer's cards go, and where the shoe and the
    /// discard tray stand.
    let dealerArea: CGPoint
    let shoe: CGPoint
    let discardTray: CGPoint
    /// Half-moon: the cloth's radius (inside the rail and the wood trim).
    var feltRadius: CGFloat = 0
    /// Half-moon: where the lettering, the insurance band and the player's
    /// card band are. Nil for the other shapes.
    var markings: HalfMoonMarkings?
    /// Half-moon: the size of the cards the table was laid out for.
    var cardSize: CGSize = .zero

    // MARK: Half-moon helpers

    /// The angle of betting circle `i` seen from `arcCenter` (π/2 is straight
    /// down, the middle of the table).
    func betSpotAngle(_ i: Int) -> CGFloat {
        guard let spot = betSpots[safe: i] else { return .pi / 2 }
        return atan2(spot.y - arcCenter.y, spot.x - arcCenter.x)
    }

    /// The turn that lines a card up with the arc at betting circle `i`:
    /// zero for the middle circle, a little either way for the others. Pass
    /// it as a pose's `rotation`, or ignore it for upright cards.
    func betSpotRotation(_ i: Int) -> CGFloat { betSpotAngle(i) - .pi / 2 }

    /// Where the player's hand on circle `i` goes: the middle of the card
    /// band straight above the circle, clear of every word on the cloth.
    func playerCardAnchor(forBetSpot i: Int) -> CGPoint {
        let band = markings?.handBand ?? 0...0
        let r = (band.lowerBound + band.upperBound) / 2
        let a = betSpotAngle(i)
        return CGPoint(x: arcCenter.x + r * cos(a), y: arcCenter.y + r * sin(a))
    }

    /// The room for circle `i`'s cards — the card band above it, as wide as
    /// the gap to the neighbouring circles (or five cards, for a lone
    /// circle). Room for a split into two to four hands side by side, or one
    /// hand cascading; keep cards inside it and they cover no printing.
    func handArea(forBetSpot i: Int) -> CGRect {
        guard let band = markings?.handBand, betSpots.indices.contains(i) else { return .zero }
        let anchor = playerCardAnchor(forBetSpot: i)
        let width: CGFloat
        if betSpots.count > 1 {
            let neighbour = i + 1 < betSpots.count ? betSpots[i + 1] : betSpots[i - 1]
            width = hypot(neighbour.x - betSpots[i].x, neighbour.y - betSpots[i].y)
        } else {
            width = cardSize.width * 5
        }
        let height = band.upperBound - band.lowerBound
        return CGRect(x: anchor.x - width / 2, y: anchor.y - height / 2, width: width, height: height)
    }

    /// The spot on the insurance band in front of circle `i`, where an
    /// insurance bet is placed — nil if the table prints no band.
    func insuranceSpot(forBetSpot i: Int) -> CGPoint? {
        guard let band = markings?.insuranceBand else { return nil }
        let r = (band.lowerBound + band.upperBound) / 2
        let a = betSpotAngle(i)
        return CGPoint(x: arcCenter.x + r * cos(a), y: arcCenter.y + r * sin(a))
    }

    /// A point on the oval's rail at `angle` from the middle (0 is to the
    /// right, π/2 straight down — the player's seat), `inset` points in from
    /// the rail's outer edge. Negative insets go outside the table. For the
    /// other shapes, the same idea on their own outline.
    func railPoint(angle: CGFloat, inset: CGFloat = 0) -> CGPoint {
        let direction = CGPoint(x: cos(angle), y: sin(angle))
        var low: CGFloat = 0
        var high = max(bounds.width, bounds.height) * 2
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let p = CGPoint(x: center.x + direction.x * mid, y: center.y + direction.y * mid)
            if contains(p, inset: inset) { low = mid } else { high = mid }
        }
        return CGPoint(x: center.x + direction.x * low, y: center.y + direction.y * low)
    }

    /// Whether `p` is on the table, `inset` points inside its outer edge.
    func contains(_ p: CGPoint, inset: CGFloat = 0) -> Bool {
        switch shape {
        case .oval:
            let r = tableRect.height / 2 - inset
            let dx = max(0, abs(p.x - tableRect.midX) - straight)
            let dy = p.y - tableRect.midY
            return r > 0 && dx * dx + dy * dy <= r * r
        case .halfMoon:
            let r = arcRadius - inset
            let dx = p.x - arcCenter.x, dy = p.y - arcCenter.y
            return r > 0 && p.y >= dealerEdgeY + inset && dx * dx + dy * dy <= r * r
        case .rectangular:
            return tableRect.insetBy(dx: inset, dy: inset).contains(p)
        }
    }

    /// Seat angles for `count` players round the oval, the first at the
    /// bottom (the player), the rest going clockwise — left, up, round and
    /// down the right — evenly by angle.
    static func seatAngles(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        return (0..<count).map { .pi / 2 + CGFloat($0) * 2 * .pi / CGFloat(count) }
    }
}

enum TableSurface {

    // MARK: Geometry

    /// Where things are on a `shape` table filling `bounds`, keeping the
    /// window's top strip (`topInset`) and `bottomReserve` points along the
    /// bottom (an action bar) clear of the table itself.
    static func geometry(for shape: TableShape, in bounds: CGRect, topInset: CGFloat = 0,
                         bottomReserve: CGFloat = 0, cardWidth: CGFloat = 80) -> TableGeometry {
        switch shape {
        case .rectangular:
            // The table starts under the window's top strip, which is left to
            // the room — the same band every screen has, so the chrome up
            // there always sits on one quiet surface rather than half on wood
            // and half on cloth.
            let rail = AppleStyle.railWidth(cardWidth)
            let table = CGRect(x: bounds.minX, y: bounds.minY + topInset, width: bounds.width,
                               height: max(1, bounds.height - topInset))
            let felt = table.insetBy(dx: rail, dy: rail)
            let play = CGRect(x: felt.minX, y: felt.minY, width: felt.width,
                              height: max(1, felt.maxY - bottomReserve - felt.minY))
            return TableGeometry(shape: shape, bounds: bounds, tableRect: table, feltRect: felt,
                                 feltPath: CGPath(rect: felt, transform: nil), railWidth: rail,
                                 center: CGPoint(x: play.midX, y: play.midY), straight: 0,
                                 arcCenter: .zero, arcRadius: 0, dealerEdgeY: bounds.minY, betSpots: [],
                                 betSpotRadius: 0, chipTray: nil, dealerArea: CGPoint(x: play.midX, y: play.minY),
                                 shoe: .zero, discardTray: .zero)

        case .oval:
            let available = CGRect(x: bounds.minX, y: bounds.minY + topInset + 8,
                                   width: bounds.width, height: max(1, bounds.height - topInset - 8 - bottomReserve))
            let aspect: CGFloat = 2.05
            var width = available.width * 0.86
            var height = width / aspect
            if height > available.height * 0.80 {
                height = available.height * 0.80
                width = height * aspect
            }
            let table = CGRect(x: (available.midX - width / 2).rounded(), y: (available.midY - height / 2).rounded(),
                               width: width.rounded(), height: height.rounded())
            let rail = min(46, max(20, height * 0.078))
            let trim = rail * 0.24
            let straight = max(0, (table.width - table.height) / 2)
            let feltInset = rail + trim
            let felt = table.insetBy(dx: feltInset, dy: feltInset)
            return TableGeometry(shape: shape, bounds: bounds, tableRect: table, feltRect: felt,
                                 feltPath: stadium(table, inset: feltInset), railWidth: rail,
                                 center: CGPoint(x: table.midX, y: table.midY), straight: straight,
                                 arcCenter: .zero, arcRadius: 0, dealerEdgeY: table.minY, betSpots: [],
                                 betSpotRadius: 0, chipTray: nil, dealerArea: CGPoint(x: table.midX, y: table.midY),
                                 shoe: .zero, discardTray: .zero)

        case .halfMoon(let print):
            // The straight edge runs under the window's top strip; the curve
            // bottoms out just above the reserve and leaves the window through
            // its sides a little over a quarter of the way down, so the table
            // fills the view the way a table fills your view when you sit at
            // one.
            let top = bounds.minY + topInset + 6
            let bottom = bounds.maxY - bottomReserve - 8
            let sag = max(60, bottom - top)
            let reach = bounds.width / 2
            let exitDepth: CGFloat = 0.72                       // of the sag, measured up from the bottom
            let rise = sag * exitDepth
            let radius = (reach * reach + rise * rise) / (2 * rise)
            let center = CGPoint(x: bounds.midX, y: bottom - radius)
            let rail = min(44, max(22, radius * 0.062))
            let edge = rail * 0.55
            let feltRadius = radius - rail - rail * 0.24
            let felt = CGMutablePath()
            felt.addEllipse(in: CGRect(x: center.x - feltRadius, y: center.y - feltRadius,
                                       width: feltRadius * 2, height: feltRadius * 2))
            let clipTop = top + edge
            let feltBox = CGRect(x: max(bounds.minX, center.x - feltRadius), y: clipTop,
                                 width: min(bounds.width, feltRadius * 2), height: max(1, center.y + feltRadius - clipTop))
            let feltShape = CGMutablePath()
            feltShape.addRect(feltBox)
            let feltPath = feltShape.intersection(felt)

            let spotRadius = min(50, max(24, radius * 0.072))
            let spotRing = feltRadius - spotRadius * 1.9
            // Far enough apart for a hand of cards over each circle, not just
            // for the circles themselves: on a big table the cards outgrow
            // the circles' fixed maximum.
            let spread = max(spotRadius * 2.5, cardWidth * 1.75) / max(1, spotRing)
            let spots = (0..<print.betSpots).map { i -> CGPoint in
                let a = CGFloat.pi / 2 + (CGFloat(print.betSpots - 1) / 2 - CGFloat(i)) * spread
                return CGPoint(x: center.x + spotRing * cos(a), y: center.y + spotRing * sin(a))
            }
            let trayWidth = min(bounds.width * 0.30, 360)
            let tray = print.showsChipTray
                ? CGRect(x: (bounds.midX - trayWidth / 2).rounded(), y: (top + edge + rail * 0.35).rounded(),
                         width: trayWidth.rounded(), height: (rail * 1.25).rounded())
                : nil
            // The dealer's cards sit just in front of the tray, the way a
            // dealer lays them, which leaves the middle of the cloth to the
            // printing and the player's cards.
            let cardHeight = (cardWidth / CardSizePolicy.aspect).rounded()
            let dealerY = (tray?.maxY ?? top + edge) + cardHeight * 0.5 + max(10, rail * 0.35)
            let markings = halfMoonMarkings(print, center: center, radius: radius, spotRing: spotRing,
                                            spotRadius: spotRadius, dealerBottom: dealerY + cardHeight / 2,
                                            cardSize: CGSize(width: cardWidth, height: cardHeight))
            var geometry = TableGeometry(shape: shape, bounds: bounds,
                                 tableRect: CGRect(x: center.x - radius, y: top, width: radius * 2,
                                                   height: center.y + radius - top),
                                 feltRect: feltBox, feltPath: feltPath, railWidth: rail,
                                 center: CGPoint(x: bounds.midX, y: top + (bottom - top) * 0.52),
                                 straight: 0, arcCenter: center, arcRadius: radius, dealerEdgeY: top,
                                 betSpots: spots, betSpotRadius: spotRadius, chipTray: tray,
                                 dealerArea: CGPoint(x: bounds.midX, y: dealerY),
                                 shoe: CGPoint(x: bounds.maxX - bounds.width * 0.14, y: dealerY),
                                 discardTray: CGPoint(x: bounds.minX + bounds.width * 0.14, y: dealerY))
            geometry.feltRadius = feltRadius
            geometry.markings = markings
            geometry.cardSize = CGSize(width: cardWidth, height: cardHeight)
            return geometry
        }
    }

    /// Lays the half-moon's printing out from the betting circles inwards:
    /// first a band for the player's cards (a card and a tenth tall), then
    /// the insurance band, the rule line and the headline — and checks the
    /// headline's letter tops clear the dealer's hand where it is widest.
    /// If they do not, the rule line is dropped, then the lettering shrinks
    /// by a fifth at a time.
    private static func halfMoonMarkings(_ print: HalfMoonPrint, center: CGPoint, radius: CGFloat,
                                         spotRing: CGFloat, spotRadius: CGFloat, dealerBottom: CGFloat,
                                         cardSize: CGSize) -> HalfMoonMarkings {
        let spotTop = spotRing - spotRadius
        let handBand = (spotTop - cardSize.height * 1.10)...(spotTop - 2)
        var size = min(28, max(12, radius * 0.040))
        var showRule = !print.rule.isEmpty
        let hasBand = !print.insurance.isEmpty
        // The dealer's hand reaches about this far either side of the middle.
        let clearX = cardSize.width * 1.6
        var result = HalfMoonMarkings(size: size, headlineRadius: 0, ruleRadius: nil, insuranceBand: nil,
                                      handBand: handBand)
        for attempt in 0..<5 {
            let bandOuter = handBand.lowerBound - size * 0.35
            let bandInner = hasBand ? bandOuter - size * 1.9 : handBand.lowerBound
            let rule: CGFloat? = showRule ? bandInner - size * 1.1 : nil
            let headline = max(radius * 0.12, (rule ?? bandInner) - size * (showRule ? 1.55 : 1.1))
            result = HalfMoonMarkings(size: size, headlineRadius: headline, ruleRadius: rule,
                                      insuranceBand: hasBand ? bandInner...bandOuter : nil, handBand: handBand)
            let lettersTop = headline - size * 0.95
            let topAtHand = center.y + (max(0, lettersTop * lettersTop - clearX * clearX)).squareRoot()
            if topAtHand >= dealerBottom + size * 0.4 || attempt == 4 { break }
            if showRule { showRule = false } else { size = max(9, size * 0.8) }
        }
        return result
    }

    /// The window's top strip over a table — the room, dark and a little
    /// grainy, like the floor round the oval and the half-moon — for a table
    /// that paints itself rather than through `paint` (Solitaire's board).
    static func paintTopBand(in bounds: CGRect, height: CGFloat, context ctx: CGContext) {
        guard height > 0 else { return }
        let band = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        ctx.saveGState()
        ctx.clip(to: band)
        ctx.setFillColor(Palette.room.cgColor)
        ctx.fill(band)
        AppleStyle.grain(in: band, context: ctx, alpha: 0.05, spread: 20)
        ctx.restoreGState()
    }

    /// The oval's outline, `inset` points in from `rect`'s edge: two
    /// semicircles joined by straight sides.
    static func stadium(_ rect: CGRect, inset: CGFloat) -> CGPath {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0 else { return CGPath(rect: .zero, transform: nil) }
        let radius = min(r.width, r.height) / 2
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // MARK: Painting

    /// Paints the table `geometry` describes, dyed `cloth`, into a top-left-
    /// origin context. The rectangle paints edge to edge; the other two paint
    /// the room around themselves.
    static func paint(_ geometry: TableGeometry, cloth: TableColor, context ctx: CGContext,
                      cardWidth: CGFloat = 80) {
        switch geometry.shape {
        case .rectangular:
            paintTopBand(in: geometry.bounds, height: geometry.tableRect.minY - geometry.bounds.minY, context: ctx)
            // Clipped: the table's light and vignette are radial gradients
            // drawn past their ends, which would otherwise wash over the band.
            ctx.saveGState()
            ctx.clip(to: geometry.tableRect)
            AppleStyle.paintTable(cloth, in: geometry.tableRect, context: ctx, cardWidth: cardWidth)
            ctx.restoreGState()
        case .oval:
            paintOval(geometry, cloth: cloth, context: ctx)
        case .halfMoon(let print):
            paintHalfMoon(geometry, print: print, cloth: cloth, context: ctx)
        }
    }

    /// The room a table stands in: nearly black, a pool of lamplight on the
    /// floor round the table, a trace of grain.
    static func paintRoom(in rect: CGRect, lamp: CGPoint, reach: CGFloat, context ctx: CGContext) {
        ctx.setFillColor(Palette.room.cgColor)
        ctx.fill(rect)
        if let g = AppleStyle.gradient([
            (NSColor(srgbRed: 0.160, green: 0.152, blue: 0.146, alpha: 1), 0),
            (NSColor(srgbRed: 0.092, green: 0.089, blue: 0.090, alpha: 1), 0.5),
            (Palette.room, 1),
        ]) {
            ctx.drawRadialGradient(g, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: reach,
                                   options: [.drawsAfterEndLocation])
        }
        AppleStyle.grain(in: rect, context: ctx, alpha: 0.05, spread: 20)
    }

    /// Cloth inside `path`: dye, a lit pool under the lamp, weave, grain and
    /// a vignette towards the rail — the same four passes as the rectangular
    /// table, clipped to a shape.
    static func paintCloth(_ path: CGPath, box: CGRect, lamp: CGPoint, cloth: TableColor, context ctx: CGContext) {
        let (center, edge) = cloth.appleGradient
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(edge.cgColor)
        ctx.fill(box)
        if let g = AppleStyle.gradient([
            (center.blended(withFraction: 0.08, of: .white) ?? center, 0),
            (center, 0.25),
            (center.blended(withFraction: 0.45, of: edge) ?? edge, 0.62),
            (edge, 1),
        ]) {
            ctx.drawRadialGradient(g, startCenter: lamp, startRadius: 0, endCenter: lamp,
                                   endRadius: max(box.width, box.height) * 0.68, options: [.drawsAfterEndLocation])
        }
        AppleStyle.drawWeave(in: box, context: ctx)
        AppleStyle.grain(in: box, context: ctx, alpha: 0.20, spread: 24)
        ctx.restoreGState()
    }

    /// A padded leather rail between `outer` and `inner`, with `mid(t)`
    /// giving the outline `t` of the way across the rail (0 outside, 1
    /// inside): a tube, lit along its crest, stitched along its inner edge.
    static func paintPaddedRail(outer: CGPath, inner: CGPath, width: CGFloat, box: CGRect,
                                mid: (CGFloat) -> CGPath, context ctx: CGContext) {
        let ring = CGMutablePath()
        ring.addPath(outer)
        ring.addPath(inner)

        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)
        let leather = NSColor(srgbRed: 0.105, green: 0.078, blue: 0.066, alpha: 1)
        ctx.setFillColor(leather.cgColor)
        ctx.fill(box)
        // The padding: concentric strokes, narrower and lighter towards the
        // crest, which is a little inside the middle of the rail.
        let steps = 14
        for i in 0..<steps {
            let f = CGFloat(i) / CGFloat(steps)
            ctx.addPath(mid(0.46))
            ctx.setLineWidth(width * (1 - f) * 0.98)
            ctx.setStrokeColor(NSColor(srgbRed: 0.34, green: 0.27, blue: 0.22, alpha: 0.055).cgColor)
            ctx.strokePath()
        }
        // One light, from above: the top of the rail lit, the bottom in shade.
        AppleStyle.fillVertical(box, context: ctx, [
            (NSColor(white: 1, alpha: 0.10), 0),
            (NSColor(white: 1, alpha: 0), 0.4),
            (NSColor(white: 0, alpha: 0.30), 1),
        ])
        // The specular line along the crest, towards the lamp.
        ctx.addPath(mid(0.38))
        ctx.setLineWidth(max(1, width * 0.10))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.075).cgColor)
        ctx.strokePath()
        AppleStyle.grain(in: box, context: ctx, alpha: 0.12, spread: 30)
        // The seam, stitched.
        ctx.addPath(mid(0.84))
        ctx.setLineWidth(max(0.6, width * 0.028))
        ctx.setLineDash(phase: 0, lengths: [max(2, width * 0.11), max(1.5, width * 0.08)])
        ctx.setStrokeColor(NSColor(srgbRed: 0.72, green: 0.64, blue: 0.54, alpha: 0.22).cgColor)
        ctx.strokePath()
        ctx.restoreGState()

        // The rounded-over outside edge catching the lamp, and a dark crease
        // where the padding meets whatever is inside it.
        ctx.saveGState()
        ctx.addPath(outer)
        ctx.setLineWidth(1.2)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
        ctx.strokePath()
        ctx.addPath(inner)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A band of walnut between two outlines, the grain running round with
    /// the band.
    static func paintWoodBand(outer: CGPath, inner: CGPath, width: CGFloat, box: CGRect,
                              mid: (CGFloat) -> CGPath, context ctx: CGContext, seed: UInt64 = 7) {
        let ring = CGMutablePath()
        ring.addPath(outer)
        ring.addPath(inner)
        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor(srgbRed: 0.345, green: 0.224, blue: 0.130, alpha: 1).cgColor)
        ctx.fill(box)
        var rng = DeterministicRNG(seed: 0x57A1_4E7 &+ seed)
        let lines = max(4, Int(width / 1.4))
        for i in 0..<lines {
            let dark = rng.next(upperBound: 100) < 58
            let strength = CGFloat(rng.next(upperBound: 80)) / 1000 + 0.03
            ctx.addPath(mid((CGFloat(i) + 0.5) / CGFloat(lines)))
            ctx.setLineWidth(0.6 + CGFloat(rng.next(upperBound: 8)) / 10)
            ctx.setStrokeColor(NSColor(white: dark ? 0 : 1, alpha: strength).cgColor)
            ctx.strokePath()
        }
        AppleStyle.fillVertical(box, context: ctx, [
            (NSColor(white: 1, alpha: 0.16), 0), (NSColor(white: 1, alpha: 0), 0.45), (NSColor(white: 0, alpha: 0.25), 1),
        ])
        AppleStyle.grain(in: box, context: ctx, alpha: 0.12, spread: 36)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(inner)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: The oval

    private static func paintOval(_ g: TableGeometry, cloth: TableColor, context ctx: CGContext) {
        let table = g.tableRect
        paintRoom(in: g.bounds, lamp: CGPoint(x: table.midX, y: table.midY - table.height * 0.1),
                  reach: max(g.bounds.width, g.bounds.height) * 0.75, context: ctx)

        let outer = stadium(table, inset: 0)
        // The table's shadow on the floor, straight down from the lamp.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: g.railWidth * 0.7), blur: g.railWidth * 2.2,
                      color: NSColor(white: 0, alpha: 0.85).cgColor)
        ctx.addPath(outer)
        ctx.setFillColor(NSColor(white: 0.02, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let rail = g.railWidth
        let trim = rail * 0.24
        let inner = stadium(table, inset: rail)
        let feltPath = stadium(table, inset: rail + trim)

        paintCloth(feltPath, box: g.feltRect, lamp: CGPoint(x: table.midX, y: table.midY - table.height * 0.12),
                   cloth: cloth, context: ctx)
        // The cloth goes dark towards the rail: the lamp is over the middle.
        ctx.saveGState()
        ctx.addPath(feltPath)
        ctx.clip()
        if let v = AppleStyle.gradient([(NSColor(white: 0, alpha: 0), 0.55), (NSColor(white: 0, alpha: 0.38), 1)]) {
            ctx.saveGState()
            ctx.translateBy(x: table.midX, y: table.midY)
            ctx.scaleBy(x: 1, y: table.height / table.width)
            ctx.drawRadialGradient(v, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                   endRadius: table.width * 0.52, options: [.drawsAfterEndLocation])
            ctx.restoreGState()
        }
        // The betting line, printed in a thin gold rule.
        let lineInset = rail + trim + g.feltRect.height * 0.13
        ctx.addPath(stadium(table, inset: lineInset))
        ctx.setLineWidth(1.4)
        ctx.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.83, blue: 0.56, alpha: 0.26).cgColor)
        ctx.strokePath()
        ctx.addPath(stadium(table, inset: lineInset + 5))
        ctx.setLineWidth(0.8)
        ctx.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.83, blue: 0.56, alpha: 0.12).cgColor)
        ctx.strokePath()
        ctx.restoreGState()
        AppleStyle.innerShadow(feltPath, in: g.feltRect, context: ctx, color: NSColor(white: 0, alpha: 0.75),
                               radius: rail * 0.55, offset: CGSize(width: 0, height: rail * 0.16))

        paintWoodBand(outer: inner, inner: feltPath, width: trim, box: table,
                      mid: { t in stadium(table, inset: rail + trim * t) }, context: ctx)
        paintPaddedRail(outer: outer, inner: inner, width: rail, box: table,
                        mid: { t in stadium(table, inset: rail * t) }, context: ctx)
    }

    // MARK: The half-moon

    private static func paintHalfMoon(_ g: TableGeometry, print: HalfMoonPrint, cloth: TableColor,
                                      context ctx: CGContext) {
        let bounds = g.bounds
        let c = g.arcCenter
        let R = g.arcRadius
        let rail = g.railWidth
        let trim = rail * 0.24
        let top = g.dealerEdgeY
        let edge = rail * 0.55

        paintRoom(in: bounds, lamp: CGPoint(x: bounds.midX, y: top + (bounds.height - top) * 0.3),
                  reach: max(bounds.width, bounds.height) * 0.8, context: ctx)

        func circle(_ r: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        }
        // Everything is clipped to the table's side of its straight edge.
        let below = CGRect(x: bounds.minX - 10, y: top, width: bounds.width + 20, height: bounds.maxY - top + 10)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: rail * 0.7), blur: rail * 2.2,
                      color: NSColor(white: 0, alpha: 0.85).cgColor)
        ctx.addPath(circle(R).intersection(CGPath(rect: below, transform: nil)))
        ctx.setFillColor(NSColor(white: 0.02, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: below)

        let feltTop = top + edge
        let feltClip = CGRect(x: bounds.minX - 10, y: feltTop, width: bounds.width + 20, height: bounds.maxY - feltTop + 10)
        let feltPath = circle(R - rail - trim).intersection(CGPath(rect: feltClip, transform: nil))
        let feltBox = feltPath.boundingBox
        paintCloth(feltPath, box: feltBox, lamp: CGPoint(x: bounds.midX, y: top + (c.y + R - top) * 0.40),
                   cloth: cloth, context: ctx)
        ctx.saveGState()
        ctx.addPath(feltPath)
        ctx.clip()
        if let v = AppleStyle.gradient([(NSColor(white: 0, alpha: 0), 0.62), (NSColor(white: 0, alpha: 0.34), 1)]) {
            ctx.drawRadialGradient(v, startCenter: c, startRadius: 0, endCenter: c, endRadius: R - rail,
                                   options: [.drawsAfterEndLocation])
        }
        paintPrint(print, geometry: g, feltRadius: R - rail - trim, context: ctx)
        ctx.restoreGState()
        AppleStyle.innerShadow(feltPath, in: feltBox, context: ctx, color: NSColor(white: 0, alpha: 0.72),
                               radius: rail * 0.55, offset: CGSize(width: 0, height: rail * 0.16))

        let clipBelowEdge = CGPath(rect: feltClip, transform: nil)
        paintWoodBand(outer: circle(R - rail).intersection(clipBelowEdge), inner: feltPath, width: trim, box: feltBox,
                      mid: { t in circle(R - rail - trim * t) }, context: ctx)
        paintPaddedRail(outer: circle(R).intersection(CGPath(rect: below, transform: nil)),
                        inner: circle(R - rail).intersection(CGPath(rect: below, transform: nil)),
                        width: rail, box: CGRect(x: c.x - R, y: top, width: R * 2, height: c.y + R - top),
                        mid: { t in circle(R - rail * t) }, context: ctx)
        ctx.restoreGState()

        // The dealer's edge: a straight length of walnut along the top.
        let edgeRect = CGRect(x: bounds.minX, y: top, width: bounds.width, height: edge)
        ctx.saveGState()
        ctx.addPath(circle(R).intersection(CGPath(rect: edgeRect, transform: nil)))
        ctx.clip()
        ctx.setFillColor(NSColor(srgbRed: 0.30, green: 0.19, blue: 0.11, alpha: 1).cgColor)
        ctx.fill(edgeRect)
        AppleStyle.drawWoodGrain(in: edgeRect, context: ctx, horizontal: true, seed: 11)
        AppleStyle.fillVertical(edgeRect, context: ctx, [(NSColor(white: 1, alpha: 0.18), 0), (NSColor(white: 0, alpha: 0.35), 1)])
        ctx.restoreGState()

        if let tray = g.chipTray { paintChipTray(tray, context: ctx) }
    }

    /// The lettering, the insurance band and the betting circles.
    private static func paintPrint(_ print: HalfMoonPrint, geometry g: TableGeometry, feltRadius: CGFloat,
                                   context ctx: CGContext) {
        let c = g.arcCenter
        let ink = NSColor(srgbRed: 0.95, green: 0.84, blue: 0.58, alpha: 0.72)
        let quietInk = NSColor(white: 1, alpha: 0.50)
        // Where each line goes was settled with the geometry (see
        // `HalfMoonMarkings`), so a game placing cards by the same numbers
        // never lands one on the words.
        guard let markings = g.markings else { return }
        let size = markings.size
        let headlineRadius = markings.headlineRadius

        let serif: NSFont = {
            let base = NSFont.systemFont(ofSize: size, weight: .semibold)
            guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }()
        AppleStyle.inked(ctx, width: size * 20) { ctx in
            drawArcText(print.headline, center: c, radius: headlineRadius, font: serif, color: ink,
                        kern: size * 0.16, context: ctx)
            if let ruleRadius = markings.ruleRadius {
                drawArcText(print.rule, center: c, radius: ruleRadius,
                            font: .systemFont(ofSize: size * 0.50, weight: .semibold), color: quietInk,
                            kern: size * 0.12, context: ctx)
            }
            if !print.insurance.isEmpty, let band = markings.insuranceBand {
                let bandInner = band.lowerBound, bandOuter = band.upperBound
                let sweep: CGFloat = min(0.62, (size * 16) / bandOuter)
                for r in [bandInner, bandOuter] {
                    ctx.addArc(center: c, radius: r, startAngle: .pi / 2 - sweep, endAngle: .pi / 2 + sweep, clockwise: false)
                    ctx.setLineWidth(max(1, size * 0.07))
                    ctx.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
                    ctx.strokePath()
                }
                drawArcText(print.insurance, center: c, radius: (bandInner + bandOuter) / 2 + size * 0.26,
                            font: .systemFont(ofSize: size * 0.56, weight: .bold), color: ink,
                            kern: size * 0.20, context: ctx)
            }
            // The betting circles: a gold rule with a hairline inside it, and
            // the cloth in the middle a shade darker where chips have worn it.
            for spot in g.betSpots {
                let r = g.betSpotRadius
                let disc = CGRect(x: spot.x - r, y: spot.y - r, width: r * 2, height: r * 2)
                ctx.setFillColor(NSColor(white: 0, alpha: 0.10).cgColor)
                ctx.fillEllipse(in: disc)
                ctx.setLineWidth(max(1.2, r * 0.05))
                ctx.setStrokeColor(ink.withAlphaComponent(0.70).cgColor)
                ctx.strokeEllipse(in: disc)
                ctx.setLineWidth(max(0.6, r * 0.018))
                ctx.setStrokeColor(ink.withAlphaComponent(0.40).cgColor)
                ctx.strokeEllipse(in: disc.insetBy(dx: r * 0.13, dy: r * 0.13))
            }
        }
    }

    /// The dealer's chip tray: a well sunk into the table with columns of
    /// chips standing on edge in it.
    private static func paintChipTray(_ tray: CGRect, context ctx: CGContext) {
        let path = ContinuousShape.roundedRect(tray, radius: tray.height * 0.18)
        AppleStyle.drawSlot(path, in: tray, context: ctx)
        let columns = 10
        let well = tray.insetBy(dx: tray.height * 0.16, dy: tray.height * 0.16)
        let pitch = well.width / CGFloat(columns)
        let denominations = [5_000, 1_000, 500, 100, 100, 25, 25, 5, 5, 1]
        for (i, denomination) in denominations.prefix(columns).enumerated() {
            let style = ChipStyle.of(denomination)
            let column = CGRect(x: well.minX + CGFloat(i) * pitch + pitch * 0.08, y: well.minY,
                                width: pitch * 0.84, height: well.height)
            let shape = ContinuousShape.roundedRect(column, radius: column.width * 0.22)
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.setFillColor(style.body.cgColor)
            ctx.fill(column)
            // The chips' edges, seen from above: thin bands across the column.
            let edge = max(1.5, column.height / 9)
            var y = column.minY
            var n = 0
            while y < column.maxY {
                ctx.setFillColor((n % 3 == 1 ? style.insert : NSColor(white: 0, alpha: 0.22)).withAlphaComponent(
                    n % 3 == 1 ? 0.55 : 0.22).cgColor)
                ctx.fill(CGRect(x: column.minX, y: y, width: column.width, height: max(0.6, edge * 0.18)))
                y += edge
                n += 1
            }
            // Round in the tube: lit on the left, shaded on the right.
            if let g = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.22), 0), (NSColor(white: 1, alpha: 0), 0.4),
                                            (NSColor(white: 0, alpha: 0.35), 1)]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: column.minX, y: column.midY),
                                       end: CGPoint(x: column.maxX, y: column.midY), options: [])
            }
            ctx.restoreGState()
        }
        AppleStyle.innerShadow(path, in: tray, context: ctx, color: NSColor(white: 0, alpha: 0.55),
                               radius: tray.height * 0.12, offset: CGSize(width: 0, height: tray.height * 0.05))
    }

    // MARK: Lettering on an arc

    /// Sets `text` along a circle round `center`, centred at the bottom of
    /// the circle and reading left to right with each letter's foot on the
    /// circle and its head towards the centre — the way the lettering on a
    /// blackjack table reads from the players' side.
    static func drawArcText(_ text: String, center: CGPoint, radius: CGFloat, font: NSFont, color: NSColor,
                            kern: CGFloat = 0, context ctx: CGContext) {
        guard !text.isEmpty, radius > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.cgColor]
        let characters = text.map { String($0) }
        let widths = characters.map { character -> CGFloat in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: attributes))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        let total = widths.reduce(0, +) + kern * CGFloat(max(0, characters.count - 1))
        var offset = -total / 2
        for (character, width) in zip(characters, widths) {
            let middle = offset + width / 2
            let angle = CGFloat.pi / 2 - middle / radius
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: attributes))
            ctx.saveGState()
            ctx.translateBy(x: point.x, y: point.y)
            ctx.rotate(by: angle - .pi / 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: -width / 2, y: 0)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
            offset += width + kern
        }
    }
}
