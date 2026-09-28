//
//  DurakState.swift
//  The rules of durak, podkidnoy and perevodnoy, for two to four players, as
//  one value type: a position, the decisions it allows, and `apply`.
//
//  HOW A BOUT RUNS
//
//  Real durak is played all at once — the defender beats while the others
//  throw in — which no program can ask of a player. So the engine asks one
//  seat at a time, in a fixed order, and `actor` is always exactly that one
//  seat (nil only once the game is over):
//
//    lead      The attacker leads any one card.
//    defend    While any attacking card is unbeaten, the defender acts:
//              beat one card (one action per card), transfer (perevodnoy,
//              before anything is beaten), or take.
//    throwIn   Once everything is beaten, the attackers are asked in
//              priority order — the main attacker, then the others clockwise
//              from the defender's left — and the first who can add a card
//              of a rank on the table is prompted. A card thrown in goes
//              straight to the defender, and when that is beaten the round
//              starts again from the top. "Pass" means "nothing more right
//              now": a seat that passed is asked again only if a rank appears
//              on the table that it could throw in and that was not there
//              when it passed. When nobody is asked, it is bito.
//    pileOn    The defender said "Take": each attacker in the same order may
//              pile on more cards («вдогонку»), one card per action, until
//              they say "Done". Nothing added can bring a new rank, so one
//              pass round the table is enough; then the defender picks up.
//
//  Seats with nothing legal to add are never asked — the round simply moves
//  on — so a player only ever sees a prompt they can do something with.
//
//  LIMITS: at most six attacking cards a bout (five in the first bout of the
//  game), and never more unbeaten attacking cards than the defender holds.
//
//  AFTER THE BOUT everyone draws back up to six, the player who led the bout
//  first, then clockwise, the defender last; the trump card under the deck
//  is the last card drawn. After bito the defender attacks next; after a take
//  the player on the defender's left does. Seats that are out are skipped
//  everywhere. A player with no cards once the deck is gone is out — at that
//  moment, even mid-bout — and the last player holding cards is the durak.
//  If the last cards of the last two players go at once, it is a draw.
//
//  Seats are in play order, clockwise: seat 0 is the human, seat + 1 the
//  player on their left.
//

import Foundation

struct DurakState: Hashable, Sendable {

    // MARK: The deal

    let rules: DurakRules
    /// The seed the deck was shuffled with. The bots derive their own
    /// randomness from it (and `actionCount`), so a restored game plays on
    /// exactly as it would have.
    let seed: UInt64
    /// The card turned up at the deal. It lies under the deck, face up, and is
    /// the last card drawn; its suit is trumps for the whole game.
    let trumpCard: Card
    var trump: Suit { trumpCard.suit }

    // MARK: The position

    /// Every seat's cards, in the order they arrived. Views sort for display.
    private(set) var hands: [[Card]]
    /// The deck: `stock[0]` is the bottom — the trump card, while the deck
    /// lasts — and cards are drawn from the end.
    private(set) var stock: [Card]
    /// Bito: face down, out of the game for good.
    private(set) var discard: [Card]
    /// The bout on the table, attacking cards in the order they were played.
    private(set) var table: [DurakPair]
    /// The main attacker: the player whose attack the defender is facing (in
    /// perevodnoy, whoever transferred last), and first to throw in.
    private(set) var attacker: Int
    private(set) var defender: Int
    /// Who led the bout's first card. The refill starts here.
    private(set) var leader: Int
    private(set) var phase: DurakPhase
    /// The one seat whose decision it is; nil when the game is over.
    private(set) var actor: Int?
    /// 0 for the first bout of the game (the one limited to five cards).
    private(set) var bout: Int
    /// Actions applied since the deal.
    private(set) var actionCount: Int
    /// Bouts in a row that ended in a take. Only bito takes cards out of the
    /// game, so a long run of takes means the same cards are going round the
    /// table; the bots read this to break such a loop (see `DurakBot`).
    private(set) var boutsWithoutBito: Int
    /// Seats in the order they went out.
    private(set) var outOrder: [Int]
    /// What everybody at the table has seen go into each hand and not come
    /// out again: cards picked up in a take, the trump card drawn last, the
    /// lowest trump shown at the opening. Public information — the bots'
    /// memory is built from this and the discard, never from `hands`.
    private(set) var known: [[Card]]
    private(set) var result: DurakResult?
    /// The lowest trump the first attacker showed, when the game opened that
    /// way.
    private(set) var shownTrump: Card?

