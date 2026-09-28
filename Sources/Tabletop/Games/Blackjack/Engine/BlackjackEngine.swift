//
//  BlackjackEngine.swift
//  The table, as numbers: the bankroll, the shoe, the round in play, and the
//  rules that move it along.
//
//  HOW IT RUNS
//
//  The engine never waits and never animates. It moves in two kinds of
//  steps. The player's — a chip on the bet, Deal, Hit, Take Insurance — are
//  methods that change the state at once and say whether they were allowed.
//  The dealer's — each opening card, the peek, the hole card, each of the
//  dealer's draws, the settlement — are `advance()`, one at a time, for as
//  long as `needsAdvance` says the table is waiting on the dealer rather
//  than on the player. The game calls `advance()` on its own clock, a beat
//  apart, and draws the table after each one; a test or a screenshot calls
//  it in a loop. Either way the state after every step is a real, stable
//  table — which is also what makes a round saved mid-deal resume exactly.
//
//  THE MONEY
//
//  Chips are never made or lost, only moved. The player was `funded` with
//  every chip they have ever had (1,000, and 1,000 more each time they
//  reset); at any moment those chips are in the player's `bankroll`, on the
//  table (`chipsInPlay`: the bet being built, hands not yet settled,
//  insurance still riding) or in the dealer's rack (`house`, which goes
//  negative when the player is winning). `isBalanced` checks the three add
//  back up, and the fuzz test checks it after every step of fifty thousand
//  rounds.
//
//  Bets are whole chips; payouts are exact, to the half chip (see
//  `BlackjackAmount`): a natural on 25 pays 37½, a surrendered 25 hands back
//  12½, and insurance on it costs 12½.
//

import Foundation

struct BlackjackEngine: Codable, Equatable {

    private(set) var rules: BlackjackRules
    /// Chips in front of the player, not on the table.
    private(set) var bankroll: BlackjackAmount
    /// The dealer's rack, net: what the house has won from the player.
    private(set) var house = BlackjackAmount.zero
    /// Every chip the player has been given.
    private(set) var funded: BlackjackAmount
    private(set) var shoe: BlackjackShoe
    /// The bet being built in the circle, before the deal.
    private(set) var pendingBet = 0
    /// The bet the last round was dealt with, for Rebet.
    private(set) var lastBet = 0
    /// The round being played, or just finished and still on the table.
    private(set) var round: BlackjackRound?

    init(rules: BlackjackRules = BlackjackRules(), seed: UInt64,
         bankroll: BlackjackAmount = BlackjackAmount(BlackjackRules.startingBankroll)) {
        self.rules = rules
        self.bankroll = bankroll
        self.funded = bankroll
        self.shoe = BlackjackShoe(decks: rules.decks, seed: seed, penetration: rules.penetration)
    }

    var phase: BlackjackPhase { round?.phase ?? .betting }

    /// Chips on the table that are still the player's to win or lose.
    var chipsInPlay: BlackjackAmount { BlackjackAmount(pendingBet) + (round?.chipsAtRisk ?? .zero) }

    /// Every chip is accounted for.
    var isBalanced: Bool { bankroll + chipsInPlay + house == funded }

    /// The shoe, the tray and the table hold every card exactly once.
    var isComposed: Bool { shoe.isComposed(withTable: round?.cardsOnTable ?? []) }

    // MARK: Betting

    /// What the player could still add to the bet, in whole chips: the
    /// table maximum, or what they have left, whichever is less.
    var betHeadroom: Int {
        guard phase == .betting else { return 0 }
        return max(0, min(rules.maximumBet - pendingBet, bankroll.wholeChips))
    }

    @discardableResult
    mutating func addToBet(_ amount: Int) -> Bool {
        guard phase == .betting, amount > 0, amount <= betHeadroom else { return false }
        bankroll -= BlackjackAmount(amount)
        pendingBet += amount
        return true
    }

    @discardableResult
    mutating func removeFromBet(_ amount: Int) -> Bool {
        guard phase == .betting, amount > 0, amount <= pendingBet else { return false }
        pendingBet -= amount
        bankroll += BlackjackAmount(amount)
        return true
    }

