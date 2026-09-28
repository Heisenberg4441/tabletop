//
//  DealGenerator.swift
//  Finds deal numbers that are actually winnable.
//

import Foundation

/// Roughly four out of five random Klondike deals can be won with perfect play,
/// so "winnable deals only" is a matter of rejecting the occasional hopeless
/// one rather than searching hard for a rare good one.
final class DealGenerator {

    private var cache: Set<Int> = []

    /// Returns a deal number the solver believes can be won. Falls back to a
    /// random deal rather than spinning forever if the search keeps timing out
    /// — an unwinnable deal now and then is much better than a hang.
    func winnableDealNumber(options: GameOptions, attempts: Int = 40) -> Int {
        for _ in 0..<attempts {
            let number = DealNumber.random()
            let state = GameState.deal(number: number,
                                       drawCount: options.drawCount,
                                       redealLimit: options.redealLimit)
            if KlondikeSolver(state: state).isWinnable() {
                cache.insert(number)
                return number
            }
        }
        return cache.randomElement() ?? DealNumber.random()
    }
}
