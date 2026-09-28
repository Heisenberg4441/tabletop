//
//  BlackjackTests.swift
//  Blackjack's checks, for `Tabletop --selftest blackjack`.
//

import Foundation

@MainActor
enum BlackjackTests {

    static func run(_ t: TestReporter) {
        t.section("Blackjack")
        t.check("the game introduces itself as blackjack", BlackjackGame.info.id == .blackjack)
    }
}
