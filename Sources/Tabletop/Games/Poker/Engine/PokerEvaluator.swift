//
//  PokerEvaluator.swift
//  How strong a poker hand is: the best five of up to seven cards.
//
//  Two speeds. The bots' Monte-Carlo equity runs thousands of showdowns per
//  decision, so the hot path, `PokerEvaluator.rawValue(of:)`, works on a
//  52-bit mask of the cards with nothing but bit arithmetic: no arrays, no
//  allocation, no table lookups, a few dozen instructions. The UI's path,
//  `PokerEvaluator.best(_:)`, is a hundred times slower and says everything —
//  the category, the exact five cards to lift at the showdown, and a sentence
//  for the banner ("Two Pair, Kings and Sevens").
//
//  THE MASK. Each suit owns a 16-bit lane of a UInt64 (clubs lowest, in Kit
//  suit order) and each rank a bit within it, two at bit 0 up to the ace at
//  bit 12. Or-ing the lanes together gives the ranks present; and-ing them
//  gives the ranks present in every suit — which is how pairs, trips and
//  quads fall out of four machine words without counting anything.
//
//  THE VALUE. One UInt32 that compares like the hands do: the category in
//  bits 20–23, then five 4-bit rank slots, most significant first (the pair
//  before its kickers, the trips before the pair of a full house). A slot
//  holds the rank index plus one, so 0 always means "no card there" — a hand
//  of fewer than five cards (the pill under your hole cards before the flop)
//  still reads correctly.
//

import Foundation

// MARK: - Ranks

extension Card {

    /// Rank for poker, ace high: two is 0 … king 11, ace 12. The Kit deck
    /// numbers the ace 1 for solitaire's sake; poker says so here instead of
    /// renumbering the deck.
    var pokerRank: Int {
        let v = value
        return v == 1 ? 12 : v - 2
    }

    /// This card's bit in a `PokerEvaluator` mask.
    var pokerBit: UInt64 {
        1 << UInt64(Int(suit.rawValue) * 16 + pokerRank)
    }
}

/// Cards written the way poker books write them — "Ah Kd 7c", ten as T —
/// for tests, scenarios and logs. Unreadable tokens are skipped.
enum PokerNotation {

    static func cards(_ text: String) -> [Card] {
        text.split(separator: " ").compactMap { card(String($0)) }
    }

    static func card(_ token: String) -> Card? {
        guard token.count == 2, let r = token.first, let u = token.last else { return nil }
        let ranks: [Character: Rank] = ["A": .ace, "K": .king, "Q": .queen, "J": .jack, "T": .ten, "9": .nine,
                                        "8": .eight, "7": .seven, "6": .six, "5": .five, "4": .four, "3": .three, "2": .two]
        let suits: [Character: Suit] = ["c": .clubs, "d": .diamonds, "h": .hearts, "s": .spades]
        guard let rank = ranks[r], let suit = suits[u] else { return nil }
        return Card(suit, rank)
    }

    /// "Ah", "Td".
    static func text(_ card: Card) -> String {
        let ranks = "23456789TJQKA"
        let suits = "cdhs"
        let r = ranks[ranks.index(ranks.startIndex, offsetBy: card.pokerRank)]
        let u = suits[suits.index(suits.startIndex, offsetBy: Int(card.suit.rawValue))]
        return "\(r)\(u)"
    }
}

/// Names of poker ranks as the descriptions need them, "King" and "Kings".
enum PokerRankName {

    /// "Ace", "Ten", "Five" — for "Flush, Ace high".
    static func singular(_ rank: Int) -> String {
        switch rank {
        case 0: return NSLocalizedString("Two", comment: "poker rank, singular (Straight, Two high)")
        case 1: return NSLocalizedString("Three", comment: "poker rank, singular")
        case 2: return NSLocalizedString("Four", comment: "poker rank, singular")
        case 3: return NSLocalizedString("Five", comment: "poker rank, singular (Straight, Five high)")
        case 4: return NSLocalizedString("Six", comment: "poker rank, singular")
        case 5: return NSLocalizedString("Seven", comment: "poker rank, singular")
        case 6: return NSLocalizedString("Eight", comment: "poker rank, singular")
        case 7: return NSLocalizedString("Nine", comment: "poker rank, singular")
        case 8: return NSLocalizedString("Ten", comment: "poker rank, singular")
        case 9: return NSLocalizedString("Jack", comment: "poker rank, singular")
        case 10: return NSLocalizedString("Queen", comment: "poker rank, singular")
        case 11: return NSLocalizedString("King", comment: "poker rank, singular")
        default: return NSLocalizedString("Ace", comment: "poker rank, singular (Flush, Ace high)")
        }
    }

