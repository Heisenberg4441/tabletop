//
//  BlackjackTests.swift
//  Blackjack's checks, for `Tabletop --selftest blackjack`.
//
//  The engine first — counting, the dealer's rule, every payout, the split
//  and surrender rules, the peek, the cut card, the strategy table — then a
//  fuzz of fifty thousand rounds of random legal play that checks after
//  every single step that no chip was made or lost and no card doubled or
//  vanished. Then the table itself (`BlackjackPlayTest`): the real
//  controller playing rounds by basic strategy through its own buttons.
//

import Foundation

@MainActor
enum BlackjackTests {

    static func run(_ t: TestReporter) {
        let clock = Date()
        t.section("Blackjack")
        t.check("the game introduces itself as blackjack", BlackjackGame.info.id == .blackjack)
        totals(t)
        dealerRule(t)
        payouts(t)
        splitting(t)
        peeking(t)
        labels(t)
        shoe(t)
        strategy(t)
        saving(t)
        t.info(String(format: "rules %.2f s", Date().timeIntervalSince(clock)))
        fuzz(t)
        t.info(String(format: "engine %.2f s", Date().timeIntervalSince(clock)))
        BlackjackPlayTest.run(t)
        t.info(String(format: "all %.2f s", Date().timeIntervalSince(clock)))
    }

    // MARK: Helpers

    /// "As", "Th", "7c": rank (A 2–9 T J Q K) and suit (c d h s).
    static func card(_ code: String) -> Card {
        let ranks: [Character: Rank] = ["A": .ace, "2": .two, "3": .three, "4": .four, "5": .five, "6": .six,
                                        "7": .seven, "8": .eight, "9": .nine, "T": .ten, "J": .jack, "Q": .queen,
                                        "K": .king]
        let suits: [Character: Suit] = ["c": .clubs, "d": .diamonds, "h": .hearts, "s": .spades]
        guard let r = code.first.flatMap({ ranks[$0] }), let s = code.last.flatMap({ suits[$0] }) else {
            return Card(.clubs, .two)
        }
        return Card(s, r)
    }

    static func cards(_ codes: String) -> [Card] {
        codes.split(separator: " ").map { card(String($0)) }
    }

    /// A table whose shoe deals `codes` next, in order: the player's first
    /// card, the dealer's up-card, the player's second, the hole card, then
    /// whatever the round draws.
    static func table(_ codes: String, rules: BlackjackRules = BlackjackRules(), bet: Int = 100,
                      bankroll: BlackjackAmount = 1_000) -> BlackjackEngine {
        var engine = BlackjackEngine(rules: rules, seed: 42, bankroll: bankroll)
        engine.stackShoe(cards(codes))
        engine.addToBet(bet)
        engine.deal()
        while engine.phase == .dealing { engine.advance() }
        return engine
    }

    /// Lets the dealer finish: every automatic step until the player is
    /// asked something or the round is over.
    static func runDealer(_ engine: inout BlackjackEngine) {
        var guardSteps = 0
        while engine.needsAdvance && guardSteps < 100 {
            engine.advance()
            guardSteps += 1
        }
    }

    static func hand(_ codes: String) -> BlackjackHand {
        var hand = BlackjackHand(bet: 10)
        hand.cards = cards(codes).map { BlackjackCard(id: Int($0.code)) }
        return hand
    }

    // MARK: Counting

    private static func totals(_ t: TestReporter) {
        func total(_ codes: String) -> BlackjackTotal { hand(codes).total }
        t.check("A–6 is soft 17", total("Ac 6d") == BlackjackTotal(points: [1, 6]) && total("Ac 6d").total == 17
                && total("Ac 6d").isSoft)
        t.check("A–6–T is hard 17", total("Ac 6d Th").total == 17 && !total("Ac 6d Th").isSoft)
        t.check("two aces are soft 12, not 22", total("Ac Ad").total == 12 && total("Ac Ad").isSoft)
        t.check("four aces and a seven are soft 21", total("Ac Ad Ah As 7c").total == 21 && total("Ac Ad Ah As 7c").isSoft)
        t.check("A–A–9–T is hard 21", total("Ac Ad 9h Tc").total == 21 && !total("Ac Ad 9h Tc").isSoft)
        t.check("K–Q–2 is 22, bust", total("Kc Qd 2h").isBust)
        t.check("court cards count ten", total("Jc Qd").total == 20 && total("Kc 5d").total == 15)
        t.check("ace and king are blackjack", hand("As Kh").isBlackjack)
        t.check("three cards to 21 are not", !hand("7s 7h 7d").isBlackjack)
    }

