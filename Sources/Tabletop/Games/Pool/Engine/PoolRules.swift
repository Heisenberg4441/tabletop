//
//  PoolRules.swift
//  Eight-ball, nine-ball and practice as pure functions: the rule state and
//  a shot's result in, the next rule state and what to tell the player out.
//
//  The rules are the WPA world standardised rules with the simplifications a
//  single-player game against the computer wants:
//
//  * No called pockets: any legally pocketed ball counts, the 8 included.
//  * Every foul gives the opponent ball in hand anywhere, except a scratch
//    on the eight-ball break, which gives it behind the head string.
//  * Eight-ball: the 8 pocketed on the break is re-spotted and the break
//    stands; the table is open after the break and the first ball legally
//    pocketed decides the groups; on an open table the 8 may not be struck
//    first; the 8 pocketed before the group is cleared, or on a foul, loses.
//  * Nine-ball: the lowest ball on the table first; any ball legally
//    pocketed continues; the 9 legally pocketed wins, on the break or in a
//    combination; the 9 pocketed on a foul is re-spotted. No push-out, and
//    no three-foul rule.
//  * Neither game enforces the break's four-balls-to-a-rail rule, nor the
//    rule against shooting from the kitchen at a ball behind the head string.
//  * Practice has no fouls; a scratched cue ball comes back to the head spot.
//
//  The engine never words anything: the outcome carries `PoolRuleMessage`
//  values and the game localises them.
//

import Foundation
#if canImport(simd)
import simd
#endif

enum PoolBallInHand: String, Codable, Sendable {
    /// Behind the head string (the break, and a scratch on the break).
    case kitchen
    /// Anywhere on the cloth.
    case anywhere
}

enum PoolFoul: String, Codable, Sendable, CaseIterable {
    /// The cue ball went into a pocket.
    case scratch
    /// The cue ball touched no ball at all.
    case noContact
    /// The first ball touched was not one the shooter was allowed to hit.
    case wrongBallFirst
    /// Nothing was pocketed and no ball reached a cushion after the contact.
    case noRail
}

enum PoolGameOverReason: String, Codable, Sendable {
    /// The shooter pocketed the 8 legally after clearing their group: won.
    case eightBallPotted
    /// The shooter pocketed the 8 before clearing their group: lost.
    case eightBallEarly
    /// The shooter pocketed the 8 on a foul: lost.
    case eightBallOnFoul
    /// The shooter pocketed the 9 legally: won.
    case nineBallPotted
}

/// What the game should tell the player about a shot, in order.
enum PoolRuleMessage: Sendable, Equatable {
    case foul(PoolFoul, player: Int)
    case ballInHand(player: Int, PoolBallInHand)
    case groupAssigned(player: Int, PoolGroup)
    case tableOpen
    case eightBallRespotted
    case nineBallRespotted
    case cueBallRespotted
    case continues(player: Int, potted: Int)
    case turnPasses(to: Int)
    case gameOver(winner: Int, reason: PoolGameOverReason)
    case tableCleared
}

struct PoolRuleState: Codable, Sendable, Equatable {
    var mode: PoolMode
    /// Whose shot it is: 0 is the player, 1 the computer (practice: always 0).
    var shooter: Int
    /// Each player's group in eight-ball, nil while the table is open.
    var groups: [PoolGroup?]
    var isBreakShot: Bool
    /// The shooter may place the cue ball before this shot.
    var ballInHand: PoolBallInHand?
    var winner: Int?
    var gameOverReason: PoolGameOverReason?
    /// The foul committed on the previous shot, if any.
    var lastFoul: PoolFoul?
    /// Shots played this game.
    var shotCount: Int
    var breaker: Int
    /// Balls the shooter has pocketed in the current visit, and each
    /// player's best visit this game.
    var run: Int
    var bestRun: [Int]
    /// Fouls each player has committed this game.
    var fouls: [Int]

