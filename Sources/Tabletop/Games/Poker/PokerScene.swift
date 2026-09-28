//
//  PokerScene.swift
//  What the poker table shows at one moment: every seat's stack, bet, cards
//  and caption, the board, the pots, the button, and the showdown's
//  highlight — as plain values.
//
//  The table view draws a scene; it never reads the engine directly. Two
//  things produce scenes:
//
//  * `PokerScene(table:)` — the settled picture of a `PokerTable`, whatever
//    phase it is in: a hand in progress, a runout with the hands turned up,
//    or the hand just paid with the winning cards lifted. It is what a
//    resize, a screenshot or a resumed game shows, and what every animated
//    sequence ends on.
//  * The table view's choreography, which starts from the scene on screen
//    and changes it a step at a time as the engine's events play out — so
//    the chips in the pot grow when the bets land, not when the engine
//    decided — and finishes by settling on `PokerScene(table:)`.
//

import AppKit

struct PokerSeatScene: Equatable {
    var name: String
    var isHuman: Bool
    /// Chips behind, as the plate shows them.
    var stack: Int
    /// Chips in front of the seat this street.
    var bet: Int
    /// The hole cards on the table (empty when none were dealt, or they
    /// went into the muck).
    var cards: [Card]
    /// Turned face up. The player's own always are.
    var faceUp: Bool
    /// Shown for everyone to see — larger and opened out.
    var revealed: Bool
    var status: PokerPlayer.Status
    /// Took chips from the pot this hand.
    var isWinner: Bool
    /// Tournament place, once out of the tournament.
    var place: Int?
    /// What the seat last did this street, when that is worth saying.
    var caption: String?
    /// The made hand at the showdown ("Two Pair").
    var handName: String?
}

struct PokerScene: Equatable {
    var seats: [PokerSeatScene]
    var board: [Card]
    /// The pots in the middle, main pot first.
    var pots: [Int]
    var button: Int?
    /// Whose turn it is.
    var toAct: Int?
    /// A computer player making up its mind.
    var thinking: Int?
    /// The winning five cards, lifted and lit.
    var highlight: Set<Card>
    /// Every other card darkened, while `highlight` shows.
    var dimsOthers: Bool
    /// The hand's result in the pot's place: "Anna wins 1,240" and the hand
    /// that won it.
    var result: PokerResultText?
    /// The player's own best hand so far, for the pill by their cards.
    var humanHand: String?
    var humanHandIsWinner: Bool

    static let empty = PokerScene(seats: [], board: [], pots: [], button: nil, toAct: nil, thinking: nil,
                                  highlight: [], dimsOthers: false, result: nil, humanHand: nil,
                                  humanHandIsWinner: false)
}

struct PokerResultText: Equatable {
    var title: String
    var subtitle: String
    /// The player took (part of) the pot.
    var humanWon: Bool
}

extension PokerScene {

