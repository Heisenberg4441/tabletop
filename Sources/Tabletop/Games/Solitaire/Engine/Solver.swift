//
//  Solver.swift
//  Decides whether a deal can be won with perfect play.
//
//  Used for two things: dealing only winnable games when the player asks for
//  them, and telling a player who is stuck whether the game was ever winnable.
//  It is a "thoughtful" solver — it can see the face-down cards — which is the
//  right question for deal generation: was this deal ever solvable at all.
//
//  Three ideas carry the whole thing:
//
//  * A position is a forty-eight byte value with no heap storage, so a child
//    costs a register copy rather than five array allocations and the ARC
//    traffic that goes with them.
//  * The stock is never searched one draw at a time. Which cards a pass can
//    ever expose is decided arithmetically, so "deal round to the seven and
//    play it" is a single move and the stock contributes no nodes of its own.
//  * The search is best-first on how much digging is left rather than
//    depth-first, because Klondike is decided by turning face-down cards over
//    and a depth-first walk will happily spend its whole budget down one
//    branch that turned none.
//

import Foundation

final class KlondikeSolver {

    /// How hard to look before giving up and calling the deal unwinnable.
    ///
    /// `nodeBudget` counts distinct positions kept, which is also the size of
    /// the pool allocated up front — sixty-four bytes each, so a quarter of a
    /// million of them is sixteen megabytes of address space and only the
    /// pages actually used ever get touched. The deadline is the real
    /// guarantee: the budget bounds memory, the clock bounds the click.
    struct Limits {
        var nodeBudget = 220_000
        var maxDepth = 512
        var deadline: TimeInterval = 0.20
    }

    private let initial: GameState
    private let limits: Limits
    private(set) var nodesVisited = 0
    private(set) var hitLimit = false

    /// The line that won, in moves the real `GameState` accepts. Empty until
    /// `isWinnable()` has returned true.
    private(set) var solution: [Move] = []

    // Facts about the deal that never change, hoisted out of the position.
    private let drawCount: Int
    private let redealLimit: Int?
    /// Whether draining the stock is part of the goal. Turning one card at a
    /// time with unlimited passes reaches every card in it eventually, so once
    /// nothing is face down the packet no longer stands between here and a win.
    private let pileMatters: Bool
    /// Face-down cards, `column * 6 + index`, bottom of the column first. A
    /// column's hidden cards are always the untouched prefix of what it was
    /// dealt, so the count in the position picks them out exactly.
    private var faceDown = [UInt8](repeating: 0, count: 7 * 6)
    /// The stock and waste as one packet, waste first, then the stock in the
    /// order it will be drawn. Cards only ever leave it and never change
    /// order, which is what makes the bitmask in `Position` sufficient.
    private var pileCards: [UInt8] = []
    /// Set when the caller handed us something this representation cannot
    /// hold; the answer is then "don't know" rather than "unwinnable".
    private let unsupported: Bool

    init(state: GameState, limits: Limits = Limits()) {
        self.initial = state
        self.limits = limits
        self.drawCount = max(1, state.drawCount)
        self.redealLimit = state.redealLimit
        self.pileMatters = !(state.drawCount == 1 && state.redealLimit == nil)

        var bad = false
        for column in 0..<7 {
            let packet = state.tableau[column]
            if packet.down.count > 6 { bad = true; break }
            for (i, card) in packet.down.enumerated() { faceDown[column * 6 + i] = card.code }
            // The packed column stores a run rather than a list, so a column
            // whose face-up cards are not one is not representable. Real play
            // cannot produce that; a hand-built fixture can.
            if packet.up.count > 13 { bad = true; break }
            for i in 1..<max(1, packet.up.count) where !packet.up[i].canStack(onTableau: packet.up[i - 1]) {
                bad = true
            }
            if bad { break }
        }
        pileCards = state.waste.map(\.code) + state.stock.reversed().map(\.code)
        if pileCards.count > 32 { bad = true }
        self.unsupported = bad
    }

    // MARK: - Answering the question

    func isWinnable() -> Bool {
        nodesVisited = 0
        hitLimit = false
        solution = []
        guard !unsupported else { hitLimit = true; return false }
        return search()
    }
}

// MARK: - Cards as bare codes

