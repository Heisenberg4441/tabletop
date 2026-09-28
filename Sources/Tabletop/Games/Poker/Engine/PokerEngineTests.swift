//
//  PokerEngineTests.swift
//  The engine's checks: the evaluator against the known hand counts and a
//  slow reference, the betting rules case by case, then tens of thousands of
//  random and bot-played hands that must conserve every chip and always end.
//
//  Sizes adapt to the build: a debug build (what `--selftest` normally runs)
//  keeps the suite to a few seconds with smaller samples and cheaper bots; a
//  release build runs the full-size versions. The numbers printed say which.
//

import Foundation

enum PokerEngineTests {

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    static func run(_ t: TestReporter) {
        // `--selftest poker --poker-sim N` / `--poker-tournaments N`
        // [`--poker-samples S`]: the bots' playing statistics instead of the
        // tests (see PokerBotSimulation).
        let samples = TabletopEnvironment.value(of: "--poker-samples").flatMap(Int.init)
        if let hands = TabletopEnvironment.value(of: "--poker-sim").flatMap(Int.init) {
            PokerBotSimulation.run(hands: hands, samples: samples, t)
            return
        }
        if let count = TabletopEnvironment.value(of: "--poker-tournaments").flatMap(Int.init) {
            PokerBotSimulation.runTournaments(count, samples: samples, t)
            return
        }
        evaluator(t)
        betting(t)
        modes(t)
        persistence(t)
        fuzz(t)
        bots(t)
    }

    // MARK: - Helpers

    static func cards(_ codes: String) -> [Card] {
        PokerNotation.cards(codes)
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// A table of bots with these stacks whose first hand puts the button on
    /// `button`.
    static func makeTable(_ stacks: [Int], mode: PokerMode = .cash, button: Int, seed: UInt64 = 7,
                          difficulty: PokerDifficulty = .standard) -> PokerTable {
        var table = PokerTable(config: PokerTableConfig(mode: mode, opponents: stacks.count, difficulty: difficulty,
                                                        includesHuman: false), seed: seed)
        table.setStacksForTesting(stacks)
        // The next hand moves the button to the next seat with chips, so
        // park it on the live seat before the one wanted.
        var previous = button
        repeat { previous = (previous - 1 + stacks.count) % stacks.count } while stacks[previous] == 0 && previous != button
        table.setButtonForTesting(previous)
        return table
    }

    @discardableResult
    static func act(_ table: inout PokerTable, _ action: PokerAction) -> [PokerEvent]? {
        try? table.apply(action)
    }

    /// Advances through every remaining street with nobody betting (checks
    /// or runouts) and returns all the events.
    @discardableResult
    static func checkDown(_ table: inout PokerTable) -> [PokerEvent] {
        var events: [PokerEvent] = []
        var steps = 0
        while steps < 100 {
            steps += 1
            switch table.phase {
            case .streetComplete: events += table.advance()
            case .betting:
                guard let o = table.options() else { return events }
                events += (try? table.apply(o.canCheck ? .check : .call)) ?? []
            default: return events
            }
        }
        return events
    }

    // MARK: - Evaluator

    /// A slow, obviously-correct five-card ranking to compare the fast one
    /// with: category first, then the tie-break ranks in order.
    static func reference(_ hand: [Card]) -> [Int] {
        let ranks = hand.map(\.pokerRank)
        var counts: [Int: Int] = [:]
        for r in ranks { counts[r, default: 0] += 1 }
        let groups = counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        let flush = Set(hand.map(\.suit)).count == 1
        let distinct = Set(ranks).sorted(by: >)
        var straight: Int?
        if distinct.count == 5 {
            if distinct[0] - distinct[4] == 4 { straight = distinct[0] }
            if distinct == [12, 3, 2, 1, 0] { straight = 3 }
        }
        let byRank = ranks.sorted(by: >)
        if let s = straight, flush { return [8, s] }
        if groups[0].value == 4 { return [7, groups[0].key, groups[1].key] }
        if groups[0].value == 3 && groups[1].value == 2 { return [6, groups[0].key, groups[1].key] }
        if flush { return [5] + byRank }
        if let s = straight { return [4, s] }
        if groups[0].value == 3 { return [3] + groups.map(\.key) }
        if groups[0].value == 2 && groups[1].value == 2 { return [2] + groups.map(\.key) }
        if groups[0].value == 2 { return [1] + groups.map(\.key) }
        return [0] + byRank
    }

    static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }

    static func evaluator(_ t: TestReporter) {
        t.section("Poker — hand evaluator")

        func named(_ codes: String) -> PokerHandResult { PokerEvaluator.best(cards(codes)) }

        let royal = named("As Ks Qs Js Ts 2d 3c")
        t.check("a royal flush is a straight flush called Royal Flush",
                royal.category == .straightFlush && royal.value.isRoyalFlush && royal.localizedDescription == "Royal Flush")
        let steel = named("Ah 2h 3h 4h 5h Kc Kd")
        t.check("the steel wheel is a five-high straight flush (over the kings)",
                steel.category == .straightFlush && steel.localizedDescription == "Straight Flush, Five high")
        let wheel = named("Ac 2d 3h 4s 5c 9d Jh")
        t.check("the wheel is a straight, five high",
                wheel.category == .straight && wheel.localizedDescription == "Straight, Five high")
        t.check("the wheel's ace reads as its low card", wheel.cards.last?.rank == .ace)
        t.check("a six-high straight beats the wheel",
                named("2d 3h 4s 5c 6d Kh Kc").value > wheel.value)
        let broadway = named("Ac Kd Qh Js Tc 2d 3h")
        t.check("ace-high straight", broadway.localizedDescription == "Straight, Ace high")
        t.check("four of a kind with the best kicker",
                named("Qc Qd Qh Qs 2c 9d Ah").localizedDescription == "Four of a Kind, Queens"
                    && named("Qc Qd Qh Qs 2c 9d Ah").cards.map(\.rank) == [.queen, .queen, .queen, .queen, .ace])
        t.check("full house, kings over sevens",
                named("Kc Kd Kh 7s 7c 2d 3h").localizedDescription == "Full House, Kings over Sevens")
        t.check("two sets of trips make a full house, the lower as the pair",
                named("9c 9d 9h 4s 4c 4d Ah").localizedDescription == "Full House, Nines over Fours")
        t.check("flush, ace high (and not the straight beside it)",
                named("Ah 9h 7h 4h 2h 3c 5d").localizedDescription == "Flush, Ace high")
        t.check("three of a kind, eights",
                named("8c 8d 8h Ks 2c 4d 6h").localizedDescription == "Three of a Kind, Eights")
        t.check("two pair, kings and sevens",
                named("Kc Kd 7h 7s 2c 4d 9h").localizedDescription == "Two Pair, Kings and Sevens")
        t.check("pair of jacks", named("Jc Jd 7h 5s 2c 4d 9h").localizedDescription == "Pair of Jacks")
        t.check("high card, ace", named("Ac Jd 7h 5s 2c 4d 9h").localizedDescription == "High Card, Ace")
        t.check("every category has its own name",
                Set(PokerHandCategory.allCases.map(\.localizedName)).count == PokerHandCategory.allCases.count)

        // Kickers.
        t.check("AK beats AQ on a board of kings' kickers",
                PokerEvaluator.evaluate(cards("Ac Kd 9s 7h 4c 3d 2s")) > PokerEvaluator.evaluate(cards("Ac Qd 9s 7h 4c 3d 2s")))
        t.check("a pair's third kicker decides",
                PokerEvaluator.evaluate(cards("8c 8d Ah Ks 6c")) > PokerEvaluator.evaluate(cards("8h 8s Ad Kc 5c")))
        let threePairs = PokerEvaluator.evaluate(cards("Kc Kd 7h 7s 5c 5d 3h"))
        t.check("with three pairs, the third pair's rank is the kicker",
                threePairs == PokerEvaluator.evaluate(cards("Kc Kd 7h 7s 5c")))
        t.check("the flush that differs at its fifth card loses",
                PokerEvaluator.evaluate(cards("Ah Jh 9h 6h 3h")) > PokerEvaluator.evaluate(cards("Ad Jd 9d 6d 2d")))
        t.check("the board plays: identical values split",
                PokerEvaluator.evaluate(cards("As Ks Qs Js Ts 2c 3d")) == PokerEvaluator.evaluate(cards("As Ks Qs Js Ts 4h 5h")))
        t.check("fewer than five cards still rank (a pocket pair preflop)",
                PokerEvaluator.best(cards("9c 9d")).localizedDescription == "Pair of Nines"
                    && PokerEvaluator.best(cards("Ac 9d")).category == .highCard)

        // Against the reference, random pairs of five-card hands.
        var rng = DeterministicRNG(seed: 99)
        var deck = Card.full
        var disagreements = 0
        let pairs = isDebug ? 20_000 : 200_000
        for _ in 0..<pairs {
            rng.shuffle(&deck)
            let a = Array(deck[0..<5]), b = Array(deck[5..<10])
            let fast = PokerEvaluator.evaluate(a).raw, fastB = PokerEvaluator.evaluate(b).raw
            let fastOrder = fast == fastB ? 0 : (fast < fastB ? -1 : 1)
            if fastOrder != compare(reference(a), reference(b)) { disagreements += 1 }
        }
        t.check("\(pairs) random five-card match-ups rank exactly as the reference does", disagreements == 0)

        // Seven cards: the best subset, and the cards `best` picks.
        var subsetMismatch = 0, pickedWrong = 0
        let sevens = isDebug ? 4_000 : 40_000
        for _ in 0..<sevens {
            rng.shuffle(&deck)
            let seven = Array(deck[0..<7])
            let value = PokerEvaluator.evaluate(seven)
            var best: UInt32 = 0
            for skipA in 0..<7 {
                for skipB in (skipA + 1)..<7 {
                    let five = seven.enumerated().filter { $0.offset != skipA && $0.offset != skipB }.map(\.element)
                    best = max(best, PokerEvaluator.evaluate(five).raw)
                }
            }
            if best != value.raw { subsetMismatch += 1 }
            let result = PokerEvaluator.best(seven)
            if result.cards.count != 5 || PokerEvaluator.evaluate(result.cards) != value
                || !result.cards.allSatisfy(seven.contains) { pickedWrong += 1 }
        }
        t.check("\(sevens) seven-card hands: the value is the best of the 21 five-card hands", subsetMismatch == 0)
        t.check("…and `best` names exactly five of the seven cards that make it", pickedWrong == 0)

        // Every five-card hand.
        let expectedFive = [1_302_540, 1_098_240, 123_552, 54_912, 10_200, 5_108, 3_744, 624, 40]
        var counts = [Int](repeating: 0, count: 9)
        let bits = Card.full.map(\.pokerBit)
        let start = now()
        for a in 0..<48 {
            let ma = bits[a]
            for b in (a + 1)..<49 {
                let mb = ma | bits[b]
                for c in (b + 1)..<50 {
                    let mc = mb | bits[c]
                    for d in (c + 1)..<51 {
                        let md = mc | bits[d]
                        for e in (d + 1)..<52 {
                            counts[Int(PokerEvaluator.rawValue(of: md | bits[e]) >> 20)] += 1
                        }
                    }
                }
            }
        }
        let fiveTime = now() - start
        t.check("all 2,598,960 five-card hands fall into the known category counts", counts == expectedFive)
        t.info(String(format: "exhaustive five-card enumeration: %.2f s (%.1f M hands/s)", fiveTime,
                      2.598_960 / max(fiveTime, 1e-9)))

        // Every seven-card hand, where there is time for 133 million of them.
        if !isDebug {
            let expectedSeven = [23_294_460, 58_627_800, 31_433_400, 6_461_620, 6_180_020, 4_047_644,
                                 3_473_184, 224_848, 41_584]
            var sevenAll = [Int](repeating: 0, count: 9)
            let allStart = now()
            for a in 0..<46 {
                for b in (a + 1)..<47 {
                    let mb = bits[a] | bits[b]
                    for c in (b + 1)..<48 {
                        let mc = mb | bits[c]
                        for d in (c + 1)..<49 {
                            let md = mc | bits[d]
                            for e in (d + 1)..<50 {
                                let me = md | bits[e]
                                for f in (e + 1)..<51 {
                                    let mf = me | bits[f]
                                    for g in (f + 1)..<52 {
                                        sevenAll[Int(PokerEvaluator.rawValue(of: mf | bits[g]) >> 20)] += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let allTime = now() - allStart
            t.check("all 133,784,560 seven-card hands fall into the known category counts", sevenAll == expectedSeven)
            t.info(String(format: "exhaustive seven-card enumeration: %.2f s (%.0f M hands/s)", allTime,
                          133.784_560 / max(allTime, 1e-9)))
        } else {
            t.info("the exhaustive seven-card count runs in release builds (133 M hands)")
        }

        // Seven-card frequencies from a seeded sample.
        let sevenProbabilities = [23_294_460, 58_627_800, 31_433_400, 6_461_620, 6_180_020, 4_047_644,
                                  3_473_184, 224_848, 41_584].map { Double($0) / 133_784_560 }
        let samples = isDebug ? 300_000 : 3_000_000
        var sevenCounts = [Int](repeating: 0, count: 9)
        var masks: [UInt64] = []
        masks.reserveCapacity(samples)
        for _ in 0..<samples {
            var m: UInt64 = 0
            var n = 0
            while n < 7 {
                let bit = bits[rng.next(upperBound: 52)]
                if m & bit == 0 { m |= bit; n += 1 }
            }
            masks.append(m)
        }
        let sevenStart = now()
        for m in masks { sevenCounts[Int(PokerEvaluator.rawValue(of: m) >> 20)] += 1 }
        let sevenTime = now() - sevenStart
        var withinTolerance = true
        for (i, p) in sevenProbabilities.enumerated() {
            let expected = p * Double(samples)
            let sigma = (expected * (1 - p)).squareRoot()
            if abs(Double(sevenCounts[i]) - expected) > 5 * sigma + 2 { withinTolerance = false }
        }
        t.check("\(samples) random seven-card hands match the known category frequencies", withinTolerance)
        t.info(String(format: "seven-card evaluation: %.1f M hands/s (%.0f ns each)",
                      Double(samples) / max(sevenTime, 1e-9) / 1e6, sevenTime / Double(samples) * 1e9))

        let slowCount = isDebug ? 5_000 : 50_000
        let slowStart = now()
        for i in 0..<slowCount {
            rng.shuffle(&deck)
            _ = PokerEvaluator.best(Array(deck[0..<7])).cards.count + i
        }
        let slowTime = now() - slowStart
        t.info(String(format: "full result with the five cards (the UI's call): %.1f µs each",
                      slowTime / Double(slowCount) * 1e6))
    }

    // MARK: - Betting

    static func betting(_ t: TestReporter) {
        t.section("Poker — betting rules")

        // Order and blinds, four-handed.
        var four = makeTable([1000, 1000, 1000, 1000], button: 0)
        four.startHand()
        t.check("four-handed: button 0, small blind 1, big blind 2",
                four.button == 0 && four.smallBlindSeat == 1 && four.bigBlindSeat == 2)
        t.check("preflop action starts left of the big blind", four.toAct == 3)
        t.check("the big blind is the bet to call", four.options()?.callAmount == 10)
        t.check("the minimum raise is to twice the big blind",
                four.options()?.minTotal == 20 && !four.isLegal(.raise(15)) && four.isLegal(.raise(20)))
        act(&four, .raise(30))
        t.check("after a raise to 30 the next minimum is 50 (the raise's increment again)",
                four.options()?.minTotal == 50 && !four.isLegal(.raise(45)) && four.isLegal(.raise(50)))
        t.check("a bet is not the name for raising a bet", !four.isLegal(.bet(60)))
        act(&four, .raise(80))
        t.check("after a raise to 80 (by 50) the minimum is 130", four.options()?.minTotal == 130)
        act(&four, .fold)                       // seat 1
        act(&four, .call)                       // seat 2, the big blind
        act(&four, .call)                       // seat 3
        t.check("the round closes when everyone has matched", four.phase == .streetComplete)
        four.advance()
        t.check("postflop the first to act is the first player left of the button still in",
                four.street == .flop && four.toAct == 2)
        t.check("the minimum bet is the big blind", four.options()?.minTotal == 10
                    && !four.isLegal(.bet(5)) && four.isLegal(.bet(10)) && four.options()?.canBet == true)
        t.check("checking is allowed with no bet, calling is not",
                four.isLegal(.check) && !four.isLegal(.call))
        let before = four
        let illegal = (try? four.apply(.raise(40))) == nil
        t.check("an illegal action throws and changes nothing", illegal && four == before)

        // A short all-in does not reopen the betting.
        var short = makeTable([1000, 40, 1000], button: 0)
        short.startHand()
        t.check("three-handed the button acts first preflop", short.toAct == 0)
        act(&short, .raise(30))
        let shove = act(&short, .allIn)
        let shoveRecord: PokerActionRecord? = shove?.compactMap { if case .acted(let r) = $0 { return r }; return nil }.first
        t.check("an all-in of 40 over a raise to 30 is a short raise",
                shoveRecord?.isAllIn == true && shoveRecord?.isFullRaise == false && short.options()?.currentBet == 40)
        t.check("a player yet to act may still raise it, by the full increment (to 60)",
                short.toAct == 2 && short.options()?.canRaise == true && short.options()?.minTotal == 60)
        act(&short, .call)
        let back = short.options()
        t.check("the original raiser may only call or fold",
                back?.seat == 0 && back?.canRaise == false && back?.canCall == true && back?.callAmount == 10
                    && !short.isLegal(.raise(100)) && !short.isLegal(.allIn) && short.isLegal(.fold))

        // Short all-ins that add up to a full raise do reopen it.
        var sum = makeTable([45, 60, 1000, 1000], button: 0)
        sum.startHand()
        act(&sum, .raise(30))                   // seat 3, by 20
        act(&sum, .allIn)                       // seat 0 to 45: short
        act(&sum, .allIn)                       // seat 1 to 60: short
        act(&sum, .call)                        // seat 2
        t.check("two short all-ins worth a full raise between them reopen the betting",
                sum.toAct == 3 && sum.options()?.canRaise == true && sum.options()?.minTotal == 80)

        // Uncalled bets.
        var uncalled = makeTable([1000, 1000, 300], button: 0)
        uncalled.startHand()
        act(&uncalled, .allIn)                  // seat 0, 1000
        act(&uncalled, .fold)                   // seat 1
        act(&uncalled, .call)                   // seat 2, all-in for 300
        let gathered = uncalled.advance()
        t.check("the unmatched 700 goes back to the big stack",
                gathered.contains(.uncalledBetReturned(seat: 0, amount: 700)))
        t.check("the pot is 300 + 300 + the small blind, for the two all-in players",
                uncalled.pots == [PokerPot(amount: 605, eligible: [0, 2])])
        t.check("with nobody left to bet, the hands turn up before the runout",
                gathered.contains { if case .handsRevealed(let shown) = $0 { return shown.count == 2 }; return false }
                    && uncalled.phase == .streetComplete && uncalled.street == .flop)
        checkDown(&uncalled)
        t.check("the runout pays out and every chip is still there",
                uncalled.phase == .betweenHands && uncalled.chipsOnTable == uncalled.chipsBoughtIn
                    && uncalled.players.reduce(0) { $0 + $1.stack } == 2300)

        var folds = makeTable([1000, 1000, 1000], button: 0)
        folds.startHand()
        act(&folds, .raise(30))
        act(&folds, .fold)
        act(&folds, .fold)
        let won = folds.advance()
        t.check("everyone folds: the raise's unmatched 20 comes back, the blinds are won",
                won.contains(.uncalledBetReturned(seat: 0, amount: 20)) && folds.players[0].stack == 1015
                    && folds.lastSummary?.awards.first?.isUncontested == true)

        // Side pots from three different all-ins.
        var side = makeTable([100, 250, 400, 1000], button: 3)
        side.startHand()
        side.rigForTesting(hole: [0: cards("Ac Ad"), 1: cards("Kc Kd"), 2: cards("Qc Qd"), 3: cards("Jc Jd")],
                           board: cards("2h 7s 9h 3s 8d"))
        t.check("side-pot table: button 3, blinds 0 and 1, seat 2 first", side.toAct == 2)
        act(&side, .allIn)                      // seat 2: 400
        act(&side, .allIn)                      // seat 3: 1000
        act(&side, .allIn)                      // seat 0: 100
        act(&side, .allIn)                      // seat 1: 250
        let collected = side.advance()
        t.check("three all-in sizes make a main pot and two side pots",
                side.pots == [PokerPot(amount: 400, eligible: [0, 1, 2, 3]), PokerPot(amount: 450, eligible: [1, 2, 3]),
                              PokerPot(amount: 300, eligible: [2, 3])]
                    && collected.contains(.uncalledBetReturned(seat: 3, amount: 600)))
        checkDown(&side)
        t.check("each pot goes to the best hand eligible for it",
                side.players.map(\.stack) == [400, 450, 300, 600])
        t.check("the summary lists three awards, main pot first",
                side.lastSummary?.awards.map(\.potIndex) == [0, 1, 2]
                    && side.lastSummary?.awards.map(\.winners) == [[0], [1], [2]])

        // The odd chip.
        var odd = makeTable([1000, 1000, 1000], button: 0)
        odd.startHand()
        odd.rigForTesting(hole: [0: cards("2c 3d"), 1: cards("4c 5d"), 2: cards("6c 7d")], board: cards("As Ks Qs Js Ts"))
        act(&odd, .call)                        // seat 0 (button)
        act(&odd, .fold)                        // seat 1
        act(&odd, .check)                       // seat 2
        checkDown(&odd)
        t.check("a split 25 gives the odd chip to the winner first left of the button",
                odd.players[2].stack == 1003 && odd.players[0].stack == 1002 && odd.players[1].stack == 995)

        // Heads-up.
        var heads = makeTable([1000, 1000], button: 1)
        heads.startHand()
        t.check("heads-up the button posts the small blind", heads.smallBlindSeat == 1 && heads.bigBlindSeat == 0)
        t.check("…and acts first before the flop", heads.toAct == 1)
        act(&heads, .call)
        t.check("the big blind still has the option", heads.toAct == 0 && heads.options()?.canRaise == true)
        act(&heads, .check)
        heads.advance()
        t.check("…and the big blind acts first after it", heads.toAct == 0 && heads.street == .flop)
        act(&heads, .check)
        t.check("the button acts last postflop", heads.toAct == 1)

        // A big blind posted short is still called in full.
        var shortBlind = makeTable([1000, 1000, 5], button: 0)
        shortBlind.startHand()
        t.check("a big blind of 5 is posted all-in, and the call is still 10",
                shortBlind.players[2].status == .allIn && shortBlind.options()?.callAmount == 10)
        act(&shortBlind, .call)
        act(&shortBlind, .call)
        t.check("with the blind all-in, the round ends once the others match", shortBlind.phase == .streetComplete)
        shortBlind.advance()
        t.check("…making a main pot of 15 and a side pot of 10",
                shortBlind.pots == [PokerPot(amount: 15, eligible: [0, 1, 2]), PokerPot(amount: 10, eligible: [0, 1])])

        // A big blind whose only opponent is all-in for less needs no option.
        var noOption = makeTable([8, 1000, 1000], button: 0)
        noOption.startHand()
        act(&noOption, .allIn)                  // seat 0: all-in for 8, less than the blind
        act(&noOption, .fold)                   // seat 1
        t.check("the big blind covering a lone short all-in does not act",
                noOption.phase == .streetComplete && noOption.toAct == nil)
        let noOptionEvents = noOption.advance()
        t.check("…and gets the unmatched 2 back", noOptionEvents.contains(.uncalledBetReturned(seat: 2, amount: 2)))

        // The button past eliminated seats.
        var moving = makeTable([1500, 0, 1500, 1500], mode: .tournament, button: 0)
        let startEvents = moving.startHand()
        t.check("the blinds skip an empty seat",
                moving.button == 0 && moving.smallBlindSeat == 2 && moving.bigBlindSeat == 3)
        t.check("nobody deals to an empty seat",
                moving.players[1].holeCards.isEmpty && startEvents.contains(.dealtHoleCards(order: [2, 3, 0])))
        act(&moving, .fold)
        act(&moving, .fold)
        moving.advance()
        moving.startHand()
        t.check("next hand the button moves to the next live seat",
                moving.button == 2 && moving.smallBlindSeat == 3 && moving.bigBlindSeat == 0)
        checkDown(&moving)
        moving.setStacksForTesting([1500, 0, 1500, 0])
        moving.startHand()
        t.check("down to two, the button (skipping the empty seat) posts the small blind",
                moving.button == 0 && moving.smallBlindSeat == 0 && moving.bigBlindSeat == 2 && moving.toAct == 0)
    }

    // MARK: - Modes

    static func modes(_ t: TestReporter) {
        t.section("Poker — tournament and cash")

        var levels = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 6, includesHuman: false), seed: 3)
        var raised: [PokerEvent] = []
        for hand in 1...9 {
            let events = levels.startHand()
            if hand == 9 { raised = events }
            if hand == 8 { t.check("hand 8 is still 10/20 with no hands left at the level",
                                   levels.blinds == PokerBlindLevel(10, 20) && levels.handsUntilNextLevel == 0) }
            // Everyone folds to the big blind.
            while levels.phase == .betting, let o = levels.options() { act(&levels, o.canCheck ? .check : .fold) }
            levels.advance()
        }
        t.check("the ninth hand raises the blinds to 15/30",
                raised.contains(.blindsRaised(level: 1, blinds: PokerBlindLevel(15, 30))) && levels.blinds == PokerBlindLevel(15, 30))
        t.check("the schedule has twelve levels up to 1,000/2,000",
                PokerTableConfig.tournamentLevels.count == 12 && PokerTableConfig.tournamentLevels.last == PokerBlindLevel(1_000, 2_000))

        // Two out in one hand.
        var bust = makeTable([100, 200, 1500, 1500], mode: .tournament, button: 3)
        bust.startHand()
        bust.rigForTesting(hole: [0: cards("7c 2d"), 1: cards("8c 3d"), 2: cards("Ah As"), 3: cards("9c 4d")],
                           board: cards("Kd Qh Tc 5s 6d"))
        act(&bust, .allIn)                      // seat 2
        act(&bust, .fold)                       // seat 3
        act(&bust, .allIn)                      // seat 0
        act(&bust, .allIn)                      // seat 1
        let bustEvents = checkDown(&bust)
        t.check("two players out in one hand: the bigger starting stack finishes higher",
                bustEvents.contains(.eliminated(seat: 1, place: 3)) && bustEvents.contains(.eliminated(seat: 0, place: 4))
                    && bust.players[0].status == .out && bust.players[1].status == .out)
        bust.startHand()
        t.check("the eliminated are not dealt in again", bust.players[0].holeCards.isEmpty && bust.players[1].holeCards.isEmpty)

        // The winner.
        var final = makeTable([1500, 1500], mode: .tournament, button: 0)
        final.startHand()
        final.rigForTesting(hole: [0: cards("Ah As"), 1: cards("7c 2d")], board: cards("Kd Qh Tc 5s 3d"))
        act(&final, .allIn)
        act(&final, .call)
        let finalEvents = checkDown(&final)
        t.check("the last player standing wins the tournament",
                finalEvents.contains(.tournamentEnded(winner: 0)) && final.phase == .gameOver
                    && final.players[0].place == 1 && final.players[1].place == 2)
        t.check("a finished tournament deals no more hands", final.startHand().isEmpty && final.phase == .gameOver)

        // Cash: rebuys and top-ups.
        var cash = makeTable([1000, 1000], mode: .cash, button: 0)
        cash.startHand()
        cash.rigForTesting(hole: [0: cards("Ah As"), 1: cards("Kc Kd")], board: cards("2d 7h 9c 4s 3d"))
        act(&cash, .allIn)
        act(&cash, .call)
        checkDown(&cash)
        t.check("a busted cash player sits out until the next hand", cash.players[1].stack == 0 && cash.players[1].status == .out)
        t.check("a cash table is never over", cash.phase == .betweenHands)
        t.check("top-ups are for stacks under 1,000", cash.canTopUp(seat: 1) && !cash.canTopUp(seat: 0))
        let rebuy = cash.startHand()
        t.check("…and buys back in for 1,000 when it comes",
                rebuy.contains(.rebought(seat: 1, amount: 1_000)) && cash.chipsBoughtIn == 3_000
                    && cash.chipsOnTable == 3_000)
        t.check("no top-ups in the middle of a hand", cash.topUp(seat: 1).isEmpty)
        checkDown(&cash)
        let before = cash.players[1].stack
        let topped = cash.topUp(seat: 1)
        t.check("between hands a short stack tops up to exactly 1,000",
                before < 1_000 ? topped == [.rebought(seat: 1, amount: 1_000 - before)] && cash.players[1].stack == 1_000
                    : topped.isEmpty)

        // Seats and characters.
        let full = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 11)
        let again = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 11)
        let bots = full.players.filter { !$0.isHuman }
        t.check("the player sits at seat 0 with five computer players", full.humanSeat == 0 && bots.count == 5)
        t.check("a full table has every personality", Set(bots.map(\.personality)).count == PokerPersonality.allCases.count)
        t.check("personalities and names come from the seed",
                full.players.map(\.personality) == again.players.map(\.personality) && full.players.map(\.name) == again.players.map(\.name))
        t.check("bots have different names", Set(bots.map(\.name)).count == bots.count)
    }

    // MARK: - Persistence

    static func persistence(_ t: TestReporter) {
        t.section("Poker — saving")

        var table = PokerTable(config: PokerTableConfig(mode: .tournament, opponents: 3), seed: 5)
        for _ in 0..<3 {
            table.startHand()
            PokerBot.playOut(&table, samples: 30)
        }
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let saved = table
        let data = (try? encoder.encode(table)) ?? Data()
        let decoded = try? decoder.decode(PokerTable.self, from: data)
        t.check("a table between hands survives the round trip exactly", decoded == table && table.isConsistent)

        table.startHand()
        let midData = (try? encoder.encode(table)) ?? Data()
        let midDecoded = try? decoder.decode(PokerTable.self, from: midData)
        t.check("…and so does a hand in progress", midDecoded == table)
        var restored = midDecoded
        restored?.abandonHandInProgress()
        t.check("a hand caught in progress can be given back to the players",
                restored?.phase == .betweenHands && restored?.isConsistent == true
                    && restored?.players.allSatisfy({ $0.bet == 0 && $0.committed == 0 }) == true)

        // Missing and damaged keys.
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object.removeValue(forKey: "levelIndex")
            object.removeValue(forKey: "lastSummary")
            object["handNumber"] = "not a number"
            object["config"] = ["mode": "cash", "difficulty": "no such difficulty"]
            let damaged = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let tolerant = try? decoder.decode(PokerTable.self, from: damaged)
            t.check("a damaged save loses the damaged fields, not the table",
                    tolerant?.players == saved.players && tolerant?.handNumber == 0
                        && tolerant?.config.mode == .cash && tolerant?.config.difficulty == .standard)
            object.removeValue(forKey: "players")
            let hopeless = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            t.check("a save without players is refused", (try? decoder.decode(PokerTable.self, from: hopeless)) == nil)
        } else {
            t.check("the table encodes to a JSON object", false)
        }

        let partialStats = try? decoder.decode(PokerStats.self, from: Data(#"{"handsWon": 3, "bestFinish": "x"}"#.utf8))
        t.check("stats decode key by key", partialStats?.handsWon == 3 && partialStats?.handsPlayed == 0
                    && partialStats?.bestFinish == nil)

        var stats = PokerStats()
        stats.recordTournament(place: 4)
        stats.recordTournament(place: 2)
        stats.recordTournament(place: 1)
        t.check("stats keep the best finish and count wins",
                stats.bestFinish == 1 && stats.tournamentsWon == 1 && stats.tournamentsPlayed == 3)

        // Through Storage (a throwaway folder under the harness).
        var between = table
        between.abandonHandInProgress()
        PokerStorage.save(between)
        t.check("the table saves between hands and loads back", PokerStorage.loadTable() == between)
        PokerStorage.save(table)   // mid-hand: ignored
        t.check("a hand in progress is not saved over it", PokerStorage.loadTable() == between)
        PokerStorage.save(stats)
        t.check("the stats save and load", PokerStorage.loadStats() == stats)
        t.check("the files are named for poker",
                PokerStorage.tableFile == "poker-table.json" && PokerStorage.statsFile == "poker-stats.json")
        PokerStorage.removeTable()
        t.check("a removed table does not come back", PokerStorage.loadTable() == nil)
    }

    // MARK: - Fuzz

    /// Something legal, at random: mostly checks and calls so hands reach
    /// the showdown, with enough raising and shoving to make side pots.
    static func randomAction(_ o: PokerActionOptions, _ rng: inout DeterministicRNG) -> PokerAction {
        let roll = rng.next(upperBound: 100)
        if roll < 9 && !o.canCheck { return .fold }
        if roll < 10 { return .fold }
        if roll < 16 && (o.canBetOrRaise || o.callIsAllIn) { return .allIn }
        if roll < 38 && o.canBetOrRaise {
            let span = max(0, min(o.maxTotal - o.minTotal, max(o.pot, 1) * 2))
            let total = o.minTotal + (span > 0 ? rng.next(upperBound: span + 1) : 0)
            return o.canBet ? .bet(total) : .raise(total)
        }
        return o.canCheck ? .check : .call
    }

    /// Something that must be refused.
    static func illegalAction(_ o: PokerActionOptions, _ rng: inout DeterministicRNG) -> PokerAction? {
        var candidates: [PokerAction] = []
        if !o.canCheck { candidates.append(.check) }
        if !o.canCall { candidates.append(.call) }
        if o.canBetOrRaise && o.minTotal < o.maxTotal {
            candidates.append(o.canBet ? .bet(o.minTotal - 1) : .raise(o.minTotal - 1))
            candidates.append(o.canBet ? .raise(o.minTotal) : .bet(o.minTotal))
        }
        candidates.append(o.canBet ? .bet(o.maxTotal + 1) : .raise(o.maxTotal + 1))
        if !o.canBetOrRaise && !o.callIsAllIn { candidates.append(.allIn) }
        return candidates.isEmpty ? nil : candidates[rng.next(upperBound: candidates.count)]
    }

    struct FuzzTally {
        var hands = 0
        var actions = 0
        var leaks = 0
        var negative = 0
        var stuck = 0
        var illegalTried = 0
        var illegalAccepted = 0
        var illegalChanged = 0
        var legalRefused = 0
        var badEndings = 0
        var sidePots = 0
        var splits = 0
        var tournaments = 0
        var tournamentsWithOneWinner = 0
        var unfinishedTournaments = 0
    }

    /// Plays one hand to the end with `chooser` picking every action.
    static func playHand(_ table: inout PokerTable, _ tally: inout FuzzTally,
                         rng: inout DeterministicRNG, tryIllegal: Bool,
                         chooser: (PokerTable, PokerActionOptions, inout DeterministicRNG) -> PokerAction) {
        let events = table.startHand()
        guard table.phase != .gameOver && table.phase != .betweenHands || !events.isEmpty else { return }
        tally.hands += 1
        var steps = 0
        var sawSidePot = false
        while table.phase == .betting || table.phase == .streetComplete {
            steps += 1
            if steps > 400 { tally.stuck += 1; break }
            if table.phase == .streetComplete {
                for event in table.advance() {
                    if case .betsCollected(let pots) = event, pots.count > 1 { sawSidePot = true }
                    if case .potAwarded(let award) = event, award.shares.count > 1 { tally.splits += 1 }
                }
            } else if let o = table.options() {
                if tryIllegal && rng.next(upperBound: 8) == 0, let bad = illegalAction(o, &rng) {
                    let before = table
                    tally.illegalTried += 1
                    if (try? table.apply(bad)) != nil { tally.illegalAccepted += 1 }
                    if table != before { tally.illegalChanged += 1; table = before }
                }
                let action = chooser(table, o, &rng)
                tally.actions += 1
                if (try? table.apply(action)) == nil {
                    tally.legalRefused += 1
                    _ = try? table.apply(o.canCheck ? .check : .fold)
                }
            } else {
                tally.stuck += 1
                break
            }
            if table.chipsOnTable != table.chipsBoughtIn { tally.leaks += 1 }
            if table.players.contains(where: { $0.stack < 0 || $0.bet < 0 || $0.committed < 0 }) { tally.negative += 1 }
        }
        if sawSidePot { tally.sidePots += 1 }
        if let summary = table.lastSummary, table.isAtHandBoundary {
            if summary.netChange.reduce(0, +) != 0 || !table.pots.isEmpty || table.potTotal != 0 { tally.badEndings += 1 }
        } else {
            tally.badEndings += 1
        }
    }

    /// Checks a tournament that has ended: one player has every chip and the
    /// places are 1…n, each once.
    static func tournamentIsSettled(_ table: PokerTable) -> Bool {
        let n = table.players.count
        let winners = table.players.filter { $0.stack > 0 }
        return table.phase == .gameOver && winners.count == 1 && winners[0].place == 1
            && winners[0].stack == n * PokerTableConfig.tournamentStack
            && Set(table.players.compactMap(\.place)) == Set(1...n)
    }

    static func fuzz(_ t: TestReporter) {
        t.section("Poker — fuzz")

        // Random legal actions.
        var rng = DeterministicRNG(seed: 20_240_928)
        var tally = FuzzTally()
        let target = 20_000
        let start = now()
        while tally.hands < target {
            let count = 2 + rng.next(upperBound: 5)
            let mode: PokerMode = rng.next(upperBound: 3) == 0 ? .tournament : .cash
            var table = PokerTable(config: PokerTableConfig(mode: mode, opponents: count, includesHuman: false),
                                   seed: rng.next())
            if mode == .cash {
                // Uneven stacks, some tiny: all-ins for every amount, side pots galore.
                table.setStacksForTesting((0..<count).map { _ in
                    rng.next(upperBound: 4) == 0 ? 1 + rng.next(upperBound: 40) : 50 + rng.next(upperBound: 1_500)
                })
                for _ in 0..<40 where tally.hands < target {
                    playHand(&table, &tally, rng: &rng, tryIllegal: true) { _, o, r in randomAction(o, &r) }
                }
            } else {
                tally.tournaments += 1
                var guardHands = 0
                while table.phase != .gameOver && guardHands < 3_000 {
                    guardHands += 1
                    playHand(&table, &tally, rng: &rng, tryIllegal: true) { _, o, r in randomAction(o, &r) }
                }
                if tournamentIsSettled(table) { tally.tournamentsWithOneWinner += 1 } else { tally.unfinishedTournaments += 1 }
            }
        }
        let elapsed = now() - start
        t.check("\(tally.hands) random hands: every chip accounted for after every action", tally.leaks == 0 && tally.negative == 0)
        t.check("every hand ended, pots paid, net change zero", tally.stuck == 0 && tally.badEndings == 0)
        t.check("illegal actions refused (\(tally.illegalTried) tried), legal ones accepted",
                tally.illegalAccepted == 0 && tally.illegalChanged == 0 && tally.legalRefused == 0)
        t.check("\(tally.tournaments) random tournaments each ended with one winner and places 1…n",
                tally.unfinishedTournaments == 0 && tally.tournamentsWithOneWinner == tally.tournaments)
        t.check("the fuzz reached side pots and split pots", tally.sidePots > 100 && tally.splits > 10)
        t.info(String(format: "%d hands, %d actions in %.2f s (%.0f µs per hand); %d with side pots, %d split pots",
                      tally.hands, tally.actions, elapsed, elapsed / Double(tally.hands) * 1e6, tally.sidePots, tally.splits))

        // Bots against bots.
        var botTally = FuzzTally()
        let botTarget = 2_000
        let samples = isDebug ? 60 : nil
        let botStart = now()
        var tables = 0
        var corrected = 0, botIllegal = 0
        while botTally.hands < botTarget {
            tables += 1
            let count = 2 + rng.next(upperBound: 5)
            let mode: PokerMode = tables % 2 == 0 ? .tournament : .cash
            let difficulty = PokerDifficulty.allCases[tables % 3]
            var table = PokerTable(config: PokerTableConfig(mode: mode, opponents: count, difficulty: difficulty,
                                                            includesHuman: false), seed: rng.next())
            var guardHands = 0
            if mode == .tournament { botTally.tournaments += 1 }
            while table.phase != .gameOver && guardHands < (mode == .tournament ? 2_000 : 60) {
                guardHands += 1
                playHand(&table, &botTally, rng: &rng, tryIllegal: false) { table, o, _ in
                    let decision = PokerBot.decide(table: table, seat: o.seat, samples: samples)
                    if decision.wasCorrected { corrected += 1 }
                    if !table.isLegal(decision.action) { botIllegal += 1 }
                    return decision.action
                }
            }
            if mode == .tournament {
                if tournamentIsSettled(table) { botTally.tournamentsWithOneWinner += 1 } else { botTally.unfinishedTournaments += 1 }
            }
        }
        let botElapsed = now() - botStart
        t.check("\(botTally.hands) bot-vs-bot hands: chips conserved, every hand ended",
                botTally.leaks == 0 && botTally.negative == 0 && botTally.stuck == 0 && botTally.badEndings == 0)
        t.check("bots never chose an illegal action (\(botTally.actions) decisions)",
                botIllegal == 0 && corrected == 0 && botTally.legalRefused == 0)
        t.check("\(botTally.tournaments) bot tournaments each ended with one winner",
                botTally.unfinishedTournaments == 0 && botTally.tournamentsWithOneWinner == botTally.tournaments)
        t.info(String(format: "bot hands: %.2f s (%.1f ms per hand, Monte-Carlo %@)", botElapsed,
                      botElapsed / Double(botTally.hands) * 1e3,
                      samples.map { "\($0) samples (debug)" } ?? "at full difficulty samples"))
    }

    // MARK: - Bots

    static func bots(_ t: TestReporter) {
        t.section("Poker — bots")

        // Equity against random hands, known values.
        var rng = DeterministicRNG(seed: 77)
        let n = isDebug ? 6_000 : 30_000
        let aces = PokerEquity.estimate(hole: cards("Ac Ad"), board: [], opponents: [.anyHand], samples: n, rng: &rng)
        let trash = PokerEquity.estimate(hole: cards("7c 2d"), board: [], opponents: [.anyHand], samples: n, rng: &rng)
        let acesFour = PokerEquity.estimate(hole: cards("Ac Ad"), board: [], opponents: Array(repeating: .anyHand, count: 4),
                                            samples: n, rng: &rng)
        t.check(String(format: "aces against one random hand: %.3f (85.2%%)", aces), abs(aces - 0.852) < 0.025)
        t.check(String(format: "seven-deuce off-suit against one: %.3f (34.6%%)", trash), abs(trash - 0.346) < 0.03)
        t.check(String(format: "aces against four: %.3f (55.9%%)", acesFour), abs(acesFour - 0.559) < 0.035)
        let nuts = PokerEquity.estimate(hole: cards("As Ks"), board: cards("Qs Js Ts 2d 3c"), opponents: [.anyHand, .anyHand],
                                        samples: 500, rng: &rng)
        t.check("a royal flush on the river has all the equity", nuts == 1)
        let raiser = PokerRangeFilter(minChen: 7.5, weakKeep: 0.2, airKeep: 1)
        let vsRaiser = PokerEquity.estimate(hole: cards("Kc 9d"), board: [], opponents: [raiser], samples: n, rng: &rng)
        let vsAny = PokerEquity.estimate(hole: cards("Kc 9d"), board: [], opponents: [.anyHand], samples: n, rng: &rng)
        t.check(String(format: "K9 does worse against a raiser's range (%.2f) than against any hand (%.2f)", vsRaiser, vsAny),
                vsRaiser < vsAny - 0.04)
        t.check("the Chen scores: aces 20, kings 16, AKs 12, 72o −1",
                PokerEquity.chen(cards("Ac Ad")) == 20 && PokerEquity.chen(cards("Kc Kd")) == 16
                    && PokerEquity.chen(cards("Ah Kh")) == 12 && PokerEquity.chen(cards("7c 2d")) == -1)

        // Board texture.
        let draw = PokerEquity.texture(hole: cards("Ah 5h"), board: cards("Kh 9h 2c"))
        let openEnded = PokerEquity.texture(hole: cards("9c 8d"), board: cards("7h 6s 2c"))
        let dry = PokerEquity.texture(hole: cards("Ac Kd"), board: cards("Kh 7c 2s"))
        t.check("textures: a flush draw, an open-ender, a dry board",
                draw.flushDraw && openEnded.straightOuts == 2 && openEnded.hasDraw && dry.dry && !dry.hasDraw)

        // Preflop sanity for every character at every level.
        var foldedAces = 0, playedTrash = 0, decisions = 0
        for difficulty in PokerDifficulty.allCases {
            for seed in UInt64(1)...6 {
                var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 6, difficulty: difficulty,
                                                                includesHuman: false), seed: seed * 31)
                table.startHand()
                guard let seat = table.toAct else { continue }
                var aces = table
                aces.rigForTesting(hole: [seat: cards("Ah As")], board: [])
                var junk = table
                junk.rigForTesting(hole: [seat: cards("7c 2d")], board: [])
                decisions += 1
                if PokerBot.decide(table: aces, seat: seat).action == .fold { foldedAces += 1 }
                if PokerBot.decide(table: junk, seat: seat).action != .fold { playedTrash += 1 }
            }
        }
        t.check("no bot folds aces preflop (\(decisions) tables)", foldedAces == 0)
        t.check("no bot plays seven-deuce off-suit under the gun", playedTrash == 0)

        // The river with the nuts, facing a pot-sized bet.
        var calledNuts = 0, nutsTables = 0
        for difficulty in PokerDifficulty.allCases {
            for seed in UInt64(1)...4 {
                var table = makeTable([1000, 1000], button: 0, seed: seed, difficulty: difficulty)
                table.startHand()
                table.rigForTesting(hole: [0: cards("9c 4d"), 1: cards("As Ks")], board: cards("Qs Js Ts 2d 3c"))
                act(&table, .call)
                act(&table, .check)
                for _ in 0..<3 {
                    table.advance()
                    while table.phase == .betting && table.street < .river, table.options() != nil { act(&table, .check) }
                }
                guard table.street == .river, table.toAct == 1 else { continue }
                act(&table, .check)                 // seat 1 checks
                if let o = table.options() { act(&table, .bet(o.potFractionTotal(1))) }   // seat 0 bets the pot
                guard table.toAct == 1 else { continue }
                nutsTables += 1
                if PokerBot.decide(table: table, seat: 1).action != .fold { calledNuts += 1 }
            }
        }
        t.check("a bot with the nuts never folds to a river bet (\(nutsTables) tables)", nutsTables > 0 && calledNuts == nutsTables)

        // Deterministic decisions.
        var sample = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 404)
        sample.startHand()
        if let seat = sample.toAct {
            let a = PokerBot.decide(table: sample, seat: seat, samples: 200)
            let b = PokerBot.decide(table: sample, seat: seat, samples: 200)
            t.check("the same situation gets the same decision", a == b && (0...1).contains(a.deliberation))
        }

        // Timing a real postflop decision at every difficulty, six-handed.
        var flop = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 8)
        flop.startHand()
        while flop.phase == .betting, flop.street == .preflop, let o = flop.options() { act(&flop, o.canCheck ? .check : .call) }
        flop.advance()
        if flop.phase == .betting, let seat = flop.toAct {
            var timings: [String] = []
            for difficulty in PokerDifficulty.allCases {
                var copy = flop
                copy.setDifficulty(difficulty)
                let skill = PokerBotSkill.of(difficulty)
                let begin = now()
                let decision = PokerBot.decide(table: copy, seat: seat)
                let ms = (now() - begin) * 1e3
                timings.append(String(format: "%@ %.1f ms (%d samples × %d opponents, equity %.2f)",
                                      difficulty.rawValue, ms, skill.samples, copy.players.filter(\.isInHand).count - 1,
                                      decision.equity ?? -1))
            }
            t.info("postflop decision: " + timings.joined(separator: "; "))
        }

        scenarios(t)
    }

