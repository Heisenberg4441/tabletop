//
//  PoolEngineStub.swift
//  A THROWAWAY stand-in for the pool engine, so the presentation can be
//  built and photographed before the real one lands.
//
//  The integration deletes this whole folder and drops in `Engine/`, which
//  implements the same API (see the engine contract in the task brief):
//  geometry, balls, shots, physics, the aiming guide, racks, rules and the
//  computer player. Nothing outside this folder may depend on anything here
//  that the contract does not name — no helper, no constant, no case beyond
//  the ones listed — and the only place that spells out engine enum cases
//  (fouls, messages, reasons) is `PoolEngineText.swift`, so reconciling a
//  different set of cases is one file's work.
//
//  What it does is deliberately crude: straight-line motion with a rolling
//  drag, elastic ball collisions, cushion reflection off the segments, a
//  capture circle per pocket, a trivial "aim at the easiest pot" computer.
//  Pure Swift, value types, Foundation and simd only, deterministic.
//

import Foundation
import simd

// MARK: - Geometry

struct PoolCushionSegment: Sendable, Equatable {
    let a: SIMD2<Double>
    let b: SIMD2<Double>
}

struct PoolPocket: Sendable {
    enum Kind: String, Sendable { case corner, side }
    let id: Int
    let kind: Kind
    let center: SIMD2<Double>
    let captureRadius: Double
    /// The two cushion noses either side of the opening.
    let mouth: (SIMD2<Double>, SIMD2<Double>)
}

struct PoolTableGeometry: Sendable {
    let length: Double
    let width: Double
    let ballRadius: Double
    let cushionNoseHeight: Double
    let cushions: [PoolCushionSegment]
    let jawTips: [SIMD2<Double>]
    let pockets: [PoolPocket]
    let headStringX: Double
    let footSpot: SIMD2<Double>
    let headSpot: SIMD2<Double>

    func kitchenContains(_ p: SIMD2<Double>) -> Bool {
        p.x < headStringX && abs(p.y) < width / 2 && p.x > -length / 2
    }

    static let standard: PoolTableGeometry = {
        let L = 2.540, W = 1.270, R = 0.028575
        let depth = 0.05                          // nose to the back of the cushion
        let c = 0.116 / 2.squareRoot()            // corner mouth 116 mm
        let jaw = depth / tan(40 * Double.pi / 180)
        let side = 0.065                          // side mouth 130 mm
        let sideLean = depth * tan(14 * Double.pi / 180)

        func A(_ sx: Double, _ sy: Double) -> SIMD2<Double> { [sx * (L / 2 - c), sy * W / 2] }
        func Aj(_ sx: Double, _ sy: Double) -> SIMD2<Double> { A(sx, sy) + [sx * jaw, sy * depth] }
        func B(_ sx: Double, _ sy: Double) -> SIMD2<Double> { [sx * L / 2, sy * (W / 2 - c)] }
        func Bj(_ sx: Double, _ sy: Double) -> SIMD2<Double> { B(sx, sy) + [sx * depth, sy * jaw] }
        func S(_ sx: Double, _ sy: Double) -> SIMD2<Double> { [sx * side, sy * W / 2] }
        func Sj(_ sx: Double, _ sy: Double) -> SIMD2<Double> { S(sx, sy) + [-sx * sideLean, sy * depth] }
        func run(_ p: [SIMD2<Double>]) -> [PoolCushionSegment] {
            (0..<(p.count - 1)).map { PoolCushionSegment(a: p[$0], b: p[$0 + 1]) }
        }
        var cushions: [PoolCushionSegment] = []
        cushions += run([Aj(-1, -1), A(-1, -1), S(-1, -1), Sj(-1, -1)])
        cushions += run([Sj(1, -1), S(1, -1), A(1, -1), Aj(1, -1)])
        cushions += run([Bj(1, -1), B(1, -1), B(1, 1), Bj(1, 1)])
        cushions += run([Aj(1, 1), A(1, 1), S(1, 1), Sj(1, 1)])
        cushions += run([Sj(-1, 1), S(-1, 1), A(-1, 1), Aj(-1, 1)])
        cushions += run([Bj(-1, 1), B(-1, 1), B(-1, -1), Bj(-1, -1)])
        let tips = [A(-1, -1), S(-1, -1), S(1, -1), A(1, -1), B(1, -1), B(1, 1),
                    A(1, 1), S(1, 1), S(-1, 1), A(-1, 1), B(-1, 1), B(-1, -1)]
        let corner = 0.02
        let pockets = [
            PoolPocket(id: 0, kind: .corner, center: [-L / 2 - corner, -W / 2 - corner], captureRadius: 0.066,
                       mouth: (A(-1, -1), B(-1, -1))),
            PoolPocket(id: 1, kind: .side, center: [0, -W / 2 - 0.042], captureRadius: 0.064,
                       mouth: (S(-1, -1), S(1, -1))),
            PoolPocket(id: 2, kind: .corner, center: [L / 2 + corner, -W / 2 - corner], captureRadius: 0.066,
                       mouth: (A(1, -1), B(1, -1))),
            PoolPocket(id: 3, kind: .corner, center: [L / 2 + corner, W / 2 + corner], captureRadius: 0.066,
                       mouth: (A(1, 1), B(1, 1))),
            PoolPocket(id: 4, kind: .side, center: [0, W / 2 + 0.042], captureRadius: 0.064,
                       mouth: (S(1, 1), S(-1, 1))),
            PoolPocket(id: 5, kind: .corner, center: [-L / 2 - corner, W / 2 + corner], captureRadius: 0.066,
                       mouth: (A(-1, 1), B(-1, 1))),
        ]
        return PoolTableGeometry(length: L, width: W, ballRadius: R, cushionNoseHeight: 0.0363,
                                 cushions: cushions, jawTips: tips, pockets: pockets,
                                 headStringX: -L / 4, footSpot: [L / 4, 0], headSpot: [-L / 4, 0])
    }()
}