    private static func dealerRule(_ t: TestReporter) {
        var h17 = BlackjackRules()
        h17.dealerHitsSoft17 = true
        let s17 = BlackjackEngine(rules: BlackjackRules(), seed: 1)
        let hits = BlackjackEngine(rules: h17, seed: 1)
        let soft17 = hand("Ac 6d").cards
        t.check("S17: the dealer stands on soft 17", !s17.dealerShouldDraw(soft17))
        t.check("H17: the dealer hits soft 17", hits.dealerShouldDraw(soft17))
        t.check("both stand on hard 17", !s17.dealerShouldDraw(hand("Tc 7d").cards) && !hits.dealerShouldDraw(hand("Tc 7d").cards))
        t.check("both draw to 16", s17.dealerShouldDraw(hand("Tc 6d").cards) && hits.dealerShouldDraw(hand("Tc 6d").cards))
        t.check("both stand on soft 18", !hits.dealerShouldDraw(hand("Ac 7d").cards))

        // Played out: the dealer shows 6 with an ace underneath.
        var a = table("Tc 6d 8h Ac 5s", rules: BlackjackRules())
        a.perform(.stand)
        runDealer(&a)
        t.check("S17 in play: the dealer keeps A–6", a.round?.dealer.count == 2)
        var b = table("Tc 6d 8h Ac 5s", rules: h17)
        b.perform(.stand)
        runDealer(&b)
        t.check("H17 in play: the dealer draws to A–6", (b.round?.dealer.count ?? 0) >= 3
                && b.round?.dealer[safe: 2]?.card == card("5s"))
        t.check("the felt says which", BlackjackRules().dealerRuleText.contains("STAND")
                && h17.dealerRuleText.contains("HIT"))
    }

    // MARK: Payouts

