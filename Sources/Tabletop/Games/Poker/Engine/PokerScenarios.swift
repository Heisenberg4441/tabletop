//
//  PokerScenarios.swift
//  The tables `--shot poker --scenario …` photographs, built by playing the
//  engine rather than by setting fields: seeded deals, scripted choices for
//  the player, and the real bots for everyone else — so a screenshot can
//  only ever show a position the rules allow.
//
//  Each builder is deterministic. Where the story needs particular cards
//  (the player's flush at the showdown), they are rigged right after the
//  deal, before anybody acts on them.
//

import Foundation

enum PokerScenarios {

    /// In the order `--shot` lists them; the first is the default.
    static let names = ["preflop", "flop", "showdown", "sidepots", "headsup"]

    /// Samples for the bots while building a scene: enough to play
    /// sensibly, few enough to build instantly.
    static let samples = 300

    static func table(_ name: String?, humanName: String? = nil) -> PokerTable? {
        let you = humanName ?? NSLocalizedString("You", comment: "poker: the human player's seat name")
        switch name ?? names[0] {
        case "preflop": return preflop(you)
        case "flop": return flop(you)
        case "showdown": return showdown(you)
        case "sidepots": return sidePots(you)
        case "headsup": return headsUp(you)
        default: return nil
        }
    }

    /// Six-handed, early in a tournament: the bots before the player have
    /// acted and it is the player's turn with ace-king suited.
    static func preflop(_ you: String) -> PokerTable? {
        for seed in UInt64(2_026)..<2_226 {
            var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: seed, humanName: you)
            table.startHand()
            table.rigForTesting(hole: [0: PokerNotation.cards("Ah Kh")], board: [])
            PokerBot.playOut(&table, stopAtHuman: true, samples: samples)
            // Somebody opened in front, and at least three players are still in.
            let raised = table.handLog.contains { $0.isAggressive }
            if table.isHumanToAct && table.street == .preflop && raised
                && table.players.filter(\.isInHand).count >= 4 {
                return table
            }
        }
        return nil
    }

    /// The player called before the flop and is first to act on it, with
    /// top pair and a flush draw.
    static func flop(_ you: String) -> PokerTable? {
        for seed in UInt64(3_100)..<3_400 {
            var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: seed, humanName: you)
            table.startHand()
            table.rigForTesting(hole: [0: PokerNotation.cards("Ah Kh")], board: PokerNotation.cards("Ks 9h 4h 2c Qd"))
            guard play(&table, until: { $0.street == .flop && $0.isHumanToAct }) else { continue }
            if table.players.filter(\.isInHand).count >= 3 && table.potTotal >= 60 { return table }
        }
        return nil
    }

    /// Just after the showdown: the player's ace-high flush took the pot
    /// from a bot's two pair.
    static func showdown(_ you: String) -> PokerTable? {
        for seed in UInt64(4_200)..<4_600 {
            var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: seed, humanName: you)
            table.startHand()
            guard let rival = table.players.first(where: { !$0.isHuman && $0.seat == 2 })?.seat else { return nil }
            table.rigForTesting(hole: [0: PokerNotation.cards("Ah 5h"), rival: PokerNotation.cards("Kd Qd")],
                                board: PokerNotation.cards("Ks 9h 4h Qc 2h"))
            guard play(&table, until: { $0.phase == .betweenHands }) else { continue }
            if let summary = table.lastSummary, summary.shown.count >= 2,
               summary.biggestWinner == 0, summary.totalPot >= 150 {
                return table
            }
        }
        return nil
    }

    /// Two short stacks all-in before the flop, three players still betting:
    /// a main pot and a side pot on the table, the player to act on the flop.
    static func sidePots(_ you: String) -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 5_150, humanName: you)
        table.setStacksForTesting([1_000, 120, 1_000, 310, 1_000, 1_000])
        table.setButtonForTesting(4)
        table.startHand()
        table.rigForTesting(hole: [0: PokerNotation.cards("Qs Qh"), 1: PokerNotation.cards("Ac 7c"),
                                   3: PokerNotation.cards("9d 9c"), 2: PokerNotation.cards("Kc Jd")],
                            board: PokerNotation.cards("Jh 8s 3c Td 2s"))
        // Script: the short stacks shove, the deep stacks call, the rest fold.
        var steps = 0
        while table.street == .preflop && steps < 40 {
            steps += 1
            if table.phase == .streetComplete { table.advance(); break }
            guard let seat = table.toAct, let o = table.options() else { break }
            let action: PokerAction
            switch seat {
            case 1, 3: action = .allIn
            case 0, 2: action = o.canCall ? .call : .check
            default: action = o.canCheck ? .check : .fold
            }
            _ = try? table.apply(action)
        }
        if table.phase == .streetComplete { table.advance() }
        // The first deep stack left of the button checks; the player is next.
        while table.phase == .betting, let seat = table.toAct, seat != 0 {
            _ = try? table.apply(.check)
        }
        guard table.street == .flop, table.isHumanToAct, table.pots.count >= 2 else { return nil }
        return table
    }

    /// One opponent, a tournament a few levels in, the player to act.
    static func headsUp(_ you: String) -> PokerTable? {
        for seed in UInt64(6_000)..<6_200 {
            var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 1), seed: seed, humanName: you)
            // Play a few levels in so the blinds (and the stacks) have moved.
            var ok = true
            for _ in 0..<18 where ok {
                table.startHand()
                ok = play(&table, until: { $0.phase == .betweenHands }, humanPolicy: .foldOrCheck)
                if table.phase == .gameOver { ok = false }
            }
            guard ok else { continue }
            table.startHand()
            table.rigForTesting(hole: [0: PokerNotation.cards("Jc Js")], board: [])
            guard play(&table, until: { $0.isHumanToAct }) else { continue }
            if table.street == .preflop && table.players[0].stack > 400 { return table }
        }
        return nil
    }

    enum HumanPolicy { case callDown, foldOrCheck }

    /// Plays on — bots by their own lights, the player by `humanPolicy` —
    /// until `condition` holds (true) or the hand ends first (false, unless
    /// the end is what was asked for).
    static func play(_ table: inout PokerTable, until condition: (PokerTable) -> Bool,
                     humanPolicy: HumanPolicy = .callDown) -> Bool {
        var steps = 0
        while steps < 500 {
            steps += 1
            if condition(table) { return true }
            switch table.phase {
            case .betting:
                guard let seat = table.toAct, let o = table.options() else { return false }
                let action: PokerAction
                if table.players[seat].isHuman {
                    switch humanPolicy {
                    case .callDown: action = o.passiveAction
                    case .foldOrCheck: action = o.canCheck ? .check : .fold
                    }
                } else {
                    action = PokerBot.decide(table: table, seat: seat, samples: samples).action
                }
                guard (try? table.apply(action)) != nil else { return false }
            case .streetComplete:
                table.advance()
            case .betweenHands, .gameOver:
                return condition(table)
            }
        }
        return false
    }
}
