//
//  PoolTests.swift
//  Pool's checks, for `Tabletop --selftest pool`.
//

import Foundation

@MainActor
enum PoolTests {

    static func run(_ t: TestReporter) {
        t.section("Pool")
        t.check("the game introduces itself as pool", PoolGame.info.id == .pool)
    }
}