    private static func payouts(_ t: TestReporter) {
        // Blackjack pays 3:2.
        var natural = table("As 9d Kh 8c")
        runDealer(&natural)
        t.check("blackjack pays 3 to 2 (100 → 250 back)", natural.round?.hands[0].result == .blackjack
                && natural.round?.hands[0].returned == 250 && natural.bankroll == 1_150)
        t.check("a natural is settled without a decision", natural.phase == .settled)
        t.check("and the hole card is shown", natural.round?.isHoleRevealed == true)
        // Exactly three to two, to the half chip: nothing rounds the house's way.
        var odd = table("As 9d Kh 8c", bet: 15)
        runDealer(&odd)
        t.check("a natural on 15 wins 22.5", odd.round?.hands[0].returned == 37.5 && odd.bankroll == 1_022.5)
        var quarter = table("As 9d Kh 8c", bet: 25)
        runDealer(&quarter)
        t.check("a natural on 25 wins 37.5 and says 'Blackjack +37.5'", quarter.round?.hands[0].returned == 62.5
                && BlackjackScene(engine: quarter).hands.first?.label == "Blackjack +" + BlackjackAmount(37.5).formatted
                && quarter.isBalanced)
        var giveQuarter = table("Tc Td 6h 7c", bet: 25)
        runDealer(&giveQuarter)
        giveQuarter.perform(.surrender)
        runDealer(&giveQuarter)
        t.check("surrendering 25 hands back 12.5, exactly half", giveQuarter.round?.hands[0].returned == 12.5
                && giveQuarter.bankroll == 987.5 && giveQuarter.isBalanced)
        var insureQuarter = table("Tc Ad 9h Kc", bet: 25)
        t.check("insurance on 25 costs 12.5", insureQuarter.insuranceCost == 12.5)
        insureQuarter.decideInsurance(take: true)
        runDealer(&insureQuarter)
        t.check("and pays 37.5 back against a blackjack (net 0)", insureQuarter.round?.insuranceReturned == 37.5
                && insureQuarter.bankroll == 1_000 && insureQuarter.isBalanced)
        t.check("half chips read '37.5', '+12.5', '\u{2212}12.5' and whole ones as before",
                BlackjackAmount(37.5).formatted.hasPrefix("37") && BlackjackAmount(37.5).formatted.hasSuffix("5")
                    && BlackjackAmount(37.5).formatted.count == 4 && BlackjackAmount(12.5).formattedChange.hasPrefix("+")
                    && (-BlackjackAmount(12.5)).formattedChange.hasPrefix("\u{2212}")
                    && BlackjackAmount(1_250).formatted == Chips.format(1_250))

        // Win, lose, push.
        var win = table("Tc 7d 9h Tc")
        win.perform(.stand)
        runDealer(&win)
        t.check("19 beats 17 and pays even money", win.round?.hands[0].result == .win && win.bankroll == 1_100)
        var tie = table("Tc 7d 7h Tc")
        tie.perform(.stand)
        runDealer(&tie)
        t.check("17 against 17 is a push", tie.round?.hands[0].result == .push && tie.bankroll == 1_000)
        var short = table("Tc 7d 6h Tc")
        short.perform(.stand)
        runDealer(&short)
        t.check("16 against 17 loses", short.round?.hands[0].result == .lose && short.bankroll == 900)
        var bust = table("Tc 5d 6h Tc Kc")
        bust.perform(.hit)
        runDealer(&bust)
        t.check("a bust loses even when the dealer would bust", bust.round?.hands[0].result == .bust
                && bust.round?.dealer.count == 2 && bust.bankroll == 900)
        t.check("and the dealer draws nothing, but shows the hole card", bust.round?.isHoleRevealed == true)
        var dealerBusts = table("Tc 6d 8h Tc 9s")
        dealerBusts.perform(.stand)
        runDealer(&dealerBusts)
        t.check("the dealer busting pays every standing hand", dealerBusts.round?.hands[0].result == .win
                && dealerBusts.round?.dealerTotal.isBust == true)

        // Double.
        var double = table("6c 6d 5h Tc Ts 9h")
        t.check("double is offered on two cards", double.legalActions().contains(.double))
        double.perform(.double)
        t.check("a double gets exactly one card", double.round?.hands[0].cards.count == 3
                && double.round?.hands[0].isDone == true)
        runDealer(&double)
        t.check("a won double pays on twice the bet (400 back)", double.round?.hands[0].returned == 400
                && double.bankroll == 1_200)

        // Surrender.
        var give = table("Tc Td 6h 7c")
        runDealer(&give)
        t.check("surrender is offered as the first decision", give.legalActions().contains(.surrender))
        give.perform(.surrender)
        runDealer(&give)
        t.check("surrender hands back half (50 of 100)", give.round?.hands[0].result == .surrender
                && give.bankroll == 950)
        var late = table("Tc 5d 3h 7c 2s")
        late.perform(.hit)
        t.check("not after a hit", !late.legalActions().contains(.surrender))
        var noSurrender = BlackjackRules()
        noSurrender.surrenderAllowed = false
        t.check("nor at a table without it", !table("Tc 5d 6h 7c", rules: noSurrender).legalActions().contains(.surrender))

        // Insurance and even money.
        var insured = table("Tc Ad 9h Kc")
        t.check("an ace up offers insurance", insured.phase == .insurance && !insured.isEvenMoneyOffer)
        insured.decideInsurance(take: true)
        t.check("insurance costs half the bet", insured.bankroll == 850 && insured.round?.insurance == 50)
        runDealer(&insured)
        t.check("insurance pays 2 to 1 against the dealer's blackjack (net 0)",
                insured.round?.insuranceReturned == 150 && insured.bankroll == 1_000 && insured.phase == .settled)
        var wasted = table("Tc Ad 9h 7c")
        wasted.decideInsurance(take: true)
        runDealer(&wasted)
        t.check("and is lost when the dealer has none", wasted.round?.insuranceReturned == 0
                && wasted.bankroll == 850 && wasted.phase == .playerTurn)
        var even = table("As Ad Kh Kc")
        t.check("a natural against an ace is offered even money", even.isEvenMoneyOffer)
        even.decideInsurance(take: true)
        runDealer(&even)
        t.check("even money pays 1 to 1 even against the dealer's blackjack",
                even.round?.hands[0].result == .evenMoney && even.bankroll == 1_100)
        var declined = table("As Ad Kh Kc")
        declined.decideInsurance(take: false)
        runDealer(&declined)
        t.check("declined, a natural against a natural pushes", declined.round?.hands[0].result == .push
                && declined.bankroll == 1_000)
        var poor = table("Tc Ad 9h 7c", bet: 100, bankroll: 100)
        t.check("no insurance offered to a player who cannot cover it", poor.phase != .insurance)
        runDealer(&poor)
        t.check("but the dealer still peeks", poor.phase == .playerTurn)

        for engine in [natural, win, tie, short, bust, double, give, insured, wasted, even, declined] {
            if !engine.isBalanced {
                t.check("the books balance after every payout", false)
                return
            }
        }
        t.check("the books balance after every payout", true)
    }

    // MARK: Splitting