    init(mode: PoolMode, breaker: Int) {
        self.mode = mode
        let first = mode == .practice ? 0 : min(max(breaker, 0), 1)
        shooter = first
        self.breaker = first
        groups = [nil, nil]
        isBreakShot = true
        ballInHand = .kitchen
        winner = nil
        gameOverReason = nil
        lastFoul = nil
        shotCount = 0
        run = 0
        bestRun = [0, 0]
        fouls = [0, 0]
    }

    var opponent: Int { 1 - shooter }
    var isOver: Bool { winner != nil }
    /// Eight-ball after the break, before anyone has a group.
    var isOpenTable: Bool { mode == .eightBall && !isBreakShot && groups[0] == nil && groups[1] == nil }

    func group(of player: Int) -> PoolGroup? {
        groups.indices.contains(player) ? groups[player] : nil
    }

    private enum CodingKeys: String, CodingKey {
        case mode, shooter, groups, isBreakShot, ballInHand, winner, gameOverReason, lastFoul, shotCount
        case breaker, run, bestRun, fouls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = ((try? c.decodeIfPresent(PoolMode.self, forKey: .mode)) ?? nil) ?? .eightBall
        let breaker = ((try? c.decodeIfPresent(Int.self, forKey: .breaker)) ?? nil) ?? 0
        self.init(mode: mode, breaker: breaker)
        shooter = min(max(((try? c.decodeIfPresent(Int.self, forKey: .shooter)) ?? nil) ?? shooter, 0), 1)
        if mode == .practice { shooter = 0 }
        let g = ((try? c.decodeIfPresent([PoolGroup?].self, forKey: .groups)) ?? nil) ?? [nil, nil]
        groups = g.count == 2 ? g : [nil, nil]
        isBreakShot = ((try? c.decodeIfPresent(Bool.self, forKey: .isBreakShot)) ?? nil) ?? true
        ballInHand = (try? c.decodeIfPresent(PoolBallInHand.self, forKey: .ballInHand)) ?? nil
        winner = (try? c.decodeIfPresent(Int.self, forKey: .winner)) ?? nil
        gameOverReason = (try? c.decodeIfPresent(PoolGameOverReason.self, forKey: .gameOverReason)) ?? nil
        lastFoul = (try? c.decodeIfPresent(PoolFoul.self, forKey: .lastFoul)) ?? nil
        shotCount = max(((try? c.decodeIfPresent(Int.self, forKey: .shotCount)) ?? nil) ?? 0, 0)
        run = max(((try? c.decodeIfPresent(Int.self, forKey: .run)) ?? nil) ?? 0, 0)
        let best = ((try? c.decodeIfPresent([Int].self, forKey: .bestRun)) ?? nil) ?? [0, 0]
        bestRun = best.count == 2 ? best : [0, 0]
        let f = ((try? c.decodeIfPresent([Int].self, forKey: .fouls)) ?? nil) ?? [0, 0]
        fouls = f.count == 2 ? f : [0, 0]
    }
}

struct PoolTurnOutcome: Sendable {
    let newState: PoolRuleState
    /// The table to play on next: re-spotted balls back on the cloth and,
    /// with ball in hand, the cue ball at a legal default spot.
    let table: PoolTableState
    let foul: PoolFoul?
    /// The same player shoots again.
    let continuesTurn: Bool
    /// The group the shooter was given by this shot.
    let groupAssigned: PoolGroup?
    let gameOver: (winner: Int, reason: PoolGameOverReason)?
    let messages: [PoolRuleMessage]
    /// Object balls pocketed on this shot that count for the shooter.
    let credited: [Int]
}

enum PoolRules {

    static func newGame(_ mode: PoolMode, breaker: Int) -> PoolRuleState {
        PoolRuleState(mode: mode, breaker: breaker)
    }

    /// The balls the shooter may strike first.
    static func legalFirstContacts(_ s: PoolRuleState, table: PoolTableState) -> Set<Int> {
        let onTable = table.objectBallsOnTable
        switch s.mode {
        case .practice:
            return Set(onTable)
        case .nineBall:
            return onTable.min().map { [$0] } ?? []
        case .eightBall:
            if s.isBreakShot { return Set(onTable) }
            if let group = s.group(of: s.shooter) {
                let mine = onTable.filter { group.contains($0) }
                return mine.isEmpty ? (onTable.contains(8) ? [8] : []) : Set(mine)
            }
            let open = onTable.filter { $0 != 8 }
            return open.isEmpty ? (onTable.contains(8) ? [8] : []) : Set(open)
        }
    }

