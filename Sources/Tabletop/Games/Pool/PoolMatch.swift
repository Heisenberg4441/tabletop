//
//  PoolMatch.swift
//  One game of pool as data: the choices it was started with, the table,
//  the rules' state, and what is kept on disk between launches.
//
//  No AppKit and no SceneKit: the controller drives it, the scene draws it,
//  and the self-tests can play whole games through it without a window.
//  The engine is authoritative about everything that happens on the cloth;
//  this only remembers it and counts.
//

import Foundation
#if canImport(simd)
import simd
#endif

/// How long the aiming guides reach.
enum PoolGuideLength: String, Codable, CaseIterable, Sendable {
    case long, short, off

    var title: String {
        switch self {
        case .long: return NSLocalizedString("Long", comment: "pool aiming guides: long")
        case .short: return NSLocalizedString("Short", comment: "pool aiming guides: short")
        case .off: return NSLocalizedString("Off", comment: "pool aiming guides: off")
        }
    }

    /// How far the object ball's line runs, in metres.
    var objectLine: Double {
        switch self {
        case .long: return 1.1
        case .short: return 0.28
        case .off: return 0
        }
    }

    /// How far the cue ball's line after contact runs.
    var cueLine: Double {
        switch self {
        case .long: return 0.45
        case .short: return 0.14
        case .off: return 0
        }
    }
}

/// The New Game card's choices, and what the first-time hints have taught.
struct PoolOptions: Codable, Equatable, Sendable {
    var mode: PoolMode = .eightBall
    var difficulty: PoolDifficulty = .medium
    var guides: PoolGuideLength = .long
    /// The player has aimed by dragging across the table: the hint beside
    /// the cue ball is no longer shown.
    var hasAimed = false
    /// The player has taken a shot: the hint beside the meter is no longer
    /// shown.
    var hasShot = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = ((try? c.decodeIfPresent(PoolMode.self, forKey: .mode)) ?? nil) ?? .eightBall
        difficulty = ((try? c.decodeIfPresent(PoolDifficulty.self, forKey: .difficulty)) ?? nil) ?? .medium
        guides = ((try? c.decodeIfPresent(PoolGuideLength.self, forKey: .guides)) ?? nil) ?? .long
        hasAimed = ((try? c.decodeIfPresent(Bool.self, forKey: .hasAimed)) ?? nil) ?? false
        hasShot = ((try? c.decodeIfPresent(Bool.self, forKey: .hasShot)) ?? nil) ?? false
    }

    /// The same game choices with `other`'s hint progress — which belongs
    /// to the player, not to any one game.
    func keepingHints(of other: PoolOptions) -> PoolOptions {
        var o = self
        o.hasAimed = other.hasAimed || hasAimed
        o.hasShot = other.hasShot || hasShot
        return o
    }
}

/// Player 0 is always the person at the Mac; player 1 is the computer.
enum PoolSeat {
    static let you = 0
    static let computer = 1
}

struct PoolMatch: Sendable {
    var options: PoolOptions
    var rules: PoolRuleState
    var table: PoolTableState
    /// Seeds the rack and every decision the computer makes in this game,
    /// so a game replays the same way from the same start.
    var seed: UInt64
    /// Who broke this game; the next rack is broken by the other player.
    var breaker: Int
    var opponentName: String
    /// Balls the player has pocketed in the current visit to the table, for
    /// the best-run statistic.
    var currentRun = 0
    /// Balls each player has pocketed this game.
    var pocketedBy: [[Int]] = [[], []]

    static func start(_ options: PoolOptions, seed: UInt64, breaker: Int, opponentName: String) -> PoolMatch {
        let table: PoolTableState
        switch options.mode {
        case .eightBall: table = PoolRack.eightBall(seed: seed)
        case .nineBall: table = PoolRack.nineBall(seed: seed)
        case .practice: table = PoolRack.practice(seed: seed)
        }
        let breaker = options.mode == .practice ? PoolSeat.you : breaker
        return PoolMatch(options: options, rules: PoolRules.newGame(options.mode, breaker: breaker),
                         table: table, seed: seed, breaker: breaker, opponentName: opponentName)
    }

    var isOver: Bool { rules.winner != nil }
    var isPractice: Bool { options.mode == .practice }
    var shooterIsComputer: Bool { !isPractice && rules.shooter == PoolSeat.computer }

    /// The seed for the computer's next decision: fixed by the game and the
    /// shot, so the same position always gets the same answer.
    var decisionSeed: UInt64 {
        seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(rules.shotCount) &* 0xBF58_476D_1CE4_E5B9 &+ 0x5EED
    }

    /// Object balls still on the cloth.
    var ballsOnTable: [Int] {
        table.balls.filter { $0.number != 0 && $0.pocket == nil }.map(\.number).sorted()
    }

    /// The balls a player still has to pocket before the eight (eight-ball),
    /// in order — or, once they are all down, just the eight. Nil while the
    /// table is open or in the other games.
    func ballsNeeded(by player: Int) -> [Int]? {
        guard options.mode == .eightBall, let group = rules.groups[safe: player] ?? nil else { return nil }
        let left = PoolEngineText.numbers(in: group).filter { n in table.ball(n).map { $0.pocket == nil } ?? false }
        return left.isEmpty ? [8] : left
    }

    /// The lowest ball on the table (nine-ball's ball "on").
    var lowestBall: Int? { ballsOnTable.first }

    // MARK: After a shot

