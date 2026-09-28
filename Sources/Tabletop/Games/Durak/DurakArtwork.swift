//
//  DurakArtwork.swift
//  Durak's cover: the thirty-six-card deck with the trump turned across under
//  it, an attack beaten on the table, and the player's fan rising from the
//  bottom of the picture.
//
//  Laid out with the kit's own `TableLayout`, so the deck, the trump and the
//  fan sit exactly as the game will put them.
//

import AppKit

enum DurakArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        TableArt.cloth(.slate, in: rect, lamp: CGPoint(x: 0.52, y: 0.40), context: ctx)

        let cardWidth = (rect.width * 0.105).rounded()
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)
        let size = renderer.size

        // The deck on the left, the trump lying across under it.
        let deck = CGPoint(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.36)
        let trump = TableLayout.trump(underDeckAt: deck, cardSize: size)
        TableArt.card(Card(.hearts, .nine), center: trump.position, angle: trump.rotation, renderer: renderer, context: ctx)
        for pose in TableLayout.deck(count: 6, center: deck, cardSize: size) {
            TableArt.card(nil, center: pose.position, renderer: renderer, context: ctx)
        }

        // An attack and its defence: each beating card across the one it beats.
        let fights = [(Card(.clubs, .eight), Card(.clubs, .queen)), (Card(.diamonds, .eight), Card(.hearts, .six))]
        let pairs = TableLayout.battlePairs(count: fights.count,
                                            center: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.34),
                                            cardSize: size)
        for (pair, fight) in zip(pairs, fights) {
            TableArt.card(fight.0, center: pair.attack.position, angle: pair.attack.rotation, renderer: renderer, context: ctx)
            TableArt.card(fight.1, center: pair.defence.position, angle: pair.defence.rotation, renderer: renderer, context: ctx)
        }

        // The hand, fanned up from below the picture, the trumps on the right.
        let hand = [Card(.spades, .six), Card(.clubs, .jack), Card(.diamonds, .ten), Card(.clubs, .ace),
                    Card(.hearts, .seven), Card(.hearts, .king), Card(.hearts, .ace)]
        let bigRenderer = TableArt.cardRenderer(width: (cardWidth * 1.2).rounded(), context: ctx)
        let anchor = CGPoint(x: rect.midX, y: rect.maxY - bigRenderer.size.height * 0.26)
        let fan = TableLayout.fan(count: hand.count, anchor: anchor, cardSize: bigRenderer.size)
        for (pose, card) in zip(fan, hand) {
            TableArt.card(card, center: pose.position, angle: pose.rotation, renderer: bigRenderer, context: ctx,
                          lifted: true)
        }
        ctx.restoreGState()
    }
}
