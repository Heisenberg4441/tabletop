//
//  DurakBot.swift
//  The computer players: Easy, Normal and Hard.
//
//  A bot is a pure function from a position to a decision. It keeps no state
//  of its own — its "memory" is the public record the engine keeps (the
//  discard, and `DurakState.known`: cards everybody saw go into a hand) and
//  its randomness is drawn from the deal's seed and the move number — so a
//  bot is safe to run on any thread, the same position always gets the same
//  answer, and a game restored from disk plays on exactly as it would have.
//
//  It never looks at another player's hand. Everything it reasons with goes
//  through `DurakBotView`, which is built from what that seat could see at a
//  real table.
//
//  HOW THEY PLAY
//
//  Every card has a cost: its rank (0 for a six ... 8 for an ace) plus 9 if it
//  is a trump, so the ace of trumps is the dearest card in the deck. Around
//  that, the courtyard's rules of thumb:
//
//  * Lead the cheapest card that is not a trump, preferably of a rank you
//    hold two of (the second can be thrown in after it). Keep trumps and aces
//    back while the deck is thick. Once it is gone, shed: lead sets, and what
//    the defender cannot beat.
//  * Throw in cheap cards of the ranks on the table while the deck is full —
//    the defender spends a card on each and you draw a fresh one — and pile
//    junk on a defender who is taking. Never hand over trumps early.
//  * Defend with the cheapest set of cards that covers every attack (a small
//    matching problem, searched exhaustively), but take instead when that
//    would cost more than picking the cards up is worth at this stage: early
//    on, two low cards in the hand beat two trumps gone. In perevodnoy,
//    transfer when it is cheap and unlikely to come straight back.
//
//  BREAKING LOOPS. Once the deck is gone, three players who each lead what
//  the next cannot beat can pass the same kings round by takes for ever (and
//  two can, in perevodnoy, by transferring). People notice and change tack;
//  so do the bots. After a run of takes with no bito
//  (`DurakState.boutsWithoutBito`, three per player still in), where a loop
//  is possible at all, every bot plays for progress: leads one of its lowest
//  cards, at random, beats whenever it can, and neither transfers nor piles
//  on — until a bito resets the count. Random play always escapes such a loop (the fuzzer plays tens of
//  thousands of games to prove it), and the bots then play near enough to it.
//
//  Easy plays those rules with no memory, a greedy defence and a little
//  randomness. Normal remembers the discard and the pick-ups, weighs how
//  likely the defender is to beat each card, and counts out the last few
//  cards of a two-player ending exactly. Hard does the same and, once the
//  deck is gone and two players are left, plays every ending it can read to
//  the end perfectly with `DurakEndgameSolver`.
//

import Foundation

enum DurakDifficulty: String, Codable, CaseIterable, Sendable {
    case easy, normal, hard

    var localizedName: String {
        switch self {
        case .easy: return NSLocalizedString("Easy", comment: "durak difficulty")
        case .normal: return NSLocalizedString("Normal", comment: "durak difficulty")
        case .hard: return NSLocalizedString("Hard", comment: "durak difficulty")
        }
    }

    /// Normal and Hard keep track of the discard and of what others picked up.
    var remembers: Bool { self != .easy }
}

/// What one seat knows: its own hand, the table, the discard, the counts of
/// everyone's cards, and — for a bot with a memory — which cards others were
/// seen to take into their hands. Nothing else.
struct DurakBotView {

    let seat: Int
    let trump: Suit
    let variant: DurakVariant
    let phase: DurakPhase
    let attacker: Int
    let defender: Int
    let hand: [Card]
    let handSet: DurakCardSet
    let counts: [Int]
    let stockCount: Int
    /// The deck's size just after the deal: 24 with two players, 12 with four.
    let initialStock: Int
    let table: [DurakPair]
    let unbeatenAttacks: [Card]
    let throwInCandidates: [Card]
    let transferTarget: Int?
    let activeCount: Int
    /// A long run of takes with no bito: time to play for progress.
    let isStalled: Bool
    let remembers: Bool
    /// Cards seen to go into each hand (empty sets for a bot without memory).
    let known: [DurakCardSet]
    /// Cards whose whereabouts this seat does not know: in some hand or in
    /// the deck (and, for a bot without memory, possibly in the discard).
    let unseen: DurakCardSet