// MARK: - Balls and the table

struct PoolBall: Codable, Sendable {
    let number: Int
    var position: SIMD2<Double>
    var velocity: SIMD2<Double>
    var spin: SIMD3<Double>
    var orientation: simd_quatd
    var pocket: Int?

    init(number: Int, position: SIMD2<Double>, velocity: SIMD2<Double> = .zero, spin: SIMD3<Double> = .zero,
         orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), pocket: Int? = nil) {
        self.number = number
        self.position = position
        self.velocity = velocity
        self.spin = spin
        self.orientation = orientation
        self.pocket = pocket
    }

    private enum CodingKeys: String, CodingKey { case number, position, velocity, spin, orientation, pocket }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        position = try c.decode(SIMD2<Double>.self, forKey: .position)
        velocity = (try? c.decode(SIMD2<Double>.self, forKey: .velocity)) ?? .zero
        spin = (try? c.decode(SIMD3<Double>.self, forKey: .spin)) ?? .zero
        let q = (try? c.decode([Double].self, forKey: .orientation)) ?? [0, 0, 0, 1]
        orientation = q.count == 4 ? simd_normalize(simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3]))
            : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        pocket = try c.decodeIfPresent(Int.self, forKey: .pocket)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(position, forKey: .position)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(spin, forKey: .spin)
        let v = orientation.vector
        try c.encode([v.x, v.y, v.z, v.w], forKey: .orientation)
        try c.encodeIfPresent(pocket, forKey: .pocket)
    }
}

struct PoolTableState: Codable, Sendable {
    var balls: [PoolBall]

    func ball(_ n: Int) -> PoolBall? { balls.first { $0.number == n } }
    var cueBall: PoolBall? { ball(0) }
    var isAtRest: Bool { balls.allSatisfy { $0.pocket != nil || simd_length($0.velocity) < 1e-4 } }
}

// MARK: - Shots and results

struct PoolShot: Codable, Sendable, Equatable {
    var aim: Double
    var power: Double
    var tipSide: Double
    var tipVertical: Double
}

enum PoolShotEvent: Sendable {
    case ballBall(Int, Int, time: Double)
    case cushion(Int, time: Double)
    case pocketed(Int, pocket: Int, time: Double)
}

struct PoolBallPose: Sendable {
    var position: SIMD2<Double>
    var orientation: simd_quatd
    var pocket: Int?
    var dropProgress: Double
}

struct PoolTrajectory: Sendable {
    let duration: Double
    fileprivate let step: Double
    fileprivate let numbers: [Int]
    fileprivate let positions: [[SIMD2<Double>]]           // [frame][ball]
    fileprivate let orientations: [[simd_quatd]]
    fileprivate let pocketings: [Int: (pocket: Int, time: Double)]

