//
//  BlackjackShoe.swift
//  The shoe, the cut card and the discard tray.
//
//  Every card in the shoe is always in exactly one of three places: still in
//  the shoe (`undealt`), on the table in a hand, or in the discard tray. The
//  shoe itself only knows about the first and the last; the engine owns the
//  table. `isComposed(withTable:)` checks the three together.
//
//  The cut card goes in about three quarters of the way down, a little
//  either side so a player cannot count on the exact spot. When it comes out
//  the round in play is finished as normal and the whole shoe is shuffled
//  before the next one — the engine calls `shuffle()` from `collect()`. If a
//  shoe ever runs dry in the middle of a round (a single deck and a flurry
//  of splits can do it), the dealer does what a real one does: shuffles the
//  discards and carries on, and the full shuffle still follows the round.
//
//  Shuffles are seeded: the n-th shuffle of a shoe uses its seed and n, so a
//  shoe restored from disk carries on exactly as it would have, and a test
//  or a screenshot deals the same cards every time.
//

import Foundation

struct BlackjackShoe: Codable, Equatable {

    private(set) var decks: Int
    /// The cards still to come, the top of the shoe — the next to be dealt —
    /// last, so a draw is `popLast()`.
    private(set) var undealt: [Int]
    /// Cards played and collected since the last shuffle.
    private(set) var discard: [Int]
    /// How many undealt cards are behind the cut card.
    private(set) var cutRemaining: Int
    /// The cut card has come out: the shoe is shuffled after this round.
    private(set) var isCutCardOut = false
    /// Shuffles so far — which, with `seed`, decides the next one.
    private(set) var shuffles = 0
    let seed: UInt64
    let penetration: Double

    init(decks: Int, seed: UInt64, penetration: Double = 0.75) {
        self.decks = max(1, decks)
        self.seed = seed
        self.penetration = penetration
        undealt = []
        discard = []
        cutRemaining = 0
        shuffle()
    }

    /// Every card the shoe was filled with.
    var size: Int { decks * 52 }

    /// The share of the shoe still to be dealt, 0…1.
    var remainingFraction: Double { Double(undealt.count) / Double(max(1, size)) }

    /// Where the cut card sits, as a share of the shoe from the back: the
    /// shoe drawing puts its sliver of yellow here.
    var cutFraction: Double { Double(cutRemaining) / Double(max(1, size)) }

    // MARK: Dealing

    /// The next card, or nil if the shoe and the discards are both empty —
    /// which would take every card of the shoe on the table at once, and
    /// cannot happen in a real round.
    mutating func draw() -> BlackjackCard? {
        if undealt.isEmpty {
            guard !discard.isEmpty else { return nil }
            // Mid-round: the discards go back in, shuffled, and the cut card
            // stays out so the full shuffle still comes after the round.
            var rng = DeterministicRNG(seed: mixedSeed(salt: 0xD15C_A4D5 ^ UInt64(discard.count)))
            var cards = discard
            rng.shuffle(&cards)
            undealt = cards
            discard = []
            isCutCardOut = true
        }
        guard let id = undealt.popLast() else { return nil }
        if undealt.count <= cutRemaining { isCutCardOut = true }
        return BlackjackCard(id: id)
    }

    /// Puts collected cards into the discard tray.
    mutating func discard(_ cards: [BlackjackCard]) {
        discard.append(contentsOf: cards.map(\.id))
    }

    /// Gathers every card and shuffles a fresh shoe. Only between rounds:
    /// cards still on the table would otherwise be dealt twice.
    mutating func shuffle() {
        var rng = DeterministicRNG(seed: mixedSeed(salt: 0))
        var cards = Array(0..<size)
        rng.shuffle(&cards)
        undealt = cards
        discard = []
        // About three quarters in, give or take a couple of percent of the
        // shoe (at least a card either way).
        let spread = max(1, size / 48)
        let jitter = rng.next(upperBound: spread * 2 + 1) - spread
        let dealtBeforeCut = Int((Double(size) * penetration).rounded()) + jitter
        cutRemaining = max(1, min(size - 1, size - dealtBeforeCut))
        isCutCardOut = false
        shuffles += 1
    }

    private func mixedSeed(salt: UInt64) -> UInt64 {
        (seed ^ salt) &+ UInt64(shuffles) &* 0x9E37_79B9_7F4A_7C15
    }

    /// Whether the shoe, the tray and `table` hold every card exactly once.
    func isComposed(withTable table: [BlackjackCard]) -> Bool {
        let all = undealt + discard + table.map(\.id)
        guard all.count == size else { return false }
        var seen = [Bool](repeating: false, count: size)
        for id in all {
            guard id >= 0, id < size, !seen[id] else { return false }
            seen[id] = true
        }
        return true
    }

    // MARK: Arranged shoes

    /// Moves one undealt copy of each of `cards` to the top of the shoe, the
    /// first of them to be dealt first. For screenshots and tests, which need
    /// a particular hand; false (and the shoe unchanged) if the shoe has run
    /// out of one of them.
    @discardableResult
    mutating func stack(_ cards: [Card]) -> Bool {
        var remaining = undealt
        var picked: [Int] = []
        for card in cards {
            // Take the copy nearest the top, so the rest of the shoe keeps
            // its order.
            guard let index = remaining.lastIndex(where: { $0 % 52 == Int(card.code) }) else { return false }
            picked.append(remaining.remove(at: index))
        }
        undealt = remaining + picked.reversed()
        return true
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey {
        case decks, undealt, discard, cutRemaining, isCutCardOut, shuffles, seed, penetration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let decks = value(.decks, 6)
        self.decks = BlackjackRules.deckChoices.contains(decks) ? decks : 6
        undealt = value(.undealt, [])
        discard = value(.discard, [])
        cutRemaining = value(.cutRemaining, 0)
        isCutCardOut = value(.isCutCardOut, false)
        shuffles = value(.shuffles, 0)
        seed = value(.seed, 0x5E_ED)
        let penetration = value(.penetration, 0.75)
        self.penetration = (0.5...0.9).contains(penetration) ? penetration : 0.75
    }
}