// The position keeps cards as their `Card.code` byte, so these mirror the
// accessors on `Card` without paying for the wrapper in the inner loop.

@inline(__always) private func rankOf(_ code: UInt8) -> Int { Int(code % 13) + 1 }
@inline(__always) private func suitOf(_ code: UInt8) -> Int { Int(code / 13) }

/// 0 for black, 1 for red. Suits run clubs, diamonds, hearts, spades.
@inline(__always) private func colorOf(_ code: UInt8) -> Int { ((suitOf(code) &+ 1) >> 1) & 1 }

/// Which of the two suits of its colour a card is: 0 for clubs and diamonds,
/// 1 for spades and hearts. One bit is all a run needs to remember.
@inline(__always) private func suitBit(_ code: UInt8) -> UInt32 { UInt32(suitOf(code) >> 1) }

@inline(__always) private func cardCode(color: Int, bit: Int, rank: Int) -> UInt8 {
    let suit = color == 0 ? bit &* 3 : bit &+ 1
    return UInt8(suit &* 13 &+ rank &- 1)
}

// MARK: - A tableau column in one word

//     bits  0...3   face-down cards, 0...6
//     bits  4...7   face-up cards, 0...13
//     bits  8...15  the top face-up card
//     bits 16...27  suit bits: bit i names the card i+1 places below the top
//
// A face-up run always descends by one rank and alternates colour, so rank and
// colour are implied by position and only the choice between the two suits of
// that colour has to be stored. An empty column is the word zero.

@inline(__always) private func colDown(_ w: UInt32) -> Int { Int(w & 0xF) }
@inline(__always) private func colUp(_ w: UInt32) -> Int { Int((w >> 4) & 0xF) }
@inline(__always) private func colTop(_ w: UInt32) -> UInt8 { UInt8(truncatingIfNeeded: w >> 8) }
@inline(__always) private func colPath(_ w: UInt32) -> UInt32 { w >> 16 }

@inline(__always) private func makeColumn(down: Int, up: Int, top: UInt8, path: UInt32) -> UInt32 {
    UInt32(down) | (UInt32(up) << 4) | (UInt32(top) << 8) | (path << 16)
}

/// The card `depth` places below the top of a column's face-up run.
@inline(__always) private func cardAt(_ w: UInt32, depth: Int) -> UInt8 {
    let top = colTop(w)
    if depth == 0 { return top }
    let bit = Int((colPath(w) >> (depth - 1)) & 1)
    return cardCode(color: colorOf(top) ^ (depth & 1), bit: bit, rank: rankOf(top) + depth)
}

// MARK: - A whole position

/// Forty-eight bytes, no references, no allocation: copying one is a register
/// move and the search never touches the allocator.
private struct Position {
    var columns = SIMD8<UInt32>()
    /// Top rank reached on each foundation, indexed by suit.
    var foundations = SIMD4<UInt8>()
    /// Bit `i` is set while pile card `i` is still in play. The pile is always
    /// this subsequence of the packet the search started with, in that order.
    var pileMask: UInt32 = 0
    /// How many of the live pile's cards are on the waste. The rest are the
    /// stock, next to be drawn first.
    var pilePos: UInt8 = 0
    var redeals: UInt8 = 0
}

// MARK: - Moves the search makes

private enum MoveKind {
    static let tableauToFoundation: UInt8 = 0
    static let tableauToTableau: UInt8 = 1
    static let pileToFoundation: UInt8 = 2
    static let pileToTableau: UInt8 = 3
}

/// One search move. A pile move folds the draws and the redeal that expose the
/// card into the move itself: `target` is the waste height to deal up to and
/// `recycles` is whether getting there costs a pass.
private struct SolverMove {
    var kind: UInt8 = 0
    var from: UInt8 = 0
    var to: UInt8 = 0
    var count: UInt8 = 0
    var target: UInt8 = 0
    var recycles: UInt8 = 0
}

private struct Node {
    var position = Position()
    var parent: Int32 = -1
    var depth: Int32 = 0
    var move = SolverMove()
}

// MARK: - The search

/// What one pass of the search is looking for. Every profile explores the same
/// legal moves; they disagree only about which position looks promising, and
/// that disagreement is the point — see `probes`.
private struct Profile {
    var down: Int
    var pile: Int
    var found: Int
    var empty: Int
    var depth: Int
    var buried: Int
    /// How much pseudo-random spread to add to the estimate, and the constant
    /// that generates it.
    var noise: Int
    var salt: UInt64
}