    func poses(at time: Double) -> [Int: PoolBallPose] {
        guard !positions.isEmpty else { return [:] }
        let t = max(0, min(time, duration))
        let f = t / step
        let i0 = min(Int(f), positions.count - 1)
        let i1 = min(i0 + 1, positions.count - 1)
        let w = min(1, max(0, f - Double(i0)))
        var poses: [Int: PoolBallPose] = [:]
        for (k, n) in numbers.enumerated() {
            let p = positions[i0][k] * (1 - w) + positions[i1][k] * w
            let q = simd_slerp(orientations[i0][k], orientations[i1][k], w)
            var pocket: Int?
            var drop = 0.0
            if let info = pocketings[n], t >= info.time {
                pocket = info.pocket
                drop = min(1, (t - info.time) / 0.35)
            }
            poses[n] = PoolBallPose(position: p, orientation: q, pocket: pocket, dropProgress: drop)
        }
        return poses
    }
}

struct PoolShotResult: Sendable {
    let events: [PoolShotEvent]
    let firstContact: Int?
    let pocketed: [(ball: Int, pocket: Int)]
    let railAfterFirstContact: Bool
    let final: PoolTableState
    let trajectory: PoolTrajectory?
}

// MARK: - Physics (crude)

enum PoolPhysics {

    static func speed(forPower power: Double) -> Double {
        0.3 + 7.7 * pow(max(0, min(1, power)), 1.6)
    }

    static func simulate(_ shot: PoolShot, from state: PoolTableState, geometry g: PoolTableGeometry = .standard,
                         record: Bool) -> PoolShotResult {
        var balls = state.balls
        let R = g.ballRadius
        guard let cueIndex = balls.firstIndex(where: { $0.number == 0 && $0.pocket == nil }) else {
            return PoolShotResult(events: [], firstContact: nil, pocketed: [], railAfterFirstContact: false,
                                  final: state, trajectory: nil)
        }
        let direction = SIMD2(cos(shot.aim), sin(shot.aim))
        let v0 = speed(forPower: shot.power)
        balls[cueIndex].velocity = direction * v0
        for i in balls.indices where i != cueIndex { balls[i].velocity = .zero }

        let dt = 1.0 / 500
        let recordEvery = 4
        var events: [PoolShotEvent] = []
        var firstContact: Int?
        var pocketed: [(ball: Int, pocket: Int)] = []
        var railAfter = false
        var cueHasHit = false
        var t = 0.0
        var step = 0
        var frames: [[SIMD2<Double>]] = []
        var turns: [[simd_quatd]] = []
        var pocketings: [Int: (pocket: Int, time: Double)] = [:]
        if record {
            frames.append(balls.map(\.position))
            turns.append(balls.map(\.orientation))
        }

