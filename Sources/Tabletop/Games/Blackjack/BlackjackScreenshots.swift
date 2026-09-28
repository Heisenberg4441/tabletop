//
//  BlackjackScreenshots.swift
//  The tables `--shot blackjack --scenario NAME` photographs.
//
//  Each starts from the same seeded shoe played a dozen rounds in by basic
//  strategy — so the discard holder has cards in it, the shoe is part
//  used, and there is a last bet to repeat — and then arranges the next
//  cards in the shoe and plays the named moment through the real engine:
//
//    betting    150 in the circle, the chips in the bar
//    decision   11 against a 6, the hint lit (Double)
//    split      eights split three ways, the first doubled, the second in play
//    insurance  19 against the dealer's ace, the question asked
//    settled    a doubled 11 made 21, the dealer bust, the winnings paid
//    new-game   the table rules card
//

import AppKit

@MainActor
enum BlackjackScreenshots {

    static func prepare(_ game: BlackjackGame, scenario: String) {
        var engine = warmTable()
        var coach = BlackjackCoachLevel.hints
        switch scenario {
        case "decision":
            deal("5h 6c 6d Ts", into: &engine)
        case "split":
            deal("8s 6c 8h Tc 8d 3c Kd 2h 9s 7d", into: &engine)
            engine.perform(.split)
            finishDealer(&engine)
            engine.perform(.split)
            finishDealer(&engine)
            engine.perform(.double)
            finishDealer(&engine)
            coach = .hints
        case "insurance":
            deal("Th Ac 9d 7s", into: &engine)
        case "settled":
            deal("6h 6c 5d Ts Kh 9c", into: &engine)
            engine.perform(.double)
            finishDealer(&engine)
        default:
            // betting, new-game
            for chip in [100, 25, 25] { engine.addToBet(chip) }
        }
        game.adoptForScreenshot(engine, coach: coach)
        switch scenario {
        case "decision": game.showHint(nil)
        case "new-game": game.newGame(nil)
        default: break
        }
    }

    /// A six-deck shoe a dozen rounds in.
    private static func warmTable() -> BlackjackEngine {
        var engine = BlackjackEngine(seed: 0x5407_0001)
        let bets = [25, 50, 50, 100, 25, 75, 100, 50, 150, 100, 50, 100]
        for bet in bets {
            engine.addToBet(bet)
            engine.deal()
            while engine.phase != .settled {
                if engine.needsAdvance {
                    engine.advance()
                } else if engine.phase == .insurance {
                    engine.decideInsurance(take: false)
                } else if let hand = engine.activeHand, let up = engine.round?.upCard {
                    engine.perform(BlackjackStrategy.recommendation(for: hand, upCard: up, rules: engine.rules,
                                                                    legal: engine.legalActions()))
                } else {
                    break
                }
            }
            engine.collect()
        }
        return engine
    }

    /// Bets 100 on the named cards and deals them.
    private static func deal(_ cards: String, into engine: inout BlackjackEngine) {
        engine.stackShoe(BlackjackTests.cards(cards))
        engine.addToBet(100)
        engine.deal()
        finishDealer(&engine)
    }

    private static func finishDealer(_ engine: inout BlackjackEngine) {
        var steps = 0
        while engine.needsAdvance && steps < 50 {
            engine.advance()
            steps += 1
        }
    }
}
