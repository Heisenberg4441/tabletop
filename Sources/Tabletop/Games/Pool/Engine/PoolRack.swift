//
//  PoolRack.swift
//  Racking the balls: the eight-ball triangle, the nine-ball diamond, and
//  scattered layouts for practice, tests and screenshots.
//
//  A real rack is never perfectly tight — the balls sit a fraction of a
//  millimetre apart, a little differently every time — and that is exactly
//  what makes every break different. A mathematically tight rack is worse
//  than unrealistic for a simulation: every ball would touch several others
//  at once and the break would depend on the order the arithmetic happened
//  to visit them. So the balls stand on a lattice with a small gap and each
//  is nudged by a seeded amount smaller than the gap, which keeps them apart
//  and the break as varied, and as repeatable, as the seed.
//

import Foundation
#if canImport(simd)
import simd
#endif

enum PoolRack {

    /// Gap between neighbouring balls in a rack, metres (a tenth of a
    /// millimetre and a half), and the largest seeded nudge of any ball.
    static let gap = 0.00015
    static let jitter = 0.00005

    /// Where the cue ball waits for the break: behind the head string, on
    /// the long axis.
    static func breakCueSpot(_ g: PoolTableGeometry = .standard) -> SIMD2<Double> {
        SIMD2(g.headStringX - 0.06, 0)
    }

    /// The eight-ball triangle: apex on the foot spot, the 8 in the middle of
    /// the third row, a solid and a stripe in the two back corners, every
    /// other ball shuffled.
    static func eightBall(seed: UInt64) -> PoolTableState {
        eightBall(seed: seed, geometry: .standard, jitter: jitter)
    }

    static func eightBall(seed: UInt64, geometry g: PoolTableGeometry, jitter: Double) -> PoolTableState {
        var rng = DeterministicRNG(seed: seed ^ 0x8B_A11)
        var solids = Array(1...7), stripes = Array(9...15)
        rng.shuffle(&solids)
        rng.shuffle(&stripes)
        let solidCorner = solids.removeLast(), stripeCorner = stripes.removeLast()
        var rest = solids + stripes
        rng.shuffle(&rest)
        let slots = triangleSlots(rows: [1, 2, 3, 4, 5], geometry: g)
        // Slots in row order: 0 apex; 1–2; 3–5 (8 at 4); 6–9; 10–14 (corners 10, 14).
        var numbers = [Int](repeating: 0, count: 15)
        numbers[4] = 8
        let leftCornerSolid = rng.next() & 1 == 0
        numbers[10] = leftCornerSolid ? solidCorner : stripeCorner
        numbers[14] = leftCornerSolid ? stripeCorner : solidCorner
        for k in 0..<15 where numbers[k] == 0 {
            numbers[k] = rest.removeLast()
        }
        return rack(numbers: numbers, slots: slots, geometry: g, rng: &rng, jitter: jitter)
    }

    /// The nine-ball diamond: 1 on the foot spot, 9 in the middle, the rest
    /// shuffled.
    static func nineBall(seed: UInt64) -> PoolTableState {
        nineBall(seed: seed, geometry: .standard, jitter: jitter)
    }

    static func nineBall(seed: UInt64, geometry g: PoolTableGeometry, jitter: Double) -> PoolTableState {
        var rng = DeterministicRNG(seed: seed ^ 0x9B_A11)
        var rest = Array(2...8)
        rng.shuffle(&rest)
        let slots = triangleSlots(rows: [1, 2, 3, 2, 1], geometry: g)
        // Slots: 0 apex; 1–2; 3–5 (9 at 4); 6–7; 8.
        var numbers = [Int](repeating: 0, count: 9)
        numbers[0] = 1
        numbers[4] = 9
        for k in 0..<9 where numbers[k] == 0 {
            numbers[k] = rest.removeLast()
        }
        return rack(numbers: numbers, slots: slots, geometry: g, rng: &rng, jitter: jitter)
    }

    /// Practice starts from a full fifteen-ball rack.
    static func practice(seed: UInt64) -> PoolTableState {
        eightBall(seed: seed)
    }

    /// The given balls scattered over the table where none touches another
    /// or a cushion, and the cue ball too if it is in the list — a mid-game
    /// layout for tests, screenshots and drills.
    static func scattered(_ numbers: [Int], seed: UInt64, geometry g: PoolTableGeometry = .standard) -> PoolTableState {
        var rng = DeterministicRNG(seed: seed ^ 0x5CA7)
        var balls: [PoolBall] = []
        let hx = g.length / 2 - g.ballRadius * 2.5, hy = g.width / 2 - g.ballRadius * 2.5
        for n in numbers {
            var p = SIMD2<Double>.zero
            for _ in 0..<400 {
                p = SIMD2(unit(&rng) * 2 - 1, unit(&rng) * 2 - 1) * SIMD2(hx, hy)
                if balls.allSatisfy({ simd_distance($0.position, p) > g.ballRadius * 2.6 }) { break }
            }
            balls.append(PoolBall(number: n, position: p, orientation: randomOrientation(&rng)))
        }
        return PoolTableState(balls: balls)
    }

    // MARK: Building blocks

    /// Lattice positions for rows of the given sizes, the first row's single
    /// ball on the foot spot and each next row a ball's height further
    /// toward the foot rail.
    static func triangleSlots(rows: [Int], geometry g: PoolTableGeometry) -> [SIMD2<Double>] {
        let d = 2 * g.ballRadius + gap
        let rowStep = d * 3.0.squareRoot() / 2
        var slots: [SIMD2<Double>] = []
        for (k, count) in rows.enumerated() {
            for i in 0..<count {
                let y = (Double(i) - Double(count - 1) / 2) * d
                slots.append(SIMD2(g.footSpot.x + Double(k) * rowStep, y))
            }
        }
        return slots
    }

    private static func rack(numbers: [Int], slots: [SIMD2<Double>], geometry g: PoolTableGeometry,
                             rng: inout DeterministicRNG, jitter: Double) -> PoolTableState {
        var balls = [PoolBall(number: 0, position: breakCueSpot(g), orientation: randomOrientation(&rng))]
        for (k, n) in numbers.enumerated() {
            var p = slots[k]
            if jitter > 0 {
                let a = unit(&rng) * 2 * .pi, m = unit(&rng).squareRoot() * jitter
                p += SIMD2(cos(a), sin(a)) * m
            }
            balls.append(PoolBall(number: n, position: p, orientation: randomOrientation(&rng)))
        }
        return PoolTableState(balls: balls)
    }

    /// Balls are racked any way up, so their numbers do not all face the
    /// same way in the triangle.
    static func randomOrientation(_ rng: inout DeterministicRNG) -> simd_quatd {
        // Shoemake's uniform random rotation.
        let u1 = unit(&rng), u2 = unit(&rng) * 2 * .pi, u3 = unit(&rng) * 2 * .pi
        let a = (1 - u1).squareRoot(), b = u1.squareRoot()
        return simd_normalize(simd_quatd(ix: a * sin(u2), iy: a * cos(u2), iz: b * sin(u3), r: b * cos(u3)))
    }

    /// Uniform in [0, 1) from the top 53 bits.
    static func unit(_ rng: inout DeterministicRNG) -> Double {
        Double(rng.next() >> 11) * 0x1p-53
    }
}