        while t < 40 {
            step += 1
            t += dt
            var moving = false
            for i in balls.indices where balls[i].pocket == nil {
                var v = balls[i].velocity
                let s = simd_length(v)
                guard s > 0 else { continue }
                // Rolling resistance plus a little drag, so a break settles in
                // a handful of seconds.
                let ns = max(0, s - (0.12 + 0.12 * s) * dt)
                v = ns < 0.004 ? .zero : v * (ns / s)
                balls[i].velocity = v
                balls[i].position += v * dt
                if ns > 0 {
                    moving = true
                    let axis = SIMD3(-v.y, v.x, 0) / ns
                    balls[i].orientation = simd_normalize(simd_quatd(angle: ns * dt / R, axis: axis) * balls[i].orientation)
                }
            }
            // Ball against ball.
            for i in balls.indices where balls[i].pocket == nil {
                for j in (i + 1)..<balls.count where balls[j].pocket == nil {
                    let d = balls[j].position - balls[i].position
                    let dist = simd_length(d)
                    guard dist < 2 * R, dist > 1e-9 else { continue }
                    let n = d / dist
                    let rel = simd_dot(balls[i].velocity - balls[j].velocity, n)
                    let overlap = 2 * R - dist
                    balls[i].position -= n * overlap / 2
                    balls[j].position += n * overlap / 2
                    guard rel > 0 else { continue }
                    let impulse = (1 + 0.95) / 2 * rel
                    balls[i].velocity -= n * impulse
                    balls[j].velocity += n * impulse
                    events.append(.ballBall(balls[i].number, balls[j].number, time: t))
                    let a = balls[i].number, b = balls[j].number
                    if a == 0 || b == 0 {
                        if firstContact == nil { firstContact = a == 0 ? b : a }
                        if !cueHasHit {
                            cueHasHit = true
                            // Follow and draw, crudely: the cue ball keeps a
                            // share of its old speed along the shot line.
                            let k = a == 0 ? i : j
                            balls[k].velocity += direction * shot.tipVertical * 0.45 * rel
                        }
                    }
                    moving = true
                }
            }
            // Cushions and jaws.
            for i in balls.indices where balls[i].pocket == nil {
                for segment in g.cushions {
                    let p = balls[i].position
                    let ab = segment.b - segment.a
                    let u = max(0, min(1, simd_dot(p - segment.a, ab) / simd_length_squared(ab)))
                    let closest = segment.a + ab * u
                    let d = p - closest
                    let dist = simd_length(d)
                    guard dist < R, dist > 1e-9 else { continue }
                    let n = d / dist
                    balls[i].position = closest + n * R
                    let vn = simd_dot(balls[i].velocity, n)
                    guard vn < 0 else { continue }
                    let tangent = balls[i].velocity - n * vn
                    balls[i].velocity = tangent * 0.94 - n * vn * 0.78
                    events.append(.cushion(balls[i].number, time: t))
                    if firstContact != nil { railAfter = true }
                }
                // Pockets.
                for pocket in g.pockets where simd_distance(balls[i].position, pocket.center) < pocket.captureRadius {
                    balls[i].pocket = pocket.id
                    balls[i].velocity = .zero
                    pocketed.append((balls[i].number, pocket.id))
                    events.append(.pocketed(balls[i].number, pocket: pocket.id, time: t))
                    pocketings[balls[i].number] = (pocket.id, t)
                    break
                }
            }
            if record && step % recordEvery == 0 {
                frames.append(balls.map(\.position))
                turns.append(balls.map(\.orientation))
            }
            if !moving { break }
        }
        for i in balls.indices { balls[i].velocity = .zero; balls[i].spin = .zero }
        var trajectory: PoolTrajectory?
        if record {
            frames.append(balls.map(\.position))
            turns.append(balls.map(\.orientation))
            let last = pocketings.values.map(\.time).max() ?? 0
            let duration = max(Double(frames.count - 1) * dt * Double(recordEvery), last + 0.4)
            trajectory = PoolTrajectory(duration: duration, step: dt * Double(recordEvery),
                                        numbers: balls.map(\.number), positions: frames,
                                        orientations: turns, pocketings: pocketings)
        }
        return PoolShotResult(events: events, firstContact: firstContact, pocketed: pocketed,
                              railAfterFirstContact: railAfter, final: PoolTableState(balls: balls),
                              trajectory: trajectory)
    }
}

// MARK: - The aiming guide

struct PoolAimPrediction: Sendable {
    var ghostBallCenter: SIMD2<Double>
    var targetBall: Int?
    var objectBallDirection: SIMD2<Double>?
    var cueBallDeflection: SIMD2<Double>?
    var cushionPoint: SIMD2<Double>?
}

