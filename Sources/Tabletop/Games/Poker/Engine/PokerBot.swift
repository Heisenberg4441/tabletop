//
//  PokerBot.swift
//  The computer players' decisions.
//
//  A bot is a pure function of the table: `PokerBot.decide(table:seat:)`
//  looks at a copy, thinks, and says what it would do. No state of its own
//  (its "memory" is the hand's action log, which is on the table), no
//  clock, no main thread — the UI calls it on a background queue through
//  `PokerBotWorker` and shows a thinking ring while it waits. The randomness
//  that keeps it from being a robot comes from a generator seeded by the
//  table's seed and the point in the hand, so the same situation always gets
//  the same answer: tests and screenshots repeat exactly.
//
//  HOW IT THINKS
//  * Preflop: the Chen score of its two cards, shifted by its personality
//    and blurred by its difficulty, against thresholds that widen with
//    position (fewer players behind), shrink with each raise in front, and
//    move with the price. At 12 big blinds or fewer it only pushes or folds.
//    Two spots are priced rather than scored, because there the price is
//    everything: facing an all-in (or a raise for a third of its chips), and
//    defending its blind against a raise. There it deals out its equity
//    against the raiser's likely range — how wide someone shoves 10 big
//    blinds deep, how wide they open from the button — widened for an
//    opponent it has watched do it hand after hand (`PokerPlayer.habits`),
//    and calls when the pot pays for it.
//  * Postflop: Monte-Carlo equity against everyone still in, their cards
//    narrowed a little by what they have done (a preflop raiser rarely holds
//    seven-deuce; someone betting the flop rarely holds nothing), weighed
//    against the pot odds, with draws given some credit for what they could
//    win later. On top of that, the human touches, each a dice roll scaled by
//    personality: c-bets as the preflop raiser, semi-bluffs with draws,
//    bluffs on boards that scare, and slow-played monsters.
//  * Sizes are fractions of the pot rounded to the table's chip unit; a bet
//    that would leave a quarter of the stack or less goes all-in instead.
//  * Difficulty is how well it does all that: Casual samples less, misjudges
//    more, ignores what opponents' actions say, calls too much and gives its
//    hand away with its bet sizes; Sharp samples most, reads ranges, bluffs
//    in position and sizes its bluffs like its value bets.
//
//  Whatever the logic says, the answer is checked against the table's
//  options before it leaves: a bot cannot make an illegal move, and the test
//  suite checks it never even tries (`wasCorrected`).
//

import Foundation

/// A bot's answer.
struct PokerBotDecision: Hashable, Sendable {
    let action: PokerAction
    /// How hard the decision was, 0…1: a trash fold is near 0, a call for
    /// the stack near 1. The UI maps it onto its thinking pause (0.6–1.8 s,
    /// or 0.25–0.6 s in Fast mode) so easy folds come quickly.
    let deliberation: Double
    /// The Monte-Carlo equity it acted on, postflop.
    let equity: Double?
    /// The logic produced something illegal and was overruled. Never true
    /// in practice; the tests hold it to that.
    let wasCorrected: Bool
}

/// A personality in numbers.
struct PokerBotStyle: Hashable, Sendable {
    /// Added to the Chen score before comparing with the thresholds.
    var looseness: Double
    /// How readily it bets and raises rather than checks and calls, 0…1.
    var aggression: Double
    /// Base chance of a pure bluff where one makes sense.
    var bluff: Double
    /// Equity it will give up when calling, i.e. how sticky it is.
    var stickiness: Double
    /// Chance of checking or just calling with a monster.
    var slowPlay: Double
    /// Chance of a continuation bet as the preflop raiser.
    var cbet: Double

    static func of(_ personality: PokerPersonality) -> PokerBotStyle {
        switch personality {
        case .tightAggressive:
            return PokerBotStyle(looseness: 0, aggression: 0.72, bluff: 0.12, stickiness: 0, slowPlay: 0.12, cbet: 0.66)
        case .looseAggressive:
            return PokerBotStyle(looseness: 1.8, aggression: 0.82, bluff: 0.22, stickiness: 0.02, slowPlay: 0.08, cbet: 0.76)
        case .tightPassive:
            return PokerBotStyle(looseness: -0.8, aggression: 0.3, bluff: 0.04, stickiness: 0.02, slowPlay: 0.28, cbet: 0.34)
        case .callingStation:
            return PokerBotStyle(looseness: 1.4, aggression: 0.28, bluff: 0.05, stickiness: 0.09, slowPlay: 0.16, cbet: 0.42)
        }
    }
}

