//
//  PokerEquity.swift
//  What the bots know about cards: how good two hole cards are before the
//  flop (the Chen formula), what the board looks like, and — the expensive
//  part — how often a hand wins against the others still in, by dealing the
//  rest of the hand out a few thousand times (Monte-Carlo).
//
//  Everything here is pure and runs on whatever thread calls it; the bots
//  call it on a background queue. The simulation is written against the
//  evaluator's bit masks and a reused buffer, so a sample costs a handful of
//  random numbers and one evaluation per player — no allocation inside the
//  loop.
//

import Foundation

/// How the simulation narrows one opponent's cards to what their actions
/// suggest. Rejection sampling: a dealt hand that does not fit is re-dealt,
/// a few times at most, so the narrowing is light rather than absolute — a
/// raiser *usually* has a good hand, not always.
struct PokerRangeFilter: Hashable, Sendable {
    /// Hands with a Chen score below this are kept only with `weakKeep`
    /// probability.
    var minChen: Double = -10
    var weakKeep: Double = 1
    /// After postflop action: hands that miss the board (no pair of their
    /// own, no flush draw) are kept with this probability…
    var airKeep: Double = 1
    /// …and a pair below the board's top card (middle or bottom pair, an
    /// underpair) with this one. Top pair, an overpair and better always stay.
    var weakPairKeep: Double = 1

    static let anyHand = PokerRangeFilter()

    init(minChen: Double = -10, weakKeep: Double = 1, airKeep: Double = 1, weakPairKeep: Double = 1) {
        self.minChen = minChen
        self.weakKeep = weakKeep
        self.airKeep = airKeep
        self.weakPairKeep = weakPairKeep
    }

    var isAnyHand: Bool { weakKeep >= 1 && airKeep >= 1 && weakPairKeep >= 1 }
}

enum PokerEquity {

    // MARK: Preflop strength

    /// Bill Chen's quick score for two hole cards: roughly −1 (seven-two
    /// off-suit) to 20 (aces). Highest card (ace 10, king 8, queen 7, jack
    /// 6, the rest half their pips), doubled for a pair (at least 5), +2
    /// suited, −1/−2/−4/−5 for gaps, +1 for connected cards below a queen,
    /// halves rounded up.
    static func chen(_ a: Card, _ b: Card) -> Double {
        chenTable[chenIndex(a.pokerRank, b.pokerRank, a.suit == b.suit)]
    }

    static func chen(_ hole: [Card]) -> Double {
        guard hole.count == 2 else { return 0 }
        return chen(hole[0], hole[1])
    }

    @inline(__always)
    private static func chenIndex(_ r1: Int, _ r2: Int, _ suited: Bool) -> Int {
        (max(r1, r2) * 13 + min(r1, r2)) * 2 + (suited ? 1 : 0)
    }

    private static let chenTable: [Double] = {
        var table = [Double](repeating: 0, count: 13 * 13 * 2)
        for hi in 0..<13 {
            for lo in 0...hi {
                for suited in [false, true] {
                    table[chenIndex(hi, lo, suited)] = chenScore(high: hi, low: lo, suited: suited && hi != lo)
                }
            }
        }
        return table
    }()

    private static func chenScore(high: Int, low: Int, suited: Bool) -> Double {
        func points(_ r: Int) -> Double {
            switch r {
            case 12: return 10
            case 11: return 8
            case 10: return 7
            case 9: return 6
            default: return Double(r + 2) / 2
            }
        }
        var score = points(high)
        if high == low {
            return max(5, score * 2)
        }
        if suited { score += 2 }
        let gap = high - low - 1
        switch gap {
        case 0: break
        case 1: score -= 1
        case 2: score -= 2
        case 3: score -= 4
        default: score -= 5
        }
        if gap <= 1 && high < 10 { score += 1 }
        return score.rounded(.up)
    }

    // MARK: The board

    struct Texture: Hashable, Sendable {
        /// Four to a flush with at least one of our cards, the river to come.
        var flushDraw = false
        /// Ranks that would complete a straight using one of our cards: two
        /// for an open-ended draw, one for a gutshot.
        var straightOuts = 0
        /// Three or more of one suit on the board.
        var flushPossible = false
        /// Three board cards within five ranks: a straight is out there.
        var straightPossible = false
        var paired = false
        /// Two of a suit on the board, or two connected cards: draws about.
        var wet = false

        var hasDraw: Bool { flushDraw || straightOuts >= 2 }
        /// A board that makes a bet believable.
        var scary: Bool { flushPossible || straightPossible || paired }
        var dry: Bool { !wet && !scary }
    }

    static func texture(hole: [Card], board: [Card]) -> Texture {
        var t = Texture()
        guard board.count >= 3 else { return t }
        var boardSuits = [Int](repeating: 0, count: 4)
        var boardRanks: UInt32 = 0
        var rankCount = [Int](repeating: 0, count: 13)
        for card in board {
            boardSuits[Int(card.suit.rawValue)] += 1
            boardRanks |= 1 << UInt32(card.pokerRank)
            rankCount[card.pokerRank] += 1
        }
        t.paired = rankCount.contains { $0 >= 2 }
        t.flushPossible = boardSuits.contains { $0 >= 3 }
        t.wet = boardSuits.contains { $0 >= 2 } || hasConnected(boardRanks, window: 3, need: 2)
        t.straightPossible = hasConnected(boardRanks, window: 5, need: 3)

        if board.count < 5 {
            for suit in 0..<4 {
                let mine = hole.filter { Int($0.suit.rawValue) == suit }.count
                if mine > 0 && mine + boardSuits[suit] == 4 { t.flushDraw = true }
            }
            var all = boardRanks
            for card in hole { all |= 1 << UInt32(card.pokerRank) }
            if PokerEvaluator.straightTop(all) < 0 {
                for r in 0..<13 where all & (1 << UInt32(r)) == 0 {
                    // Only outs our cards help with count: the board making a
                    // straight on its own is everybody's.
                    if PokerEvaluator.straightTop(all | 1 << UInt32(r)) >= 0
                        && PokerEvaluator.straightTop(boardRanks | 1 << UInt32(r)) < 0 {
                        t.straightOuts += 1
                    }
                }
            }
        }
        return t
    }

