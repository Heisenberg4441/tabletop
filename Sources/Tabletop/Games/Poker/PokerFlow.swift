//
//  PokerFlow.swift
//  The loop that runs a poker table: deal, let everyone act in turn — the
//  player through the buttons, the computer players after a pause for
//  thought — move the hand on street by street, pay it, and deal the next.
//
//  It owns the engine's `PokerTable` and is the only thing that changes it.
//  Every change comes back as events, which go to the table view to be
//  played out; the flow waits exactly as long as that takes before its next
//  step, on the view's `TableScheduler`. So the same loop, with no view and
//  an immediate scheduler, plays whole tournaments in the self-tests in a
//  blink — the path they test is the path the player plays.
//
//  TIME. Nothing here uses a timer of its own. Every pause — a bot's
//  thinking, the beat before the flop, the result before the next deal — is
//  a step on the scheduler, which the game suspends whenever it is not on
//  screen and cancels on a new game. A bot's decision is computed in
//  milliseconds off the main thread (`PokerBotWorker`); the pause the player
//  sees is the scheduler's, minus however long the computing took, so a
//  decision that arrives while the game is in the background simply waits
//  there with the rest.
//
//  STALE WORK. A generation number goes up on every new table; a step or a
//  decision from an older one finds it changed and does nothing.
//

import AppKit

/// Who makes the computer players' decisions.
@MainActor
protocol PokerDecider: AnyObject {
    func decide(_ table: PokerTable, seat: Int, completion: @escaping (PokerBotDecision) -> Void)
    func cancel()
}

/// The app's: on a background queue, answered on the main thread.
@MainActor
final class PokerWorkerDecider: PokerDecider {
    let worker = PokerBotWorker()
    var samples: Int?

    func decide(_ table: PokerTable, seat: Int, completion: @escaping (PokerBotDecision) -> Void) {
        worker.decide(table, seat: seat, samples: samples, completion: completion)
    }

    func cancel() { worker.cancel() }
}

/// The tests' and the screenshots': straight away, on the calling thread.
@MainActor
final class PokerDirectDecider: PokerDecider {
    var samples: Int?

    init(samples: Int? = nil) { self.samples = samples }

    func decide(_ table: PokerTable, seat: Int, completion: @escaping (PokerBotDecision) -> Void) {
        completion(PokerBot.decide(table: table, seat: seat, samples: samples))
    }

    func cancel() {}
}

/// What the game around the flow is told.
@MainActor
protocol PokerFlowDelegate: AnyObject {
    /// Whose turn it is, or the phase, changed: the action bar and the
    /// status pills follow.
    func flowDidChangeState(_ flow: PokerFlow)
    /// A hand has been paid (the table is already between hands). For the
    /// record, and for saving.
    func flow(_ flow: PokerFlow, didFinishHand summary: PokerHandSummary)
    /// The tournament is over for the player — shown once the last hand has
    /// played out and been read. Place 1 is a win.
    func flow(_ flow: PokerFlow, tournamentOverWithPlace place: Int)
    /// The table has moved on in a way a relaunch must not undo — a new deal,
    /// the player's own action — so it should be saved now.
    func flowReachedCheckpoint(_ flow: PokerFlow)
}

extension PokerFlowDelegate {
    func flowReachedCheckpoint(_ flow: PokerFlow) {}
}

/// Something the player asked for before their turn came.
enum PokerPreAction: Equatable {
    /// Check if it is free when the turn comes, otherwise fold.
    case checkFold
}

@MainActor
final class PokerFlow {

    enum Stage: Equatable {
        /// No table yet.
        case idle
        /// Cards and chips are moving; nobody is being waited for.
        case playing
        /// The player's turn: the flow waits for `act(_:)`.
        case humanTurn
        /// A computer player is making up its mind.
        case botThinking(Int)
        /// A hand is over; the next is dealt by itself after a pause, or on
        /// `dealNextHand()`.
        case betweenHands
        /// The tournament is over for the player.
        case finished
    }

    private(set) var table: PokerTable
    private(set) var stage: Stage = .idle
    let scheduler: TableScheduler
    weak var view: PokerTableView?
    weak var delegate: PokerFlowDelegate?
    var decider: PokerDecider
    /// The bots' pace. Changeable during a game.
    var speed: PokerSpeed = .normal
    /// The player's seat is played by the bots too: tests and demos.
    var autopilot = false
    /// Stop dealing by itself after this many hands of this flow (tests).
    var handLimit: Int?
    /// Checked before the player's turn comes; cleared when used and when a
    /// new hand starts.
    var preAction: PokerPreAction? {
        didSet { if preAction != oldValue { delegate?.flowDidChangeState(self) } }
    }
    /// A cash-game top-up asked for during a hand, made before the next one.
    private(set) var pendingTopUp = false
    private(set) var handsDealt = 0