extension KlondikeSolver {

    /// Every move worth trying fits in this much space: seven foundation
    /// plays, at most seven times seven column-to-column moves, and at most
    /// four destinations for each of thirty-two pile cards.
    private static let moveCapacity = 256

    /// Nodes one pass may keep. Small on purpose: Klondike's solving times are
    /// wildly heavy-tailed, so a pass that has not found a line in this many
    /// positions is far more likely to be down a bad path than close to the
    /// answer, and starting again with different taste beats pressing on.
    private static let probeCapacity = Int(ProcessInfo.processInfo.environment["T_PROBE"] ?? "") ?? 30_000

    /// The passes, in order. The weights matter less than the disagreement:
    /// each solves a slightly different set of deals, and together they settle
    /// far more than any one of them does with the whole budget to itself.
    private static let probes: [Profile] = [
        Profile(down: 6, pile: 1, found: 1, empty: 3, depth: 1, buried: 0, noise: 0, salt: 0),
        Profile(down: 4, pile: 1, found: 1, empty: 0, depth: 1, buried: 2, noise: 3, salt: 0x9e37_79b9_7f4a_7c15),
        Profile(down: 6, pile: 1, found: 2, empty: 3, depth: 0, buried: 0, noise: 0, salt: 0),
        Profile(down: 8, pile: 2, found: 1, empty: 2, depth: 2, buried: 2, noise: 5, salt: 0xc2b2_ae3d_27d4_eb4f),
        Profile(down: 2, pile: 1, found: 1, empty: 0, depth: 1, buried: 0, noise: 0, salt: 0),
        Profile(down: 6, pile: 1, found: 1, empty: 4, depth: 1, buried: 2, noise: 3, salt: 0x1656_67b1_9e37_79f9),
        Profile(down: 5, pile: 2, found: 2, empty: 3, depth: 1, buried: 1, noise: 7, salt: 0xff51_afd7_ed55_8ccd),
        Profile(down: 10, pile: 1, found: 1, empty: 6, depth: 1, buried: 3, noise: 3, salt: 0x2545_f491_4f6c_dd1d),
    ]

    private enum ProbeResult {
        /// A winning position was reached; the argument is its node index.
        case won(Int)
        /// The whole reachable space was searched. No line exists.
        case exhausted
        /// Ran out of nodes or clock with the frontier still full.
        case cutoff(Int)
    }

    private func search() -> Bool {
        guard let root = pack(initial) else { hitLimit = true; return false }

        let total = max(1024, limits.nodeBudget)
        let perProbe = min(total, Self.probeCapacity)

        let pool = UnsafeMutablePointer<Node>.allocate(capacity: perProbe)
        defer { pool.deallocate() }

        // A power-of-two open-addressed set of position keys, twice the pool so
        // probes stay short. `calloc` hands back zero pages from the kernel,
        // which costs nothing until a page is written; an explicit memset of
        // the whole table on every call would not be free.
        var tableSize = 1
        while tableSize < perProbe * 2 { tableSize <<= 1 }
        guard let tableRaw = calloc(tableSize, MemoryLayout<UInt64>.size) else {
            hitLimit = true
            return false
        }
        let table = tableRaw.assumingMemoryBound(to: UInt64.self)
        defer { free(tableRaw) }

        let moves = UnsafeMutablePointer<SolverMove>.allocate(capacity: Self.moveCapacity)
        defer { moves.deallocate() }

        if isCertainWin(root) { return finish(pool: pool, goal: -1) }

        let started = ContinuousClock.now
        let deadline = Duration.seconds(limits.deadline)
        var spent = 0
        var pass = 0

        while spent < total {
            if ContinuousClock.now - started > deadline { hitLimit = true; return false }
            if pass > 0 { memset(tableRaw, 0, tableSize * MemoryLayout<UInt64>.size) }

            var profile = Self.probes[pass % Self.probes.count]
            if pass >= Self.probes.count {
                // The listed passes are spent. Keep going with the same
                // weights but a fresh scatter each time, so every extra pass
                // is a genuinely new attempt rather than a repeat of one that
                // has already failed.
                profile.noise = max(profile.noise, 3)
                profile.salt = scramble(UInt64(pass))
            }
            pass += 1
            let budget = min(perProbe, total - spent)

            switch probe(root, profile: profile, budget: budget, pool: pool,
                         table: table, tableMask: tableSize - 1, moves: moves,
                         started: started, deadline: deadline) {
            case .won(let goal):
                return finish(pool: pool, goal: goal)
            case .exhausted:
                // Ordering cannot change what is reachable, so one pass that
                // ran the whole space dry settles the deal for all of them.
                return false
            case .cutoff(let used):
                spent += used
            }
        }
        hitLimit = true
        return false
    }

