//
//  DurakTypes.swift
//  The vocabulary of the rules engine: the game's options, the decisions a
//  player can make, and the events a view animates.
//
//  FOR THE LOCALISER — the Russian names of the game's terms, which the
//  English source strings stand in for:
//
//      Durak           «Дурак»          the loser, the fool
//      Podkidnoy       «Подкидной»      the variant with throw-ins
//      Perevodnoy      «Переводной»     the variant with transfers
//      Take            «Беру»           the defender picks the cards up
//      Bito            «Бито»           every attack beaten, cards discarded
//      Pass            «Пас»            nothing to add right now
//      Trump           «Козырь»
//      Transfer        «Перевести»
//      Draw            «Ничья»
//

import Foundation

/// Which durak is being played.
enum DurakVariant: String, Codable, CaseIterable, Sendable {
    /// «Подкидной»: the defender beats or takes; everyone else may throw in
    /// cards of the ranks on the table.
    case podkidnoy
    /// «Переводной»: podkidnoy, plus the defender may pass the attack on to
    /// the next player by adding a card of the same rank before beating
    /// anything.
    case perevodnoy

    var localizedName: String {
        switch self {
        case .podkidnoy: return NSLocalizedString("Podkidnoy", comment: "durak variant with throw-ins («Подкидной»)")
        case .perevodnoy: return NSLocalizedString("Perevodnoy", comment: "durak variant with transfers («Переводной»)")
        }
    }
}

/// The options a game is dealt with.
///
/// Seats are numbered in PLAY ORDER, which is clockwise round the table:
/// seat 0 is the human, seat 1 the player on their left (the one they
/// attack), and so on. The next seat is always "the player to the left".
/// How the seats map to the screen is the view's business.
struct DurakRules: Codable, Hashable, Sendable {
    /// 2...4: the human plus one to three computer players.
    var playerCount: Int
    var variant: DurakVariant

    init(playerCount: Int, variant: DurakVariant = .podkidnoy) {
        self.playerCount = min(max(playerCount, 2), 4)
        self.variant = variant
    }

    private enum CodingKeys: String, CodingKey { case playerCount, variant }

    /// A saved game's rules are the game: a count outside 2...4 is damage,
    /// not something to round to the nearest table, so it refuses — and the
    /// position it came with is dropped rather than played to other rules.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let count = try c.decode(Int.self, forKey: .playerCount)
        guard (2...4).contains(count) else {
            throw DecodingError.dataCorruptedError(forKey: .playerCount, in: c, debugDescription: "2 to 4 players")
        }
        self.init(playerCount: count, variant: try c.decode(DurakVariant.self, forKey: .variant))
    }

    /// Everybody refills to six after each bout while the deck lasts.
    static let handSize = 6
    /// No bout may hold more than six attacking cards...
    static let maximumAttacks = 6
    /// ...and the very first bout of a game no more than five.
    static let firstBoutAttacks = 5
}

/// Who attacks first.
enum DurakOpening: Codable, Hashable, Sendable {
    /// The player holding the lowest trump leads, and shows it. The first
    /// game of a session, and the game after a draw.
    case lowestTrump
    /// «Под дурака»: the previous game's durak (a seat) defends the first
    /// bout, so the player on their right attacks.
    case intoDurak(Int)

    /// The opening that follows a finished game, by the courtyard custom.
    static func following(_ previous: DurakResult?, playerCount: Int) -> DurakOpening {
        if case .durak(let seat)? = previous, (0..<playerCount).contains(seat) { return .intoDurak(seat) }
        return .lowestTrump
    }
}

/// One attacking card and, once it has been beaten, the card that beat it.
struct DurakPair: Codable, Hashable, Sendable {
    var attack: Card
    var defence: Card?

    var isBeaten: Bool { defence != nil }
}

/// What the player whose decision it is has been asked to do.
enum DurakPhase: String, Codable, Sendable {
    /// The table is empty: the attacker leads one card.
    case lead
    /// There is at least one unbeaten card: the defender beats one, transfers
    /// (perevodnoy) or takes.
    case defend
    /// Everything on the table is beaten: the prompted attacker may throw in
    /// a card of a rank on the table, or pass. When nobody adds, it is bito.
    case throwIn
    /// The defender has said "Take": the prompted attacker may pile on more
    /// cards of the ranks on the table («вдогонку»), or say they are done.
    /// When everybody is done, the defender picks the lot up.
    case pileOn
    /// The game is over; see `DurakState.result`.
    case over
}