enum PoolAimGuide {
    static func predict(aim: Double, from state: PoolTableState,
                        geometry g: PoolTableGeometry = .standard) -> PoolAimPrediction {
        let R = g.ballRadius
        let dir = SIMD2(cos(aim), sin(aim))
        guard let cue = state.cueBall, cue.pocket == nil else {
            return PoolAimPrediction(ghostBallCenter: .zero)
        }
        var best = Double.infinity
        var target: PoolBall?
        for ball in state.balls where ball.number != 0 && ball.pocket == nil {
            let rel = ball.position - cue.position
            let along = simd_dot(rel, dir)
            guard along > 0 else { continue }
            let perp2 = simd_length_squared(rel) - along * along
            let reach = 4 * R * R
            guard perp2 < reach else { continue }
            let t = along - (reach - perp2).squareRoot()
            if t < best { best = t; target = ball }
        }
        // Where the cue ball would meet a cushion.
        var wall = Double.infinity
        for segment in g.cushions {
            let ab = segment.b - segment.a
            let normal = simd_normalize(SIMD2(-ab.y, ab.x))
            for side in [1.0, -1.0] {
                let n = normal * side
                let a = segment.a + n * R
                let denom = dir.x * ab.y - dir.y * ab.x
                guard abs(denom) > 1e-9 else { continue }
                let w = a - cue.position
                let t = (w.x * ab.y - w.y * ab.x) / denom
                let u = (w.x * dir.y - w.y * dir.x) / denom
                if t > 1e-6, u >= 0, u <= 1, t < wall { wall = t }
            }
        }
        if let target, best < wall {
            let ghost = cue.position + dir * best
            let objectDirection = simd_normalize(target.position - ghost)
            var deflection = dir - objectDirection * simd_dot(dir, objectDirection)
            deflection = simd_length(deflection) > 1e-6 ? simd_normalize(deflection) : .zero
            return PoolAimPrediction(ghostBallCenter: ghost, targetBall: target.number,
                                     objectBallDirection: objectDirection,
                                     cueBallDeflection: simd_length(deflection) > 0 ? deflection : nil,
                                     cushionPoint: nil)
        }
        let end = cue.position + dir * (wall.isFinite ? wall : 1)
        return PoolAimPrediction(ghostBallCenter: end, targetBall: nil, objectBallDirection: nil,
                                 cueBallDeflection: nil, cushionPoint: end)
    }
}

// MARK: - Racks

enum PoolMode: String, Codable, Sendable { case eightBall, nineBall, practice }
enum PoolDifficulty: String, Codable, CaseIterable, Sendable { case easy, medium, hard }
enum PoolGroup: String, Codable, Sendable { case solids, stripes }

enum PoolRack {

    private static func spot(row: Int, index: Int, g: PoolTableGeometry, rng: inout DeterministicRNG) -> SIMD2<Double> {
        let R = g.ballRadius
        let gap = 0.0002
        let x = g.footSpot.x + Double(row) * (2 * R + gap) * 3.0.squareRoot() / 2
        let y = (Double(index) - Double(row) / 2) * (2 * R + gap)
        let jitter = SIMD2(Double(rng.next(upperBound: 100)) - 50, Double(rng.next(upperBound: 100)) - 50) * 2e-6
        return SIMD2(x, y) + jitter
    }

    private static func orientation(_ rng: inout DeterministicRNG) -> simd_quatd {
        let a = Double(rng.next(upperBound: 6283)) / 1000
        let b = Double(rng.next(upperBound: 3141)) / 1000 - 1.57
        return simd_normalize(simd_quatd(angle: a, axis: [0, 0, 1]) * simd_quatd(angle: b * 0.5, axis: [1, 0, 0]))
    }

    private static func cue(_ g: PoolTableGeometry) -> PoolBall {
        PoolBall(number: 0, position: [g.headStringX - 0.06, 0.02])
    }

    static func eightBall(seed: UInt64) -> PoolTableState {
        let g = PoolTableGeometry.standard
        var rng = DeterministicRNG(seed: seed)
        var solids = Array(1...7), stripes = Array(9...15)
        rng.shuffle(&solids)
        rng.shuffle(&stripes)
        // The back corners: one of each.
        let leftSolid = rng.next(upperBound: 2) == 0
        let cornerA = leftSolid ? solids.removeLast() : stripes.removeLast()
        let cornerB = leftSolid ? stripes.removeLast() : solids.removeLast()
        var rest = solids + stripes
        rng.shuffle(&rest)
        var balls = [cue(g)]
        for row in 0..<5 {
            for i in 0...row {
                let number: Int
                if row == 2 && i == 1 { number = 8 }
                else if row == 4 && i == 0 { number = cornerA }
                else if row == 4 && i == 4 { number = cornerB }
                else { number = rest.removeLast() }
                balls.append(PoolBall(number: number, position: spot(row: row, index: i, g: g, rng: &rng),
                                      orientation: orientation(&rng)))
            }
        }
        return PoolTableState(balls: balls)
    }

