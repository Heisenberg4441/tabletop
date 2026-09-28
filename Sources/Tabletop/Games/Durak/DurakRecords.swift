//
//  DurakRecords.swift
//  What durak keeps on disk: the New Game choices, the player's record, and
//  the session at the table — who the opponents are, how often each has been
//  the durak tonight, and the game in progress.
//
//      durak-settings.json   opponents, variant, difficulty, hand order
//      durak-stats.json      the player's record, per variant
//      durak-game.json       the session: names, scoreboard, the game itself
//
//  Every file is decoded key by key with a fallback for each, so a file from
//  an older build — or one with a damaged corner — loses only what is
//  actually unreadable. The game in progress is the one exception that is
//  all or nothing: `DurakState` checks every card on the way in, and a
//  position that does not add up is dropped rather than played.
//

import Foundation

// MARK: - Settings

/// The New Game card's choices, and how the player likes their hand sorted.
struct DurakSettings: Codable, Equatable {
    /// 1...3 computer players.
    var opponents = 2
    var variant = DurakVariant.podkidnoy
    var difficulty = DurakDifficulty.normal
    var handOrder = DurakHandOrder.bySuit

    static let fileName = Storage.fileName("settings.json", for: .durak)

    var playerCount: Int { opponents + 1 }

    init() {}

    private enum CodingKeys: String, CodingKey { case opponents, variant, difficulty, handOrder }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = DurakSettings()
        let opponents = ((try? c.decodeIfPresent(Int.self, forKey: .opponents)) ?? nil) ?? defaults.opponents
        self.opponents = min(max(opponents, 1), 3)
        variant = ((try? c.decodeIfPresent(DurakVariant.self, forKey: .variant)) ?? nil) ?? defaults.variant
        difficulty = ((try? c.decodeIfPresent(DurakDifficulty.self, forKey: .difficulty)) ?? nil) ?? defaults.difficulty
        handOrder = ((try? c.decodeIfPresent(DurakHandOrder.self, forKey: .handOrder)) ?? nil) ?? defaults.handOrder
    }

    static func load() -> DurakSettings {
        Storage.load(DurakSettings.self, from: fileName) ?? DurakSettings()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }
}

// MARK: - Statistics

/// How one game ended for the player.
enum DurakOutcome: Equatable {
    /// Left holding cards.
    case durak
    /// The last two ran out together.
    case draw
    /// Got rid of every card while someone else was still playing; `first`
    /// when nobody went out before them.
    case escaped(first: Bool)
}

/// The player's record, kept separately for each variant — transfers make
/// perevodnoy a different game to be good at.
struct DurakStatistics: Codable, Equatable {

    struct Record: Codable, Equatable {
        var played = 0
        /// Not the durak (a draw is counted on its own).
        var escaped = 0
        /// Out before anybody else.
        var firstOut = 0
        var durak = 0
        var draws = 0

        init() {}

        private enum CodingKeys: String, CodingKey { case played, escaped, firstOut, durak, draws }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func value(_ key: CodingKeys) -> Int { max(0, ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0) }
            played = value(.played)
            escaped = value(.escaped)
            firstOut = value(.firstOut)
            durak = value(.durak)
            draws = value(.draws)
        }

        mutating func record(_ outcome: DurakOutcome) {
            played += 1
            switch outcome {
            case .durak: durak += 1
            case .draw: draws += 1
            case .escaped(let first):
                escaped += 1
                if first { firstOut += 1 }
            }
        }
    }

    var podkidnoy = Record()
    var perevodnoy = Record()

    static let fileName = Storage.fileName("stats.json", for: .durak)

    init() {}

    private enum CodingKeys: String, CodingKey { case podkidnoy, perevodnoy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        podkidnoy = ((try? c.decodeIfPresent(Record.self, forKey: .podkidnoy)) ?? nil) ?? Record()
        perevodnoy = ((try? c.decodeIfPresent(Record.self, forKey: .perevodnoy)) ?? nil) ?? Record()
    }

    subscript(variant: DurakVariant) -> Record {
        get { variant == .podkidnoy ? podkidnoy : perevodnoy }
        set { if variant == .podkidnoy { podkidnoy = newValue } else { perevodnoy = newValue } }
    }

    static func load() -> DurakStatistics {
        Storage.load(DurakStatistics.self, from: fileName) ?? DurakStatistics()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }
}

// MARK: - The session

/// Tonight's tally: how many games, and how often each seat was the durak.
struct DurakScoreboard: Codable, Equatable {
    var games = 0
    var draws = 0
    /// Per seat, seat 0 the player.
    var durakCounts: [Int]

