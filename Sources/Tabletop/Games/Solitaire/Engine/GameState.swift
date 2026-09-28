//
//  GameState.swift
//  The rules of Klondike, and nothing else.
//
//  This type knows how to deal, what moves are legal, how to apply one and how
//  to take it back. It deliberately knows nothing about score, time, animation
//  or AppKit: the solver runs thousands of copies of it per second on a
//  background thread, and `Game` layers the presentation concerns on top.
//

import Foundation

// MARK: - Piles

enum PileKind: UInt8, Hashable, Codable, Sendable {
    case stock, waste, foundation, tableau
}

/// Addresses a pile on the table. `index` is the foundation (0...3) or tableau
/// column (0...6); it is 0 and ignored for the stock and waste.
struct PileID: Hashable, Codable, Sendable {
    var kind: PileKind
    var index: Int

    init(_ kind: PileKind, _ index: Int = 0) {
        self.kind = kind
        self.index = index
    }

    static let stock = PileID(.stock)
    static let waste = PileID(.waste)
    static func foundation(_ i: Int) -> PileID { PileID(.foundation, i) }
    static func tableau(_ i: Int) -> PileID { PileID(.tableau, i) }
}

/// One of the seven columns: a face-down packet with a face-up run on top.
struct TableauColumn: Hashable, Codable, Sendable {
    var down: [Card] = []
    var up: [Card] = []

    var isEmpty: Bool { down.isEmpty && up.isEmpty }
    var count: Int { down.count + up.count }
    var topCard: Card? { up.last }

    /// The card at `index` counting from the bottom of the whole column.
    func card(at index: Int) -> Card {
        index < down.count ? down[index] : up[index - down.count]
    }
}

// MARK: - Moves

/// Every move a player can make. Deliberately small and value-typed so the
/// solver can enumerate and compare them without allocating.
enum Move: Hashable, Codable, Sendable {
    /// Turn `count` cards from the stock onto the waste (1 or 3, or fewer if
    /// the stock is nearly empty).
    case draw(count: Int)
    /// Turn the waste back over to re-form the stock.
    case recycle
    case wasteToFoundation
    case wasteToTableau(column: Int)
    case tableauToFoundation(column: Int)
    case tableauToTableau(from: Int, to: Int, count: Int)
    case foundationToTableau(suit: Suit, column: Int)

    /// Where the moving card(s) come from.
    var source: PileID {
        switch self {
        case .draw, .recycle: return .stock
        case .wasteToFoundation, .wasteToTableau: return .waste
        case .tableauToFoundation(let c): return .tableau(c)
        case .tableauToTableau(let f, _, _): return .tableau(f)
        case .foundationToTableau(let s, _): return .foundation(Int(s.rawValue))
        }
    }

    /// Where they are going.
    ///
    /// Takes the state because a move to a foundation does not name which one —
    /// that is decided by the suit of the card on top of the source pile. An
    /// earlier version of this returned foundation 0 for every such move, which
    /// would have sent every ace to the clubs pile.
    func destination(in state: GameState) -> PileID {
        switch self {
        case .draw: return .waste
        case .recycle: return .stock
        case .wasteToFoundation:
            return .foundation(state.waste.last?.foundationIndex ?? 0)
        case .wasteToTableau(let c): return .tableau(c)
        case .tableauToFoundation(let column):
            return .foundation(state.tableau[column].topCard?.foundationIndex ?? 0)
        case .tableauToTableau(_, let t, _): return .tableau(t)
        case .foundationToTableau(_, let c): return .tableau(c)
        }
    }

    /// True for moves that only shuffle the stock around. Used to tell a
    /// "real" move from housekeeping when detecting a dead game.
    var isStockCycling: Bool {
        switch self {
        case .draw, .recycle: return true
        default: return false
        }
    }
}

/// Everything needed to take a move back exactly, including the incidental
/// state changes it caused. Undo in this game is expected to be perfect —
/// players use it to explore — so nothing may be reconstructed by guesswork.
struct MoveRecord: Hashable, Codable, Sendable {
    var move: Move
    /// The card that moved, for single-card moves. Undo needs it to know which
    /// foundation to take a card back off; deriving it by scanning the four
    /// foundations is ambiguous the moment two of them share a top rank.
    var movedCard: Card?
    /// The source column turned a face-down card face up as a side effect.
    var flippedSourceCard: Bool
    var previousWasteFan: Int
    var previousRedealsUsed: Int
}

