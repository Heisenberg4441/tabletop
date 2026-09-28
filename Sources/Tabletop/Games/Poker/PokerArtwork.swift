//
//  PokerArtwork.swift
//  Poker's cover: the showdown, the moment the game is built round. The far
//  side of an oval table, two opponents' cards face down at the rail, the
//  board in the middle with the three cards that make the hand lifted and
//  lit, the two that do not darkened — and at the front the player's own
//  ace and ten of hearts, lit too: a royal flush, and the pot on its way.
//
//  Built from the kit rather than beside it — the same oval, rail and cloth
//  `CardTableView` paints for the real table, the same printed board places,
//  the same chips and dealer button — so the cover and the game read as one.
//  No text: the tile prints the title underneath.
//

import AppKit

enum PokerArtwork {

    private static let gold = NSColor(srgbRed: 0.980, green: 0.812, blue: 0.392, alpha: 1)

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        // A table wider than the picture: the far rail curves across the top
        // just inside the frame, the ends run off the sides, the near rail
        // lies past the bottom edge. `TableSurface` centres its oval in the
        // bounds it is given, 86% of their width, so the bounds are worked
        // back from where the table should be.
        let tableWidth = rect.width * 1.24
        let tableHeight = tableWidth / 2.05
        let tableTop = rect.minY + rect.height * 0.035
        let boundsHeight = tableHeight / 0.8 + 12
        let bounds = CGRect(x: rect.midX - tableWidth / 0.86 / 2,
                            y: tableTop + tableHeight / 2 - (boundsHeight - 8) / 2 - 8,
                            width: tableWidth / 0.86, height: boundsHeight)
        let geometry = TableSurface.geometry(for: .oval, in: bounds, cardWidth: rect.width * 0.1)
        TableSurface.paint(geometry, cloth: .blue, context: ctx)

