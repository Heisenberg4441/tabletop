//
//  Benchmark.swift
//  `Solitaire --benchmark` — checks the solver is fast enough to sit in front
//  of a "New Game" click without the player noticing.
//
//  The median matters more than the mean here: "New Game" waits for one deal
//  to be classified, and the mean is dragged around by the handful of deals
//  that spend the whole budget.
//

import Foundation

enum Benchmark {

    static func run() -> Int32 {
        let deals = Int(ProcessInfo.processInfo.environment["BENCH_DEALS"] ?? "") ?? 200
        print("Solver, \(deals) random draw-one deals")
        measure(deals: deals, drawCount: 1)
        print("")
        print("Solver, \(deals) random draw-three deals")
        measure(deals: deals, drawCount: 3)
        print("")
        print("Card rendering")
        let renderer = CardRenderer(theme: Theme(), size: CGSize(width: 110, height: 157), scale: 2)
        let start = Date()
        for card in Card.full { _ = renderer.faceImage(for: card) }
        _ = renderer.backImage()
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "  53 card bitmaps in %.1f ms (%.2f MB cached)",
                     elapsed * 1000, Double(renderer.cacheBytes) / 1_048_576))
        return 0
    }

    private static func measure(deals: Int, drawCount: Int) {
        var limits = KlondikeSolver.Limits()
        let environment = ProcessInfo.processInfo.environment
        if let budget = Int(environment["BENCH_BUDGET"] ?? "") { limits.nodeBudget = budget }
        if let deadline = Double(environment["BENCH_DEADLINE"] ?? "") { limits.deadline = deadline }

        var solved: [Int] = []
        var winnable = 0, undecided = 0
        var totalNodes = 0
        var times: [TimeInterval] = []
        let start = Date()
        for n in 1...deals {
            let state = GameState.deal(number: n * 37 + drawCount, drawCount: drawCount)
            let solver = KlondikeSolver(state: state, limits: limits)
            let t0 = Date()
            if solver.isWinnable() { winnable += 1; solved.append(n) } else if solver.hitLimit { undecided += 1 }
            times.append(Date().timeIntervalSince(t0))
            totalNodes += solver.nodesVisited
        }
        let elapsed = Date().timeIntervalSince(start)
        times.sort()
        let median = times[times.count / 2]
        let p90 = times[min(times.count - 1, times.count * 9 / 10)]
        print(String(format: "  %d winnable (%.0f%%), %d undecided (hit the limit)",
                     winnable, Double(winnable) / Double(deals) * 100, undecided))
        print(String(format: "  %.1f ms median, %.1f ms 90th percentile, %.1f ms mean, %.1f ms worst",
                     median * 1000, p90 * 1000, elapsed / Double(deals) * 1000, times[times.count - 1] * 1000))
        print(String(format: "  %.0f k states per second", Double(totalNodes) / elapsed / 1000))
        if environment["BENCH_LIST"] != nil { print("  solved \(solved)") }
    }
}
