//
//  SolitaireArtwork.swift
//  Solitaire's cover: a game under way, told in six cards rather than
//  fifty-two — the stock, a run cascading down the middle, and the first ace
//  gone up to its foundation.
//
//  A miniature of the whole board reads as a thumbnail screenshot: at tile
//  size its cards are too small to show their indices. A cover is a still
//  life instead — a few cards, large enough to read, on the lit cloth, with a
//  clear margin on every side.
//

import AppKit

enum SolitaireArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        TableArt.cloth(.green, in: rect, lamp: CGPoint(x: 0.5, y: 0.32), context: ctx)

        // Cards a fifth of the tile wide, unless the tile is too short for
        // the run to fit between the margins.
        let pad = min(rect.width, rect.height) * 0.09
        let fan: CGFloat = 0.25
        let byHeight = (rect.height - pad * 2) / (1 + 3 * fan) * 0.70
        let cardWidth = min(rect.width * 0.21, byHeight).rounded()
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)
        let h = renderer.size.height
        let top = rect.minY + pad + h / 2

        // The stock on the left, a card or two thick.
        let stock = CGPoint(x: rect.minX + rect.width * 0.19, y: top)
        TableArt.card(nil, center: CGPoint(x: stock.x + 1.5, y: stock.y + 1.5), renderer: renderer, context: ctx)
        TableArt.card(nil, center: stock, renderer: renderer, context: ctx)

        // The run down the middle, each card a quarter of a card below the
        // last, the column lying a hair off square.
        let run = [Card(.spades, .king), Card(.hearts, .queen), Card(.clubs, .jack), Card(.diamonds, .ten)]
        let angle: CGFloat = -0.035
        for (i, card) in run.enumerated() {
            let dy = CGFloat(i) * h * fan
            TableArt.card(card, center: CGPoint(x: rect.midX - dy * sin(angle), y: top + dy * cos(angle)),
                          angle: angle, renderer: renderer, context: ctx)
        }

        // The ace, gone up to its foundation on the right.
        let foundation = CGPoint(x: rect.maxX - rect.width * 0.19, y: top)
        TableArt.card(Card(.hearts, .ace), center: foundation, angle: 0.02, renderer: renderer, context: ctx)
        ctx.restoreGState()
    }
}
