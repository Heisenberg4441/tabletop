//
//  Layout.swift
//  Where every card goes, as pure geometry.
//
//  The whole animation strategy rests on this file: the board is a function of
//  the game state, so any change — a move, an undo, a restart, a window resize —
//  is expressed as "recompute the placements and let the layers glide to their
//  new homes". Nothing has to know what kind of change it was.
//

import CoreGraphics
import Foundation

/// Where one card sits on the table.
struct CardPlacement: Equatable {
    var card: Card
    var frame: CGRect
    var faceUp: Bool
    /// Stacking order across the whole board, so a card flying from one pile
    /// to another passes above everything it crosses.
    var z: Int
    var pile: PileID
    /// Position within its own pile, bottom card first.
    var indexInPile: Int
}

/// Slots that are drawn even when no card is on them.
struct PilePlacement: Equatable {
    var pile: PileID
    var frame: CGRect
}

struct BoardLayout: Equatable {

    // Every metric below is a multiple of the card width, so the board is the
    // same design at any size.
    private enum Ratio {
        static let cardAspect: CGFloat = 0.70          // width / height, as real cards are
        static let sideMargin: CGFloat = 0.35
        static let topMargin: CGFloat = 0.30
        static let bottomMargin: CGFloat = 0.28
        static let columnGap: CGFloat = 0.20
        static let rowGap: CGFloat = 0.42
        static let faceDownFan: CGFloat = 0.15
        static let faceUpFan: CGFloat = 0.31
        static let minFaceUpFan: CGFloat = 0.13        // never overlap past the corner index
        static let minFaceDownFan: CGFloat = 0.055
        static let wasteFan: CGFloat = 0.30
        static let cornerRadius: CGFloat = 0.062
    }

    static let minimumCardWidth: CGFloat = 56
    static let maximumCardWidth: CGFloat = 168

    let bounds: CGRect
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let cornerRadius: CGFloat
    /// Top-left of the board's content, once it has been centred in `bounds`.
    let origin: CGPoint
    let columnGap: CGFloat
    let rowGap: CGFloat
    let wasteFan: CGFloat
    /// Vertical room a tableau column may use before its fan must tighten.
    let tableauHeight: CGFloat

