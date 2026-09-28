//
//  DurakEndgameSolver.swift
//  Perfect play once the deck is gone and two players are left.
//
//  With the deck empty and everybody else out, nothing is hidden any more:
//  every card that is not in your hand, on the table or in the discard is in
//  the other player's hand. So the position is a game of perfect information,
//  and small enough to search to the end: minimax with alpha-beta and a
//  transposition table, on a position that is four 36-bit words and a few
//  bytes. The result is exact — win, draw or durak — for every move.
//
//  The search works from public information only (`DurakBotView`'s rule):
//  the opponent's hand is reconstructed, never read, and the reconstruction
//  is checked against the count of cards the opponent visibly holds.
//
//  The rules here are the engine's rules restated for two sides and bit
//  masks, because the engine's arrays cost too much to copy a million times.
//  `DurakTests` plays thousands of small endgames through both and checks
//  that they agree to the last draw.
//
//  PODKIDNOY ALWAYS ENDS: every bout either sends cards to the discard (bito)
//  or, after a take, leaves the same attacker attacking with fewer cards. So
//  its positions form a finite acyclic graph and plain alpha-beta over a
//  transposition table is exact.
//
//  PEREVODNOY CAN GO ROUND IN CIRCLES: a transfer swaps the roles, so two
//  players who keep transferring and taking can repeat a position for ever.
//  Nobody at a real table would, and the solver scores endless play as a
//  draw — the value of a position is then +1 if side 0 can force a win, -1
//  if side 1 can, and 0 otherwise, which is well defined and independent of
//  how the position was reached. Alpha-beta computes exactly that as long as
//  it never meets a position already on its own line (every value it combines
//  is then a true value); the moment it does, the search starts again as a
//  retrograde analysis of the whole reachable graph — two attractor
//  computations, which handle cycles exactly. Plain minimax that calls a
//  repetition on its own line a draw arrives at the same value for the
//  position it starts from, which is what the self-test's brute force does.
//

import Foundation

struct DurakEndgameSolver {

    /// One position, from side 0's point of view. Side 0 is the player the
    /// search is for.
    struct Position: Hashable {
        var hand0: UInt64
        var hand1: UInt64
        /// Every card on the table.
        var table: UInt64
        /// The attacking cards not yet beaten.
        var unbeaten: UInt64
        /// Attacking cards played this bout.
        var attacks: Int8
        /// The side that leads and throws in (0 or 1); the other defends.
        var attacker: Int8
        var phase: Phase
        /// This bout's attack limit: five in the game's first bout, else six.
        var limit: Int8
        /// -1, or the ranks on the table when the attacker passed in this
        /// bout's throw-in round (the engine asks them again only for a
        /// rank that has appeared since).
        var passed: Int16

        func hand(_ side: Int8) -> UInt64 { side == 0 ? hand0 : hand1 }

        mutating func setHand(_ side: Int8, _ bits: UInt64) {
            if side == 0 { hand0 = bits } else { hand1 = bits }
        }

        var defender: Int8 { 1 - attacker }
        var toMove: Int8 { phase == .defend ? defender : attacker }
    }

    enum Phase: Int8, Hashable {
        case lead, defend, throwIn, pileOn
    }

    /// A move in the search's own terms: durak card indices.
    enum Move: Hashable {
        case attack(Int)
        case defend(Int, on: Int)
        case transfer(Int)
        case take
        case pass
    }

    /// The outcome of a move: a position still to play, or the game's end
    /// scored for side 0 (+1 the other side is the durak, 0 a draw, -1 side
    /// 0 is the durak).
    enum Outcome {
        case position(Position)
        case end(Int8)
    }

    private enum Bound: UInt8 { case exact, lower, upper }
    private struct Entry { var value: Int8; var bound: Bound }
    private struct OutOfBudget: Error {}
    /// Alpha-beta met a position already on its own line.
    private struct Repetition: Error {}