/// A difficulty in numbers.
struct PokerBotSkill: Hashable, Sendable {
    /// Monte-Carlo deals per postflop decision.
    var samples: Int
    /// Uniform error added to its equity estimate, ±.
    var equityNoise: Double
    /// Uniform error added to its preflop hand score, ±.
    var chenNoise: Double
    /// How much it narrows opponents' ranges from their actions, 0…1.
    var narrowing: Double
    /// Extra equity it gives up when calling (on top of personality).
    var stickiness: Double
    /// Scales every bluff.
    var bluffScale: Double
    /// Plays wider in late position and bluffs more when last to act.
    var positionAware: Bool
    /// Bets big with strong hands and small with bluffs — a tell to exploit.
    var sizingTells: Bool
    /// The share of its equity it expects to turn into chips after calling a
    /// raise before the flop, for a hand of even equity: a weak hand out of
    /// position realises less, a strong one more (see `blindDefence`), and a
    /// weaker player less of either. What a blind defence is priced with.
    var realization: Double

    static func of(_ difficulty: PokerDifficulty) -> PokerBotSkill {
        switch difficulty {
        case .casual:
            return PokerBotSkill(samples: 1_000, equityNoise: 0.09, chenNoise: 1.5, narrowing: 0.3,
                                 stickiness: 0.05, bluffScale: 0.5, positionAware: false, sizingTells: true,
                                 realization: 0.66)
        case .standard:
            return PokerBotSkill(samples: 2_000, equityNoise: 0.04, chenNoise: 0.8, narrowing: 0.8,
                                 stickiness: 0.02, bluffScale: 0.85, positionAware: true, sizingTells: false,
                                 realization: 0.72)
        case .sharp:
            return PokerBotSkill(samples: 3_000, equityNoise: 0, chenNoise: 0.35, narrowing: 1,
                                 stickiness: 0, bluffScale: 1, positionAware: true, sizingTells: false,
                                 realization: 0.74)
        }
    }
}

enum PokerBot {

    /// What the bot in `seat` does now. Pure and thread-safe: call it off
    /// the main thread. `samples` overrides the difficulty's Monte-Carlo
    /// count (tests and simulations use fewer); `difficulty` overrides the
    /// table's (simulations that seat different levels together).
    static func decide(table: PokerTable, seat: Int, samples: Int? = nil,
                       difficulty: PokerDifficulty? = nil) -> PokerBotDecision {
        guard table.phase == .betting, table.players.indices.contains(seat) else {
            return PokerBotDecision(action: .check, deliberation: 0, equity: nil, wasCorrected: false)
        }
        let options = table.options(for: seat)
        var mind = PokerBotMind(table: table, seat: seat, options: options, samplesOverride: samples,
                                difficulty: difficulty ?? table.config.difficulty)
        let choice = table.street == .preflop ? mind.preflop() : mind.postflop()
        let legal = PokerTable.isLegal(choice.action, options)
        let action = legal ? choice.action : (options.canCheck ? .check : (options.canCall ? .call : .fold))
        let jitter = (PokerEquity.unit(&mind.rng) - 0.5) * 0.16
        return PokerBotDecision(action: action, deliberation: max(0, min(1, choice.deliberation + jitter)),
                                equity: choice.equity, wasCorrected: !legal)
    }

    /// Plays the hand on with bots in every seat that is asked — or stops
    /// when it reaches the human's turn, if `stopAtHuman` — through every
    /// street and the payout. For the fast-forward after the player folds
    /// (run it off the main thread; apply the result there) and for tests.
    /// Returns everything that happened, in order.
    @discardableResult
    static func playOut(_ table: inout PokerTable, stopAtHuman: Bool = false, samples: Int? = nil) -> [PokerEvent] {
        var events: [PokerEvent] = []
        var guardSteps = 0
        while guardSteps < 1_000 {
            guardSteps += 1
            switch table.phase {
            case .betting:
                guard let seat = table.toAct else { return events }
                if stopAtHuman && table.players[seat].isHuman { return events }
                let decision = decide(table: table, seat: seat, samples: samples)
                if let produced = try? table.apply(decision.action) {
                    events += produced
                } else if let produced = try? table.apply(table.options()?.passiveAction ?? .fold) {
                    events += produced
                } else {
                    return events
                }
            case .streetComplete:
                events += table.advance()
            case .betweenHands, .gameOver:
                return events
            }
        }
        return events
    }
}