    private static func splitting(_ t: TestReporter) {
        // 8–8 against a 6, re-split to four hands.
        var split = table("8c 6d 8h Tc 8s 8d 8h 3c Kc 2d 9s 5h 7c")
        t.check("a pair can be split", split.legalActions().contains(.split))
        split.perform(.split)
        t.check("into two hands of one card, each with the bet", split.round?.hands.count == 2
                && split.round?.hands.allSatisfy({ $0.cards.count == 1 && $0.bet == 100 }) == true
                && split.bankroll == 800)
        runDealer(&split)
        t.check("the first hand is dealt its second card", split.round?.hands[0].cards.count == 2)
        split.perform(.split)
        runDealer(&split)
        split.perform(.split)
        runDealer(&split)
        t.check("re-splits make four hands", split.round?.hands.count == 4)
        t.check("and no more", !split.legalActions().contains(.split))
        // The first hand is now 8–8 again, with four hands out: it may not
        // split, but may double.
        t.check("double after split is allowed", split.legalActions().contains(.double))
        split.perform(.double)
        runDealer(&split)
        t.check("play moves on to the next hand", split.round?.active == 1)
        while split.phase == .playerTurn {
            if split.needsAdvance { split.advance() } else { split.perform(.stand) }
        }
        runDealer(&split)
        t.check("every split hand is settled", split.phase == .settled
                && split.round?.hands.allSatisfy({ $0.isSettled }) == true)
        t.check("the split round balances", split.isBalanced)

        // Split, double one of the hands, dealer busts: each hand is paid on
        // its own bet — 400 back on the doubled 200, 200 on the other.
        var das = table("8c 6d 8h Tc 3s Kd 9h 9c")
        das.perform(.split)
        runDealer(&das)
        das.perform(.double)
        runDealer(&das)
        das.perform(.stand)
        runDealer(&das)
        t.check("split and double after split pay on each hand's own bet (400 and 200 back)",
                das.round?.hands.map(\.returned) == [400, 200] && das.bankroll == 1_300 && das.isBalanced)

        var noDAS = BlackjackRules()
        noDAS.doubleAfterSplit = false
        var strict = table("8c 6d 8h Tc 3s", rules: noDAS)
        strict.perform(.split)
        runDealer(&strict)
        t.check("no double after split at a table without it", !strict.legalActions().contains(.double))

        // Aces.
        var aces = table("Ac 6d Ah Tc Kd Ac 9s", bet: 100)
        aces.perform(.split)
        runDealer(&aces)
        t.check("split aces get one card each and play goes on", aces.round?.hands.allSatisfy({ $0.cards.count == 2 && $0.isDone }) == true
                && aces.phase != .playerTurn)
        t.check("an ace can't be re-split, even with another ace", aces.round?.hands[1].cards.map(\.card.rank) == [.ace, .ace])
        t.check("ace–ten after a split is 21, not blackjack", aces.round?.hands[0].total.total == 21
                && aces.round?.hands[0].isBlackjack == false)
        runDealer(&aces)
        t.check("and is paid 1 to 1 (200 back)", aces.round?.hands[0].result == .win && aces.round?.hands[0].returned == 200)

        // Split aces cannot hit.
        var acesTwo = table("Ac 6d Ah Tc 5d", bet: 100)
        acesTwo.perform(.split)
        acesTwo.advance()
        t.check("a split ace takes no more cards", acesTwo.round?.hands[0].isDone == true
                && !acesTwo.legalActions().contains(.hit))

        var broke = table("8c 6d 8h Tc", bet: 100, bankroll: 150)
        t.check("no split or double without the chips to cover it", !broke.legalActions().contains(.split)
                && !broke.legalActions().contains(.double))
        broke.perform(.stand)
        t.check("tens of different ranks split as a pair", hand("Kc Qd").isPair)
    }

    // MARK: Words on the table

    private static func labels(_ t: TestReporter) {
        t.check("a soft total reads 'Soft 17', a hard one '17'", BlackjackScene.totalText(BlackjackTotal(points: [1, 6])) == "Soft 17"
                && BlackjackScene.totalText(BlackjackTotal(points: [10, 7])) == "17")
        t.check("soft 21 reads '21'", BlackjackScene.totalText(BlackjackTotal(points: [1, 10])) == "21")
        var win = table("Tc 7d 9h Tc")
        win.perform(.stand)
        runDealer(&win)
        var natural = table("As 9d Kh 8c")
        runDealer(&natural)
        var give = table("Tc Td 6h 7c")
        runDealer(&give)
        give.perform(.surrender)
        runDealer(&give)
        func label(_ engine: BlackjackEngine) -> String? { BlackjackScene(engine: engine).hands.first?.label }
        t.check("results read 'Win +100', 'Blackjack +150', 'Surrender −50'",
                label(win) == "Win +100" && label(natural) == "Blackjack +150" && label(give) == "Surrender \u{2212}50")
        let paid = BlackjackScene(engine: natural)
        t.check("a paid natural shows the bet and the 3:2 beside it until collected",
                paid.stacks[.bet(0)]?.amount == 100 && paid.stacks[.payout(0)]?.amount == 150
                    && BlackjackScene(engine: natural, chipsCollected: true).chipsOnCloth == 0)
        t.check("the dealer's hole card is face down until turned", table("9c 6d 8h Tc").phase == .playerTurn
                && BlackjackScene(engine: table("9c 6d 8h Tc")).dealer.map(\.faceUp) == [true, false])
    }

    // MARK: The peek

