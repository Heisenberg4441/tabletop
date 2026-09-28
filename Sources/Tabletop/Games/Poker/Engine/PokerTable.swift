//
//  PokerTable.swift
//  No-limit hold'em, the rules and nothing else: seats, button, blinds, the
//  betting state machine, side pots, the showdown, the tournament and the
//  cash game around it.
//
//  A value type with no AppKit and no clock. The UI keeps one on the main
//  thread and drives it with four calls — `startHand()`, `apply(_:)`,
//  `advance()`, and `topUp(seat:)` between cash hands — each of which leaves
//  the table in its final state and returns the `PokerEvent`s that got it
//  there, for the animation. A bot gets a copy to think about on a
//  background thread (see `PokerBot`). The loop the UI runs:
//
//      switch table.phase {
//      case .betweenHands:   show the result, then table.startHand()
//      case .betting:        table.toAct is the human? wait for a button;
//                            a bot? PokerBot.decide(...) off the main thread,
//                            then table.apply(decision.action)
//      case .streetComplete: after a beat, table.advance()
//      case .gameOver:       the tournament banner
//      }
//
//  SEATS. `players[i].seat == i`, and seat numbers increase clockwise — the
//  direction the button, the blinds and the action move. With a human at
//  the table they are seat 0.
//
//  RULES, as the tests pin them down:
//  * Blinds: the two live seats after the button; heads-up the button posts
//    the small blind. A blind bigger than the stack is posted all-in, and the
//    others still call the full big blind. Preflop starts left of the big
//    blind (heads-up: the button), postflop left of the button (heads-up:
//    the big blind) — one formula for both.
//  * The moving button: it goes to the next seat that still has chips, and
//    the blinds follow it, whoever busted last hand.
//  * No-limit sizing: the smallest bet is the big blind; the smallest raise
//    is the last full raise's increment (never less than the big blind). An
//    all-in for less than that does not reopen the betting to players who
//    have already acted — unless the raises since they acted add up to a
//    full one. A call for more than the stack is an all-in for less.
//  * The part of a bet nobody matched goes back before the pots are made;
//    pots are rebuilt from every player's total for the hand, so any mix of
//    all-ins gives the right side pots. A split pot's odd chips go one at a
//    time to the winners nearest the button's left.
//

import Foundation

// MARK: - A seat

struct PokerPlayer: Hashable, Codable, Sendable {

    enum Status: String, Codable, Sendable {
        /// In the hand with chips behind: may still act.
        case active
        /// In the hand with nothing behind; waits for the showdown.
        case allIn
        case folded
        /// Not dealt in: no chips. A tournament player stays out (see
        /// `place`); a cash player buys back in at the next hand.
        case out
    }

    let seat: Int
    var name: String
    var isHuman: Bool
    var personality: PokerPersonality
    /// Chips behind — not counting `bet`.
    var stack: Int
    /// Chips in front of the seat on this street.
    var bet: Int = 0
    /// Everything put in this hand, bets on this street included.
    var committed: Int = 0
    /// Two cards once dealt. Kept after the hand for the showdown picture.
    var holeCards: [Card] = []
    var status: Status = .active
    /// Has made a voluntary action since the street began. Posting a blind
    /// does not count, which is what gives the big blind its option.
    var hasActed = false
    /// The bet to match right after this player last acted. The betting is
    /// reopened to them only by a full raise's worth on top of it.
    var actedAtBet = 0
    /// What they did last on this street, for the seat's caption. Cleared
    /// when the street changes.
    var lastAction: PokerActionRecord?
    /// Tournament finishing place once out, 1 for the winner.
    var place: Int?
    /// Every chip this player ever brought to the table: the first stack,
    /// rebuys and top-ups. The chips on the table always add up to the sum.
    var boughtIn: Int
    var stackAtHandStart: Int
    /// The last hands this seat acted in before the flop, oldest first, at
    /// most `habitMemory` of them. Public knowledge — anyone at the table
    /// could have watched — and what the bots read an opponent by.
    var habits: [PokerPreflopHabit] = []
    static let habitMemory = 12

    var isInHand: Bool { status == .active || status == .allIn }
    var canAct: Bool { status == .active }
    /// Chips in front and behind: what the player is playing with this street.
    var chipsInPlay: Int { stack + bet }

    init(seat: Int, name: String, isHuman: Bool, personality: PokerPersonality, stack: Int) {
        self.seat = seat
        self.name = name
        self.isHuman = isHuman
        self.personality = personality
        self.stack = stack
        self.boughtIn = stack
        self.stackAtHandStart = stack
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seat = try c.decode(Int.self, forKey: .seat)
        name = c.pokerDecode(.name, "")
        isHuman = c.pokerDecode(.isHuman, false)
        personality = c.pokerDecode(.personality, .tightAggressive)
        stack = max(0, c.pokerDecode(.stack, 0))
        bet = c.pokerDecode(.bet, 0)
        committed = c.pokerDecode(.committed, 0)
        holeCards = c.pokerDecode(.holeCards, [])
        status = c.pokerDecode(.status, .active)
        hasActed = c.pokerDecode(.hasActed, false)
        actedAtBet = c.pokerDecode(.actedAtBet, 0)
        lastAction = c.pokerDecode(.lastAction, nil)
        place = c.pokerDecode(.place, nil)
        boughtIn = c.pokerDecode(.boughtIn, stack)
        stackAtHandStart = c.pokerDecode(.stackAtHandStart, stack)
        habits = Array(c.pokerDecode(.habits, [PokerPreflopHabit]()).suffix(Self.habitMemory))
    }

