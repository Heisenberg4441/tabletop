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
    /// Apple mode: the skeuomorphic table. Off by default because the flat
    /// board is the one that stays out of the way, and this one is a choice
    /// about taste rather than a better default.
    var apple: Bool = false
    /// Fireballs, fireworks, confetti and captions on every move. Off, and
    /// the only setting in here that exists purely as a joke.
    var brainrot: Bool = false
    /// The dubstep loop that comes with the mode. A separate switch from the
    /// mode itself, and off on its own account: a window that starts playing
    /// music because a visual setting was left on would be indefensible.
    var brainrotMusic: Bool = false
    var windowFrame: String?

    static let fileName = "preferences.json"

    init() {}

    /// Decoded key by key, with a default for anything missing.
    ///
    /// The synthesised decoder throws on the first absent key, and `load()`
    /// answers a throw with a fresh `Preferences` — so adding one field to this
    /// struct would silently reset the table colour, the card back, the window
    /// position and everything else a player had chosen. `GameOptions` decodes
    /// itself by hand for the same reason.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drawCount = try c.decodeIfPresent(Int.self, forKey: .drawCount) ?? 1
        scoring = try c.decodeIfPresent(ScoringMode.self, forKey: .scoring) ?? .standard
        timed = try c.decodeIfPresent(Bool.self, forKey: .timed) ?? true
        winnableDealsOnly = try c.decodeIfPresent(Bool.self, forKey: .winnableDealsOnly) ?? false
        clickPrefersFoundation = try c.decodeIfPresent(Bool.self, forKey: .clickPrefersFoundation) ?? true
        autoPlaySafeCards = try c.decodeIfPresent(Bool.self, forKey: .autoPlaySafeCards) ?? false
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? false
        table = try c.decodeIfPresent(TableColor.self, forKey: .table) ?? .green
        backStyle = try c.decodeIfPresent(CardBackStyle.self, forKey: .backStyle) ?? .lattice
        backColor = try c.decodeIfPresent(CardBackColor.self, forKey: .backColor) ?? .navy
        fourColorDeck = try c.decodeIfPresent(Bool.self, forKey: .fourColorDeck) ?? false
        apple = try c.decodeIfPresent(Bool.self, forKey: .apple) ?? false
        brainrot = try c.decodeIfPresent(Bool.self, forKey: .brainrot) ?? false
        brainrotMusic = try c.decodeIfPresent(Bool.self, forKey: .brainrotMusic) ?? false
        windowFrame = try c.decodeIfPresent(String.self, forKey: .windowFrame)
    }

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
        theme.apple = apple
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
