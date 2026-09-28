//
//  PokerBotSimulation.swift
//  How the bots actually play, in numbers: `Tabletop --selftest poker
//  --poker-sim N` seats six of them at a cash table for N hands and prints
//  the statistics a poker player would look at — how often each character
//  plays a hand, raises, bets, goes to showdown, and what it wins — and
//  whether the sharper bots take the casual ones' chips.
//
//  A tuning instrument rather than a test: nothing here passes or fails.
//

import Foundation

enum PokerBotSimulation {

    struct SeatStats {
        var hands = 0
        var voluntary = 0          // VPIP: called or raised preflop
        var raisedPreflop = 0      // PFR
        var aggressive = 0         // postflop bets and raises
        var passive = 0            // postflop calls
        var sawFlop = 0
        var showdowns = 0
        var wonAtShowdown = 0
        var allIns = 0
        var net = 0
        var checkedTo = 0          // postflop: could check
        var betWhenCheckedTo = 0
        var facedBet = 0           // postflop: facing a bet
        var foldedToBet = 0
        var raisedBet = 0
    }

    static func run(hands: Int, samples: Int?, _ t: TestReporter) {
        t.section("Poker — bot simulation (\(hands) hands, six-handed cash)")
        var byPersonality: [PokerPersonality: SeatStats] = [:]
        var byDifficulty: [PokerDifficulty: SeatStats] = [:]
        var rng = DeterministicRNG(seed: 1_234)
        var played = 0
        var tableIndex = 0
        var potSizes: [Int] = []
        let start = ProcessInfo.processInfo.systemUptime
        while played < hands {
            tableIndex += 1
            var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 6, includesHuman: false),
                                   seed: rng.next())
            // Every difficulty at every table, the seats rotating so no level
            // always sits in the same spot.
            let levels: [PokerDifficulty] = (0..<6).map { PokerDifficulty.allCases[($0 + tableIndex) % 3] }
            for _ in 0..<100 where played < hands {
                let before = table.players.map(\.stack)
                table.startHand()
                played += 1
                var steps = 0
                while (table.phase == .betting || table.phase == .streetComplete) && steps < 400 {
                    steps += 1
                    if table.phase == .streetComplete { table.advance(); continue }
                    guard let seat = table.toAct else { break }
                    let decision = PokerBot.decide(table: table, seat: seat, samples: samples, difficulty: levels[seat])
                    if table.street > .preflop, let o = table.options() {
                        var s = SeatStats()
                        let aggressive: Bool
                        switch decision.action {
                        case .bet, .raise: aggressive = true
                        case .allIn: aggressive = !o.callIsAllIn
                        default: aggressive = false
                        }
                        if o.canCheck {
                            s.checkedTo = 1
                            s.betWhenCheckedTo = aggressive ? 1 : 0
                        } else {
                            s.facedBet = 1
                            s.foldedToBet = decision.action == .fold ? 1 : 0
                            s.raisedBet = aggressive ? 1 : 0
                        }
                        byPersonality[table.players[seat].personality, default: SeatStats()].add(s)
                        byDifficulty[levels[seat], default: SeatStats()].add(s)
                    }
                    _ = try? table.apply(decision.action)
                }
                guard let summary = table.lastSummary else { continue }
                potSizes.append(summary.totalPot)
                let log = table.handLog
                for p in table.players where p.status != .out || before[p.seat] > 0 {
                    guard !p.holeCards.isEmpty else { continue }
                    var s = SeatStats()
                    s.hands = 1
                    let mine = log.filter { $0.seat == p.seat }
                    let pre = mine.filter { $0.street == .preflop }
                    if pre.contains(where: { $0.kind == .call || $0.isAggressive }) { s.voluntary = 1 }
                    if pre.contains(where: \.isAggressive) { s.raisedPreflop = 1 }
                    let post = mine.filter { $0.street > .preflop }
                    s.aggressive = post.filter(\.isAggressive).count
                    s.passive = post.filter { $0.kind == .call }.count
                    let foldedPreflop = pre.contains { $0.kind == .fold }
                    if !foldedPreflop && table.board.count >= 3 { s.sawFlop = 1 }
                    if summary.shown.contains(where: { $0.seat == p.seat }) {
                        s.showdowns = 1
                        if (summary.winnings[p.seat] ?? 0) > 0 { s.wonAtShowdown = 1 }
                    }
                    if mine.contains(where: \.isAllIn) { s.allIns = 1 }
                    s.net = summary.netChange[p.seat]
                    byPersonality[p.personality, default: SeatStats()].add(s)
                    byDifficulty[levels[p.seat], default: SeatStats()].add(s)
                }
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        func line(_ name: String, _ s: SeatStats) -> String {
            let h = Double(max(1, s.hands))
            return String(format: "%@: VPIP %.0f%%  PFR %.0f%%  AF %.1f  saw flop %.0f%%  WTSD %.0f%%  W$SD %.0f%%  all-in %.1f%%  net %+.1f BB/100",
                          name, Double(s.voluntary) / h * 100, Double(s.raisedPreflop) / h * 100,
                          Double(s.aggressive) / Double(max(1, s.passive)),
                          Double(s.sawFlop) / h * 100, Double(s.showdowns) / Double(max(1, s.sawFlop)) * 100,
                          Double(s.wonAtShowdown) / Double(max(1, s.showdowns)) * 100, Double(s.allIns) / h * 100,
                          Double(s.net) / 10 / h * 100)
                + String(format: "  | bets when checked to %.0f%%, vs a bet: fold %.0f%% raise %.0f%%",
                         Double(s.betWhenCheckedTo) / Double(max(1, s.checkedTo)) * 100,
                         Double(s.foldedToBet) / Double(max(1, s.facedBet)) * 100,
                         Double(s.raisedBet) / Double(max(1, s.facedBet)) * 100)
        }
        for personality in PokerPersonality.allCases {
            if let s = byPersonality[personality] { t.info(line(personality.rawValue, s)) }
        }
        for difficulty in PokerDifficulty.allCases {
            if let s = byDifficulty[difficulty] { t.info(line(difficulty.rawValue, s)) }
        }
        let sorted = potSizes.sorted()
        t.info(String(format: "pots: median %d, 90th percentile %d; %.1f ms per hand",
                      sorted[safe: sorted.count / 2] ?? 0, sorted[safe: sorted.count * 9 / 10] ?? 0,
                      elapsed / Double(max(1, played)) * 1e3))
    }
}