    /// Spreads a pass number out over the whole word, so consecutive passes
    /// disagree about everything rather than about the low bits.
    private func scramble(_ value: UInt64) -> UInt64 {
        var z = (value &+ 1) &* 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    private func probe(_ root: Position, profile: Profile, budget: Int,
                       pool: UnsafeMutablePointer<Node>,
                       table: UnsafeMutablePointer<UInt64>, tableMask: Int,
                       moves: UnsafeMutablePointer<SolverMove>,
                       started: ContinuousClock.Instant, deadline: Duration) -> ProbeResult {
        (pool + 0).initialize(to: Node(position: root, parent: -1, depth: 0, move: SolverMove()))
        _ = insert(key(of: root), table, tableMask)
        var used = 1

        // Entries pack the estimate above the node index so one unsigned
        // compare orders the queue. The index is stored inverted, which breaks
        // ties towards the newest node and lets the pass fall back to
        // depth-first behaviour wherever the estimate stops discriminating.
        let rootKey = key(of: root)
        var queue: [UInt64] = [heapEntry(estimate(root, depth: 0, key: rootKey, profile), 0)]
        queue.reserveCapacity(budget / 2)
        var sinceClockCheck = 0

        while let entry = pop(&queue) {
            sinceClockCheck += 1
            if sinceClockCheck >= 512 {
                sinceClockCheck = 0
                if ContinuousClock.now - started > deadline { return .cutoff(used) }
            }

            let index = Int(UInt32.max - UInt32(truncatingIfNeeded: entry))
            let parent = pool[index]
            let childDepth = parent.depth + 1
            let count = generateMoves(parent.position, into: moves)

            for i in 0..<count {
                let move = moves[i]
                let child = apply(move, to: parent.position)
                nodesVisited += 1

                if isCertainWin(child) {
                    guard used < budget else { return .cutoff(used) }
                    (pool + used).initialize(
                        to: Node(position: child, parent: Int32(index), depth: childDepth, move: move))
                    return .won(used)
                }
                guard childDepth < limits.maxDepth else { continue }
                let childKey = key(of: child)
                guard insert(childKey, table, tableMask) else { continue }
                guard used < budget else { return .cutoff(used) }

                (pool + used).initialize(
                    to: Node(position: child, parent: Int32(index), depth: childDepth, move: move))
                push(&queue, heapEntry(estimate(child, depth: Int(childDepth), key: childKey, profile),
                                       used))
                used += 1
            }
        }
        return .exhausted
    }

    /// Turns the node chain ending at `goal` into real moves, replays it
    /// through the actual rules and only then agrees the deal is winnable.
    /// A wrong "unwinnable" costs the player a different deal; a wrong
    /// "winnable" costs them an unplayable game, so the claim gets checked.
    private func finish(pool: UnsafeMutablePointer<Node>, goal: Int) -> Bool {
        var line: [Move] = []
        if goal >= 0 {
            var chain: [Int] = []
            var index = goal
            while index > 0 {
                chain.append(index)
                index = Int(pool[index].parent)
            }
            for node in chain.reversed() {
                append(pool[node].move, from: pool[Int(pool[node].parent)].position, to: &line)
            }
        }

        var state = initial
        for move in line {
            guard state.apply(move) != nil else { hitLimit = true; return false }
        }

        // The search stops as soon as every card is reachable, because from
        // there the game plays itself; walking that tail out is what proves it.
        var steps = 0
        while !state.isWon {
            guard steps < 4000, let move = state.autoFinishMove(), state.apply(move) != nil else {
                hitLimit = true
                return false
            }
            line.append(move)
            steps += 1
        }
        solution = line
        return true
    }
}

// MARK: - Building and reading the packed position

extension KlondikeSolver {

