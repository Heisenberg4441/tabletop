//
//  Game.swift
//  One game in progress: rules plus everything the rules do not care about —
//  score, clock, move count, and a perfect undo history.
//

import Foundation

struct GameOptions: Equatable, Codable, Sendable {
    var drawCount: Int = 1
    var redealLimit: Int?
    var scoring: ScoringMode = .standard
    /// Off by default. A timed game quietly drains the score, and a first-time
    /// player should not have to work out why their score is going down.
    var timed: Bool = false
    var winnableDealsOnly: Bool = false
    /// A click on a card sends it to a foundation when it can go, rather than
    /// preferring to build the tableau.
    var clickPrefersFoundation: Bool = true
    /// Send aces and twos up the moment they appear.
    var autoPlaySafeCards: Bool = false

    /// Vegas is traditionally played with the stock limited, which is what
    /// makes it hard enough to be worth money.
    static func defaultRedealLimit(scoring: ScoringMode, drawCount: Int) -> Int? {
        guard scoring == .vegas else { return nil }
        return drawCount == 1 ? 0 : 2
    }

    // Older saves are missing the fields added since; decode them as defaults
    // rather than throwing the whole game away.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drawCount = try c.decodeIfPresent(Int.self, forKey: .drawCount) ?? 1
        redealLimit = try c.decodeIfPresent(Int.self, forKey: .redealLimit)
        scoring = try c.decodeIfPresent(ScoringMode.self, forKey: .scoring) ?? .standard
        timed = try c.decodeIfPresent(Bool.self, forKey: .timed) ?? false
        winnableDealsOnly = try c.decodeIfPresent(Bool.self, forKey: .winnableDealsOnly) ?? false
        clickPrefersFoundation = try c.decodeIfPresent(Bool.self, forKey: .clickPrefersFoundation) ?? true
        autoPlaySafeCards = try c.decodeIfPresent(Bool.self, forKey: .autoPlaySafeCards) ?? false
    }
}

/// What just happened, so the view knows how to animate it.
enum GameEvent {
    case dealt
    case moved(MoveRecord)
    case undone
    case redone
    case won
}

final class Game {

    private(set) var state: GameState
    private(set) var options: GameOptions
    private(set) var dealNumber: Int

    /// The score as recorded in the undo history. The number shown to the
    /// player also folds in the timed game's steady drain and, once won, the
    /// finishing bonus — neither of which belongs in the history.
    private(set) var score: Int
    private(set) var timeBonus: Int = 0

    /// Everything the player has done, undo included. This is the number in the
    /// status bar: it is a measure of effort, not of the solution.
    private(set) var actionCount = 0
    /// Moves in the line that actually reached the current position. This is
    /// what a "fewest moves" record has to be measured in, or exploring with
    /// undo would put the record permanently out of reach.
    var moveCount: Int { undoStack.reduce(0) { $0 + $1.records.count } }

    var onEvent: ((GameEvent) -> Void)?

    /// One undoable action. Several moves collapse into one entry when the game
    /// makes them on the player's behalf — an auto-finish is a single ⌘Z, not
    /// fifty-two of them.
    private struct Entry {
        var records: [MoveRecord]
        /// The change the score *actually* took, after clamping. Storing the
        /// nominal value instead lets a player undo a clamped penalty for free
        /// and inflate the score without bound.
        var appliedScoreDelta: Int
    }
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    private var openGroup: Entry?

    // MARK: Clock

    /// Seconds spent on this deal, excluding time the game was paused.
    ///
    /// Measured on the continuous clock rather than `Date`: wall-clock time
    /// jumps when the system syncs with a time server or the user changes the
    /// clock, and a game timer that can run backwards is a bug report.
    private(set) var accumulatedTime: TimeInterval = 0
    private var runningSince: ContinuousClock.Instant?
    private(set) var hasStarted = false

    var elapsed: TimeInterval {
        guard let runningSince else { return accumulatedTime }
        let interval = ContinuousClock.now - runningSince
        return accumulatedTime + Double(interval.components.seconds)
            + Double(interval.components.attoseconds) * 1e-18
    }

    var isClockRunning: Bool { runningSince != nil }

    // MARK: Lifecycle

    init(dealNumber: Int, options: GameOptions) {
        self.dealNumber = dealNumber
        self.options = options
        self.score = options.scoring.startingScore
        self.state = GameState.deal(
            number: dealNumber,
            drawCount: options.drawCount,
            redealLimit: options.redealLimit
        )
    }

