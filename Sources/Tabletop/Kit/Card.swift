//
//  Card.swift
//  The 52-card deck, encoded as compactly as possible.
//
//  Shared by every card game in the collection, so nothing in here knows any
//  game's rules — what may go on what is each game's business, written as an
//  extension in its own folder (Klondike's is `Card+Klondike.swift`). A game
//  that plays with a short deck, like Durak's 36, filters `Card.full`.
//
//  A card is a single byte: `suit * 13 + (rank - 1)`, i.e. 0...51.
//  Keeping it a byte matters — the solver hashes millions of positions and
//  packs whole piles into fixed-size buffers, so an array of class instances
//  (or even a two-field struct) would cost real time in ARC and cache misses.
//

import Foundation

/// The four suits, in the order solitaire lays out its foundations — which is
/// also the order the card codes are packed in, so it can never change.
enum Suit: UInt8, CaseIterable, Codable, Sendable {
    case clubs = 0
    case diamonds = 1
    case hearts = 2
    case spades = 3

    /// Red suits may only be stacked on black ones and vice versa.
    var isRed: Bool { self == .diamonds || self == .hearts }

    /// `0` for black, `1` for red — cheaper to compare than the suit itself
    /// when all we care about is alternation.
    var colorBit: UInt8 { isRed ? 1 : 0 }

    var symbol: String {
        switch self {
        case .clubs: return "\u{2663}"
        case .diamonds: return "\u{2666}"
        case .hearts: return "\u{2665}"
        case .spades: return "\u{2660}"
        }
    }

    /// Spoken by VoiceOver and used in the accessibility tree.
    var localizedName: String {
        switch self {
        case .clubs: return NSLocalizedString("Clubs", comment: "suit")
        case .diamonds: return NSLocalizedString("Diamonds", comment: "suit")
        case .hearts: return NSLocalizedString("Hearts", comment: "suit")
        case .spades: return NSLocalizedString("Spades", comment: "suit")
        }
    }
}

/// Ranks are 1...13, ace low, so that `rank.rawValue` doubles as a solitaire
/// foundation's height once that rank has been played: an empty foundation is
/// 0, an ace makes it 1. Games where the ace ranks high (poker, durak) say so
/// in their own comparison rather than renumbering the deck.
enum Rank: UInt8, CaseIterable, Codable, Sendable {
    case ace = 1, two, three, four, five, six, seven, eight, nine, ten
    case jack, queen, king

    var isCourt: Bool { rawValue >= 11 }

    /// The glyph shown in the corner index.
    var label: String {
        switch self {
        case .ace: return "A"
        case .ten: return "10"
        case .jack: return "J"
        case .queen: return "Q"
        case .king: return "K"
        default: return String(rawValue)
        }
    }

    var localizedName: String {
        switch self {
        case .ace: return NSLocalizedString("Ace", comment: "rank")
        case .jack: return NSLocalizedString("Jack", comment: "rank")
        case .queen: return NSLocalizedString("Queen", comment: "rank")
        case .king: return NSLocalizedString("King", comment: "rank")
        default: return String(rawValue)
        }
    }
}

/// One of the 52 cards. `code` is the only stored property.
struct Card: Hashable, Codable, Sendable, CustomStringConvertible {
    /// `suit * 13 + (rank - 1)`, always in `0...51`.
    let code: UInt8

    init(code: UInt8) {
        assert(code < 52, "card code out of range")
        self.code = code
    }

    init(_ suit: Suit, _ rank: Rank) {
        self.code = suit.rawValue &* 13 &+ (rank.rawValue &- 1)
    }

    var suit: Suit { Suit(rawValue: code / 13)! }
    var rank: Rank { Rank(rawValue: code % 13 &+ 1)! }

    var isRed: Bool { suit.isRed }
    var colorBit: UInt8 { suit.colorBit }

    /// Rank as an integer, for the arithmetic the rules do constantly.
    var value: Int { Int(code % 13) + 1 }

    /// A full ordered deck, ace of clubs through king of spades.
    static let full: [Card] = (0..<52).map { Card(code: UInt8($0)) }

    var description: String { "\(rank.label)\(suit.symbol)" }

    /// e.g. "Ace of Spades" — used for accessibility labels.
    var accessibilityName: String {
        String(
            format: NSLocalizedString("%@ of %@", comment: "card name: rank of suit"),
            rank.localizedName, suit.localizedName
        )
    }
}
