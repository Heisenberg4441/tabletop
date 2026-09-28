//
//  PokerTests.swift
//  Poker's checks, for `Tabletop --selftest poker`.
//

import AppKit

@MainActor
enum PokerTests {

    static func run(_ t: TestReporter) {
        t.section("Poker")
        t.check("the game introduces itself as poker", PokerGame.info.id == .poker)
        // `--selftest poker --poker-artwork out.png`: the library tile, drawn
        // large enough to judge, instead of the tests.
        if let path = TabletopEnvironment.value(of: "--poker-artwork") {
            t.check("the cover is drawn to \(path)", PokerArtwork.writeSheet(to: path))
            return
        }
        PokerEngineTests.run(t)
        PokerWorkerTests.run(t)
        PokerFlowTests.run(t)
    }
}
