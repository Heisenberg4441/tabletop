//
//  Rules.swift
//  Dealing, move generation, and the click-to-move logic.
//

import Foundation

// MARK: - Dealing

extension GameState {

    /// Builds the classic Klondike layout for a given deal number. The same
    /// number always produces the same cards, on any Mac, forever.
    static func deal(number: Int, drawCount: Int = 1, redealLimit: Int? = nil) -> GameState {
        var rng = DeterministicRNG(seed: DealNumber.seed(for: number))
        var deck = Card.full
        rng.shuffle(&deck)
        return deal(deck: deck, drawCount: drawCount, redealLimit: redealLimit)
    }

    /// Lays out an already-shuffled deck. Split out so the solver's deal
    /// generator can test a candidate shuffle without going through a number.
    static func deal(deck: [Card], drawCount: Int = 1, redealLimit: Int? = nil) -> GameState {
        precondition(deck.count == 52)
        var state = GameState()
        state.drawCount = drawCount
        state.redealLimit = redealLimit

        var next = deck.count - 1
        func take() -> Card {
            defer { next -= 1 }
            return deck[next]
        }

        // Deal row by row across the triangle: column j receives j+1 cards and
        // the last one to land on it is the face-up card.
        for row in 0..<7 {
            for column in row..<7 {
                let card = take()
                if row == column {
                    state.tableau[column].up.append(card)
                } else {
                    state.tableau[column].down.append(card)
                }
            }
        }

        state.stock = Array(deck[0...next])
        state.wasteFan = 0
        return state
    }

    /// Sanity check used by the tests and by debug builds after every move:
    /// all 52 cards, each exactly once.
    var isConsistent: Bool {
        var seen = Set<UInt8>()
        for c in stock { if !seen.insert(c.code).inserted { return false } }
        for c in waste { if !seen.insert(c.code).inserted { return false } }
        for column in tableau {
            for c in column.down { if !seen.insert(c.code).inserted { return false } }
            for c in column.up { if !seen.insert(c.code).inserted { return false } }
        }
        for (i, top) in foundations.enumerated() {
            guard let suit = Suit(rawValue: UInt8(i)) else { return false }
            for r in 1...13 where UInt8(r) <= top {
                if !seen.insert(Card(suit, Rank(rawValue: UInt8(r))!).code).inserted { return false }
            }
        }
        return seen.count == 52
    }
}

// MARK: - Move generation

extension GameState {

    /// Every legal move in the current position, in no particular order.
    /// Used by the hint engine and by the "no moves left" check.
    func allMoves(includeFoundationToTableau: Bool = true) -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(24)

        // Waste → anywhere
        if let card = waste.last {
            if canPlaceOnFoundation(card) { moves.append(.wasteToFoundation) }
            for column in 0..<7 where canPlace(card, onColumn: column) {
                moves.append(.wasteToTableau(column: column))
            }
        }

        for from in 0..<7 {
            let column = tableau[from]
            guard !column.up.isEmpty else { continue }

            if let top = column.topCard, canPlaceOnFoundation(top) {
                moves.append(.tableauToFoundation(column: from))
            }

            // Every face-up card in the run is a candidate pick-up point.
            for depth in 1...column.up.count {
                let card = column.up[column.up.count - depth]
                let movesWholeColumn = (depth == column.count)
                for to in 0..<7 where to != from {
                    if tableau[to].isEmpty {
                        // A king already sitting on bare table may be dragged to
                        // another empty column, but the move changes nothing, so
                        // it is not offered as a hint and never counts as the
                        // move that keeps a dead game alive.
                        guard card.rank == .king, !movesWholeColumn else { continue }
                        moves.append(.tableauToTableau(from: from, to: to, count: depth))
                    } else if card.canStack(onTableau: tableau[to].topCard!) {
                        moves.append(.tableauToTableau(from: from, to: to, count: depth))
                    }
                }
            }
        }

        if includeFoundationToTableau {
            for i in 0..<4 where foundations[i] > 0 {
                let suit = Suit(rawValue: UInt8(i))!
                let card = Card(suit, Rank(rawValue: foundations[i])!)
                for column in 0..<7 where canPlace(card, onColumn: column) {
                    moves.append(.foundationToTableau(suit: suit, column: column))
                }
            }
        }