// MARK: - Game state

struct GameState: Hashable, Codable, Sendable {

    // Cards, top of each packet is the *last* element throughout.
    var stock: [Card] = []
    var waste: [Card] = []
    /// Top rank reached on each foundation, indexed by `Suit.rawValue`.
    /// `0` means empty, `13` means complete.
    var foundations: [UInt8] = [0, 0, 0, 0]
    var tableau: [TableauColumn] = Array(repeating: TableauColumn(), count: 7)

    /// How many of the waste's top cards are fanned out for the player.
    /// In draw-3 this is 3 after a draw and shrinks as those cards are played.
    var wasteFan: Int = 0

    var redealsUsed: Int = 0

    // Rules that vary by preference.
    var drawCount: Int = 1
    /// `nil` means unlimited passes through the stock.
    var redealLimit: Int?

    // MARK: Derived

    var isWon: Bool { foundations.allSatisfy { $0 == 13 } }

    var foundationCardCount: Int { foundations.reduce(0) { $0 + Int($1) } }

    /// The card sitting on top of foundation `i`, if any.
    func foundationTop(_ i: Int) -> Card? {
        let r = foundations[i]
        guard r > 0 else { return nil }
        return Card(Suit(rawValue: UInt8(i))!, Rank(rawValue: r)!)
    }

    /// Whether the deal still allows turning the waste back over, ignoring
    /// whether the cards happen to be in the right place right now.
    var hasRedealsRemaining: Bool {
        guard let limit = redealLimit else { return true }
        return redealsUsed < limit
    }

    var canRecycle: Bool {
        !waste.isEmpty && stock.isEmpty && hasRedealsRemaining
    }

    /// True once the game is decided and finishing it is pure clicking.
    ///
    /// The strict case is everything face up with the stock and waste empty.
    /// Draw-one with unlimited passes also qualifies, because every remaining
    /// card is guaranteed to reach the top of the waste — but note the `&&`:
    /// an earlier `||` here let draw-three qualify, and the auto-finish loop
    /// would then cycle the stock forever without ever playing a card.
    var canAutoFinish: Bool {
        guard !isWon else { return false }
        guard tableau.allSatisfy({ $0.down.isEmpty }) else { return false }
        if stock.isEmpty && waste.isEmpty { return true }
        return drawCount == 1 && redealLimit == nil
    }

    // MARK: Legality

    func isLegal(_ move: Move) -> Bool {
        switch move {
        case .draw(let n):
            // Asking for three with two left is legal; it draws two, and the
            // record then says `draw(2)` — which redo has to be able to replay,
            // so the bound is a range rather than the two configured values.
            // The point of the bound is only to stop a corrupt save dealing
            // seven cards at once.
            return !stock.isEmpty && n >= 1 && n <= 3

        case .recycle:
            return canRecycle

        case .wasteToFoundation:
            guard let card = waste.last else { return false }
            return card.value == Int(foundations[card.foundationIndex]) + 1

        case .wasteToTableau(let column):
            guard let card = waste.last, tableau.indices.contains(column) else { return false }
            return canPlace(card, onColumn: column)

        case .tableauToFoundation(let column):
            guard tableau.indices.contains(column), let card = tableau[column].topCard else { return false }
            return card.value == Int(foundations[card.foundationIndex]) + 1

        case .tableauToTableau(let from, let to, let count):
            guard from != to,
                  tableau.indices.contains(from), tableau.indices.contains(to),
                  count > 0, count <= tableau[from].up.count
            else { return false }
            let card = tableau[from].up[tableau[from].up.count - count]
            // A whole column headed by a king may move to an empty one. It wins
            // nothing by itself, but players rearrange the table for room and
            // for tidiness, and refusing the move only feels like a bug.
            return canPlace(card, onColumn: to)

        case .foundationToTableau(let suit, let column):
            let i = Int(suit.rawValue)
            guard foundations[i] > 0, tableau.indices.contains(column) else { return false }
            let card = Card(suit, Rank(rawValue: foundations[i])!)
            return canPlace(card, onColumn: column)
        }
    }

    /// Klondike's tableau rule: an empty column takes a king, anything else
    /// takes the next lower rank in the opposite colour.
    func canPlace(_ card: Card, onColumn column: Int) -> Bool {
        guard let top = tableau[column].topCard else { return card.rank == .king }
        return card.canStack(onTableau: top)
    }