    init(state: DurakState, seat: Int, remembers: Bool) {
        self.seat = seat
        trump = state.trump
        variant = state.rules.variant
        phase = state.phase
        attacker = state.attacker
        defender = state.defender
        hand = state.hands[seat]
        handSet = DurakCardSet(hand)
        counts = state.hands.map(\.count)
        stockCount = state.stockCount
        initialStock = 36 - DurakRules.handSize * state.playerCount
        table = state.table
        unbeatenAttacks = state.unbeatenAttacks
        throwInCandidates = state.throwInCandidates(for: seat)
        transferTarget = state.transferTarget
        activeCount = state.activeSeats.count
        // Only where a loop can happen at all. Between two players nothing
        // repeats while the deck lasts (every take leaves the attacker short
        // and drawing), nor ever in podkidnoy (see DurakEndgameSolver): a run
        // of takes there is simply someone being punished, and should go on
        // being punished, with throw-ins and all.
        let active = state.activeSeats.count
        let canLoop = active > 2 || (state.stockCount == 0 && state.rules.variant == .perevodnoy)
        isStalled = canLoop && state.boutsWithoutBito >= 3 * max(2, active)
        self.remembers = remembers
        var seen = handSet.union(DurakCardSet(state.tableCards))
        // The trump card under the deck is face up for everyone to see.
        if state.trumpCardInStock { seen.insert(state.trumpCard) }
        if remembers {
            known = state.known.enumerated().map { $0.offset == seat ? DurakCardSet() : DurakCardSet($0.element) }
            seen = seen.union(DurakCardSet(state.discard))
            for set in known { seen = seen.union(set) }
        } else {
            known = Array(repeating: DurakCardSet(), count: state.playerCount)
        }
        unseen = DurakCardSet.all.subtracting(seen)
    }

    /// How far into the deck the game is: 0 at the deal, 1 once it is gone.
    var progress: Double {
        initialStock > 0 ? 1 - Double(stockCount) / Double(initialStock) : 1
    }

    var isEndgame: Bool { stockCount == 0 }

    func isTrump(_ card: Card) -> Bool { card.suit == trump }

    /// The bots' measure of how precious a card is.
    func cost(_ card: Card) -> Int { card.durakRankIndex + (card.suit == trump ? 9 : 0) }

    func count(ofRank rank: Rank) -> Int { hand.reduce(0) { $0 + ($1.rank == rank ? 1 : 0) } }

    /// Cards in `other`'s hand this seat cannot account for.
    func unknownSlots(_ other: Int) -> Int { max(0, counts[other] - known[other].count) }

    /// The chance that `other` holds `card`.
    func probabilityHolds(_ other: Int, _ card: Card) -> Double {
        if known[other].contains(card) { return 1 }
        guard unseen.contains(card), unseen.count > 0 else { return 0 }
        return min(1, Double(unknownSlots(other)) / Double(unseen.count))
    }

    /// The chance that `other` holds at least one card that beats `attack`:
    /// certain if one was seen going in, otherwise hypergeometric over the
    /// cards this seat cannot place.
    func probabilityCanBeat(_ other: Int, _ attack: Card) -> Double {
        let beaters = DurakCardSet.beaters(of: attack, trump: trump)
        if !known[other].intersection(beaters).isEmpty { return 1 }
        let good = unseen.intersection(beaters).count
        let slots = unknownSlots(other)
        let pool = unseen.count
        guard good > 0, slots > 0, pool > 0 else { return 0 }
        var none = 1.0
        for i in 0..<slots {
            let remaining = pool - i
            guard remaining > 0 else { break }
            none *= max(0, Double(remaining - good)) / Double(remaining)
            if none == 0 { break }
        }
        return 1 - none
    }
}

struct DurakBot: Sendable {

