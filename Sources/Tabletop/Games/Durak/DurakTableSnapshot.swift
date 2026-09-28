//
//  DurakTableSnapshot.swift
//  The table as the player can see it at this instant — which may be a few
//  events behind the engine.
//
//  One action can do a lot at once: the defender beats the last card, the
//  table goes to bito, four players draw, the next bout starts. The engine
//  returns all of it as a list of events and is already at the end of the
//  list; the view shows the events one after another. This is what it lays
//  the cards out from in between: a mirror of the position that the events
//  are applied to one at a time, exactly as the engine's own event-replay
//  test does, and that equals the engine's position again once the last one
//  has been shown. (`matches(_:)` checks that; the view falls back to the
//  engine's position if it ever did not.)
//

import AppKit

struct DurakTableSnapshot: Equatable {

    var playerCount: Int
    /// Every seat's cards, in the order they arrived; the view sorts the
    /// player's for display.
    var hands: [[Card]]
    /// The deck, bottom first — `stock[0]` is the trump card once it has been
    /// turned — drawn from the end.
    var stock: [Card]
    /// False before the deal has turned the trump: the whole deck is face
    /// down, the trump card still somewhere inside it.
    var trumpTurned: Bool
    var trumpCard: Card?
    var table: [DurakPair]
    /// Bito, in the order it went.
    var discard: [Card]
    var attacker: Int
    var defender: Int
    /// The defender, once they have said "Take": the others are piling on.
    var takingSeat: Int?
    var outOrder: [Int]
    var result: DurakResult?

    /// The position at rest.
    init(state: DurakState) {
        playerCount = state.playerCount
        hands = state.hands
        stock = state.stock
        trumpTurned = true
        trumpCard = state.trumpCard
        table = state.table
        discard = state.discard
        attacker = state.attacker
        defender = state.defender
        takingSeat = state.phase == .pileOn ? state.defender : nil
        outOrder = state.outOrder
        result = state.result
    }

    /// A table before any deal: the whole deck squared up, face down.
    init(emptyTable playerCount: Int) {
        self.playerCount = playerCount
        hands = Array(repeating: [], count: playerCount)
        stock = Card.durakDeck
        trumpTurned = false
        trumpCard = nil
        table = []
        discard = []
        attacker = 0
        defender = 1 % max(playerCount, 1)
        takingSeat = nil
        outOrder = []
        result = nil
    }

    /// The moment before `dealt`: every card in the deck, the ones about to
    /// be dealt on top in the order they will leave it, then the trump card,
    /// then the rest — so the deal takes each card off the top.
    init(beforeDealing hands: [[Card]], trump: Card, stockAfter: [Card]) {
        playerCount = hands.count
        var order: [Card] = []
        let longest = hands.map(\.count).max() ?? 0
        for i in 0..<longest {
            for seat in hands.indices where i < hands[seat].count { order.append(hands[seat][i]) }
        }
        // Bottom first: the deck left after the deal, the trump card, then
        // the dealt cards with the first one dealt on top.
        stock = Array(stockAfter.dropFirst()) + [trump] + order.reversed()
        self.hands = Array(repeating: [], count: hands.count)
        trumpTurned = false
        trumpCard = trump
        table = []
        discard = []
        attacker = 0
        defender = 1 % max(hands.count, 1)
        takingSeat = nil
        outOrder = []
        result = nil
    }

    // MARK: Reading

    /// The cards lying face down on the deck (the turned trump excluded).
    var deckCards: [Card] { trumpTurned ? Array(stock.dropFirst()) : stock }

    /// The turned trump, while it is still under the deck.
    var trumpUnderDeck: Card? { trumpTurned ? stock.first : nil }

    var unbeatenCount: Int { table.reduce(0) { $0 + ($1.isBeaten ? 0 : 1) } }

    func isOut(_ seat: Int) -> Bool { outOrder.contains(seat) }

    /// Where `card` is, as far as the view is concerned.
    func seat(holding card: Card) -> Int? {
        hands.firstIndex { $0.contains(card) }
    }

    /// Whether the snapshot shows exactly the engine's position.
    func matches(_ state: DurakState) -> Bool {
        playerCount == state.playerCount && trumpTurned && trumpCard == state.trumpCard
            && stock == state.stock && table == state.table && Set(discard) == Set(state.discard)
            && hands.map { Set($0) } == state.hands.map { Set($0) }
            && attacker == state.attacker && defender == state.defender
            && outOrder == state.outOrder && result == state.result
    }

    // MARK: Applying events

    /// Moves the table on by one event. Events that are not about cards
    /// (`passed`, `opening`) only change who is who.
    mutating func apply(_ event: DurakEvent) {
        switch event {
        case .dealt(let dealt, let trump):
            // The deal takes the top cards in round order; whatever the deck
            // held before, it now holds what is left under the turned trump.
            let dealtSet = Set(dealt.flatMap { $0 })
            let rest = stock.filter { !dealtSet.contains($0) && $0 != trump }
            hands = dealt
            stock = [trump] + rest
            trumpCard = trump
            trumpTurned = true
        case .opening(let a, let d, _), .boutStarted(let a, let d):
            attacker = a
            defender = d
            takingSeat = nil
        case .attacked(let seat, let card), .threwIn(let seat, let card):
            remove(card, from: seat)
            table.append(DurakPair(attack: card))
        case .beat(let seat, let card, let attack):
            remove(card, from: seat)
            if let i = table.firstIndex(where: { $0.attack == attack && !$0.isBeaten }) { table[i].defence = card }
        case .transferred(let seat, let card, let to):
            remove(card, from: seat)
            table.append(DurakPair(attack: card))
            attacker = seat
            defender = to
        case .takes(let seat):
            takingSeat = seat
        case .passed:
            break
        case .took(let seat, let cards):
            if hands.indices.contains(seat) { hands[seat] += cards }
            table.removeAll()
            takingSeat = nil
        case .bito(let cards):
            discard += cards
            table.removeAll()
        case .drew(let seat, let cards):
            let drawn = Set(cards)
            stock.removeAll { drawn.contains($0) }
            if hands.indices.contains(seat) { hands[seat] += cards }
        case .playerOut(let seat, _):
            if !outOrder.contains(seat) { outOrder.append(seat) }
        case .gameOver(let result):
            self.result = result
            takingSeat = nil
        }
    }

    private mutating func remove(_ card: Card, from seat: Int) {
        guard hands.indices.contains(seat), let i = hands[seat].firstIndex(of: card) else { return }
        hands[seat].remove(at: i)
    }

    /// What a `.passed` by `seat` said, for the word by their seat: "Done"
    /// while a defender is taking, "Pass" otherwise. (Bito is announced when
    /// it happens, not when the first attacker passes: the others may still
    /// throw in.)
    func passWord(for seat: Int) -> DurakPassKind {
        takingSeat != nil ? .done : .pass
    }
}

extension Suit {
    /// The suit in its own colour on dark glass — a card's red, lifted a
    /// little to read there, or white — for the trump pill and the toast
    /// that names the lowest trump.
    @MainActor var durakTint: NSColor { isRed ? DurakTrumpPill.red : Palette.textPrimary }

    /// The suit's SF Symbol, for pills and toasts.
    var durakSymbolName: String {
        switch self {
        case .clubs: return "suit.club.fill"
        case .diamonds: return "suit.diamond.fill"
        case .hearts: return "suit.heart.fill"
        case .spades: return "suit.spade.fill"
        }
    }
}
