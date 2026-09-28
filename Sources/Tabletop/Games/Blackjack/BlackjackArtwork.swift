//
//  BlackjackArtwork.swift
//  Blackjack's cover: the game's own table at the moment a natural is paid —
//  the ace of spades and the king of hearts above the one betting circle,
//  the bet and its three-to-two payout side by side in the circle, the
//  dealer's up-card and hole card beyond the gold lettering, and the shoe
//  at the dealer's left, cut by the edge of the tile.
//
//  The table is the kit's half-moon, laid out exactly as the game lays it
//  out in a window — a 1200 × 800 table with one circle, cards the game's
//  size — and then framed: the picture is the part of that table from just
//  above the dealer's cards down to the betting circle, scaled to fill the
//  tile, with the dealer's cards brought down to sit just over the words.
//  That way the circle, the lettering, the chips and the cards keep their
//  real proportions, and the player's cards lie in the band the kit keeps
//  clear of the printing. At tile size only the headline can be read, so
//  the rule line and the insurance band are left off.
//

import AppKit

enum BlackjackArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)

        // The table as a window would lay it out.
        let table = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let cardWidth: CGFloat = 80
        var print = HalfMoonPrint(betSpots: 1, showsChipTray: false)
        print.rule = ""
        print.insurance = ""
        let geometry = TableSurface.geometry(for: .halfMoon(print), in: table, topInset: 0, bottomReserve: 60,
                                             cardWidth: cardWidth)
        let cardHeight = (cardWidth / CardSizePolicy.aspect).rounded()
        let cardSize = CGSize(width: cardWidth, height: cardHeight)
        let spot = geometry.betSpots.first ?? CGPoint(x: table.midX, y: table.maxY * 0.8)

        // The dealer's cards stand just clear of the headline's letters, and
        // the frame runs from a tenth of the picture above them to just below
        // the circle, at the tile's proportions.
        let markings = geometry.markings
        let headlineY = geometry.arcCenter.y + (markings?.headlineRadius ?? 280)
        let letterSize = markings?.size ?? 24
        let dealerCenterY = headlineY - letterSize * 1.45 - cardHeight / 2
        let dealerTop = dealerCenterY - cardHeight / 2
        let circleBottom = spot.y + geometry.betSpotRadius
        let frameHeight = (circleBottom - dealerTop) / 0.84
        let frameWidth = frameHeight * rect.width / max(1, rect.height)
        let frame = CGRect(x: table.midX - frameWidth / 2, y: dealerTop - frameHeight * 0.10,
                           width: frameWidth, height: frameHeight)
        let k = rect.width / frame.width
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -frame.minX, y: -frame.minY)

        TableSurface.paint(geometry, cloth: .burgundy, context: ctx, cardWidth: cardWidth)
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)

        // The shoe at the dealer's left, three quarters full, its far end
        // leaving the tile.
        let body = BlackjackShoeLayer.bodySize(cardSize)
        ctx.saveGState()
        ctx.translateBy(x: frame.maxX - body.width * 0.38, y: dealerCenterY + cardHeight * 0.16)
        ctx.rotate(by: BlackjackShoeLayer.angle)
        BlackjackShoeLayer.draw(ctx, cardSize: cardSize, remaining: 0.72, cut: 0.25, cutCardOut: false,
                                back: renderer.backImage())
        ctx.restoreGState()

        // The dealer: seven of clubs showing, the hole card beside it.
        let dealer = CGPoint(x: geometry.dealerArea.x, y: dealerCenterY)
        TableArt.card(Card(.clubs, .seven), center: CGPoint(x: dealer.x - cardWidth * 0.31, y: dealer.y),
                      angle: -0.015, renderer: renderer, context: ctx)
        TableArt.card(nil, center: CGPoint(x: dealer.x + cardWidth * 0.31, y: dealer.y + 1),
                      angle: 0.012, renderer: renderer, context: ctx)

        // The bet in the circle and, beside it, the dealer's three-to-two:
        // 200 riding, 300 paid — two black chips and three.
        let r = geometry.betSpotRadius * 0.43
        let base = spot.y + r * 0.66
        TableArt.chipStack([100, 100], base: CGPoint(x: spot.x - r * 1.08, y: base), radius: r, context: ctx, seed: 8)
        TableArt.chipStack([100, 100, 100], base: CGPoint(x: spot.x + r * 1.08, y: base), radius: r, context: ctx, seed: 9)

        // The natural, in the card band above the circle.
        let hand = geometry.playerCardAnchor(forBetSpot: 0)
        TableArt.card(Card(.spades, .ace), center: CGPoint(x: hand.x - cardWidth * 0.26, y: hand.y + cardHeight * 0.02),
                      angle: -0.06, renderer: renderer, context: ctx, lifted: true)
        TableArt.card(Card(.hearts, .king), center: CGPoint(x: hand.x + cardWidth * 0.26, y: hand.y - cardHeight * 0.03),
                      angle: 0.07, renderer: renderer, context: ctx, lifted: true)
        ctx.restoreGState()
    }
}