        if !stock.isEmpty {
            moves.append(.draw(count: drawCount))
        } else if canRecycle {
            moves.append(.recycle)
        }

        return moves
    }

    /// True when the player is out of useful moves.
    ///
    /// Two kinds of move are deliberately not counted as progress:
    ///
    /// * cycling the stock, which by itself changes nothing — so instead of
    ///   guessing we walk the whole cycle and ask whether any card that will
    ///   come up is actually playable;
    /// * pulling a card back off a foundation, which is legal at any time an
    ///   empty column exists and would therefore make this property
    ///   permanently false, hiding every genuinely dead game.
    ///
    /// The second exclusion is what Microsoft Solitaire does too. It can in
    /// principle call a game dead that a foundation retreat would revive, but
    /// that position is vanishingly rare and the alternative — never telling
    /// the player the game is over — is far worse.
    var isStuck: Bool {
        if isWon { return false }
        // Any real move at all means we are not stuck.
        if allMoves(includeFoundationToTableau: false).contains(where: { !$0.isStockCycling }) {
            return false
        }

        // Which cards will ever reach the top of the waste?
        //
        // Draw-one exposes every card, so this is the whole packet. Draw-three
        // exposes only the last card of each batch of three, and — this is the
        // part that surprises people — turning the waste back over reproduces
        // the *identical* sequence when nothing has been played from it. So a
        // card stranded in the middle of a batch stays stranded no matter how
        // many redeals remain. Only a recycle with cards already sitting on the
        // waste shifts the batching, because the pass then starts three cards
        // out of step.
        var reachable = drawBoundaryCards(of: stock)
        if let top = waste.last { reachable.append(top) }
        if hasRedealsRemaining && !(stock.isEmpty && waste.isEmpty) {
            // After draining the stock, the waste holds `waste + reverse(stock)`;
            // turning it over makes the next stock `stock + reverse(waste)`.
            reachable.append(contentsOf: drawBoundaryCards(of: stock + waste.reversed()))
        }

        for card in reachable {
            if canPlaceOnFoundation(card) { return false }
            for column in 0..<7 where canPlace(card, onColumn: column) { return false }
        }
        return true
    }

    /// The cards of `packet` that land face up on top of the waste when it is
    /// dealt out `drawCount` at a time. The last batch may be short.
    private func drawBoundaryCards(of packet: [Card]) -> [Card] {
        guard !packet.isEmpty else { return [] }
        var result: [Card] = []
        result.reserveCapacity(packet.count / max(1, drawCount) + 1)
        var index = packet.count - 1
        while index >= 0 {
            let take = min(drawCount, index + 1)
            result.append(packet[index - take + 1])
            index -= take
        }
        return result
    }
}

// MARK: - Click to move

/// Where a click landed. The view translates a point into one of these and
/// hands it to the game; the game decides what, if anything, should happen.
enum ClickTarget: Equatable {
    case stock
    case waste
    case foundation(Int)
    /// A face-up card in a tableau column, identified by how many cards sit on
    /// top of it (0 = the top card itself).
    case tableauCard(column: Int, depthFromTop: Int)
    case emptyTableau(Int)
    case nothing
}

extension GameState {