    /// The settled picture of `table`.
    init(table: PokerTable) {
        self = .empty
        let summary = Self.displayedSummary(table)
        let shown = Set(summary?.shown.map(\.seat) ?? [])
        let winnings = summary?.winnings ?? [:]
        let revealedDuringHand = table.handsAreRevealed && table.phase != .betweenHands

        seats = table.players.map { p in
            var cards: [Card] = []
            var faceUp = p.isHuman
            var revealed = false
            if summary != nil {
                // The hand has been paid: the cards that were shown stay up;
                // a winner nobody called keeps theirs face down; the
                // player's own stay in front of them unless they folded.
                if shown.contains(p.seat) {
                    cards = p.holeCards
                    faceUp = true
                    revealed = !p.isHuman
                } else if (p.status == .active || p.status == .allIn) && p.holeCards.count == 2 {
                    cards = p.holeCards
                }
            } else if p.isInHand && p.holeCards.count == 2 {
                cards = p.holeCards
                if revealedDuringHand {
                    faceUp = true
                    revealed = !p.isHuman
                }
            }
            var caption: String?
            if summary == nil, let action = p.lastAction, action.kind != .smallBlind, action.kind != .bigBlind,
               action.kind != .fold {
                caption = action.caption
            }
            return PokerSeatScene(name: p.name, isHuman: p.isHuman, stack: p.stack, bet: p.bet, cards: cards,
                                  faceUp: faceUp, revealed: revealed, status: p.status,
                                  isWinner: (winnings[p.seat] ?? 0) > 0, place: p.place, caption: caption,
                                  handName: nil)
        }
        board = table.board
        pots = table.pots.map(\.amount)
        button = table.button
        toAct = table.phase == .betting ? table.toAct : nil

        if let summary {
            let names = table.players.map(\.name)
            let headline = summary.headline(names: names, humanSeat: table.humanSeat)
            let humanWon = table.humanSeat.map { (winnings[$0] ?? 0) > 0 } ?? false
            if !headline.title.isEmpty {
                result = PokerResultText(title: headline.title, subtitle: headline.subtitle, humanWon: humanWon)
            }
            if let award = Self.featuredAward(summary), let hand = award.hand {
                highlight = Set(hand.cards)
                dimsOthers = true
            }
            for hand in summary.shown {
                guard let result = hand.result, seats.indices.contains(hand.seat), !seats[hand.seat].isHuman else { continue }
                seats[hand.seat].handName = result.name
            }
        }
        if let human = table.humanSeat, seats.indices.contains(human), seats[human].cards.count == 2 {
            humanHand = Self.handDescription(seats[human].cards, board: table.board)
            humanHandIsWinner = summary != nil && (winnings[human] ?? 0) > 0
        }
    }

    /// The summary of the hand still lying on the table: the table is
    /// between hands and the last hand's cards have not been swept yet.
    static func displayedSummary(_ table: PokerTable) -> PokerHandSummary? {
        guard table.phase == .betweenHands || table.phase == .gameOver,
              let summary = table.lastSummary, summary.handNumber == table.handNumber,
              table.players.contains(where: { $0.holeCards.count == 2 }) else { return nil }
        return summary
    }

    /// The award the result names — the one whose winning cards are lifted
    /// last, after any others have been paid.
    static func featuredAward(_ summary: PokerHandSummary) -> PokerPotAward? {
        guard let winner = summary.biggestWinner else { return summary.awards.first }
        return summary.awards.first { $0.winners.contains(winner) }
    }

    /// The awards in the order they are paid out on the table: side pots
    /// first, the featured one last.
    static func payoutOrder(_ summary: PokerHandSummary) -> [PokerPotAward] {
        let featured = featuredAward(summary)
        let others = summary.awards.filter { $0 != featured }.sorted { $0.potIndex > $1.potIndex }
        return others + (featured.map { [$0] } ?? [])
    }

    /// The player's hand in words: the pair or the suited cards before the
    /// flop, the made hand after it ("Two Pair, Kings and Sevens").
    static func handDescription(_ hole: [Card], board: [Card]) -> String? {
        guard hole.count == 2 else { return nil }
        if board.count >= 3 {
            return PokerEvaluator.best(hole + board).localizedDescription
        }
        let a = hole[0].pokerRank, b = hole[1].pokerRank
        if a == b {
            return String(format: NSLocalizedString("Pair of %@", comment: "poker hand: a pair, e.g. Pair of Jacks"),
                          PokerRankName.plural(a))
        }
        let high = max(a, b), low = min(a, b)
        let format = hole[0].suit == hole[1].suit
            ? NSLocalizedString("%@–%@ suited", comment: "poker starting hand, e.g. Ace–King suited")
            : NSLocalizedString("%@–%@ offsuit", comment: "poker starting hand, e.g. Ace–King offsuit")
        return String(format: format, PokerRankName.singular(high), PokerRankName.singular(low))
    }
}