    mutating func clearBet() {
        guard phase == .betting else { return }
        bankroll += BlackjackAmount(pendingBet)
        pendingBet = 0
    }

    /// The last round's bet can go out again: there was one, it is not what
    /// is already in the circle, and the player can cover it.
    var canRebet: Bool {
        (phase == .betting || phase == .settled) && lastBet >= rules.minimumBet && lastBet <= rules.maximumBet
            && pendingBet != lastBet && bankroll + BlackjackAmount(pendingBet) >= BlackjackAmount(lastBet)
    }

    /// Replaces the bet in the circle with the last round's.
    @discardableResult
    mutating func rebet() -> Bool {
        guard phase == .betting, canRebet else { return false }
        bankroll += BlackjackAmount(pendingBet) - BlackjackAmount(lastBet)
        pendingBet = lastBet
        return true
    }

    var canDeal: Bool {
        phase == .betting && pendingBet >= rules.minimumBet && pendingBet <= rules.maximumBet
    }

    /// Takes the bet in the circle and starts the round.
    @discardableResult
    mutating func deal() -> Bool {
        guard canDeal else { return false }
        round = BlackjackRound(bet: pendingBet)
        lastBet = pendingBet
        pendingBet = 0
        return true
    }

    // MARK: The dealer's steps

    /// One thing the dealer did, for the table to show.
    enum Step: Equatable {
        case dealtToPlayer(hand: Int, card: BlackjackCard)
        case dealtToDealer(card: BlackjackCard, faceUp: Bool)
        case peeked(dealerBlackjack: Bool)
        case revealedHole
        case settled
        /// Nothing to do — `advance()` was called with nothing waiting.
        case none
    }

    /// The table is waiting on the dealer, not on the player.
    var needsAdvance: Bool {
        guard let round else { return false }
        switch round.phase {
        case .dealing, .peek, .dealerTurn, .settling: return true
        case .playerTurn: return round.hands[safe: round.active]?.cards.count == 1   // a split hand's second card
        case .betting, .insurance, .settled: return false
        }
    }

    /// The dealer's next step.
    @discardableResult
    mutating func advance() -> Step {
        guard var round else { return .none }
        defer { self.round = round }
        switch round.phase {
        case .dealing:
            // Player, dealer up, player, dealer down.
            let dealt = round.hands[0].cards.count + round.dealer.count
            guard let card = shoe.draw() else { return .none }
            let step: Step
            if dealt % 2 == 0 {
                round.hands[0].cards.append(card)
                step = .dealtToPlayer(hand: 0, card: card)
            } else {
                round.dealer.append(card)
                step = .dealtToDealer(card: card, faceUp: dealt == 1)
            }
            if dealt == 3 { openingDealt(&round) }
            return step

        case .peek:
            let blackjack = round.dealerHasBlackjack
            if round.insurance > .zero {
                let returned = blackjack ? round.insurance * 3 : .zero
                round.insuranceReturned = returned
                bankroll += returned
                house += round.insurance - returned
            }
            if blackjack {
                // No decisions against a dealer natural: the hole card turns
                // over and the round is settled.
                round.isHoleRevealed = true
                for i in round.hands.indices { round.hands[i].isDone = true }
                round.phase = .settling
            } else if round.hands[0].isBlackjack {
                round.hands[0].isDone = true
                round.phase = .dealerTurn
            } else {
                round.phase = .playerTurn
                round.active = 0
            }
            return .peeked(dealerBlackjack: blackjack)

        case .playerTurn:
            // A split hand waiting for its second card.
            let i = round.active
            guard round.hands[safe: i]?.cards.count == 1, let card = shoe.draw() else { return .none }
            round.hands[i].cards.append(card)
            if round.hands[i].isSplitAces || round.hands[i].total.total >= 21 {
                finishHand(&round)
            }
            return .dealtToPlayer(hand: i, card: card)

        case .dealerTurn:
            let step: Step
            if !round.isHoleRevealed {
                round.isHoleRevealed = true
                step = .revealedHole
            } else if let card = shoe.draw() {
                round.dealer.append(card)
                step = .dealtToDealer(card: card, faceUp: true)
            } else {
                step = .none
            }
            if !dealerWillDraw(round) { round.phase = .settling }
            return step

        case .settling:
            settle(&round)
            return .settled

        case .betting, .insurance, .settled:
            return .none
        }
    }