    private func pack(_ state: GameState) -> Position? {
        var position = Position()
        for column in 0..<7 {
            let packet = state.tableau[column]
            guard let top = packet.up.last else {
                guard packet.down.isEmpty else { return nil }
                continue
            }
            var path: UInt32 = 0
            // `up` runs bottom to top; the path is written from the top down.
            for depth in 1..<packet.up.count {
                path |= suitBit(packet.up[packet.up.count - 1 - depth].code) << (depth - 1)
            }
            position.columns[column] = makeColumn(
                down: packet.down.count, up: packet.up.count, top: top.code, path: path)
        }
        for suit in 0..<4 { position.foundations[suit] = state.foundations[suit] }
        position.pileMask = pileCards.isEmpty ? 0 : (UInt32(1) << pileCards.count) &- 1
        position.pilePos = UInt8(state.waste.count)
        position.redeals = UInt8(min(state.redealsUsed, 255))
        if redealLimit == nil { position.redeals = 0 }
        return position
    }

    /// True once the rest of the game is a formality.
    ///
    /// With nothing left face down and nothing left in the stock, the lowest
    /// card missing from the foundations is always the top of its column — the
    /// cards above it would have to be lower still, and those are already up —
    /// so it can always be played, and by induction so can every card after it.
    /// Drawing one at a time with unlimited passes reaches every stock card as
    /// well, so the same argument covers that case with the packet still full.
    private func isCertainWin(_ p: Position) -> Bool {
        for column in 0..<7 where colDown(p.columns[column]) != 0 { return false }
        if p.pileMask == 0 { return true }
        return drawCount == 1 && redealLimit == nil
    }

    private func key(of p: Position) -> UInt64 {
        @inline(__always) func mix(_ value: UInt64) -> UInt64 {
            var z = value &* 0xff51_afd7_ed55_8ccd
            z ^= z >> 33
            return z
        }
        var h: UInt64 = 0x9e37_79b9_7f4a_7c15
        // The seven column words plus the unused eighth lane read as four
        // sixty-four bit lanes, which halves the rounds for the same coverage.
        let wide = unsafeBitCast(p.columns, to: SIMD4<UInt64>.self)
        for lane in 0..<4 { h = mix(h ^ wide[lane] &+ UInt64(lane)) }
        var foundations: UInt64 = 0
        for suit in 0..<4 { foundations |= UInt64(p.foundations[suit]) << (suit * 8) }
        h = mix(h ^ foundations)
        h = mix(h ^ (UInt64(p.pileMask) << 8) ^ UInt64(p.pilePos))
        if redealLimit != nil { h = mix(h ^ (UInt64(p.redeals) << 56)) }
        return h
    }
}

// MARK: - Move generation

extension KlondikeSolver {

    /// A card is safe to send up when nothing can ever want to sit on it: both
    /// cards that could, the opposite colour one rank down, are already on
    /// their foundations. Aces and twos qualify outright, since an ace never
    /// needs a home in the tableau either.
    @inline(__always)
    private func isSafe(_ card: UInt8, _ foundations: SIMD4<UInt8>) -> Bool {
        let rank = rankOf(card)
        if rank <= 2 { return true }
        let need = UInt8(rank - 1)
        if colorOf(card) == 0 { return foundations[1] >= need && foundations[2] >= need }
        return foundations[0] >= need && foundations[3] >= need
    }