    /// Throw-in round: for each seat, -1 if it has not passed this bout,
    /// otherwise the ranks on the table (bit 0 the six) when it did.
    private var passedRanks: [Int]
    /// Pile-on round: the seats that said "Done".
    private var doneSeats: [Bool]

    // MARK: - Starting a game

    /// A fresh game: the deck shuffled from `seed`, six cards each, the trump
    /// turned. The events are `dealt`, `opening` and `boutStarted`.
    ///
    /// When the opening is by lowest trump and nobody was dealt a trump at
    /// all (about one deal in fifty with two players), the cards are gathered
    /// and dealt again from the same generator — the usual redeal, and
    /// invisible to the player, since the misdeal is never shown.
    static func newGame(rules: DurakRules, seed: UInt64,
                        opening: DurakOpening = .lowestTrump) -> (state: DurakState, events: [DurakEvent]) {
        var rng = DeterministicRNG(seed: seed)
        var deck = Card.durakDeck
        for _ in 0..<64 {
            rng.shuffle(&deck)
            if let game = deal(rules: rules, deck: deck, seed: seed, opening: opening) { return game }
        }
        // Sixty-four trumpless deals in a row cannot happen; if it somehow
        // did, open with seat 0 rather than loop for ever. A deal "into" a
        // seat never fails on a valid deck.
        guard let game = deal(rules: rules, deck: deck, seed: seed, opening: .intoDurak(1 % rules.playerCount))
        else { preconditionFailure("the durak deck is always dealable") }
        return game
    }

    /// Deals `deck` exactly as given: card i to seat i % players for the
    /// first 6 × players cards, the next one turned up as trumps, the rest
    /// the deck with `deck[6 × players + 1]` on top. Nil when the opening is
    /// by lowest trump and nobody holds one. For tests and screenshots.
    static func deal(rules: DurakRules, deck: [Card], seed: UInt64 = 0,
                     opening: DurakOpening) -> (state: DurakState, events: [DurakEvent])? {
        let n = rules.playerCount
        let dealtCount = DurakRules.handSize * n
        guard deck.count == 36, Set(deck).count == 36, deck.allSatisfy(\.isDurakCard) else { return nil }
        var hands = Array(repeating: [Card](), count: n)
        for i in 0..<dealtCount { hands[i % n].append(deck[i]) }
        let trumpCard = deck[dealtCount]
        let stock = [trumpCard] + deck[(dealtCount + 1)...].reversed()

        var first: Int
        var shown: Card?
        switch opening {
        case .lowestTrump:
            var best: (seat: Int, card: Card)?
            for seat in 0..<n {
                for card in hands[seat] where card.suit == trumpCard.suit {
                    if let lowest = best, lowest.card.durakValue <= card.durakValue { continue }
                    best = (seat, card)
                }
            }
            guard let best else { return nil }
            first = best.seat
            shown = best.card
        case .intoDurak(let durak):
            // The player on the durak's right attacks, so the durak defends.
            first = ((durak % n) - 1 + n) % n
        }

        var state = DurakState(rules: rules, seed: seed, trumpCard: trumpCard, hands: hands, stock: stock,
                               discard: [], attacker: first)
        if let shown {
            state.known[first] = [shown]
            state.shownTrump = shown
        }
        let events: [DurakEvent] = [
            .dealt(hands: hands, trump: trumpCard),
            .opening(attacker: state.attacker, defender: state.defender, shown: shown),
            .boutStarted(attacker: state.attacker, defender: state.defender),
        ]
        return (state, events)
    }

