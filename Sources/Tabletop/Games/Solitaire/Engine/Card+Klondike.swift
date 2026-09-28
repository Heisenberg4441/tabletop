//
//  Card+Klondike.swift
//  What may go on what, in Klondike.
//
//  Kept out of `Card` itself because the deck is shared by every game in the
//  collection and these are one game's rules: a red five on a black six means
//  something in solitaire and nothing at all in poker.
//

import Foundation

extension Card {

    /// Index of the foundation this card belongs on.
    var foundationIndex: Int { Int(code / 13) }

    /// True if `self` may be stacked directly on `other` in the tableau:
    /// one lower in rank and of the opposite colour.
    func canStack(onTableau other: Card) -> Bool {
        colorBit != other.colorBit && value == other.value - 1
    }

    /// True if `self` may be played onto a foundation whose top card is `top`
    /// (`nil` meaning the foundation is empty and wants an ace).
    func canStack(onFoundation top: Card?) -> Bool {
        guard let top else { return rank == .ace }
        return top.suit == suit && value == top.value + 1
    }
}