    let trump: Suit
    let transfers: Bool
    /// Positions the search may visit before it gives up; the bot then falls
    /// back to its heuristics.
    let budget: Int
    private(set) var nodes = 0
    private var memo: [Position: Entry] = [:]
    /// The positions on the line being searched — kept only in perevodnoy,
    /// the one variant whose positions can repeat.
    private var line: Set<Position> = []
    /// No line may be deeper than this: the search runs on a background
    /// thread with a small stack, and no real ending is anywhere near it.
    static let maximumDepth = 400
    private let beaters: [UInt64]
    /// Card indices cheapest first (plain cards by rank, then trumps), so
    /// moves come out in a good order without sorting at every node.
    private let cheapestOrder: [Int]

    init(trump: Suit, transfers: Bool, budget: Int = DurakEndgameSolver.defaultBudget) {
        self.trump = trump
        self.transfers = transfers
        self.budget = budget
        beaters = Card.durakDeck.map { DurakCardSet.beaters(of: $0, trump: trump).bits }
        let cost = Card.durakDeck.map { $0.durakRankIndex + ($0.suit == trump ? 9 : 0) }
        cheapestOrder = (0..<36).sorted { cost[$0] < cost[$1] || (cost[$0] == cost[$1] && $0 < $1) }
        memo.reserveCapacity(4096)
    }

    /// Enough for nearly every ending of up to fourteen cards in play, in
    /// well under a tenth of a second in a release build, and about 50 MB at
    /// most.
    ///
    /// Perevodnoy stays at this. Its hard endings are the ones whose lines
    /// repeat, and those need the whole reachable graph walked (see above) —
    /// measured over real Hard games, four times the budget solves one more
    /// fourteen-card ending in forty and costs four times the memory; the
    /// rest do not finish even at two million positions (700 MB). The
    /// heuristics play them until they shrink.
    static let defaultBudget = 120_000

    /// Podkidnoy never repeats, so alpha-beta's table is all the memory it
    /// needs: this reads most sixteen-card endings (about 55 MB, a tenth of
    /// a second — well inside the bot's pause for thought). A debug build
    /// searches several times slower, so there it reads a card less, in the
    /// same time.
    #if DEBUG
    static let deepBudget = defaultBudget
    #else
    static let deepBudget = 400_000
    #endif

    /// Endings with more cards than this in play (both hands and the table)
    /// are not attempted: measured over real games, they almost always run
    /// out of budget, which would only burn time. The heuristics play them
    /// until they shrink.
    static let maximumCards = 15

    /// Without transfers, with `deepBudget`, a card further.
    #if DEBUG
    static let maximumCardsWithoutTransfers = maximumCards
    #else
    static let maximumCardsWithoutTransfers = 16
    #endif

    // MARK: From the engine

    /// The position `seat` sees in `state`, when it is a perfect-information
    /// endgame: the deck gone and nobody but `seat` and one opponent holding
    /// cards (the opponent may have just played their last card mid-bout —
    /// the bout still has to be settled). Nil otherwise. Uses only what
    /// `seat` may know.
    static func position(of state: DurakState, for seat: Int) -> (Position, opponent: Int)? {
        guard state.stock.isEmpty, !state.isOver, let actor = state.actor else { return nil }
        let holders = (0..<state.playerCount).filter { !state.hands[$0].isEmpty }
        // The two sides are the defender and the one seat that can still
        // throw in: whichever of them `seat` is not.
        let opponent: Int
        if seat == state.defender {
            opponent = holders.first { $0 != seat } ?? state.attacker
        } else {
            opponent = state.defender
        }
        guard opponent != seat, holders.allSatisfy({ $0 == seat || $0 == opponent }),
              actor == seat || actor == opponent else { return nil }
        let mine = DurakCardSet(state.hands[seat])
        let table = DurakCardSet(state.tableCards)
        // Everything not in my hand, on the table or in the discard is the
        // opponent's: the deck is gone and everybody else is out.
        let theirs = DurakCardSet.all.subtracting(mine).subtracting(table).subtracting(DurakCardSet(state.discard))
        guard theirs.count == state.hands[opponent].count else { return nil }
        let attackerSeat = state.defender == seat ? opponent : seat
        let phase: Phase
        switch state.phase {
        case .lead: phase = .lead
        case .defend: phase = .defend
        case .throwIn: phase = .throwIn
        case .pileOn: phase = .pileOn
        case .over: return nil
        }
        let position = Position(
            hand0: mine.bits, hand1: theirs.bits, table: table.bits,
            unbeaten: DurakCardSet(state.unbeatenAttacks).bits,
            attacks: Int8(state.attackCount), attacker: attackerSeat == seat ? 0 : 1, phase: phase,
            limit: Int8(state.attackLimit), passed: Int16(state.throwInPassMask(for: attackerSeat)))
        return (position, opponent)
    }

