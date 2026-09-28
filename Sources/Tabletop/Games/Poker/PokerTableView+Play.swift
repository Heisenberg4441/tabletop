//
//  PokerTableView+Play.swift
//  The engine's events, played out on the table: the deal going round, a
//  bet sliding out from a seat, the bets gathered into the pot, the board
//  dealt, the hands turned up, the winning five lifted and the pot pushed to
//  the winner.
//
//  The engine has already finished when this starts — every call leaves the
//  table final and hands back what happened, in order. Each event becomes a
//  step on the table's scheduler at a running time; each step changes the
//  scene on screen and lets `transition` animate the difference. So a
//  sequence pauses when the game goes to the background (the scheduler is
//  suspended), a new game drops it (`cancelAll()`), a screenshot sees it
//  land at once (immediate mode), and a resize in the middle of it shows the
//  steps played so far and nothing else. The last step settles on the
//  engine's own picture, `PokerScene(table:)`, so the table can never drift
//  from the rules.
//
//  Chips in the air are decoration: `ChipFlight` flies them, and a separate
//  step at the moment they land changes the amounts, rather than a flight's
//  completion — which the compositor may never deliver for a window that is
//  not being drawn.
//

import AppKit

/// How long things take at the table, for the pace the player chose and for
/// a hand the player is no longer in (then everything hurries).
struct PokerPace: Equatable {
    var speed: PokerSpeed = .normal
    /// The player has folded or is out: the rest of the hand plays itself
    /// out briskly.
    var hurried = false
    /// Things fly (false under Reduce Motion, in tests and in screenshots:
    /// then they simply arrive, and only the pauses keep the rhythm).
    var moves = true

    private var fast: Bool { speed == .fast }

    var dealStagger: Double { hurried ? 0.045 : (fast ? 0.06 : 0.08) }
    var cardMove: Double { moves ? Motion.cardMove : 0 }
    var cardFlip: Double { moves ? Motion.cardFlip : 0 }
    var chipFlight: Double { moves ? (hurried || fast ? 0.34 : Motion.chipFlight) : 0 }
    /// After an action lands, before the next player starts to think.
    var actionBeat: Double { hurried ? 0.08 : (fast ? 0.16 : 0.28) }
    /// After the bets are gathered, before the next card comes.
    var streetBeat: Double { hurried ? 0.18 : (fast ? 0.28 : 0.42) }
    /// Between streets of an all-in runout — the moment everyone watches.
    var runoutPause: Double { hurried ? 0.45 : (fast ? 0.8 : 1.25) }
    var revealBeat: Double { hurried ? 0.3 : (fast ? 0.45 : 0.7) }
    /// The hands are up; a breath before the pot moves.
    var showdownBeat: Double { hurried ? 0.4 : (fast ? 0.6 : 0.95) }
    var awardBeat: Double { hurried ? 0.3 : (fast ? 0.45 : 0.65) }
    /// How long the result stays before the next hand is dealt by itself.
    var resultHold: Double { hurried ? 1.9 : (fast ? 2.3 : 3.4) }

    /// A computer player's pause for thought: the difficulty of the decision
    /// (0…1) sets it, a little jitter (0…1) keeps it from being metronomic.
    func thinking(deliberation: Double, jitter: Double) -> Double {
        let base = hurried ? 0.14 + 0.22 * deliberation : speed.thinkingTime(deliberation: deliberation)
        return base * (0.88 + 0.24 * max(0, min(1, jitter)))
    }
}

extension PokerTableView {