    /// Any position at the start of a bout, for tests, screenshots and the
    /// endgame checks: the given hands and deck (whose first card, if any,
    /// must be `trumpCard`), every other card already in the discard, and
    /// `attacker` to lead. `bout` 0 makes it the five-card first bout. Nil if
    /// the cards do not add up to the deck or the attacker has none.
    static func position(rules: DurakRules, trumpCard: Card, hands: [[Card]], stock: [Card] = [],
                         attacker: Int, bout: Int = 1, known: [[Card]]? = nil,
                         seed: UInt64 = 0) -> DurakState? {
        let n = rules.playerCount
        guard hands.count == n, (0..<n).contains(attacker) else { return nil }
        let held = hands.flatMap { $0 } + stock
        guard held.allSatisfy(\.isDurakCard), Set(held).count == held.count else { return nil }
        guard stock.isEmpty || stock[0] == trumpCard else { return nil }
        let discard = Card.durakDeck.filter { !held.contains($0) }
        var state = DurakState(rules: rules, seed: seed, trumpCard: trumpCard, hands: hands, stock: stock,
                               discard: discard, attacker: attacker)
        guard !state.isOut(attacker), state.nextActive(after: attacker) != nil else { return nil }
        state.bout = bout
        if let known, known.count == n { state.known = known }
        return state
    }

    private init(rules: DurakRules, seed: UInt64, trumpCard: Card, hands: [[Card]], stock: [Card],
                 discard: [Card], attacker: Int) {
        let n = rules.playerCount
        self.rules = rules
        self.seed = seed
        self.trumpCard = trumpCard
        self.hands = hands
        self.stock = stock
        self.discard = discard
        self.table = []
        self.attacker = attacker
        self.leader = attacker
        self.defender = (attacker + 1) % n
        self.phase = .lead
        self.actor = attacker
        self.bout = 0
        self.actionCount = 0
        self.boutsWithoutBito = 0
        self.outOrder = []
        self.known = Array(repeating: [], count: n)
        self.result = nil
        self.shownTrump = nil
        self.passedRanks = Array(repeating: -1, count: n)
        self.doneSeats = Array(repeating: false, count: n)
        self.defender = nextActive(after: attacker) ?? (attacker + 1) % n
    }

    // MARK: - Reading the position

    var playerCount: Int { rules.playerCount }
    var isOver: Bool { phase == .over }
    var stockCount: Int { stock.count }
    /// The trump card still lies under the deck (it goes with the last draw).
    var trumpCardInStock: Bool { !stock.isEmpty }

    /// A seat with no cards once the deck is gone: out of the game, safe.
    func isOut(_ seat: Int) -> Bool { hands[seat].isEmpty && stock.isEmpty }

    /// Seats still playing, in seat order.
    var activeSeats: [Int] { (0..<playerCount).filter { !isOut($0) } }

    /// The next seat clockwise after `seat` that is still playing, or nil if
    /// there is none but `seat` itself.
    func nextActive(after seat: Int) -> Int? {
        var s = (seat + 1) % playerCount
        while s != seat {
            if !isOut(s) { return s }
            s = (s + 1) % playerCount
        }
        return nil
    }

    /// Five in the first bout of the game, six after.
    var attackLimit: Int { bout == 0 ? DurakRules.firstBoutAttacks : DurakRules.maximumAttacks }
    var attackCount: Int { table.count }
    var unbeatenCount: Int { table.reduce(0) { $0 + ($1.isBeaten ? 0 : 1) } }
    /// The attacking cards still waiting to be beaten, in table order.
    var unbeatenAttacks: [Card] { table.filter { !$0.isBeaten }.map(\.attack) }
    /// Every card on the table: each attack followed by its defence.
    var tableCards: [Card] { table.flatMap { [$0.attack] + ($0.defence.map { [$0] } ?? []) } }
    /// The ranks on the table, bit 0 the six.
    var tableRankMask: UInt16 {
        table.reduce(0) { mask, pair in
            mask | 1 << UInt16(pair.attack.durakRankIndex) | (pair.defence.map { 1 << UInt16($0.durakRankIndex) } ?? 0)
        }
    }

    /// How many more attacking cards the bout can take right now.
    var remainingAttackRoom: Int {
        max(0, min(attackLimit - attackCount, hands[defender].count - unbeatenCount))
    }

    /// The throw-in order: the main attacker, then everybody else clockwise
    /// from the defender's left. The defender never throws in.
    var throwInOrder: [Int] {
        var order = [attacker]
        var s = (defender + 1) % playerCount
        while s != defender {
            if s != attacker { order.append(s) }
            s = (s + 1) % playerCount
        }
        return order
    }

    /// The refill order: the bout's leader, then clockwise, the defender last.
    var refillOrder: [Int] {
        (0..<playerCount).map { (leader + $0) % playerCount }.filter { $0 != defender } + [defender]
    }

