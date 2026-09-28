//
//  PoolGame.swift
//  Eight-ball pool. A placeholder until the game itself lands in this folder.
//

import AppKit

final class PoolGame: NSViewController, TabletopGame {

    static var info: GameInfo {
        GameInfo(
            id: .pool,
            title: NSLocalizedString("Pool", comment: "game title"),
            subtitle: NSLocalizedString("Eight-ball on a full-size table", comment: "pool subtitle"),
            detail: NSLocalizedString("1–2 players · vs computer", comment: "pool players"),
            symbolName: "8.circle.fill",
            accent: NSColor(srgbRed: 0.090, green: 0.420, blue: 0.470, alpha: 1),
            keyEquivalent: "1"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Eight-ball is played with a cue ball and fifteen object balls: seven \
        solids, seven stripes and the black eight.

        • After the break, the first ball you pot decides your group.
        • Pot all of your group, then the eight, to win.
        • Pot the eight early, or pot the cue ball on the eight, and you lose \
        the frame.
        """, comment: "pool help text")
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
        PoolTests.run(t)
    }

    // MARK: Library tile

    /// The rack under the lamp, seen from behind the cue ball. See
    /// `PoolArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        PoolArtwork.draw(in: ctx, rect: rect)
    }
}
