//
//  Scoring.swift
//  The three scoring systems, kept apart from the rules.
//

import Foundation

enum ScoringMode: String, CaseIterable, Codable, Sendable {
    case standard
    case vegas
    case none

    var localizedName: String {
        switch self {
        case .standard: return NSLocalizedString("Standard", comment: "scoring mode")
        case .vegas: return NSLocalizedString("Vegas", comment: "scoring mode")
        case .none: return NSLocalizedString("None", comment: "scoring mode")
        }
    }

    /// Vegas counts in dollars and starts in the hole.
    var isCurrency: Bool { self == .vegas }
    var startingScore: Int { self == .vegas ? -52 : 0 }
    /// Standard scoring never drops below zero; Vegas very much does.
    var clampsAtZero: Bool { self == .standard }
}

/// The classic Windows Solitaire point table, which Microsoft Solitaire
/// Collection still uses for its Standard mode.
enum Scoring {

    static func points(for record: MoveRecord, mode: ScoringMode, state: GameState) -> Int {
        switch mode {
        case .none:
            return 0

        case .vegas:
            // Vegas pays five dollars a card, one way or the other. Nothing
            // else scores.
            switch record.move {
            case .wasteToFoundation, .tableauToFoundation: return 5
            case .foundationToTableau: return -5
            default: return 0
            }

        case .standard:
            var points = 0
            switch record.move {
            case .wasteToTableau:
                points += 5
            case .wasteToFoundation, .tableauToFoundation:
                points += 10
            case .foundationToTableau:
                points -= 15
            case .recycle:
                // Only draw-one is penalised, and only from the second pass on;
                // draw-three players would otherwise be punished for playing
                // the game as designed.
                if state.drawCount == 1 {
                    points -= 100
                } else if record.previousRedealsUsed >= 2 {
                    points -= 20
                }
            case .draw, .tableauToTableau:
                break
            }
            // Exposing a face-down card is worth as much as a waste play.
            if record.flippedSourceCard { points += 5 }
            return points
        }
    }

    /// The classic timed-game bonus, awarded on a win: the faster the finish,
    /// the larger the payout, and nothing at all under half a minute.
    static func timeBonus(mode: ScoringMode, timed: Bool, seconds: TimeInterval) -> Int {
        guard mode == .standard, timed, seconds > 30 else { return 0 }
        return Int(700_000.0 / seconds)
    }

    /// In a timed standard game two points drain away every ten seconds.
    static func timePenalty(mode: ScoringMode, timed: Bool, seconds: TimeInterval) -> Int {
        guard mode == .standard, timed else { return 0 }
        return -2 * Int(seconds / 10)
    }

    /// Vegas rewards a completed deal with the pot back plus the winnings; the
    /// per-card payments already cover it, so a win needs no extra bonus.
    static func winBonus(mode: ScoringMode) -> Int { 0 }
}
