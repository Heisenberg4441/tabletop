//
//  GameCatalog.swift
//  Which games exist, and in what order.
//
//  The one place a new game is registered. The switch is exhaustive over
//  `GameID`, so adding a case there without a game here — or the other way
//  round — is a compile error rather than a tile that crashes when clicked.
//

import AppKit

@MainActor
enum GameCatalog {

    /// Every game, in library order — which is `GameID.allCases` order.
    static var all: [any TabletopGame.Type] {
        GameID.allCases.map(type(for:))
    }

    static func type(for id: GameID) -> any TabletopGame.Type {
        switch id {
        case .pool: return PoolGame.self
        case .poker: return PokerGame.self
        case .blackjack: return BlackjackGame.self
        case .durak: return DurakGame.self
        case .solitaire: return SolitaireGame.self
        }
    }

    static func info(for id: GameID) -> GameInfo {
        type(for: id).info
    }
}
