//
//  BlackjackRound.swift
//  One round at the table: the player's hands, the dealer's, the insurance,
//  and where in the round we are.
//
//  The phases, in order:
//
//      betting ─ deal ─▶ dealing ─▶ insurance ─▶ peek ─▶ playerTurn ─▶ dealerTurn ─▶ settling ─▶ settled
//                          (4 cards)  (dealer ace)  (ace or ten up)   (per hand)     (hole card, draws)
//
//  `betting` is the table between rounds — no round at all — and `settled`
//  is a finished round still lying on the table, results showing, until the
//  player starts the next bet and the cards are collected. Insurance and
//  the peek are skipped when the dealer's up-card does not call for them;
//  the dealer's draws are skipped when no hand is left for the dealer to beat
//  — every one busted, surrendered or paid as a blackjack — but the hole card
//  is still turned over, so the player always sees it.
//

import Foundation

enum BlackjackPhase: String, Codable {
    /// Between rounds: the player is building a bet.
    case betting
    /// The four opening cards are going out, one at a time.
    case dealing
    /// The dealer shows an ace: insurance (or even money) is offered.
    case insurance
    /// The dealer shows an ace or a ten-card and checks the hole card.
    case peek
    /// The player's decisions, hand by hand.
    case playerTurn
    /// The hole card turns over and the dealer draws.
    case dealerTurn
    /// Every hand is about to be paid or taken.
    case settling
    /// The round is over; the results are on the table.
    case settled
}

/// What the player can do with the hand in front of them.
enum BlackjackAction: String, Codable, CaseIterable {
    case hit, stand, double, split, surrender

    var title: String {
        switch self {
        case .hit: return NSLocalizedString("Hit", comment: "blackjack action")
        case .stand: return NSLocalizedString("Stand", comment: "blackjack action")
        case .double: return NSLocalizedString("Double", comment: "blackjack action: double down")
        case .split: return NSLocalizedString("Split", comment: "blackjack action")
        case .surrender: return NSLocalizedString("Surrender", comment: "blackjack action")
        }
    }
}

/// How a hand came out.
enum BlackjackResult: String, Codable {
    /// A natural, paid three to two.
    case blackjack
    /// Took even money on a natural against the dealer's ace.
    case evenMoney
    case win
    case push
    case lose
    case bust
    case surrender

    var isWin: Bool { self == .blackjack || self == .evenMoney || self == .win }
    var isLoss: Bool { self == .lose || self == .bust || self == .surrender }
}

struct BlackjackHand: Codable, Equatable {

    var cards: [BlackjackCard] = []
    /// The chips riding on the hand — twice the original after a double.
    var bet: Int
    var isDoubled = false
    /// Made by splitting a pair: a two-card twenty-one here is just twenty-one.
    var isFromSplit = false
    /// A split ace: one card, no more, and no re-split.
    var isSplitAces = false
    var isSurrendered = false
    var tookEvenMoney = false
    /// No more cards: stood, busted, doubled, surrendered, twenty-one.
    var isDone = false
    /// Set when the round settles.
    var result: BlackjackResult?
    /// Chips handed back when it settled, the stake included — twice the
    /// bet for a win, the bet for a push, nothing for a loss.
    var returned = 0

    init(bet: Int) {
        self.bet = bet
    }

    var total: BlackjackTotal { BlackjackTotal(cards) }
    var isBust: Bool { total.isBust }

    /// Ace and ten-card as the first two cards of an unsplit hand.
    var isBlackjack: Bool { !isFromSplit && cards.count == 2 && total.total == 21 }

    var isPair: Bool { cards.count == 2 && cards[0].points == cards[1].points }

    var isSettled: Bool { result != nil }

    /// Still standing for the dealer to beat: not busted, not given up, and
    /// not already paid as a natural.
    var isLive: Bool { !isBust && !isSurrendered && !isBlackjack && !tookEvenMoney }