    /// The heuristics' weights, in card-cost units (a six is 0, an ace 8, a
    /// trump 9 more). Tuned by A/B matches of thousands of games against the
    /// previous weights, two to four players, both variants; the big wins
    /// were leading cheap cards (not merely unbeatable ones) once the deck is
    /// gone, keeping the strong ones to defend with, and throwing in freely.
    struct Tuning: Sendable {
        // Leading while the deck lasts.
        var leadPair = 1.6
        var leadTrumpEarly = 4.0
        var leadAceEarly = 2.0
        var leadUnbeatable = 2.5
        // Leading once it is gone.
        var endLeadCost = 1.0
        var endLeadSet = 5.0
        var endLeadUnbeatable = 2.0
        /// The defender down to one card or two with the deck gone: what a
        /// lead they can beat costs, heads up and round a bigger table.
        var endLeadLastCard = 24.0
        var endLeadLastTwo = 10.0
        var endLeadLastCardTable = 8.0
        var endLeadLastTwoTable = 4.0
        // Defending.
        var beatWeightEndgame = 0.35
        var takeBase = 8.0
        var takeGrowth = 12.0
        var takePerCard = 1.5
        var takePerCardGrowth = 2.5
        var takeEndgame = 30.0
        /// With two players a transfer comes straight back to you with one
        /// more card; round a bigger table it moves on. Measured: be sparing
        /// with two, keen with more.
        var transferBonusHeadsUp = 1.5
        var transferBonus = 4.5
        var transferRisk = 4.0
        // Adding cards.
        var throwBase = 6.0
        var throwGrowth = 8.0
        var pileBase = 4.0
        var pileGrowth = 4.0
        var throwUnbeatable = 2.5
        var endTrumpOdds = 0.35
    }

    let difficulty: DurakDifficulty
    let tuning: Tuning

    init(_ difficulty: DurakDifficulty, tuning: Tuning = Tuning()) {
        self.difficulty = difficulty
        self.tuning = tuning
    }

    /// `seat`'s decision in `state`, which must be `seat`'s to make. Pure and
    /// thread-safe: run it off the main thread (Hard's endgame search can
    /// take a few tens of milliseconds) and apply the result on it.
    func decide(in state: DurakState, seat: Int) -> DurakAction {
        decideReporting(in: state, seat: seat).action
    }

    /// `decide`, also saying whether the heuristics produced something illegal
    /// and a legal fallback had to be used — which the self-tests insist
    /// never happens.
    func decideReporting(in state: DurakState, seat: Int) -> (action: DurakAction, fellBack: Bool) {
        let legal = state.legalActions(for: seat)
        guard let first = legal.first else { return (.pass, true) }
        if legal.count == 1 { return (first, false) }
        var rng = DeterministicRNG(seed: Self.seed(for: state, seat: seat))
        let view = DurakBotView(state: state, seat: seat, remembers: difficulty.remembers)
        var choice = heuristicChoice(view, rng: &rng)
        guard legal.contains(choice) else { return (first, true) }

        // Podkidnoy between two can never loop, so the solver is always safe
        // there; a perevodnoy position can, and a stalled one is left to the
        // loop-breaking heuristics.
        if let reach = solverReach(transfers: view.variant == .perevodnoy), view.isEndgame, view.activeCount <= 2,
           !(view.isStalled && view.variant == .perevodnoy) {
            var solver = DurakEndgameSolver(trump: state.trump, transfers: state.rules.variant == .perevodnoy,
                                            budget: reach.budget)
            // Keeps the heuristic's move when it is as good as any — it is
            // the more natural of equals — and otherwise plays the best.
            if let best = solver.choose(in: state, for: seat, preferring: choice, maximumCards: reach.cards),
               legal.contains(best) {
                choice = best
            }
        }
        return (choice, false)
    }

    /// How big a two-player ending, deck gone, this bot reads to the end —
    /// cards in play, and the positions it may look at — or nil if it never
    /// does.
    ///
    /// Hard reads every ending it can finish in its thinking pause. Normal
    /// reads the last few cards, as anyone who remembers what has gone does:
    /// with four or five cards between two players, "if I lead the queen he
    /// cannot beat it and has to take" is plain counting, not genius — and a
    /// won courtyard ending thrown away by leading the one card the last
    /// card beats is the mistake nobody forgives. Easy counts nothing.
    func solverReach(transfers: Bool) -> (cards: Int, budget: Int)? {
        switch difficulty {
        case .hard:
            return transfers
                ? (DurakEndgameSolver.maximumCards, DurakEndgameSolver.defaultBudget)
                : (DurakEndgameSolver.maximumCardsWithoutTransfers, DurakEndgameSolver.deepBudget)
        case .normal:
            return (8, 20_000)
        case .easy:
            return nil
        }
    }

