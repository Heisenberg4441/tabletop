//
//  SolitaireLifecycleTests.swift
//  Solitaire as one game among five: what happens to it when the player
//  walks away, comes back, relaunches, or deals again at the wrong moment.
//
//  The engine's tests (SolitaireTests) cover the rules. These cover the
//  controller, through its real board in a window that is never shown: that
//  nothing keeps ticking after the game has stopped — an auto-finish still
//  stepping, or the win cascade's display link it would have started — and
//  that the statistics count each deal once and each win at all.
//

import AppKit

@MainActor
enum SolitaireLifecycleTests {

    static func run(_ t: TestReporter) {
        walkingAway(t)
        statistics(t)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A game in a window that is never shown, with its view laid out.
    private static func host(_ game: SolitaireGame) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = game.view
        game.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        game.view.layoutSubtreeIfNeeded()
        return window
    }

    /// Every card up in four columns, one suit each: auto-finish plays all
    /// fifty-two.
    private static var solvedBoard: GameState {
        var state = GameState()
        for suit in Suit.allCases {
            state.tableau[Int(suit.rawValue)].up = (1...13).reversed().compactMap {
                Rank(rawValue: UInt8($0)).map { Card(suit, $0) }
            }
        }
        return state
    }

    /// One king short of a win.
    private static var oneMoveFromWinning: GameState {
        var state = GameState()
        for suit in Suit.allCases { state.foundations[Int(suit.rawValue)] = 13 }
        state.foundations[3] = 12
        state.tableau[0].up = [Card(.spades, .king)]
        return state
    }

    private static func walkingAway(_ t: TestReporter) {
        t.section("Solitaire when the player walks away")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = saved }

        let solitaire = SolitaireGame()
        let window = host(solitaire)
        defer { withExtendedLifetime(window) {} }
        guard let board = solitaire.boardForTesting else {
            t.check("the board is there", false)
            return
        }
        solitaire.gameDidBecomeActive()
        board.game.forceState(solvedBoard)
        board.replaceGame(board.game, dealAnimation: false)
        solitaire.autoFinish(nil)
        pump(0.1)
        t.check("an auto-finish is under way", board.isPerformingSequence && !board.game.isWon)
        solitaire.gameWillResignActive()
        t.check("walking away plays it out at once — the deal is won", board.game.isWon && !board.isPerformingSequence)
        t.check("and the win cascade's display link is never started", !board.isWinAnimationRunning)
        pump(0.4)
        t.check("nor started later by a step that was already waiting", !board.isWinAnimationRunning)

        // Back at the table, a win does get its cascade.
        solitaire.gameDidBecomeActive()
        board.game.forceState(oneMoveFromWinning)
        board.replaceGame(board.game, dealAnimation: false)
        _ = board.perform(.tableauToFoundation(column: 0))
        t.check("in front, a win plays its cascade", board.isWinAnimationRunning)
        solitaire.gameWillResignActive()
        t.check("which lands at once when the player leaves", !board.isWinAnimationRunning)
        solitaire.prepareToQuit()
    }

    private static func statistics(_ t: TestReporter) {
        t.section("Solitaire statistics")
        Storage.remove(SolitaireStatistics.fileName)
        Storage.remove(Storage.fileName("current-game.json", for: .solitaire))

        let first = SolitaireGame()
        let window = host(first)
        first.drawFromStock(nil)
        first.prepareToQuit()
        let drawCount = first.preferences.drawCount
        t.check("the first move of a deal counts it as played",
                SolitaireStatistics.load()[drawCount].played == 1)

        // Relaunch: the same deal comes back from disk, and another move is
        // made on it.
        let second = SolitaireGame()
        window.contentView = second.view
        second.view.layoutSubtreeIfNeeded()
        second.drawFromStock(nil)
        second.prepareToQuit()
        t.check("a deal restored after a relaunch is not counted again",
                SolitaireStatistics.load()[drawCount].played == 1)

        // A new deal asked for while the win cascade is still flying.
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = saved }
        let third = SolitaireGame()
        window.contentView = third.view
        third.view.layoutSubtreeIfNeeded()
        third.gameDidBecomeActive()
        guard let board = third.boardForTesting else {
            t.check("the board is there", false)
            return
        }
        board.game.forceState(oneMoveFromWinning)
        board.replaceGame(board.game, dealAnimation: false)
        _ = board.perform(.tableauToFoundation(column: 0))
        let before = SolitaireStatistics.load()[drawCount]
        t.check("a won deal's cascade is flying", board.isWinAnimationRunning)
        third.newGame(nil)
        let after = SolitaireStatistics.load()[drawCount]
        t.check("⌘N in the middle of it still records the win (won \(before.won) → \(after.won))",
                after.won == before.won + 1 && after.currentStreak >= 1)
        third.gameWillResignActive()
        third.prepareToQuit()
        withExtendedLifetime(window) {}
    }
}