    static func action(for move: Move) -> DurakAction {
        switch move {
        case .attack(let c): return .attack(Card.durak(index: c))
        case .defend(let c, let on): return .defend(Card.durak(index: c), on: Card.durak(index: on))
        case .transfer(let c): return .transfer(Card.durak(index: c))
        case .take: return .take
        case .pass: return .pass
        }
    }

    /// Every legal move for `seat` in `state` with its exact value for `seat`
    /// (+1 win, 0 draw, -1 durak), or nil when the position is not a
    /// two-player endgame, is not `seat`'s decision, or is too big to finish
    /// within the budget.
    mutating func evaluateMoves(in state: DurakState, for seat: Int,
                                preferring preferred: DurakAction? = nil) -> [(action: DurakAction, value: Int)]? {
        guard state.actor == seat, let (root, _) = Self.position(of: state, for: seat) else { return nil }
        var moves = orderedMoves(root)
        if let preferred, let i = moves.firstIndex(where: { Self.action(for: $0) == preferred }) {
            moves.insert(moves.remove(at: i), at: 0)
        }
        var results: [(DurakAction, Int)] = []
        if transfers { line = [root] }
        defer { line = [] }
        do {
            for move in moves {
                let value: Int8
                switch apply(move, to: root) {
                case .end(let v): value = v
                case .position(let next): value = try search(next, -1, 1, depth: 1)
                }
                results.append((Self.action(for: move), Int(value)))
            }
        } catch is Repetition {
            nodes = 0
            guard let values = retrograde(from: root) else { return nil }
            return moves.map { move in
                switch apply(move, to: root) {
                case .end(let v): return (Self.action(for: move), Int(v))
                case .position(let next): return (Self.action(for: move), Int(values[next] ?? 0))
                }
            }
        } catch {
            return nil
        }
        return results
    }

    /// The best move for `seat`, keeping `preferred` (the heuristics' choice)
    /// unless another move is strictly better; nil when the position is not
    /// a two-player endgame, is too big, or runs out of budget.
    ///
    /// Cheaper than `evaluateMoves`: the preferred move gets an exact value,
    /// and every other move only has to show whether it beats that — a
    /// narrow window that alpha-beta usually settles in a few nodes.
    mutating func choose(in state: DurakState, for seat: Int, preferring preferred: DurakAction,
                         maximumCards: Int = DurakEndgameSolver.maximumCards) -> DurakAction? {
        guard state.actor == seat, let (root, _) = Self.position(of: state, for: seat) else { return nil }
        let inPlay = (root.hand0 | root.hand1 | root.table).nonzeroBitCount
        guard inPlay <= maximumCards else { return nil }
        var moves = orderedMoves(root)
        if let i = moves.firstIndex(where: { Self.action(for: $0) == preferred }) {
            moves.insert(moves.remove(at: i), at: 0)
        }
        if transfers { line = [root] }
        defer { line = [] }
        do {
            var best: Int8 = -2
            var choice = moves[0]
            for move in moves {
                let value: Int8
                switch apply(move, to: root) {
                case .end(let v): value = v
                case .position(let next):
                    // The first move exactly; the rest only against it.
                    value = try search(next, best < -1 ? -1 : best, 1, depth: 1)
                }
                if value > best {
                    best = value
                    choice = move
                }
                if best == 1 { break }
            }
            return Self.action(for: choice)
        } catch is Repetition {
            // Straight to the graph: alpha-beta over every move again would
            // only spend the budget the walk needs, meeting the same repeat.
            nodes = 0
            guard let values = retrograde(from: root) else { return nil }
            var best: Int8 = -2
            var choice = moves[0]
            for move in moves {
                let value: Int8
                switch apply(move, to: root) {
                case .end(let v): value = v
                case .position(let next): value = values[next] ?? 0
                }
                if value > best {
                    best = value
                    choice = move
                }
            }
            return Self.action(for: choice)
        } catch {
            return nil
        }
    }