    /// A human-looking pause before a bot's move: 0.5–1.2 s, a touch longer
    /// for a defence with choices to weigh. Deterministic, like the rest.
    static func thinkingDelay(in state: DurakState, seat: Int) -> TimeInterval {
        var rng = DeterministicRNG(seed: seed(for: state, seat: seat) ^ 0x5DEE_CE66_D1CE_4E5B)
        let base = 0.5 + Double(rng.next(upperBound: 1000)) / 1000 * 0.5
        let weighing = state.phase == .defend ? min(0.2, Double(state.legalActions(for: seat).count) * 0.03) : 0
        return min(1.2, base + weighing)
    }

    static func seed(for state: DurakState, seat: Int) -> UInt64 {
        var h = state.seed &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(state.actionCount) &* 0xBF58_476D_1CE4_E5B9
        h ^= UInt64(seat + 1) &* 0x94D0_49BB_1331_11EB
        return h
    }

    // MARK: Heuristics

    private var noise: Double { difficulty == .easy ? 0.3 : 0 }
    private var weighsOdds: Bool { difficulty != .easy }

    func heuristicChoice(_ view: DurakBotView, rng: inout DeterministicRNG) -> DurakAction {
        if view.isStalled { return progressChoice(view, rng: &rng) }
        switch view.phase {
        case .lead: return chooseLead(view, rng: &rng)
        case .defend: return chooseDefence(view, rng: &rng)
        case .throwIn: return chooseThrowIn(view, pileOn: false, rng: &rng)
        case .pileOn: return chooseThrowIn(view, pileOn: true, rng: &rng)
        case .over: return .pass
        }
    }