/// One decision's worth of thinking.
private struct PokerBotMind {

    struct Choice {
        var action: PokerAction
        var deliberation: Double
        var equity: Double? = nil
    }

    let table: PokerTable
    let seat: Int
    let o: PokerActionOptions
    let me: PokerPlayer
    let style: PokerBotStyle
    let skill: PokerBotSkill
    let bigBlind: Double
    /// The most this hand can be played for: the smaller of our chips and
    /// the biggest opponent's.
    let effectiveStack: Int
    var rng: DeterministicRNG

    init(table: PokerTable, seat: Int, options: PokerActionOptions, samplesOverride: Int?, difficulty: PokerDifficulty) {
        self.table = table
        self.seat = seat
        self.o = options
        me = table.players[seat]
        style = PokerBotStyle.of(me.personality)
        var skill = PokerBotSkill.of(difficulty)
        if let samplesOverride { skill.samples = max(1, samplesOverride) }
        self.skill = skill
        bigBlind = Double(max(1, table.blinds.bigBlind))
        let biggestOpponent = table.players.filter { $0.isInHand && $0.seat != seat }.map(\.chipsInPlay).max() ?? 0
        effectiveStack = min(me.chipsInPlay, biggestOpponent)
        let mix = table.seed
            ^ (UInt64(table.handNumber) &* 0x9E37_79B9_7F4A_7C15)
            ^ (UInt64(table.handLog.count) &* 0xC2B2_AE3D_27D4_EB4F)
            ^ (UInt64(seat) &* 0x1656_67B1_9E37_79F9)
        rng = DeterministicRNG(seed: mix)
    }

    // MARK: Dice

    mutating func roll(_ probability: Double) -> Bool {
        PokerEquity.unit(&rng) < probability
    }

    mutating func noise(_ amplitude: Double) -> Double {
        amplitude == 0 ? 0 : (PokerEquity.unit(&rng) * 2 - 1) * amplitude
    }

    mutating func between(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * PokerEquity.unit(&rng)
    }

    // MARK: Actions

    var fold: PokerAction { o.canCheck ? .check : .fold }

    /// Bet or raise to `total`, rounded to the chip unit — all-in when that
    /// would leave a quarter of the stack or less behind.
    func aggressive(to total: Double) -> PokerAction {
        guard o.canBetOrRaise else { return o.passiveAction }
        let unit = Double(max(1, table.chipUnit))
        let rounded = o.clampTotal(Int((total / unit).rounded() * unit))
        if Double(rounded - o.playerBet) >= 0.75 * Double(o.stack) { return .allIn }
        return o.aggressiveAction(to: rounded)
    }

    func raiseToBigBlinds(_ multiple: Double) -> PokerAction {
        aggressive(to: multiple * bigBlind)
    }

    /// A bet or raise of `fraction` of the pot.
    func potBet(_ fraction: Double) -> PokerAction {
        aggressive(to: Double(o.potFractionTotal(fraction)))
    }

    /// Everything, or a call when raising is not open to us.
    var shove: PokerAction { o.canBetOrRaise || o.callIsAllIn ? .allIn : o.passiveAction }

    /// Call — or, when the call would leave only crumbs behind, all-in.
    var callOrCommit: PokerAction {
        guard o.canCall else { return .check }
        let behind = o.stack - o.callAmount
        if behind > 0 && Double(behind) < 0.3 * Double(o.pot + o.callAmount) && o.canBetOrRaise { return .allIn }
        return .call
    }

    // MARK: Preflop