    /// Whether `need` ranks of `ranks` fall within some run of `window`
    /// consecutive ranks (the ace counting low as well).
    private static func hasConnected(_ ranks: UInt32, window: Int, need: Int) -> Bool {
        let m = (ranks << 1) | ((ranks >> 12) & 1)
        for low in 0...(14 - window) {
            let slice = (m >> UInt32(low)) & ((1 << UInt32(window)) - 1)
            if slice.nonzeroBitCount >= need { return true }
        }
        return false
    }

    // MARK: Monte-Carlo

    /// Card code → evaluator bit, so the inner loop never builds a `Card`.
    private static let bitForCode: [UInt64] = Card.full.map(\.pokerBit)

    /// The share of the pot `hole` wins on average against `opponents`
    /// (one filter each) with `board` so far: the rest of the board and the
    /// opponents' cards dealt at random `samples` times, ties split.
    static func estimate(hole: [Card], board: [Card], opponents: [PokerRangeFilter],
                         samples: Int, rng: inout DeterministicRNG) -> Double {
        let k = opponents.count
        guard k > 0, hole.count == 2, samples > 0 else { return 1 }
        let holeMask = PokerEvaluator.mask(hole)
        let boardMask = PokerEvaluator.mask(board)
        let dead = holeMask | boardMask
        var live: [UInt8] = []
        live.reserveCapacity(52)
        for code in 0..<52 where dead & bitForCode[code] == 0 { live.append(UInt8(code)) }
        let n = live.count
        let missing = 5 - board.count
        guard n >= 2 * k + missing else { return 1 }
        let filtersAreTrivial = opponents.allSatisfy(\.isAnyHand)
        let bits = bitForCode
        let boardTop = board.map(\.pokerRank).max() ?? -1

        var opponentMasks = [UInt64](repeating: 0, count: k)
        var share = 0.0
        for _ in 0..<samples {
            var pos = 0
            for o in 0..<k {
                var attempt = 0
                while true {
                    let i = pos + rng.next(upperBound: n - pos)
                    live.swapAt(pos, i)
                    let j = pos + 1 + rng.next(upperBound: n - pos - 1)
                    live.swapAt(pos + 1, j)
                    if filtersAreTrivial || attempt >= 5
                        || accepts(opponents[o], live[pos], live[pos + 1], boardMask: boardMask,
                                   boardCount: board.count, boardTop: boardTop, rng: &rng) {
                        break
                    }
                    attempt += 1
                }
                opponentMasks[o] = bits[Int(live[pos])] | bits[Int(live[pos + 1])]
                pos += 2
            }
            var common = boardMask
            for _ in 0..<missing {
                let i = pos + rng.next(upperBound: n - pos)
                live.swapAt(pos, i)
                common |= bits[Int(live[pos])]
                pos += 1
            }
            let mine = PokerEvaluator.rawValue(of: holeMask | common)
            var ties = 0
            var lost = false
            for o in 0..<k {
                let theirs = PokerEvaluator.rawValue(of: opponentMasks[o] | common)
                if theirs > mine { lost = true; break }
                if theirs == mine { ties += 1 }
            }
            if !lost { share += 1 / Double(ties + 1) }
        }
        return share / Double(samples)
    }

    /// Whether a dealt pair of cards fits `filter` this time: a hand that
    /// does not fit its preflop range, or misses a board the player has been
    /// acting on, survives only with its keep probability.
    private static func accepts(_ filter: PokerRangeFilter, _ a: UInt8, _ b: UInt8, boardMask: UInt64,
                                boardCount: Int, boardTop: Int, rng: inout DeterministicRNG) -> Bool {
        let ra = Int(a % 13), rb = Int(b % 13)
        // Card codes put the ace at 0; poker ranks put it at 12.
        let pa = ra == 0 ? 12 : ra - 1, pb = rb == 0 ? 12 : rb - 1
        if filter.weakKeep < 1 {
            let score = chenTable[chenIndex(pa, pb, a / 13 == b / 13)]
            if score < filter.minChen && unit(&rng) >= filter.weakKeep { return false }
        }
        guard boardCount >= 3, filter.airKeep < 1 || filter.weakPairKeep < 1 else { return true }
        let mask = bitForCode[Int(a)] | bitForCode[Int(b)] | boardMask
        let value = PokerEvaluator.rawValue(of: mask)
        let category = value >> 20
        guard category <= 1 else { return true }          // two pair or better stays
        var keep = 1.0
        if category == 1 {
            let pair = Int((value >> 16) & 0xF) - 1
            if pair != pa && pair != pb {
                keep = filter.airKeep                      // the pair is the board's, not theirs
            } else if pair < boardTop {
                keep = filter.weakPairKeep
            }
        } else {
            keep = filter.airKeep
        }
        if keep < 1 && boardCount < 5 {
            // A flush draw is a reason to be in the pot, not air.
            for suit in 0..<4 where ((mask >> UInt64(suit * 16)) & 0x1FFF).nonzeroBitCount >= 4 {
                keep = max(keep, filter.weakPairKeep)
            }
        }
        return keep >= 1 || unit(&rng) < keep
    }

    @inline(__always)
    static func unit(_ rng: inout DeterministicRNG) -> Double {
        Double(rng.next() >> 11) / Double(1 << 53)
    }
}