    /// Cards `seat` could put on the table as an attacker right now, if it were
    /// asked: ranks on the table, within the limits.
    func throwInCandidates(for seat: Int) -> [Card] {
        guard seat != defender, !table.isEmpty, remainingAttackRoom > 0 else { return [] }
        let ranks = tableRankMask
        return hands[seat].filter { ranks & (1 << UInt16($0.durakRankIndex)) != 0 }
    }

    /// Perevodnoy: the seat a transfer would pass the attack to, if the
    /// defender may transfer at all right now — nothing beaten yet, every
    /// attacking card of one rank, room for one more card, and a next player
    /// holding at least as many cards as the attack would then have.
    var transferTarget: Int? {
        guard rules.variant == .perevodnoy, phase == .defend, let first = table.first else { return nil }
        guard table.allSatisfy({ !$0.isBeaten && $0.attack.rank == first.attack.rank }) else { return nil }
        guard attackCount < attackLimit, let target = nextActive(after: defender) else { return nil }
        guard hands[target].count >= attackCount + 1 else { return nil }
        return target
    }

    /// -1 if `seat` has not passed in this bout's throw-in round, otherwise the
    /// ranks that were on the table when it did (bit 0 the six). Public —
    /// everybody heard the pass — and needed by the endgame solver to ask the
    /// same questions the engine will.
    func throwInPassMask(for seat: Int) -> Int { passedRanks[seat] }

    /// The unbeaten attacking cards `card` could beat. For a view deciding
    /// whether a click on `card` is unambiguous.
    func attacks(beatableBy card: Card) -> [Card] {
        table.filter { !$0.isBeaten && card.durakBeats($0.attack, trump: trump) }.map(\.attack)
    }

    // MARK: Decisions

    /// Everything `seat` may do now; empty unless it is `seat`'s decision.
    func legalActions(for seat: Int) -> [DurakAction] {
        guard phase != .over, seat == actor, hands.indices.contains(seat) else { return [] }
        switch phase {
        case .lead:
            return hands[seat].map { .attack($0) }
        case .defend:
            var actions: [DurakAction] = []
            for pair in table where !pair.isBeaten {
                for card in hands[seat] where card.durakBeats(pair.attack, trump: trump) {
                    actions.append(.defend(card, on: pair.attack))
                }
            }
            if transferTarget != nil, let rank = table.first?.attack.rank {
                for card in hands[seat] where card.rank == rank { actions.append(.transfer(card)) }
            }
            actions.append(.take)
            return actions
        case .throwIn, .pileOn:
            return throwInCandidates(for: seat).map { .attack($0) } + [.pass]
        case .over:
            return []
        }
    }

    /// The actions of whoever's decision it is.
    var legalActions: [DurakAction] { actor.map(legalActions(for:)) ?? [] }

    func isLegal(_ action: DurakAction, by seat: Int) -> Bool {
        var copy = self
        return (try? copy.apply(action, by: seat)) != nil
    }

    /// The cards `seat` can play at all right now — what a view lifts.
    func playableCards(for seat: Int) -> [Card] {
        var seen = Set<Card>()
        return legalActions(for: seat).compactMap(\.card).filter { seen.insert($0).inserted }
    }

    /// What a `.pass` by `seat` would mean, or nil if it may not pass.
    func passKind(for seat: Int) -> DurakPassKind? {
        guard seat == actor else { return nil }
        switch phase {
        case .throwIn: return seat == attacker ? .bito : .pass
        case .pileOn: return .done
        default: return nil
        }
    }

    /// `seat`'s part in the bout, for its status word.
    func role(of seat: Int) -> DurakRole {
        if case .durak(let loser)? = result, loser == seat { return .durak }
        if isOut(seat) { return .out }
        if phase == .over { return .idle }
        if seat == defender { return phase == .pileOn ? .taking : .defending }
        if seat == attacker { return .attacking }
        return .idle
    }

    // MARK: - Playing