    /// How often, lately, this seat's preflop action was one `matching`:
    /// blended with `prior` as if `weight` more hands had gone that way, so
    /// two shoves in two hands read as a tendency, not a certainty.
    func habitRate(prior: Double, weight: Double, matching: (PokerPreflopHabit) -> Bool) -> Double {
        let hits = Double(habits.filter(matching).count)
        return (hits + prior * weight) / (Double(habits.count) + weight)
    }
}

// MARK: - The table

struct PokerTable: Codable, Equatable, Sendable {

    private(set) var config: PokerTableConfig
    private(set) var players: [PokerPlayer]
    /// Seeds every shuffle (one per hand) and every bot decision.
    private(set) var seed: UInt64

    private(set) var phase: PokerPhase = .betweenHands
    private(set) var street: PokerStreet = .preflop
    private(set) var board: [Card] = []
    /// Chips gathered from earlier streets, main pot first. The current
    /// street's bets are still in front of the players (`PokerPlayer.bet`).
    private(set) var pots: [PokerPot] = []
    /// Nil before the first hand.
    private(set) var button: Int?
    private(set) var smallBlindSeat: Int?
    private(set) var bigBlindSeat: Int?
    /// Whose turn it is, during `.betting`.
    private(set) var toAct: Int?
    /// The bet to match on this street. Preflop it is the full big blind even
    /// when the big blind itself was posted short.
    private(set) var currentBet = 0
    /// The last full raise's increment: a raise must add at least this much.
    private(set) var minRaise = 0
    /// Whoever made the last full bet or raise, this street and preflop.
    private(set) var lastAggressor: Int?
    private(set) var preflopAggressor: Int?
    /// Whoever made the last full bet or raise on the street before this one
    /// (the one who "has the betting lead").
    private(set) var lastStreetAggressor: Int?
    /// Hands dealt so far; the current one's number while it is played.
    private(set) var handNumber = 0
    /// Tournament blind level, an index into `PokerTableConfig.tournamentLevels`.
    private(set) var levelIndex = 0
    /// Every action this hand, blinds included, in order.
    private(set) var handLog: [PokerActionRecord] = []
    /// Everyone left has turned their cards up (nobody can bet any more).
    private(set) var handsAreRevealed = false
    /// The last hand that was paid, for the banner and the log.
    private(set) var lastSummary: PokerHandSummary?

    private var deck: [Card] = []
    private var deckPosition = 0

    // MARK: Setting up

    /// A new table: the player (if `config.includesHuman`) at seat 0 and the
    /// computer players clockwise from there, named from `BotRoster` unless
    /// `botNames` says otherwise, each with a personality drawn from `seed`.
    init(config: PokerTableConfig, seed: UInt64,
         humanName: String = NSLocalizedString("You", comment: "poker: the human player's seat name"),
         botNames: [String]? = nil) {
        var config = config
        config.opponents = PokerTableConfig.clampedOpponents(config.opponents, includesHuman: config.includesHuman)
        self.config = config
        self.seed = seed
        let count = config.playerCount
        let botCount = config.includesHuman ? count - 1 : count
        let names = botNames ?? BotRoster.pick(botCount, seed: seed)
        // Every character appears once before any repeats, in an order the
        // seed decides — a full table has one of each.
        var characters = PokerPersonality.allCases
        var rng = DeterministicRNG(seed: seed ^ 0x5045_5253_4F4E_4131)
        rng.shuffle(&characters)
        players = (0..<count).map { seat in
            let isHuman = config.includesHuman && seat == 0
            let bot = config.includesHuman ? seat - 1 : seat
            let name = isHuman ? humanName
                : (names[safe: bot] ?? String(format: NSLocalizedString("Player %d", comment: "poker: fallback seat name"),
                                               seat + 1))
            return PokerPlayer(seat: seat, name: name, isHuman: isHuman,
                               personality: characters[max(0, bot) % characters.count],
                               stack: config.startingStack)
        }
    }

    // MARK: Reading the table

    var blinds: PokerBlindLevel {
        guard config.mode == .tournament else { return PokerTableConfig.cashBlinds }
        let levels = PokerTableConfig.tournamentLevels
        return levels[max(0, min(levelIndex, levels.count - 1))]
    }

    /// The seat the player sits in, if there is one.
    var humanSeat: Int? { players.first(where: \.isHuman)?.seat }

    /// The size bets are rounded to by the bots and the bet slider: 5 at the
    /// low levels, 25 once the small blind reaches 100.
    var chipUnit: Int {
        let sb = blinds.smallBlind
        if sb >= 100 && sb % 25 == 0 { return 25 }
        return sb % 5 == 0 ? 5 : 1
    }