    /// Plays `events` — what took the engine from the table on screen to
    /// `table` — and returns how many seconds it takes. The caller's next
    /// step belongs after that, on the same scheduler.
    @discardableResult
    func play(_ events: [PokerEvent], settlingOn table: PokerTable, pace: PokerPace) -> TimeInterval {
        guard let layout = layoutModel else {
            show(PokerScene(table: table))
            return 0
        }
        var t: TimeInterval = 0
        func at(_ time: TimeInterval, _ block: @escaping (PokerTableView) -> Void) {
            scheduler.after(time) { [weak self] in
                guard let self else { return }
                block(self)
            }
        }
        let flight = pace.chipFlight
        let move = pace.cardMove
        let betChip = layout.betChipDiameter
        let potChip = layout.potChipDiameter
        // An all-in runout: the hands are already up.
        var runout = scene.seats.contains { $0.revealed }
        var awardsPlayed = false

        for event in events {
            switch event {
            case .blindsRaised(_, let blinds):
                at(t) { view in
                    Toast.show(String(format: NSLocalizedString("Blinds up · %1$@/%2$@",
                                                                comment: "poker toast: the blinds rise, e.g. Blinds up · 25/50"),
                                      Chips.format(blinds.smallBlind), Chips.format(blinds.bigBlind)),
                               symbolName: "arrow.up.circle", in: view, placement: .top, duration: 2.4)
                }

            case .rebought(let seat, let amount):
                at(t) { view in
                    view.step(0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].stack += amount
                        s.seats[seat].status = .active
                    }
                    if table.players[safe: seat]?.isHuman == true {
                        Toast.show(String(format: NSLocalizedString("You bought in for %@", comment: "poker toast: the player topped up"),
                                          Chips.format(amount)),
                                   symbolName: "plus.circle", in: view, placement: .top, duration: 2.2)
                    }
                }

            case .handStarted(_, let button):
                let hadCards = !scene.board.isEmpty || scene.seats.contains { !$0.cards.isEmpty } || scene.result != nil
                at(t) { view in
                    view.transition(to: Self.freshHand(table: table, button: view.scene.button ?? button),
                                    duration: move, muckDuration: move * 1.2)
                    if hadCards { Sound.play(.slide) }
                }
                t += hadCards ? move + 0.2 : 0.05
                if scene.button != button {
                    at(t) { view in view.step(Motion.relaxed) { $0.button = button } }
                    t += scene.button == nil ? 0.1 : Motion.relaxed * 0.8
                }

            case .acted(let record):
                let seat = record.seat
                let blind = record.kind == .smallBlind || record.kind == .bigBlind
                at(t) { view in
                    if record.added > 0 {
                        ChipFlight.fly(amount: record.added, from: view.seatPoint(seat), to: view.betPoint(seat),
                                       in: view.tableLayer, chipDiameter: betChip, duration: flight)
                    }
                    view.step(record.kind == .fold ? move : 0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].stack -= record.added
                        if record.isAllIn { s.seats[seat].status = .allIn }
                        if record.kind == .fold {
                            s.seats[seat].status = .folded
                            s.seats[seat].cards = []
                            if s.seats[seat].isHuman { s.humanHand = nil }
                        }
                        if !blind { s.seats[seat].caption = record.caption }
                        s.toAct = nil
                        s.thinking = nil
                    }
                    if record.kind == .fold { Sound.play(.slide) }
                }
                at(t + (record.added > 0 ? flight : 0)) { view in
                    view.step(0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].bet = record.total
                    }
                }
                if record.kind == .fold {
                    // "Fold" is said and then goes: the dimmed seat says it
                    // from then on.
                    at(t + 1.4) { view in
                        view.step(0) { s in
                            guard s.seats.indices.contains(seat), s.seats[seat].status == .folded else { return }
                            s.seats[seat].caption = nil
                        }
                    }
                }
                if blind {
                    t += 0.16
                } else {
                    t += (record.added > 0 ? flight : max(move, 0.2)) + pace.actionBeat
                }

