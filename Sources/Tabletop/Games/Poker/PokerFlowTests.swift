//
//  PokerFlowTests.swift
//  The presentation's checks: the table's geometry at every size and player
//  count, the scenes the scenarios make, and whole games played through
//  `PokerFlow` — the loop the player plays — with the bots in every seat, no
//  animation and an immediate scheduler, with and without a table view
//  watching. Then the edges: the player's buttons and keys, a bot's pause
//  held while the game is away, a decision that arrives too late, saving and
//  the record.
//

import AppKit

/// A decider the test answers by hand: the flow waits on it exactly as it
/// waits on the background worker.
@MainActor
final class PokerManualDecider: PokerDecider {
    private(set) var pending: (table: PokerTable, seat: Int, completion: (PokerBotDecision) -> Void)?
    private(set) var asked = 0

    func decide(_ table: PokerTable, seat: Int, completion: @escaping (PokerBotDecision) -> Void) {
        asked += 1
        pending = (table, seat, completion)
    }

    func cancel() { pending = nil }

    /// Answers the question waiting, as the bot would.
    func answer(samples: Int = 30) {
        guard let pending else { return }
        self.pending = nil
        pending.completion(PokerBot.decide(table: pending.table, seat: pending.seat, samples: samples))
    }
}

/// Watches a flow the way the game does, and keeps score.
@MainActor
final class PokerFlowRecorder: PokerFlowDelegate {
    var hands = 0
    var places: [Int] = []
    var chipsAlwaysAddUp = true
    var stateChanges = 0
    /// Run between hands, once the hand has played out, with the flow.
    var onHand: ((PokerFlow) -> Void)?

    func flowDidChangeState(_ flow: PokerFlow) {
        stateChanges += 1
        // Between hands, once the last hand has played out on the table.
        if flow.stage == .betweenHands || flow.stage == .finished, flow.table.lastSummary != nil,
           flow.table.handNumber != lastBoundary {
            lastBoundary = flow.table.handNumber
            onHand?(flow)
        }
    }
    private var lastBoundary = -1

    func flow(_ flow: PokerFlow, didFinishHand summary: PokerHandSummary) {
        hands += 1
        if flow.table.chipsOnTable != flow.table.chipsBoughtIn || !flow.table.isConsistent { chipsAlwaysAddUp = false }
    }

    func flow(_ flow: PokerFlow, tournamentOverWithPlace place: Int) { places.append(place) }
}

@MainActor
enum PokerFlowTests {

    static func run(_ t: TestReporter) {
        if let hands = TabletopEnvironment.value(of: "--poker-live").flatMap(Int.init) {
            live(t, hands: hands)
            return
        }
        let savedOverride = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = savedOverride }