    /// "Aces", "Sixes" — for "Pair of Aces", "Full House, Kings over Sixes".
    static func plural(_ rank: Int) -> String {
        switch rank {
        case 0: return NSLocalizedString("Twos", comment: "poker rank, plural (Pair of Twos)")
        case 1: return NSLocalizedString("Threes", comment: "poker rank, plural")
        case 2: return NSLocalizedString("Fours", comment: "poker rank, plural")
        case 3: return NSLocalizedString("Fives", comment: "poker rank, plural")
        case 4: return NSLocalizedString("Sixes", comment: "poker rank, plural")
        case 5: return NSLocalizedString("Sevens", comment: "poker rank, plural")
        case 6: return NSLocalizedString("Eights", comment: "poker rank, plural")
        case 7: return NSLocalizedString("Nines", comment: "poker rank, plural")
        case 8: return NSLocalizedString("Tens", comment: "poker rank, plural")
        case 9: return NSLocalizedString("Jacks", comment: "poker rank, plural")
        case 10: return NSLocalizedString("Queens", comment: "poker rank, plural")
        case 11: return NSLocalizedString("Kings", comment: "poker rank, plural")
        default: return NSLocalizedString("Aces", comment: "poker rank, plural (Pair of Aces)")
        }
    }
}

// MARK: - Categories and values

/// The nine kinds of hand, weakest first. The raw value is what
/// `PokerHandValue` stores in its top bits, so the order can never change.
enum PokerHandCategory: Int, CaseIterable, Codable, Sendable, Comparable {
    case highCard = 0, pair, twoPair, threeOfAKind, straight, flush, fullHouse, fourOfAKind, straightFlush

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// "Two Pair", "Full House". A royal flush is named by `PokerHandValue`,
    /// which knows it is ace high.
    var localizedName: String {
        switch self {
        case .highCard: return NSLocalizedString("High Card", comment: "poker hand category")
        case .pair: return NSLocalizedString("Pair", comment: "poker hand category")
        case .twoPair: return NSLocalizedString("Two Pair", comment: "poker hand category")
        case .threeOfAKind: return NSLocalizedString("Three of a Kind", comment: "poker hand category")
        case .straight: return NSLocalizedString("Straight", comment: "poker hand category")
        case .flush: return NSLocalizedString("Flush", comment: "poker hand category")
        case .fullHouse: return NSLocalizedString("Full House", comment: "poker hand category")
        case .fourOfAKind: return NSLocalizedString("Four of a Kind", comment: "poker hand category")
        case .straightFlush: return NSLocalizedString("Straight Flush", comment: "poker hand category")
        }
    }

    /// How many of the five rank slots the category fills with ranks that
    /// matter (the rest are kickers it does not have, or repeats).
    var significantSlots: Int {
        switch self {
        case .highCard, .flush: return 5
        case .pair: return 4
        case .twoPair, .threeOfAKind: return 3
        case .fullHouse, .fourOfAKind: return 2
        case .straight, .straightFlush: return 1
        }
    }
}