    static func nineBall(seed: UInt64) -> PoolTableState {
        let g = PoolTableGeometry.standard
        var rng = DeterministicRNG(seed: seed)
        var rest = [2, 3, 4, 5, 6, 7, 8]
        rng.shuffle(&rest)
        let layout: [(Int, Int)] = [(0, 0), (1, 0), (1, 1), (2, 0), (2, 1), (2, 2), (3, 0), (3, 1), (4, 0)]
        var balls = [cue(g)]
        for (k, (row, index)) in layout.enumerated() {
            // A diamond: rows of 1, 2, 3, 2, 1.
            let width = row <= 2 ? row : 4 - row
            let i = Double(index) - Double(width) / 2
            let base = spot(row: row, index: 0, g: g, rng: &rng)
            let position = SIMD2(base.x, i * (2 * g.ballRadius + 0.0002))
            let number = k == 0 ? 1 : (k == 4 ? 9 : rest.removeLast())
            balls.append(PoolBall(number: number, position: position, orientation: orientation(&rng)))
        }
        return PoolTableState(balls: balls)
    }

    static func practice(seed: UInt64) -> PoolTableState {
        eightBall(seed: seed)
    }
}

// MARK: - Rules (trivial)

enum PoolBallInHand: String, Codable, Sendable { case kitchen, anywhere }
enum PoolFoul: String, Codable, Sendable { case scratch, noContact, wrongBallFirst, noRail }
enum PoolGameOverReason: String, Sendable { case eightPocketed, eightEarly, eightOnFoul, ninePocketed }

enum PoolRuleMessage: Sendable, Equatable {
    case foul(PoolFoul)
    case groupAssigned(player: Int, group: PoolGroup)
    case tableOpen
    case eightRespotted
    case nineRespotted
    case cueBallRespotted
}

struct PoolRuleState: Codable, Sendable {
    var mode: PoolMode
    var shooter: Int
    var groups: [PoolGroup?]
    var isBreakShot: Bool
    var ballInHand: PoolBallInHand?
    var winner: Int?
    var lastFoul: PoolFoul?
    var shotCount: Int
}

struct PoolTurnOutcome: Sendable {
    var newState: PoolRuleState
    var table: PoolTableState
    var foul: PoolFoul?
    var continuesTurn: Bool
    var groupAssigned: PoolGroup?
    var gameOver: (winner: Int, reason: PoolGameOverReason)?
    var messages: [PoolRuleMessage]
}

enum PoolRules {

    static func newGame(_ mode: PoolMode, breaker: Int) -> PoolRuleState {
        PoolRuleState(mode: mode, shooter: mode == .practice ? 0 : breaker, groups: [nil, nil], isBreakShot: true,
                      ballInHand: mode == .practice ? nil : .kitchen, winner: nil, lastFoul: nil, shotCount: 0)
    }

    private static func group(of n: Int) -> PoolGroup? {
        (1...7).contains(n) ? .solids : ((9...15).contains(n) ? .stripes : nil)
    }

    private static func remaining(_ group: PoolGroup, _ table: PoolTableState) -> Int {
        table.balls.filter { $0.pocket == nil && Self.group(of: $0.number) == group }.count
    }

    static func legalFirstContacts(_ s: PoolRuleState, table: PoolTableState) -> Set<Int> {
        let onTable = Set(table.balls.filter { $0.pocket == nil && $0.number != 0 }.map(\.number))
        switch s.mode {
        case .practice: return onTable
        case .nineBall: return onTable.min().map { [$0] } ?? []
        case .eightBall:
            guard let mine = s.groups[safeIndex: s.shooter] ?? nil else { return onTable.subtracting([8]) }
            let own = onTable.filter { group(of: $0) == mine }
            return own.isEmpty ? onTable.intersection([8]) : own
        }
    }

    static func isValidPlacement(_ p: SIMD2<Double>, _ s: PoolRuleState, table: PoolTableState,
                                 geometry g: PoolTableGeometry = .standard) -> Bool {
        let R = g.ballRadius
        guard abs(p.x) <= g.length / 2 - R, abs(p.y) <= g.width / 2 - R else { return false }
        if s.ballInHand == .kitchen, !g.kitchenContains(p) { return false }
        for ball in table.balls where ball.number != 0 && ball.pocket == nil {
            if simd_distance(ball.position, p) < 2 * R { return false }
        }
        return true
    }

