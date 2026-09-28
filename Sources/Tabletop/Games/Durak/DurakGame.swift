//
//  DurakGame.swift
//  Durak, the Russian game of attack and defence, against computer players.
//  A placeholder until the game itself lands in this folder.
//

import AppKit

final class DurakGame: NSViewController, TabletopGame {

    static var info: GameInfo {
        GameInfo(
            id: .durak,
            title: NSLocalizedString("Durak", comment: "game title"),
            subtitle: NSLocalizedString("The classic Russian card game", comment: "durak subtitle"),
            detail: NSLocalizedString("1 player · vs computer", comment: "durak players"),
            symbolName: "suit.club.fill",
            accent: NSColor(srgbRed: 0.278, green: 0.306, blue: 0.451, alpha: 1),
            keyEquivalent: "4"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Played with thirty-six cards, six through ace. The last card of the \
        deal is turned up, and its suit is trumps for the whole game.

        • The attacker leads a card; the defender beats it with a higher card \
        of the same suit, or with any trump.
        • The attacker may keep adding cards of a rank already on the table. \
        A defender who cannot beat them all picks the lot up.
        • Everyone draws back up to six from the deck. Nobody wins durak — the \
        last player left holding cards is the durak, the fool.
        """, comment: "durak help text")
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
        DurakTests.run(t)
    }

    // MARK: Library tile

    /// The deck with the trump across it, a beaten attack, the hand below. See `DurakArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        DurakArtwork.draw(in: ctx, rect: rect)
    }
}