    /// Tournament: hands still to be dealt at this level after the current
    /// (or last) one; 0 means the next hand raises the blinds. Nil in a cash
    /// game and at the last level.
    var handsUntilNextLevel: Int? {
        guard config.mode == .tournament,
              levelIndex < PokerTableConfig.tournamentLevels.count - 1 else { return nil }
        return max(0, (levelIndex + 1) * PokerTableConfig.handsPerLevel - handNumber)
    }

    /// Every chip in the middle: the pots plus every bet in front of a seat.
    var potTotal: Int {
        pots.reduce(0) { $0 + $1.amount } + players.reduce(0) { $0 + $1.bet }
    }

    /// Every chip at the table, wherever it is. Always equal to `chipsBoughtIn`.
    var chipsOnTable: Int {
        players.reduce(0) { $0 + $1.stack + $1.bet } + pots.reduce(0) { $0 + $1.amount }
    }

    var chipsBoughtIn: Int { players.reduce(0) { $0 + $1.boughtIn } }

    /// Seats still holding chips (or in the hand).
    var seatsWithChips: [Int] {
        players.filter { $0.stack > 0 || $0.isInHand }.map(\.seat)
    }

    /// The player's tournament place once it is known: when they bust, or 1
    /// when they win.
    var humanPlace: Int? { humanSeat.flatMap { players[$0].place } }

    /// It is the player's turn.
    var isHumanToAct: Bool {
        phase == .betting && toAct != nil && toAct == humanSeat
    }

    /// The best hand `seat` holds right now with the board so far — for the
    /// pill beside the player's cards ("Two Pair"). Nil without hole cards.
    func currentHand(for seat: Int) -> PokerHandResult? {
        guard let player = players[safe: seat], player.holeCards.count == 2 else { return nil }
        return PokerEvaluator.best(player.holeCards + board)
    }

    /// The next seat clockwise after `seat` for which `test` holds.
    func nextSeat(after seat: Int, where test: (PokerPlayer) -> Bool) -> Int? {
        let n = players.count
        guard n > 0 else { return nil }
        for step in 1...n {
            let s = ((seat + step) % n + n) % n
            if test(players[s]) { return s }
        }
        return nil
    }

    /// `seats` in the order play reaches them, starting left of the button —
    /// the dealing order, the showdown order and the odd-chip order.
    func orderedFromButton(_ seats: [Int]) -> [Int] {
        let n = max(1, players.count)
        let start = ((button ?? 0) + 1) % n
        return seats.sorted { (($0 - start) % n + n) % n < (($1 - start) % n + n) % n }
    }

    /// Players in the hand still to act after `seat` this round, in order —
    /// a bot's sense of position.
    func seatsStillToAct(after seat: Int) -> [Int] {
        guard players.count > 1, players.indices.contains(seat) else { return [] }
        var result: [Int] = []
        var s = seat
        for _ in 0..<(players.count - 1) {
            s = (s + 1) % players.count
            if needsToAct(s) && s != seat { result.append(s) }
        }
        return result
    }

    // MARK: Options

    /// What the player to act may do, or nil when nobody is to act.
    func options() -> PokerActionOptions? {
        guard phase == .betting, let seat = toAct else { return nil }
        return options(for: seat)
    }

    /// What `seat` could do if it were their turn in the current betting.
    func options(for seat: Int) -> PokerActionOptions {
        let p = players[seat]
        let toCall = max(0, currentBet - p.bet)
        let callAmount = min(toCall, p.stack)
        let someoneCouldCall = players.contains { $0.seat != seat && $0.canAct }
        let reopened = !p.hasActed || currentBet - p.actedAtBet >= minRaise
        let canAggress = p.canAct && p.stack > toCall && someoneCouldCall && reopened
        let maxTotal = p.bet + p.stack
        let fullMinimum = currentBet == 0 ? max(minRaise, blinds.bigBlind) : currentBet + minRaise
        return PokerActionOptions(
            seat: seat,
            canFold: p.canAct,
            canCheck: p.canAct && toCall == 0,
            canCall: p.canAct && toCall > 0,
            callAmount: callAmount,
            callIsAllIn: toCall > 0 && p.stack <= toCall,
            canBet: canAggress && currentBet == 0,
            canRaise: canAggress && currentBet > 0,
            minTotal: min(maxTotal, fullMinimum),
            maxTotal: maxTotal,
            currentBet: currentBet,
            playerBet: p.bet,
            stack: p.stack,
            pot: potTotal)
    }

    /// Whether `action` is allowed for the player to act right now.
    func isLegal(_ action: PokerAction) -> Bool {
        guard let o = options() else { return false }
        return Self.isLegal(action, o)
    }

    static func isLegal(_ action: PokerAction, _ o: PokerActionOptions) -> Bool {
        switch action {
        case .fold: return o.canFold
        case .check: return o.canCheck
        case .call: return o.canCall
        case .bet(let total): return o.canBet && total >= o.minTotal && total <= o.maxTotal
        case .raise(let total): return o.canRaise && total >= o.minTotal && total <= o.maxTotal
        case .allIn: return o.stack > 0 && (o.callIsAllIn || o.canBetOrRaise)
        }
    }