    private static func peeking(_ t: TestReporter) {
        var ten = table("9c Kd 8h Ac")
        t.check("a ten up is peeked at at once", ten.phase == .peek)
        runDealer(&ten)
        t.check("a dealer blackjack ends the round before any decision", ten.phase == .settled
                && ten.round?.hands[0].cards.count == 2 && ten.round?.hands[0].result == .lose)
        t.check("it is shown", ten.round?.isHoleRevealed == true)
        var ace = table("9c Ad 8h Kc")
        t.check("an ace up asks about insurance first", ace.phase == .insurance && ace.legalActions().isEmpty)
        ace.decideInsurance(take: false)
        runDealer(&ace)
        t.check("then peeks and settles", ace.phase == .settled && ace.round?.hands[0].result == .lose)
        var none = table("9c Td 8h 7c")
        runDealer(&none)
        t.check("no blackjack: the player plays", none.phase == .playerTurn && !none.legalActions().isEmpty)
        t.check("with the hole card still down", none.round?.isHoleRevealed == false)
        var six = table("9c 6d 8h Ac")
        t.check("a six up is not peeked", six.phase == .playerTurn)
        six.perform(.stand)
        runDealer(&six)
        t.check("(and the dealer's A–6 stands later)", six.round?.dealerTotal.total == 17)
    }

    // MARK: The shoe

    private static func shoe(_ t: TestReporter) {
        for decks in BlackjackRules.deckChoices {
            var shoe = BlackjackShoe(decks: decks, seed: UInt64(decks) * 17)
            var composed = shoe.isComposed(withTable: [])
            let cut = shoe.cutRemaining
            let penetration = 1 - Double(cut) / Double(shoe.size)
            var shuffles = 0
            for round in 0..<600 {
                var table: [BlackjackCard] = []
                for _ in 0..<(4 + round % 5) { if let card = shoe.draw() { table.append(card) } }
                composed = composed && shoe.isComposed(withTable: table)
                shoe.discard(table)
                if shoe.isCutCardOut {
                    shoe.shuffle()
                    shuffles += 1
                    composed = composed && shoe.isComposed(withTable: []) && shoe.undealt.count == decks * 52
                }
            }
            t.check("\(decks)-deck shoe: always \(decks * 52) cards across \(shuffles) reshuffles", composed && shuffles > 0)
            t.check("\(decks)-deck shoe: the cut card goes in near 75% (\(Int(penetration * 100))%)",
                    abs(penetration - 0.75) < 0.05)
        }

        // The cut card comes out mid-round; the shuffle waits for the round.
        var rules = BlackjackRules()
        rules.decks = 1
        var engine = BlackjackEngine(rules: rules, seed: 9)
        var roundsToCut = 0
        var shuffledMidRound = false
        var shuffledAfter = false
        while roundsToCut < 40 {
            engine.addToBet(10)
            engine.deal()
            let shuffles = engine.shoe.shuffles
            while engine.phase != .settled {
                if engine.needsAdvance { engine.advance() } else if engine.phase == .insurance { engine.decideInsurance(take: false) } else {
                    engine.perform(.stand)
                }
            }
            if engine.shoe.shuffles != shuffles { shuffledMidRound = true }
            let out = engine.shoe.isCutCardOut
            let shuffled = engine.collect()
            roundsToCut += 1
            if out {
                shuffledAfter = shuffled && engine.shoe.undealt.count == 52
                break
            }
            if shuffled { shuffledMidRound = true }
        }
        t.check("the shoe is not shuffled while a round is in play", !shuffledMidRound)
        t.check("and is shuffled before the next round once the cut card is out (\(roundsToCut) rounds)",
                shuffledAfter)
        let a = BlackjackShoe(decks: 6, seed: 5)
        let b = BlackjackShoe(decks: 6, seed: 5)
        t.check("a seeded shoe deals the same cards every time", a == b && a != BlackjackShoe(decks: 6, seed: 6))

        // Run a single deck dry mid-round: the discards go back in.
        var dry = BlackjackShoe(decks: 1, seed: 3)
        var held: [BlackjackCard] = []
        for _ in 0..<40 { if let card = dry.draw() { held.append(card) } }
        dry.discard(Array(held.prefix(30)))
        held.removeFirst(30)
        for _ in 0..<20 { if let card = dry.draw() { held.append(card) } }
        t.check("a shoe that runs dry reshuffles its discards", held.count == 30 && dry.isComposed(withTable: held))
    }

    // MARK: Basic strategy

