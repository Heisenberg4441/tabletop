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
        guard let table = game.table else {
            t.check("the table loads", false)
            return
        }
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
                for chip in BlackjackGame.chips(for: min(amount, (game.engine.bankroll / 5) * 5)) { game.pickChip(chip) }
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
            var steps = 0
            while game.engine.phase != .settled && steps < 60 {
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
            if game.engine.phase != .settled { problems.append("round \(n) stuck in \(game.engine.phase)") }
            rounds += 1
            verify("settled")
            // The payout's beat has passed (the scheduler runs at once here):
            // the winnings are back with the player, and the pill says so.
            let pill = TopBarStatus.items(for: .blackjack).first { $0.id == "bankroll" }?.text ?? ""
            if game.currentScene.chipsOnCloth != 0 || !pill.contains(Chips.format(game.engine.bankroll)) {
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
        window.contentView = nil
        Storage.remove(BlackjackSavedTable.fileName)
        Storage.remove(BlackjackStatistics.fileName)
    }

    private static func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent? {
        let codes: [String: UInt16] = ["3": 20, "h": 4, "s": 1, "d": 2, "p": 35, "r": 15, "\r": 36]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: codes[characters] ?? 0)
    }
}