    private var generation = 0
    private var autoDeal: TableScheduler.Token?

    init(table: PokerTable, scheduler: TableScheduler, decider: PokerDecider) {
        self.table = table
        self.scheduler = scheduler
        self.decider = decider
        self.speed = table.config.speed
    }

    // MARK: Reading

    var humanSeat: Int? { table.humanSeat }

    /// The player is not in this hand (folded, or out of chips), so the rest
    /// of it can hurry.
    var humanIsSittingOut: Bool {
        guard let seat = table.humanSeat, let p = table.players[safe: seat] else { return true }
        return !p.isInHand
    }

    var pace: PokerPace {
        PokerPace(speed: speed, hurried: humanIsSittingOut, moves: Motion.isEnabled)
    }

    /// A cash-game top-up would add chips (now, or before the next hand).
    var canTopUp: Bool {
        guard table.config.mode == .cash, !pendingTopUp, let seat = table.humanSeat,
              let p = table.players[safe: seat] else { return false }
        return p.stack < PokerTableConfig.cashStack
    }

    // MARK: Starting

    /// Sits down at `table`: a new game (dealt at once when `dealNow`) or
    /// one resumed from disk (which waits for the player to deal). With
    /// `frozen`, nothing starts by itself — a screenshot's still life.
    func start(_ table: PokerTable, dealNow: Bool, frozen: Bool = false) {
        cancelPending()
        self.table = table
        preAction = nil
        pendingTopUp = false
        handsDealt = 0
        stage = .idle
        view?.show(PokerScene(table: table))
        if frozen {
            stage = stageForFrozenTable()
            var thinking: Int?
            if case .botThinking(let seat) = stage { thinking = seat }
            view?.setTurn(toAct: table.phase == .betting ? table.toAct : nil, thinking: thinking)
            delegate?.flowDidChangeState(self)
            return
        }
        if dealNow && table.phase == .betweenHands && table.humanPlace == nil {
            // The first deal is a breath away: nothing to offer the player
            // meanwhile (a "Deal" button that vanishes as it appears).
            stage = .playing
            delegate?.flowDidChangeState(self)
            later(0.35) { [weak self] in self?.deal() }
            return
        }
        proceed(autoDeal: false)
    }

    /// Drops everything scheduled or being thought about.
    func cancelPending() {
        generation += 1
        decider.cancel()
        scheduler.cancelAll()
        autoDeal = nil
    }

    private func stageForFrozenTable() -> Stage {
        switch table.phase {
        case .betting:
            guard let seat = table.toAct else { return .playing }
            return table.players[seat].isHuman && !autopilot ? .humanTurn : .botThinking(seat)
        case .betweenHands: return table.humanPlace != nil ? .finished : .betweenHands
        case .gameOver: return .finished
        case .streetComplete: return .playing
        }
    }

    // MARK: The player

    /// The player's action. False, with nothing changed, unless it is the
    /// player's turn and the action is legal.
    @discardableResult
    func act(_ action: PokerAction) -> Bool {
        guard stage == .humanTurn, table.isHumanToAct, table.isLegal(action) else { return false }
        let done = perform(action)
        if done { delegate?.flowReachedCheckpoint(self) }
        return done
    }

    /// Deals the next hand now, rather than after the pause.
    func dealNextHand() {
        guard stage == .betweenHands else { return }
        deal()
    }

    private func deal() {
        guard table.phase == .betweenHands, table.humanPlace == nil else { return }
        if let autoDeal { scheduler.cancel(autoDeal) }
        autoDeal = nil
        var events: [PokerEvent] = []
        if pendingTopUp, let seat = table.humanSeat {
            events += table.topUp(seat: seat)
            pendingTopUp = false
        }
        preAction = nil
        events += table.startHand()
        if table.phase == .gameOver {
            proceed(autoDeal: false)
            return
        }
        // Saved with its deck the moment it is dealt: quitting now and coming
        // back finds these same cards mid-hand, not a fresh deal of them.
        delegate?.flowReachedCheckpoint(self)
        handsDealt += 1
        stage = .playing
        delegate?.flowDidChangeState(self)
        let duration = present(events)
        later(duration) { [weak self] in self?.proceed() }
    }

    /// Cash game: back up to a full stack — now if between hands, otherwise
    /// before the next hand.
    func topUp() {
        guard canTopUp, let seat = table.humanSeat else { return }
        if table.phase == .betweenHands {
            let events = table.topUp(seat: seat)
            _ = present(events)
        } else {
            pendingTopUp = true
        }
        delegate?.flowDidChangeState(self)
    }

    // MARK: The loop