    mutating func preflop() -> Choice {
        let hole = me.holeCards
        let chen = PokerEquity.chen(hole)
        let strength = chen + style.looseness + noise(skill.chenNoise)
        let log = table.handLog.filter { $0.street == .preflop }
        let raises = log.filter(\.isAggressive).count
        let limpers = raises == 0 ? log.filter { $0.kind == .call }.count : 0
        let dealt = table.players.filter { $0.status != .out }.count
        let behind = table.seatsStillToAct(after: seat).count
        let isBigBlind = seat == table.bigBlindSeat
        let isSmallBlind = seat == table.smallBlindSeat
        let toCall = Double(o.callAmount)
        let suited = hole.count == 2 && hole[0].suit == hole[1].suit
        let pair = hole.count == 2 && hole[0].pokerRank == hole[1].pokerRank

        // Fewer players behind, fewer who can wake up with a better hand.
        // Chen 7.5 is about the top 14% of hands, 5.5 about the top 35%.
        var openThreshold: Double
        switch behind {
        case 0, 1, 2: openThreshold = 5.5
        case 3: openThreshold = 6.5
        case 4: openThreshold = 7
        default: openThreshold = 7.5
        }
        if !skill.positionAware { openThreshold = 6.5 }
        if dealt == 2 { openThreshold = 4 } else if dealt == 3 { openThreshold -= 0.5 }

        // Passive players need more to re-raise than their looseness says.
        let threeBet = 11.5 - style.aggression * 2 + (1 - style.aggression) * 1.5
        if raises > 0, let lastRaise = log.last(where: \.isAggressive), lastRaise.seat != seat {
            // Calling would put a third of what this hand can be played for
            // in the middle — or the raise is all in: a price, not a score.
            let committing = table.players[lastRaise.seat].status == .allIn
                || toCall * 3 >= Double(effectiveStack) || Double(effectiveStack) / bigBlind <= 12
            if committing { return commitment(lastRaise: lastRaise) }
            if raises == 1 && (isBigBlind || isSmallBlind) {
                return blindDefence(strength: strength, lastRaise: lastRaise, threeBet: threeBet)
            }
        }

        if Double(effectiveStack) / bigBlind <= 12 {
            return shortStack(strength: strength, openThreshold: openThreshold, raises: raises)
        }

        if raises == 0 {
            if o.canCheck {
                // The big blind, limped to: raise the good ones, see a flop with the rest.
                if strength >= 10.5 && roll(style.aggression) {
                    return Choice(action: raiseToBigBlinds(3.5 + Double(limpers)), deliberation: 0.5)
                }
                return Choice(action: .check, deliberation: 0.2)
            }
            if strength >= openThreshold {
                if style.aggression < 0.5 && strength < openThreshold + 2.5 && roll(1 - style.aggression) {
                    return Choice(action: .call, deliberation: 0.35)
                }
                let size = skill.sizingTells ? 3 : between(2.2, 2.8)
                return Choice(action: raiseToBigBlinds(size + Double(limpers)), deliberation: 0.4)
            }
            if limpers > 0 && strength >= openThreshold - 1.5 && toCall <= bigBlind
                && roll(0.35 + style.stickiness * 4) {
                return Choice(action: .call, deliberation: 0.35)
            }
            if isSmallBlind && strength >= openThreshold - 2 && toCall <= bigBlind / 2 {
                return Choice(action: .call, deliberation: 0.3)
            }
            return Choice(action: fold, deliberation: strength < openThreshold - 3 ? 0.1 : 0.3)
        }

        let raiseSize = Double(o.currentBet) / bigBlind
        if raises == 1 {
            let callThreshold = max(openThreshold, 7) + 0.5 + max(0, raiseSize - 3) * 0.5
                - (isBigBlind ? 1.5 : 0) - style.stickiness * 10
            if strength >= threeBet {
                return Choice(action: aggressive(to: Double(o.currentBet) * (behind > 0 ? 3.5 : 3)), deliberation: 0.6)
            }
            if skill.positionAware && behind <= 2 && suited && (6..<9).contains(chen) && roll(style.bluff * 0.5) {
                return Choice(action: aggressive(to: Double(o.currentBet) * 3), deliberation: 0.6)
            }
            if pair && toCall <= Double(effectiveStack) / 15 && roll(0.85) {
                return Choice(action: callOrCommit, deliberation: 0.45)
            }
            if strength >= callThreshold {
                return Choice(action: callOrCommit, deliberation: 0.5)
            }
            return Choice(action: fold, deliberation: 0.35)
        }

        // A three-bet or more in front: only the best hands go on.
        let fourBet = 13.5 - style.aggression
        let callThreshold = 11 + (toCall > Double(effectiveStack) * 0.3 ? 1 : 0) - style.stickiness * 10
        if strength >= fourBet {
            return Choice(action: aggressive(to: Double(o.currentBet) * 2.3), deliberation: 0.8)
        }
        if strength >= callThreshold {
            return Choice(action: callOrCommit, deliberation: 0.75)
        }
        return Choice(action: fold, deliberation: 0.5)
    }