    /// What the controller needs to tell the player about a finished shot.
    struct Summary {
        var shooter: Int
        var pocketed: [Int]
        var foul: PoolFoul?
        var groupAssigned: PoolGroup?
        var continues: Bool
        var gameOver: (winner: Int, reason: PoolGameOverReason)?
        var remarks: [String]
        /// A run the player just ended, if it beat nothing yet — the caller
        /// compares it with the record.
        var finishedRun: Int?
    }

    /// Takes the engine's verdict on a shot into the game.
    mutating func apply(_ outcome: PoolTurnOutcome, result: PoolShotResult) -> Summary {
        let shooter = rules.shooter
        let pocketed = result.pocketed.map(\.ball).filter { $0 != 0 }
        // What counts for the shooter is what the rules credited — not a ball
        // of the opponent's that happened to drop, nor one re-spotted after a
        // foul — plus the winning eight or nine, which the rules report as
        // the game's end rather than as a credit.
        var counted = outcome.credited
        if let over = outcome.gameOver, over.winner == shooter {
            for n in [8, 9] where pocketed.contains(n) && !counted.contains(n) { counted.append(n) }
        }
        if !isPractice, pocketedBy.indices.contains(shooter) {
            pocketedBy[shooter].append(contentsOf: counted)
        }
        var finishedRun: Int?
        if shooter == PoolSeat.you && options.mode == .eightBall {
            if outcome.foul == nil { currentRun += counted.count }
            if !outcome.continuesTurn || outcome.gameOver != nil {
                finishedRun = currentRun
                currentRun = 0
            }
        }
        rules = outcome.newState
        table = outcome.table
        return Summary(shooter: shooter, pocketed: pocketed, foul: outcome.foul,
                       groupAssigned: outcome.groupAssigned, continues: outcome.continuesTurn,
                       gameOver: outcome.gameOver,
                       remarks: outcome.messages.compactMap(PoolEngineText.remark),
                       finishedRun: finishedRun)
    }
}

// MARK: - On disk

/// `pool-game.json`: the game in progress, at rest between shots.
struct PoolSavedGame: Codable {
    var options: PoolOptions
    var rules: PoolRuleState
    var table: PoolTableState
    var seed: UInt64
    var breaker: Int
    var opponentName: String
    var currentRun: Int
    var pocketedBy: [[Int]]
    var aim: Double

    init(_ match: PoolMatch, aim: Double) {
        options = match.options
        rules = match.rules
        table = match.table
        seed = match.seed
        breaker = match.breaker
        opponentName = match.opponentName
        currentRun = match.currentRun
        pocketedBy = match.pocketedBy
        self.aim = aim
    }

    /// Key by key: a missing or unreadable detail falls back to a default,
    /// but a table or a rule state that cannot be read makes the whole save
    /// unreadable — a game cannot be resumed without them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        rules = try c.decode(PoolRuleState.self, forKey: .rules)
        table = try c.decode(PoolTableState.self, forKey: .table)
        options = value(PoolOptions.self, .options, PoolOptions())
        seed = value(UInt64.self, .seed, 1)
        breaker = value(Int.self, .breaker, PoolSeat.you)
        opponentName = value(String.self, .opponentName, BotRosterFallback.name)
        currentRun = value(Int.self, .currentRun, 0)
        pocketedBy = value([[Int]].self, .pocketedBy, [[], []])
        if pocketedBy.count != 2 { pocketedBy = [[], []] }
        aim = value(Double.self, .aim, 0)
    }

    var match: PoolMatch {
        PoolMatch(options: options, rules: rules, table: table, seed: seed, breaker: breaker,
                  opponentName: opponentName, currentRun: currentRun, pocketedBy: pocketedBy)
    }

    /// A save worth resuming: sixteen or ten balls, each on the table or in
    /// a pocket, and a game that is not over.
    var isPlausible: Bool {
        let numbers = Set(table.balls.map(\.number))
        let expected = options.mode == .nineBall ? Set(0...9) : Set(0...15)
        return numbers == expected && rules.winner == nil && table.balls.allSatisfy { ball in
            ball.pocket != nil || (ball.position.x.isFinite && ball.position.y.isFinite
                                   && abs(ball.position.x) < 1.5 && abs(ball.position.y) < 0.8)
        }
    }
}

/// The opponent's name when a save lost it.
enum BotRosterFallback {
    static var name: String { NSLocalizedString("Anna", comment: "computer player's name") }
}

#if os(macOS)
/// `pool-stats.json`: games and wins against the computer at each
/// difficulty, and the longest eight-ball run.
struct PoolStatistics: Codable, Equatable {
    var played: [String: Int] = [:]
    var won: [String: Int] = [:]
    var bestRun = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        played = ((try? c.decodeIfPresent([String: Int].self, forKey: .played)) ?? nil) ?? [:]
        won = ((try? c.decodeIfPresent([String: Int].self, forKey: .won)) ?? nil) ?? [:]
        bestRun = ((try? c.decodeIfPresent(Int.self, forKey: .bestRun)) ?? nil) ?? 0
    }

    mutating func record(win: Bool, difficulty: PoolDifficulty) {
        played[difficulty.rawValue, default: 0] += 1
        if win { won[difficulty.rawValue, default: 0] += 1 }
    }

    func games(_ difficulty: PoolDifficulty) -> Int { played[difficulty.rawValue] ?? 0 }
    func wins(_ difficulty: PoolDifficulty) -> Int { won[difficulty.rawValue] ?? 0 }

    static let fileName = Storage.fileName("stats.json", for: .pool)

    static func load() -> PoolStatistics {
        Storage.load(PoolStatistics.self, from: fileName) ?? PoolStatistics()
    }

    func save() { Storage.save(self, to: Self.fileName) }
}
#endif
