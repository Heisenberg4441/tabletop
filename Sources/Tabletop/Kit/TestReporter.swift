//
//  TestReporter.swift
//  The one object every self-test in the app writes its verdicts to.
//
//  `Tabletop --selftest` runs the kit's tests and then every game's, and the
//  games are written by different people at different times. What keeps the
//  output one readable report — and what lets build.sh fail the build on a
//  single broken check anywhere — is that they all go through this, rather than
//  each printing and counting in its own way.
//
//  The format is fixed and deliberately plain, because it is read by eye in a
//  terminal and by `grep FAIL` in scripts:
//
//      Section title
//        ok   what was checked
//        FAIL what was checked
//        info anything worth knowing that is not a pass or a fail
//

import Foundation

final class TestReporter {

    /// Checks that came out false, across every section so far.
    private(set) var failures = 0
    /// Every check made, passed or not — a suite that silently stopped running
    /// its checks would otherwise look exactly like one that passes.
    private(set) var checks = 0

    /// Where the lines go. Standard output by default; a test of the reporter
    /// itself can collect them instead.
    private let write: (String) -> Void

    init(write: @escaping (String) -> Void = { print($0) }) {
        self.write = write
    }

    /// Starts a group of related checks. Unindented, so the report reads as a
    /// list of headings with verdicts underneath.
    func section(_ title: String) {
        write(title)
    }

    /// Records one verdict. Returns it too, so a test can stop early when a
    /// precondition fails instead of piling up failures that all mean the same
    /// thing.
    @discardableResult
    func check(_ name: String, _ ok: Bool) -> Bool {
        checks += 1
        if !ok { failures += 1 }
        write(ok ? "  ok   \(name)" : "  FAIL \(name)")
        return ok
    }

    /// A line of context that is neither a pass nor a fail — a win rate, a
    /// timing — so it can sit in the report without being mistaken for either.
    func info(_ text: String) {
        write("  info \(text)")
    }

    /// Ends the report: a blank line, then the one-line verdict build.sh shows
    /// with `tail`, and the process exit status to go with it.
    func finish(passed: String, failed: (Int) -> String) -> Int32 {
        write("")
        write(failures == 0 ? passed : failed(failures))
        return failures == 0 ? 0 : 1
    }
}
