//
//  PokerGame.swift
//  Texas Hold'em against computer players. A placeholder until the game
//  itself lands in this folder.
//

import AppKit

final class PokerGame: NSViewController, TabletopGame {

    static var info: GameInfo {
        GameInfo(
            id: .poker,
            title: NSLocalizedString("Poker", comment: "game title"),
            subtitle: NSLocalizedString("Texas Hold’em against the table", comment: "poker subtitle"),
            detail: NSLocalizedString("1 player · vs computer", comment: "poker players"),
            symbolName: "suit.spade.fill",
            accent: NSColor(srgbRed: 0.145, green: 0.318, blue: 0.557, alpha: 1),
            keyEquivalent: "2"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Each player is dealt two cards face down; five more are dealt face up \
        in the middle for everyone to share, in three rounds.

        • Make the best five-card hand from your two cards and the five on the \
        table.
        • Bet, call, raise or fold as each round of cards comes out.
        • The best hand at the showdown takes the pot — unless everyone else \
        folded first.
        """, comment: "poker help text")
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func loadView() {
        view = ComingSoonView(info: Self.info)
    }

    func makeGameMenu() -> NSMenu {
        ComingSoonView.menu(for: Self.info)
    }

    static func runSelfTests(_ t: TestReporter) {
        PokerTests.run(t)
    }

    // MARK: Library tile

    /// Pocket aces at the rail of an oval table, the board and the pot beyond. See `PokerArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        PokerArtwork.draw(in: ctx, rect: rect)
    }
}