    /// After the fourth card: insurance, a peek, or straight to the player.
    private func openingDealt(_ round: inout BlackjackRound) {
        guard let up = round.upCard else { return }
        if up.isAce {
            round.phase = canOfferInsurance(round) ? .insurance : .peek
        } else if up.isTenValue {
            round.phase = .peek
        } else if round.hands[0].isBlackjack {
            round.hands[0].isDone = true
            round.phase = .dealerTurn
        } else {
            round.phase = .playerTurn
            round.active = 0
        }
    }

    /// Even money needs no chips; insurance needs half the bet.
    private func canOfferInsurance(_ round: BlackjackRound) -> Bool {
        let cost = BlackjackAmount(round.hands[0].bet).half
        return round.hands[0].isBlackjack || (cost > .zero && bankroll >= cost)
    }

    /// Whether the dealer draws again: only while a hand is left to beat,
    /// to sixteen, and on a soft seventeen at an H17 table.
    private func dealerWillDraw(_ round: BlackjackRound) -> Bool {
        guard round.isHoleRevealed, round.hands.contains(where: \.isLive) else { return false }
        let total = round.dealerTotal
        return total.total < 17 || (total.total == 17 && total.isSoft && rules.dealerHitsSoft17)
    }

    /// Whether the dealer's hand as it stands would draw — for the tests.
    func dealerShouldDraw(_ cards: [BlackjackCard]) -> Bool {
        let total = BlackjackTotal(cards)
        return total.total < 17 || (total.total == 17 && total.isSoft && rules.dealerHitsSoft17)
    }

    // MARK: Insurance

    /// What insurance would cost: half the bet, to the half chip.
    var insuranceCost: BlackjackAmount { BlackjackAmount(round?.hands.first?.bet ?? 0).half }

    /// The player holds a natural against the dealer's ace: the offer is
    /// even money rather than insurance.
    var isEvenMoneyOffer: Bool { phase == .insurance && round?.hands.first?.isBlackjack == true }

    @discardableResult
    mutating func decideInsurance(take: Bool) -> Bool {
        guard var round, round.phase == .insurance else { return false }
        if take {
            if round.hands[0].isBlackjack {
                round.hands[0].tookEvenMoney = true
                round.hands[0].isDone = true
            } else {
                let cost = insuranceCost
                guard cost > .zero, cost <= bankroll else { return false }
                bankroll -= cost
                round.insurance = cost
            }
        }
        round.phase = .peek
        self.round = round
        return true
    }

    // MARK: The player's decisions

    /// The hand being played, if the player is to act on it.
    var activeHand: BlackjackHand? {
        guard let round, round.phase == .playerTurn, !needsAdvance else { return nil }
        return round.hands[safe: round.active]
    }

    /// Every decision open to the player right now.
    func legalActions() -> Set<BlackjackAction> {
        guard let round, let hand = activeHand, !hand.isDone else { return [] }
        var actions: Set<BlackjackAction> = [.stand]
        if !hand.isSplitAces { actions.insert(.hit) }
        let twoCards = hand.cards.count == 2
        let covered = bankroll >= BlackjackAmount(hand.bet)
        if twoCards && !hand.isSplitAces && covered && (!hand.isFromSplit || rules.doubleAfterSplit) {
            actions.insert(.double)
        }
        if twoCards && hand.isPair && !hand.isSplitAces && round.hands.count < rules.maximumHands && covered {
            actions.insert(.split)
        }
        // Late surrender: the first decision of an unsplit hand.
        if rules.surrenderAllowed && twoCards && round.hands.count == 1 && !hand.isFromSplit {
            actions.insert(.surrender)
        }
        return actions
    }

