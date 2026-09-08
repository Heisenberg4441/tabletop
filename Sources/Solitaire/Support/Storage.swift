//
//  Storage.swift
//  Preferences, statistics and the game in progress, all on disk.
//

import AppKit

enum Storage {

    static let bundleIdentifier = "com.solitaire.klondike"

    /// ~/Library/Application Support/<bundle id>/ — created on first use.
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        // Atomic, so a crash mid-write cannot leave a half-written save that
        // refuses to load next launch.
        try? data.write(to: url, options: .atomic)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

/// Everything the player can choose, persisted as one file rather than a
/// scattering of UserDefaults keys — a bundled app built without Xcode has a
/// bundle identifier that tools sometimes disagree about, and a plain JSON file
/// in Application Support never surprises anyone.
struct Preferences: Codable, Equatable {
    var drawCount: Int = 1
    var scoring: ScoringMode = .standard
    var timed: Bool = true
    var winnableDealsOnly: Bool = false
    var clickPrefersFoundation: Bool = true
    var autoPlaySafeCards: Bool = false
    var soundEnabled: Bool = false
    var table: TableColor = .green
    var backStyle: CardBackStyle = .lattice
    var backColor: CardBackColor = .navy
    var fourColorDeck: Bool = false
    var windowFrame: String?

    static let fileName = "preferences.json"

    static func load() -> Preferences {
        Storage.load(Preferences.self, from: fileName) ?? Preferences()
    }

    func save() {
        Storage.save(self, to: Self.fileName)
    }

    var theme: Theme {
        var theme = Theme()
        theme.table = table
        theme.backStyle = backStyle
        theme.backColor = backColor
        theme.fourColorDeck = fourColorDeck
        return theme
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
struct Statistics: Codable, Equatable {

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

    static let fileName = "statistics.json"

    static func load() -> Statistics {
        Storage.load(Statistics.self, from: fileName) ?? Statistics()
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
