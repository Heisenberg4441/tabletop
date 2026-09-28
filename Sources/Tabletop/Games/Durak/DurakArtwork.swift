//
//  DurakArtwork.swift
//  Durak's cover: a close-up of the table at the moment the game is about.
//
//  The opponent's hand, face down, reaching in from the top edge; the deck
//  on the left with the trump turned across under it; in the middle an
//  attack of eights, both beaten — one with a higher club, one with a trump;
//  the bito pile thrown down on the right; and the player's fan rising from
//  the bottom edge, sorted with the trumps at the right, the cards that
//  could be thrown in lifted and lit gold — exactly as the table shows them.
//
//  Laid out with the kit's own `TableLayout`, so the deck, the trump and the
//  fans sit as the game puts them.
//

import AppKit

enum DurakArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        TableArt.cloth(.slate, in: rect, lamp: CGPoint(x: 0.50, y: 0.44), context: ctx)

        let cardWidth = min(rect.width * 0.125, rect.height * 0.27 * 0.70).rounded()
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)
        let size = renderer.size
        let trumps = Suit.hearts

        // The opponent across the table: a face-down fan, half off the top.
        let topFan = TableLayout.fan(count: 6, anchor: CGPoint(x: rect.midX, y: rect.minY + size.height * 0.14),
                                     cardSize: size, side: .top,
                                     style: FanStyle(spacing: 0.24, maximumSpread: 0.40, radius: 3.0), scale: 0.78)
        let small = TableArt.cardRenderer(width: (cardWidth * 0.78).rounded(), context: ctx)
        for pose in topFan {
            TableArt.card(nil, center: pose.position, angle: pose.rotation, renderer: small, context: ctx)
        }

        // The deck on the left, the trump across under it.
        let deck = CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.41)
        let trump = TableLayout.trump(underDeckAt: deck, cardSize: size)
        TableArt.card(Card(trumps, .nine), center: trump.position, angle: trump.rotation, renderer: renderer, context: ctx)
        for pose in TableLayout.deck(count: 7, center: deck, cardSize: size, visibleThickness: 6) {
            TableArt.card(nil, center: pose.position, renderer: renderer, context: ctx)
        }

        // The bito pile on the right, thrown down anyhow.
        let pile = CGPoint(x: rect.maxX - rect.width * 0.115, y: rect.minY + rect.height * 0.39)
        for pose in TableLayout.discardPile(count: 5, center: pile, cardSize: size, seed: 4, maxAngle: 0.42) {
            TableArt.card(nil, center: pose.position, angle: pose.rotation, renderer: renderer, context: ctx)
        }

        // The fight: two eights, each beaten — the beating card across it,
        // down and to the right, turned about twelve degrees.
        let fights = [(Card(.clubs, .eight), Card(.clubs, .queen)), (Card(.diamonds, .eight), Card(trumps, .six))]
        let middle = CGPoint(x: rect.midX + rect.width * 0.01, y: rect.minY + rect.height * 0.39)
        for (i, fight) in fights.enumerated() {
            let x = middle.x + (CGFloat(i) - 0.5) * size.width * 1.55
            TableArt.card(fight.0, center: CGPoint(x: x - size.width * 0.10, y: middle.y - size.height * 0.06),
                          angle: i == 0 ? -0.04 : 0.02, renderer: renderer, context: ctx)
            TableArt.card(fight.1, center: CGPoint(x: x + size.width * 0.14, y: middle.y + size.height * 0.09),
                          angle: i == 0 ? 0.21 : 0.19, renderer: renderer, context: ctx)
        }

        // The player's hand rising from the bottom edge, suits together and
        // trumps last; the sixes and eights (ranks on the table) lifted and
        // lit, as the game shows what may be thrown in.
        let hand = Card.durakSorted([Card(.clubs, .ten), Card(.clubs, .ace), Card(.diamonds, .jack), Card(.spades, .six),
                                     Card(.spades, .eight), Card(trumps, .eight), Card(trumps, .king)],
                                    trump: trumps, order: .bySuit)
        let playable: Set<Card> = [Card(.spades, .six), Card(.spades, .eight), Card(trumps, .eight)]
        let big = TableArt.cardRenderer(width: (cardWidth * 1.12).rounded(), context: ctx)
        let anchor = CGPoint(x: rect.midX, y: rect.maxY - big.size.height * 0.24)
        let fan = TableLayout.fan(count: hand.count, anchor: anchor, cardSize: big.size,
                                  style: FanStyle(spacing: 0.52, maximumSpread: 0.66, radius: 3.4))
        for (pose, card) in zip(fan, hand) {
            var center = pose.position
            let isPlayable = playable.contains(card)
            if isPlayable {
                let lift = big.size.height * 0.10
                center.x += sin(pose.rotation) * lift
                center.y -= cos(pose.rotation) * lift
                glow(card, center: center, angle: pose.rotation, renderer: big, context: ctx)
            }
            TableArt.card(card, center: center, angle: pose.rotation, renderer: big, context: ctx, lifted: isPlayable)
        }
        ctx.restoreGState()
    }

    /// The table's "you can play this": a soft gold light under the card.
    private static func glow(_ card: Card, center: CGPoint, angle: CGFloat, renderer: CardRenderer, context ctx: CGContext) {
        guard let image = renderer.faceImage(for: card) else { return }
        let size = renderer.size
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setShadow(offset: .zero, blur: size.width * 0.22, color: Palette.accent.withAlphaComponent(0.85).cgColor)
        TableArt.draw(image, in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                      context: ctx)
        ctx.restoreGState()
    }
}