extension PokerBotSimulation {

    /// `--poker-tournaments N`: how long Sit & Gos last and how their hands
    /// end, for every table size.
    static func runTournaments(_ count: Int, samples: Int?, _ t: TestReporter) {
        t.section("Poker — tournament simulation (\(count) per table size)")
        var rng = DeterministicRNG(seed: 4_321)
        for players in 2...6 {
            var lengths: [Int] = []
            var showdowns = 0, hands = 0
            for _ in 0..<count {
                var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: players,
                                                                includesHuman: false), seed: rng.next())
                var played = 0
                while table.phase != .gameOver && played < 2_000 {
                    table.startHand()
                    played += 1
                    PokerBot.playOut(&table, samples: samples)
                    if table.lastSummary?.shown.isEmpty == false { showdowns += 1 }
                }
                lengths.append(played)
                hands += played
            }
            lengths.sort()
            t.info(String(format: "%d players: median %d hands (shortest %d, longest %d); %.0f%% of hands shown down",
                          players, lengths[lengths.count / 2], lengths.first ?? 0, lengths.last ?? 0,
                          Double(showdowns) / Double(max(1, hands)) * 100))
        }
    }
}

extension PokerBotSimulation.SeatStats {
    mutating func add(_ o: Self) {
        hands += o.hands
        voluntary += o.voluntary
        raisedPreflop += o.raisedPreflop
        aggressive += o.aggressive
        passive += o.passive
        sawFlop += o.sawFlop
        showdowns += o.showdowns
        wonAtShowdown += o.wonAtShowdown
        allIns += o.allIns
        net += o.net
        checkedTo += o.checkedTo
        betWhenCheckedTo += o.betWhenCheckedTo
        facedBet += o.facedBet
        foldedToBet += o.foldedToBet
        raisedBet += o.raisedBet
    }
}
