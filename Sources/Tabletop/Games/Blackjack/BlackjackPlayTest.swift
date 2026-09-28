//
//  BlackjackPlayTest.swift
//  The real table, played: a `BlackjackGame` in a window that is never
//  shown, driven through the same methods its chips, buttons and keys call,
//  by a player who bets at random and plays basic strategy.
//
//  The engine's own fuzz proves the rules keep the money straight; this
//  proves the table does — that after every click and every dealer's step
//  the chips on the cloth are the chips the engine says are there, every
//  card on the table is a card in a hand, the labels say what the hands
//  are, the bar offers exactly what is legal, the statistics add up, and a
//  round left half dealt waits, without ticking, until the player is back.
//

import AppKit

@MainActor
enum BlackjackPlayTest {

    static func run(_ t: TestReporter) {
        t.section("Blackjack table")
        let previousOverride = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = previousOverride }

        Storage.remove(BlackjackSavedTable.fileName)
        Storage.remove(BlackjackStatistics.fileName)
        let game = BlackjackGame()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = game.view
        game.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        game.view.layoutSubtreeIfNeeded()
        let table = game.table
        table.scheduler.isImmediate = true
        game.gameDidBecomeActive()
        t.check("a new table starts with 1,000 and a full six-deck shoe", game.engine.bankroll == 1_000
                && game.engine.shoe.undealt.count == 312 && game.engine.phase == .betting)
        t.check("the bar offers the chips and Deal, Deal waiting for a bet",
                table.bar.leadingAccessory === table.rack && table.bar.button(for: "deal")?.isEnabled == false)

        // Keys: 3 is the 100 chip, Option-3 takes it back.
        if let key = keyEvent("3", window: window) { table.keyDown(with: key) }
        t.check("the 3 key puts a 100 chip in the circle", game.engine.pendingBet == 100
                && table.stackAmountForTesting(.bet(0)) == 100)
        if let key = keyEvent("3", modifiers: .option, window: window) { table.keyDown(with: key) }
        t.check("Option-3 takes it back", game.engine.pendingBet == 0 && table.stackAmountForTesting(.bet(0)) == 0)

        var rng = DeterministicRNG(seed: 0x7AB1E)
        var balanced = true
        var sceneMatches = true
        var labelsMatch = true
        var barMatches = true
        var rounds = 0
        var splits = 0
        var insurances = 0
        var shuffles = 0
        var viaKeys = 0
        var collectedOK = true
        var problems: [String] = []

        func verify(_ moment: String) {
            let engine = game.engine
            if !engine.isBalanced { balanced = false; problems.append("unbalanced \(moment)") }
            let scene = game.currentScene
            if table.scene != scene { sceneMatches = false; problems.append("stale scene \(moment)") }
            let cards = engine.round?.cardsOnTable.count ?? 0
            if table.sceneSpriteCount != cards { sceneMatches = false; problems.append("\(table.sceneSpriteCount) sprites for \(cards) cards \(moment)") }
            for (key, amount) in scene.stacks where table.stackAmountForTesting(key) != amount.amount {
                sceneMatches = false
                problems.append("stack \(key) shows \(table.stackAmountForTesting(key)) not \(amount.amount) \(moment)")
            }
            for (i, hand) in scene.hands.enumerated() where table.badgeTextForTesting("hand\(i)") != hand.label {
                labelsMatch = false
                problems.append("hand \(i) says \(table.badgeTextForTesting("hand\(i)") ?? "nothing") \(moment)")
            }
            if engine.phase == .playerTurn && !engine.needsAdvance {
                let legal = engine.legalActions()
                for action in BlackjackAction.allCases where action != .surrender || engine.rules.surrenderAllowed {
                    if table.bar.button(for: action.rawValue)?.isEnabled != legal.contains(action) {
                        barMatches = false
                        problems.append("\(action) button \(moment)")
                    }
                }
            }
        }

