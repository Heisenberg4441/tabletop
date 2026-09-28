//
//  SelfTestRunner.swift
//  `Tabletop --selftest [kit|<game id>]`: the kit's checks, then every game's.
//
//  One reporter for the whole run, so a single failure anywhere — in the deck,
//  in the migration, in any game's engine — makes the exit status non-zero,
//  which is what build.sh stops on.
//

import AppKit

@MainActor
enum SelfTestRunner {

    static func run(only: String?) -> Int32 {
        let known = ["kit"] + GameID.allCases.map(\.rawValue)
        if let only, !known.contains(only) {
            FileHandle.standardError.write(Data(
                "selftest: no such suite '\(only)'. Try one of: \(known.joined(separator: ", "))\n".utf8))
            return 2
        }
        let t = TestReporter()
        if only == nil || only == "kit" {
            KitTests.run(t)
        }
        for type in GameCatalog.all where only == nil || only == type.info.id.rawValue {
            type.runSelfTests(t)
        }
        return t.finish(passed: "All self-tests passed.", failed: { "\($0) self-test(s) FAILED." })
    }
}