    private func generateMoves(_ p: Position, into buffer: UnsafeMutablePointer<SolverMove>) -> Int {
        var n = 0

        // A safe foundation play from the tableau is forced. It cannot be
        // wrong — nothing will ever need the card back — and it touches
        // neither the stock's phase nor any other column, so every line that
        // wins from here still wins after it. Branching on it only multiplies
        // the search.
        for column in 0..<7 {
            let word = p.columns[column]
            guard colUp(word) > 0 else { continue }
            let card = colTop(word)
            guard Int(p.foundations[suitOf(card)]) + 1 == rankOf(card) else { continue }
            if isSafe(card, p.foundations) {
                buffer[0] = SolverMove(kind: MoveKind.tableauToFoundation, from: UInt8(column))
                return 1
            }
            buffer[n] = SolverMove(kind: MoveKind.tableauToFoundation, from: UInt8(column))
            n += 1
        }

        // Same for a card the stock can reach, but only when the packet's
        // batching cannot matter. Turning one card at a time with unlimited
        // passes reaches every card in the packet whatever the waste happens
        // to be standing on, so taking one out early strands nothing. Deal
        // three at a time and it does: removing a card shifts every later
        // batch by one and a different set of cards comes up next pass, which
        // measurably costs deals that were winnable the other way round.
        if !pileMatters, let forced = forcedPileMove(p) {
            buffer[0] = forced
            return 1
        }

        // Two empty columns are interchangeable, so only ever fill the first.
        var firstEmpty = -1
        for column in 0..<7 where p.columns[column] == 0 {
            firstEmpty = column
            break
        }

        for from in 0..<7 {
            let source = p.columns[from]
            let up = colUp(source)
            guard up > 0 else { continue }
            let top = colTop(source)
            let topRank = rankOf(top)
            let topColor = colorOf(top)

            // Only a king can head for an empty column, it can only be the
            // bottom of the run, and shifting one that already sits on bare
            // table achieves nothing.
            if firstEmpty >= 0, topRank + up - 1 == 13, colDown(source) > 0 {
                buffer[n] = SolverMove(kind: MoveKind.tableauToTableau, from: UInt8(from),
                                       to: UInt8(firstEmpty), count: UInt8(up))
                n += 1
            }

            for to in 0..<7 where to != from {
                let destination = p.columns[to]
                guard colUp(destination) > 0 else { continue }
                let seat = colTop(destination)
                // At most one card in a descending run has the rank the seat
                // wants, so the pick-up depth is arithmetic rather than search.
                let depth = rankOf(seat) - 1 - topRank
                guard depth >= 0, depth < up else { continue }
                guard topColor ^ (depth & 1) != colorOf(seat) else { continue }
                buffer[n] = SolverMove(kind: MoveKind.tableauToTableau, from: UInt8(from),
                                       to: UInt8(to), count: UInt8(depth + 1))
                n += 1
            }
        }

        n += generatePileMoves(p, into: buffer + n, firstEmpty: firstEmpty)
        return n
    }

    /// How many passes over the waste it takes to bring the pile to `target`
    /// cards on the waste, or -1 if it cannot get there at all.
    ///
    /// Dealing `drawCount` at a time from where the waste stands now exposes
    /// every `drawCount`-th card and then whatever the short last handful ends
    /// on. Turning the waste back over restarts the count from zero, which is
    /// the only thing that changes the phase; a second pass repeats the first,
    /// so one is all that is ever worth counting.
    @inline(__always)
    private func passesToReach(_ target: Int, from position: Int, total: Int,
                               canRecycle: Bool) -> Int {
        if target >= position, (target - position) % drawCount == 0 || target == total { return 0 }
        if canRecycle, target % drawCount == 0 || target == total { return 1 }
        return -1
    }

    @inline(__always)
    private func canRecycle(_ p: Position) -> Bool {
        redealLimit.map { Int(p.redeals) < $0 } ?? true
    }

    /// A reachable pile card that is safe to send straight up, if there is one.
    private func forcedPileMove(_ p: Position) -> SolverMove? {
        let total = p.pileMask.nonzeroBitCount
        guard total > 0 else { return nil }
        let position = Int(p.pilePos)
        let recycles = canRecycle(p)
        var mask = p.pileMask
        var index = 0
        while mask != 0 {
            let card = pileCards[mask.trailingZeroBitCount]
            mask &= mask &- 1
            index += 1
            guard Int(p.foundations[suitOf(card)]) + 1 == rankOf(card),
                  isSafe(card, p.foundations) else { continue }
            let passes = passesToReach(index, from: position, total: total, canRecycle: recycles)
            guard passes >= 0 else { continue }
            return SolverMove(kind: MoveKind.pileToFoundation, target: UInt8(index),
                              recycles: UInt8(passes))
        }
        return nil
    }