        // Some rounds are arranged, so every kind of hand is sure to come up:
        // a pair of eights and a re-split, split aces, insurance against a
        // natural, even money, a surrender.
        let arranged: [Int: String] = [3: "8c 6d 8h Tc 8s", 11: "Ac 5d Ah Tc", 20: "Tc Ad 9h Kc", 30: "As Ad Kh 7c",
                                       45: "Tc Td 6h 7c", 60: "9c 6d 9h Tc 9s"]
        for n in 0..<80 {
            if game.engine.isBroke { game.resetBankroll() }
            if game.engine.phase == .settled, let cards = arranged[n] {
                game.pickChip(25)
                game.clearBet()
                game.stackShoeForTesting(BlackjackTests.cards(cards))
            }
            // Bet with the chips, or deal the last bet again from an empty circle.
            if n > 0 && rng.next(upperBound: 3) == 0 && game.engine.canRebet {
                game.deal()
            } else {
                let amount = [10, 25, 50, 100, 150, 200, 300][rng.next(upperBound: 7)]
                for chip in BlackjackGame.chips(for: min(amount, (game.engine.bankroll.wholeChips / 5) * 5)) { game.pickChip(chip) }
                verify("after betting")
                if n % 7 == 0, let key = keyEvent("\r", window: window) {
                    table.keyDown(with: key)
                    viaKeys += 1
                } else {
                    game.deal()
                }
            }
            if game.engine.shoe.discard.isEmpty && n > 0 { shuffles += 1 }
            verify("after the deal")
            // A round that leaves the player broke is cleared at once (the
            // scheduler runs at once here), so it ends in `betting`.
            func over() -> Bool { game.engine.phase == .settled || game.engine.phase == .betting }
            var steps = 0
            while !over() && steps < 60 {
                steps += 1
                switch game.engine.phase {
                case .insurance:
                    insurances += 1
                    if !game.isAskingInsurance { problems.append("insurance without its question") }
                    game.decideInsurance(take: rng.next(upperBound: 4) == 0)
                case .playerTurn where !game.engine.needsAdvance:
                    guard let advice = game.recommendation else { break }
                    if advice == .split { splits += 1 }
                    let keys: [BlackjackAction: String] = [.hit: "h", .stand: "s", .double: "d", .split: "p", .surrender: "r"]
                    if n % 5 == 0, let key = keyEvent(keys[advice] ?? "s", window: window) {
                        table.keyDown(with: key)
                        viaKeys += 1
                    } else {
                        game.play(advice)
                    }
                default:
                    game.runDealerForTesting()
                }
                verify("in play")
            }
            if !over() { problems.append("round \(n) stuck in \(game.engine.phase)") }
            rounds += 1
            verify("settled")
            // The payout's beat has passed (the scheduler runs at once here):
            // the winnings are back with the player, and the pill says so.
            let pill = TopBarStatus.items(for: .blackjack).first { $0.id == "bankroll" }?.text ?? ""
            if game.currentScene.chipsOnCloth != .zero || !pill.contains(game.engine.bankroll.formatted) {
                collectedOK = false
                problems.append("round \(n): \(game.currentScene.chipsOnCloth) left on the cloth, pill '\(pill)'")
            }
        }
        t.check("\(rounds) rounds played through the table's own controls (\(viaKeys) by key)",
                rounds == 80 && !problems.contains { $0.contains("stuck") })
        t.check("every chip accounted for after every click and every dealer's step", balanced)
        t.check("the cloth shows exactly the engine's cards and chips at every step", sceneMatches)
        t.check("every hand's capsule says what the hand is", labelsMatch)
        t.check("a beat after the payout the winnings are back with the player, and the bankroll pill says so", collectedOK)
        t.check("the bar offers exactly the legal plays", barMatches)
        t.check("splits, insurance and reshuffles all came up (\(splits), \(insurances), \(shuffles))",
                splits >= 3 && insurances >= 2 && shuffles > 0)
        let s = game.statistics
        t.check("the statistics count every hand once (\(s.hands) hands, \(s.rounds) rounds)",
                s.rounds == 80 && s.hands == s.wins + s.losses + s.pushes && s.hands >= 80)
        if !problems.isEmpty { t.info("first problems: \(problems.prefix(4).joined(separator: "; "))") }

        // Saved and restored: the same table, to the card.
        game.prepareToQuit()
        let restored = BlackjackGame()
        t.check("the table comes back from disk exactly as it was left", restored.engine == game.engine)