    init(playerCount: Int) {
        durakCounts = Array(repeating: 0, count: playerCount)
    }

    private enum CodingKeys: String, CodingKey { case games, draws, durakCounts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        games = max(0, ((try? c.decodeIfPresent(Int.self, forKey: .games)) ?? nil) ?? 0)
        draws = max(0, ((try? c.decodeIfPresent(Int.self, forKey: .draws)) ?? nil) ?? 0)
        durakCounts = (((try? c.decodeIfPresent([Int].self, forKey: .durakCounts)) ?? nil) ?? []).map { max(0, $0) }
    }

    mutating func record(_ result: DurakResult) {
        games += 1
        switch result {
        case .draw: draws += 1
        case .durak(let seat):
            if durakCounts.indices.contains(seat) { durakCounts[seat] += 1 }
        }
    }
}

/// Everything about the table that outlives one game: the same opponents
/// play on from game to game — the durak of the last one defends first in
/// the next («под дурака») — until the player picks a different number of
/// them.
struct DurakSession: Codable {
    /// Seat 1 onwards; seat 0 is always the player.
    var names: [String]
    var scoreboard: DurakScoreboard
    /// How the last finished game ended, for the next one's opening.
    var lastResult: DurakResult?
    /// The game on the table, finished or not. Nil before the first deal.
    var state: DurakState?
    /// Whether `state`'s ending is already in the statistics and the
    /// scoreboard — so a finished game restored after a relaunch is not
    /// counted twice.
    var resultRecorded = false
    /// For the discard pile's jitter, so a relaunch lays it out the same.
    var pileSeed: UInt64 = 1

    static let fileName = Storage.fileName("game.json", for: .durak)

    var playerCount: Int { names.count + 1 }

    init(names: [String]) {
        self.names = names
        scoreboard = DurakScoreboard(playerCount: names.count + 1)
    }

    private enum CodingKeys: String, CodingKey { case names, scoreboard, lastResult, state, resultRecorded, pileSeed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        names = try c.decode([String].self, forKey: .names)
        guard (1...3).contains(names.count) else {
            throw DecodingError.dataCorruptedError(forKey: .names, in: c, debugDescription: "1 to 3 opponents")
        }
        let n = names.count + 1
        var board = ((try? c.decodeIfPresent(DurakScoreboard.self, forKey: .scoreboard)) ?? nil) ?? DurakScoreboard(playerCount: n)
        if board.durakCounts.count != n { board = DurakScoreboard(playerCount: n) }
        scoreboard = board
        lastResult = (try? c.decodeIfPresent(DurakResult.self, forKey: .lastResult)) ?? nil
        if case .durak(let seat)? = lastResult, !(0..<n).contains(seat) { lastResult = nil }
        // A damaged or inconsistent game is dropped on its own; the session
        // around it — the names, the tally — survives.
        let state = (try? c.decodeIfPresent(DurakState.self, forKey: .state)) ?? nil
        self.state = state?.playerCount == n ? state : nil
        resultRecorded = ((try? c.decodeIfPresent(Bool.self, forKey: .resultRecorded)) ?? nil) ?? false
        pileSeed = ((try? c.decodeIfPresent(UInt64.self, forKey: .pileSeed)) ?? nil) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(names, forKey: .names)
        try c.encode(scoreboard, forKey: .scoreboard)
        try c.encodeIfPresent(lastResult, forKey: .lastResult)
        try c.encodeIfPresent(state, forKey: .state)
        try c.encode(resultRecorded, forKey: .resultRecorded)
        try c.encode(pileSeed, forKey: .pileSeed)
    }

    static func load() -> DurakSession? {
        Storage.load(DurakSession.self, from: fileName)
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    /// Opponents' names for a new table: from the kit's roster, the same
    /// names for the same seed.
    static func pickNames(_ count: Int, seed: UInt64) -> [String] {
        BotRoster.pick(count, seed: seed)
    }
}

extension DurakResult {
    /// The player's side of it.
    func outcome(for seat: Int, outOrder: [Int]) -> DurakOutcome {
        switch self {
        case .draw:
            // The draw is between the two who ran out together at the end;
            // anyone who went out before them simply escaped.
            let together = outOrder.suffix(2)
            return together.contains(seat) || !outOrder.contains(seat) ? .draw : .escaped(first: outOrder.first == seat)
        case .durak(let loser):
            return loser == seat ? .durak : .escaped(first: outOrder.first == seat)
        }
    }
}