    /// Moves that start with turning the stock over.
    ///
    /// Dealing without playing is never worth a node of its own: it can only
    /// shrink the set of cards the rest of the pass will expose, and playing
    /// the card on top leaves every later boundary exactly where it was. So
    /// each reachable card becomes one move that deals up to it and plays it.
    private func generatePileMoves(_ p: Position, into buffer: UnsafeMutablePointer<SolverMove>,
                                   firstEmpty: Int) -> Int {
        let total = p.pileMask.nonzeroBitCount
        guard total > 0 else { return 0 }

        let position = Int(p.pilePos)
        let recycles = canRecycle(p)

        var n = 0
        var mask = p.pileMask
        var index = 0
        while mask != 0 {
            let card = pileCards[mask.trailingZeroBitCount]
            mask &= mask &- 1
            index += 1
            let target = index

            let passes = passesToReach(target, from: position, total: total, canRecycle: recycles)
            guard passes >= 0 else { continue }

            if Int(p.foundations[suitOf(card)]) + 1 == rankOf(card) {
                buffer[n] = SolverMove(kind: MoveKind.pileToFoundation, target: UInt8(target),
                                       recycles: UInt8(passes))
                n += 1
            }
            if rankOf(card) == 13 {
                if firstEmpty >= 0 {
                    buffer[n] = SolverMove(kind: MoveKind.pileToTableau, to: UInt8(firstEmpty),
                                           target: UInt8(target), recycles: UInt8(passes))
                    n += 1
                }
                continue
            }
            for to in 0..<7 {
                let destination = p.columns[to]
                guard colUp(destination) > 0 else { continue }
                let seat = colTop(destination)
                guard rankOf(seat) == rankOf(card) + 1, colorOf(seat) != colorOf(card) else { continue }
                buffer[n] = SolverMove(kind: MoveKind.pileToTableau, to: UInt8(to),
                                       target: UInt8(target), recycles: UInt8(passes))
                n += 1
            }
        }
        return n
    }
}

// MARK: - Applying a move

extension KlondikeSolver {

    /// The column word left after lifting `count` cards off the top, turning
    /// the next face-down card over if that emptied the run.
    @inline(__always)
    private func lift(_ word: UInt32, count: Int, column: Int) -> UInt32 {
        let remaining = colUp(word) - count
        if remaining > 0 {
            return makeColumn(down: colDown(word), up: remaining,
                              top: cardAt(word, depth: count), path: colPath(word) >> count)
        }
        let down = colDown(word)
        guard down > 0 else { return 0 }
        return makeColumn(down: down - 1, up: 1, top: faceDown[column * 6 + down - 1], path: 0)
    }

    /// The column word left after dropping a run of `count` cards, whose own
    /// top card and suit bits are given, onto `word`.
    @inline(__always)
    private func drop(_ word: UInt32, top: UInt8, count: Int, path: UInt32) -> UInt32 {
        let up = colUp(word)
        guard up > 0 else { return makeColumn(down: 0, up: count, top: top, path: path) }
        let joined = path | (suitBit(colTop(word)) << (count - 1)) | (colPath(word) << count)
        return makeColumn(down: colDown(word), up: up + count, top: top, path: joined)
    }

    private func apply(_ move: SolverMove, to p: Position) -> Position {
        var child = p
        switch move.kind {
        case MoveKind.tableauToFoundation:
            let column = Int(move.from)
            let card = colTop(p.columns[column])
            child.foundations[suitOf(card)] = UInt8(rankOf(card))
            child.columns[column] = lift(p.columns[column], count: 1, column: column)

        case MoveKind.tableauToTableau:
            let from = Int(move.from), to = Int(move.to), count = Int(move.count)
            let source = p.columns[from]
            let path = colPath(source) & ((UInt32(1) << (count - 1)) &- 1)
            child.columns[from] = lift(source, count: count, column: from)
            child.columns[to] = drop(child.columns[to], top: colTop(source), count: count, path: path)

        default:
            let target = Int(move.target)
            let bit = nthSetBit(p.pileMask, target - 1)
            let card = pileCards[bit]
            child.pileMask = p.pileMask & ~(UInt32(1) << bit)
            child.pilePos = UInt8(target - 1)
            if redealLimit != nil { child.redeals = p.redeals &+ move.recycles }
            if move.kind == MoveKind.pileToFoundation {
                child.foundations[suitOf(card)] = UInt8(rankOf(card))
            } else {
                child.columns[Int(move.to)] = drop(child.columns[Int(move.to)],
                                                   top: card, count: 1, path: 0)
            }
        }
        return child
    }