        // A round half dealt when the game leaves the screen waits for it.
        table.scheduler.isImmediate = false
        if game.engine.phase == .settled { game.pickChip(25) } else { game.rebet() }
        for chip in [25] where game.engine.pendingBet < 10 { game.pickChip(chip) }
        game.deal()
        let pending = table.scheduler.pendingCount
        let cardsBefore = game.engine.round?.cardsOnTable.count ?? -1
        game.gameWillResignActive()
        t.check("leaving mid-deal suspends the dealer (\(pending) step waiting)",
                pending == 1 && table.scheduler.isSuspended && game.engine.round?.cardsOnTable.count == cardsBefore)
        game.gameDidBecomeActive()
        table.scheduler.runPendingImmediately()
        t.check("and coming back carries on dealing", !table.scheduler.isSuspended
                && (game.engine.round?.cardsOnTable.count ?? 0) > cardsBefore)
        table.scheduler.isImmediate = true
        game.runDealerForTesting()
        while game.engine.phase != .settled {
            if game.engine.phase == .insurance { game.decideInsurance(take: false) } else if let advice = game.recommendation {
                game.play(advice)
            } else { game.runDealerForTesting() }
        }
        t.check("the books still balance", game.engine.isBalanced)
        game.gameWillResignActive()
        t.check("nothing is left scheduled once the round is over and the game is away", table.scheduler.pendingCount == 0)
        game.gameDidBecomeActive()

        modals(game, t)
        outOfChips(game, t, window: window)
        halfChips(game, t)
        layout(game, t, window: window)