    private static func strategy(_ t: TestReporter) {
        let rules = BlackjackRules()
        let all: Set<BlackjackAction> = [.hit, .stand, .double, .split, .surrender]
        func advice(_ codes: String, _ up: String, _ rules: BlackjackRules = BlackjackRules(),
                    legal: Set<BlackjackAction>? = nil) -> BlackjackAction {
            let h = hand(codes)
            var allowed = legal ?? all
            if !h.isPair { allowed.remove(.split) }
            return BlackjackStrategy.recommendation(for: h, upCard: BlackjackCard(id: Int(card(up).code)),
                                                    rules: rules, legal: allowed)
        }
        t.check("11 vs 10 → double (6D S17)", advice("6c 5d", "Th") == .double)
        t.check("16 vs 10 → surrender", advice("Tc 6d", "Th") == .surrender)
        t.check("16 vs 10 → hit when surrender is not on offer", advice("Tc 6d", "Th", legal: [.hit, .stand]) == .hit)
        t.check("A7 vs 9 → hit", advice("Ac 7d", "9h") == .hit)
        t.check("A7 vs 4 → double", advice("Ac 7d", "4h") == .double)
        t.check("A7 vs 4 → stand when doubling is not allowed", advice("Ac 7d", "4h", legal: [.hit, .stand]) == .stand)
        t.check("88 vs A → split", advice("8c 8d", "Ah") == .split)
        t.check("12 vs 4 → stand", advice("Tc 2d", "4h") == .stand)
        t.check("12 vs 2 → hit", advice("Tc 2d", "2h") == .hit)
        t.check("AA vs anything → split", advice("Ac Ad", "Th") == .split && advice("Ac Ad", "6h") == .split)
        t.check("TT vs 6 → stand", advice("Tc Kd", "6h") == .stand)
        t.check("99 vs 7 → stand, 99 vs 8 → split", advice("9c 9d", "7h") == .stand && advice("9c 9d", "8h") == .split)
        t.check("55 vs 9 → double, like 10", advice("5c 5d", "9h") == .double)
        t.check("11 vs A → hit at 6D S17, double at H17", advice("6c 5d", "Ah") == .hit
                && advice("6c 5d", "Ah", { var r = rules; r.dealerHitsSoft17 = true; return r }()) == .double)
        t.check("11 vs A → double with one deck", advice("6c 5d", "Ah", { var r = rules; r.decks = 1; return r }()) == .double)
        t.check("15 vs A → surrender at H17 only", advice("Tc 5d", "Ah") == .hit
                && advice("Tc 5d", "Ah", { var r = rules; r.dealerHitsSoft17 = true; return r }()) == .surrender)
        // Eights that cannot be split (no chips for a second bet) are a hard 16.
        let noSplit: Set<BlackjackAction> = [.hit, .stand, .surrender]
        t.check("unsplittable 88 vs 10 → surrender, like 16", advice("8c 8d", "Th", legal: noSplit) == .surrender
                && advice("8c 8d", "9h", legal: noSplit) == .surrender && advice("8c 8d", "Ah", legal: noSplit) == .surrender)
        t.check("unsplittable 88 vs 9 at H17 → surrender, vs 7 → hit",
                advice("8c 8d", "9h", { var r = rules; r.dealerHitsSoft17 = true; return r }(), legal: noSplit) == .surrender
                    && advice("8c 8d", "7h", legal: noSplit) == .hit)
        let one = { () -> BlackjackRules in var r = rules; r.decks = 1; return r }()
        let two = { () -> BlackjackRules in var r = rules; r.decks = 2; return r }()
        let oneH17 = { () -> BlackjackRules in var r = one; r.dealerHitsSoft17 = true; return r }()
        let twoH17 = { () -> BlackjackRules in var r = two; r.dealerHitsSoft17 = true; return r }()
        t.check("2D S17: A2 and A3 vs 4 hit, A6 vs 2 hits", advice("Ac 2d", "4h", two) == .hit
                && advice("Ac 3d", "4h", two) == .hit && advice("Ac 6d", "2h", two) == .hit)
        t.check("1D S17: A2 and A3 vs 4 double, A6 vs 2 doubles", advice("Ac 2d", "4h", one) == .double
                && advice("Ac 3d", "4h", one) == .double && advice("Ac 6d", "2h", one) == .double)
        t.check("A7 vs A: stands at 1D S17, hits at 1D H17 and 2D", advice("Ac 7d", "Ah", one) == .stand
                && advice("Ac 7d", "Ah", oneH17) == .hit && advice("Ac 7d", "Ah", two) == .hit)
        t.check("H17 with one or two decks surrenders 15 and 17 against an ace",
                [oneH17, twoH17].allSatisfy { advice("Tc 5d", "Ah", $0) == .surrender && advice("Tc 7d", "Ah", $0) == .surrender })
        t.check("22 vs 3 → split with DAS, hit without", advice("2c 2d", "3h") == .split
                && advice("2c 2d", "3h", { var r = rules; r.doubleAfterSplit = false; return r }()) == .hit)
        t.check("a three-card 16 vs 10 hits", advice("Tc 4d 2h", "Th", legal: [.hit, .stand]) == .hit)
        t.check("soft 18 vs 2 → stand (S17), double (H17)", advice("Ac 7d", "2h") == .stand
                && advice("Ac 7d", "2h", { var r = rules; r.dealerHitsSoft17 = true; return r }()) == .double)
        t.check("never insurance", !BlackjackStrategy.takesInsurance)
    }

    // MARK: Saving