    // MARK: Playing a hand

    /// Deals the next hand: cash rebuys, the tournament's next level, the
    /// button, the blinds, two cards each. Does nothing outside
    /// `.betweenHands`; moves to `.gameOver` instead when fewer than two
    /// players have chips.
    ///
    /// A cash player with no chips — the human included — buys back in for
    /// a full stack here, so the table never stalls; a UI that wants to ask
    /// first calls `topUp(seat:)` before this.
    @discardableResult
    mutating func startHand() -> [PokerEvent] {
        guard phase == .betweenHands else { return [] }
        var events: [PokerEvent] = []

        if config.mode == .cash {
            for i in players.indices where players[i].stack == 0 {
                events += topUp(seat: i)
            }
        }
        let live = players.filter { $0.stack > 0 }.map(\.seat)
        guard live.count >= 2 else {
            phase = .gameOver
            return events
        }

        handNumber += 1
        if config.mode == .tournament {
            let level = min((handNumber - 1) / PokerTableConfig.handsPerLevel,
                            PokerTableConfig.tournamentLevels.count - 1)
            if level != levelIndex {
                levelIndex = level
                events.append(.blindsRaised(level: level, blinds: blinds))
            }
        }

        for i in players.indices {
            players[i].bet = 0
            players[i].committed = 0
            players[i].holeCards = []
            players[i].hasActed = false
            players[i].actedAtBet = 0
            players[i].lastAction = nil
            players[i].stackAtHandStart = players[i].stack
            players[i].status = players[i].stack > 0 ? .active : .out
        }
        board = []
        pots = []
        street = .preflop
        handLog = []
        lastAggressor = nil
        preflopAggressor = nil
        lastStreetAggressor = nil
        handsAreRevealed = false

        // The moving button: the next seat that still has chips.
        let newButton: Int
        if let old = button, let next = nextSeat(after: old, where: { $0.status != .out }) {
            newButton = next
        } else {
            var rng = DeterministicRNG(seed: seed ^ 0x4255_5454_4F4E)
            newButton = live[rng.next(upperBound: live.count)]
        }
        button = newButton
        events.append(.handStarted(number: handNumber, button: newButton))

        let dealtIn: (PokerPlayer) -> Bool = { $0.status != .out }
        let sb = live.count == 2 ? newButton : (nextSeat(after: newButton, where: dealtIn) ?? newButton)
        let bb = nextSeat(after: sb, where: dealtIn) ?? sb
        smallBlindSeat = sb
        bigBlindSeat = bb
        events.append(.acted(post(sb, blinds.smallBlind, kind: .smallBlind)))
        events.append(.acted(post(bb, blinds.bigBlind, kind: .bigBlind)))
        currentBet = blinds.bigBlind
        minRaise = blinds.bigBlind

        deck = Card.full
        var rng = DeterministicRNG(seed: handSeed)
        rng.shuffle(&deck)
        deckPosition = 0
        let order = orderedFromButton(players.filter(dealtIn).map(\.seat))
        for _ in 0..<2 {
            for seat in order { players[seat].holeCards.append(draw()) }
        }
        events.append(.dealtHoleCards(order: order))

        phase = .betting
        passAction(after: bb, events: &events)
        return events
    }

    /// Takes the action for the player whose turn it is. Throws, changing
    /// nothing, when it is not legal — the engine is the referee, so neither
    /// a bot nor a stray click can bend the rules.
    @discardableResult
    mutating func apply(_ action: PokerAction) throws -> [PokerEvent] {
        guard phase == .betting, let seat = toAct else { throw PokerEngineError.notBetting }
        let o = options(for: seat)
        guard Self.isLegal(action, o) else { throw PokerEngineError.illegalAction(action) }

        let record: PokerActionRecord
        switch action {
        case .fold:
            players[seat].status = .folded
            record = PokerActionRecord(seat: seat, street: street, kind: .fold, total: players[seat].bet,
                                       added: 0, isAllIn: false, isFullRaise: false)
        case .check:
            record = PokerActionRecord(seat: seat, street: street, kind: .check, total: players[seat].bet,
                                       added: 0, isAllIn: false, isFullRaise: false)
        case .call:
            record = call(seat, o)
        case .bet(let total), .raise(let total):
            record = raise(seat, to: total)
        case .allIn:
            record = o.callIsAllIn ? call(seat, o) : raise(seat, to: o.maxTotal)
        }
        players[seat].hasActed = true
        players[seat].actedAtBet = currentBet
        players[seat].lastAction = record
        handLog.append(record)

        var events: [PokerEvent] = [.acted(record)]
        passAction(after: seat, events: &events)
        return events
    }