        game.gameWillResignActive()
        window.contentView = nil
        Storage.remove(BlackjackSavedTable.fileName)
        Storage.remove(BlackjackStatistics.fileName)
    }

    // MARK: Questions over the table

    /// The New Game card is modal: the Blackjack menu's shortcuts wait for
    /// it like the bar's buttons do — ⌘↩ under the card must not deal a
    /// round that Start would then forfeit.
    private static func modals(_ game: BlackjackGame, _ t: TestReporter) {
        let table = game.table
        if game.engine.isBroke { game.resetBankroll() }
        if game.engine.phase == .settled { game.pickChip(25) } else if game.engine.pendingBet == 0 { game.pickChip(25) }
        let menu = game.makeGameMenu()
        func enabled(_ action: Selector) -> Bool {
            guard let item = menu.items.first(where: { $0.action == action }) else { return false }
            return game.validateMenuItem(item)
        }
        let before = (game.engine.phase, game.engine.bankroll, game.engine.pendingBet)
        t.check("between rounds Deal and Reset Bankroll are on the menu",
                enabled(#selector(BlackjackGame.dealFromMenu(_:))) && enabled(#selector(BlackjackGame.resetBankrollFromMenu(_:))))
        game.newGame(nil)
        let card = OptionsCard.presentedCards.first { $0.isDescendant(of: table) }
        t.check("New Game puts up the rules card", card != nil)
        t.check("under it Deal, Rebet, Clear Bet, Reset Bankroll and Show Hint are off the menu",
                !enabled(#selector(BlackjackGame.dealFromMenu(_:))) && !enabled(#selector(BlackjackGame.rebetFromMenu(_:)))
                    && !enabled(#selector(BlackjackGame.clearBetFromMenu(_:)))
                    && !enabled(#selector(BlackjackGame.resetBankrollFromMenu(_:))) && !enabled(#selector(BlackjackGame.showHint(_:))))
        game.dealFromMenu(nil)
        game.rebetFromMenu(nil)
        game.clearBetFromMenu(nil)
        game.resetBankrollFromMenu(nil)
        game.pickChip(100)
        t.check("and a shortcut sent anyway changes nothing on the table",
                (game.engine.phase, game.engine.bankroll, game.engine.pendingBet) == before && Banner.banners(in: table).isEmpty)
        card?.dismiss(animated: false)

        // The reset confirmation holds the table too.
        game.resetBankrollFromMenu(nil)
        t.check("Reset Bankroll… asks first, and Deal waits for the answer",
                Banner.banners(in: table).count == 1 && !enabled(#selector(BlackjackGame.dealFromMenu(_:)))
                    && table.bar.button(for: "deal")?.isEnabled == false)
        game.dealFromMenu(nil)
        t.check("(⌘↩ does not deal under it)", game.engine.phase == before.0)
        game.newGame(nil)
        t.check("New Game takes the confirmation away and asks its own question",
                Banner.banners(in: table).isEmpty && OptionsCard.presentedCards.contains { $0.isDescendant(of: table) })
        OptionsCard.presentedCards.first { $0.isDescendant(of: table) }?.dismiss(animated: false)
        game.refreshForTesting()
        t.check("and with it gone, the table is the player's again", enabled(#selector(BlackjackGame.dealFromMenu(_:))))

        // A hand being dealt when the card goes up waits for it: nothing
        // is dealt, and no question comes up, until the card is put away.
        table.scheduler.isImmediate = false
        game.clearBet()
        game.stackShoeForTesting(BlackjackTests.cards("Tc Ad 9h 7c"))
        game.pickChip(100)
        game.deal()
        game.newGame(nil)
        game.runDealerForTesting()
        t.check("under the New Game card the dealer's hands stop", game.engine.round?.cardsOnTable.isEmpty == true
                && table.scheduler.pendingCount == 0 && !game.isAskingInsurance)
        OptionsCard.presentedCards.first { $0.isDescendant(of: table) }?.cancelOperation(nil)
        game.runDealerForTesting()
        t.check("and Cancel lets the deal carry on, to the insurance question", game.engine.phase == .insurance
                && game.isAskingInsurance)
        game.decideInsurance(take: false)
        game.runDealerForTesting()
        table.scheduler.isImmediate = true
        while game.engine.phase != .settled {
            if let advice = game.recommendation { game.play(advice) } else { game.runDealerForTesting() }
        }
        game.runDealerForTesting()
    }

    /// Losing the last chips: the hand is seen, then cleared, and only then
    /// comes the offer of a new bankroll — never stacked on another question.
    private static func outOfChips(_ game: BlackjackGame, _ t: TestReporter, window: NSWindow) {
        let table = game.table
        game.resetBankroll()
        game.clearBet()
        // (Suits the arranged rounds before have not used up.)
        game.stackShoeForTesting(BlackjackTests.cards("Js 9s 6s Qs"))
        for chip in BlackjackGame.chips(for: 1_000) { game.pickChip(chip) }
        game.deal()
        game.runDealerForTesting()
        game.play(.stand)
        game.runDealerForTesting()
        t.check("a round that takes the last chip is cleared off the table", game.engine.bankroll == .zero
                && game.engine.phase == .betting && table.sceneSpriteCount == 0)
        t.check("and then the table offers a new bankroll", Banner.banners(in: table).count == 1
                && table.rack.isEnabled == false && table.bar.button(for: "deal")?.isEnabled == false)
        game.resetBankrollFromMenu(nil)
        t.check("Reset Bankroll… answers that offer rather than asking again",
                Banner.banners(in: table).isEmpty && game.engine.bankroll == 1_000 && game.engine.isBalanced)

        // A settled round that broke the player shows no offer over the hand.
        var engine = BlackjackTests.table("Tc 9d 6h Tc", bet: 100, bankroll: 100)
        BlackjackTests.runDealer(&engine)
        engine.perform(.stand)
        BlackjackTests.runDealer(&engine)
        game.adoptForScreenshot(engine, coach: .hints)
        t.check("while the losing hand is still on the cloth, nothing covers it",
                game.engine.phase == .settled && game.engine.isBroke && Banner.banners(in: table).isEmpty)
        let shown = Banner.banners(in: table).count
        game.resetBankroll()
        t.check("and a reset from there clears the hand and leaves no offer up", shown == 0
                && Banner.banners(in: table).isEmpty && game.engine.phase == .betting && game.engine.bankroll == 1_000)
    }

    /// A natural on 25 pays 37½ — on the cloth, on its capsule, in the pill.
    private static func halfChips(_ game: BlackjackGame, _ t: TestReporter) {
        let table = game.table
        // The moment the payout lands, before it is collected.
        var natural = BlackjackTests.table("As 9d Kh 8c", bet: 25)
        BlackjackTests.runDealer(&natural)
        game.adoptForScreenshot(natural, coach: .hints)
        let label = table.badgeTextForTesting("hand0") ?? ""
        t.check("a natural on 25 pays 37.5 into the circle and says so ('\(label)')",
                table.stackAmountForTesting(.payout(0)) == 37.5 && label == "Blackjack +" + BlackjackAmount(37.5).formatted)

        // Played through the table, the half reaches the bankroll.
        game.resetBankroll()
        game.clearBet()
        game.stackShoeForTesting(BlackjackTests.cards("As 9d Kh 8c"))
        game.pickChip(25)
        game.deal()
        game.runDealerForTesting()
        let pill = TopBarStatus.items(for: .blackjack).first { $0.id == "bankroll" }?.text ?? ""
        t.check("and the half reaches the bankroll ('\(pill)')", game.engine.bankroll == 1_037.5
                && pill.contains(BlackjackAmount(1_037.5).formatted) && game.engine.isBalanced)
    }

    // MARK: Nothing on top of anything

    /// At the smallest, the default and a large window: the insurance bet's
    /// capsule clear of the player's cards, the insurance question clear of
    /// the dealer's total and the player's cards, and a four-way split's
    /// chips and capsules each clear of the next hand's.
    private static func layout(_ game: BlackjackGame, _ t: TestReporter, window: NSWindow) {
        let table = game.table
        var problems: [String] = []
        func cardTop() -> CGFloat {
            table.spriteIDs.compactMap { id -> CGFloat? in
                guard let pose = table.pose(of: id), pose.position.y > table.bounds.midY * 0.8 else { return nil }
                return pose.position.y - table.cardSize.height / 2
            }.min() ?? .greatestFiniteMagnitude
        }
        for size in [CGSize(width: 960, height: 640), CGSize(width: 1200, height: 800), CGSize(width: 1728, height: 1080)] {
            window.setContentSize(size)
            game.view.frame = CGRect(origin: .zero, size: size)
            game.view.layoutSubtreeIfNeeded()
            let name = "\(Int(size.width))"

            var insured = BlackjackTests.table("Tc Ad 9h 7c")
            insured.decideInsurance(take: true)
            game.adoptForScreenshot(insured, coach: .hints)
            if let frame = table.stackFrameForTesting(.insurance), frame.maxY > cardTop() + 1 {
                problems.append("\(name): the insurance bet runs under the cards")
            }

            game.adoptForScreenshot(BlackjackTests.table("Tc Ad 9h 7c"), coach: .hints)
            if let prompt = table.prompt, let dealer = table.badgeFrameForTesting("dealer") {
                if prompt.frame.intersects(dealer) { problems.append("\(name): the insurance question covers the dealer's total") }
                if prompt.frame.maxY > cardTop() { problems.append("\(name): the insurance question covers the cards") }
            } else {
                problems.append("\(name): no insurance question")
            }

            var split = BlackjackTests.table("8s 6c 8h Tc 8d 8c 3c Kd 2h 9s Qs 5d 7s", bet: 185, bankroll: 2_000)
            for action in [BlackjackAction.split, .split, .split, .double, .double, .stand, .stand] {
                split.perform(action)
                BlackjackTests.runDealer(&split)
            }
            game.adoptForScreenshot(split, coach: .hints)
            // The chips and capsules themselves, not the shadow room round them.
            func chips(_ key: BlackjackScene.Stack) -> CGRect? { table.stackFrameForTesting(key)?.insetBy(dx: 6, dy: 0) }
            for i in 0..<3 {
                if let payout = chips(.payout(i)), let next = chips(.bet(i + 1)), payout.intersects(next) {
                    problems.append("\(name): hand \(i)'s winnings run into hand \(i + 1)'s bet")
                }
                if let a = table.badgeFrameForTesting("hand\(i)"), let b = table.badgeFrameForTesting("hand\(i + 1)"), a.intersects(b) {
                    problems.append("\(name): hand \(i)'s capsule overlaps hand \(i + 1)'s")
                }
            }
            if split.round?.hands.count != 4 || split.phase != .settled { problems.append("\(name): the split did not play out") }
        }
        window.setContentSize(CGSize(width: 1200, height: 800))
        game.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        game.view.layoutSubtreeIfNeeded()
        if !problems.isEmpty { t.info("layout: \(problems.joined(separator: "; "))") }
        t.check("at 960, 1200 and 1728 wide nothing on the cloth covers anything it should not", problems.isEmpty)
        game.resetBankroll()
    }

    private static func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        let codes: [String: UInt16] = ["3": 20, "h": 4, "s": 1, "d": 2, "p": 35, "r": 15, "\r": 36]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: codes[characters] ?? 0)
    }
}