/// How a game ended.
enum DurakResult: Codable, Hashable, Sendable {
    /// The seat left holding cards: the durak.
    case durak(Int)
    /// The last attacker and the last defender ran out together: nobody is
    /// the durak.
    case draw
}

/// A decision. The seat making it is passed alongside, to `apply(_:by:)`.
enum DurakAction: Codable, Hashable, Sendable, CustomStringConvertible {
    /// Put a card on the table as an attacking card: the lead, a throw-in,
    /// or a card piled on a defender who is taking.
    case attack(Card)
    /// The defender covers the unbeaten attacking card `on` with `card`.
    case defend(Card, on: Card)
    /// Perevodnoy: the defender adds `card`, of the attacking cards' rank, and
    /// the next player defends against them all.
    case transfer(Card)
    /// The defender gives up the bout and will pick up every card on the table.
    case take
    /// An attacker has nothing (more) to add: "Bito" from the main attacker
    /// once everything is beaten, "Pass" from the others, "Done" while the
    /// defender is taking. `DurakState.passKind(for:)` says which to print.
    case pass

    var description: String {
        switch self {
        case .attack(let card): return "attack \(card)"
        case .defend(let card, let attack): return "beat \(attack) with \(card)"
        case .transfer(let card): return "transfer \(card)"
        case .take: return "take"
        case .pass: return "pass"
        }
    }

    /// The card this action puts on the table, if any.
    var card: Card? {
        switch self {
        case .attack(let card), .defend(let card, _), .transfer(let card): return card
        case .take, .pass: return nil
        }
    }
}

/// What a `.pass` means at this moment, for the button's title.
enum DurakPassKind: Sendable {
    /// The main attacker, everything beaten: "Bito".
    case bito
    /// Another attacker in the throw-in round: "Pass".
    case pass
    /// An attacker piling on a defender who is taking: "Done".
    case done
}

/// A seat's part in the current bout, for the status word under its name.
enum DurakRole: Sendable {
    case attacking      // the main attacker
    case defending
    case taking         // the defender, having said "Take"
    case idle           // waiting: may throw in when asked
    case out            // no cards left with the deck gone: safe
    case durak          // the game is over and this seat lost
}

/// Something that happened, in the order it happened, for the view to
/// animate. `apply(_:by:)` and `DurakState.newGame` return them; everything
/// the view needs to move a card is in the event, and the state after the
/// whole list has been applied is `DurakState` itself.
enum DurakEvent: Hashable, Sendable {
    /// Six cards each, one at a time round the table starting with seat 0
    /// (hand[s][i] is the i-th card seat s received), then the next card
    /// turned up as trumps and slid under the deck, crosswise and visible.
    case dealt(hands: [[Card]], trump: Card)
    /// Who opens: with `shown` the lowest trump, which the attacker showed
    /// ("Maria has the 6♥ — she starts"); nil when the durak of the last game
    /// defends first.
    case opening(attacker: Int, defender: Int, shown: Card?)
    /// A new bout: `attacker` leads against `defender`.
    case boutStarted(attacker: Int, defender: Int)
    /// The lead: the first card of a bout.
    case attacked(seat: Int, card: Card)
    /// A card thrown in (or piled on a taker) by `seat`.
    case threwIn(seat: Int, card: Card)
    /// The defender covered `attack` with `card`.
    case beat(seat: Int, card: Card, attack: Card)
    /// Perevodnoy: `seat` added `card` and `to` defends now.
    case transferred(seat: Int, card: Card, to: Int)
    /// The defender said "Take". The cards stay on the table while the
    /// attackers pile on; `took` follows.
    case takes(seat: Int)
    /// An attacker passed (Bito / Pass / Done).
    case passed(seat: Int)
    /// The defender picked up every card on the table.
    case took(seat: Int, cards: [Card])
    /// Every attack was beaten: the table goes face down to the discard.
    case bito(cards: [Card])
    /// `seat` drew these from the deck, top first. The last card of the
    /// deck is the trump card from under it; see `DurakState.trumpCard`.
    case drew(seat: Int, cards: [Card])
    /// `seat` has no cards and the deck is gone: they are out, safe.
    /// `place` is 1 for the first player out.
    case playerOut(seat: Int, place: Int)
    /// The game is over.
    case gameOver(DurakResult)
}

/// Why `apply(_:by:)` refused an action.
enum DurakError: Error, Equatable, Sendable {
    /// It is not this seat's decision (or the game is over).
    case notYourTurn
    /// The action breaks the rules in the current position.
    case illegal
}