    /// Moves a finished betting round on: returns the uncalled bet, gathers
    /// the bets into pots, then deals the next street — or pays the pots, at
    /// the river or when everyone else has folded. Does nothing outside
    /// `.streetComplete`.
    ///
    /// When nobody can bet any more (everyone but one is all-in) each call
    /// deals one more street and stays in `.streetComplete`, so the runout
    /// can be paced street by street; the first such call turns the hands up.
    @discardableResult
    mutating func advance() -> [PokerEvent] {
        guard phase == .streetComplete else { return [] }
        var events: [PokerEvent] = []
        returnUncalledBet(&events)
        collectBets(&events)

        let inHand = players.filter(\.isInHand).map(\.seat)
        if inHand.count <= 1 {
            awardUncontested(to: inHand.first, &events)
            finishHand(showdown: [], &events)
            return events
        }
        if street >= .river {
            let shown = showdown(&events)
            finishHand(showdown: shown, &events)
            return events
        }

        let canBet = players.filter(\.canAct).count >= 2
        if !canBet && !handsAreRevealed {
            handsAreRevealed = true
            events.append(.handsRevealed(orderedFromButton(inHand).map {
                PokerShownHand(seat: $0, holeCards: players[$0].holeCards, result: nil)
            }))
        }
        dealNextStreet(&events)
        if canBet {
            phase = .betting
            passAction(after: button ?? 0, events: &events)
        } else {
            phase = .streetComplete
        }
        return events
    }

    /// Cash game, between hands: brings `seat` back up to a full stack.
    /// Returns the `.rebought` event, or nothing when it does not apply.
    @discardableResult
    mutating func topUp(seat: Int) -> [PokerEvent] {
        guard config.mode == .cash, phase == .betweenHands, players.indices.contains(seat) else { return [] }
        let amount = PokerTableConfig.cashStack - players[seat].stack
        guard amount > 0 else { return [] }
        players[seat].stack += amount
        players[seat].boughtIn += amount
        return [.rebought(seat: seat, amount: amount)]
    }

    /// Whether `topUp(seat:)` would add anything now.
    func canTopUp(seat: Int) -> Bool {
        config.mode == .cash && phase == .betweenHands
            && (players[safe: seat]?.stack ?? PokerTableConfig.cashStack) < PokerTableConfig.cashStack
    }

    // MARK: The machinery

    /// Adds this hand's preflop action to every seat's habits — for the
    /// seats that had a decision to make (a big blind given a walk had none).
    private mutating func rememberPreflopHabits() {
        for i in players.indices {
            let mine = handLog.filter { $0.seat == i && $0.street == .preflop
                && $0.kind != .smallBlind && $0.kind != .bigBlind }
            guard !mine.isEmpty else { continue }
            let start = max(1, players[i].stackAtHandStart)
            let habit: PokerPreflopHabit
            if mine.contains(where: { $0.isAggressive && ($0.isAllIn || $0.total * 3 >= start) }) {
                habit = .shoved
            } else if mine.contains(where: \.isAggressive) {
                habit = .raised
            } else {
                habit = .passive
            }
            players[i].habits.append(habit)
            if players[i].habits.count > PokerPlayer.habitMemory {
                players[i].habits.removeFirst(players[i].habits.count - PokerPlayer.habitMemory)
            }
        }
    }

    private var handSeed: UInt64 {
        seed &+ UInt64(handNumber) &* 0x9E37_79B9_7F4A_7C15
    }

    private mutating func draw() -> Card {
        defer { deckPosition += 1 }
        return deck[safe: deckPosition] ?? Card(code: 0)
    }

    /// Moves up to `amount` from the stack to the bet.
    @discardableResult
    private mutating func putIn(_ seat: Int, _ amount: Int) -> Int {
        let chips = max(0, min(amount, players[seat].stack))
        players[seat].stack -= chips
        players[seat].bet += chips
        players[seat].committed += chips
        if players[seat].stack == 0 && players[seat].status == .active {
            players[seat].status = .allIn
        }
        return chips
    }

    private mutating func post(_ seat: Int, _ amount: Int, kind: PokerActionRecord.Kind) -> PokerActionRecord {
        let added = putIn(seat, amount)
        let record = PokerActionRecord(seat: seat, street: .preflop, kind: kind, total: players[seat].bet,
                                       added: added, isAllIn: players[seat].stack == 0, isFullRaise: false)
        players[seat].lastAction = record
        handLog.append(record)
        return record
    }

    private mutating func call(_ seat: Int, _ o: PokerActionOptions) -> PokerActionRecord {
        let added = putIn(seat, o.callAmount)
        return PokerActionRecord(seat: seat, street: street, kind: .call, total: players[seat].bet,
                                 added: added, isAllIn: players[seat].stack == 0, isFullRaise: false)
    }

    private mutating func raise(_ seat: Int, to total: Int) -> PokerActionRecord {
        let wasBet = currentBet == 0
        let added = putIn(seat, total - players[seat].bet)
        let newTotal = players[seat].bet
        let increment = newTotal - currentBet
        let isFull = increment >= minRaise
        if isFull {
            minRaise = increment
            lastAggressor = seat
            if street == .preflop { preflopAggressor = seat }
        }
        currentBet = max(currentBet, newTotal)
        return PokerActionRecord(seat: seat, street: street, kind: wasBet ? .bet : .raise, total: newTotal,
                                 added: added, isAllIn: players[seat].stack == 0, isFullRaise: isFull)
    }

    /// Someone still owes an action this round.
    private func needsToAct(_ seat: Int) -> Bool {
        let p = players[seat]
        return p.canAct && (!p.hasActed || p.bet < currentBet)
    }