    static func evaluate(_ r: PoolShotResult, before: PoolTableState, state s: PoolRuleState) -> PoolTurnOutcome {
        var table = r.final
        var next = s
        next.shotCount += 1
        next.isBreakShot = false
        next.ballInHand = nil
        var messages: [PoolRuleMessage] = []
        let pocketed = r.pocketed.map(\.ball)
        let scratch = pocketed.contains(0)

        if s.mode == .practice {
            if scratch, let i = table.balls.firstIndex(where: { $0.number == 0 }) {
                table.balls[i].pocket = nil
                table.balls[i].position = PoolTableGeometry.standard.headSpot
                messages.append(.cueBallRespotted)
            }
            next.lastFoul = nil
            return PoolTurnOutcome(newState: next, table: table, foul: nil, continuesTurn: true, groupAssigned: nil,
                                   gameOver: nil, messages: messages)
        }

        let legal = legalFirstContacts(s, table: before)
        var foul: PoolFoul?
        if scratch { foul = .scratch }
        else if r.firstContact == nil { foul = .noContact }
        else if let first = r.firstContact, !legal.contains(first) { foul = .wrongBallFirst }
        else if pocketed.isEmpty && !r.railAfterFirstContact && !s.isBreakShot { foul = .noRail }

        var gameOver: (winner: Int, reason: PoolGameOverReason)?
        var assigned: PoolGroup?
        var continues = false
        let other = 1 - s.shooter

        switch s.mode {
        case .nineBall:
            if pocketed.contains(9) {
                if foul == nil {
                    gameOver = (s.shooter, .ninePocketed)
                } else if let i = table.balls.firstIndex(where: { $0.number == 9 }) {
                    table.balls[i].pocket = nil
                    table.balls[i].position = PoolTableGeometry.standard.footSpot
                    messages.append(.nineRespotted)
                }
            }
            continues = foul == nil && pocketed.contains { $0 != 0 }
        case .eightBall:
            if pocketed.contains(8) {
                if s.isBreakShot && foul == nil, let i = table.balls.firstIndex(where: { $0.number == 8 }) {
                    table.balls[i].pocket = nil
                    table.balls[i].position = PoolTableGeometry.standard.footSpot
                    messages.append(.eightRespotted)
                } else if let mine = s.groups[safeIndex: s.shooter] ?? nil, remaining(mine, before) == 0, foul == nil {
                    gameOver = (s.shooter, .eightPocketed)
                } else {
                    gameOver = (other, foul == nil ? .eightEarly : .eightOnFoul)
                }
            }
            if gameOver == nil, foul == nil, !s.isBreakShot, s.groups[s.shooter] == nil,
               let first = pocketed.first(where: { group(of: $0) != nil }), let g = group(of: first) {
                next.groups[s.shooter] = g
                next.groups[other] = g == .solids ? .stripes : .solids
                assigned = g
                messages.append(.groupAssigned(player: s.shooter, group: g))
            }
            let mine = next.groups[s.shooter]
            continues = foul == nil && pocketed.contains { n in
                n != 0 && n != 8 && (mine == nil || group(of: n) == mine)
            }
        case .practice:
            break
        }

        if let foul {
            messages.append(.foul(foul))
            next.ballInHand = .anywhere
            if let i = table.balls.firstIndex(where: { $0.number == 0 }), table.balls[i].pocket != nil {
                table.balls[i].pocket = nil
                table.balls[i].position = PoolTableGeometry.standard.headSpot
            }
        }
        next.lastFoul = foul
        if let gameOver {
            next.winner = gameOver.winner
        } else if !continues {
            next.shooter = other
        }
        return PoolTurnOutcome(newState: next, table: table, foul: foul, continuesTurn: continues && gameOver == nil,
                               groupAssigned: assigned, gameOver: gameOver, messages: messages)
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - The computer (trivial)

struct PoolAIDecision: Sendable {
    var placement: SIMD2<Double>?
    var shot: PoolShot
}

enum PoolAI {

    static func decide(table: PoolTableState, rules: PoolRuleState, difficulty: PoolDifficulty,
                       seed: UInt64) -> PoolAIDecision {
        let g = PoolTableGeometry.standard
        let R = g.ballRadius
        var rng = DeterministicRNG(seed: seed)
        var table = table
        var placement: SIMD2<Double>?
        let targets = PoolRules.legalFirstContacts(rules, table: table)
        if rules.ballInHand != nil {
            // Put the cue ball a little behind the easiest-looking target, or
            // in the kitchen for the break.
            var spot = SIMD2(g.headStringX - 0.1, 0.0)
            if rules.ballInHand == .anywhere, let t = targets.sorted().first, let ball = table.ball(t) {
                let pocket = g.pockets.min { simd_distance($0.center, ball.position) < simd_distance($1.center, ball.position) }
                if let pocket {
                    let away = simd_normalize(ball.position - pocket.center)
                    let candidate = ball.position + away * 0.3
                    if PoolRules.isValidPlacement(candidate, rules, table: table) { spot = candidate }
                }
            }
            if !PoolRules.isValidPlacement(spot, rules, table: table) { spot = [g.headStringX - 0.2, 0.25] }
            placement = spot
            if let i = table.balls.firstIndex(where: { $0.number == 0 }) {
                table.balls[i].position = spot
                table.balls[i].pocket = nil
            }
        }
        guard let cue = table.cueBall else {
            return PoolAIDecision(placement: placement, shot: PoolShot(aim: 0, power: 0.5, tipSide: 0, tipVertical: 0))
        }
        if rules.isBreakShot {
            let aim = atan2(g.footSpot.y - cue.position.y, g.footSpot.x - cue.position.x)
            return PoolAIDecision(placement: placement, shot: PoolShot(aim: aim, power: 0.95, tipSide: 0, tipVertical: 0.1))
        }
        var best: (score: Double, aim: Double, power: Double)?
        for number in targets {
            guard let ball = table.ball(number) else { continue }
            for pocket in g.pockets {
                let toPocket = pocket.center - ball.position
                let ghost = ball.position - simd_normalize(toPocket) * 2 * R
                let toGhost = ghost - cue.position
                let cut = acos(max(-1, min(1, simd_dot(simd_normalize(toGhost), simd_normalize(toPocket)))))
                guard cut < 1.2 else { continue }
                let score = cos(cut) / (1 + simd_length(toGhost) + simd_length(toPocket))
                if best == nil || score > best!.score {
                    let distance = simd_length(toGhost) + simd_length(toPocket)
                    best = (score, atan2(toGhost.y, toGhost.x), min(0.9, 0.25 + distance * 0.18))
                }
            }
        }
        let sigma: Double
        switch difficulty {
        case .easy: sigma = 1.2
        case .medium: sigma = 0.45
        case .hard: sigma = 0.12
        }
        let noise = (Double(rng.next(upperBound: 2001)) / 1000 - 1) * sigma * Double.pi / 180
        if let best {
            return PoolAIDecision(placement: placement,
                                  shot: PoolShot(aim: best.aim + noise, power: best.power, tipSide: 0, tipVertical: 0))
        }
        let any = targets.compactMap { table.ball($0) }.first
        let aim = any.map { atan2($0.position.y - cue.position.y, $0.position.x - cue.position.x) } ?? 0
        return PoolAIDecision(placement: placement, shot: PoolShot(aim: aim, power: 0.4, tipSide: 0, tipVertical: 0))
    }
}

// MARK: - Engine tests (the stub's own, minimal)

enum PoolEngineTests {
    static func run(_ t: TestReporter) {
        t.section("Pool engine (stub)")
        let g = PoolTableGeometry.standard
        t.check("six pockets and eighteen cushion segments", g.pockets.count == 6 && g.cushions.count == 18)
        let rack = PoolRack.eightBall(seed: 7)
        t.check("an eight-ball rack has sixteen balls", rack.balls.count == 16)
        var straight = PoolTableState(balls: [PoolBall(number: 0, position: [0.2, 0]),
                                              PoolBall(number: 1, position: [0.8, 0])])
        let shot = PoolShot(aim: 0, power: 0.5, tipSide: 0, tipVertical: 0)
        let a = PoolPhysics.simulate(shot, from: straight, record: true)
        let b = PoolPhysics.simulate(shot, from: straight, record: true)
        t.check("the same shot twice comes out the same", a.final.balls.map(\.position) == b.final.balls.map(\.position))
        t.check("a straight shot contacts the object ball first", a.firstContact == 1)
        let corner = g.pockets[3].center
        straight.balls[1].position = straight.balls[0].position + (corner - straight.balls[0].position) * 0.75
        let aim = atan2(corner.y - straight.balls[0].position.y, corner.x - straight.balls[0].position.x)
        let pot = PoolPhysics.simulate(PoolShot(aim: aim, power: 0.4, tipSide: 0, tipVertical: 0), from: straight, record: false)
        t.check("a straight-in shot pockets the object ball", pot.pocketed.contains { $0.ball == 1 })
    }
}