    private func proceed(autoDeal allowAutoDeal: Bool = true) {
        switch table.phase {
        case .betweenHands:
            if table.config.mode == .tournament, let place = table.humanPlace {
                finish(place: place)
                return
            }
            stage = .betweenHands
            view?.setTurn(toAct: nil, thinking: nil)
            delegate?.flowDidChangeState(self)
            let limitReached = handLimit.map { handsDealt >= $0 } ?? false
            if allowAutoDeal && !limitReached {
                let g = generation
                autoDeal = scheduler.after(pace.resultHold) { [weak self] in
                    guard let self, self.generation == g else { return }
                    self.autoDeal = nil
                    self.dealNextHand()
                }
            }

        case .gameOver:
            finish(place: table.humanPlace ?? 1)

        case .betting:
            guard let seat = table.toAct else { return }
            if table.players[seat].isHuman && !autopilot {
                if preAction == .checkFold, let o = table.options() {
                    // The box ticked in advance answers for the player, after
                    // the briefest beat so it can be seen to happen.
                    preAction = nil
                    stage = .playing
                    later(0.25) { [weak self] in _ = self?.perform(o.canCheck ? .check : .fold) }
                    return
                }
                stage = .humanTurn
                view?.setTurn(toAct: seat, thinking: nil)
                delegate?.flowDidChangeState(self)
            } else {
                think(for: seat)
            }

        case .streetComplete:
            stage = .playing
            delegate?.flowDidChangeState(self)
            later(pace.hurried ? 0.08 : 0.22) { [weak self] in self?.advanceStreet() }
        }
    }

    private func think(for seat: Int) {
        stage = .botThinking(seat)
        view?.setTurn(toAct: seat, thinking: seat)
        delegate?.flowDidChangeState(self)
        let asked = table
        let started = CACurrentMediaTime()
        let g = generation
        decider.decide(asked, seat: seat) { [weak self] decision in
            guard let self, self.generation == g, self.table == asked else { return }
            let pause = self.scheduler.isImmediate ? 0
                : max(0, self.pace.thinking(deliberation: decision.deliberation, jitter: self.jitter(seat))
                      - (CACurrentMediaTime() - started))
            self.later(pause) { [weak self] in
                guard let self, self.table == asked else { return }
                // The engine is the referee; a bot that ever proposed
                // something illegal would check or call instead.
                let action = self.table.isLegal(decision.action) ? decision.action
                    : (self.table.options()?.passiveAction ?? .fold)
                _ = self.perform(action)
            }
        }
    }

    @discardableResult
    private func perform(_ action: PokerAction) -> Bool {
        guard let events = try? table.apply(action) else { return false }
        stage = .playing
        view?.setTurn(toAct: nil, thinking: nil)
        delegate?.flowDidChangeState(self)
        let duration = present(events)
        later(duration) { [weak self] in self?.proceed() }
        return true
    }

    private func advanceStreet() {
        guard table.phase == .streetComplete else { return proceed() }
        let events = table.advance()
        let duration = present(events)
        for case .handEnded(let summary) in events {
            delegate?.flow(self, didFinishHand: summary)
        }
        let hold = scheduler.isImmediate ? 0 : Self.finalHold(after: table, pace: pace)
        later(duration + hold) { [weak self] in self?.proceed() }
    }

    /// How long the hand just paid stays on the table before the flow moves
    /// on, beyond its own choreography: nothing, usually — the next deal
    /// waits the result's hold anyway — but the hand that decides the
    /// tournament for the player (their last, or the one that wins it) is
    /// followed by the banner, which clears the table; so it stays long
    /// enough for its result to be read first.
    static func finalHold(after table: PokerTable, pace: PokerPace) -> TimeInterval {
        guard table.isAtHandBoundary else { return 0 }
        let decided = table.phase == .gameOver || (table.config.mode == .tournament && table.humanPlace != nil)
        return decided ? max(2.6, pace.resultHold) : 0
    }

    private func finish(place: Int) {
        guard stage != .finished else { return }
        stage = .finished
        view?.setTurn(toAct: nil, thinking: nil)
        delegate?.flowDidChangeState(self)
        delegate?.flow(self, tournamentOverWithPlace: place)
    }

    // MARK: Plumbing

    private func present(_ events: [PokerEvent]) -> TimeInterval {
        guard let view else { return 0 }
        return view.play(events, settlingOn: table, pace: pace)
    }

    private func later(_ delay: TimeInterval, _ block: @escaping () -> Void) {
        let g = generation
        scheduler.after(delay) { [weak self] in
            guard let self, self.generation == g else { return }
            block()
        }
    }

    /// A little unevenness in how long a bot takes, the same every time the
    /// same moment comes round.
    private func jitter(_ seat: Int) -> Double {
        var rng = DeterministicRNG(seed: table.seed ^ UInt64(table.handNumber &* 7919 &+ table.handLog.count &* 31 &+ seat))
        return Double(rng.next(upperBound: 1_000)) / 1_000
    }
}
