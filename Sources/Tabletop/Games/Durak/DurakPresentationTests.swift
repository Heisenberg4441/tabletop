//
//  DurakPresentationTests.swift
//  The durak table, driven the way the player drives it.
//
//  The engine's tests (Engine/DurakEngineTests) prove the rules. These prove
//  everything between the rules and the player: that the table the view
//  animates event by event arrives at the engine's position; that the
//  layout keeps every hand, seat and card on the cloth and out of each
//  other's way at every window size; and — the main one — that whole games
//  played through the real controller, its real table view in a window that
//  is never shown, with the player's moves made by clicks, drops and the
//  action bar's buttons and the bots moving on the table's scheduler, run to
//  their end with every card where it should be, the result counted once,
//  and nothing ticking after the game has left the screen.
//

import AppKit

@MainActor
enum DurakPresentationTests {

    static func run(_ t: TestReporter) {
        let savedOverride = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = savedOverride }

        let sections: [(String, (TestReporter) -> Void)] = [
            ("mirror", snapshotMirror), ("layout", layout), ("games", controllerGames), ("interaction", interaction),
            ("lifecycle", lifecycle), ("persistence", persistence), ("scenarios", scenarios),
        ]
        var timings: [String] = []
        for (name, section) in sections {
            let start = Date()
            section(t)
            timings.append(String(format: "%@ %.2f s", name, Date().timeIntervalSince(start)))
        }
        t.info("presentation tests: " + timings.joined(separator: ", "))
    }

    // MARK: Helpers

    static func clearFiles() {
        for name in [DurakSession.fileName, DurakStatistics.fileName, DurakSettings.fileName] { Storage.remove(name) }
    }

    /// A game in a window that is never shown, laid out at `size`.
    static func host(_ game: DurakGame, size: CGSize = CGSize(width: 1200, height: 800)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = game.view
        game.view.frame = CGRect(origin: .zero, size: size)
        game.view.layoutSubtreeIfNeeded()
        return window
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func findButton(_ title: String, in view: NSView) -> CapsuleButton? {
        if let button = view as? CapsuleButton, button.title == title, !button.isHiddenOrHasHiddenAncestor { return button }
        for sub in view.subviews { if let found = findButton(title, in: sub) { return found } }
        return nil
    }

    static func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    // MARK: The mirror

    /// Random bot games: the snapshot, applying each event in turn, lands on
    /// the engine's position after every action, and never loses a card on
    /// the way.
    private static func snapshotMirror(_ t: TestReporter) {
        t.section("Durak table: the view's table follows the engine event by event")
        var actions = 0, mismatches = 0, lost = 0, games = 0
        for game in 0..<24 {
            let players = 2 + game % 3
            let variant: DurakVariant = game % 2 == 0 ? .podkidnoy : .perevodnoy
            let dealt = DurakState.newGame(rules: DurakRules(playerCount: players, variant: variant), seed: UInt64(900 + game))
            var state = dealt.state
            guard case .dealt(let hands, let trump)? = dealt.events.first else { mismatches += 1; continue }
            var mirror = DurakTableSnapshot(beforeDealing: hands, trump: trump, stockAfter: state.stock)
            for event in dealt.events { mirror.apply(event) }
            if !mirror.matches(state) { mismatches += 1 }
            let bot = DurakBot(DurakDifficulty.allCases[game % 3])
            while let actor = state.actor, actions < 40_000 {
                guard let events = try? state.apply(bot.decide(in: state, seat: actor), by: actor) else { break }
                for event in events {
                    mirror.apply(event)
                    let total = mirror.hands.reduce(0) { $0 + $1.count } + mirror.stock.count + mirror.discard.count
                        + mirror.table.reduce(0) { $0 + 1 + ($1.defence == nil ? 0 : 1) }
                    if total != 36 { lost += 1 }
                }
                if !mirror.matches(state) { mismatches += 1 }
                actions += 1
            }
            if state.isOver { games += 1 }
        }
        t.check("\(games) of 24 games played out, \(actions) actions", games == 24)
        t.check("after every action the table shows exactly the engine's position (\(mismatches) differences)", mismatches == 0)
        t.check("and between events all 36 cards are somewhere (\(lost) slips)", lost == 0)
    }

    // MARK: Layout

    private static func layout(_ t: TestReporter) {
        t.section("Durak table: layout at every size")
        let sizes = [CGSize(width: 960, height: 640), CGSize(width: 1200, height: 800),
                     CGSize(width: 1440, height: 900), CGSize(width: 2200, height: 1300), CGSize(width: 1000, height: 1000)]
        var problems: [String] = []
        for size in sizes {
            for players in 2...4 {
                let table = DurakTableView(playerCount: players)
                table.frame = CGRect(origin: .zero, size: size)
                // A deal, so the layout is for this many players.
                let state = DurakState.newGame(rules: DurakRules(playerCount: players), seed: 5).state
                table.show(DurakTableSnapshot(state: state))
                table.layoutSubtreeIfNeeded()
                let l = table.layoutModel
                let label = "\(Int(size.width))×\(Int(size.height)) \(players)p"
                let felt = l.felt.insetBy(dx: -0.5, dy: -0.5)
                func inside(_ r: CGRect, _ what: String) {
                    if !felt.contains(r) { problems.append("\(label): \(what) leaves the cloth") }
                }
                let seats = (0..<players).map { l.seatFrame($0) }
                for (i, a) in seats.enumerated() {
                    inside(a, "seat \(i)")
                    for (j, b) in seats.enumerated() where j > i && a.intersects(b) {
                        problems.append("\(label): seats \(i) and \(j) overlap")
                    }
                }
                var hands: [CGRect] = []
                var bigHands: [(Int, CGRect)] = []
                for count in [6, 14, 24] {
                    let human = TableLayout.bounds(of: l.humanHand(count: count, lifted: Set(0..<count)), cardSize: l.cardSize)
                    inside(human, "your \(count)-card hand")
                    if human.maxY > l.play.maxY + 1 { problems.append("\(label): your hand reaches the bar") }
                    if human.intersects(seats[0]) { problems.append("\(label): your \(count)-card hand covers your seat") }
                    if count == 6 { hands.append(human) }
                    for seat in 1..<players {
                        for shown in [false, true] {
                            let box = TableLayout.bounds(of: l.botHand(l.places[seat], count: count, seat: seat, shown: shown),
                                                         cardSize: l.cardSize)
                            inside(box, "seat \(seat)'s \(count)-card hand")
                            if count == 6 && !shown { hands.append(box) }
                            if count <= 14 && !shown { bigHands.append((seat, box)) }
                            for (other, frame) in seats.enumerated() where box.intersects(frame.insetBy(dx: 2, dy: 2)) {
                                if count <= 14 || other != seat {
                                    problems.append("\(label): seat \(seat)'s \(count)-card hand\(shown ? " (shown)" : "") covers seat \(other)")
                                }
                            }
                        }
                    }
                }
                // The fight: six pairs, each inside the cloth and clear of
                // every seat, hand, the deck and the pile.
                var fight = CGRect.null
                for i in 0..<6 {
                    let pair = l.pair(i, of: 6, attack: Card.durakDeck[i], defence: Card.durakDeck[i + 9])
                    fight = fight.union(TableLayout.boundingBox(of: pair.attack, cardSize: l.cardSize))
                        .union(TableLayout.boundingBox(of: pair.defence, cardSize: l.cardSize))
                }
                inside(fight, "the fight")
                // Every attacking card shares one rank when a transfer is
                // possible, so there are at most three before it.
                let zone = l.transferZone(count: 3)
                inside(zone, "the transfer place")
                let deck = TableLayout.bounds(of: l.deck(count: 24) + [l.trumpPose], cardSize: l.cardSize)
                let pile = TableLayout.bounds(of: l.discard(count: 30, seed: 3), cardSize: l.cardSize)
                inside(deck, "the deck")
                inside(pile, "the bito pile")
                for (name, box) in [("the fight", fight.union(zone)), ("the deck", deck), ("the pile", pile)] {
                    for (i, frame) in seats.enumerated() where box.intersects(frame) {
                        problems.append("\(label): \(name) covers seat \(i)")
                    }
                    for (i, hand) in hands.enumerated() where box.intersects(hand) {
                        problems.append("\(label): \(name) covers hand \(i)")
                    }
                }
                for (seat, hand) in bigHands where hand.intersects(deck) || hand.intersects(pile) {
                    problems.append("\(label): seat \(seat)'s big hand runs into the deck or the pile")
                }
                if fight.intersects(deck) || fight.intersects(pile) || zone.intersects(deck) || zone.intersects(pile) {
                    problems.append("\(label): the fight runs into the deck or the pile")
                }
            }
        }
        t.check("hands, seats, the deck, the fight and the pile stay on the cloth and apart \(problems.prefix(6))",
                problems.isEmpty)
        let narrow = DurakTableView(playerCount: 4)
        narrow.frame = CGRect(x: 0, y: 0, width: 960, height: 640)
        narrow.show(DurakTableSnapshot(state: DurakState.newGame(rules: DurakRules(playerCount: 4), seed: 5).state))
        narrow.layoutSubtreeIfNeeded()
        let wide = DurakTableView(playerCount: 2)
        wide.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        wide.show(DurakTableSnapshot(state: DurakState.newGame(rules: DurakRules(playerCount: 2), seed: 5).state))
        wide.layoutSubtreeIfNeeded()
        t.check("six pairs in a row on a wide table, two rows of three on a narrow one (\(wide.layoutModel.perRow), \(narrow.layoutModel.perRow))",
                wide.layoutModel.perRow == 6 && narrow.layoutModel.perRow == 3)
    }

    // MARK: Whole games through the controller

    /// Plays the player's decision the way the player would: a click on the
    /// card (and on its target when the click alone is ambiguous), or the
    /// button in the bar. Returns whether the game moved.
    static func playLikeAPerson(_ action: DurakAction, game: DurakGame) -> Bool {
        guard let before = game.match.state?.actionCount else { return false }
        let table = game.table!
        func moved() -> Bool { (game.match.state?.actionCount ?? before) > before }
        switch action {
        case .take:
            table.actionBar.button(for: "take")?.performPress()
        case .pass:
            table.actionBar.button(for: "pass")?.performPress()
        case .attack(let card):
            table.click(card.durakIndex)
        case .defend(let card, let attack):
            table.click(card.durakIndex)
            if !moved() {
                guard table.selectedCard == card else { return false }
                table.click(attack.durakIndex)
            }
        case .transfer(let card):
            table.click(card.durakIndex)
            if !moved() {
                guard table.selectedCard == card else { return false }
                let zone = table.layoutModel.transferZone(count: game.match.state?.table.count ?? 0)
                table.clickCloth(at: CGPoint(x: zone.midX, y: zone.midY))
            }
        }
        return moved()
    }

    private static func controllerGames(_ t: TestReporter) {
        t.section("Durak table: whole games through the controller, played by clicks and buttons")
        clearFiles()
        let game = DurakGame()
        var seed: UInt64 = 40
        game.nextSeed = { seed += 1; return seed }
        let window = host(game)
        defer { withExtendedLifetime(window) {} }
        game.match.decidesInline = true
        game.gameDidBecomeActive()
        t.check("the first time, the New Game card is up and nothing is dealt",
                game.isOptionsCardUp && game.match.state == nil)

        struct Config { let opponents: Int; let variant: DurakVariant; let difficulty: DurakDifficulty; let games: Int }
        let configs = [Config(opponents: 1, variant: .podkidnoy, difficulty: .hard, games: 2),
                       Config(opponents: 2, variant: .perevodnoy, difficulty: .normal, games: 2),
                       Config(opponents: 3, variant: .podkidnoy, difficulty: .easy, games: 1),
                       Config(opponents: 3, variant: .perevodnoy, difficulty: .hard, games: 2)]
        let chooser = DurakBot(.normal)
        var finished = 0, played = 0, uiMisses = 0, disagreements = 0, stuck = 0, steps = 0
        var openingsRight = 0, openingsChecked = 0, bannerShown = 0
        var byPlayers: [Int: Int] = [:]
        let start = Date()
        for config in configs {
            var settings = DurakSettings()
            settings.opponents = config.opponents
            settings.variant = config.variant
            settings.difficulty = config.difficulty
            game.startNewGame(with: settings)
            var previous: DurakResult?
            for index in 0..<config.games {
                if index > 0 {
                    // The banner's New Game: the next game at the same table.
                    guard let banner = game.endBannerForTesting, let again = findButton(
                        NSLocalizedString("New Game", comment: "durak end banner button"), in: banner) else {
                        t.check("the end banner offers New Game", false)
                        break
                    }
                    again.performPress()
                    if case .durak(let loser)? = previous, let state = game.match.state {
                        openingsChecked += 1
                        if state.defender == loser { openingsRight += 1 }
                    }
                }
                played += 1
                var guardSteps = 0
                while let state = game.match.state, !state.isOver, guardSteps < 4_000 {
                    guardSteps += 1
                    steps += 1
                    game.table.scheduler.runPendingImmediately()
                    guard let now = game.match.state, !now.isOver else { break }
                    if !game.match.isPresenting && !game.table.spritesAgree(with: now) { disagreements += 1 }
                    if game.match.isAwaitingHuman {
                        let action = chooser.decide(in: now, seat: 0)
                        if !playLikeAPerson(action, game: game) {
                            uiMisses += 1
                            game.match.play(action)
                        }
                    } else if game.table.scheduler.pendingCount == 0 {
                        stuck += 1
                        break
                    }
                }
                game.table.scheduler.runPendingImmediately()
                if let state = game.match.state, state.isOver {
                    finished += 1
                    byPlayers[state.playerCount, default: 0] += 1
                    if game.table.spritesAgree(with: state) == false { disagreements += 1 }
                    if game.endBannerForTesting != nil { bannerShown += 1 }
                    previous = state.result
                }
            }
        }
        let seconds = Date().timeIntervalSince(start)
        t.check("\(finished) of \(played) games finished, 2 to 4 players, both variants \(byPlayers.sorted { $0.key < $1.key })",
                finished == played && byPlayers.count == 3)
        t.check("every one of the player's moves went through a click, a drop or a button (\(uiMisses) did not)", uiMisses == 0)
        t.check("whenever the table is still, every card is where the engine says, face up or down as it should be (\(disagreements) differences)",
                disagreements == 0)
        t.check("the table never stalls waiting for nobody (\(stuck))", stuck == 0)
        t.check("each game ends with the banner (\(bannerShown))", bannerShown == finished)
        t.check("the durak defends first in the next game («под дурака», \(openingsRight) of \(openingsChecked))",
                openingsRight == openingsChecked && openingsChecked > 0)
        let stats = game.statisticsForTesting
        let recorded = stats.podkidnoy.played + stats.perevodnoy.played
        let board = game.sessionForTesting?.scoreboard
        t.check("every finished game is in the statistics once (\(recorded))", recorded == finished)
        // The last table is every config with the last one's number of
        // opponents, back to the first that had a different number.
        let lastTable = configs.reversed().prefix { $0.opponents == configs.last?.opponents }.reduce(0) { $0 + $1.games }
        t.check("and in the session's scoreboard (\(board?.games ?? -1) games at the last table)",
                board?.games == lastTable)
        t.info(String(format: "%d steps in %.2f s", steps, seconds))

        // A new game mid-game counts as the loss it would have been.
        game.startNewGame()
        game.table.scheduler.runPendingImmediately()
        var moves = 0
        while let state = game.match.state, !state.isOver, moves < 6 {
            if game.match.isAwaitingHuman {
                game.match.play(chooser.decide(in: state, seat: 0))
                moves += 1
            }
            game.table.scheduler.runPendingImmediately()
        }
        let variant = game.match.state?.rules.variant ?? .perevodnoy
        let before = game.statisticsForTesting[variant]
        let wasOut = game.match.state?.isOut(0) ?? false
        game.startNewGame()
        let after = game.statisticsForTesting[variant]
        t.check("a game abandoned mid-way counts once, as a loss while you held cards",
                after.played == before.played + 1 && (wasOut || after.durak == before.durak + 1))
        game.gameWillResignActive()
        game.prepareToQuit()
    }

    // MARK: Clicks, drops and keys

    /// Perevodnoy, three players: seat 1 leads the 7♠ at seat 2, who passes
    /// it on with the 7♦ — so the player faces two sevens, holding the 9♥
    /// (a trump that beats either), the 7♣ (which can only pass it on again)
    /// and the 6♠ (which can do nothing).
    static func transferPosition() -> DurakState? {
        let c: (String) -> [Card] = { DurakEngineTests.cards($0) }
        guard var state = DurakState.position(
            rules: DurakRules(playerCount: 3, variant: .perevodnoy), trumpCard: DurakEngineTests.card("Ah"),
            hands: [c("9h 7c 6s Qc Kc"), c("7s 8c 9c Jd Jc"), c("7d 10d 6d Qs Ks")],
            stock: c("Ah 6c 8d"), attacker: 1) else { return nil }
        guard (try? state.apply(.attack(DurakEngineTests.card("7s")), by: 1)) != nil,
              (try? state.apply(.transfer(DurakEngineTests.card("7d")), by: 2)) != nil else { return nil }
        return state
    }

    private static func interaction(_ t: TestReporter) {
        t.section("Durak table: clicks, drops and keys")
        clearFiles()
        let game = DurakGame()
        let window = host(game)
        defer { withExtendedLifetime(window) {} }
        game.match.decidesInline = true
        game.gameDidBecomeActive()
        guard let state = transferPosition() else {
            t.check("the test position deals", false)
            return
        }
        let card = DurakEngineTests.card
        let session = DurakSession(names: ["Anna", "Boris"])
        game.install(state, session: session)
        let table = game.table!
        t.check("the player is asked to defend two sevens", game.match.isAwaitingHuman && state.unbeatenAttacks.count == 2)
        t.check("the cards that can do something lift and glow: the 9♥ and the 7♣, not the 6♠",
                table.prompt?.playable == [card("9h"), card("7c")])
        t.check("the Take and Transfer buttons are in the bar",
                table.actionBar.button(for: "take")?.isEnabled == true && table.actionBar.button(for: "transfer") != nil
                    && !table.actionBar.isHidden)

        table.click(card("6s").durakIndex)
        t.check("a click on a card that can do nothing does nothing", game.match.state?.actionCount == state.actionCount)
        table.click(card("9h").durakIndex)
        t.check("a click on the 9♥, which could beat either seven, picks it up instead of playing it",
                table.selectedCard == card("9h") && game.match.state?.actionCount == state.actionCount)
        if let esc = key("\u{1b}", code: 53, in: window) { table.keyDown(with: esc) }
        t.check("Escape puts it back", table.selectedCard == nil)
        table.click(card("9h").durakIndex)
        table.click(card("7d").durakIndex)
        let beaten = game.match.state?.table.first { $0.attack == card("7d") }?.defence
        t.check("then a click on the 7♦ beats that one", beaten == card("9h"))
        game.table.scheduler.runPendingImmediately()

        // Drops, on a fresh copy of the position.
        game.install(state, session: session)
        let layout = table.layoutModel
        let zone = layout.transferZone(count: state.table.count)
        let handPoint = CGPoint(x: layout.felt.midX, y: layout.play.maxY - 10)
        t.check("dropping a card back on the hand does nothing", table.dropAction(for: card("9h"), at: handPoint) == nil)
        if let pose = table.restingPose(of: card("7s")) {
            t.check("dropping the 9♥ on the 7♠ beats the 7♠",
                    table.dropAction(for: card("9h"), at: pose.position) == .defend(card("9h"), on: card("7s")))
        }
        t.check("dropping the 7♣ on the transfer place passes the attack on",
                table.dropAction(for: card("7c"), at: CGPoint(x: zone.midX, y: zone.midY)) == .transfer(card("7c")))
        t.check("dropping the 9♥ on the bare cloth is ambiguous, and flies home",
                table.dropAction(for: card("9h"), at: CGPoint(x: layout.felt.midX, y: layout.fightRect.minY + 4)) == nil)
        let id = card("7c").durakIndex
        let picked = table.draggableSprites(startingAt: id)
        t.check("the 7♣ can be picked up, the 6♠ cannot",
                picked == [id] && table.draggableSprites(startingAt: card("6s").durakIndex) == nil)
        _ = table.spritesDropped([id], at: CGPoint(x: zone.midX, y: zone.midY))
        t.check("and dropping it there transfers to Anna",
                game.match.state?.defender == 1 && game.match.state?.table.count == 3)
        table.scheduler.runPendingImmediately()

        // Keys: T takes; Space and Return say Bito / Pass / Done.
        game.install(state, session: session)
        if let t_ = key("t", code: 17, in: window) { table.keyDown(with: t_) }
        t.check("T takes", game.match.state?.phase == .pileOn || (game.match.state?.hands[0].count ?? 0) > state.hands[0].count)
        table.scheduler.runPendingImmediately()

        if var throwIn = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card("Ah"),
                                             hands: [DurakEngineTests.cards("7c 7s 9d Qd Kc"), DurakEngineTests.cards("8c 9c Jd Jc 6h")],
                                             stock: DurakEngineTests.cards("Ah 6c 8d"), attacker: 0),
           (try? throwIn.apply(.attack(card("7c")), by: 0)) != nil,
           (try? throwIn.apply(.defend(card("8c"), on: card("7c")), by: 1)) != nil {
            game.install(throwIn, session: DurakSession(names: ["Anna"]))
            t.check("your attack, all beaten: the bar says Bito",
                    table.actionBar.button(for: "pass")?.title == NSLocalizedString("Bito", comment: "durak button: everything is beaten («Бито»)"))
            if let space = key(" ", code: 49, in: window) { table.keyDown(with: space) }
            t.check("Space says it", (game.match.state?.discard.count ?? 0) > throwIn.discard.count
                        || game.match.state?.attacker == 1)
            table.scheduler.runPendingImmediately()
        }
        game.gameWillResignActive()
    }

    // MARK: Walking away

    private static func lifecycle(_ t: TestReporter) {
        t.section("Durak table: nothing moves while the game is away")
        clearFiles()
        let game = DurakGame()
        var seed: UInt64 = 7
        game.nextSeed = { seed += 1; return seed }
        let window = host(game)
        defer { withExtendedLifetime(window) {} }
        game.match.thinkingPace = 0.25
        game.gameDidBecomeActive()
        // A game a few moves in, with a computer player to move.
        var state = DurakState.newGame(rules: DurakRules(playerCount: 4), seed: 11).state
        let bot = DurakBot(.normal)
        while let actor = state.actor, actor == 0 || state.actionCount < 5 {
            _ = try? state.apply(bot.decide(in: state, seat: actor), by: actor)
        }
        game.install(state, session: DurakSession(names: ["Anna", "Boris", "Dmitri"]))
        pump(0.05)
        guard game.match.thinkingSeat != nil, let before = game.match.state?.actionCount else {
            t.check("a bot is thinking", false)
            return
        }
        game.gameWillResignActive()
        t.check("leaving suspends the table's clock and holds the match",
                game.table.scheduler.isSuspended && game.match.isHeld)
        pump(0.35)      // longer than any (shortened) thinking pause
        t.check("a bot mid-thought does not move while the game is away",
                game.match.state?.actionCount == before && game.match.thinkingSeat != nil)
        game.gameDidBecomeActive()
        var waited = 0.0
        while game.match.state?.actionCount == before && waited < 3 {
            pump(0.05)
            waited += 0.05
        }
        t.check(String(format: "back at the table it makes its move, worked out in the background (%.1f s)", waited),
                (game.match.state?.actionCount ?? before) > before)

        // The New Game card holds the bots too.
        for _ in 0..<200 where game.match.thinkingSeat == nil {
            if game.match.isAwaitingHuman, let state = game.match.state {
                game.match.play(DurakBot(.easy).decide(in: state, seat: 0))
            }
            pump(0.02)
        }
        let held = game.match.state?.actionCount
        game.newGame(nil)
        pump(0.35)
        t.check("with the New Game card up, nobody plays", game.isOptionsCardUp && game.match.state?.actionCount == held)
        if let cancel = findButton(NSLocalizedString("Cancel", comment: ""), in: game.view) { cancel.performPress() }
        waited = 0
        while game.match.state?.actionCount == held && waited < 3 {
            pump(0.05)
            waited += 0.05
        }
        t.check("Cancel lets the table carry on", !game.isOptionsCardUp && game.match.state?.actionCount != held)
        game.gameWillResignActive()
        pump(0.05)
        let pending = game.table.scheduler.pendingCount
        let frozen = game.match.state?.actionCount
        pump(0.35)
        t.check("and after leaving again, still nothing (\(pending) steps waiting)", game.match.state?.actionCount == frozen)
        game.prepareToQuit()
    }

    // MARK: Saving

    private static func persistence(_ t: TestReporter) {
        t.section("Durak table: saving and resuming")
        clearFiles()
        let first = DurakGame()
        var seed: UInt64 = 70
        first.nextSeed = { seed += 1; return seed }
        let window = host(first)
        defer { withExtendedLifetime(window) {} }
        first.match.decidesInline = true
        first.gameDidBecomeActive()
        var settings = DurakSettings()
        settings.opponents = 2
        settings.variant = .perevodnoy
        settings.handOrder = .byRank
        first.startNewGame(with: settings)
        for _ in 0..<30 {
            first.table.scheduler.runPendingImmediately()
            if first.match.isAwaitingHuman, let state = first.match.state {
                first.match.play(DurakBot(.normal).decide(in: state, seat: 0))
            }
        }
        first.table.scheduler.runPendingImmediately()
        first.gameWillResignActive()
        first.prepareToQuit()
        let saved = first.match.state
        let names = first.sessionForTesting?.names

        let second = DurakGame()
        window.contentView = second.view
        second.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        second.view.layoutSubtreeIfNeeded()
        t.check("a relaunch resumes the same position, card for card", second.match.state == saved && saved != nil)
        t.check("with the same opponents", second.sessionForTesting?.names == names)
        t.check("laid out as it was", saved.map { second.table.spritesAgree(with: $0) } ?? false)
        t.check("and the hand sorted the way the player chose", second.table.handOrder == .byRank)
        second.prepareToQuit()

        // A damaged game is dropped; the table around it survives.
        if let session = DurakSession.load() {
            if let url = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any] {
                var damaged = url
                if var state = damaged["state"] as? [String: Any] {
                    state["discard"] = []
                    damaged["state"] = state
                }
                if let data = try? JSONSerialization.data(withJSONObject: damaged),
                   let decoded = try? JSONDecoder().decode(DurakSession.self, from: data) {
                    t.check("a save whose cards do not add up loses the game, keeps the names",
                            decoded.state == nil && decoded.names == session.names)
                } else {
                    t.check("a damaged save still decodes", false)
                }
            }
        }
        struct Scrambled: Encodable {
            let names = ["Anna"]
            let scoreboard = ["games": "many"]
            let state = "not a game"
        }
        Storage.save(Scrambled(), to: DurakSession.fileName)
        let third = DurakGame()
        window.contentView = third.view
        third.view.layoutSubtreeIfNeeded()
        t.check("with no game to resume, the New Game card comes up", third.isOptionsCardUp && third.match.state == nil)
        third.prepareToQuit()
        clearFiles()
    }

    // MARK: Screenshots

    private static func scenarios(_ t: TestReporter) {
        t.section("Durak table: every screenshot scenario finds its moment")
        var missing: [String] = []
        for name in DurakScenario.names where DurakScenario.make(name) == nil { missing.append(name) }
        t.check("\(DurakScenario.names.count) scenarios \(missing)", missing.isEmpty)
    }
}