        layout(t)
        scenes(t)
        headlessGames(t)
        withTableView(t)
        playerTurn(t)
        waitingAndPreActions(t)
        pausing(t)
        backgroundWorker(t)
        controller(t)
    }

    // MARK: Live

    /// `--selftest poker --poker-live`: a few hands in real time, animated,
    /// in a window that is never shown — the paths the quick tests skip
    /// (cards in flight, chips in the air, deals that wait their turn). Too
    /// slow for every run.
    static func live(_ t: TestReporter, hands: Int) {
        t.section("Poker — live, animated, in real time")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = saved }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = PokerTableView()
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 3, speed: .fast), seed: 2_024)
        let flow = PokerFlow(table: table, scheduler: view.scheduler, decider: PokerWorkerDecider())
        let recorder = PokerFlowRecorder()
        flow.delegate = recorder
        flow.view = view
        flow.autopilot = true
        flow.speed = .fast
        flow.handLimit = hands
        var settled = true
        recorder.onHand = { flow in
            if view.scene != PokerScene(table: flow.table) { settled = false }
        }
        let started = Date()
        flow.start(table, dealNow: true)
        let deadline = Date().addingTimeInterval(Double(hands) * 25)
        while !(flow.stage == .betweenHands && flow.handsDealt == hands) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // Let the last flights land.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        t.check("\(hands) hands play out in real time (\(recorder.hands))", recorder.hands == hands)
        t.check("…each ends on exactly the engine's picture", settled && view.scene == PokerScene(table: flow.table))
        let cards = view.scene.board.count + view.scene.seats.reduce(0) { $0 + $1.cards.count }
        t.check("…with one card on the table for every card in play", view.spriteIDs.count == cards)
        t.info(String(format: "%.1f s", Date().timeIntervalSince(started)))
        flow.cancelPending()
        window.contentView = nil
    }

    // MARK: Geometry

    static func layout(_ t: TestReporter) {
        t.section("Poker — the table at every size")
        let sizes = [CGSize(width: 960, height: 640), CGSize(width: 1200, height: 800), CGSize(width: 1440, height: 900),
                     CGSize(width: 1728, height: 1080), CGSize(width: 1000, height: 900), CGSize(width: 2200, height: 1200)]
        // The seats themselves: in the window, clear of the bar and of each
        // other.
        var problems: [String] = []
        for size in sizes {
            let view = PokerTableView()
            view.frame = CGRect(origin: .zero, size: size)
            for count in 2...6 {
                view.show(Self.scene(seats: count))
                view.layoutSubtreeIfNeeded()
                guard let l = view.layoutModel else { problems.append("\(size) no layout"); continue }
                let tag = "\(Int(size.width))×\(Int(size.height)) \(count)p"
                let top = TabletopChrome.minimumTopInset
                let barTop = size.height - view.actionBar.reservedHeight + Spacing.m
                for (i, spot) in l.spots.enumerated() {
                    if spot.seatFrame.minY < top - 0.5 { problems.append("\(tag) seat \(i) in the window strip") }
                    if spot.seatFrame.maxY > barTop + 0.5 { problems.append("\(tag) seat \(i) under the bar") }
                    if spot.seatFrame.minX < 0 || spot.seatFrame.maxX > size.width { problems.append("\(tag) seat \(i) off the side") }
                    for (j, other) in l.spots.enumerated() where j > i && spot.seatFrame.intersects(other.seatFrame) {
                        problems.append("\(tag) seats \(i) and \(j) overlap")
                    }
                    if !l.geometry.contains(spot.bet, inset: l.geometry.railWidth * 1.2) {
                        problems.append("\(tag) seat \(i)'s bet off the cloth")
                    }
                    if i > 0 && spot.revealedScale < l.opponentScale - 0.001 {
                        problems.append("\(tag) seat \(i)'s shown cards smaller than its hidden ones")
                    }
                }
                if l.pot.y >= TableLayout.bounds(of: l.board, cardSize: l.cardSize).minY {
                    problems.append("\(tag) the pot below the board")
                }
            }
        }
        t.check("at six window sizes and two to six players, the seats sit in the window, clear of each other \(problems.prefix(6))",
                problems.isEmpty)

        // Then everything on show, as drawn: the most crowded moment of each
        // kind for every player count — with the button at every seat at
        // once — and every screenshot scene: nothing on anything else.
        let started = ProcessInfo.processInfo.systemUptime
        var crowded: [String] = []
        var scenes: [String] = []
        let names = PokerGame.screenshotScenarios.filter { $0 != "new-game" }
        for size in sizes {
            let view = PokerTableView()
            view.frame = CGRect(origin: .zero, size: size)
            let tag = "\(Int(size.width))×\(Int(size.height))"
            func check(_ scene: PokerScene, _ what: String, everyButton: Bool = false, into list: inout [String]) {
                view.show(scene)
                view.layoutSubtreeIfNeeded()
                var prints = view.footprints()
                if everyButton, let l = view.layoutModel {
                    prints += l.spots.enumerated().map { i, spot in
                        PokerFootprint(kind: .dealer, owner: i,
                                       rect: PokerLayout.dealerRect(at: spot.dealer, diameter: l.dealerDiameter).insetBy(dx: 2, dy: 2))
                    }
                }
                for problem in PokerTableView.overlaps(in: prints) { list.append("\(tag) \(what): \(problem)") }
                let barTop = size.height - view.actionBar.reservedHeight
                for f in prints where f.kind != .seat && (f.rect.maxY > barTop || f.rect.minY < view.playBounds.minY
                                                         || f.rect.minX < 0 || f.rect.maxX > size.width) {
                    list.append("\(tag) \(what): \(f.kind.rawValue) \(f.owner ?? -1) off the table")
                }
            }
            for count in 2...6 {
                for moment in CrowdedMoment.allCases {
                    check(Self.crowdedScene(seats: count, moment: moment), "\(count)p \(moment)", everyButton: true,
                          into: &crowded)
                }
            }
            for name in names {
                guard let table = PokerGame.scenarioTable(name) else { continue }
                let settled = PokerScene(table: table)
                check(settled, name, into: &scenes)
                // A showdown a beat before the pot is pushed: the hands and
                // their names up, the pots still in the middle.
                if let summary = PokerScene.displayedSummary(table), !summary.shown.isEmpty {
                    var before = settled
                    before.pots = summary.awards.map(\.amount)
                    before.result = nil
                    before.highlight = []
                    before.dimsOthers = false
                    for i in before.seats.indices { before.seats[i].isWinner = false }
                    check(before, name + " before the push", into: &scenes)
                }
            }
        }
        t.check("the most crowded moments at every count, the button at every seat: nothing on anything else \(crowded.prefix(6))",
                crowded.isEmpty)
        if !crowded.isEmpty { t.info("\(crowded.count) overlaps in crowded scenes") }
        t.check("every screenshot scene at six sizes: nothing on anything else \(scenes.prefix(6))", scenes.isEmpty)
        if !scenes.isEmpty { t.info("\(scenes.count) overlaps in the screenshot scenes") }
        t.info(String(format: "%.1f s", ProcessInfo.processInfo.systemUptime - started))

        // Seats go round clockwise, evenly, with the player at the bottom.
        let view = PokerTableView()
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        view.show(scene(seats: 6))
        view.layoutSubtreeIfNeeded()
        if let l = view.layoutModel {
            let a = l.spots.map(\.avatar)
            t.check("six seats: the player at the bottom centre, seat 1 to their left and so on clockwise",
                    abs(a[0].x - 600) < 1 && a[1].x < a[0].x && a[1].y > a[2].y && a[3].y < a[2].y + 1
                        && abs(a[3].x - 600) < 1 && a[4].x > 600 && a[5].y > a[4].y)
            t.check("…balanced left to right", abs((a[1].x + a[5].x) / 2 - 600) < 1.5 && abs((a[2].x + a[4].x) / 2 - 600) < 1.5)
            // The seat across the table bets beside its cards, not onto the
            // pot; the two seats at an end push their chips apart.
            let across = l.spots[3]
            t.check("the seat across the table bets beside its cards, clear of the pot",
                    !PokerLayout.betRect(at: across.bet, chip: l.betChipDiameter).intersects(l.potBand))
            let upper = PokerLayout.betRect(at: l.spots[2].bet, chip: l.betChipDiameter)
            let lower = PokerLayout.betRect(at: l.spots[1].bet, chip: l.betChipDiameter)
            t.check("…and the two seats at the left end keep their bets apart (\(Int(lower.minY - upper.maxY)) pt)",
                    lower.minY - upper.maxY >= 12)
        }
    }

    enum CrowdedMoment: String, CaseIterable, CustomStringConvertible {
        /// Everyone's largest bet and caption out, the pots in the middle.
        case betting
        /// Everyone all in: the hands turned up over the pots.
        case runout
        /// The hands' names up, the pots not yet pushed.
        case beforePush
        /// The pot gone, the result in its place.
        case result

        var description: String { rawValue }
    }

    /// A table as full as it gets at `moment`: every seat in, with two cards,
    /// a bet of four stacks, the longest caption and hand name, several pots
    /// and the longest result — words the layout was not told. (No button:
    /// the check puts one at every seat.)
    static func crowdedScene(seats count: Int, moment: CrowdedMoment) -> PokerScene {
        var s = scene(seats: count)
        var deck = Card.full
        s.button = nil
        let shown = moment != .betting
        for i in s.seats.indices {
            s.seats[i].cards = [deck.removeFirst(), deck.removeFirst()]
            s.seats[i].faceUp = s.seats[i].isHuman || shown
            s.seats[i].revealed = shown && !s.seats[i].isHuman
            if moment == .betting {
                s.seats[i].bet = 1_480 + i * 1_111
                s.seats[i].caption = String(format: NSLocalizedString("Raise %@", comment: "poker caption: raised to, e.g. Raise 120"),
                                            Chips.format(12_345 + i))
            }
            if (moment == .beforePush || moment == .result) && !s.seats[i].isHuman {
                s.seats[i].handName = NSLocalizedString("Three of a Kind", comment: "poker hand category")
            }
        }
        s.board = Array(deck.prefix(moment == .betting || moment == .runout ? 3 : 5))
        switch moment {
        case .betting: s.pots = [4_440, 1_480]
        case .runout, .beforePush: s.pots = [8_880, 4_440, 2_220]
        case .result:
            // Every card among the winners, so every card is lifted.
            s.highlight = Set(s.seats.flatMap(\.cards) + s.board)
            s.dimsOthers = true
            s.result = PokerResultText(title: String(format: NSLocalizedString("Split pot of %@", comment: "poker banner: a pot split three or more ways"),
                                                     Chips.format(12_345)),
                                       subtitle: "Full House, Queens over Sevens", shortSubtitle: "Full House", humanWon: false)
        }
        s.humanHand = "Full House, Queens over Sevens"
        s.humanHandShort = NSLocalizedString("Full House", comment: "poker hand category")
        return s
    }

    private static func avatarBox(_ spot: PokerSeatSpot) -> CGRect {
        let r = SeatView.avatarSize / 2
        return CGRect(x: spot.avatar.x - r, y: spot.avatar.y - r, width: r * 2, height: r * 2)
    }

    /// A scene with `seats` players and nothing dealt.
    static func scene(seats: Int) -> PokerScene {
        PokerScene(table: PokerTable(config: PokerTableConfig(mode: .cash, opponents: seats - 1), seed: 3))
    }

    // MARK: Scenes

    static func scenes(_ t: TestReporter) {
        t.section("Poker — the screenshot tables")
        let all = PokerGame.screenshotScenarios
        t.check("every scenario builds a table (\(all.joined(separator: ", ")))",
                all.allSatisfy { PokerGame.scenarioTable($0) != nil })
        t.check("the five from the spec are there, preflop first",
                Array(all.prefix(5)) == ["preflop", "flop", "showdown", "sidepots", "headsup"])
        if let table = PokerGame.scenarioTable("preflop") {
            let s = PokerScene(table: table)
            t.check("preflop: six at the table and the player to act, a raise in front",
                    s.seats.count == 6 && s.toAct == 0 && s.seats.contains { $0.caption?.hasPrefix("Raise") ?? false }
                        && s.seats[0].cards.count == 2 && s.seats[0].faceUp)
        }
        if let table = PokerGame.scenarioTable("showdown") {
            let s = PokerScene(table: table)
            t.check("showdown: the winning five lifted, the rest dimmed, the result said and the player named winner",
                    s.highlight.count == 5 && s.dimsOthers && s.result?.humanWon == true && s.pots.isEmpty
                        && s.seats[0].isWinner && s.seats.contains { !$0.isHuman && $0.revealed && $0.handName != nil })
            t.check("…and the result reads like the spec (\(s.result?.title ?? "") — \(s.result?.subtitle ?? ""))",
                    s.result?.title.hasPrefix("You win") == true && s.result?.subtitle == "Flush, Ace high")
        }
        if let table = PokerGame.scenarioTable("sidepots") {
            let s = PokerScene(table: table)
            t.check("side pots: a main pot and a side pot, two players all-in", s.pots.count >= 2
                        && s.seats.filter { $0.status == .allIn }.count == 2)
            t.check("…labelled as such", PokerTableView.potTitle(index: 0, count: 2, amount: 480).hasPrefix("Main pot")
                        && PokerTableView.potTitle(index: 1, count: 2, amount: 90).hasPrefix("Side pot"))
        }
        if let table = PokerGame.scenarioTable("runout") {
            let s = PokerScene(table: table)
            t.check("runout: both hands turned up, the flop out", s.seats.filter(\.faceUp).count == 2 && s.board.count == 3
                        && s.seats.contains { $0.revealed })
        }
        if let table = PokerGame.scenarioTable("headsup") {
            t.check("heads-up: two seats, the player to act", table.players.count == 2 && table.isHumanToAct)
        }
        t.check("hand descriptions before the flop read naturally",
                PokerScene.handDescription(PokerNotation.cards("Ah Kh"), board: []) == "Ace–King suited"
                    && PokerScene.handDescription(PokerNotation.cards("7c 7d"), board: []) == "Pair of Sevens"
                    && PokerScene.handDescription(PokerNotation.cards("2c 9d"), board: []) == "Nine–Two offsuit")
    }

    // MARK: Whole games

    static func headlessFlow(_ table: PokerTable, samples: Int = 30) -> (PokerFlow, PokerFlowRecorder) {
        let flow = PokerFlow(table: table, scheduler: TableScheduler(immediate: true), decider: PokerDirectDecider(samples: samples))
        let recorder = PokerFlowRecorder()
        flow.delegate = recorder
        flow.autopilot = true
        return (flow, recorder)
    }

    static func headlessGames(_ t: TestReporter) {
        t.section("Poker — whole games through the flow the table plays")
        let started = ProcessInfo.processInfo.systemUptime
        var allEnded = true
        var placesRight = true
        var chipsRight = true
        var hands = 0
        var winners = 0
        for (i, opponents) in [5, 3, 1, 4].enumerated() {
            let table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: opponents), seed: 700 + UInt64(i))
            let (flow, recorder) = headlessFlow(table)
            flow.start(table, dealNow: true)
            allEnded = allEnded && flow.stage == .finished && recorder.places.count == 1
            let place = recorder.places.first ?? 0
            placesRight = placesRight && (1...(opponents + 1)).contains(place) && flow.table.humanPlace == place
            chipsRight = chipsRight && recorder.chipsAlwaysAddUp
            hands += recorder.hands
            if place == 1 { winners += 1 }
        }
        t.check("four tournaments (2, 4, 5 and 6 players) play to the end, the player's place told once", allEnded)
        t.check("…the place is a real one and matches the engine's", placesRight)
        t.check("…and every chip is accounted for after every hand", chipsRight)
        t.info("\(hands) hands, the player's seat on autopilot won \(winners) of 4, "
               + String(format: "%.2f s", ProcessInfo.processInfo.systemUptime - started))

        // A cash game goes on for as long as the player likes.
        let cash = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 811)
        let (flow, recorder) = headlessFlow(cash)
        flow.handLimit = 30
        flow.start(cash, dealNow: true)
        t.check("a cash game deals thirty hands and waits between them (\(recorder.hands) hands)",
                flow.stage == .betweenHands && flow.handsDealt == 30 && recorder.hands == 30 && recorder.chipsAlwaysAddUp)
        if flow.canTopUp {
            flow.topUp()
            t.check("topping up between hands brings the stack back to 1,000",
                    flow.table.players[0].stack == PokerTableConfig.cashStack && !flow.canTopUp)
        } else {
            t.check("the player is at a full stack or more, nothing to top up",
                    flow.table.players[0].stack >= PokerTableConfig.cashStack)
        }
        flow.dealNextHand()
        t.check("…and Deal Next Hand deals one more", flow.handsDealt == 31)
    }

    /// The same, with the table view playing every event out: after each
    /// hand, what is on the table is exactly what the engine says.
    static func withTableView(_ t: TestReporter) {
        t.section("Poker — the table view keeps up with the engine")
        let view = PokerTableView()
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        view.scheduler.isImmediate = true
        let table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: 912)
        let flow = PokerFlow(table: table, scheduler: view.scheduler, decider: PokerDirectDecider(samples: 30))
        let recorder = PokerFlowRecorder()
        flow.delegate = recorder
        flow.view = view
        flow.autopilot = true
        flow.handLimit = 14
        var settled = true
        var spritesMatch = true
        var resultShown = true
        var mismatch = ""
        recorder.onHand = { flow in
            let expected = PokerScene(table: flow.table)
            if view.scene != expected {
                settled = false
                if mismatch.isEmpty { mismatch = "hand \(flow.table.handNumber)" }
            }
            let cards = expected.board.count + expected.seats.reduce(0) { $0 + $1.cards.count }
            if view.spriteIDs.count != cards { spritesMatch = false }
            if (view.resultPill.text != nil) != (expected.result != nil) || view.resultPill.isHidden == (expected.result != nil) {
                resultShown = false
            }
        }
        view.layoutSubtreeIfNeeded()
        flow.start(table, dealNow: true)
        t.check("fourteen hands (or the tournament's end) with the view watching (\(recorder.hands))",
                recorder.hands == 14 || flow.stage == .finished)
        t.check("after every hand the table shows exactly the engine's picture \(mismatch)", settled)
        t.check("…one card on the table for every card in play", spritesMatch)
        t.check("…and the result is said when there is one", resultShown)
        view.setFrameSize(CGSize(width: 980, height: 660))
        view.layoutSubtreeIfNeeded()
        t.check("a resize between hands re-lays the same picture", view.scene == PokerScene(table: flow.table)
                    && view.layoutModel?.geometry.bounds.width == 980)
    }

    // MARK: The player

    static func playerTurn(_ t: TestReporter) {
        t.section("Poker — the player's turn")
        guard let table = PokerGame.scenarioTable("preflop") else { t.check("a preflop table", false); return }
        let flow = PokerFlow(table: table, scheduler: TableScheduler(immediate: true), decider: PokerDirectDecider(samples: 30))
        flow.handLimit = 0
        flow.start(table, dealNow: false)
        t.check("the flow waits for the player", flow.stage == .humanTurn && flow.table.isHumanToAct)
        let before = flow.table
        t.check("an illegal action is refused and changes nothing", !flow.act(.check) && flow.table == before)
        t.check("…and so is a raise below the minimum", !flow.act(.raise(before.currentBet + 1)) && flow.table == before)
        t.check("folding plays the hand out without the player, to the payout",
                flow.act(.fold) && flow.stage == .betweenHands && flow.table.phase == .betweenHands
                    && flow.table.players[0].status == .folded)
        t.check("…at the brisk pace of a hand the player is out of", flow.pace.hurried)

        // A raise, sized by the bar's rules.
        let flow2 = PokerFlow(table: table, scheduler: TableScheduler(immediate: true), decider: PokerDirectDecider(samples: 30))
        flow2.handLimit = 0
        flow2.start(table, dealNow: false)
        if let o = flow2.table.options() {
            let suggested = PokerActionPanel.suggestedTotal(o, table: flow2.table)
            t.check("the suggested raise is three times the bet, in whole chips (\(suggested))",
                    suggested == o.clampTotal(o.currentBet * 3) && suggested % flow2.table.chipUnit == 0)
            t.check("…and it is legal", flow2.act(o.aggressiveAction(to: suggested)))
        }
    }

    static func waitingAndPreActions(_ t: TestReporter) {
        t.section("Poker — waiting for the table")
        let decider = PokerManualDecider()
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 3), seed: 1_313)
        // The next hand's button is seat 2: seat 3 and the player post the
        // blinds, and the bots in seats 1, 2 and 3 act before the player.
        table.setButtonForTesting(1)
        let flow = PokerFlow(table: table, scheduler: TableScheduler(immediate: true), decider: decider)
        flow.handLimit = 1
        flow.start(table, dealNow: true)
        t.check("a bot is thinking, and the flow waits on it", {
            if case .botThinking = flow.stage { return decider.pending != nil }
            return false
        }())
        // Answer bots until it is the player's turn or the hand is over.
        var guardSteps = 0
        flow.preAction = .checkFold
        while decider.pending != nil && guardSteps < 60 {
            guardSteps += 1
            decider.answer()
        }
        t.check("Check/Fold ticked in advance answers for the player when the turn comes",
                flow.preAction == nil && flow.table.handLog.contains { $0.seat == 0 && ($0.kind == .check || $0.kind == .fold) })

        // A new game while a bot is still thinking: its answer must not land.
        let fresh = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 3), seed: 1_414)
        let flow3 = PokerFlow(table: fresh, scheduler: TableScheduler(immediate: true), decider: decider)
        flow3.autopilot = true
        flow3.handLimit = 1
        flow3.start(fresh, dealNow: true)
        let asked = decider.pending
        let other = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 2), seed: 1_515)
        flow3.start(other, dealNow: false)
        if let asked {
            asked.completion(PokerBot.decide(table: asked.table, seat: asked.seat, samples: 20))
        }
        t.check("a decision for the old table is dropped when a new one sits down",
                asked != nil && flow3.table == other && flow3.stage == .betweenHands)
    }

    /// The bot's pause stops when the game goes away, and carries on after.
    static func pausing(_ t: TestReporter) {
        t.section("Poker — a pause for thought keeps the table's hours")
        let scheduler = TableScheduler(immediate: false)
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 2, speed: .fast), seed: 1_616)
        table.setButtonForTesting(2)
        let flow = PokerFlow(table: table, scheduler: scheduler, decider: PokerDirectDecider(samples: 20))
        flow.autopilot = true
        flow.speed = .fast
        flow.handLimit = 1
        flow.start(table, dealNow: true)
        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        spin(4) { if case .botThinking = flow.stage { return true }; return false }
        var thinking = false
        if case .botThinking = flow.stage { thinking = true }
        t.check("the deal lands and a bot starts thinking", thinking)
        scheduler.suspend()
        let frozen = flow.table
        spin(0.5)
        t.check("suspended (the game went to the background), the bot's pause holds: nobody acts",
                flow.table == frozen && scheduler.pendingCount > 0)
        scheduler.resume()
        spin(3) { flow.table != frozen }
        t.check("resumed, it carries on and acts", flow.table.handLog.count > frozen.handLog.count)
        scheduler.cancelAll()
        flow.cancelPending()
    }

    static func backgroundWorker(_ t: TestReporter) {
        t.section("Poker — the bots thinking off the main thread")
        let table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 1), seed: 1_717)
        let decider = PokerWorkerDecider()
        decider.samples = 40
        let flow = PokerFlow(table: table, scheduler: TableScheduler(immediate: true), decider: decider)
        let recorder = PokerFlowRecorder()
        flow.delegate = recorder
        flow.autopilot = true
        let started = Date()
        flow.start(table, dealNow: true)
        let deadline = Date().addingTimeInterval(30)
        while flow.stage != .finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        t.check("a heads-up tournament plays to the end with every decision made in the background (\(recorder.hands) hands)",
                flow.stage == .finished && recorder.places.count == 1 && recorder.chipsAlwaysAddUp)
        t.info(String(format: "%.2f s", Date().timeIntervalSince(started)))
    }

    // MARK: The game

    static func controller(_ t: TestReporter) {
        t.section("Poker — the game")
        Storage.remove(PokerStorage.tableFile)
        Storage.remove(PokerStorage.statsFile)
        Storage.remove(PokerPreferences.fileName)
        let game = PokerGame()
        let view = game.tableViewForTesting
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        view.layoutSubtreeIfNeeded()
        t.check("the first time, the New Game card is up and there is no Cancel",
                game.optionsCardForTesting?.isPresented == true && game.optionsCardForTesting?.onCancel == nil)
        t.check("…and the action bar stands down behind it", game.panelForTesting.mode == .hidden)
        t.check("⌘N is off while that card is up — it is the New Game card, and one without Cancel",
                !game.validateMenuItem(NSMenuItem(title: "", action: #selector(PokerGame.newGame(_:)), keyEquivalent: "n")))
        // Leaving before choosing: the still life behind the card is nobody's
        // game, so nothing is saved and the next launch asks again.
        game.gameWillResignActive()
        game.prepareToQuit()
        t.check("leaving before choosing saves no table, so the next launch asks again", PokerStorage.loadTable() == nil)
        Storage.remove(PokerPreferences.fileName)

        // The player's turn, from the preflop scene.
        game.prepareForScreenshot(scenario: "preflop")
        let panel = game.panelForTesting
        let flow = game.flowForTesting
        t.check("the player's turn shows the bet control and Fold · Call · Raise", panel.mode == .turn && !panel.bet.isHidden
                    && panel.bar.actions.map(\.id) == ["fold", "passive", "aggressive"])
        t.check("…with the five presets", panel.bet.presets.map(\.title) == ["Min", "½ Pot", "¾ Pot", "Pot", "All-in"])
        t.check("…and the keys F, C and Return", panel.bar.actions.map(\.keyEquivalent) == ["f", "c", "\r"])
        let reserveTurn = panel.bar.reservedHeight
        if let o = flow.table.options() {
            let before = panel.bet.value
            if let right = key("\u{F703}", code: 124), let escape = key("\u{1b}", code: 53), let r = key("r", code: 15) {
                _ = panel.handleKey(right)
                t.check("→ adds a chip to the bet", panel.bet.value == min(o.maxTotal, before + flow.table.chipUnit))
                _ = panel.handleKey(escape)
                t.check("Escape puts the suggested amount back", panel.bet.value == before)
                t.check("R is the bar's key (it moves the keyboard to the slider)", panel.handleKey(r))
            }
            panel.bet.value = o.maxTotal
            t.check("at the top of the range the button goes all-in", panel.chosenAction(o) == .allIn
                        && panel.bar.button(for: "aggressive") != nil)
        }
        panel.bar.button(for: "fold")?.performPress()
        t.check("the Fold button folds", flow.table.players[0].status == .folded)

        // The keyboard: R hands it to the slider; acting hides the slider and
        // hands it back to the table, where R, the arrows and Escape are
        // heard — rather than stranding it on the window.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        game.prepareForScreenshot(scenario: "preflop")
        panel.focusBet()
        let onSlider = (window.firstResponder as? NSView)?.isDescendant(of: panel.bet) == true
        panel.bar.button(for: "passive")?.performPress()
        t.check("R gives the slider the keyboard, and acting gives it back to the table",
                onSlider && flow.table.players[0].hasActed && window.firstResponder === view)
        window.contentView = nil
        view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        // Checking is free: no Fold on the bar, and F folds nothing.
        game.prepareForScreenshot(scenario: "long-hand")
        t.check("when checking is free the bar has no Fold: Check · Bet (\(panel.bar.actions.map(\.id)))",
                flow.table.options()?.canCheck == true && panel.bar.actions.map(\.id) == ["passive", "aggressive"]
                    && !panel.bar.actions.contains { $0.keyEquivalent == "f" })
        // Everyone else all in: no turn can come, so nothing to tick in advance.
        game.prepareForScreenshot(scenario: "big-bets")
        t.check("with everyone else all in, no Check/Fold to tick", panel.mode == .hidden)

        // Between hands.
        game.prepareForScreenshot(scenario: "showdown")
        t.check("between hands the bar offers Deal Next Hand on Return",
                panel.mode == .betweenHands && panel.bar.actions.last?.id == "deal" && panel.bar.actions.last?.keyEquivalent == "\r")
        t.check("the bar keeps its height whatever it holds, so the table never jumps",
                panel.bar.reservedHeight == reserveTurn)
        game.prepareForScreenshot(scenario: "runout")
        t.check("all-in, the bar steps aside", panel.mode == .hidden && panel.bar.isHidden)

        // Whole games through the game itself: the record and the save.
        flow.decider = PokerDirectDecider(samples: 25)
        flow.autopilot = true
        flow.handLimit = 6
        view.scheduler.isImmediate = true
        game.newGameSameSettings(nil)
        let stats = PokerStorage.loadStats()
        t.check("six hands are recorded in the statistics (\(stats.handsPlayed))",
                stats.handsPlayed == 6 || flow.stage == .finished)
        t.check("…and the table is saved between hands", PokerStorage.loadTable() == flow.table)
        flow.handLimit = nil
        flow.dealNextHand()
        t.check("playing on, the tournament ends with the player's place in the record and a banner",
                flow.stage == .finished && PokerStorage.loadStats().tournamentsPlayed == 1
                    && Banner.banners(in: view).count == 1)
        t.check("…the table quiet under it", view.isQuiet && view.resultPill.isHidden)
        if let last = PokerGame.scenarioTable("tournament-end"), let ordinary = PokerGame.scenarioTable("showdown") {
            t.check("the hand that ends the tournament stays on the table a while before the banner; others do not wait",
                    PokerFlow.finalHold(after: last, pace: PokerPace()) >= 2.6
                        && PokerFlow.finalHold(after: ordinary, pace: PokerPace()) == 0)
        }
        let rows = PokerStatisticsWindow.rows(PokerStorage.loadStats())
        t.check("the statistics sheet has its eight rows", rows.count == 8)

        // A relaunch resumes at the hand boundary.
        let resumed = PokerGame()
        _ = resumed.tableViewForTesting
        t.check("a new session resumes the saved table, not a New Game card",
                resumed.flowForTesting.table == PokerStorage.loadTable() && resumed.optionsCardForTesting == nil)
        Banner.dismissAll(in: view)

        // Quitting in the middle of a hand: saved as it stands, deck and all,
        // and picked up there — the same cards, the same chips in, the
        // player's turn — not the chips given back and the hand dealt again.
        flow.autopilot = false
        game.newGameSameSettings(nil)
        let midHand = flow.table
        game.prepareToQuit()
        let again = PokerGame()
        _ = again.tableViewForTesting
        t.check("quitting mid-hand and coming back finds that hand where it stood, the player to act",
                flow.stage == .humanTurn && midHand.phase == .betting && again.flowForTesting.table == midHand
                    && again.flowForTesting.stage == .humanTurn)
        Banner.dismissAll(in: view)

        // Preferences survive a damaged file.
        Storage.save(["opponents": "many", "speed": "fast"], to: PokerPreferences.fileName)
        let p = PokerPreferences.load()
        t.check("a damaged preferences file keeps what it can", p.speed == .fast && p.opponents == 5)
        Storage.remove(PokerPreferences.fileName)
        Storage.remove(PokerStorage.tableFile)
        Storage.remove(PokerStorage.statsFile)

        // The menu.
        let menu = game.makeGameMenu()
        t.check("the menu: New Game is ⌘N and Statistics ⌥⌘S",
                menu.items.contains { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }
                    && menu.items.contains { $0.keyEquivalent == "s" && $0.keyEquivalentModifierMask == [.command, .option] })
        for name in ["trophy.fill", "flag.checkered", "arrow.up.circle", "circle.grid.2x1", "number", "plus.circle", "checkmark"] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil { t.check("symbol \(name) exists", false) }
        }
    }

    private static func key(_ characters: String, code: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: code)
    }
}