    /// Plays `action` on the active hand. Returns the card it dealt, if any,
    /// or nil when the action was not allowed (and nothing changed).
    @discardableResult
    mutating func perform(_ action: BlackjackAction) -> Step? {
        guard legalActions().contains(action), var round else { return nil }
        defer { self.round = round }
        let i = round.active
        switch action {
        case .hit:
            guard let card = shoe.draw() else { return nil }
            round.hands[i].cards.append(card)
            if round.hands[i].total.total >= 21 { finishHand(&round) }
            return .dealtToPlayer(hand: i, card: card)

        case .stand:
            finishHand(&round)
            return Step.none

        case .double:
            guard let card = shoe.draw() else { return nil }
            bankroll -= BlackjackAmount(round.hands[i].bet)
            round.hands[i].bet *= 2
            round.hands[i].isDoubled = true
            round.hands[i].cards.append(card)
            finishHand(&round)
            return .dealtToPlayer(hand: i, card: card)

        case .split:
            let hand = round.hands[i]
            bankroll -= BlackjackAmount(hand.bet)
            let aces = hand.cards[0].isAce
            var first = BlackjackHand(bet: hand.bet)
            first.cards = [hand.cards[0]]
            first.isFromSplit = true
            first.isSplitAces = aces
            var second = first
            second.cards = [hand.cards[1]]
            round.hands[i] = first
            round.hands.insert(second, at: i + 1)
            // `needsAdvance` now deals the first hand its second card.
            return Step.none

        case .surrender:
            round.hands[i].isSurrendered = true
            finishHand(&round)
            return Step.none
        }
    }

    /// The active hand takes no more cards: on to the next hand that still
    /// wants them, or to the dealer.
    private func finishHand(_ round: inout BlackjackRound) {
        round.hands[round.active].isDone = true
        if let next = round.hands.indices.first(where: { $0 > round.active && !round.hands[$0].isDone }) {
            round.active = next
        } else {
            round.phase = .dealerTurn
        }
    }

    // MARK: Settling

    private mutating func settle(_ round: inout BlackjackRound) {
        let dealer = round.dealerTotal
        let dealerBlackjack = round.dealerHasBlackjack
        for i in round.hands.indices {
            let hand = round.hands[i]
            let bet = BlackjackAmount(hand.bet)
            let result: BlackjackResult
            let returned: BlackjackAmount
            if hand.tookEvenMoney {
                (result, returned) = (.evenMoney, bet * 2)
            } else if hand.isSurrendered {
                (result, returned) = (.surrender, bet.half)
            } else if hand.isBust {
                (result, returned) = (.bust, .zero)
            } else if hand.isBlackjack {
                // Three to two, exactly: the bet back and one and a half times it.
                (result, returned) = dealerBlackjack ? (.push, bet) : (.blackjack, bet + (bet * 3).half)
            } else if dealerBlackjack {
                (result, returned) = (.lose, .zero)
            } else if dealer.isBust || hand.total.total > dealer.total {
                (result, returned) = (.win, bet * 2)
            } else if hand.total.total == dealer.total {
                (result, returned) = (.push, bet)
            } else {
                (result, returned) = (.lose, .zero)
            }
            round.hands[i].result = result
            round.hands[i].returned = returned
            round.hands[i].isDone = true
            bankroll += returned
            house += bet - returned
        }
        round.isHoleRevealed = true
        round.phase = .settled
    }

    // MARK: Between rounds

    /// Clears a settled round off the table — cards to the discard tray —
    /// and shuffles if the cut card came out. True if it shuffled.
    @discardableResult
    mutating func collect() -> Bool {
        guard let round, round.phase == .settled else { return false }
        shoe.discard(round.cardsOnTable)
        self.round = nil
        guard shoe.isCutCardOut else { return false }
        shoe.shuffle()
        return true
    }