    /// Whether the cue ball may be put down at `p`: only with ball in hand,
    /// wholly on the cloth (behind the head string for a kitchen ball in
    /// hand) and touching no other ball.
    static func isValidPlacement(_ p: SIMD2<Double>, _ s: PoolRuleState, table: PoolTableState,
                                 geometry g: PoolTableGeometry = .standard) -> Bool {
        guard let hand = s.ballInHand, p.x.isFinite, p.y.isFinite else { return false }
        switch hand {
        case .kitchen: guard g.kitchenContains(p) else { return false }
        case .anywhere: guard g.fitsOnCloth(p) else { return false }
        }
        let clearance = 2 * g.ballRadius + 1e-6
        return table.balls.allSatisfy { b in
            b.number == 0 || b.pocket != nil || simd_distance_squared(b.position, p) >= clearance * clearance
        }
    }

    static func evaluate(_ r: PoolShotResult, before: PoolTableState, state: PoolRuleState) -> PoolTurnOutcome {
        evaluate(r, before: before, state: state, geometry: .standard)
    }

    static func evaluate(_ r: PoolShotResult, before: PoolTableState, state s: PoolRuleState,
                         geometry g: PoolTableGeometry) -> PoolTurnOutcome {
        switch s.mode {
        case .practice: return practice(r, state: s, geometry: g)
        case .nineBall: return nineBall(r, before: before, state: s, geometry: g)
        case .eightBall: return eightBall(r, before: before, state: s, geometry: g)
        }
    }

    // MARK: Fouls

    /// The foul a shot commits, if any, worst first.
    static func foul(of r: PoolShotResult, legal: Set<Int>, isBreak: Bool) -> PoolFoul? {
        if r.scratched { return .scratch }
        guard let first = r.firstContact else { return .noContact }
        if !legal.contains(first) { return .wrongBallFirst }
        let potted = r.pocketed.contains { $0.ball != 0 }
        if !isBreak && !potted && !r.railAfterFirstContact { return .noRail }
        return nil
    }

    // MARK: Eight-ball

    private static func eightBall(_ r: PoolShotResult, before: PoolTableState, state s: PoolRuleState,
                                  geometry g: PoolTableGeometry) -> PoolTurnOutcome {
        var next = s
        var table = r.final
        var messages: [PoolRuleMessage] = []
        let shooter = s.shooter
        let legal = legalFirstContacts(s, table: before)
        let potted = r.pocketed.map(\.ball).filter { $0 != 0 }
        let foul = foul(of: r, legal: legal, isBreak: s.isBreakShot)
        let eight = potted.contains(8)
        var gameOver: (winner: Int, reason: PoolGameOverReason)?
        var assigned: PoolGroup?
        var continues = false
        var credited: [Int] = []

        if s.isBreakShot {
            if eight {
                respot(8, on: &table, geometry: g)
                messages.append(.eightBallRespotted)
            }
            // The 8 is back on the cloth: it keeps the break alive but is
            // nobody's ball, and must not count in a run.
            credited = potted.filter { $0 != 8 }
            continues = foul == nil && !potted.isEmpty
            next.isBreakShot = false
            messages.append(.tableOpen)
        } else if eight {
            let group = s.group(of: shooter)
            let cleared = group.map { gr in !before.objectBallsOnTable.contains { gr.contains($0) } } ?? false
            if foul == nil && cleared {
                gameOver = (shooter, .eightBallPotted)
            } else {
                gameOver = (1 - shooter, foul == nil ? .eightBallEarly : .eightBallOnFoul)
            }
        } else if foul == nil {
            if let group = s.group(of: shooter) {
                credited = potted.filter { group.contains($0) }
                continues = !credited.isEmpty
            } else if let firstBall = potted.first(where: { $0 != 8 }), let group = PoolGroup.of(firstBall) {
                // The open table closes on the first ball legally pocketed.
                assigned = group
                next.groups[shooter] = group
                next.groups[1 - shooter] = group.opposite
                messages.append(.groupAssigned(player: shooter, group))
                credited = potted.filter { group.contains($0) }
                continues = true
            }
        }
        return finish(r: r, state: s, next: next, table: table, foul: foul, continues: continues,
                      assigned: assigned, gameOver: gameOver, credited: credited, messages: messages,
                      kitchenOnScratch: s.isBreakShot, geometry: g)
    }