    /// The lowest-scoring card, or with Easy's noise sometimes the runner-up
    /// when it is nearly as good.
    private func pick(_ scored: [(Card, Double)], rng: inout DeterministicRNG) -> Card? {
        let sorted = scored.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.durakIndex < $1.0.durakIndex) }
        guard let best = sorted.first else { return nil }
        if noise > 0, sorted.count > 1, sorted[1].1 - best.1 < 3,
           Double(rng.next(upperBound: 1000)) / 1000 < noise {
            return sorted[1].0
        }
        return best.0
    }

    /// Play that gets cards out of the game: a low lead the defender can
    /// probably beat, a beat whenever there is one, nothing added.
    private func progressChoice(_ view: DurakBotView, rng: inout DeterministicRNG) -> DurakAction {
        switch view.phase {
        case .lead:
            let cheapest = view.hand.sorted {
                view.cost($0) < view.cost($1) || (view.cost($0) == view.cost($1) && $0.durakIndex < $1.durakIndex)
            }
            guard !cheapest.isEmpty else { return .pass }
            return .attack(cheapest[rng.next(upperBound: min(3, cheapest.count))])
        case .defend:
            if let cover = Self.cheapestCover(view.unbeatenAttacks, hand: view.hand, trump: view.trump),
               let first = cover.pairs.first {
                return .defend(first.defence, on: first.attack)
            }
            return .take
        case .throwIn, .pileOn, .over:
            return .pass
        }
    }

    private func chooseLead(_ view: DurakBotView, rng: inout DeterministicRNG) -> DurakAction {
        let defender = view.defender
        var scored: [(Card, Double)] = []
        for card in view.hand {
            let same = Double(view.count(ofRank: card.rank) - 1)
            let trump = view.isTrump(card)
            var score: Double
            if !view.isEndgame {
                let p = view.progress
                score = Double(view.cost(card))
                score -= (trump ? 0.5 : tuning.leadPair) * same
                if trump { score += tuning.leadTrumpEarly * (1 - p) }
                if card.rank == .ace && !trump && p < 0.6 { score += tuning.leadAceEarly }
                if weighsOdds {
                    let unbeatable = 1 - view.probabilityCanBeat(defender, card)
                    score -= tuning.leadUnbeatable * unbeatable
                    // The defender is nearly out and the deck nearly gone:
                    // lead what they cannot answer.
                    if view.counts[defender] <= 2 && p > 0.7 { score -= 3 * unbeatable }
                }
            } else {
                // No deck: every card shed is a step towards getting out.
                // Lead sets, and cards the defender has to pick up.
                let left = view.counts[defender]
                let nearOut = left <= 2
                // Even without a memory, a player sees that the defender is
                // down to a card or two, and weighs what might beat the lead.
                let beatable = weighsOdds || nearOut ? view.probabilityCanBeat(defender, card) : 0.7
                score = tuning.endLeadCost * Double(view.cost(card)) - tuning.endLeadSet * same
                    - tuning.endLeadUnbeatable * (1 - beatable)
                if nearOut {
                    // A lead the defender beats with their last card lets them
                    // out — heads up, that makes you the durak, whatever the
                    // card was worth. Round a bigger table it only lets one
                    // more escape, so it weighs less.
                    let weight = view.activeCount <= 2 ? (left == 1 ? tuning.endLeadLastCard : tuning.endLeadLastTwo)
                                                       : (left == 1 ? tuning.endLeadLastCardTable : tuning.endLeadLastTwoTable)
                    score += weight * beatable
                }
            }
            scored.append((card, score))
        }
        guard let card = pick(scored, rng: &rng) else { return .pass }
        return .attack(card)
    }

    private func chooseDefence(_ view: DurakBotView, rng: inout DeterministicRNG) -> DurakAction {
        let attacks = view.unbeatenAttacks
        var options: [(DurakAction, Double)] = []

        let cover = difficulty == .easy
            ? Self.greedyCover(attacks, hand: view.hand, trump: view.trump)
            : Self.cheapestCover(attacks, hand: view.hand, trump: view.trump)
        if let cover, let first = cover.pairs.first {
            let weight = view.isEndgame ? tuning.beatWeightEndgame : 1.0
            options.append((.defend(first.defence, on: first.attack), Double(cover.cost) * weight))
        }

        options.append((.take, takeCost(view)))

        if view.variant == .perevodnoy, let target = view.transferTarget, let rank = attacks.first?.rank {
            for card in view.hand where card.rank == rank {
                var score = Double(view.cost(card))
                    - (view.activeCount <= 2 ? tuning.transferBonusHeadsUp : tuning.transferBonus)
                if view.isEndgame { score -= 1 }
                if weighsOdds {
                    // It may come straight back (or on round the table) with
                    // one more card: the other cards of the rank we cannot see.
                    let others = Card.durakDeck.filter { $0.rank == rank && $0 != card && !view.handSet.contains($0) }
                    let back = others.map { view.probabilityHolds(target, $0) }.reduce(0, +)
                    score += tuning.transferRisk * min(1, back)
                }
                options.append((.transfer(card), score))
            }
        }

        let sorted = options.sorted { $0.1 < $1.1 }
        guard let best = sorted.first else { return .take }
        // Easy now and then takes when beating needs a trump, or beats when
        // it might have taken — a person's inconsistency, never a blunder
        // that gives cards away for nothing.
        if noise > 0, sorted.count > 1, abs(sorted[1].1 - best.1) < 2,
           Double(rng.next(upperBound: 1000)) / 1000 < noise {
            return sorted[1].0
        }
        return best.0
    }

    /// What giving up the bout costs, in card-cost units: losing the turn and
    /// carrying the attack cards, cheap early and ruinous once the deck is
    /// gone. Trumps and high cards picked up soften it.
    private func takeCost(_ view: DurakBotView) -> Double {
        let attacks = Double(view.table.count)
        let oversize = Double(max(0, view.hand.count - DurakRules.handSize)) * 0.5
        if view.isEndgame { return tuning.takeEndgame + 5 * attacks + oversize }
        let p = view.progress
        var gains = 0.0
        for pair in view.table {
            let rank = Double(pair.attack.durakRankIndex)
            if view.isTrump(pair.attack) { gains += 2 + 0.3 * rank } else if rank >= 6 { gains += 0.8 }
        }
        return tuning.takeBase + tuning.takeGrowth * p * p + (tuning.takePerCard + tuning.takePerCardGrowth * p) * attacks
            - gains * (1 - p) + oversize
    }

    private func chooseThrowIn(_ view: DurakBotView, pileOn: Bool, rng: inout DeterministicRNG) -> DurakAction {
        let candidates = view.throwInCandidates.sorted {
            view.cost($0) < view.cost($1) || (view.cost($0) == view.cost($1) && $0.durakIndex < $1.durakIndex)
        }
        for card in candidates where shouldThrow(card, view: view, pileOn: pileOn, rng: &rng) {
            return .attack(card)
        }
        return .pass
    }

    private func shouldThrow(_ card: Card, view: DurakBotView, pileOn: Bool, rng: inout DeterministicRNG) -> Bool {
        let rank = Double(card.durakRankIndex)
        let trump = view.isTrump(card)
        if view.isEndgame {
            // Shedding is the whole game now. Trumps go only when the hand is
            // nearly empty or the defender cannot answer them.
            if !trump { return true }
            if view.hand.count <= 2 { return true }
            return weighsOdds && !pileOn && view.probabilityCanBeat(view.defender, card) < tuning.endTrumpOdds
        }
        // Trumps are not given away while the deck lasts.
        if trump { return false }
        if difficulty == .easy {
            let limit = pileOn ? 6.0 : 5.0
            return rank <= limit && rng.next(upperBound: 4) != 0
        }
        let p = view.progress
        var limit = pileOn ? tuning.pileBase + tuning.pileGrowth * p : tuning.throwBase + tuning.throwGrowth * p
        if !pileOn && weighsOdds {
            // A card the defender probably cannot beat is worth throwing even
            // if it is a good one: they pick up the whole table.
            limit += tuning.throwUnbeatable * (1 - view.probabilityCanBeat(view.defender, card))
        }
        return rank <= limit
    }

    // MARK: Covering an attack

    /// The cheapest way to beat every card in `attacks` with distinct cards
    /// from `hand`, by total cost; nil if they cannot all be beaten. Searched
    /// exhaustively, most constrained attack first — at most six attacks, so
    /// this is a few hundred steps at worst.
    static func cheapestCover(_ attacks: [Card], hand: [Card],
                              trump: Suit) -> (pairs: [(attack: Card, defence: Card)], cost: Int)? {
        func cost(_ c: Card) -> Int { c.durakRankIndex + (c.suit == trump ? 9 : 0) }
        let options = attacks.map { attack in
            hand.filter { $0.durakBeats(attack, trump: trump) }.sorted { cost($0) < cost($1) }
        }
        let order = attacks.indices.sorted { options[$0].count < options[$1].count }
        guard order.allSatisfy({ !options[$0].isEmpty }) else { return nil }
        var best: [Card]?
        var bestCost = Int.max
        var chosen = Array(repeating: Card(.spades, .ace), count: attacks.count)
        var used = Set<Card>()
        func search(_ depth: Int, _ total: Int) {
            if total >= bestCost { return }
            if depth == order.count {
                bestCost = total
                best = chosen
                return
            }
            let i = order[depth]
            for card in options[i] where !used.contains(card) {
                used.insert(card)
                chosen[i] = card
                search(depth + 1, total + cost(card))
                used.remove(card)
            }
        }
        search(0, 0)
        guard let best else { return nil }
        return (zip(attacks, best).map { ($0, $1) }, bestCost)
    }

    /// Easy's cover: each attack in turn takes the cheapest beater left.
    static func greedyCover(_ attacks: [Card], hand: [Card],
                            trump: Suit) -> (pairs: [(attack: Card, defence: Card)], cost: Int)? {
        func cost(_ c: Card) -> Int { c.durakRankIndex + (c.suit == trump ? 9 : 0) }
        var left = hand
        var pairs: [(attack: Card, defence: Card)] = []
        var total = 0
        for attack in attacks {
            guard let card = left.filter({ $0.durakBeats(attack, trump: trump) }).min(by: { cost($0) < cost($1) }),
                  let i = left.firstIndex(of: card) else { return nil }
            left.remove(at: i)
            pairs.append((attack, card))
            total += cost(card)
        }
        return (pairs, total)
    }
}
