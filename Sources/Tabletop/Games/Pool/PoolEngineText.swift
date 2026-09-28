//
//  PoolEngineText.swift
//  Everything the player reads about what the engine decided, in words.
//
//  The engine reports fouls, rule messages and the reason a game ended as
//  enums, and leaves the words to the presentation. This is the only file
//  outside the engine that spells out those enums' cases, so that when the
//  engine grows a case (or renames one) this is the one file to reconcile.
//

import Foundation

enum PoolEngineText {

    // MARK: Names

    static func mode(_ mode: PoolMode) -> String {
        switch mode {
        case .eightBall: return NSLocalizedString("8-Ball", comment: "pool game: eight-ball")
        case .nineBall: return NSLocalizedString("9-Ball", comment: "pool game: nine-ball")
        case .practice: return NSLocalizedString("Practice", comment: "pool game: practice on your own")
        }
    }

    static func modeSymbol(_ mode: PoolMode) -> String {
        switch mode {
        case .eightBall: return "8.circle.fill"
        case .nineBall: return "9.circle.fill"
        case .practice: return "circle.dashed"
        }
    }

    static func difficulty(_ difficulty: PoolDifficulty) -> String {
        switch difficulty {
        case .easy: return NSLocalizedString("Easy", comment: "pool difficulty")
        case .medium: return NSLocalizedString("Medium", comment: "pool difficulty")
        case .hard: return NSLocalizedString("Hard", comment: "pool difficulty")
        }
    }

    static func group(_ group: PoolGroup) -> String {
        switch group {
        case .solids: return NSLocalizedString("Solids", comment: "pool: balls 1 to 7")
        case .stripes: return NSLocalizedString("Stripes", comment: "pool: balls 9 to 15")
        }
    }

    /// The balls in a group, lowest first.
    static func numbers(in group: PoolGroup) -> [Int] {
        switch group {
        case .solids: return Array(1...7)
        case .stripes: return Array(9...15)
        }
    }

    // MARK: Fouls

    /// A foul, short enough for a toast: "Scratch", "No rail".
    static func foul(_ foul: PoolFoul) -> String {
        switch foul {
        case .scratch: return NSLocalizedString("Scratch", comment: "pool foul: the cue ball went in a pocket")
        case .noContact: return NSLocalizedString("No ball hit", comment: "pool foul: the cue ball touched nothing")
        case .wrongBallFirst: return NSLocalizedString("Wrong ball first", comment: "pool foul: hit the wrong ball first")
        case .noRail: return NSLocalizedString("No rail after contact", comment: "pool foul: nothing reached a cushion")
        }
    }

    // MARK: The end of a game

    /// Why the game ended, as the result banner's second line.
    static func gameOver(_ reason: PoolGameOverReason, winnerIsYou: Bool, opponent: String) -> String {
        switch reason {
        case .eightPocketed:
            return winnerIsYou
                ? NSLocalizedString("You cleared your group and sank the eight.", comment: "pool result")
                : String(format: NSLocalizedString("%@ cleared the table and sank the eight.", comment: "pool result"), opponent)
        case .eightEarly:
            return winnerIsYou
                ? String(format: NSLocalizedString("%@ sank the eight too early.", comment: "pool result"), opponent)
                : NSLocalizedString("The eight went down before your group was clear.", comment: "pool result")
        case .eightOnFoul:
            return winnerIsYou
                ? String(format: NSLocalizedString("%@ fouled on the eight.", comment: "pool result"), opponent)
                : NSLocalizedString("The eight went down on a foul.", comment: "pool result")
        case .ninePocketed:
            return winnerIsYou
                ? NSLocalizedString("You sank the nine.", comment: "pool result")
                : String(format: NSLocalizedString("%@ sank the nine.", comment: "pool result"), opponent)
        }
    }

    // MARK: Rule messages

    /// A passing remark for a rule message that the rest of the outcome does
    /// not already say — a re-spotted ball — or nil for one it does (fouls
    /// and groups are told from the outcome's own fields).
    static func remark(_ message: PoolRuleMessage) -> String? {
        switch message {
        case .foul, .groupAssigned, .tableOpen: return nil
        case .eightRespotted: return NSLocalizedString("The eight is spotted again", comment: "pool toast")
        case .nineRespotted: return NSLocalizedString("The nine is spotted again", comment: "pool toast")
        case .cueBallRespotted: return NSLocalizedString("Cue ball spotted again", comment: "pool toast")
        }
    }
}
