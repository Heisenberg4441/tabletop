//
//  SolitaireStatus.swift
//  What the solitaire table says about the game in progress, and the three
//  buttons worth having permanently to hand.
//
//  This used to be an opaque strip under the board. It is now two pieces of
//  the kit: the numbers — deal, score, clock, moves — are status pills in the
//  window's top strip (`TopBarStatus`), and Undo, Hint and Auto-Finish ride
//  in a glass action bar floating over the bottom of the felt. The board keeps
//  its cards clear of the bar through `BoardView.bottomInset`.
//

import AppKit

enum SolitaireStatus {

    /// The pills for `game`: the deal, the score (unless scoring is off), the
    /// clock and the move count. Digits are tabular, so a ticking clock never
    /// makes its neighbours shuffle.
    static func pills(for game: Game, scoring: ScoringMode) -> [StatusPillItem] {
        var items: [StatusPillItem] = [
            StatusPillItem(id: "deal", text: String(format: NSLocalizedString("Deal %d", comment: "deal number"),
                                                    game.dealNumber), symbolName: "number"),
        ]
        switch scoring {
        case .none:
            break
        case .vegas:
            let score = game.displayScore
            items.append(StatusPillItem(id: "score", text: String(
                format: NSLocalizedString("%@$%d", comment: "vegas score pill"), score < 0 ? "\u{2212}" : "", abs(score)),
                symbolName: "dollarsign.circle"))
        case .standard:
            items.append(StatusPillItem(id: "score", text: String(
                format: NSLocalizedString("Score %d", comment: "score pill"), game.displayScore), symbolName: "star"))
        }
        let seconds = Int(game.elapsed)
        items.append(StatusPillItem(id: "time", text: String(format: "%d:%02d", seconds / 60, seconds % 60),
                                    symbolName: "clock"))
        items.append(StatusPillItem(id: "moves", text: Plural.format(
            game.actionCount,
            one: NSLocalizedString("%d move", comment: "move count pill, singular"),
            other: NSLocalizedString("%d moves", comment: "move count pill, plural")),
            symbolName: "arrow.left.arrow.right"))
        return items
    }

    /// The bar's buttons. Auto-Finish appears only when the game is already
    /// decided — and then it is the obvious next thing to do, so it is the
    /// primary one.
    static func actions(for game: Game, undo: @escaping () -> Void, hint: @escaping () -> Void,
                        finish: @escaping () -> Void) -> [ChromeAction] {
        var actions: [ChromeAction] = []
        if game.canAutoFinish {
            actions.append(ChromeAction(id: "finish", title: NSLocalizedString("Auto-Finish", comment: ""),
                                        symbolName: "wand.and.sparkles", style: .primary, handler: finish))
        }
        actions.append(ChromeAction(id: "hint", title: NSLocalizedString("Hint", comment: ""), symbolName: "lightbulb",
                                    isEnabled: !game.isWon, handler: hint))
        actions.append(ChromeAction(id: "undo", title: NSLocalizedString("Undo", comment: ""),
                                    symbolName: "arrow.uturn.backward", isEnabled: game.canUndo, handler: undo))
        return actions
    }
}