    /// The round is over when nobody owes an action — or when only one
    /// player could still act and has already matched everyone else, so
    /// there is nobody left to bet against (the big blind whose opponents
    /// are all in for less needs no option).
    private func bettingRoundIsOver() -> Bool {
        let inHand = players.filter(\.isInHand)
        if inHand.count <= 1 { return true }
        let active = inHand.filter(\.canAct)
        if active.isEmpty { return true }
        if active.count == 1 {
            let p = active[0]
            let highestOther = inHand.lazy.filter { $0.seat != p.seat }.map(\.bet).max() ?? 0
            return p.bet >= highestOther
        }
        return !active.contains { !$0.hasActed || $0.bet < currentBet }
    }

    private mutating func passAction(after seat: Int, events: inout [PokerEvent]) {
        if !bettingRoundIsOver(), let next = nextSeat(after: seat, where: { self.needsToAct($0.seat) }) {
            toAct = next
            phase = .betting
            return
        }
        toAct = nil
        phase = .streetComplete
        events.append(.bettingRoundEnded(street: street))
    }

    private mutating func returnUncalledBet(_ events: inout [PokerEvent]) {
        guard let top = players.indices.max(by: { players[$0].bet < players[$1].bet }),
              players[top].bet > 0, players[top].isInHand else { return }
        let second = players.indices.filter { $0 != top }.map { players[$0].bet }.max() ?? 0
        let excess = players[top].bet - second
        guard excess > 0 else { return }
        players[top].bet -= excess
        players[top].committed -= excess
        players[top].stack += excess
        if players[top].status == .allIn { players[top].status = .active }
        events.append(.uncalledBetReturned(seat: top, amount: excess))
    }

    private mutating func collectBets(_ events: inout [PokerEvent]) {
        let moved = players.reduce(0) { $0 + $1.bet }
        let rebuilt = Self.buildPots(committed: players.map(\.committed), live: players.map(\.isInHand))
        let changed = rebuilt != pots
        pots = rebuilt
        for i in players.indices {
            players[i].bet = 0
            players[i].hasActed = false
            players[i].actedAtBet = 0
            players[i].lastAction = nil
        }
        currentBet = 0
        minRaise = blinds.bigBlind
        lastStreetAggressor = lastAggressor
        lastAggressor = nil
        if moved > 0 || changed { events.append(.betsCollected(pots: pots)) }
    }

    /// Main pot and side pots from each seat's total for the hand.
    ///
    /// Peel off the smallest commitment still standing among the players in
    /// the hand: everyone pays up to that level into a pot those players can
    /// win; repeat with what is left. Chips folded players put in beyond every
    /// live player's total can only arise if an uncalled bet was not returned;
    /// they go to the last pot rather than vanish.
    static func buildPots(committed: [Int], live: [Bool]) -> [PokerPot] {
        var remaining = committed
        var pots: [PokerPot] = []
        while true {
            let contenders = remaining.indices.filter { live[$0] && remaining[$0] > 0 }
            guard let level = contenders.map({ remaining[$0] }).min() else { break }
            var amount = 0
            for i in remaining.indices {
                let take = min(remaining[i], level)
                amount += take
                remaining[i] -= take
            }
            if let last = pots.indices.last, pots[last].eligible == contenders {
                pots[last].amount += amount
            } else {
                pots.append(PokerPot(amount: amount, eligible: contenders))
            }
        }
        let leftover = remaining.reduce(0, +)
        if leftover > 0 {
            if let last = pots.indices.last {
                pots[last].amount += leftover
            } else {
                pots.append(PokerPot(amount: leftover, eligible: live.indices.filter { live[$0] }))
            }
        }
        return pots
    }

    private mutating func dealNextStreet(_ events: inout [PokerEvent]) {
        guard let next = PokerStreet(rawValue: street.rawValue + 1), next <= .river else { return }
        _ = draw()   // the burn card
        var cards: [Card] = []
        while board.count + cards.count < next.boardCount { cards.append(draw()) }
        board += cards
        street = next
        events.append(.dealtCommunity(street: next, cards: cards))
    }

    private mutating func awardUncontested(to seat: Int?, _ events: inout [PokerEvent]) {
        guard let seat else { return }
        for (i, pot) in pots.enumerated() where pot.amount > 0 {
            players[seat].stack += pot.amount
            events.append(.potAwarded(PokerPotAward(potIndex: i, amount: pot.amount,
                                                    shares: [PokerPotShare(seat: seat, amount: pot.amount)], hand: nil)))
        }
    }