    init(restoring saved: SavedGame) {
        self.dealNumber = saved.dealNumber
        self.options = saved.options
        self.state = saved.state
        self.score = saved.score
        self.actionCount = saved.actionCount
        self.accumulatedTime = saved.elapsed
        self.hasStarted = saved.hasStarted
        self.undoStack = saved.history.map {
            Entry(records: $0.records, appliedScoreDelta: $0.appliedScoreDelta)
        }
    }

    var isWon: Bool { state.isWon }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canAutoFinish: Bool { state.canAutoFinish }
    var isStuck: Bool { state.isStuck }

    /// Applies the preferences that only affect how input is interpreted, so
    /// changing them never disturbs a game in progress.
    func updateLiveOptions(clickPrefersFoundation: Bool, autoPlaySafeCards: Bool) {
        options.clickPrefersFoundation = clickPrefersFoundation
        options.autoPlaySafeCards = autoPlaySafeCards
    }

    // MARK: Clock control

    func startClock() {
        guard runningSince == nil, !isWon else { return }
        runningSince = ContinuousClock.now
    }

    func pauseClock() {
        guard runningSince != nil else { return }
        accumulatedTime = elapsed
        runningSince = nil
    }

    // MARK: Undo grouping

    /// Moves made until the matching `endUndoGroup` collapse into one undo step.
    func beginUndoGroup() {
        guard openGroup == nil else { return }
        openGroup = Entry(records: [], appliedScoreDelta: 0)
    }

    func endUndoGroup() {
        guard let group = openGroup else { return }
        openGroup = nil
        guard !group.records.isEmpty else { return }
        undoStack.append(group)
    }

    // MARK: Moves

    @discardableResult
    func perform(_ move: Move) -> MoveRecord? {
        guard !isWon else { return nil }
        guard let record = state.apply(move) else { return nil }

        if !hasStarted {
            hasStarted = true
            startClock()
        }

        let nominal = Scoring.points(for: record, mode: options.scoring, state: state)
        let applied = applyScore(nominal)

        if openGroup != nil {
            openGroup?.records.append(record)
            openGroup?.appliedScoreDelta += applied
        } else {
            undoStack.append(Entry(records: [record], appliedScoreDelta: applied))
        }
        redoStack.removeAll(keepingCapacity: true)
        actionCount += 1

        assert(state.isConsistent, "a move lost or duplicated a card: \(move)")
        onEvent?(.moved(record))

        if state.isWon { finishWin() }
        return record
    }

    func autoMove(for target: ClickTarget) -> Move? {
        state.autoMove(for: target, foundationFirst: options.clickPrefersFoundation)
    }

    @discardableResult
    func undo() -> Bool {
        endUndoGroup()
        guard let entry = undoStack.popLast() else { return false }
        for record in entry.records.reversed() { state.undo(record) }
        score -= entry.appliedScoreDelta
        redoStack.append(entry)
        actionCount += 1
        // The finishing bonus is not part of the history; it exists only while
        // the game is actually won, so undoing the winning move retracts it.
        if !state.isWon { timeBonus = 0 }
        assert(state.isConsistent, "undo lost or duplicated a card")
        onEvent?(.undone)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        var replayed: [MoveRecord] = []
        var applied = 0
        for record in entry.records {
            guard let fresh = state.apply(record.move) else { break }
            replayed.append(fresh)
            applied += applyScore(Scoring.points(for: fresh, mode: options.scoring, state: state))
        }
        guard !replayed.isEmpty else { return false }
        undoStack.append(Entry(records: replayed, appliedScoreDelta: applied))
        actionCount += 1
        onEvent?(.redone)
        if state.isWon { finishWin() }
        return true
    }

    func restart() {
        state = GameState.deal(
            number: dealNumber,
            drawCount: options.drawCount,
            redealLimit: options.redealLimit
        )
        score = options.scoring.startingScore
        timeBonus = 0
        actionCount = 0
        undoStack.removeAll()
        redoStack.removeAll()
        openGroup = nil
        accumulatedTime = 0
        runningSince = nil
        hasStarted = false
        onEvent?(.dealt)
    }

    /// Adds `delta` and returns how much the score actually moved. The two
    /// differ whenever the clamp bites, and the difference is what undo has to
    /// give back.
    @discardableResult
    private func applyScore(_ delta: Int) -> Int {
        let before = score
        score += delta
        if options.scoring.clampsAtZero { score = max(0, score) }
        return score - before
    }