            case .dealtHoleCards(let order):
                let stagger = pace.dealStagger
                at(t) { view in
                    var delays: [Int: CFTimeInterval] = [:]
                    var k = 0
                    for round in 0..<2 {
                        for seat in order {
                            delays[Self.holeID(seat: seat, card: round)] = Double(k) * stagger
                            k += 1
                        }
                    }
                    view.step(move, delays: delays) { s in
                        for seat in order where s.seats.indices.contains(seat) {
                            s.seats[seat].cards = table.players[seat].holeCards
                        }
                    }
                    Sound.play(.deal)
                }
                t += Double(max(0, order.count * 2 - 1)) * stagger + move + 0.1
                at(t) { view in
                    view.step(0) { s in
                        guard let human = table.humanSeat, s.seats.indices.contains(human) else { return }
                        s.humanHand = PokerScene.handDescription(s.seats[human].cards, board: s.board)
                    }
                }
                t += 0.15

            case .bettingRoundEnded:
                t += 0.1

            case .uncalledBetReturned(let seat, let amount):
                at(t) { view in
                    ChipFlight.fly(amount: amount, from: view.betPoint(seat), to: view.seatPoint(seat),
                                   in: view.tableLayer, chipDiameter: betChip, duration: flight)
                    view.step(0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].bet = max(0, s.seats[seat].bet - amount)
                    }
                }
                at(t + flight) { view in
                    view.step(0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].stack += amount
                        if s.seats[seat].status == .allIn { s.seats[seat].status = .active }
                    }
                }
                t += flight + 0.05

            case .betsCollected(let pots):
                // The flow waits for each batch to finish before the next
                // call, so the bets on screen now are the ones to gather.
                let anyBets = scene.seats.contains { $0.bet > 0 }
                at(t) { view in
                    let target = view.layoutModel?.pot ?? view.geometry.center
                    for (seat, s) in view.scene.seats.enumerated() where s.bet > 0 {
                        ChipFlight.fly(amount: s.bet, from: view.betPoint(seat), to: target, in: view.tableLayer,
                                       chipDiameter: potChip, duration: flight)
                    }
                    view.step(0) { s in
                        for i in s.seats.indices {
                            s.seats[i].bet = 0
                            s.seats[i].caption = nil
                        }
                    }
                }
                at(t + (anyBets ? flight : 0)) { view in
                    view.step(0.2) { $0.pots = pots.map(\.amount) }
                }
                t += (anyBets ? flight : 0) + pace.streetBeat

            case .handsRevealed(let shown):
                runout = true
                at(t) { view in
                    view.step(pace.cardFlip + 0.06) { s in
                        for hand in shown where s.seats.indices.contains(hand.seat) {
                            s.seats[hand.seat].cards = hand.holeCards
                            s.seats[hand.seat].faceUp = true
                            s.seats[hand.seat].revealed = !s.seats[hand.seat].isHuman
                        }
                    }
                    Sound.play(.flip)
                }
                t += pace.cardFlip + pace.revealBeat

            case .dealtCommunity(_, let cards):
                let stagger = 0.11
                at(t) { view in
                    let start = view.scene.board.count
                    var delays: [Int: CFTimeInterval] = [:]
                    for i in cards.indices { delays[Self.boardID(start + i)] = Double(i) * stagger }
                    view.step(move, delays: delays) { $0.board += cards }
                    Sound.play(.place)
                }
                t += move + Double(max(0, cards.count - 1)) * stagger + 0.08
                at(t) { view in
                    view.step(0) { s in
                        guard let human = table.humanSeat, s.seats.indices.contains(human) else { return }
                        s.humanHand = PokerScene.handDescription(s.seats[human].cards, board: s.board)
                    }
                }
                t += runout ? pace.runoutPause : 0.1

            case .showdown(let shown):
                let newlyShown = shown.filter { hand in !(scene.seats[safe: hand.seat]?.faceUp ?? false) }
                at(t) { view in
                    view.step(pace.cardFlip + 0.06) { s in
                        for hand in shown where s.seats.indices.contains(hand.seat) {
                            s.seats[hand.seat].cards = hand.holeCards
                            s.seats[hand.seat].faceUp = true
                            s.seats[hand.seat].revealed = !s.seats[hand.seat].isHuman
                            if !s.seats[hand.seat].isHuman { s.seats[hand.seat].handName = hand.result?.name }
                        }
                    }
                    if !newlyShown.isEmpty { Sound.play(.flip) }
                }
                t += (newlyShown.isEmpty ? 0.2 : pace.cardFlip) + pace.showdownBeat

            case .potAwarded:
                guard !awardsPlayed else { continue }
                awardsPlayed = true
                guard let summary = events.lazy.compactMap({ e -> PokerHandSummary? in
                    if case .handEnded(let s) = e { return s }
                    return nil
                }).first else { continue }
                for award in PokerScene.payoutOrder(summary) {
                    at(t) { view in
                        let from = view.potPoint(award.potIndex)
                        for share in award.shares {
                            ChipFlight.fly(amount: share.amount, from: from, to: view.seatPoint(share.seat),
                                           in: view.tableLayer, chipDiameter: potChip, duration: flight,
                                           maximumChips: 8)
                        }
                        view.step(Motion.standard) { s in
                            if let hand = award.hand {
                                s.highlight = Set(hand.cards)
                                s.dimsOthers = true
                            }
                            if s.pots.indices.contains(award.potIndex) { s.pots[award.potIndex] = 0 }
                            for share in award.shares where s.seats.indices.contains(share.seat) {
                                s.seats[share.seat].isWinner = true
                            }
                        }
                    }
                    at(t + flight) { view in
                        view.step(0) { s in
                            for share in award.shares where s.seats.indices.contains(share.seat) {
                                s.seats[share.seat].stack += share.amount
                            }
                        }
                    }
                    t += flight + pace.awardBeat
                }

            case .handEnded:
                at(t) { view in
                    let settled = PokerScene(table: table)
                    view.step(Motion.standard) { s in
                        s.result = settled.result
                        s.humanHand = settled.humanHand
                        s.humanHandIsWinner = settled.humanHandIsWinner
                    }
                }

            case .eliminated(let seat, let place):
                at(t) { view in
                    view.step(0) { s in
                        guard s.seats.indices.contains(seat) else { return }
                        s.seats[seat].status = .out
                        s.seats[seat].place = place
                    }
                }

            case .tournamentEnded:
                break
            }
        }
        // Settle on the engine's own picture of the table. A computer player
        // whose turn it now is comes up already thinking — the flow asks it
        // in the same moment — rather than flashing the player's "your turn"
        // ring for a frame first.
        at(t) { view in
            var settled = PokerScene(table: table)
            if let seat = settled.toAct, table.players[safe: seat]?.isHuman == false { settled.thinking = seat }
            view.transition(to: settled, duration: 0)
        }
        return t
    }

    /// Changes the scene on screen with `change` and animates the difference.
    func step(_ duration: CFTimeInterval, delays: [Int: CFTimeInterval] = [:],
              _ change: (inout PokerScene) -> Void) {
        var s = scene
        change(&s)
        transition(to: s, duration: duration, delays: delays)
    }

    /// Marks whose turn it is and who is thinking, straight away.
    func setTurn(toAct: Int?, thinking: Int?) {
        guard scene.toAct != toAct || scene.thinking != thinking else { return }
        step(0) { s in
            s.toAct = toAct
            s.thinking = thinking
        }
    }

    /// The table cleared for a new hand: last hand's cards and words gone,
    /// every stack as it stood before the blinds, the button where it was.
    static func freshHand(table: PokerTable, button: Int?) -> PokerScene {
        var s = PokerScene.empty
        s.button = button
        s.seats = table.players.map { p in
            PokerSeatScene(name: p.name, isHuman: p.isHuman, stack: p.stackAtHandStart, bet: 0, cards: [],
                           faceUp: p.isHuman, revealed: false, status: p.stackAtHandStart > 0 ? .active : .out,
                           isWinner: false, place: p.place, caption: nil, handName: nil)
        }
        return s
    }
}