    /// Applies `seat`'s decision and runs the game forward to the next
    /// decision: the round moving on, bito or the pick-up, the refill, the
    /// next bout, the end. Returns what happened, in order.
    ///
    /// Throws, and leaves the state untouched, if it is not `seat`'s decision
    /// or the action is not legal — a stale click is harmless.
    @discardableResult
    mutating func apply(_ action: DurakAction, by seat: Int) throws -> [DurakEvent] {
        guard phase != .over, seat == actor else { throw DurakError.notYourTurn }
        var events: [DurakEvent] = []

        // Every case checks everything before it changes anything, so a
        // refusal leaves the position exactly as it was.
        switch (phase, action) {
        case (.lead, .attack(let card)):
            guard hands[seat].contains(card) else { throw DurakError.illegal }
            play(card, from: seat)
            table.append(DurakPair(attack: card))
            events.append(.attacked(seat: seat, card: card))
            noteIfOut(seat, &events)
            phase = .defend
            actor = defender

        case (.throwIn, .attack(let card)), (.pileOn, .attack(let card)):
            guard hands[seat].contains(card), remainingAttackRoom > 0,
                  tableRankMask & (1 << UInt16(card.durakRankIndex)) != 0 else { throw DurakError.illegal }
            play(card, from: seat)
            table.append(DurakPair(attack: card))
            passedRanks[seat] = -1
            events.append(.threwIn(seat: seat, card: card))
            noteIfOut(seat, &events)
            if phase == .throwIn {
                phase = .defend
                actor = defender
            } else {
                advancePileOn(&events)
            }

        case (.defend, .defend(let card, let attack)):
            guard hands[seat].contains(card), card.durakBeats(attack, trump: trump),
                  let index = table.firstIndex(where: { $0.attack == attack && !$0.isBeaten })
            else { throw DurakError.illegal }
            play(card, from: seat)
            table[index].defence = card
            events.append(.beat(seat: seat, card: card, attack: attack))
            noteIfOut(seat, &events)
            if unbeatenCount > 0 {
                actor = defender
            } else {
                openThrowIn(&events)
            }

        case (.defend, .transfer(let card)):
            guard let target = transferTarget, hands[seat].contains(card),
                  card.rank == table.first?.attack.rank else { throw DurakError.illegal }
            play(card, from: seat)
            table.append(DurakPair(attack: card))
            events.append(.transferred(seat: seat, card: card, to: target))
            noteIfOut(seat, &events)
            attacker = seat
            defender = target
            actor = target

        case (.defend, .take):
            phase = .pileOn
            doneSeats = Array(repeating: false, count: playerCount)
            events.append(.takes(seat: seat))
            advancePileOn(&events)

        case (.throwIn, .pass):
            passedRanks[seat] = Int(tableRankMask)
            events.append(.passed(seat: seat))
            openThrowIn(&events)

        case (.pileOn, .pass):
            doneSeats[seat] = true
            events.append(.passed(seat: seat))
            advancePileOn(&events)

        default:
            throw DurakError.illegal
        }
        actionCount += 1
        return events
    }

    private mutating func play(_ card: Card, from seat: Int) {
        if let i = hands[seat].firstIndex(of: card) { hands[seat].remove(at: i) }
        if let i = known[seat].firstIndex(of: card) { known[seat].remove(at: i) }
    }

    private mutating func noteIfOut(_ seat: Int, _ events: inout [DurakEvent]) {
        guard isOut(seat), !outOrder.contains(seat) else { return }
        outOrder.append(seat)
        events.append(.playerOut(seat: seat, place: outOrder.count))
    }

    /// Everything is beaten: prompt the first attacker who can add something
    /// they have not already declined, or call it bito.
    private mutating func openThrowIn(_ events: inout [DurakEvent]) {
        for seat in throwInOrder {
            let cards = throwInCandidates(for: seat)
            guard !cards.isEmpty else { continue }
            let passed = passedRanks[seat]
            if passed >= 0 && !cards.contains(where: { passed & (1 << $0.durakRankIndex) == 0 }) { continue }
            phase = .throwIn
            actor = seat
            return
        }
        let cards = tableCards
        discard += cards
        table.removeAll()
        boutsWithoutBito = 0
        events.append(.bito(cards: cards))
        finishBout(took: false, &events)
    }