        let cardWidth = (rect.width * 0.098).rounded()
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)
        let size = renderer.size
        let lift = size.height * 0.12

        // The board's five places, printed as on the real table.
        let boardY = rect.minY + rect.height * 0.47
        let row = TableLayout.row(count: 5, center: CGPoint(x: rect.midX, y: boardY), cardSize: size, gap: 0.12)
        ctx.saveGState()
        ctx.setLineWidth(max(0.6, cardWidth * 0.018))
        ctx.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.83, blue: 0.56, alpha: 0.18).cgColor)
        for pose in row {
            let box = CGRect(x: pose.position.x - size.width / 2 - 2, y: pose.position.y - size.height / 2 - 2,
                             width: size.width + 4, height: size.height + 4)
            ctx.addPath(ContinuousShape.roundedRect(box, radius: size.width * 0.09))
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Two opponents across the table, their cards face down at the rail.
        let backs = TableArt.cardRenderer(width: (cardWidth * 0.62).rounded(), context: ctx)
        let farY = rect.minY + rect.height * 0.215
        for (x, turn) in [(rect.minX + rect.width * 0.20, 0.34 as CGFloat), (rect.minX + rect.width * 0.80, -0.34)] {
            let side: CGFloat = turn > 0 ? 1 : -1
            TableArt.card(nil, center: CGPoint(x: x - cardWidth * 0.12, y: farY), angle: turn - 0.10 * side,
                          renderer: backs, context: ctx)
            TableArt.card(nil, center: CGPoint(x: x + cardWidth * 0.12, y: farY + cardWidth * 0.02), angle: turn + 0.06 * side,
                          renderer: backs, context: ctx)
        }

        // The board: king, queen and jack of hearts make the hand; the seven
        // and the two stand down.
        let board: [(Card, Bool)] = [(Card(.hearts, .king), true), (Card(.clubs, .seven), false),
                                     (Card(.hearts, .queen), true), (Card(.hearts, .jack), true),
                                     (Card(.spades, .two), false)]
        for (pose, (card, wins)) in zip(row, board) {
            let center = CGPoint(x: pose.position.x, y: pose.position.y - (wins ? lift : 0))
            if wins { glow(center: center, size: size, angle: 0, context: ctx) }
            TableArt.card(card, center: center, renderer: renderer, context: ctx, lifted: wins)
            if !wins { dim(center: center, size: size, angle: 0, context: ctx) }
        }

        // The pot, pushed towards the winner, and the dealer button.
        let r = cardWidth * 0.30
        let potY = rect.minY + rect.height * 0.86
        let potX = rect.midX - cardWidth * 2.55
        TableArt.chipStack([500, 500, 500, 500], base: CGPoint(x: potX - r * 2.15, y: potY), radius: r, context: ctx, seed: 2)
        TableArt.chipStack([100, 100, 100, 100, 100, 100], base: CGPoint(x: potX, y: potY - r * 0.35), radius: r,
                           context: ctx, seed: 4)
        TableArt.chipStack([25, 25, 25], base: CGPoint(x: potX + r * 2.15, y: potY + r * 0.1), radius: r, context: ctx, seed: 3)
        if let button = AvatarRenderer.dealerButton(diameter: r * 1.45, scale: max(1, ctx.ctm.a)) {
            let side = r * 1.45 + 6
            TableArt.draw(button, in: CGRect(x: rect.midX + cardWidth * 2.25, y: potY - side * 0.62, width: side, height: side),
                          context: ctx)
        }

        // The player's ace and ten of hearts, peeled up at the front, lit.
        let big = TableArt.cardRenderer(width: (cardWidth * 1.5).rounded(), context: ctx)
        let handY = rect.maxY - big.size.height * 0.34
        let hand: [(Card, CGPoint, CGFloat)] = [
            (Card(.hearts, .ace), CGPoint(x: rect.midX - cardWidth * 0.46, y: handY), -0.15),
            (Card(.hearts, .ten), CGPoint(x: rect.midX + cardWidth * 0.46, y: handY - cardWidth * 0.05), 0.11),
        ]
        for (_, center, angle) in hand {
            glow(center: center, size: big.size, angle: angle, context: ctx)
        }
        for (card, center, angle) in hand {
            TableArt.card(card, center: center, angle: angle, renderer: big, context: ctx, lifted: true)
        }
        ctx.restoreGState()
    }

    /// The soft gold light under a winning card, as the table lights it.
    private static func glow(center: CGPoint, size: CGSize, angle: CGFloat, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let box = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        ctx.setShadow(offset: .zero, blur: size.width * 0.30, color: gold.cgColor)
        ctx.addPath(ContinuousShape.roundedRect(box.insetBy(dx: 1, dy: 1), radius: size.width * 0.07))
        ctx.setFillColor(gold.withAlphaComponent(0.9).cgColor)
        ctx.fillPath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The veil over a card that is not part of the hand.
    private static func dim(center: CGPoint, size: CGSize, angle: CGFloat, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let box = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        ctx.addPath(ContinuousShape.roundedRect(box, radius: size.width * 0.062))
        ctx.setFillColor(NSColor(white: 0, alpha: 0.40).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// `--selftest poker --poker-artwork out.png`: the cover at the library
    /// tile's size and at twice it, side by side, for looking at.
    static func writeSheet(to path: String) -> Bool {
        let tile = CGSize(width: 424, height: 264)
        let sheet = CGSize(width: tile.width * 3 + 60, height: tile.height * 2 + 40)
        let image = ChipRenderer.render(size: sheet, scale: 2) { ctx in
            ctx.setFillColor(Palette.room.cgColor)
            ctx.fill(CGRect(origin: .zero, size: sheet))
            draw(in: ctx, rect: CGRect(x: 20, y: 20, width: tile.width, height: tile.height))
            draw(in: ctx, rect: CGRect(x: tile.width + 40, y: 20, width: tile.width * 2, height: tile.height * 2))
        }
        guard let image else { return false }
        return LayerSnapshot.writePNG(image, to: path)
    }
}