    private enum CodingKeys: String, CodingKey {
        case cards, bet, isDoubled, isFromSplit, isSplitAces, isSurrendered, tookEvenMoney, isDone, result, returned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        cards = value(.cards, [])
        bet = max(0, value(.bet, 0))
        isDoubled = value(.isDoubled, false)
        isFromSplit = value(.isFromSplit, false)
        isSplitAces = value(.isSplitAces, false)
        isSurrendered = value(.isSurrendered, false)
        tookEvenMoney = value(.tookEvenMoney, false)
        isDone = value(.isDone, false)
        result = value(.result, nil as BlackjackResult?)
        returned = max(0, value(.returned, 0))
    }
}

struct BlackjackRound: Codable, Equatable {

    var phase: BlackjackPhase = .dealing
    var hands: [BlackjackHand]
    /// The hand being played, during `playerTurn`.
    var active = 0
    /// The dealer's cards: the up-card first, the hole card second.
    var dealer: [BlackjackCard] = []
    var isHoleRevealed = false
    /// The insurance bet, if one was taken.
    var insurance = 0
    /// What the insurance paid back once the dealer had looked — nil while
    /// it is still riding (or was never taken).
    var insuranceReturned: Int?
    /// The bet the round was dealt with, before any doubles and splits.
    var initialBet: Int

    init(bet: Int) {
        hands = [BlackjackHand(bet: bet)]
        initialBet = bet
    }

    var dealerTotal: BlackjackTotal { BlackjackTotal(dealer) }
    var upCard: BlackjackCard? { dealer.first }
    var dealerHasBlackjack: Bool { dealer.count == 2 && dealerTotal.total == 21 }

    /// Every card on the table.
    var cardsOnTable: [BlackjackCard] { dealer + hands.flatMap(\.cards) }

    /// Chips staked and not yet settled.
    var chipsAtRisk: Int {
        hands.filter { !$0.isSettled }.reduce(0) { $0 + $1.bet } + (insuranceReturned == nil ? insurance : 0)
    }

    /// Everything staked this round: the bets as they stand, and insurance.
    var totalStaked: Int { hands.reduce(0) { $0 + $1.bet } + insurance }

    /// Everything handed back, once settled.
    var totalReturned: Int { hands.reduce(0) { $0 + $1.returned } + (insuranceReturned ?? 0) }

    /// The round's result for the player, once settled.
    var net: Int { totalReturned - totalStaked }

    private enum CodingKeys: String, CodingKey {
        case phase, hands, active, dealer, isHoleRevealed, insurance, insuranceReturned, initialBet
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        phase = value(.phase, .dealing)
        hands = value(.hands, [])
        active = value(.active, 0)
        dealer = value(.dealer, [])
        isHoleRevealed = value(.isHoleRevealed, false)
        insurance = max(0, value(.insurance, 0))
        insuranceReturned = value(.insuranceReturned, nil as Int?)
        initialBet = value(.initialBet, hands.first?.bet ?? 0)
    }

    /// Whether the round could have come out of the engine: the right number
    /// of cards for its phase, a hand to play when it is the player's turn.
    /// A saved round that fails this is refunded rather than resumed.
    var isPlausible: Bool {
        guard !hands.isEmpty, hands.count <= 4, dealer.count <= 12, active >= 0, active < hands.count else { return false }
        if hands.contains(where: { $0.bet <= 0 || $0.cards.count > 12 }) { return false }
        switch phase {
        case .betting: return false
        case .dealing: return hands.count == 1 && hands[0].cards.count + dealer.count < 4
        case .insurance, .peek: return hands.count == 1 && hands[0].cards.count == 2 && dealer.count == 2
        case .playerTurn:
            return dealer.count == 2 && !hands[active].isDone && !hands[active].cards.isEmpty
        case .dealerTurn, .settling: return dealer.count >= 2 && hands.allSatisfy { $0.isDone }
        case .settled: return dealer.count >= 2 && hands.allSatisfy { $0.isSettled }
        }
    }
}