    // MARK: Nine-ball

    private static func nineBall(_ r: PoolShotResult, before: PoolTableState, state s: PoolRuleState,
                                 geometry g: PoolTableGeometry) -> PoolTurnOutcome {
        var next = s
        var table = r.final
        var messages: [PoolRuleMessage] = []
        let legal = legalFirstContacts(s, table: before)
        let potted = r.pocketed.map(\.ball).filter { $0 != 0 }
        let foul = foul(of: r, legal: legal, isBreak: s.isBreakShot)
        var gameOver: (winner: Int, reason: PoolGameOverReason)?
        if potted.contains(9) {
            if foul == nil {
                gameOver = (s.shooter, .nineBallPotted)
            } else {
                respot(9, on: &table, geometry: g)
                messages.append(.nineBallRespotted)
            }
        }
        next.isBreakShot = false
        let credited = foul == nil ? potted : []
        return finish(r: r, state: s, next: next, table: table, foul: foul, continues: foul == nil && !potted.isEmpty,
                      assigned: nil, gameOver: gameOver, credited: credited, messages: messages,
                      kitchenOnScratch: false, geometry: g)
    }

    // MARK: Practice

    private static func practice(_ r: PoolShotResult, state s: PoolRuleState, geometry g: PoolTableGeometry)
        -> PoolTurnOutcome {
        var next = s
        var table = r.final
        var messages: [PoolRuleMessage] = []
        next.isBreakShot = false
        next.shotCount += 1
        next.shooter = 0
        next.lastFoul = nil
        let potted = r.pocketed.map(\.ball).filter { $0 != 0 }
        next.run = s.run + potted.count
        next.bestRun[0] = max(next.bestRun[0], next.run)
        if r.scratched {
            placeCueBall(on: &table, preferring: g.headSpot, kitchen: false, geometry: g)
            next.ballInHand = .anywhere
            messages.append(.cueBallRespotted)
        } else {
            next.ballInHand = nil
        }
        if table.objectBallsOnTable.isEmpty { messages.append(.tableCleared) }
        return PoolTurnOutcome(newState: next, table: table, foul: nil, continuesTurn: true, groupAssigned: nil,
                               gameOver: nil, messages: messages, credited: potted)
    }

    // MARK: Shared

