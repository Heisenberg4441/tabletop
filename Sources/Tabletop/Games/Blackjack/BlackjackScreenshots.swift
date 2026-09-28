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
//    cut-card   a natural paid on the last hand before the shuffle, the cut
//               card out on the cloth
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
        case "cut-card":
            // Rounds until the next deal takes the cut card out (collecting
            // a round with it out would shuffle, so stop just short).
            var rounds = 0
            while engine.shoe.undealt.count > engine.shoe.cutRemaining + 5 && rounds < 200 {
                playRound(&engine, bet: 50)
                rounds += 1
            }
            deal("As 9d Kh 7c", into: &engine)
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
        for bet in [25, 50, 50, 100, 25, 75, 100, 50, 150, 100, 50, 100] { playRound(&engine, bet: bet) }
        return engine
    }

    /// One round by basic strategy, collected.
    private static func playRound(_ engine: inout BlackjackEngine, bet: Int) {
        if engine.isBroke { engine.resetBankroll() }
        engine.addToBet(min(bet, engine.betHeadroom))
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

    /// Bets 100 on the named cards and deals them. A shoe well into its run
    /// may have dealt every copy of one of them; then the same rank in
    /// another suit stands in (or, for a ten, any ten-card).
    private static func deal(_ cards: String, into engine: inout BlackjackEngine) {
        var pool = engine.shoe.undealt.map { Card(code: UInt8($0 % 52)) }
        var arranged: [Card] = []
        for card in BlackjackTests.cards(cards) {
            let index = pool.lastIndex(of: card) ?? pool.lastIndex { $0.rank == card.rank }
                ?? pool.lastIndex { min(10, $0.value) == min(10, card.value) }
            if let index { arranged.append(pool.remove(at: index)) }
        }
        engine.stackShoe(arranged)
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
