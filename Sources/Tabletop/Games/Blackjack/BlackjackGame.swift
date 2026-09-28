//
//  BlackjackGame.swift
//  Blackjack against the dealer. A placeholder until the game itself lands in
//  this folder.
//

import AppKit

final class BlackjackGame: NSViewController, TabletopGame {

    static var info: GameInfo {
        GameInfo(
            id: .blackjack,
            title: NSLocalizedString("Blackjack", comment: "game title"),
            subtitle: NSLocalizedString("Beat the dealer to twenty-one", comment: "blackjack subtitle"),
            detail: NSLocalizedString("1 player · vs the dealer", comment: "blackjack players"),
            symbolName: "suit.diamond.fill",
            accent: NSColor(srgbRed: 0.545, green: 0.153, blue: 0.188, alpha: 1),
            keyEquivalent: "3"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Get closer to twenty-one than the dealer without going over.

        • Number cards count their number, court cards count ten, and an ace \
        counts one or eleven, whichever helps.
        • Hit to take another card; stand to keep what you have. Double down \
        to double your bet for exactly one more card, or split a pair into two \
        hands.
        • The dealer draws to sixteen and stands on seventeen. An ace and a \
        ten-card dealt together is a blackjack, and pays three to two.
        """, comment: "blackjack help text")
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
        BlackjackTests.run(t)
    }

    // MARK: Library tile

    /// A natural on the betting circle, the dealer beyond the printed arcs. See `BlackjackArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        BlackjackArtwork.draw(in: ctx, rect: rect)
    }
}
