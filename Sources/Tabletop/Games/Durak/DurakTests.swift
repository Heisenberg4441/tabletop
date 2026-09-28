//
//  DurakTests.swift
//  Durak's checks, for `Tabletop --selftest durak`: the rules and the bots
//  first (Engine/DurakEngineTests), then the table the player plays them on
//  (DurakPresentationTests) — whole games through the real controller,
//  driven by clicks, drops and keys.
//

import Foundation

@MainActor
enum DurakTests {

    static func run(_ t: TestReporter) {
        t.section("Durak")
        t.check("the game introduces itself as durak", DurakGame.info.id == .durak)
        DurakEngineTests.run(t)
        DurakPresentationTests.run(t)
    }
}
