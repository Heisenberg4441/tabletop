//
//  PokerGame+Scenarios.swift
//  The screenshot scenes beyond the engine's five: a bot thinking while the
//  player waits, an all-in runout with the hands turned up, the end of a
//  tournament, and the New Game card. Built like the engine's — by playing
//  the engine, seeded, with the player's choices scripted — so each shows a
//  position the rules allow.
//

import Foundation

extension PokerGame {

    static let extraScenarios = ["thinking", "runout", "tournament-end", "new-game"]

    /// The table for a scenario, the engine's five included.
    static func scenarioTable(_ name: String) -> PokerTable? {
        switch name {
        case "thinking": return thinkingTable()
        case "runout": return runoutTable()
        case "tournament-end": return tournamentEndTable()
        case "new-game": return PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: 1)
        default: return PokerScenarios.table(name)
        }
    }

    /// The flop, the player still in with chips behind, a bot to act after
    /// them — its ring sweeping.
    private static func thinkingTable() -> PokerTable? {
        for seed in UInt64(7_300)..<7_500 {
            var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: seed)
            table.startHand()
            table.rigForTesting(hole: [0: PokerNotation.cards("Qs Js")], board: PokerNotation.cards("Qh 8s 3s 5d Kc"))
            let found = PokerScenarios.play(&table, until: { t in
                guard t.street == .flop, t.phase == .betting, let seat = t.toAct, seat != 0 else { return false }
                return t.players[0].hasActed && t.players[0].canAct && t.players.filter(\.isInHand).count >= 3
            })
            if found { return table }
        }
        return nil
    }

    /// The player all-in before the flop with aces, called by kings: the
    /// hands are up and the flop is out, the turn and river to come.
    private static func runoutTable() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 8_080)
        table.setButtonForTesting(3)
        table.startHand()
        let caller = 2
        table.rigForTesting(hole: [0: PokerNotation.cards("Ad Ac"), caller: PokerNotation.cards("Kh Ks")],
                            board: PokerNotation.cards("Kd 7c 2h 9s 4c"))
        var steps = 0
        while table.phase == .betting, steps < 40 {
            steps += 1
            guard let seat = table.toAct, let o = table.options() else { break }
            let action: PokerAction
            if seat == 0 {
                action = .allIn
            } else if seat == caller {
                action = o.canCall ? .call : (o.canCheck ? .check : .allIn)
            } else {
                action = o.canCheck ? .check : .fold
            }
            guard (try? table.apply(action)) != nil else { return nil }
        }
        guard table.phase == .streetComplete else { return nil }
        table.advance()
        guard table.handsAreRevealed, table.street == .flop else { return nil }
        return table
    }

    /// A heads-up tournament the player has just won, the last hand still
    /// on the table.
    private static func tournamentEndTable() -> PokerTable? {
        for seed in UInt64(9_000)..<9_060 {
            var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 1), seed: seed)
            var hands = 0
            while table.phase == .betweenHands && hands < 200 {
                hands += 1
                table.startHand()
                PokerBot.playOut(&table, samples: 120)
            }
            if table.phase == .gameOver, table.humanPlace == 1,
               let summary = table.lastSummary, !summary.shown.isEmpty {
                return table
            }
        }
        return nil
    }
}