    private static func saving(_ t: TestReporter) {
        var engine = table("8c 6d 8h Tc 3s")
        engine.perform(.split)
        engine.advance()
        let saved = BlackjackSavedTable(engine: engine, coach: .coach, shoesStarted: 3)
        let data = (try? JSONEncoder().encode(saved)) ?? Data()
        let restored = try? JSONDecoder().decode(BlackjackSavedTable.self, from: data)
        t.check("a table saved mid-split comes back exactly", restored?.engine == engine && restored?.coach == .coach
                && restored?.shoesStarted == 3)
        var resumed = restored?.engine ?? engine
        var original = engine
        resumed.perform(.stand)
        original.perform(.stand)
        runDealer(&resumed)
        runDealer(&original)
        t.check("and plays on the same cards", resumed == original)

        // Tolerant decoding: nonsense values fall back one key at a time.
        let junk = #"{"engine":{"bankroll":750,"rules":{"decks":7,"dealerHitsSoft17":true,"minimumBet":"x"},"lastBet":50,"round":{"phase":"playerTurn","hands":[]}},"coach":9}"#
        let odd = try? JSONDecoder().decode(BlackjackSavedTable.self, from: Data(junk.utf8))
        t.check("a damaged file keeps what it can", odd?.engine.bankroll == 750 && odd?.engine.rules.decks == 6
                && odd?.engine.rules.dealerHitsSoft17 == true && odd?.engine.rules.minimumBet == 10
                && odd?.engine.lastBet == 50 && odd?.coach == .hints)
        t.check("an impossible round is dropped and the table balances", odd?.engine.round == nil
                && odd?.engine.isBalanced == true && odd?.engine.isComposed == true)

        // A table saved with a half chip in it reads back to the half.
        var halves = table("As 9d Kh 8c", bet: 25)
        runDealer(&halves)
        let halvesData = (try? JSONEncoder().encode(halves)) ?? Data()
        t.check("a bankroll of 1,037.5 is saved and restored to the half chip",
                (try? JSONDecoder().decode(BlackjackEngine.self, from: halvesData)) == halves
                    && String(decoding: halvesData, as: UTF8.self).contains("1037.5"))

        // Numbers no table could reach are held to ones it could, so a
        // damaged file can neither overflow a sum nor wedge the table.
        func damaged(_ edit: (String) -> String) -> BlackjackEngine? {
            var engine = table("8c 6d 8h Tc 3s")
            engine.perform(.stand)
            let text = String(decoding: (try? JSONEncoder().encode(engine)) ?? Data(), as: UTF8.self)
            return try? JSONDecoder().decode(BlackjackEngine.self, from: Data(edit(text).utf8))
        }
        func replacing(_ key: String, with value: String) -> (String) -> String {
            { text in
                guard let range = text.range(of: "\"\(key)\":") else { return text }
                let rest = text[range.upperBound...]
                let end = rest.firstIndex(where: { $0 == "," || $0 == "}" }) ?? rest.endIndex
                return text.replacingCharacters(in: range.upperBound..<end, with: value)
            }
        }
        let rich = damaged(replacing("bankroll", with: "9223372036854775807"))
        let bigBet = damaged(replacing("bet", with: "9223372036854775000"))
        let wedged = damaged(replacing("minimumBet", with: "5000"))
        var backwards = damaged(replacing("shuffles", with: "-7"))
        t.check("a bankroll near Int.max is held to the table's range and balances",
                rich.map { $0.bankroll <= BlackjackAmount(BlackjackEngine.largestAmount) && $0.isBalanced } == true)
        t.check("a bet past the table limit drops the round, refunding what the books say was bet",
                bigBet.map { $0.round == nil && $0.bankroll == 1_000 && $0.isBalanced } == true)
        t.check("a minimum bet of 5,000 is held to one a new bankroll can meet",
                wedged.map { $0.rules.minimumBet <= 100 && $0.rules.maximumBet >= $0.rules.minimumBet } == true)
        backwards?.collect()
        let reshuffled = backwards.map { shoe -> Bool in
            var shoe = shoe.shoe
            shoe.shuffle()
            return shoe.shuffles >= 1 && shoe.isComposed(withTable: [])
        }
        t.check("a negative shuffle count is read as none, and the shoe shuffles", reshuffled == true)

        // A shoe that lost a card is replaced and the round refunded.
        var broken = engine
        let text = String(decoding: (try? JSONEncoder().encode(broken)) ?? Data(), as: UTF8.self)
        let damaged = text.replacingOccurrences(of: "\"discard\":[]", with: "\"discard\":[0]")
        if let repaired = try? JSONDecoder().decode(BlackjackEngine.self, from: Data(damaged.utf8)) {
            broken = repaired
        }
        t.check("a shoe with a duplicated card is replaced, the bets on the table refunded",
                broken.round == nil && broken.isComposed && broken.bankroll == 1_000 && broken.isBalanced)
    }

    // MARK: Fuzz