    /// The move a single click should perform — the heart of playing this game
    /// with one hand. Returns `nil` when the click has nothing to do.
    ///
    /// - Parameter foundationFirst: when a card could go either to a
    ///   foundation or onto another column, prefer the foundation. This is what
    ///   players expect from a tap; turning it off makes clicks build the
    ///   tableau instead, which suits players who like to keep low cards in play.
    func autoMove(for target: ClickTarget, foundationFirst: Bool = true) -> Move? {
        switch target {

        case .stock:
            if !stock.isEmpty { return .draw(count: drawCount) }
            return canRecycle ? .recycle : nil

        case .waste:
            guard let card = waste.last else { return nil }
            let toFoundation: Move? = canPlaceOnFoundation(card) ? .wasteToFoundation : nil
            let toTableau: Move? = bestColumn(for: card, from: nil).map { .wasteToTableau(column: $0) }
            return choose(foundation: toFoundation, tableau: toTableau, card: card,
                          foundationFirst: foundationFirst)

        case .tableauCard(let column, let depthFromTop):
            let up = tableau[column].up
            guard depthFromTop < up.count else { return nil }
            let count = depthFromTop + 1
            let card = up[up.count - count]

            // A run of more than one card can only ever go to another column.
            if count > 1 {
                return bestColumn(for: card, from: column, runLength: count)
                    .map { .tableauToTableau(from: column, to: $0, count: count) }
            }

            let toFoundation: Move? = canPlaceOnFoundation(card)
                ? .tableauToFoundation(column: column) : nil
            let toTableau: Move? = bestColumn(for: card, from: column, runLength: 1)
                .map { .tableauToTableau(from: column, to: $0, count: 1) }
            return choose(foundation: toFoundation, tableau: toTableau, card: card,
                          foundationFirst: foundationFirst)

        case .foundation, .emptyTableau, .nothing:
            // Clicking a foundation deliberately does nothing: pulling a card
            // back down is a real decision, so it stays a drag.
            return nil
        }
    }

    private func choose(foundation: Move?, tableau: Move?, card: Card,
                        foundationFirst: Bool) -> Move? {
        guard let foundation else { return tableau }
        guard let tableau else { return foundation }
        if foundationFirst { return foundation }
        // Even when building the tableau is preferred, an ace or a two is never
        // worth keeping in play.
        return card.value <= 2 ? foundation : tableau
    }

    /// Picks the most useful column to drop `card` on.
    ///
    /// Two columns can legally accept the same card (both black sixes want the
    /// same red five). Preferring the column with fewer face-down cards keeps
    /// the buried columns diggable instead of piling more on top of them.
    func bestColumn(for card: Card, from source: Int?, runLength: Int = 1) -> Int? {
        var best: Int?
        var bestScore = Int.min

        for column in 0..<7 where column != source {
            // `canPlace` already keeps everything but a king out of an empty
            // column; a king that is the whole of its own column is welcome to
            // move to another empty one, which is what the player asked for by
            // clicking it.
            guard canPlace(card, onColumn: column) else { continue }
            var score = 0
            if !tableau[column].isEmpty { score += 1000 }          // real stacks first
            score -= tableau[column].down.count * 10               // do not bury diggable columns
            score -= column                                        // stable, left-to-right tiebreak
            if score > bestScore { bestScore = score; best = column }
        }

        return best
    }
}

// MARK: - Safe autoplay

extension GameState {

    /// The standard "safe to send up" rule: a card can go to its foundation
    /// with no risk of being needed below, once both opposite-colour
    /// foundations have reached at least one rank lower.
    ///
    /// Aces and twos are always safe.
    func isSafeToAutoPlay(_ card: Card) -> Bool {
        guard canPlaceOnFoundation(card) else { return false }
        if card.value <= 2 { return true }
        let opposite: [Int] = card.isRed ? [0, 3] : [1, 2]   // clubs/spades vs diamonds/hearts
        let need = card.value - 1
        return opposite.allSatisfy { Int(foundations[$0]) >= need }
    }

    /// Every card that can be sent to a foundation right now without thinking.
    func safeAutoPlayMove() -> Move? {
        if let card = waste.last, isSafeToAutoPlay(card) { return .wasteToFoundation }
        for column in 0..<7 {
            if let card = tableau[column].topCard, isSafeToAutoPlay(card) {
                return .tableauToFoundation(column: column)
            }
        }
        return nil
    }

    /// One step of the end-game auto-finish: the lowest card that will go up.
    func autoFinishMove() -> Move? {
        var best: Move?
        var bestValue = Int.max
        if let card = waste.last, canPlaceOnFoundation(card), card.value < bestValue {
            bestValue = card.value
            best = .wasteToFoundation
        }
        for column in 0..<7 {
            if let card = tableau[column].topCard, canPlaceOnFoundation(card), card.value < bestValue {
                bestValue = card.value
                best = .tableauToFoundation(column: column)
            }
        }
        if best == nil {
            // Nothing on top is playable but cards remain in the stock: turn
            // one over and try again.
            if !stock.isEmpty { return .draw(count: drawCount) }
            if canRecycle { return .recycle }
        }
        return best
    }
}