    /// The defender is taking: prompt the next attacker who is not done and
    /// can still add a card, or hand the defender the table.
    private mutating func advancePileOn(_ events: inout [DurakEvent]) {
        for seat in throwInOrder where !doneSeats[seat] && !throwInCandidates(for: seat).isEmpty {
            phase = .pileOn
            actor = seat
            return
        }
        let cards = tableCards
        hands[defender] += cards
        known[defender] += cards
        table.removeAll()
        boutsWithoutBito += 1
        events.append(.took(seat: defender, cards: cards))
        finishBout(took: true, &events)
    }

    private mutating func finishBout(took: Bool, _ events: inout [DurakEvent]) {
        let order = refillOrder
        for seat in order where !stock.isEmpty && hands[seat].count < DurakRules.handSize {
            let count = min(DurakRules.handSize - hands[seat].count, stock.count)
            var drawn: [Card] = []
            for _ in 0..<count {
                if let card = stock.popLast() { drawn.append(card) }
            }
            hands[seat] += drawn
            // The trump card was lying face up: everyone saw who got it.
            if drawn.contains(trumpCard) { known[seat].append(trumpCard) }
            events.append(.drew(seat: seat, cards: drawn))
        }
        // Anyone the deck ran out on before their turn to draw is out now.
        for seat in order { noteIfOut(seat, &events) }

        let active = activeSeats
        if active.count <= 1 {
            let result: DurakResult = active.first.map { .durak($0) } ?? .draw
            self.result = result
            phase = .over
            actor = nil
            events.append(.gameOver(result))
            return
        }
        // Bito: the defender attacks next (or, if they are out, the next
        // player on). A take: the defender loses the turn to their left.
        let next: Int
        if took || isOut(defender) {
            next = nextActive(after: defender) ?? active[0]
        } else {
            next = defender
        }
        attacker = next
        leader = next
        defender = nextActive(after: next) ?? active[active[0] == next ? 1 : 0]
        phase = .lead
        actor = next
        bout += 1
        passedRanks = Array(repeating: -1, count: playerCount)
        doneSeats = Array(repeating: false, count: playerCount)
        events.append(.boutStarted(attacker: attacker, defender: defender))
    }

    // MARK: - Positions a seat cannot tell apart

    /// This position with `a` and `b` swapped between wherever they are — for
    /// the self-test that proves a bot never peeks: `seat` must not be able
    /// to tell the two positions apart, so each card must be in another
    /// seat's hand without anyone having seen it go in, or in the deck (but
    /// not the face-up trump card under it). Nil if either is visible to
    /// `seat`.
    func exchangingUnseen(_ a: Card, _ b: Card, from seat: Int) -> DurakState? {
        func location(_ card: Card) -> (seat: Int?, index: Int)? {
            for s in 0..<playerCount where s != seat {
                if let i = hands[s].firstIndex(of: card), !known[s].contains(card) { return (s, i) }
            }
            if let i = stock.firstIndex(of: card), i > 0 { return (nil, i) }
            return nil
        }
        guard a != b, let la = location(a), let lb = location(b) else { return nil }
        var copy = self
        func put(_ card: Card, at place: (seat: Int?, index: Int)) {
            if let s = place.seat { copy.hands[s][place.index] = card } else { copy.stock[place.index] = card }
        }
        put(b, at: la)
        put(a, at: lb)
        return copy
    }

    // MARK: - Checking

    /// Every card accounted for exactly once and the table obeying the rules.
    /// A restored game that fails this is thrown away rather than played.
    var isConsistent: Bool {
        let n = playerCount
        guard (2...4).contains(n), hands.count == n, known.count == n,
              passedRanks.count == n, doneSeats.count == n else { return false }
        let all = hands.flatMap { $0 } + stock + discard + tableCards
        guard all.count == 36, Set(all).count == 36, all.allSatisfy(\.isDurakCard) else { return false }
        guard stock.isEmpty || stock[0] == trumpCard else { return false }
        for pair in table {
            if let defence = pair.defence, !defence.durakBeats(pair.attack, trump: trump) { return false }
        }
        for seat in 0..<n where !known[seat].allSatisfy(hands[seat].contains) { return false }
        guard (0..<n).contains(attacker), (0..<n).contains(defender), (0..<n).contains(leader),
              attacker != defender else { return false }
        switch phase {
        case .over:
            return actor == nil && result != nil && table.isEmpty
        case .lead:
            return actor == attacker && table.isEmpty && !isOut(attacker)
        case .defend:
            return actor == defender && unbeatenCount > 0 && table.count <= attackLimit
                && unbeatenCount <= hands[defender].count
        case .throwIn:
            guard let actor else { return false }
            return actor != defender && unbeatenCount == 0 && !table.isEmpty
        case .pileOn:
            guard let actor else { return false }
            return actor != defender && !table.isEmpty && table.count <= attackLimit
                && unbeatenCount <= hands[defender].count
        }
    }
}