    /// Fifty thousand rounds of random — but legal — play, including every
    /// rule set, bet sizes up to the limit, insurance taken at random and
    /// bankrupt players reset: after every step the chips must balance and
    /// the round must be one the engine could have made.
    private static func fuzz(_ t: TestReporter) {
        var rng = DeterministicRNG(seed: 0xB1AC_4ACC)
        let started = Date()
        var rules = BlackjackRules()
        var engine = BlackjackEngine(rules: rules, seed: 77)
        var balanced = true
        var composed = true
        var plausible = true
        var stuck = false
        var rounds = 0
        var shuffles = 0
        var splitsToFour = 0
        var insured = 0
        var results: [BlackjackResult: Int] = [:]
        let order = BlackjackAction.allCases

        for n in 0..<50_000 {
            if n % 5_000 == 0 {
                // A new table every so often, to cover every rule set.
                rules.decks = BlackjackRules.deckChoices[rng.next(upperBound: 4)]
                rules.dealerHitsSoft17 = rng.next(upperBound: 2) == 0
                rules.surrenderAllowed = rng.next(upperBound: 2) == 0
                rules.doubleAfterSplit = rng.next(upperBound: 2) == 0
                engine.startShoe(rules: rules, seed: UInt64(n) &+ 1)
            }
            if engine.isBroke { engine.resetBankroll() }
            let most = min(rules.maximumBet, engine.bankroll.wholeChips) / 5
            let bet = max(2, 2 + rng.next(upperBound: max(1, most - 1))) * 5
            guard engine.addToBet(min(bet, engine.betHeadroom)), engine.deal() else {
                stuck = true
                break
            }
            var steps = 0
            while engine.phase != .settled && steps < 200 {
                steps += 1
                if engine.needsAdvance {
                    engine.advance()
                } else if engine.phase == .insurance {
                    let take = rng.next(upperBound: 3) == 0
                    engine.decideInsurance(take: take)
                    if take { insured += 1 }
                } else {
                    let legal = order.filter(engine.legalActions().contains)
                    guard !legal.isEmpty else {
                        stuck = true
                        break
                    }
                    // Favour splitting, so re-splits get exercised.
                    let pick = legal.contains(.split) && rng.next(upperBound: 2) == 0
                        ? BlackjackAction.split : legal[rng.next(upperBound: legal.count)]
                    engine.perform(pick)
                }
                balanced = balanced && engine.isBalanced
                plausible = plausible && (engine.round?.isPlausible(maximumBet: engine.rules.maximumBet) ?? true)
            }
            if steps >= 200 { stuck = true }
            if stuck { break }
            if engine.round?.hands.count == 4 { splitsToFour += 1 }
            for hand in engine.round?.hands ?? [] {
                if let result = hand.result { results[result, default: 0] += 1 }
            }
            if n % 100 == 0 { composed = composed && engine.isComposed }
            if engine.collect() {
                shuffles += 1
                composed = composed && engine.isComposed && engine.shoe.undealt.count == engine.shoe.size
            }
            balanced = balanced && engine.isBalanced
            rounds += 1
        }
        let seconds = Date().timeIntervalSince(started)
        t.check("fuzz: \(rounds) random rounds finish without a stuck or impossible table", rounds == 50_000 && !stuck && plausible)
        t.check("fuzz: every chip accounted for after every step (bankroll + table + house)", balanced)
        t.check("fuzz: every card in the shoe, the tray or a hand, exactly once, across \(shuffles) shuffles", composed)
        t.check("fuzz: every outcome occurs, re-splits to four hands included (\(splitsToFour))",
                [.blackjack, .evenMoney, .win, .push, .lose, .bust, .surrender].allSatisfy { (results[$0] ?? 0) > 0 }
                    && splitsToFour > 0 && insured > 0)
        t.info(String(format: "fuzz took %.2f s", seconds))

        // Basic strategy's return should land near the textbook −0.4% for
        // these rules: within two standard errors of it over this many
        // rounds, close enough that a natural paid at even money (about
        // −2.3%) would fail.
        var strategist = BlackjackEngine(rules: BlackjackRules(), seed: 2_024, bankroll: 10_000_000)
        var wagered = BlackjackAmount.zero
        for _ in 0..<20_000 {
            strategist.addToBet(100)
            strategist.deal()
            while strategist.phase != .settled {
                if strategist.needsAdvance {
                    strategist.advance()
                } else if strategist.phase == .insurance {
                    strategist.decideInsurance(take: false)
                } else if let hand = strategist.activeHand, let up = strategist.round?.upCard {
                    strategist.perform(BlackjackStrategy.recommendation(
                        for: hand, upCard: up, rules: strategist.rules, legal: strategist.legalActions()))
                } else {
                    break
                }
            }
            wagered += strategist.round?.totalStaked ?? 0
            strategist.collect()
        }
        let edge = (strategist.bankroll - 10_000_000).chips / max(1, wagered.chips) * 100
        t.check(String(format: "basic strategy returns %.2f%% over 20,000 rounds (textbook ≈ −0.4%%)", edge),
                edge > -2.0 && edge < 1.2)
    }
}