    /// Twelve big blinds or fewer: all-in or out.
    mutating func shortStack(strength: Double, openThreshold: Double, raises: Int) -> Choice {
        let stackInBlinds = Double(effectiveStack) / bigBlind
        let push = openThreshold - 1 - (12 - stackInBlinds) * 0.45
        if raises == 0 {
            if o.canCheck {
                return Choice(action: strength >= push + 2 ? shove : .check, deliberation: 0.3)
            }
            if strength >= push { return Choice(action: shove, deliberation: 0.6) }
            if seat == table.smallBlindSeat && strength >= push - 3 && Double(o.callAmount) <= bigBlind / 2 {
                return Choice(action: .call, deliberation: 0.3)
            }
            return Choice(action: fold, deliberation: 0.2)
        }
        let toCall = Double(o.callAmount)
        let potOdds = toCall / max(1, Double(o.pot) + toCall)
        let callThreshold = 6 + potOdds * 8 - style.stickiness * 10
        if potOdds < 0.2 && strength >= 5 { return Choice(action: callOrCommit, deliberation: 0.4) }
        if strength >= callThreshold {
            return Choice(action: o.canBetOrRaise || o.callIsAllIn ? .allIn : .call, deliberation: 0.8)
        }
        return Choice(action: fold, deliberation: 0.55)
    }

    // MARK: Priced preflop decisions

    /// The preflop action order: left of the big blind round to it
    /// (heads-up, the button first).
    var preflopOrder: [Int] {
        let dealt = table.players.filter { $0.holeCards.count == 2 }.map(\.seat)
        let fromButton = table.orderedFromButton(dealt)
        guard let bb = table.bigBlindSeat, let i = fromButton.firstIndex(of: bb) else { return fromButton }
        return Array(fromButton[(i + 1)...] + fromButton[...i])
    }

    /// The share of starting hands `player` makes `record`'s raise with.
    ///
    /// A starting point from the situation — all in `depth` big blinds deep,
    /// roughly as wide as the push-or-fold charts (everything at five big
    /// blinds, half the hands at ten, one in twelve at sixty); an open
    /// raise, wide from the small blind and tighter with every player left
    /// behind; tighter again over somebody else's raise — then blended with
    /// what this player has actually been doing, the more so the better the
    /// bot reads: a seat that has moved in six hands of six is shoving
    /// nearly anything, one that never has, only its best.
    func raiseRange(of player: PokerPlayer, record: PokerActionRecord) -> Double {
        let shove = record.isAllIn || record.total * 3 >= max(1, player.stackAtHandStart)
        let order = preflopOrder
        let behind = order.firstIndex(of: record.seat).map { order.count - 1 - $0 } ?? 1
        let before = table.handLog.prefix { $0 != record }.filter { $0.street == .preflop && $0.isAggressive }.count
        var base: Double
        if shove {
            let depth = Double(min(player.stackAtHandStart, max(me.stackAtHandStart, me.chipsInPlay))) / bigBlind
            base = min(1, 5.5 / max(1, depth))
        } else {
            base = 0.62
        }
        base *= pow(0.72, Double(max(0, behind - 1)))
        if before > 0 { base *= 0.55 }
        base = max(0.03, base)
        let rate = player.habitRate(prior: base, weight: 4 / max(0.25, skill.narrowing)) { habit in
            shove ? habit == .shoved : habit != .passive
        }
        return max(0.03, min(1, rate))
    }

    /// The opponents a call would be up against — the raiser, and whoever
    /// has already called it — each with the range their action suggests,
    /// and how many are still to have their say.
    func opponentsOfRaise(_ lastRaise: PokerActionRecord) -> (ranges: [PokerRangeFilter], stillToAnswer: Int) {
        let raiser = table.players[lastRaise.seat]
        let share = raiseRange(of: raiser, record: lastRaise)
        let after = table.handLog.drop { $0 != lastRaise }.dropFirst()
        var ranges = [PokerEquity.topRange(share)]
        var stillToAnswer = 0
        for p in table.players where p.isInHand && p.seat != seat && p.seat != raiser.seat {
            if after.contains(where: { $0.seat == p.seat && ($0.kind == .call || $0.isAggressive) }) {
                // Called a raise they could have folded to: a strong hand.
                ranges.append(PokerEquity.topRange(max(0.03, share * 0.6)))
            } else {
                stillToAnswer += 1
            }
        }
        return (ranges, stillToAnswer)
    }

