//
//  SolitairePreferences.swift
//  Solitaire's own settings and its lifetime record, both on disk.
//
//  Only the choices that belong to this game live here — the rules it is
//  played under and how a click behaves. The table, the card backs, the
//  four-colour deck and the sound are shared by every card game in the
//  collection and live in `TablePreferences`; the window's frame belongs to the
//  window. Files written by the solitaire-only app still carry those keys, and
//  the key-by-key decoder below simply never reads them.
//

import AppKit

struct SolitairePreferences: Codable, Equatable {
    var drawCount: Int = 1
    var scoring: ScoringMode = .standard
    var timed: Bool = true
    var winnableDealsOnly: Bool = false
    var clickPrefersFoundation: Bool = true
    var autoPlaySafeCards: Bool = false

    /// `solitaire-preferences.json` — the old `preferences.json`, renamed on
    /// the way across by `Storage.migrateLegacyFiles`.
    static let fileName = Storage.fileName("preferences.json", for: .solitaire)

    init() {}

    /// Decoded key by key, with a default for anything missing.
    ///
    /// The synthesised decoder throws on the first absent key, and `load()`
    /// answers a throw with a fresh `SolitairePreferences` — so adding one
    /// field to this struct would silently reset every rule a player had
    /// chosen. `GameOptions` decodes itself by hand for the same reason. Keys
    /// this struct no longer has — the table colour, Apple mode and the rest
    /// of what an older build wrote — are ignored rather than rejected.
    ///
    /// And a key it cannot read — a scoring mode a later build added, a
    /// number where a flag should be — falls back on its own, like
    /// `TablePreferences`, rather than throwing and taking every other rule
    /// the player chose down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        let draw = value(Int.self, .drawCount, 1)
        drawCount = draw == 3 ? 3 : 1
        scoring = value(ScoringMode.self, .scoring, .standard)
        timed = value(Bool.self, .timed, true)
        winnableDealsOnly = value(Bool.self, .winnableDealsOnly, false)
        clickPrefersFoundation = value(Bool.self, .clickPrefersFoundation, true)
        autoPlaySafeCards = value(Bool.self, .autoPlaySafeCards, false)
    }

    static func load() -> SolitairePreferences {
        Storage.load(SolitairePreferences.self, from: fileName) ?? SolitairePreferences()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    var gameOptions: GameOptions {
        var options = GameOptions()
        options.drawCount = drawCount
        options.scoring = scoring
        options.timed = timed
        options.winnableDealsOnly = winnableDealsOnly
        options.clickPrefersFoundation = clickPrefersFoundation
        options.autoPlaySafeCards = autoPlaySafeCards
        options.redealLimit = GameOptions.defaultRedealLimit(scoring: scoring, drawCount: drawCount)
        return options
    }
}

/// Lifetime record, split by draw mode because a draw-three win is worth a
/// great deal more than a draw-one win and mixing them makes both meaningless.
struct SolitaireStatistics: Codable, Equatable {

    struct Record: Codable, Equatable {
        var played = 0
        var won = 0
        var currentStreak = 0
        var longestStreak = 0
        var fastestWin: TimeInterval?
        var fewestMoves: Int?
        var bestScore: Int?
        var totalTime: TimeInterval = 0

        var winPercentage: Double {
            played == 0 ? 0 : Double(won) / Double(played) * 100
        }
    }

    var drawOne = Record()
    var drawThree = Record()

    static let fileName = Storage.fileName("statistics.json", for: .solitaire)

    static func load() -> SolitaireStatistics {
        Storage.load(SolitaireStatistics.self, from: fileName) ?? SolitaireStatistics()
    }

    func save() { Storage.save(self, to: Self.fileName) }

    subscript(drawCount: Int) -> Record {
        get { drawCount == 1 ? drawOne : drawThree }
        set { if drawCount == 1 { drawOne = newValue } else { drawThree = newValue } }
    }

    /// A game only counts once the player has actually made a move; abandoning
    /// a deal before touching it should not dent the win rate.
    mutating func recordStart(drawCount: Int) {
        self[drawCount].played += 1
    }

    mutating func recordWin(drawCount: Int, time: TimeInterval, moves: Int, score: Int) {
        var record = self[drawCount]
        record.won += 1
        record.currentStreak += 1
        record.longestStreak = max(record.longestStreak, record.currentStreak)
        record.fastestWin = min(record.fastestWin ?? .greatestFiniteMagnitude, time)
        record.fewestMoves = min(record.fewestMoves ?? .max, moves)
        record.bestScore = max(record.bestScore ?? Int.min, score)
        record.totalTime += time
        self[drawCount] = record
    }

    mutating func recordLoss(drawCount: Int, time: TimeInterval) {
        var record = self[drawCount]
        record.currentStreak = 0
        record.totalTime += time
        self[drawCount] = record
    }
}
