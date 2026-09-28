//
//  BlackjackStrategy.swift
//  Basic strategy: the play that loses least, for every hand against every
//  dealer up-card, at this table's rules.
//
//  The tables are the standard total-dependent ones — the chart printed on
//  the card a casino gift shop sells — for a multi-deck game, with the
//  well-known adjustments for the rules the New Game card can change:
//
//    * H17 (the dealer hits soft 17): double 11 against an ace, double soft
//      19 against a six and soft 18 against a two; surrender 15 and 17
//      against an ace, and (four or more decks) a pair of eights too.
//    * One or two decks: double 11 against an ace and 9 against a two;
//      surrender 16 only against a ten or an ace (and 15 against a ten).
//    * One deck only: double 8 against a five or six, soft 17 against a two,
//      soft 13 and 14 against a four, soft 19 against a six; stand on soft 18
//      against an ace when the dealer stands on soft 17.
//    * No double after split: the small pairs split against fewer cards.
//
//  The one- and two-deck cells were checked against a composition-dependent
//  expectation for the two-card hand; where two plays are within a
//  thousandth of a bet of each other, the published chart's play is kept.
//
//  Insurance is never basic strategy, and neither is even money: the coach
//  says so when asked.
//
//  The answer is always one of the actions the hand actually has: "double"
//  on a hand that cannot double falls back to hitting (or, for the "double
//  or stand" hands, standing), "surrender" falls back to the play under it.
//

import Foundation

enum BlackjackStrategy {

    /// The basic-strategy play for `hand` against `upCard`, from `legal`.
    static func recommendation(for hand: BlackjackHand, upCard: BlackjackCard, rules: BlackjackRules,
                               legal: Set<BlackjackAction>) -> BlackjackAction {
        let points = hand.cards.map(\.points)
        let total = BlackjackTotal(points: points)
        let up = upCard.isAce ? 11 : upCard.points
        let h17 = rules.dealerHitsSoft17
        let decks = rules.decks
        let multi = decks >= 4

        func pick(_ first: BlackjackAction, else fallback: BlackjackAction) -> BlackjackAction {
            legal.contains(first) ? first : (legal.contains(fallback) ? fallback : .stand)
        }

        // Surrender first: it is the one play that only exists as the first.
        if legal.contains(.surrender) && !total.isSoft {
            // Eights are split rather than surrendered — when they can be.
            // Eights that cannot (the bankroll will not cover a second bet)
            // are a plain hard 16.
            let eights = hand.isPair && points[0] == 8 && legal.contains(.split)
            var give = false
            if eights {
                give = h17 && multi && up == 11
            } else if total.total == 16 {
                give = up == 10 || up == 11 || (multi && up == 9)
            } else if total.total == 15 {
                give = up == 10 || (h17 && up == 11)
            } else if total.total == 17 {
                give = h17 && up == 11
            }
            if give { return .surrender }
        }

        // Pairs.
        if hand.isPair && legal.contains(.split) {
            let das = rules.doubleAfterSplit
            let split: Bool
            switch points[0] {
            case 1: split = true
            case 10: split = false
            case 9: split = (2...6).contains(up) || up == 8 || up == 9
            case 8: split = true
            case 7: split = (2...7).contains(up)
            case 6: split = das ? (2...6).contains(up) : (3...6).contains(up)
            case 5: split = false
            case 4: split = das && (up == 5 || up == 6)
            default: split = das ? (2...7).contains(up) : (4...7).contains(up)      // 2s and 3s
            }
            if split { return .split }
        }

        // Soft totals: an ace counting eleven.
        if total.isSoft {
            switch total.total {
            case 20, 21:
                return .stand
            case 19:
                return (up == 6 && (h17 || decks == 1)) ? pick(.double, else: .stand) : .stand
            case 18:
                if (3...6).contains(up) || (up == 2 && h17) { return pick(.double, else: .stand) }
                if up == 2 || up == 7 || up == 8 { return .stand }
                if up == 11 && decks == 1 && !h17 { return .stand }
                return pick(.hit, else: .stand)
            case 17:
                if (3...6).contains(up) || (up == 2 && decks == 1) { return pick(.double, else: .hit) }
                return pick(.hit, else: .stand)
            case 15, 16:
                return (4...6).contains(up) ? pick(.double, else: .hit) : pick(.hit, else: .stand)
            case 13, 14:
                if (5...6).contains(up) || (up == 4 && decks == 1) { return pick(.double, else: .hit) }
                return pick(.hit, else: .stand)
            default:
                return pick(.hit, else: .stand)                                    // soft 12: two aces
            }
        }

        // Hard totals.
        switch total.total {
        case 17...:
            return .stand
        case 13...16:
            return (2...6).contains(up) ? .stand : pick(.hit, else: .stand)
        case 12:
            return (4...6).contains(up) ? .stand : pick(.hit, else: .stand)
        case 11:
            if up <= 10 || h17 || decks <= 2 { return pick(.double, else: .hit) }
            return pick(.hit, else: .stand)
        case 10:
            return up <= 9 ? pick(.double, else: .hit) : pick(.hit, else: .stand)
        case 9:
            if (3...6).contains(up) || (up == 2 && decks <= 2) { return pick(.double, else: .hit) }
            return pick(.hit, else: .stand)
        case 8:
            if decks == 1 && (up == 5 || up == 6) { return pick(.double, else: .hit) }
            return pick(.hit, else: .stand)
        default:
            return pick(.hit, else: .stand)
        }
    }

    /// The basic-strategy answer to "insurance?" and "even money?": no.
    static let takesInsurance = false
}