// MARK: - Saving

extension DurakState: Codable {

    private enum CodingKeys: String, CodingKey {
        case rules, seed, trumpCard, hands, stock, discard, table, attacker, defender, leader, phase, actor
        case bout, actionCount, boutsWithoutBito, outOrder, known, result, shownTrump, passedRanks, doneSeats
    }

    /// The position itself must all be there; the bookkeeping around it falls
    /// back to "nothing happened yet" key by key, so a save from an older
    /// build still resumes. Whatever decodes is then checked card by card.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decode(DurakRules.self, forKey: .rules)
        let n = rules.playerCount
        seed = ((try? c.decodeIfPresent(UInt64.self, forKey: .seed)) ?? nil) ?? 0
        trumpCard = try c.decode(Card.self, forKey: .trumpCard)
        hands = try c.decode([[Card]].self, forKey: .hands)
        stock = try c.decode([Card].self, forKey: .stock)
        discard = try c.decode([Card].self, forKey: .discard)
        table = try c.decode([DurakPair].self, forKey: .table)
        attacker = try c.decode(Int.self, forKey: .attacker)
        defender = try c.decode(Int.self, forKey: .defender)
        phase = try c.decode(DurakPhase.self, forKey: .phase)
        actor = try c.decodeIfPresent(Int.self, forKey: .actor)
        leader = ((try? c.decodeIfPresent(Int.self, forKey: .leader)) ?? nil) ?? attacker
        bout = ((try? c.decodeIfPresent(Int.self, forKey: .bout)) ?? nil) ?? 1
        actionCount = ((try? c.decodeIfPresent(Int.self, forKey: .actionCount)) ?? nil) ?? 0
        boutsWithoutBito = ((try? c.decodeIfPresent(Int.self, forKey: .boutsWithoutBito)) ?? nil) ?? 0
        outOrder = ((try? c.decodeIfPresent([Int].self, forKey: .outOrder)) ?? nil) ?? []
        known = ((try? c.decodeIfPresent([[Card]].self, forKey: .known)) ?? nil) ?? Array(repeating: [], count: n)
        result = (try? c.decodeIfPresent(DurakResult.self, forKey: .result)) ?? nil
        shownTrump = (try? c.decodeIfPresent(Card.self, forKey: .shownTrump)) ?? nil
        passedRanks = ((try? c.decodeIfPresent([Int].self, forKey: .passedRanks)) ?? nil)
            ?? Array(repeating: -1, count: n)
        doneSeats = ((try? c.decodeIfPresent([Bool].self, forKey: .doneSeats)) ?? nil)
            ?? Array(repeating: false, count: n)
        if known.count != n || !(0..<n).allSatisfy({ known[$0].allSatisfy(hands[$0].contains) }) {
            known = Array(repeating: [], count: n)
        }
        guard isConsistent else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "inconsistent durak position"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rules, forKey: .rules)
        try c.encode(seed, forKey: .seed)
        try c.encode(trumpCard, forKey: .trumpCard)
        try c.encode(hands, forKey: .hands)
        try c.encode(stock, forKey: .stock)
        try c.encode(discard, forKey: .discard)
        try c.encode(table, forKey: .table)
        try c.encode(attacker, forKey: .attacker)
        try c.encode(defender, forKey: .defender)
        try c.encode(leader, forKey: .leader)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(actor, forKey: .actor)
        try c.encode(bout, forKey: .bout)
        try c.encode(actionCount, forKey: .actionCount)
        try c.encode(boutsWithoutBito, forKey: .boutsWithoutBito)
        try c.encode(outOrder, forKey: .outOrder)
        try c.encode(known, forKey: .known)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(shownTrump, forKey: .shownTrump)
        try c.encode(passedRanks, forKey: .passedRanks)
        try c.encode(doneSeats, forKey: .doneSeats)
    }
}