    /// Facing an all-in, or a raise that commits a third of what the hand is
    /// played for: call (or move in over it) when the equity against the
    /// raiser's range beats the price.
    mutating func commitment(lastRaise: PokerActionRecord) -> Choice {
        let toCall = Double(o.callAmount)
        let (ranges, stillToAnswer) = opponentsOfRaise(lastRaise)
        var need = toCall / max(1, Double(o.pot) + toCall)
        // Somebody behind may wake up with a hand.
        need += min(0.1, 0.025 * Double(stillToAnswer))
        // A tournament life is worth more than its chips while there are
        // places to be paid below the winner's.
        let alive = table.players.filter { $0.stack > 0 || $0.isInHand }.count
        if table.config.mode == .tournament && alive >= 3 && toCall >= Double(o.stack) * 0.8 { need += 0.03 }
        need -= style.stickiness + skill.stickiness + style.looseness * 0.008
        let samples = max(150, skill.samples / 3)
        var equity = PokerEquity.estimate(hole: me.holeCards, board: [], opponents: ranges, samples: samples, rng: &rng)
        equity = max(0, min(1, equity + noise(skill.equityNoise)))
        let close = abs(equity - need) < 0.06
        guard equity >= need else {
            return Choice(action: fold, deliberation: close ? 0.85 : 0.45, equity: equity)
        }
        // A big raise with chips left behind it: calling most of the stack
        // only to fold the rest later is the worst of both.
        if table.players[lastRaise.seat].status != .allIn && o.canBetOrRaise && equity >= need + 0.06 {
            return Choice(action: .allIn, deliberation: 0.8, equity: equity)
        }
        return Choice(action: callOrCommit, deliberation: close ? 0.9 : 0.6, equity: equity)
    }

    /// In a blind, facing one raise that is not for the stack: the blind is
    /// already in, so the price is good — continue when the equity against
    /// the raiser's range, discounted for playing the hand out of position
    /// (`realization`), pays for the call. The best hands re-raise, and a
    /// bot that notices somebody raising every hand re-raises them lighter.
    mutating func blindDefence(strength: Double, lastRaise: PokerActionRecord, threeBet: Double) -> Choice {
        if strength >= threeBet {
            return Choice(action: aggressive(to: Double(o.currentBet) * 3.5), deliberation: 0.6)
        }
        let toCall = Double(o.callAmount)
        let (ranges, stillToAnswer) = opponentsOfRaise(lastRaise)
        let share = raiseRange(of: table.players[lastRaise.seat], record: lastRaise)
        var need = toCall / max(1, Double(o.pot) + toCall)
        need += 0.03 * Double(stillToAnswer)
        // Its character, not its skill: a better player defends wider here,
        // because it plays the flop better (`realization`).
        need -= style.stickiness + style.looseness * 0.008
        let samples = max(150, skill.samples / 4)
        var equity = PokerEquity.estimate(hole: me.holeCards, board: [], opponents: ranges, samples: samples, rng: &rng)
        equity = max(0, min(1, equity + noise(skill.equityNoise)))
        if skill.positionAware && ranges.count == 1 && share >= 0.45 && equity >= 0.56 && roll(style.aggression * 0.6) {
            return Choice(action: aggressive(to: Double(o.currentBet) * 3), deliberation: 0.6, equity: equity)
        }
        // Trash that flops little and plays the hand out of position keeps
        // less of its equity than a hand that dominates: heads-up against a
        // min-raise that folds roughly the worst quarter of hands.
        let realized = equity * max(0.4, min(1, skill.realization + 0.9 * (equity - 0.5)))
        if realized >= need {
            return Choice(action: callOrCommit, deliberation: 0.45, equity: equity)
        }
        return Choice(action: fold, deliberation: realized >= need - 0.04 ? 0.5 : 0.25, equity: equity)
    }

    // MARK: Postflop

