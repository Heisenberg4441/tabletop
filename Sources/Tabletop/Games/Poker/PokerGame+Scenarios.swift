//
//  PokerGame+Scenarios.swift
//  The screenshot scenes beyond the engine's five: a bot thinking while the
//  player waits, an all-in runout with the hands turned up, the end of a
//  tournament, and the New Game card — and the crowded moments the layout
//  has to survive: the seat across a heads-up table showing down, six bets
//  of four stacks each, a bet from the far side with a pot in the middle,
//  five pots, the longest name for the player's hand, a split pot. Built
//  like the engine's — by playing the engine, seeded, with everyone's
//  choices scripted — so each shows a position the rules allow.
//

import Foundation

extension PokerGame {

    static let extraScenarios = ["thinking", "runout", "tournament-end", "new-game",
                                 "three-handed", "four-handed", "five-handed",
                                 "headsup-showdown", "big-bets", "top-bet", "five-pots", "long-hand", "split-pot"]

    /// The table for a scenario, the engine's five included.
    static func scenarioTable(_ name: String) -> PokerTable? {
        switch name {
        case "thinking": return thinkingTable()
        case "runout": return runoutTable()
        case "tournament-end": return tournamentEndTable()
        case "new-game": return PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: 1)
        case "three-handed": return handed(3)
        case "four-handed": return handed(4)
        case "five-handed": return handed(5)
        case "headsup-showdown": return headsUpShowdown()
        case "big-bets": return bigBets()
        case "top-bet": return topBet()
        case "five-pots": return fivePots()
        case "long-hand": return longHand()
        case "split-pot": return splitPot()
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

    /// `players` at the table, the flop out, the player to act with chips
    /// in front of somebody — to see the seats balanced at every count.
    private static func handed(_ players: Int) -> PokerTable? {
        for seed in UInt64(10_000 + players * 100)..<UInt64(10_200 + players * 100) {
            var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: players - 1), seed: seed)
            table.startHand()
            let found = PokerScenarios.play(&table, until: { t in
                t.street == .flop && t.isHumanToAct && t.players.filter(\.isInHand).count >= players - 1
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

    // MARK: Crowded moments

    /// Plays `table` on, asking `choose` for every action, until it returns
    /// nil (that seat is left to act) or the hand ends. False if a scripted
    /// action was not legal.
    @discardableResult
    private static func script(_ table: inout PokerTable,
                               _ choose: (PokerTable, Int, PokerActionOptions) -> PokerAction?) -> Bool {
        for _ in 0..<300 {
            switch table.phase {
            case .betting:
                guard let seat = table.toAct, let o = table.options() else { return true }
                guard let action = choose(table, seat, o) else { return true }
                guard (try? table.apply(action)) != nil else { return false }
            case .streetComplete:
                table.advance()
            case .betweenHands, .gameOver:
                return true
            }
        }
        return true
    }

    /// Heads-up, checked down to the river: the seat across the table turns
    /// up the better hand — its cards, its hand's name and the result all in
    /// the space between it and the board.
    private static func headsUpShowdown() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 1), seed: 791)
        table.startHand()
        table.rigForTesting(hole: [0: PokerNotation.cards("Ac 3d"), 1: PokerNotation.cards("Kd Kc")],
                            board: PokerNotation.cards("Ks 9h 4h Qc 2h"))
        guard script(&table, { t, seat, o in
            if o.canBet && t.street == .flop && seat == 1 { return .bet(60) }
            return o.canCheck ? .check : .call
        }), table.phase == .betweenHands, table.lastSummary?.shown.isEmpty == false else { return nil }
        return table
    }

    /// Six bets of four stacks each: the player raises to 1,480 and
    /// everyone moves in behind them — so the two seats at each end of the
    /// oval have their largest bets side by side.
    private static func bigBets() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 5), seed: 777)
        table.setStacksForTesting([1_500, 1_480, 1_365, 1_290, 1_455, 1_235])
        // The button moves on to seat 3 as the hand starts: the player is
        // first to speak.
        table.setButtonForTesting(2)
        table.startHand()
        // Stopped with the round complete and the bets still out in front.
        while table.phase == .betting {
            guard let seat = table.toAct, (try? table.apply(seat == 0 ? .raise(1_480) : .allIn)) != nil else { return nil }
        }
        guard table.players.allSatisfy({ $0.bet > 0 }) else { return nil }
        return table
    }

    /// The flop: the seat across the table bets 600 into a pot of 1,200,
    /// and it comes round to the player — the far seat's chips and the pot
    /// both in the middle of the table.
    private static func topBet() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 781)
        table.setButtonForTesting(1)
        table.startHand()
        table.rigForTesting(hole: [0: PokerNotation.cards("Jd Tc")], board: PokerNotation.cards("Jh 8s 3c Td 2s"))
        guard script(&table, { t, seat, o in
            if t.street == .preflop {
                if o.currentBet < 200 { return .raise(200) }
                return o.canCall ? .call : .check
            }
            switch seat {
            case 3: return .bet(600)
            case 4: return .fold
            case 5: return .call
            case 0: return nil
            default: return o.canCheck ? .check : .fold
            }
        }), table.isHumanToAct, table.street == .flop else { return nil }
        return table
    }

    /// Four players all in for four different amounts before the flop, two
    /// betting on after it: a main pot and four side pots.
    private static func fivePots() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 792)
        table.setStacksForTesting([2_000, 100, 300, 600, 1_000, 2_000])
        table.setButtonForTesting(4)
        table.startHand()
        table.rigForTesting(hole: [:], board: PokerNotation.cards("Jh 8s 3c Td 2s"))
        guard script(&table, { t, seat, o in
            if t.street == .preflop {
                return (1...4).contains(seat) ? .allIn : (o.canCall ? .call : .check)
            }
            if t.street == .flop { return o.canBet ? .bet(300) : .call }
            return seat == 0 ? nil : (o.canCheck ? .check : .call)
        }), table.pots.count >= 5, table.isHumanToAct else { return nil }
        return table
    }

    /// The player's full house, Queens over Sevens — the longest name the
    /// pill by their cards can have — with six at the table.
    private static func longHand() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 794)
        table.startHand()
        table.rigForTesting(hole: [0: PokerNotation.cards("Qs Qh")], board: PokerNotation.cards("Qc 7d 7s 2h 3c"))
        guard script(&table, { t, seat, o in
            if t.street == .preflop { return o.canCheck ? .check : .call }
            if seat == 0 { return nil }
            return o.canCheck ? .check : .call
        }), table.isHumanToAct, table.street >= .flop else { return nil }
        return table
    }

    /// A royal flush on the board: the player and the seat across the table
    /// split the pot.
    private static func splitPot() -> PokerTable? {
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 783)
        table.startHand()
        table.rigForTesting(hole: [0: PokerNotation.cards("2c 3d"), 3: PokerNotation.cards("4c 5d")],
                            board: PokerNotation.cards("Ah Kh Qh Jh Th"))
        guard script(&table, { _, seat, o in
            if seat == 0 || seat == 3 { return o.canCheck ? .check : .call }
            return o.canCheck ? .check : .fold
        }), table.phase == .betweenHands else { return nil }
        return table
    }
}
