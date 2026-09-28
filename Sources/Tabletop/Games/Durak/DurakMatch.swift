//
//  DurakMatch.swift
//  The game's clock: who decides next, when a computer player makes up its
//  mind, and the pause while the table shows what just happened.
//
//  The engine always names exactly one seat whose decision it is. This turns
//  that into a game played at a human pace:
//
//    1. An action is applied — the player's, or a bot's — and the engine's
//       events are handed to the view to show, one after another.
//    2. When the view has shown them, the next decision is looked at. The
//       player's: wait for a click. A bot's: it "thinks" — a pause of half a
//       second to a little over one (`DurakBot.thinkingDelay`), with the
//       decision itself worked out off the main thread meanwhile (Hard's
//       endgame search can take a few milliseconds). Only when both the
//       pause is over and the answer is in is the move made, so bots act one
//       at a time, never in the same instant.
//
//  Everything waits on the table's `TableScheduler`, which the game suspends
//  when it leaves the screen; and the match can be held — the game gone to
//  the library, or the New Game card up over the table — in which case a
//  decision that arrives is kept, and made when the hold is released. A new
//  game bumps a generation number, so an answer still being worked out for
//  the old one is thrown away when it arrives.
//

import Foundation

@MainActor
final class DurakMatch {

    /// Why the match is standing still.
    enum Hold: Hashable {
        /// The game is not the active screen of a key, visible window.
        case inactive
        /// The New Game card (or another modal piece of chrome) is up.
        case modal
    }

    /// The seat whose cards are on the screen face up: the player.
    nonisolated static let human = 0

    private(set) var state: DurakState?
    var difficulty: DurakDifficulty

    /// Shows events, then calls back. The view's `present`.
    var present: (([DurakEvent], DurakState, @escaping () -> Void) -> Void)?
    /// Something about whose turn it is changed: prompts, the bar, the
    /// seats' rings, saving. Called after every action and every change of
    /// thinking or presenting.
    var onChange: (() -> Void)?

    /// Work bots' decisions out on the calling thread instead of in the
    /// background — for the headless self-tests, which drive the scheduler by
    /// hand and have no run loop turning.
    var decidesInline = false

    /// Scales the bots' pauses for thought — 1 at the table; the self-tests
    /// that wait on the real clock shorten them.
    var thinkingPace: Double = 1

    private let scheduler: TableScheduler
    private(set) var holds: Set<Hold> = [.inactive]
    private(set) var isPresenting = false
    /// The bot making up its mind, if any.
    private(set) var thinkingSeat: Int?

    private var generation = 0
    private var pendingDecision: DurakAction?
    private var pauseOver = false

    init(scheduler: TableScheduler, difficulty: DurakDifficulty) {
        self.scheduler = scheduler
        self.difficulty = difficulty
    }

    // MARK: Reading

    /// The player may act: it is their decision, nothing is being shown and
    /// the match is not held for a modal card.
    var isAwaitingHuman: Bool {
        guard let state, !state.isOver, state.actor == Self.human else { return false }
        return !isPresenting && !holds.contains(.modal)
    }

    var isHeld: Bool { !holds.isEmpty }

    // MARK: Starting

    /// A new deal: its events are shown, then play begins.
    func begin(_ state: DurakState, events: [DurakEvent]) {
        reset()
        self.state = state
        isPresenting = true
        onChange?()
        let token = generation
        present?(events, state) { [weak self] in
            guard let self, self.generation == token else { return }
            self.isPresenting = false
            self.advance()
        }
    }

    /// A game restored from disk, already laid out: play carries on from
    /// where it stood.
    func resume(_ state: DurakState) {
        reset()
        self.state = state
        onChange?()
        advance()
    }

    /// Forgets the game on the table (nothing is dealt).
    func clear() {
        reset()
        state = nil
        onChange?()
    }

    private func reset() {
        generation += 1
        thinkingSeat = nil
        pendingDecision = nil
        pauseOver = false
        isPresenting = false
    }

    // MARK: Holding

    func hold(_ reason: Hold) {
        holds.insert(reason)
        onChange?()
    }

    /// Lets the match go on. A bot whose pause ran out during the hold moves
    /// a moment later, rather than the instant the table reappears.
    func release(_ reason: Hold) {
        guard holds.remove(reason) != nil else { return }
        onChange?()
        guard holds.isEmpty else { return }
        if thinkingSeat != nil {
            let token = generation
            scheduler.after(0.35 * thinkingPace) { [weak self] in
                guard let self, self.generation == token else { return }
                self.makePendingMove()
            }
        } else {
            advance()
        }
    }

    // MARK: Playing

    /// The player's decision. False, and nothing happens, if it is not theirs
    /// to make or not legal — a stale click is harmless.
    @discardableResult
    func play(_ action: DurakAction) -> Bool {
        guard isAwaitingHuman else { return false }
        return apply(action, by: Self.human)
    }

    private func apply(_ action: DurakAction, by seat: Int) -> Bool {
        guard var next = state, let events = try? next.apply(action, by: seat) else { return false }
        state = next
        isPresenting = true
        onChange?()
        let token = generation
        present?(events, next) { [weak self] in
            guard let self, self.generation == token else { return }
            self.isPresenting = false
            self.advance()
        }
        return true
    }

    /// Looks at whose decision it is now and gets it made.
    private func advance() {
        guard let state, !isPresenting, holds.isEmpty, thinkingSeat == nil else {
            onChange?()
            return
        }
        guard !state.isOver, let actor = state.actor, actor != Self.human else {
            onChange?()
            return
        }
        think(actor, in: state)
    }

    /// A bot's turn: the pause and the answer, in parallel.
    private func think(_ seat: Int, in state: DurakState) {
        generation += 1
        let token = generation
        thinkingSeat = seat
        pendingDecision = nil
        pauseOver = false
        onChange?()

        // Once the player is out they are only watching the others finish:
        // the bots keep a human rhythm, but a brisker one.
        let watching = state.isOut(Self.human) ? 0.5 : 1
        scheduler.after(DurakBot.thinkingDelay(in: state, seat: seat) * thinkingPace * watching) { [weak self] in
            guard let self, self.generation == token else { return }
            self.pauseOver = true
            self.makePendingMove()
        }
        let bot = DurakBot(difficulty)
        if decidesInline {
            decided(bot.decide(in: state, seat: seat), token: token)
        } else {
            Task { @MainActor [weak self] in
                let action = await Task.detached(priority: .userInitiated) {
                    bot.decide(in: state, seat: seat)
                }.value
                self?.decided(action, token: token)
            }
        }
    }

    private func decided(_ action: DurakAction, token: Int) {
        guard generation == token else { return }
        pendingDecision = action
        makePendingMove()
    }

    /// Moves once the pause is over, the answer is in and nothing holds the
    /// match.
    private func makePendingMove() {
        guard pauseOver, holds.isEmpty, let seat = thinkingSeat, let action = pendingDecision,
              let state else { return }
        thinkingSeat = nil
        pendingDecision = nil
        pauseOver = false
        if apply(action, by: seat) { return }
        // A bot never proposes an illegal move (the self-tests play thousands
        // of games to make sure); if one ever did, it takes the first legal
        // one rather than freezing the table.
        if let fallback = state.legalActions(for: seat).first, apply(fallback, by: seat) { return }
        onChange?()
    }
}