    private func finishWin() {
        pauseClock()
        timeBonus = Scoring.timeBonus(mode: options.scoring, timed: options.timed, seconds: elapsed)
        onEvent?(.won)
    }

    /// The number on screen: the recorded score, the timed game's drain, and
    /// the finishing bonus once there is one.
    var displayScore: Int {
        var total = score + timeBonus
        if options.scoring == .standard, options.timed, hasStarted, !isWon {
            total += Scoring.timePenalty(mode: options.scoring, timed: options.timed, seconds: elapsed)
        }
        return options.scoring.clampsAtZero ? max(0, total) : total
    }

    // MARK: Hints

    func hint() -> Move? {
        let moves = state.allMoves(includeFoundationToTableau: false)
        guard !moves.isEmpty else { return nil }
        return moves.max(by: { rank($0) < rank($1) })
    }

    /// Higher is better. The ordering encodes ordinary Klondike strategy:
    /// uncover face-down cards first, then get aces and twos out of the way,
    /// then make room, and only cycle the stock when there is nothing else.
    private func rank(_ move: Move) -> Int {
        switch move {
        case .tableauToTableau(let from, let to, let count):
            var score = 100
            let source = state.tableau[from]
            if count == source.up.count && source.down.isEmpty { score += 220 }
            else if count == source.up.count && !source.down.isEmpty { score += 200 }
            else { score -= 40 }
            if state.tableau[to].isEmpty { score -= 30 }
            return score

        case .wasteToTableau:
            return 150

        case .tableauToFoundation(let column):
            guard let card = state.tableau[column].topCard else { return 0 }
            var score = state.isSafeToAutoPlay(card) ? 190 : 60
            if state.tableau[column].up.count == 1 && !state.tableau[column].down.isEmpty {
                score += 30
            }
            return score

        case .wasteToFoundation:
            guard let card = state.waste.last else { return 0 }
            return state.isSafeToAutoPlay(card) ? 185 : 70

        case .foundationToTableau:
            return 10

        case .draw, .recycle:
            return 5
        }
    }

    /// Replaces the position wholesale. Only the self-test uses this — it is
    /// how a near-won board is set up without playing a real game to get there.
    func forceState(_ newState: GameState) {
        state = newState
        undoStack.removeAll()
        redoStack.removeAll()
        hasStarted = true
        startClock()
    }

    // MARK: Saving

    var saved: SavedGame {
        SavedGame(
            dealNumber: dealNumber,
            options: options,
            state: state,
            score: score,
            actionCount: actionCount,
            elapsed: elapsed,
            hasStarted: hasStarted,
            history: undoStack.map {
                SavedGame.Entry(records: $0.records, appliedScoreDelta: $0.appliedScoreDelta)
            }
        )
    }
}

/// The on-disk shape of a game in progress.
///
/// The version tag is the whole point: without one, adding a single field to
/// any of the types below turns every existing save into a decode failure, and
/// the player loses the game they were in the middle of.
struct SavedGame: Codable {
    struct Entry: Codable {
        var records: [MoveRecord]
        var appliedScoreDelta: Int
    }

    static let currentVersion = 1

    var version: Int = SavedGame.currentVersion
    var dealNumber: Int
    var options: GameOptions
    var state: GameState
    var score: Int
    var actionCount: Int
    var elapsed: TimeInterval
    var hasStarted: Bool
    var history: [Entry]

    init(dealNumber: Int, options: GameOptions, state: GameState, score: Int,
         actionCount: Int, elapsed: TimeInterval, hasStarted: Bool, history: [Entry]) {
        self.dealNumber = dealNumber
        self.options = options
        self.state = state
        self.score = score
        self.actionCount = actionCount
        self.elapsed = elapsed
        self.hasStarted = hasStarted
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= SavedGame.currentVersion else {
            // A save written by a newer build. Refusing it loses one game;
            // guessing at it could corrupt the statistics.
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "save is from a newer version of the app")
        }
        dealNumber = try c.decode(Int.self, forKey: .dealNumber)
        options = try c.decode(GameOptions.self, forKey: .options)
        state = try c.decode(GameState.self, forKey: .state)
        score = try c.decode(Int.self, forKey: .score)
        actionCount = try c.decodeIfPresent(Int.self, forKey: .actionCount) ?? 0
        elapsed = try c.decode(TimeInterval.self, forKey: .elapsed)
        hasStarted = try c.decode(Bool.self, forKey: .hasStarted)
        history = try c.decodeIfPresent([Entry].self, forKey: .history) ?? []
    }
}