    private mutating func showdown(_ events: inout [PokerEvent]) -> [PokerShownHand] {
        street = .showdown
        let inHand = orderedFromButton(players.filter(\.isInHand).map(\.seat))
        var results: [Int: PokerHandResult] = [:]
        for seat in inHand { results[seat] = PokerEvaluator.best(players[seat].holeCards + board) }
        let shown = inHand.map { PokerShownHand(seat: $0, holeCards: players[$0].holeCards, result: results[$0]) }
        events.append(.showdown(shown))

        for (i, pot) in pots.enumerated() where pot.amount > 0 {
            let contenders = orderedFromButton(pot.eligible.filter { results[$0] != nil })
            guard let best = contenders.compactMap({ results[$0]?.value }).max() else { continue }
            let winners = contenders.filter { results[$0]?.value == best }
            let share = pot.amount / winners.count
            var odd = pot.amount % winners.count
            var shares: [PokerPotShare] = []
            for seat in winners {
                let extra = odd > 0 ? 1 : 0
                odd -= extra
                shares.append(PokerPotShare(seat: seat, amount: share + extra))
                players[seat].stack += share + extra
            }
            events.append(.potAwarded(PokerPotAward(potIndex: i, amount: pot.amount, shares: shares,
                                                    hand: winners.first.flatMap { results[$0] })))
        }
        return shown
    }

    private mutating func finishHand(showdown shown: [PokerShownHand], _ events: inout [PokerEvent]) {
        let awards: [PokerPotAward] = events.compactMap {
            if case .potAwarded(let award) = $0 { return award }
            return nil
        }
        pots = []
        toAct = nil
        for i in players.indices {
            players[i].bet = 0
            players[i].committed = 0
        }
        let summary = PokerHandSummary(handNumber: handNumber, board: board, awards: awards, shown: shown,
                                       netChange: players.map { $0.stack - $0.stackAtHandStart })
        lastSummary = summary
        events.append(.handEnded(summary))
        rememberPreflopHabits()

        let busted = players.filter { $0.status != .out && $0.stack == 0 }
        for p in busted { players[p.seat].status = .out }
        guard config.mode == .tournament else {
            phase = .betweenHands
            return
        }
        // Several out in one hand: whoever started it with more chips
        // finishes higher; level stacks go by the button order.
        let remaining = players.filter { $0.stack > 0 }.map(\.seat)
        let order = orderedFromButton(busted.map(\.seat))
        let ranked = busted.map(\.seat).sorted {
            let a = players[$0].stackAtHandStart, b = players[$1].stackAtHandStart
            if a != b { return a > b }
            return (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0)
        }
        for (k, seat) in ranked.enumerated() {
            let place = remaining.count + 1 + k
            players[seat].place = place
            events.append(.eliminated(seat: seat, place: place))
        }
        if remaining.count == 1, let winner = remaining.first {
            players[winner].place = 1
            phase = .gameOver
            events.append(.tournamentEnded(winner: winner))
        } else {
            phase = remaining.count >= 2 ? .betweenHands : .gameOver
        }
    }
}

// MARK: - Saving and restoring

extension PokerTable {

    /// A table that can be played from: two to six seats numbered in order,
    /// no negative stacks, every chip accounted for — and mid-hand, somebody
    /// able to act whose turn it is. A save that fails this is thrown away
    /// rather than resumed.
    var isConsistent: Bool {
        guard (2...6).contains(players.count),
              players.enumerated().allSatisfy({ $0.offset == $0.element.seat }),
              players.allSatisfy({ $0.stack >= 0 && $0.bet >= 0 && $0.committed >= 0 }),
              chipsOnTable == chipsBoughtIn else { return false }
        if phase == .betting {
            guard let seat = toAct, players.indices.contains(seat), players[seat].canAct else { return false }
        }
        return true
    }

    /// No hand is being played.
    var isAtHandBoundary: Bool { phase == .betweenHands || phase == .gameOver }

    /// Undoes a hand that cannot go on — a save whose deck is missing — by
    /// giving every seat back what it put in, so the table resumes between
    /// hands. The hand's number stays used: the next hand is shuffled from
    /// the next number, so the same cards never come round twice.
    mutating func abandonHandInProgress() {
        guard phase == .betting || phase == .streetComplete else { return }
        for i in players.indices {
            players[i].stack += players[i].committed
            players[i].bet = 0
            players[i].committed = 0
            if players[i].status != .out { players[i].status = .active }
        }
        pots = []
        board = []
        toAct = nil
        handsAreRevealed = false
        phase = .betweenHands
    }