    // MARK: - Scenarios and headlines

    static func scenarios(_ t: TestReporter) {
        t.section("Poker — screenshot scenarios and banners")
        let start = now()
        let built = PokerScenarios.names.map { ($0, PokerScenarios.table($0)) }
        t.info(String(format: "scenarios built in %.2f s", now() - start))
        for (name, table) in built {
            t.check("scenario \(name) builds a consistent table", table?.chipsOnTable == table?.chipsBoughtIn && table != nil)
        }
        let preflop = built[0].1, flop = built[1].1, showdown = built[2].1, side = built[3].1, heads = built[4].1
        t.check("preflop: six players, the player to act before the flop",
                preflop?.players.count == 6 && preflop?.isHumanToAct == true && preflop?.street == .preflop)
        t.check("flop: the player to act with top pair",
                flop?.isHumanToAct == true && flop?.street == .flop && flop?.currentHand(for: 0)?.category == .pair)
        t.check("showdown: the player's flush took the pot",
                showdown?.lastSummary?.biggestWinner == 0 && showdown?.lastSummary?.awards.first?.hand?.category == .flush
                    && showdown?.phase == .betweenHands)
        t.check("sidepots: two all-ins, a main pot and a side pot",
                side?.pots.count == 2 && side?.players.filter({ $0.status == .allIn }).count == 2 && side?.isHumanToAct == true)
        t.check("headsup: two players, the player to act", heads?.players.count == 2 && heads?.isHumanToAct == true)
        t.check("the same scenario twice is the same table", PokerScenarios.table("flop") == flop)

        if let summary = showdown?.lastSummary, let names = showdown?.players.map(\.name) {
            let line = summary.headline(names: names, humanSeat: 0)
            t.check("the banner: \"\(line.title) — \(line.subtitle)\"",
                    line.title.hasPrefix("You win ") && line.subtitle == "Flush, Ace high")
        }
        let split = PokerHandSummary(handNumber: 1, board: [], awards: [
            PokerPotAward(potIndex: 0, amount: 25, shares: [PokerPotShare(seat: 2, amount: 13), PokerPotShare(seat: 1, amount: 12)],
                          hand: PokerEvaluator.best(cards("As Ks Qs Js Ts")))], shown: [], netChange: [0, 2, 3])
        t.check("a split names both players", split.headline(names: ["You", "Maria", "Hiro"], humanSeat: 0).title
                    == "Hiro and Maria split 25")
        let folded = PokerHandSummary(handNumber: 1, board: [], awards: [
            PokerPotAward(potIndex: 0, amount: 30, shares: [PokerPotShare(seat: 1, amount: 30)], hand: nil)], shown: [],
                                      netChange: [-10, 10])
        let foldLine = folded.headline(names: ["You", "Maria"], humanSeat: 0)
        t.check("an uncontested pot has no hand line", foldLine.title == "Maria wins 30" && foldLine.subtitle.isEmpty)
    }
}


