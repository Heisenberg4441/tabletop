//
//  BlackjackArtwork.swift
//  Blackjack's cover: a natural — the ace of spades and the king of hearts —
//  above a betting circle on a half-moon table, the bet in the circle, the
//  dealer's up-card and hole card at the top, and one arc of gold lettering
//  between them.
//
//  The table is the kit's own half-moon, laid out exactly as it would be in
//  a window — a 1200 × 800 table with its cards — and then framed: the
//  picture is the part of that table from just above the lettering down to
//  the betting circle, scaled to fill the tile, with the dealer's two cards
//  brought down to sit just over the words. That way the circles, the
//  lettering and the cards keep their real proportions (drawn at tile size
//  directly, the circles' minimum size would swallow the picture), and the
//  kit's own rule that the player's cards lie in a band clear of the
//  printing holds on the cover too. At tile size only the headline can be
//  read, so the rule line and the insurance band are left off.
//

import AppKit

enum BlackjackArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)

        // The table as a window would lay it out.
        let table = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let cardWidth: CGFloat = 80
        var print = HalfMoonPrint(betSpots: 3, showsChipTray: false)
        print.rule = ""
        print.insurance = ""
        let geometry = TableSurface.geometry(for: .halfMoon(print), in: table, topInset: 0, bottomReserve: 60,
                                             cardWidth: cardWidth)
        let cardHeight = (cardWidth / CardSizePolicy.aspect).rounded()
        let spot = geometry.betSpots[safe: 1] ?? CGPoint(x: table.midX, y: table.maxY * 0.8)

        // The dealer's cards stand just clear of the headline's letters, and
        // the frame runs from a tenth of the picture above them to just below
        // the middle circle, at the tile's proportions.
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

        // The dealer: seven of clubs showing, the hole card beside it.
        let dealer = CGPoint(x: geometry.dealerArea.x, y: dealerCenterY)
        TableArt.card(Card(.clubs, .seven), center: CGPoint(x: dealer.x - cardWidth * 0.36, y: dealer.y),
                      angle: -0.02, renderer: renderer, context: ctx)
        TableArt.card(nil, center: CGPoint(x: dealer.x + cardWidth * 0.36, y: dealer.y + 2),
                      angle: 0.03, renderer: renderer, context: ctx)

        // The bet — two chips — in the middle circle, and the natural in the
        // card band above it, where the geometry keeps the lettering away.
        let r = geometry.betSpotRadius * 0.46
        TableArt.chipStack([100, 25], base: CGPoint(x: spot.x, y: spot.y + r * 0.55), radius: r, context: ctx, seed: 8)
        let hand = geometry.playerCardAnchor(forBetSpot: 1)
        TableArt.card(Card(.spades, .ace), center: CGPoint(x: hand.x - cardWidth * 0.30, y: hand.y + cardHeight * 0.02),
                      angle: -0.09, renderer: renderer, context: ctx, lifted: true)
        TableArt.card(Card(.hearts, .king), center: CGPoint(x: hand.x + cardWidth * 0.30, y: hand.y - cardHeight * 0.02),
                      angle: 0.08, renderer: renderer, context: ctx, lifted: true)
        ctx.restoreGState()
    }
}