    mutating func postflop() -> Choice {
        let opponents = table.players.filter { $0.isInHand && $0.seat != seat }
        let filters = opponents.map(rangeFilter)
        var equity = PokerEquity.estimate(hole: me.holeCards, board: table.board, opponents: filters,
                                          samples: skill.samples, rng: &rng)
        equity = max(0, min(1, equity + noise(skill.equityNoise)))
        let texture = PokerEquity.texture(hole: me.holeCards, board: table.board)
        let pot = Double(max(1, o.pot))
        let toCall = Double(o.callAmount)
        let potOdds = toCall / (pot + toCall)
        let stackToPot = Double(effectiveStack) / pot
        let lastToAct = table.seatsStillToAct(after: seat).isEmpty
        let headsUp = opponents.count == 1
        let river = table.street == .river
        let isAggressor = table.preflopAggressor == seat
        let bluffChance = style.bluff * skill.bluffScale * (skill.positionAware && lastToAct ? 1.5 : 1)

        func choice(_ action: PokerAction, _ deliberation: Double) -> Choice {
            Choice(action: action, deliberation: deliberation, equity: equity)
        }

        if o.canCheck {
            if equity >= 0.72 {
                if texture.dry && equity >= 0.85 && !river && roll(style.slowPlay) {
                    return choice(.check, 0.45)
                }
                return choice(potBet(valueSize(equity: equity, texture: texture)), 0.5)
            }
            if equity >= 0.56 && roll(0.3 + style.aggression * 0.45) {
                return choice(potBet(skill.sizingTells ? 0.66 : between(0.4, 0.55)), 0.45)
            }
            if isAggressor && table.street == .flop && opponents.count <= 2
                && roll(style.cbet * (texture.dry ? 1.1 : 0.75)) {
                return choice(potBet(between(0.33, 0.5)), 0.4)
            }
            // Having bet the last street and been called, keep the story
            // going now and then — with some equity, or on a card that scares.
            if table.lastStreetAggressor == seat && opponents.count <= 2
                && (equity >= 0.45 || texture.scary) && roll(style.aggression * 0.5 * skill.bluffScale) {
                return choice(potBet(between(0.5, 0.7)), 0.5)
            }
            if texture.hasDraw && !river && roll(style.aggression * 0.5) {
                return choice(potBet(between(0.5, 0.66)), 0.5)
            }
            if headsUp && equity < 0.35 && (river || texture.scary) && roll(bluffChance) {
                return choice(potBet(bluffSize()), 0.6)
            }
            // Checked to, last to act, against one or two: take a stab at a
            // pot nobody seems to want.
            if lastToAct && opponents.count <= 2 && !river && roll(style.aggression * 0.3 * skill.bluffScale) {
                return choice(potBet(between(0.33, 0.5)), 0.4)
            }
            return choice(.check, 0.25)
        }

        // Facing a bet. Calling before the river buys a card but invites
        // more bets on the streets to come, so it needs a margin over the
        // bare price — which a draw earns back in what it wins when it hits.
        // A bigger bet also says more about the hand behind it than its
        // price alone.
        var needed = potOdds - style.stickiness - skill.stickiness
        switch table.street {
        case .flop: needed += 0.09
        case .turn: needed += 0.07
        default: needed += 0.04
        }
        needed += 0.1 * min(1, toCall / max(1, pot - toCall))
        if texture.hasDraw && !river && stackToPot > 2 { needed -= 0.06 }
        if skill.sizingTells && toCall > pot * 0.9 { needed += 0.06 }        // big bets scare it off
        let bigDecision = toCall >= Double(o.stack) * 0.3
        if equity >= 0.82 || (equity >= 0.7 && headsUp && roll(style.aggression * 0.6)) {
            if o.canRaise && !(roll(style.slowPlay) && !river) {
                return choice(aggressive(to: Double(o.currentBet) * between(2.5, 3.2)), 0.7)
            }
            return choice(callOrCommit, 0.6)
        }
        if texture.hasDraw && table.street == .flop && o.canRaise && roll(style.aggression * 0.18) {
            return choice(aggressive(to: Double(o.currentBet) * between(2.6, 3.0)), 0.7)
        }
        if headsUp && texture.scary && equity < 0.3 && o.canRaise && roll(bluffChance * 0.2) {
            return choice(aggressive(to: Double(o.currentBet) * 2.8), 0.8)
        }
        if equity >= needed {
            return choice(callOrCommit, bigDecision ? 0.9 : 0.55)
        }
        if potOdds < 0.12 && equity > 0.2 {
            return choice(.call, 0.4)
        }
        return choice(.fold, bigDecision ? 0.85 : 0.45)
    }