    private static func finish(r: PoolShotResult, state s: PoolRuleState, next start: PoolRuleState,
                               table start2: PoolTableState, foul: PoolFoul?, continues: Bool,
                               assigned: PoolGroup?, gameOver: (winner: Int, reason: PoolGameOverReason)?,
                               credited: [Int], messages start3: [PoolRuleMessage], kitchenOnScratch: Bool,
                               geometry g: PoolTableGeometry) -> PoolTurnOutcome {
        var next = start
        var table = start2
        var messages = start3
        let shooter = s.shooter
        next.shotCount = s.shotCount + 1
        next.lastFoul = foul
        next.isBreakShot = false
        next.ballInHand = nil
        if let foul {
            next.fouls[shooter] += 1
            messages.insert(.foul(foul, player: shooter), at: 0)
        }
        if let gameOver {
            next.winner = gameOver.winner
            next.gameOverReason = gameOver.reason
            next.run = s.run + credited.count
            next.bestRun[shooter] = max(next.bestRun[shooter], next.run)
            messages.append(.gameOver(winner: gameOver.winner, reason: gameOver.reason))
            if r.scratched {
                placeCueBall(on: &table, preferring: g.headSpot, kitchen: false, geometry: g)
            }
            return PoolTurnOutcome(newState: next, table: table, foul: foul, continuesTurn: false,
                                   groupAssigned: assigned, gameOver: gameOver, messages: messages, credited: credited)
        }
        if continues {
            next.shooter = shooter
            next.run = s.run + credited.count
            next.bestRun[shooter] = max(next.bestRun[shooter], next.run)
            messages.append(.continues(player: shooter, potted: credited.count))
        } else {
            next.shooter = 1 - shooter
            next.run = 0
            messages.append(.turnPasses(to: 1 - shooter))
        }
        if foul != nil {
            let hand: PoolBallInHand = (foul == .scratch && kitchenOnScratch) ? .kitchen : .anywhere
            next.ballInHand = hand
            if r.scratched || hand == .kitchen {
                placeCueBall(on: &table, preferring: hand == .kitchen ? PoolRack.breakCueSpot(g) : g.headSpot,
                             kitchen: hand == .kitchen, geometry: g)
            }
            messages.append(.ballInHand(player: next.shooter, hand))
        }
        return PoolTurnOutcome(newState: next, table: table, foul: foul, continuesTurn: continues,
                               groupAssigned: assigned, gameOver: nil, messages: messages, credited: credited)
    }

    /// Puts a pocketed ball back on the foot spot, or — when that is taken —
    /// on the nearest free point of the long axis behind it (toward the foot
    /// rail), else in front of it.
    static func respot(_ number: Int, on table: inout PoolTableState, geometry g: PoolTableGeometry) {
        guard var ball = table.ball(number) else { return }
        let r = g.ballRadius
        let others = table.balls.filter { $0.number != number && $0.pocket == nil }
        func free(_ p: SIMD2<Double>) -> Bool {
            g.fitsOnCloth(p) && others.allSatisfy { simd_distance($0.position, p) >= 2 * r + 1e-6 }
        }
        var spot = g.footSpot
        if !free(spot) {
            var found: SIMD2<Double>?
            var x = g.footSpot.x
            while x <= g.length / 2 - r {
                let p = SIMD2(x, 0.0)
                if free(p) { found = p; break }
                x += 0.001
            }
            if found == nil {
                x = g.footSpot.x
                while x >= -g.length / 2 + r {
                    let p = SIMD2(x, 0.0)
                    if free(p) { found = p; break }
                    x -= 0.001
                }
            }
            spot = found ?? g.footSpot
        }
        ball.position = spot
        ball.pocket = nil
        ball.velocity = .zero
        ball.spin = .zero
        table.update(ball)
    }

    /// Brings the cue ball back to the cloth at `preferring`, or the nearest
    /// free point to it (in the kitchen when asked).
    static func placeCueBall(on table: inout PoolTableState, preferring target: SIMD2<Double>, kitchen: Bool,
                             geometry g: PoolTableGeometry) {
        var cue = table.cueBall ?? PoolBall(number: 0, position: target)
        let r = g.ballRadius
        let others = table.balls.filter { $0.number != 0 && $0.pocket == nil }
        func free(_ p: SIMD2<Double>) -> Bool {
            (kitchen ? g.kitchenContains(p) : g.fitsOnCloth(p))
                && others.allSatisfy { simd_distance($0.position, p) >= 2 * r + 1e-6 }
        }
        var spot = target
        if !free(spot) {
            // Rings outward from the target until something is free.
            search: for ring in 1...200 {
                let radius = Double(ring) * r * 0.5
                let steps = max(8, ring * 6)
                for k in 0..<steps {
                    let a = Double(k) / Double(steps) * 2 * .pi
                    let p = target + SIMD2(cos(a), sin(a)) * radius
                    if free(p) { spot = p; break search }
                }
            }
        }
        cue.position = spot
        cue.pocket = nil
        cue.velocity = .zero
        cue.spin = .zero
        table.cueBall = cue
    }
}
