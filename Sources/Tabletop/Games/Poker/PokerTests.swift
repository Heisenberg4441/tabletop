//
//  PokerTests.swift
//  Poker's checks, for `Tabletop --selftest poker`.
//

import Foundation

@MainActor
enum PokerTests {

    static func run(_ t: TestReporter) {
        t.section("Poker")
        t.check("the game introduces itself as poker", PokerGame.info.id == .poker)
    }
}