    /// The exact value of `state` for `seat`, whoever is to move; nil when
    /// it is not a two-player endgame or the budget runs out.
    mutating func value(of state: DurakState, for seat: Int) -> Int? {
        guard let (root, _) = Self.position(of: state, for: seat) else { return nil }
        do {
            return Int(try search(root, -1, 1, depth: 0))
        } catch is Repetition {
            nodes = 0
            return retrograde(from: root).flatMap { $0[root] }.map(Int.init)
        } catch {
            return nil
        }
    }

    // MARK: The search

    private mutating func search(_ p: Position, _ alphaIn: Int8, _ betaIn: Int8, depth: Int) throws -> Int8 {
        nodes += 1
        if nodes > budget || depth > Self.maximumDepth { throw OutOfBudget() }
        if transfers {
            guard line.insert(p).inserted else { throw Repetition() }
        }
        defer { if transfers { line.remove(p) } }
        var alpha = alphaIn, beta = betaIn
        if let entry = memo[p] {
            switch entry.bound {
            case .exact: return entry.value
            case .lower: alpha = max(alpha, entry.value)
            case .upper: beta = min(beta, entry.value)
            }
            if alpha >= beta { return entry.value }
        }
        let maximising = p.toMove == 0
        var best: Int8 = maximising ? -2 : 2
        for move in orderedMoves(p) {
            let value: Int8
            switch apply(move, to: p) {
            case .end(let v): value = v
            case .position(let next): value = try search(next, alpha, beta, depth: depth + 1)
            }
            if maximising {
                if value > best { best = value }
                if best > alpha { alpha = best }
            } else {
                if value < best { best = value }
                if best < beta { beta = best }
            }
            if alpha >= beta { break }
        }
        let bound: Bound = best <= alphaIn ? .upper : (best >= betaIn ? .lower : .exact)
        memo[p] = Entry(value: best, bound: bound)
        return best
    }

    // MARK: Retrograde analysis, for positions that can repeat

