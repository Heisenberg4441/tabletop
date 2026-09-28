//
//  DurakTests.swift
//  Durak's checks, for `Tabletop --selftest durak`.
//

import Foundation

@MainActor
enum DurakTests {

    static func run(_ t: TestReporter) {
        t.section("Durak")
        t.check("the game introduces itself as durak", DurakGame.info.id == .durak)
    }
}