/// The background worker, which needs the main run loop to hand answers back.
@MainActor
enum PokerWorkerTests {

    static func run(_ t: TestReporter) {
        t.section("Poker — thinking off the main thread")
        var table = PokerTable(config: PokerTableConfig(mode: .cash, opponents: 5), seed: 91)
        table.startHand()
        PokerBot.playOut(&table, stopAtHuman: true, samples: 50)
        guard let seat = table.nextSeat(after: table.toAct ?? 0, where: { !$0.isHuman && $0.canAct }) else {
            t.check("a bot to ask", false)
            return
        }
        let worker = PokerBotWorker()
        var stale = false
        var answer: PokerBotDecision?
        var answeredOnMain = false
        worker.decide(table, seat: seat, samples: 100) { _ in stale = true }
        worker.cancel()
        t.check("cancelling stops the thinking", !worker.isThinking)
        worker.decide(table, seat: seat, samples: 100) { decision in
            answer = decision
            answeredOnMain = Thread.isMainThread
        }
        t.check("…and asking again starts it", worker.isThinking)
        let deadline = Date().addingTimeInterval(5)
        while answer == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        t.check("the answer comes back on the main thread", answer != nil && answeredOnMain && !worker.isThinking)
        t.check("a cancelled question never answers", !stale)
        t.check("the background answer is the one the bot gives directly",
                answer == PokerBot.decide(table: table, seat: seat, samples: 100))

        // Fast-forward: the rest of the hand, in the background.
        var finished: PokerTable?
        var events: [PokerEvent] = []
        var fold = table
        _ = try? fold.apply(.fold)
        worker.playOut(fold, stopAtHuman: true) { result, produced in
            finished = result
            events = produced
        }
        let playDeadline = Date().addingTimeInterval(10)
        while finished == nil && Date() < playDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        t.check("after the player folds, the hand plays out in the background to the payout",
                finished?.phase == .betweenHands && events.contains { if case .handEnded = $0 { return true }; return false }
                    && finished?.chipsOnTable == finished?.chipsBoughtIn)
    }
}