    /// How big a value bet is, as a fraction of the pot.
    mutating func valueSize(equity: Double, texture: PokerEquity.Texture) -> Double {
        if skill.sizingTells { return between(0.8, 1.0) }
        if texture.wet || texture.hasDraw { return between(0.6, 0.8) }
        return equity > 0.9 ? between(0.5, 0.75) : between(0.33, 0.55)
    }

    /// A bluff is sized like a value bet, except by a bot that gives itself away.
    mutating func bluffSize() -> Double {
        skill.sizingTells ? 0.33 : between(0.5, 0.75)
    }

    /// What an opponent's actions this hand say about their cards.
    func rangeFilter(for opponent: PokerPlayer) -> PokerRangeFilter {
        guard skill.narrowing > 0 else { return .anyHand }
        let actions = table.handLog.filter { $0.seat == opponent.seat }
        let preflopRaises = actions.filter { $0.street == .preflop && $0.isAggressive }.count
        let preflopCalls = actions.filter { $0.street == .preflop && $0.kind == .call }.count
        let postflopAggression = actions.filter { $0.street > .preflop && $0.isAggressive }.count
        let postflopCalls = actions.filter { $0.street > .preflop && $0.kind == .call }.count
        var filter = PokerRangeFilter()
        if preflopRaises >= 2 {
            filter.minChen = 10
            filter.weakKeep = 0.1
        } else if preflopRaises == 1 {
            // A raise from somebody who raises everything says less.
            let share = opponent.habitRate(prior: 0.18, weight: 4 / max(0.25, skill.narrowing)) { $0 != .passive }
            filter.minChen = min(7.5, PokerEquity.chenThreshold(top: share))
            filter.weakKeep = 0.2
        } else if preflopCalls > 0 {
            filter.minChen = 5
            filter.weakKeep = 0.45
        }
        // Betting and raising says "I have it" (or a bluff, which the keep
        // probabilities leave room for); calling says "I have something".
        if postflopAggression >= 2 {
            filter.airKeep = 0.1
            filter.weakPairKeep = 0.3
        } else if postflopAggression == 1 {
            filter.airKeep = 0.2
            filter.weakPairKeep = 0.6
        } else if postflopCalls > 0 {
            filter.airKeep = 0.5
        }
        filter.weakKeep = 1 - (1 - filter.weakKeep) * skill.narrowing
        filter.airKeep = 1 - (1 - filter.airKeep) * skill.narrowing
        filter.weakPairKeep = 1 - (1 - filter.weakPairKeep) * skill.narrowing
        return filter
    }
}

// MARK: - Thinking off the main thread

/// Runs bot decisions on a background queue and hands the answers back on
/// the main thread — and only if they are still wanted. `cancel()` (a new
/// game, leaving the table) makes any answer in flight vanish, so a stale
/// decision can never land on a new hand.
///
/// The decision itself takes milliseconds; the thinking pause the player
/// sees is the UI's, on its `TableScheduler`, which suspends with the game.
/// So pausing needs nothing here: an answer that arrives while the game is
/// in the background waits in the scheduler like any other step.
#if os(macOS)
@MainActor
final class PokerBotWorker {

    private let queue = DispatchQueue(label: "com.tabletop.poker.bots", qos: .userInitiated)
    private var generation = 0
    private(set) var isThinking = false

    /// Asks the bot in `seat` about `table` (a copy is taken). `completion`
    /// runs on the main thread unless `cancel()` is called first.
    func decide(_ table: PokerTable, seat: Int, samples: Int? = nil,
                completion: @escaping (PokerBotDecision) -> Void) {
        generation += 1
        let ticket = generation
        isThinking = true
        queue.async { [weak self] in
            let decision = PokerBot.decide(table: table, seat: seat, samples: samples)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == ticket else { return }
                    self.isThinking = false
                    completion(decision)
                }
            }
        }
    }

    /// Plays the rest of the hand with bots (see `PokerBot.playOut`) in the
    /// background and returns the finished table and its events.
    func playOut(_ table: PokerTable, stopAtHuman: Bool,
                 completion: @escaping (PokerTable, [PokerEvent]) -> Void) {
        generation += 1
        let ticket = generation
        isThinking = true
        queue.async { [weak self] in
            var copy = table
            let events = PokerBot.playOut(&copy, stopAtHuman: stopAtHuman)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == ticket else { return }
                    self.isThinking = false
                    completion(copy, events)
                }
            }
        }
    }

    /// Forgets every answer still on its way.
    func cancel() {
        generation += 1
        isThinking = false
    }
}
#endif
