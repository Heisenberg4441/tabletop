//
//  BlackjackRules.swift
//  The house rules at the table: how many decks, what the dealer does with a
//  soft seventeen, whether a hand may be surrendered, and the limits.
//
//  The defaults are the common six-deck Strip game — dealer stands on all
//  seventeens, double on any two cards and after a split, late surrender,
//  split to four hands, blackjack paying three to two — because that is the
//  game a player who has sat at a casino table expects, and the one the
//  printed felt describes.
//
//  Only the first four settings are the player's to choose (the New Game
//  card); the rest are fixed for the table but kept here rather than as
//  constants, so the engine, the strategy table and the tests all read one
//  description of the game.
//

import Foundation

struct BlackjackRules: Codable, Equatable {

    /// Decks in the shoe: 1, 2, 6 or 8.
    var decks = 6
    /// H17 when true: the dealer draws to a soft seventeen. S17 otherwise.
    var dealerHitsSoft17 = false
    /// Late surrender: half the bet back instead of playing the hand, as the
    /// hand's first decision and only after the dealer has checked for
    /// blackjack.
    var surrenderAllowed = true
    /// Double down on a hand that came from a split.
    var doubleAfterSplit = true
    /// A pair may be split until the player holds this many hands.
    var maximumHands = 4
    var minimumBet = 10
    var maximumBet = 1_000
    /// How far into the shoe the cut card goes, as a fraction of the cards.
    var penetration = 0.75

    /// The shoe sizes the New Game card offers.
    static let deckChoices = [1, 2, 6, 8]

    /// What a new player — or a player who went broke and asked for more —
    /// sits down with.
    static let startingBankroll = 1_000

    init() {}

    // Key by key, each with a fallback: a file written by an older build (or
    // hand-edited) loses only the settings it gets wrong, never the rest.
    private enum CodingKeys: String, CodingKey {
        case decks, dealerHitsSoft17, surrenderAllowed, doubleAfterSplit, maximumHands
        case minimumBet, maximumBet, penetration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BlackjackRules()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let decks = value(.decks, defaults.decks)
        self.decks = Self.deckChoices.contains(decks) ? decks : defaults.decks
        dealerHitsSoft17 = value(.dealerHitsSoft17, defaults.dealerHitsSoft17)
        surrenderAllowed = value(.surrenderAllowed, defaults.surrenderAllowed)
        doubleAfterSplit = value(.doubleAfterSplit, defaults.doubleAfterSplit)
        maximumHands = max(1, min(4, value(.maximumHands, defaults.maximumHands)))
        // Limits a new bankroll can always meet, and a maximum above them.
        minimumBet = max(5, min(100, value(.minimumBet, defaults.minimumBet)))
        maximumBet = max(minimumBet, min(10_000, value(.maximumBet, defaults.maximumBet)))
        let penetration = value(.penetration, defaults.penetration)
        self.penetration = (0.5...0.9).contains(penetration) ? penetration : defaults.penetration
    }

    /// What the dealer's rule line on the felt says.
    var dealerRuleText: String {
        dealerHitsSoft17
            ? NSLocalizedString("DEALER MUST HIT SOFT 17", comment: "printed on the blackjack table: H17")
            : NSLocalizedString("DEALER MUST STAND ON SOFT 17", comment: "printed on the blackjack table: S17")
    }
}

/// How much help the table gives: none, a Hint button, or a Hint button and
/// a quiet word after a play that strays from basic strategy.
enum BlackjackCoachLevel: Int, Codable, CaseIterable {
    case off, hints, coach

    var title: String {
        switch self {
        case .off: return NSLocalizedString("Off", comment: "blackjack coach: no help")
        case .hints: return NSLocalizedString("Hints", comment: "blackjack coach: a hint button")
        case .coach: return NSLocalizedString("Coach", comment: "blackjack coach: hints and a word after a mistake")
        }
    }
}