    func canPlaceOnFoundation(_ card: Card) -> Bool {
        card.value == Int(foundations[card.foundationIndex]) + 1
    }

    // MARK: Applying and undoing

    /// Applies `move` and returns the record needed to undo it, or `nil` if the
    /// move was not legal. The state is untouched on failure.
    @discardableResult
    mutating func apply(_ move: Move) -> MoveRecord? {
        guard isLegal(move) else { return nil }
        var record = MoveRecord(
            move: move,
            movedCard: nil,
            flippedSourceCard: false,
            previousWasteFan: wasteFan,
            previousRedealsUsed: redealsUsed
        )

        switch move {
        case .draw(let n):
            let actual = min(n, stock.count)
            for _ in 0..<actual { waste.append(stock.removeLast()) }
            wasteFan = actual
            // The record must carry the count that actually moved, not the
            // count that was asked for, or undo at the end of the stock breaks.
            record.move = .draw(count: actual)

        case .recycle:
            stock = waste.reversed()
            waste.removeAll(keepingCapacity: true)
            wasteFan = 0
            redealsUsed += 1

        case .wasteToFoundation:
            let card = waste.removeLast()
            foundations[card.foundationIndex] = card.rank.rawValue
            record.movedCard = card
            shrinkWasteFan()

        case .wasteToTableau(let column):
            let card = waste.removeLast()
            tableau[column].up.append(card)
            record.movedCard = card
            shrinkWasteFan()

        case .tableauToFoundation(let column):
            let card = tableau[column].up.removeLast()
            foundations[card.foundationIndex] = card.rank.rawValue
            record.movedCard = card
            record.flippedSourceCard = flipIfNeeded(column)

        case .tableauToTableau(let from, let to, let count):
            let moved = tableau[from].up.suffix(count)
            tableau[from].up.removeLast(count)
            tableau[to].up.append(contentsOf: moved)
            record.flippedSourceCard = flipIfNeeded(from)

        case .foundationToTableau(let suit, let column):
            let i = Int(suit.rawValue)
            let card = Card(suit, Rank(rawValue: foundations[i])!)
            foundations[i] -= 1
            tableau[column].up.append(card)
            record.movedCard = card
        }

        return record
    }

    /// Exactly reverses `apply`.
    mutating func undo(_ record: MoveRecord) {
        switch record.move {
        case .draw(let n):
            for _ in 0..<n { stock.append(waste.removeLast()) }

        case .recycle:
            waste = stock.reversed()
            stock.removeAll(keepingCapacity: true)

        case .wasteToFoundation:
            guard let card = record.movedCard else { break }
            foundations[card.foundationIndex] = card.rank.rawValue - 1
            waste.append(card)

        case .wasteToTableau(let column):
            waste.append(tableau[column].up.removeLast())

        case .tableauToFoundation(let column):
            if record.flippedSourceCard { unflip(column) }
            guard let card = record.movedCard else { break }
            foundations[card.foundationIndex] = card.rank.rawValue - 1
            tableau[column].up.append(card)

        case .tableauToTableau(let from, let to, let count):
            if record.flippedSourceCard { unflip(from) }
            let moved = tableau[to].up.suffix(count)
            tableau[to].up.removeLast(count)
            tableau[from].up.append(contentsOf: moved)

        case .foundationToTableau(let suit, let column):
            let card = tableau[column].up.removeLast()
            foundations[Int(suit.rawValue)] = card.rank.rawValue
        }

        wasteFan = record.previousWasteFan
        redealsUsed = record.previousRedealsUsed
    }

    // MARK: Helpers

    private mutating func shrinkWasteFan() {
        wasteFan = waste.isEmpty ? 0 : max(1, min(wasteFan - 1, waste.count))
    }

    /// Turns the newly exposed card face up, as Klondike always does
    /// automatically. Returns whether anything flipped.
    private mutating func flipIfNeeded(_ column: Int) -> Bool {
        guard tableau[column].up.isEmpty, !tableau[column].down.isEmpty else { return false }
        tableau[column].up.append(tableau[column].down.removeLast())
        return true
    }

    private mutating func unflip(_ column: Int) {
        guard let card = tableau[column].up.popLast() else { return }
        tableau[column].down.append(card)
    }
}
