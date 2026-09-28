//
//  BlackjackCards.swift
//  Cards as blackjack counts them.
//
//  A shoe holds several decks, so it holds several aces of spades, and the
//  table has to tell them apart — each is its own sprite, flying from the
//  shoe to a hand and on to the discard tray. So a card in the shoe is a
//  number, `0 ..< decks × 52`, and its face is that number modulo 52: the
//  kit's `Card` code. The number is the card's identity for as long as the
//  shoe lasts, which makes "every card is somewhere, exactly once" a check
//  the tests can make after every round.
//

import Foundation

struct BlackjackCard: Codable, Hashable, CustomStringConvertible {

    /// Which physical card in the shoe this is.
    let id: Int

    init(id: Int) {
        self.id = max(0, id)
    }

    /// The face printed on it.
    var card: Card { Card(code: UInt8(id % 52)) }

    /// What it counts: its number, ten for a court card, and one for an ace
    /// (which `BlackjackTotal` may promote to eleven).
    var points: Int { min(10, card.value) }

    var isAce: Bool { card.rank == .ace }
    var isTenValue: Bool { points == 10 }

    var description: String { card.description }

    // Stored as the bare number.
    init(from decoder: Decoder) throws {
        id = max(0, try decoder.singleValueContainer().decode(Int.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

/// A hand's count: the best total not over twenty-one if there is one, and
/// whether an ace in it is still counting eleven.
struct BlackjackTotal: Equatable {

    /// The count, with one ace as eleven when that does not bust the hand.
    let total: Int
    /// An ace is counting eleven: another card cannot bust the hand.
    let isSoft: Bool

    init(points: [Int]) {
        let hard = points.reduce(0, +)
        // Only ever one ace counts eleven — two would be twenty-two.
        if points.contains(1) && hard + 10 <= 21 {
            total = hard + 10
            isSoft = true
        } else {
            total = hard
            isSoft = false
        }
    }

    init(_ cards: [BlackjackCard]) {
        self.init(points: cards.map(\.points))
    }

    var isBust: Bool { total > 21 }
}
