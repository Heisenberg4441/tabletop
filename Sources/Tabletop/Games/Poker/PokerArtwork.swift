//
//  PokerArtwork.swift
//  Poker's cover: pocket aces peeled up at the rail of an oval table, the
//  board and the pot in the middle.
//
//  Built from the kit rather than beside it — the same oval, rail and cloth
//  `CardTableView` paints for the real table, framed close so the far rail
//  curves across the top of the picture, and the same chips `ChipStackLayer`
//  stands on it — so the cover and the game can never drift apart.
//

import AppKit

enum PokerArtwork {

    static func draw(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        // A table bigger than the picture, so only its far half shows.
        let virtual = CGRect(x: rect.minX - rect.width * 0.22, y: rect.minY - rect.height * 0.16,
                             width: rect.width * 1.44, height: rect.height * 1.62)
        let geometry = TableSurface.geometry(for: .oval, in: virtual, cardWidth: rect.width * 0.1)
        TableSurface.paint(geometry, cloth: .blue, context: ctx)

        let cardWidth = (rect.width * 0.082).rounded()
        let renderer = TableArt.cardRenderer(width: cardWidth, context: ctx)
        let h = renderer.size.height

        // The board: flop and turn, the river still to come.
        let boardY = rect.minY + rect.height * 0.44
        let board = [Card(.hearts, .ace), Card(.diamonds, .king), Card(.clubs, .seven), Card(.spades, .queen)]
        let row = TableLayout.row(count: 5, center: CGPoint(x: rect.midX, y: boardY), cardSize: renderer.size, gap: 0.12)
        for (pose, card) in zip(row, board) {
            TableArt.card(card, center: pose.position, renderer: renderer, context: ctx)
        }

        // The pot, in front of the board.
        let r = cardWidth * 0.30
        let potY = boardY + h * 1.02
        let potX = rect.midX + cardWidth * 1.9
        TableArt.chipStack([100, 100, 100, 100], base: CGPoint(x: potX - r * 2.15, y: potY), radius: r, context: ctx, seed: 1)
        TableArt.chipStack([500, 500, 500], base: CGPoint(x: potX, y: potY - r * 0.3), radius: r, context: ctx, seed: 2)
        TableArt.chipStack([25, 25, 25, 25, 25], base: CGPoint(x: potX + r * 2.15, y: potY), radius: r, context: ctx, seed: 3)

        // The player's stacks at the rail, and the dealer button.
        let front = rect.minY + rect.height * 0.97
        TableArt.chipStack([100, 100, 100, 100, 100, 100], base: CGPoint(x: rect.midX - cardWidth * 2.6, y: front),
                           radius: r * 1.05, context: ctx, seed: 4)
        TableArt.chipStack([25, 25, 25, 25], base: CGPoint(x: rect.midX - cardWidth * 1.85, y: front + r * 0.3),
                           radius: r * 1.05, context: ctx, seed: 5)
        if let button = AvatarRenderer.dealerButton(diameter: r * 1.5, scale: max(1, ctx.ctm.a)) {
            let side = r * 1.5 + 6
            TableArt.draw(button, in: CGRect(x: rect.midX - cardWidth * 3.8, y: boardY + h * 0.55, width: side, height: side),
                          context: ctx)
        }

        // Pocket aces, peeled up at the front.
        let bigRenderer = TableArt.cardRenderer(width: (cardWidth * 1.45).rounded(), context: ctx)
        let handY = rect.maxY - bigRenderer.size.height * 0.30
        TableArt.card(Card(.spades, .ace), center: CGPoint(x: rect.midX - cardWidth * 0.42, y: handY),
                      angle: -0.16, renderer: bigRenderer, context: ctx, lifted: true)
        TableArt.card(Card(.hearts, .ace), center: CGPoint(x: rect.midX + cardWidth * 0.42, y: handY - cardWidth * 0.06),
                      angle: 0.12, renderer: bigRenderer, context: ctx, lifted: true)
        ctx.restoreGState()
    }
}