    /// The bit index of set bit number `n`, counting from zero.
    @inline(__always)
    private func nthSetBit(_ mask: UInt32, _ n: Int) -> Int {
        var remaining = mask
        for _ in 0..<n { remaining &= remaining &- 1 }
        return remaining.trailingZeroBitCount
    }

    /// Expands one search move into the moves the real game understands,
    /// spelling out the draws and the redeal a pile move folded away.
    private func append(_ move: SolverMove, from p: Position, to line: inout [Move]) {
        switch move.kind {
        case MoveKind.tableauToFoundation:
            line.append(.tableauToFoundation(column: Int(move.from)))
        case MoveKind.tableauToTableau:
            line.append(.tableauToTableau(from: Int(move.from), to: Int(move.to),
                                          count: Int(move.count)))
        default:
            let total = p.pileMask.nonzeroBitCount
            var at = Int(p.pilePos)
            if move.recycles > 0 {
                while at < total {
                    line.append(.draw(count: drawCount))
                    at = min(at + drawCount, total)
                }
                line.append(.recycle)
                at = 0
            }
            while at < Int(move.target) {
                line.append(.draw(count: drawCount))
                at = min(at + drawCount, total)
            }
            if move.kind == MoveKind.pileToFoundation {
                line.append(.wasteToFoundation)
            } else {
                line.append(.wasteToTableau(column: Int(move.to)))
            }
        }
    }
}

// MARK: - Ordering the frontier

extension KlondikeSolver {

    /// How far the position looks from a game that finishes itself.
    ///
    /// Face-down cards dominate because turning them over is the only thing
    /// that opens Klondike up; the packet counts because a draw-three game is
    /// not decided until the stock has drained; and the foundations count so
    /// that two equally dug-out positions prefer the one further along.
    /// Depth is added at weight one, which keeps the walk honest — pure greed
    /// wanders sideways forever across positions that shuffle runs about.
    @inline(__always)
    private func estimate(_ p: Position, depth: Int, key: UInt64, _ profile: Profile) -> Int {
        var down = 0
        var empties = 0
        var buried = 0
        for column in 0..<7 {
            let word = p.columns[column]
            let hidden = colDown(word)
            down += hidden
            if word == 0 { empties += 1 }
            if hidden > 0 { buried += colUp(word) }
        }
        var found = 0
        for suit in 0..<4 { found += Int(p.foundations[suit]) }

        var value = depth * profile.depth
            + down * profile.down
            + p.pileMask.nonzeroBitCount * (pileMatters ? profile.pile : 0)
            + (52 - found) * profile.found
            - empties * profile.empty
            + buried * profile.buried
        if profile.noise > 0 {
            value += Int((key &* profile.salt) >> 58) % (profile.noise + 1)
        }
        return value + 64
    }

    @inline(__always)
    private func heapEntry(_ estimate: Int, _ index: Int) -> UInt64 {
        (UInt64(UInt32(truncatingIfNeeded: estimate)) << 32)
            | UInt64(UInt32.max - UInt32(truncatingIfNeeded: index))
    }

    private func push(_ heap: inout [UInt64], _ entry: UInt64) {
        heap.append(entry)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) >> 1
            guard heap[parent] > heap[child] else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private func pop(_ heap: inout [UInt64]) -> UInt64? {
        guard let best = heap.first else { return nil }
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                var smallest = left
                if right < heap.count, heap[right] < heap[left] { smallest = right }
                guard heap[smallest] < heap[parent] else { break }
                heap.swapAt(smallest, parent)
                parent = smallest
            }
        }
        return best
    }

    /// Records `key` in the open-addressed set, answering whether it was new.
    @inline(__always)
    private func insert(_ key: UInt64, _ table: UnsafeMutablePointer<UInt64>, _ mask: Int) -> Bool {
        let stored = key | 1                     // zero marks an empty slot
        var slot = Int(truncatingIfNeeded: key >> 24) & mask
        while true {
            let found = table[slot]
            if found == 0 { table[slot] = stored; return true }
            if found == stored { return false }
            slot = (slot + 1) & mask
        }
    }
}
