//
//  DurakCards.swift
//  The thirty-six-card deck, durak's rank order, which card beats which, and
//  a 36-bit card set the bots and the endgame solver can afford to copy
//  millions of times.
//
//  The kit's `Card` knows nothing about durak (its ace is rank 1, for
//  solitaire's sake), so everything here is an extension with a `durak`
//  prefix — the whole app is one module, and another game's `Card.beats`
//  would collide with an unprefixed one.
//

import Foundation

extension Card {

    /// Durak's rank order: six lowest, ace highest — 6 ... 14.
    var durakValue: Int { rank == .ace ? 14 : Int(rank.rawValue) }

    /// 0 for a six ... 8 for an ace: the value the bots' arithmetic and the
    /// bit layout of `DurakCardSet` use.
    var durakRankIndex: Int { durakValue - 6 }

    /// 0...35: `suit * 9 + rank index`. The bit this card occupies in a
    /// `DurakCardSet`.
    var durakIndex: Int { Int(suit.rawValue) * 9 + durakRankIndex }

    /// The card at `durakIndex` `index`.
    static func durak(index: Int) -> Card {
        let suit = Suit(rawValue: UInt8(index / 9)) ?? .clubs
        let value = index % 9 + 6
        let rank = value == 14 ? Rank.ace : (Rank(rawValue: UInt8(value)) ?? .six)
        return Card(suit, rank)
    }

    /// Whether this card belongs to durak's short deck (six through ace).
    var isDurakCard: Bool { rank == .ace || rank.rawValue >= 6 }

    /// The thirty-six cards, clubs first, six to ace within a suit — the
    /// order `DurakCardSet` iterates in.
    static let durakDeck: [Card] = (0..<36).map { Card.durak(index: $0) }

    /// Whether this card, played by the defender, beats `attack`: a higher
    /// card of the same suit, or any trump on a card that is not a trump.
    /// (A trump on a trump must be the higher trump — that is the same-suit
    /// rule, since the trump suit is a suit like any other.)
    func durakBeats(_ attack: Card, trump: Suit) -> Bool {
        if suit == attack.suit { return durakValue > attack.durakValue }
        return suit == trump
    }
}

/// How the player's fan is sorted. Trumps always sit at the right-hand end.
enum DurakHandOrder: String, Codable, CaseIterable, Sendable {
    /// Suits grouped (colours alternating where they can), six to ace within
    /// each, trumps last.
    case bySuit
    /// Six to ace across the suits, trumps last.
    case byRank
}

extension Card {

    /// `cards` in display order for a hand, left to right.
    static func durakSorted(_ cards: [Card], trump: Suit, order: DurakHandOrder) -> [Card] {
        // Black, red, black, red: with the trump suit taken out, neighbouring
        // groups still mostly differ in colour.
        let suitOrder: [Suit] = [.clubs, .diamonds, .spades, .hearts].filter { $0 != trump } + [trump]
        func suitKey(_ c: Card) -> Int { suitOrder.firstIndex(of: c.suit) ?? 0 }
        return cards.sorted { a, b in
            let aTrump = a.suit == trump, bTrump = b.suit == trump
            if aTrump != bTrump { return bTrump }
            switch order {
            case .bySuit:
                if a.suit != b.suit { return suitKey(a) < suitKey(b) }
                return a.durakValue < b.durakValue
            case .byRank:
                if a.durakValue != b.durakValue { return a.durakValue < b.durakValue }
                return suitKey(a) < suitKey(b)
            }
        }
    }
}

/// A set of durak cards as one 64-bit word, bit `durakIndex` per card.
///
/// The engine's state keeps plain arrays of `Card` — they are what a view
/// wants to read, and a hand's order is the order the cards arrived in — but
/// the bots and the endgame solver ask "which of these beat that" thousands
/// of times per decision, and a word answers that with a mask.
struct DurakCardSet: Hashable, Codable, Sendable, Sequence {

    private(set) var bits: UInt64

    init(bits: UInt64 = 0) { self.bits = bits & DurakCardSet.allBits }

    init<S: Sequence>(_ cards: S) where S.Element == Card {
        var bits: UInt64 = 0
        for card in cards where card.isDurakCard { bits |= 1 << UInt64(card.durakIndex) }
        self.bits = bits
    }

    static let allBits: UInt64 = (1 << 36) - 1
    static let all = DurakCardSet(bits: allBits)
    static let empty = DurakCardSet()

    var count: Int { bits.nonzeroBitCount }
    var isEmpty: Bool { bits == 0 }

    func contains(_ card: Card) -> Bool { card.isDurakCard && bits & (1 << UInt64(card.durakIndex)) != 0 }
    mutating func insert(_ card: Card) { bits |= 1 << UInt64(card.durakIndex) }
    mutating func remove(_ card: Card) { bits &= ~(1 << UInt64(card.durakIndex)) }

    func union(_ other: DurakCardSet) -> DurakCardSet { DurakCardSet(bits: bits | other.bits) }
    func intersection(_ other: DurakCardSet) -> DurakCardSet { DurakCardSet(bits: bits & other.bits) }
    func subtracting(_ other: DurakCardSet) -> DurakCardSet { DurakCardSet(bits: bits & ~other.bits) }

    /// Nine bits, one per rank (bit 0 the six): the ranks present in the set.
    var rankMask: UInt16 { DurakCardSet.rankMask(of: bits) }

    static func rankMask(of bits: UInt64) -> UInt16 {
        UInt16(truncatingIfNeeded: (bits | bits >> 9 | bits >> 18 | bits >> 27) & 0x1FF)
    }

    /// Every card of the ranks in `mask`, in all four suits.
    static func cards(ofRanks mask: UInt16) -> DurakCardSet {
        let m = UInt64(mask & 0x1FF)
        return DurakCardSet(bits: m | m << 9 | m << 18 | m << 27)
    }

    /// The cards of one suit.
    static func suit(_ suit: Suit) -> DurakCardSet {
        DurakCardSet(bits: UInt64(0x1FF) << UInt64(Int(suit.rawValue) * 9))
    }

    /// Every card that beats `attack` with `trump` as trumps.
    static func beaters(of attack: Card, trump: Suit) -> DurakCardSet {
        let suitBase = Int(attack.suit.rawValue) * 9
        let rank = attack.durakRankIndex
        // The higher cards of the attack's own suit...
        var bits: UInt64 = 0
        if rank < 8 {
            bits = (UInt64(0x1FF) >> UInt64(rank + 1)) << UInt64(suitBase + rank + 1)
        }
        // ...and every trump, unless the attack is a trump itself.
        if attack.suit != trump { bits |= suit(trump).bits }
        return DurakCardSet(bits: bits)
    }

    func makeIterator() -> AnyIterator<Card> {
        var remaining = bits
        return AnyIterator {
            guard remaining != 0 else { return nil }
            let index = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            return Card.durak(index: index)
        }
    }

    var cards: [Card] { Array(self) }
}