    /// Walks away from a round mid-hand: whatever is still riding goes to
    /// the house, and the cards to the tray. What New Game does to a round
    /// in play.
    mutating func forfeitRound() {
        guard var round else { return }
        if round.phase == .settled {
            collect()
            return
        }
        house += round.chipsAtRisk
        for i in round.hands.indices where !round.hands[i].isSettled {
            round.hands[i].result = .lose
            round.hands[i].returned = .zero
        }
        if round.insuranceReturned == nil { round.insuranceReturned = .zero }
        shoe.discard(round.cardsOnTable)
        self.round = nil
    }

    /// A new shoe at `rules`. Only between rounds, with the bet in the
    /// circle handed back.
    mutating func startShoe(rules newRules: BlackjackRules, seed: UInt64) {
        forfeitRound()
        clearBet()
        rules = newRules
        shoe = BlackjackShoe(decks: newRules.decks, seed: seed, penetration: newRules.penetration)
        if lastBet > rules.maximumBet || lastBet < rules.minimumBet { lastBet = 0 }
    }

    /// The player can no longer make the table minimum.
    var isBroke: Bool {
        (phase == .betting || phase == .settled) && pendingBet == 0 && bankroll < BlackjackAmount(rules.minimumBet)
    }

    /// A fresh bankroll, between rounds.
    mutating func resetBankroll() {
        if phase == .settled { collect() }
        guard phase == .betting else { return }
        clearBet()
        let fresh = BlackjackAmount(BlackjackRules.startingBankroll)
        funded += fresh - bankroll
        bankroll = fresh
    }

    // MARK: Screenshots and tests

    /// Puts `cards` on top of the shoe, the first to be dealt first.
    @discardableResult
    mutating func stackShoe(_ cards: [Card]) -> Bool {
        shoe.stack(cards)
    }

    // MARK: Restoring

    private enum CodingKeys: String, CodingKey {
        case rules, bankroll, house, funded, shoe, pendingBet, lastBet, round
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        // Every number is held to a range no table could leave — a
        // hand-edited or damaged file must not be able to overflow a sum.
        rules = value(.rules, BlackjackRules())
        let money = BlackjackAmount.zero...BlackjackAmount(Self.largestAmount)
        bankroll = value(.bankroll, BlackjackAmount(BlackjackRules.startingBankroll)).clamped(to: money)
        house = value(.house, BlackjackAmount.zero).clamped(to: -money.upperBound...money.upperBound)
        pendingBet = max(0, min(rules.maximumBet, value(.pendingBet, 0)))
        lastBet = max(0, min(rules.maximumBet, value(.lastBet, 0)))
        round = value(.round, nil as BlackjackRound?)
        let fallbackShoe = BlackjackShoe(decks: rules.decks, seed: UInt64(truncatingIfNeeded: bankroll.halves &* 7_919),
                                         penetration: rules.penetration)
        shoe = value(.shoe, fallbackShoe)
        funded = value(.funded, bankroll + BlackjackAmount(pendingBet) + house)
            .clamped(to: -money.upperBound * 10...money.upperBound * 10)
        repair(fallbackShoe: fallbackShoe)
    }

    /// What a round dropped on restoring hands back: its stake — but never
    /// more than the books say left the bankroll, since the round's own
    /// figures may be the damaged part.
    private func refund(_ round: BlackjackRound) -> BlackjackAmount {
        let books = funded - bankroll - house - BlackjackAmount(pendingBet)
        return max(.zero, min(round.chipsAtRisk, books))
    }

    /// No bankroll, house or funding past this is believed.
    static let largestAmount = 100_000_000

    /// Makes a restored table whole: a round that could not have happened is
    /// refunded, a shoe that has lost or doubled a card is replaced, and the
    /// books are balanced.
    private mutating func repair(fallbackShoe: BlackjackShoe) {
        if let round, !round.isPlausible(maximumBet: rules.maximumBet) {
            bankroll += refund(round)
            self.round = nil
        }
        if shoe.decks != rules.decks || !isComposed {
            if let round {
                bankroll += refund(round)
                self.round = nil
            }
            shoe = fallbackShoe
        }
        if pendingBet > 0 && round != nil {
            bankroll += BlackjackAmount(pendingBet)
            pendingBet = 0
        }
        if !isBalanced { house = funded - bankroll - chipsInPlay }
    }
}