/// A hand's strength as one number: bigger beats smaller, equal splits.
struct PokerHandValue: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    let raw: UInt32

    init(raw: UInt32) { self.raw = raw }

    static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }

    var category: PokerHandCategory {
        PokerHandCategory(rawValue: Int(raw >> 20)) ?? .highCard
    }

    /// The rank indices (two = 0 … ace = 12) in the category's slots, most
    /// significant first, as many as the hand has: [pair, kicker, kicker,
    /// kicker] for a pair, [top] for a straight.
    var ranks: [Int] {
        var result: [Int] = []
        for slot in 0..<5 {
            let nibble = Int((raw >> UInt32(16 - slot * 4)) & 0xF)
            if nibble == 0 { break }
            result.append(nibble - 1)
        }
        return result
    }

    var isRoyalFlush: Bool { category == .straightFlush && ranks.first == 12 }

    /// "Two Pair", or "Royal Flush" — short enough for the pill by your cards.
    var name: String {
        isRoyalFlush ? NSLocalizedString("Royal Flush", comment: "poker hand category") : category.localizedName
    }

    /// The whole sentence: "Two Pair, Kings and Sevens", "Flush, Ace high",
    /// "Straight, Five high", "Pair of Jacks".
    var localizedDescription: String {
        let r = ranks
        func s(_ i: Int) -> String { PokerRankName.singular(r[safe: i] ?? 0) }
        func p(_ i: Int) -> String { PokerRankName.plural(r[safe: i] ?? 0) }
        switch category {
        case .highCard:
            return String(format: NSLocalizedString("High Card, %@", comment: "poker hand: high card, e.g. High Card, Ace"), s(0))
        case .pair:
            return String(format: NSLocalizedString("Pair of %@", comment: "poker hand: a pair, e.g. Pair of Jacks"), p(0))
        case .twoPair:
            return String(format: NSLocalizedString("Two Pair, %@ and %@",
                                                    comment: "poker hand: two pair, e.g. Two Pair, Kings and Sevens"), p(0), p(1))
        case .threeOfAKind:
            return String(format: NSLocalizedString("Three of a Kind, %@",
                                                    comment: "poker hand: trips, e.g. Three of a Kind, Eights"), p(0))
        case .straight:
            return String(format: NSLocalizedString("Straight, %@ high", comment: "poker hand: straight, e.g. Straight, Five high"), s(0))
        case .flush:
            return String(format: NSLocalizedString("Flush, %@ high", comment: "poker hand: flush, e.g. Flush, Ace high"), s(0))
        case .fullHouse:
            return String(format: NSLocalizedString("Full House, %@ over %@",
                                                    comment: "poker hand: full house, e.g. Full House, Kings over Sevens"), p(0), p(1))
        case .fourOfAKind:
            return String(format: NSLocalizedString("Four of a Kind, %@",
                                                    comment: "poker hand: quads, e.g. Four of a Kind, Queens"), p(0))
        case .straightFlush:
            if isRoyalFlush { return NSLocalizedString("Royal Flush", comment: "poker hand category") }
            return String(format: NSLocalizedString("Straight Flush, %@ high",
                                                    comment: "poker hand: straight flush, e.g. Straight Flush, Nine high"), s(0))
        }
    }

    var description: String { localizedDescription }
}

/// Everything the table shows about a made hand.
struct PokerHandResult: Hashable, Codable, Sendable {
    let value: PokerHandValue
    /// The (up to) five cards that make the hand, the ones that matter most
    /// first — the pair before its kickers, a straight from the top down
    /// (the wheel's ace last). These are the cards that lift at the showdown.
    let cards: [Card]

    var category: PokerHandCategory { value.category }
    var name: String { value.name }
    var localizedDescription: String { value.localizedDescription }
}

// MARK: - The evaluator

enum PokerEvaluator {

    /// The mask of `cards`, duplicates folded (there are none in a real deal).
    static func mask(_ cards: [Card]) -> UInt64 {
        var m: UInt64 = 0
        for card in cards { m |= card.pokerBit }
        return m
    }

    /// The best hand in `mask`, which holds up to seven cards.
    ///
    /// The order of the tests matters and is only right for seven cards or
    /// fewer: a flush there leaves at most two other cards, too few for quads
    /// or a full house beside it, so a flush can return at once; a full house
    /// must be looked for before a straight, which it beats and can coexist
    /// with.
    @inline(__always)
    static func rawValue(of mask: UInt64) -> UInt32 {
        let c = UInt32(truncatingIfNeeded: mask) & 0x1FFF
        let d = UInt32(truncatingIfNeeded: mask >> 16) & 0x1FFF
        let h = UInt32(truncatingIfNeeded: mask >> 32) & 0x1FFF
        let s = UInt32(truncatingIfNeeded: mask >> 48) & 0x1FFF
        let all = c | d | h | s

        var flush: UInt32 = 0
        if c.nonzeroBitCount >= 5 { flush = c }
        else if d.nonzeroBitCount >= 5 { flush = d }
        else if h.nonzeroBitCount >= 5 { flush = h }
        else if s.nonzeroBitCount >= 5 { flush = s }
        if flush != 0 {
            let top = straightTop(flush)
            if top >= 0 { return (8 << 20) | UInt32(top + 1) << 16 }
            return (5 << 20) | kickers(flush, 5)
        }

        // A bit-sliced counter across the four suits: for every rank at once,
        // `ones`, `twos` and `fours` are the binary digits of how many suits
        // hold it.
        var ones = c ^ d
        var twos = c & d
        var carry = ones & h
        ones ^= h
        var fours = twos & carry
        twos ^= carry
        carry = ones & s
        ones ^= s
        fours |= twos & carry
        twos ^= carry
        let trips = ones & twos
        let pairs = twos & ~ones

        if fours != 0 {
            let q = highest(fours)
            return (7 << 20) | UInt32(q + 1) << 16 | kickers(all & ~(1 << UInt32(q)), 1) << 12
        }
        if trips != 0 {
            let t = highest(trips)
            // Two sets of trips make a full house too: the lower one plays as the pair.
            let rest = (trips & ~(1 << UInt32(t))) | pairs
            if rest != 0 {
                return (6 << 20) | UInt32(t + 1) << 16 | UInt32(highest(rest) + 1) << 12
            }
        }
        let top = straightTop(all)
        if top >= 0 { return (4 << 20) | UInt32(top + 1) << 16 }
        if trips != 0 {
            let t = highest(trips)
            return (3 << 20) | UInt32(t + 1) << 16 | kickers(all & ~(1 << UInt32(t)), 2) << 8
        }
        if pairs != 0 {
            let p1 = highest(pairs)
            let others = pairs & ~(1 << UInt32(p1))
            if others != 0 {
                // A third pair's rank can be the kicker; so can a single card.
                let p2 = highest(others)
                let rest = all & ~(1 << UInt32(p1)) & ~(1 << UInt32(p2))
                return (2 << 20) | UInt32(p1 + 1) << 16 | UInt32(p2 + 1) << 12 | kickers(rest, 1) << 8
            }
            return (1 << 20) | UInt32(p1 + 1) << 16 | kickers(all & ~(1 << UInt32(p1)), 3) << 4
        }
        return kickers(all, 5)
    }