    /// The value of every position reachable from `root`, with endless play a
    /// draw; nil if there are more of them than the budget allows.
    ///
    /// The whole graph is walked first, breadth first so nothing recurses.
    /// Then two attractors are grown backwards from the ends: the positions
    /// from which side 0 can force a win (side 0 to move needs one child in
    /// the set, side 1 to move must have every child in it), and likewise for
    /// side 1. Everything in neither set is a draw — each side can keep the
    /// other from winning, if need be for ever.
    private mutating func retrograde(from root: Position) -> [Position: Int8]? {
        var index: [Position: Int] = [root: 0]
        var positions: [Position] = [root]
        // Each edge: a child's index, or a finished game's value as -2 - v
        // (so -1 → -1, 0 → -2, +1 → -3); never mistaken for an index.
        var edges: [[Int]] = []
        var cursor = 0
        while cursor < positions.count {
            let p = positions[cursor]
            cursor += 1
            var out: [Int] = []
            for move in orderedMoves(p) {
                switch apply(move, to: p) {
                case .end(let v):
                    out.append(-2 - Int(v))
                case .position(let next):
                    if let i = index[next] {
                        out.append(i)
                    } else {
                        nodes += 1
                        if nodes > budget { return nil }
                        index[next] = positions.count
                        out.append(positions.count)
                        positions.append(next)
                    }
                }
            }
            edges.append(out)
        }
        let count = positions.count
        var parents = Array(repeating: [Int](), count: count)
        for (i, out) in edges.enumerated() {
            for e in out where e >= 0 { parents[e].append(i) }
        }

        /// The positions from which `side` can force the game to end `goal`.
        func attractor(side: Int8, goal: Int8) -> [Bool] {
            var inSet = Array(repeating: false, count: count)
            // For positions where the other side moves: how many of their
            // moves still escape the set.
            var escapes = Array(repeating: 0, count: count)
            var queue: [Int] = []
            for i in 0..<count {
                let mover = positions[i].toMove == side
                var reaches = false
                var escaping = 0
                for e in edges[i] {
                    if e >= 0 { escaping += 1 } else if Int8(-2 - e) == goal { reaches = true } else { escaping += 1 }
                }
                escapes[i] = escaping
                if (mover && reaches) || (!mover && escaping == 0) {
                    inSet[i] = true
                    queue.append(i)
                }
            }
            // Children-in-set counts for the other side's positions only count
            // edges to positions, so a finished game that is not `goal` is an
            // escape for ever.
            var head = 0
            while head < queue.count {
                let c = queue[head]
                head += 1
                for parent in parents[c] where !inSet[parent] {
                    if positions[parent].toMove == side {
                        inSet[parent] = true
                        queue.append(parent)
                    } else {
                        escapes[parent] -= 1
                        if escapes[parent] == 0 {
                            inSet[parent] = true
                            queue.append(parent)
                        }
                    }
                }
            }
            return inSet
        }
        let wins = attractor(side: 0, goal: 1)
        let losses = attractor(side: 1, goal: -1)
        var values: [Position: Int8] = [:]
        values.reserveCapacity(count)
        for i in 0..<count {
            values[positions[i]] = wins[i] ? 1 : (losses[i] ? -1 : 0)
        }
        return values
    }

    // MARK: The rules, for two sides

    private func throwable(_ p: Position) -> UInt64 {
        guard p.attacks < p.limit,
              p.unbeaten.nonzeroBitCount < p.hand(p.defender).nonzeroBitCount else { return 0 }
        let ranks = DurakCardSet.rankMask(of: p.table)
        return p.hand(p.attacker) & DurakCardSet.cards(ofRanks: ranks).bits
    }

    private func transferCards(_ p: Position) -> UInt64 {
        guard transfers, p.phase == .defend, p.table == p.unbeaten, p.attacks < p.limit,
              p.hand(p.attacker).nonzeroBitCount >= Int(p.attacks) + 1 else { return 0 }
        let ranks = DurakCardSet.rankMask(of: p.table)
        guard ranks.nonzeroBitCount == 1 else { return 0 }
        return p.hand(p.defender) & DurakCardSet.cards(ofRanks: ranks).bits
    }

    /// Legal moves, likeliest-best first so alpha-beta cuts early: cheap cards
    /// before dear ones, putting cards down before passing or taking.
    func orderedMoves(_ p: Position) -> [Move] {
        var moves: [Move] = []
        moves.reserveCapacity(12)
        switch p.phase {
        case .lead:
            let hand = p.hand(p.attacker)
            for c in cheapestOrder where hand & (1 << UInt64(c)) != 0 { moves.append(.attack(c)) }
        case .defend:
            let hand = p.hand(p.defender)
            // Beats in order of the beating card's cost.
            for b in cheapestOrder where hand & (1 << UInt64(b)) != 0 {
                var u = p.unbeaten
                while u != 0 {
                    let a = u.trailingZeroBitCount
                    u &= u - 1
                    if beaters[a] & (1 << UInt64(b)) != 0 { moves.append(.defend(b, on: a)) }
                }
            }
            let transferable = transferCards(p)
            if transferable != 0 {
                for c in cheapestOrder where transferable & (1 << UInt64(c)) != 0 { moves.append(.transfer(c)) }
            }
            moves.append(.take)
        case .throwIn, .pileOn:
            let cards = throwable(p)
            if cards != 0 {
                for c in cheapestOrder where cards & (1 << UInt64(c)) != 0 { moves.append(.attack(c)) }
            }
            moves.append(.pass)
        }
        return moves
    }