    enum CodingKeys: String, CodingKey {
        case config, players, seed, phase, street, board, pots, button, smallBlindSeat, bigBlindSeat, toAct
        case currentBet, minRaise, lastAggressor, preflopAggressor, lastStreetAggressor, handNumber, levelIndex, handLog
        case handsAreRevealed, lastSummary, deck, deckPosition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = c.pokerDecode(.config, PokerTableConfig())
        players = try c.decode([PokerPlayer].self, forKey: .players)
        seed = c.pokerDecode(.seed, 1)
        phase = c.pokerDecode(.phase, .betweenHands)
        street = c.pokerDecode(.street, .preflop)
        board = c.pokerDecode(.board, [])
        pots = c.pokerDecode(.pots, [])
        button = c.pokerDecode(.button, nil)
        smallBlindSeat = c.pokerDecode(.smallBlindSeat, nil)
        bigBlindSeat = c.pokerDecode(.bigBlindSeat, nil)
        toAct = c.pokerDecode(.toAct, nil)
        currentBet = c.pokerDecode(.currentBet, 0)
        minRaise = c.pokerDecode(.minRaise, 0)
        lastAggressor = c.pokerDecode(.lastAggressor, nil)
        preflopAggressor = c.pokerDecode(.preflopAggressor, nil)
        lastStreetAggressor = c.pokerDecode(.lastStreetAggressor, nil)
        handNumber = c.pokerDecode(.handNumber, 0)
        levelIndex = c.pokerDecode(.levelIndex, 0)
        handLog = c.pokerDecode(.handLog, [])
        handsAreRevealed = c.pokerDecode(.handsAreRevealed, false)
        lastSummary = c.pokerDecode(.lastSummary, nil)
        deck = c.pokerDecode(.deck, [])
        deckPosition = c.pokerDecode(.deckPosition, 0)
        if let button, !players.indices.contains(button) { self.button = nil }
        // A hand in progress needs its deck to go on; without one, give the
        // chips back and resume between hands.
        if !isAtHandBoundary && (deckPosition > deck.count || deck.count < 20) { abandonHandInProgress() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(config, forKey: .config)
        try c.encode(players, forKey: .players)
        try c.encode(seed, forKey: .seed)
        try c.encode(phase, forKey: .phase)
        try c.encode(street, forKey: .street)
        try c.encode(board, forKey: .board)
        try c.encode(pots, forKey: .pots)
        try c.encodeIfPresent(button, forKey: .button)
        try c.encodeIfPresent(smallBlindSeat, forKey: .smallBlindSeat)
        try c.encodeIfPresent(bigBlindSeat, forKey: .bigBlindSeat)
        try c.encodeIfPresent(toAct, forKey: .toAct)
        try c.encode(currentBet, forKey: .currentBet)
        try c.encode(minRaise, forKey: .minRaise)
        try c.encodeIfPresent(lastAggressor, forKey: .lastAggressor)
        try c.encodeIfPresent(preflopAggressor, forKey: .preflopAggressor)
        try c.encodeIfPresent(lastStreetAggressor, forKey: .lastStreetAggressor)
        try c.encode(handNumber, forKey: .handNumber)
        try c.encode(levelIndex, forKey: .levelIndex)
        try c.encode(handLog, forKey: .handLog)
        try c.encode(handsAreRevealed, forKey: .handsAreRevealed)
        try c.encodeIfPresent(lastSummary, forKey: .lastSummary)
        try c.encode(deck, forKey: .deck)
        try c.encode(deckPosition, forKey: .deckPosition)
    }
}

// MARK: - Test hooks

extension PokerTable {

    /// Changes how well the bots play from their next decision on. The rest
    /// of the setup is fixed for the table's life.
    mutating func setDifficulty(_ difficulty: PokerDifficulty) {
        config.difficulty = difficulty
    }

    /// Sets every stack (and books the difference as bought in, so the chips
    /// still add up). Between hands only; for tests and screenshot scenes.
    mutating func setStacksForTesting(_ stacks: [Int]) {
        guard phase == .betweenHands || phase == .gameOver else { return }
        for (i, stack) in stacks.enumerated() where players.indices.contains(i) {
            players[i].boughtIn += stack - players[i].stack
            players[i].stack = max(0, stack)
            players[i].status = stack > 0 ? .active : .out
        }
        if players.filter({ $0.stack > 0 }).count >= 2 { phase = .betweenHands }
    }

    /// Puts the button on `seat`, so the next hand moves it one live seat on.
    mutating func setButtonForTesting(_ seat: Int) {
        button = seat
    }

    /// Gives `seat` a history the bots have watched.
    mutating func setHabitsForTesting(_ habits: [PokerPreflopHabit], seat: Int) {
        guard players.indices.contains(seat) else { return }
        players[seat].habits = Array(habits.suffix(PokerPlayer.habitMemory))
    }

    /// Replaces the hole cards dealt this hand and stacks the deck so the
    /// board comes out as `board` (fewer than five fills in from the rest).
    /// Call it straight after `startHand()`.
    mutating func rigForTesting(hole: [Int: [Card]], board wanted: [Card]) {
        for (seat, cards) in hole where players.indices.contains(seat) { players[seat].holeCards = cards }
        // Seats not rigged keep their cards unless a rigged card was theirs;
        // those get a replacement nobody holds.
        let claimed = Set(hole.values.flatMap { $0 } + board + wanted)
        var spare = Card.full.filter { card in
            !claimed.contains(card) && !players.contains { $0.holeCards.contains(card) }
        }
        for i in players.indices where hole[i] == nil {
            for (k, card) in players[i].holeCards.enumerated() where claimed.contains(card) && !spare.isEmpty {
                players[i].holeCards[k] = spare.removeFirst()
            }
        }
        let used = Set(players.flatMap(\.holeCards) + board + wanted)
        var rest = Card.full.filter { !used.contains($0) }
        var stacked: [Card] = []
        var queue = wanted[...]
        for next in PokerStreet.allCases where next > street && next <= .river {
            stacked.append(rest.removeFirst())    // burn
            let count = next.boardCount - (PokerStreet(rawValue: next.rawValue - 1)?.boardCount ?? 0)
            for _ in 0..<count { stacked.append(queue.popFirst() ?? rest.removeFirst()) }
        }
        deck = stacked + rest
        deckPosition = 0
    }
}