    static func evaluate(mask: UInt64) -> PokerHandValue {
        PokerHandValue(raw: rawValue(of: mask))
    }

    static func evaluate(_ cards: [Card]) -> PokerHandValue {
        PokerHandValue(raw: rawValue(of: mask(cards)))
    }

    /// The best hand in `cards` (any number up to seven), with the five cards
    /// that make it and its description. For the UI and the showdown rather
    /// than inner loops, but cheap all the same: the value already says which
    /// ranks play and how many of each, so the cards are picked straight off
    /// it instead of trying every five-card subset.
    static func best(_ cards: [Card]) -> PokerHandResult {
        let value = evaluate(cards)
        let category = value.category
        var ranks = value.ranks
        var pool = cards
        if category == .flush || category == .straightFlush {
            // Only the flush suit plays; with seven cards there is just one.
            var perSuit = [Int](repeating: 0, count: 4)
            for card in cards { perSuit[Int(card.suit.rawValue)] += 1 }
            if let suit = perSuit.indices.max(by: { perSuit[$0] < perSuit[$1] }) {
                pool = cards.filter { Int($0.suit.rawValue) == suit }
            }
        }
        if category == .straight || category == .straightFlush, let top = ranks.first {
            // Five ranks down from the top; the wheel's ace comes last.
            ranks = (0..<5).map { top - $0 < 0 ? 12 : top - $0 }
        }
        let multiplicity: [Int]
        switch category {
        case .pair: multiplicity = [2, 1, 1, 1]
        case .twoPair: multiplicity = [2, 2, 1]
        case .threeOfAKind: multiplicity = [3, 1, 1]
        case .fullHouse: multiplicity = [3, 2]
        case .fourOfAKind: multiplicity = [4, 1]
        default: multiplicity = [1, 1, 1, 1, 1]
        }
        // Highest suit first among equals, so the choice is stable.
        pool.sort { $0.suit.rawValue > $1.suit.rawValue }
        var chosen: [Card] = []
        chosen.reserveCapacity(5)
        for (rank, count) in zip(ranks, multiplicity) {
            var taken = 0
            for card in pool where taken < count && card.pokerRank == rank && !chosen.contains(card) {
                chosen.append(card)
                taken += 1
            }
        }
        return PokerHandResult(value: value, cards: chosen)
    }

    // MARK: Bit helpers

    /// Index of the highest set bit; the mask must not be zero.
    @inline(__always)
    private static func highest(_ m: UInt32) -> Int {
        31 - m.leadingZeroBitCount
    }

    /// The `count` highest ranks in `m`, packed into `count` nibbles (rank + 1,
    /// most significant first), zero-filled on the right when there are fewer.
    @inline(__always)
    private static func kickers(_ m: UInt32, _ count: Int) -> UInt32 {
        var rest = m
        var out: UInt32 = 0
        for _ in 0..<count {
            out <<= 4
            if rest != 0 {
                let r = highest(rest)
                out |= UInt32(r + 1)
                rest &= ~(1 << UInt32(r))
            }
        }
        return out
    }

    /// The top rank of the highest straight in a 13-bit rank mask, or -1.
    ///
    /// Shifting the mask up one place and copying the ace into bit 0 lets the
    /// ace play low as well as high; five consecutive bits then survive four
    /// shifted ands, and the highest survivor is the straight's bottom card.
    @inline(__always)
    static func straightTop(_ ranks: UInt32) -> Int {
        let m = (ranks << 1) | ((ranks >> 12) & 1)
        let run = m & (m >> 1) & (m >> 2) & (m >> 3) & (m >> 4)
        guard run != 0 else { return -1 }
        return highest(run) + 3
    }
}