    func apply(_ move: Move, to position: Position) -> Outcome {
        var p = position
        switch (p.phase, move) {
        case (.lead, .attack(let c)):
            let bit = UInt64(1) << UInt64(c)
            p.setHand(p.attacker, p.hand(p.attacker) & ~bit)
            p.table = bit
            p.unbeaten = bit
            p.attacks = 1
            p.phase = .defend
            return .position(p)

        case (.defend, .defend(let c, let a)):
            let bit = UInt64(1) << UInt64(c)
            p.setHand(p.defender, p.hand(p.defender) & ~bit)
            p.table |= bit
            p.unbeaten &= ~(UInt64(1) << UInt64(a))
            return p.unbeaten == 0 ? allBeaten(p) : .position(p)

        case (.defend, .transfer(let c)):
            let bit = UInt64(1) << UInt64(c)
            p.setHand(p.defender, p.hand(p.defender) & ~bit)
            p.table |= bit
            p.unbeaten |= bit
            p.attacks += 1
            p.attacker = p.defender
            p.passed = -1
            return .position(p)

        case (.defend, .take):
            p.phase = .pileOn
            return throwable(p) == 0 ? endBout(p, took: true) : .position(p)

        case (.throwIn, .attack(let c)):
            let bit = UInt64(1) << UInt64(c)
            p.setHand(p.attacker, p.hand(p.attacker) & ~bit)
            p.table |= bit
            p.unbeaten |= bit
            p.attacks += 1
            p.passed = -1
            p.phase = .defend
            return .position(p)

        case (.throwIn, .pass):
            return endBout(p, took: false)

        case (.pileOn, .attack(let c)):
            let bit = UInt64(1) << UInt64(c)
            p.setHand(p.attacker, p.hand(p.attacker) & ~bit)
            p.table |= bit
            p.unbeaten |= bit
            p.attacks += 1
            return throwable(p) == 0 ? endBout(p, took: true) : .position(p)

        case (.pileOn, .pass):
            return endBout(p, took: true)

        default:
            // Not a move of this phase; the search never generates one.
            return .position(p)
        }
    }

    /// Everything is beaten: the attacker is asked to throw in if they have
    /// something they have not already declined, and otherwise it is bito.
    private func allBeaten(_ position: Position) -> Outcome {
        var p = position
        let cards = throwable(p)
        let fresh = p.passed < 0 || DurakCardSet.rankMask(of: cards) & ~UInt16(bitPattern: p.passed) != 0
        if cards != 0 && fresh {
            p.phase = .throwIn
            return .position(p)
        }
        return endBout(p, took: false)
    }

    private func endBout(_ position: Position, took: Bool) -> Outcome {
        var p = position
        if took {
            p.setHand(p.defender, p.hand(p.defender) | p.table)
        }
        let out0 = p.hand0 == 0, out1 = p.hand1 == 0
        if out0 && out1 { return .end(0) }
        if out0 { return .end(1) }
        if out1 { return .end(-1) }
        // Bito: the defender attacks next. A take: the attacker goes again —
        // with two players left, they are the defender's left-hand neighbour.
        if !took { p.attacker = p.defender }
        p.table = 0
        p.unbeaten = 0
        p.attacks = 0
        p.phase = .lead
        p.limit = Int8(DurakRules.maximumAttacks)
        p.passed = -1
        return .position(p)
    }
}