    var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }

    init(bounds: CGRect) {
        self.bounds = bounds

        // Solve for the largest card that fits the width, then check the
        // height can take a reasonable fan and shrink if it cannot.
        let widthUnits = 7 + 6 * Ratio.columnGap + 2 * Ratio.sideMargin
        let byWidth = max(bounds.width, 1) / widthUnits

        let heightUnits = Ratio.topMargin + (1 / Ratio.cardAspect) + Ratio.rowGap
            + (1 / Ratio.cardAspect) + 6 * Ratio.faceUpFan + Ratio.bottomMargin
        let byHeight = max(bounds.height, 1) / heightUnits

        let width = min(max(min(byWidth, byHeight), Self.minimumCardWidth), Self.maximumCardWidth)
        self.cardWidth = width.rounded()
        self.cardHeight = (width / Ratio.cardAspect).rounded()
        self.cornerRadius = max(3, (width * Ratio.cornerRadius).rounded())
        self.columnGap = (width * Ratio.columnGap).rounded()
        self.rowGap = (width * Ratio.rowGap).rounded()
        self.wasteFan = (width * Ratio.wasteFan).rounded()

        let contentWidth = 7 * cardWidth + 6 * columnGap
        let x = bounds.minX + ((bounds.width - contentWidth) / 2).rounded()

        // Centre the board vertically in whatever room is left over. The height
        // used for the calculation is a fixed reference — the space a fully
        // grown board wants — not the height of the current deal, so the table
        // does not creep up and down as columns get longer during a game.
        let referenceHeight = heightUnits * width
        let slack = max(0, bounds.height - referenceHeight)
        let y = bounds.minY + (width * Ratio.topMargin + slack / 2).rounded()
        self.origin = CGPoint(x: max(bounds.minX, x), y: y)

        let used = y - bounds.minY + cardHeight + rowGap + (width * Ratio.bottomMargin)
        self.tableauHeight = max(cardHeight, bounds.height - used)
    }

    // MARK: Slots

    func columnX(_ column: Int) -> CGFloat {
        origin.x + CGFloat(column) * (cardWidth + columnGap)
    }

    var topRowY: CGFloat { origin.y }
    var tableauY: CGFloat { origin.y + cardHeight + rowGap }

    /// The resting frame of a pile's base slot.
    func frame(of pile: PileID) -> CGRect {
        switch pile.kind {
        case .stock:
            return CGRect(x: columnX(0), y: topRowY, width: cardWidth, height: cardHeight)
        case .waste:
            return CGRect(x: columnX(1), y: topRowY, width: cardWidth, height: cardHeight)
        case .foundation:
            return CGRect(x: columnX(3 + pile.index), y: topRowY, width: cardWidth, height: cardHeight)
        case .tableau:
            return CGRect(x: columnX(pile.index), y: tableauY, width: cardWidth, height: cardHeight)
        }
    }

    var pileSlots: [PilePlacement] {
        var slots: [PilePlacement] = [
            PilePlacement(pile: .stock, frame: frame(of: .stock)),
            PilePlacement(pile: .waste, frame: frame(of: .waste)),
        ]
        for i in 0..<4 { slots.append(PilePlacement(pile: .foundation(i), frame: frame(of: .foundation(i)))) }
        for i in 0..<7 { slots.append(PilePlacement(pile: .tableau(i), frame: frame(of: .tableau(i)))) }
        return slots
    }

    // MARK: Fan compression

    /// How far apart the cards of one column sit.
    ///
    /// A long column has to tighten up or it runs off the bottom of the window.
    /// Both offsets shrink by the same factor so the column keeps its rhythm,
    /// and neither goes below the point where the corner index disappears —
    /// past that the player cannot read the column at all, so the cards
    /// overlap the window's bottom edge instead, which is the lesser evil and
    /// what every good implementation does.
    func fanOffsets(column: TableauColumn) -> (down: CGFloat, up: CGFloat) {
        let base = cardWidth
        var down = (base * Ratio.faceDownFan).rounded()
        var up = (base * Ratio.faceUpFan).rounded()

        let downCount = CGFloat(max(0, column.down.count))
        let upCount = CGFloat(max(0, column.up.count - 1))
        let slack = max(0, tableauHeight - cardHeight)
        let needed = downCount * down + upCount * up
        guard needed > slack else { return (down, up) }

        // Squeeze in stages rather than scaling both offsets together. A
        // face-down card carries no information beyond "there is a card here",
        // so tightening those costs the player nothing; tightening the face-up
        // cards hides the rank and suit they need to read. Spend the cheap
        // slack first and only then touch the expensive kind.
        let minDown = (base * Ratio.minFaceDownFan).rounded()
        let minUp = (base * Ratio.minFaceUpFan).rounded()

        let overflow = needed - slack
        let downSlack = downCount * (down - minDown)
        if downSlack >= overflow {
            if downCount > 0 { down = (down - overflow / downCount).rounded() }
            return (max(minDown, down), up)
        }

        down = minDown
        let remaining = downCount * down + upCount * up - slack
        if remaining > 0, upCount > 0 {
            up = max(minUp, (up - remaining / upCount).rounded())
        }
        return (down, up)
    }

    // MARK: Placements

    /// Every card on the board, in drawing order.
    func placements(for state: GameState) -> [CardPlacement] {
        var result: [CardPlacement] = []
        result.reserveCapacity(52)
        var z = 0

        // Stock: only the top few need to exist as separate cards, but keeping
        // them all placed means a recycle animates every card back.
        let stockFrame = frame(of: .stock)
        for (i, card) in state.stock.enumerated() {
            result.append(CardPlacement(card: card, frame: stockFrame, faceUp: false,
                                        z: z, pile: .stock, indexInPile: i))
            z += 1
        }

        // Waste: the last `wasteFan` cards spread to the right.
        let wasteFrame = frame(of: .waste)
        let fanned = min(max(state.wasteFan, state.waste.isEmpty ? 0 : 1), state.waste.count)
        for (i, card) in state.waste.enumerated() {
            let fromTop = state.waste.count - 1 - i
            let step = fanned - 1 - fromTop        // 0 for the oldest fanned card
            let dx = CGFloat(max(0, step)) * wasteFan
            result.append(CardPlacement(card: card, frame: wasteFrame.offsetBy(dx: dx, dy: 0),
                                        faceUp: true, z: z, pile: .waste, indexInPile: i))
            z += 1
        }

        // Foundations.
        for i in 0..<4 {
            let f = frame(of: .foundation(i))
            let top = Int(state.foundations[i])
            guard top > 0, let suit = Suit(rawValue: UInt8(i)) else { continue }
            for r in 1...top {
                let card = Card(suit, Rank(rawValue: UInt8(r))!)
                result.append(CardPlacement(card: card, frame: f, faceUp: true,
                                            z: z, pile: .foundation(i), indexInPile: r - 1))
                z += 1
            }
        }

        // Tableau.
        for i in 0..<7 {
            let column = state.tableau[i]
            let (down, up) = fanOffsets(column: column)
            var y = tableauY
            var index = 0
            for card in column.down {
                result.append(CardPlacement(
                    card: card,
                    frame: CGRect(x: columnX(i), y: y, width: cardWidth, height: cardHeight),
                    faceUp: false, z: z, pile: .tableau(i), indexInPile: index))
                y += down; z += 1; index += 1
            }
            for card in column.up {
                result.append(CardPlacement(
                    card: card,
                    frame: CGRect(x: columnX(i), y: y, width: cardWidth, height: cardHeight),
                    faceUp: true, z: z, pile: .tableau(i), indexInPile: index))
                y += up; z += 1; index += 1
            }
        }

        return result
    }

    // MARK: Hit testing

    /// What the player clicked. Walks the board from the top card down, so the
    /// visually frontmost card always wins.
    func target(at point: CGPoint, state: GameState, placements: [CardPlacement]) -> ClickTarget {
        for placement in placements.reversed() {
            // A fanned card's visible area is only the sliver above the next
            // card, except for the one on top. Using the full frame would make
            // clicks land on the card behind the one under the pointer.
            guard visibleRect(of: placement, in: placements).contains(point) else { continue }
            switch placement.pile.kind {
            case .stock:
                return .stock
            case .waste:
                // Only the topmost waste card can be picked up.
                return placement.indexInPile == state.waste.count - 1 ? .waste : .nothing
            case .foundation:
                return .foundation(placement.pile.index)
            case .tableau:
                let column = state.tableau[placement.pile.index]
                guard placement.indexInPile >= column.down.count else { return .nothing }
                let depth = column.count - 1 - placement.indexInPile
                return .tableauCard(column: placement.pile.index, depthFromTop: depth)
            }
        }

        // No card — did they hit an empty slot?
        for slot in pileSlots where slot.frame.contains(point) {
            switch slot.pile.kind {
            case .stock: return .stock
            case .waste: return .waste
            case .foundation: return .foundation(slot.pile.index)
            case .tableau: return .emptyTableau(slot.pile.index)
            }
        }
        return .nothing
    }

    /// The part of a card the player can actually see and therefore click.
    private func visibleRect(of placement: CardPlacement, in placements: [CardPlacement]) -> CGRect {
        guard let next = placements.first(where: {
            $0.pile == placement.pile && $0.indexInPile == placement.indexInPile + 1
        }) else {
            return placement.frame
        }
        if next.frame.minY > placement.frame.minY {
            return CGRect(x: placement.frame.minX, y: placement.frame.minY,
                          width: placement.frame.width,
                          height: next.frame.minY - placement.frame.minY)
        }
        if next.frame.minX > placement.frame.minX {
            return CGRect(x: placement.frame.minX, y: placement.frame.minY,
                          width: next.frame.minX - placement.frame.minX,
                          height: placement.frame.height)
        }
        // Perfectly stacked (stock, foundations): only the top card is visible.
        return .null
    }

    /// The pile a dragged card was dropped on, chosen by how much the dragged
    /// card overlaps each slot rather than by where the pointer is — that is
    /// what makes dropping feel forgiving.
    func dropTarget(for rect: CGRect, state: GameState) -> PileID? {
        var best: PileID?
        var bestArea: CGFloat = 0
        for slot in pileSlots {
            guard slot.pile.kind == .tableau || slot.pile.kind == .foundation else { continue }
            var target = slot.frame
            if slot.pile.kind == .tableau {
                let column = state.tableau[slot.pile.index]
                let (down, up) = fanOffsets(column: column)
                let extent = CGFloat(column.down.count) * down
                    + CGFloat(max(0, column.up.count - 1)) * up
                target.size.height += extent
            }
            let overlap = target.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea { bestArea = area; best = slot.pile }
        }
        // Require a real overlap, not a corner graze.
        let minimum = rect.width * rect.height * 0.12
        return bestArea >= minimum ? best : nil
    }
}

extension CGRect {
    /// Zero for a null rect, which is what `intersection` returns when two
    /// rectangles do not overlap at all.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
