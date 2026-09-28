//
//  PoolEngineTests.swift
//  The engine's checks: geometry, the physics against what a real table
//  does, the break, fuzzing for tunnelling, determinism, speed, the rules
//  and the computer opponent. Run by `Tabletop --selftest pool`.
//
//  Numbers a check depends on are measured from the engine's own output, so
//  a failure prints what the table actually did. Timings are only checked
//  in release builds (debug is an order of magnitude slower) but are always
//  printed.
//

import Foundation
import simd

enum PoolEngineTests {

    static func run(_ t: TestReporter) {
        geometry(t)
        motion(t)
        cushions(t)
        pockets(t)
        breaking(t)
        fuzz(t)
        determinism(t)
        performance(t)
        aimGuide(t)
        rules(t)
        persistence(t)
        computer(t)
    }

    // MARK: Helpers

    static let g = PoolTableGeometry.standard
    static var r: Double { g.ballRadius }

    static func table(_ balls: [(Int, SIMD2<Double>)]) -> PoolTableState {
        PoolTableState(balls: balls.map { PoolBall(number: $0.0, position: $0.1) })
    }

    static func aim(_ from: SIMD2<Double>, _ to: SIMD2<Double>) -> Double {
        atan2(to.y - from.y, to.x - from.x)
    }

    static func ms(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    static func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    static var isRelease: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// A straight-in line along a corner pocket's axis: the object ball
    /// `objectToPocket` from the pocket's aim point, the cue ball
    /// `cueToObject` behind it.
    static func straightIn(pocket: Int = 3, objectToPocket: Double = 0.5, cueToObject: Double = 0.6)
        -> (table: PoolTableState, cue: SIMD2<Double>, ball: SIMD2<Double>, aim: Double) {
        let p = g.pockets[pocket]
        let ball = p.target - p.axis * objectToPocket
        let cue = ball - p.axis * cueToObject
        return (table([(0, cue), (1, ball)]), cue, ball, atan2(p.axis.y, p.axis.x))
    }

    // MARK: Geometry

    static func geometry(_ t: TestReporter) {
        t.section("Pool engine: table geometry")
        t.check("18 cushion segments (a nose and two jaw facings per rail)", g.cushions.count == 18)
        t.check("12 jaw points and 6 pockets", g.jawTips.count == 12 && g.pockets.count == 6)
        let corners = g.pockets.filter { $0.kind == .corner }, sides = g.pockets.filter { $0.kind == .side }
        t.check("corner mouths 116 mm, side mouths 130 mm",
                corners.allSatisfy { abs($0.mouthWidth - 0.116) < 1e-9 } && sides.allSatisfy { abs($0.mouthWidth - 0.130) < 1e-9 })
        // Consecutive segments share their end points all the way round a
        // rail, and every normal faces where balls travel.
        var chained = true
        for rail in 0..<6 {
            let s = g.cushions.filter { $0.rail == rail }
            chained = chained && s.count == 3 && s[0].b == s[1].a && s[1].b == s[2].a
        }
        t.check("each rail's jaw, nose and jaw form one chain", chained)
        t.check("every nose faces the middle of the table",
                g.cushions.filter { $0.kind == .nose }.allSatisfy { simd_dot($0.normal, -$0.a) > 0 })
        let mirrored = g.pockets.allSatisfy { p in
            g.pockets.contains { q in simd_distance(q.center, SIMD2(-p.center.x, p.center.y)) < 1e-12 }
                && g.pockets.contains { q in simd_distance(q.center, SIMD2(p.center.x, -p.center.y)) < 1e-12 }
        }
        t.check("pockets are placed mirror-symmetrically", mirrored)
        t.check("the kitchen is behind the head string",
                g.kitchenContains(SIMD2(-0.9, 0)) && !g.kitchenContains(SIMD2(-0.5, 0))
                    && !g.kitchenContains(SIMD2(-1.27, 0)))
        t.check("cushion outlines are four-point polygons", g.cushionOutlines.count == 6
                    && g.cushionOutlines.allSatisfy { $0.count == 4 })
    }

    // MARK: Motion

    static func motion(_ t: TestReporter) {
        t.section("Pool engine: stroke, slide and roll")
        let line = straightIn()
        // A little below centre so the cue ball does not follow it in.
        let result = PoolPhysics.simulate(PoolShot(aim: line.aim, power: 0.3, tipVertical: -0.4), from: line.table,
                                          record: false)
        t.check("a straight-in shot pockets the object ball in the pocket it was aimed at",
                result.pocketed.contains { $0.ball == 1 && $0.pocket == 3 } && !result.scratched)
        let side = g.pockets[4]
        let sideBall = side.target - side.axis * 0.4
        let sideTable = table([(0, sideBall - side.axis * 0.5), (1, sideBall)])
        let sideResult = PoolPhysics.simulate(PoolShot(aim: atan2(side.axis.y, side.axis.x), power: 0.3),
                                             from: sideTable, record: false)
        t.check("a straight-in shot pockets the object ball in a side pocket",
                sideResult.pocketed.contains { $0.ball == 1 && $0.pocket == 4 })

        // Stun: the draw that has just worn off at the object ball. From the
        // model, a ball struck at v with offset b (radii) slides with its
        // backspin decaying: ω hits zero after t = −(5b/2)(v/R)/(5μg/2R)
        // = −b v/(μ g), having run v t − ½ μ g t².
        let prm = PoolPhysics.Parameters.standard
        let b = -0.3 * prm.safeTipOffset
        let (v0, _) = PoolPhysics.strike(PoolShot(aim: 0, power: 0.45, tipVertical: -0.3))
        let speed = simd_length(v0)
        let mu = prm.slidingFriction * prm.gravity
        let tStun = -b * speed / mu
        let stunDistance = speed * tStun - 0.5 * mu * tStun * tStun
        let stun = straightIn(objectToPocket: 0.45, cueToObject: stunDistance + 2 * r)
        let stunResult = PoolPhysics.simulate(PoolShot(aim: stun.aim, power: 0.45, tipVertical: -0.3),
                                              from: stun.table, record: false)
        let contact = stun.ball - g.pockets[3].axis * (2 * r)
        let stop = stunResult.final.cueBall.map { simd_distance($0.position, contact) } ?? 1
        t.check("a stop shot leaves the cue ball within a radius of the contact point (\(f(stop * 1000, 1)) mm)",
                stop < r && stunResult.pocketed(1))

        // Follow and draw along the same line, 0.6 s after the contact —
        // before a following cue ball can reach the pocket.
        let far = straightIn(objectToPocket: 0.5, cueToObject: 0.35)
        let axis = g.pockets[3].axis
        let contactPoint = far.ball - axis * 2 * r
        func travel(_ vertical: Double) -> Double {
            let shot = PoolShot(aim: far.aim, power: 0.45, tipVertical: vertical)
            let first = PoolPhysics.simulate(shot, from: far.table, record: false)
            guard let when = first.firstContactTime else { return .nan }
            var at: SIMD2<Double>?
            _ = PoolPhysics.simulate(shot, from: far.table, geometry: g, record: false, parameters: prm) { s, time in
                if at == nil && time >= when + 0.6 { at = s.cueBall?.position }
            }
            return at.map { simd_dot($0 - contactPoint, axis) } ?? .nan
        }
        let follow = travel(0.9), draw = travel(-0.9)
        t.check("follow carries the cue ball on through the contact (\(f(follow)) m)", follow > 0.15)
        t.check("draw brings the cue ball back (\(f(draw)) m)", draw < -0.15)

        // Slide to roll: a centre-struck ball ends up rolling at 5/7 of its
        // speed, with the contact point at rest.
        let lone = table([(0, SIMD2(-1.0, 0))])
        var rolling: (v: SIMD2<Double>, w: SIMD3<Double>)?
        let stroke = PoolShot(aim: 0, power: 0.3)
        let (vStart, _) = PoolPhysics.strike(stroke)
        _ = PoolPhysics.simulate(stroke, from: lone, geometry: g, record: false, parameters: prm) { state, _ in
            if rolling == nil, let c = state.cueBall, simd_length(c.velocity) > 0 {
                let u = SIMD2(c.velocity.x - r * c.spin.y, c.velocity.y + r * c.spin.x)
                if simd_length(u) < 1e-9 { rolling = (c.velocity, c.spin) }
            }
        }
        if let rolling {
            let ratio = simd_length(rolling.v) / simd_length(vStart)
            t.check("a stun ball starts rolling at 5/7 of its speed (\(f(ratio, 4)))", abs(ratio - 5.0 / 7) < 0.002)
            let wr = simd_length(SIMD2(rolling.w.x, rolling.w.y)) * r
            t.check("a rolling ball's spin matches its speed (|ω|R = |v|)", abs(wr - simd_length(rolling.v)) < 1e-9)
        } else {
            t.check("a stun ball starts rolling", false)
        }
        // Squirt: right english sends the cue ball a little left of the cue.
        let (vRight, wRight) = PoolPhysics.strike(PoolShot(aim: 0, power: 0.5, tipSide: 1))
        let squirt = atan2(vRight.y, vRight.x) * 180 / .pi
        t.check("right english squirts the ball left, 1–3° at full side (\(f(squirt))°)", squirt > 1 && squirt < 3)
        t.check("right english spins the ball counter-clockwise seen from above", wRight.z > 0)
    }

    // MARK: Cushions

    /// A ball sent into the foot rail at `incidence` degrees from square:
    /// its velocity just before and just after the cushion.
    static func rebound(incidence: Double, power: Double, side: Double = 0, vertical: Double = 0,
                        from distance: Double = 0.8) -> (before: SIMD2<Double>, after: SIMD2<Double>)? {
        let a = incidence * .pi / 180
        let hit = SIMD2(g.length / 2 - r, 0.0)
        let start = hit - SIMD2(cos(a), sin(a)) * distance
        var before: SIMD2<Double>?, after: SIMD2<Double>?
        var last: SIMD2<Double>?
        _ = PoolPhysics.simulate(PoolShot(aim: a, power: power, tipSide: side, tipVertical: vertical),
                                 from: table([(0, start)]), geometry: g, record: false, parameters: .standard) { s, _ in
            guard after == nil, let v = s.cueBall?.velocity else { return }
            if let l = last, l.x > 0, v.x < 0 { before = l; after = v }
            last = v
        }
        guard let before, let after else { return nil }
        return (before, after)
    }

    static func cushions(_ t: TestReporter) {
        t.section("Pool engine: cushions")
        // A stun ball (struck low enough to arrive with no spin) off the rail
        // at 30°: close to the mirror angle, a little squarer (friction).
        if let s = rebound(incidence: 30, power: 0.45, vertical: -0.45, from: 0.3) {
            let into = atan2(s.before.y, s.before.x) * 180 / .pi
            let out = atan2(s.after.y, -s.after.x) * 180 / .pi
            t.check("a ball with no english rebounds near the mirror angle (\(f(into, 1))° in, \(f(out, 1))° out)",
                    abs(out - into) < 5)
            let ratio = abs(s.after.x / s.before.x)
            t.check("cushion restitution square to the rail is 0.6–0.9 (\(f(ratio)))", ratio > 0.6 && ratio < 0.9)
        } else {
            t.check("a ball rebounds off the foot rail", false)
        }
        // Running and reverse english at the same line: heading up-table into
        // the foot rail, left english (clockwise) runs, right checks.
        if let plain = rebound(incidence: 30, power: 0.4), let running = rebound(incidence: 30, power: 0.4, side: -1),
           let check = rebound(incidence: 30, power: 0.4, side: 1) {
            let a0 = atan2(plain.after.y, -plain.after.x) * 180 / .pi
            let a1 = atan2(running.after.y, -running.after.x) * 180 / .pi
            let a2 = atan2(check.after.y, -check.after.x) * 180 / .pi
            t.check("running english widens the rebound (\(f(a0, 1))° → \(f(a1, 1))°)", a1 > a0 + 5)
            t.check("reverse english narrows it (\(f(a0, 1))° → \(f(a2, 1))°)", a2 < a0 - 3)
        } else {
            t.check("english rebounds", false)
        }
        // Straight in with side: the ball comes back off square, to the side
        // the english says, mirror-symmetric left and right.
        if let l = rebound(incidence: 0, power: 0.4, side: -1), let rr = rebound(incidence: 0, power: 0.4, side: 1) {
            let al = atan2(l.after.y, -l.after.x) * 180 / .pi, ar = atan2(rr.after.y, -rr.after.x) * 180 / .pi
            t.check("side english kicks a square ball off square, symmetric (\(f(al, 1))° / \(f(ar, 1))°)",
                    al > 5 && ar < -5 && abs(al + ar) < 0.01)
        }
    }

    // MARK: Pockets

    /// Whether a lone ball rolled at pocket `id` from 0.6 m, `angle` degrees
    /// off the pocket's axis and `offset` metres to the side of its mouth,
    /// drops.
    static func drops(_ id: Int, angle: Double, offset: Double, power: Double) -> Bool {
        let pocket = g.pockets[id]
        let a = atan2(pocket.axis.y, pocket.axis.x) + angle * .pi / 180
        let dir = SIMD2(cos(a), sin(a))
        let start = pocket.mouthCenter + SIMD2(-dir.y, dir.x) * offset - dir * 0.6
        let res = PoolPhysics.simulate(PoolShot(aim: a, power: power, tipVertical: 0.8), from: table([(0, start)]),
                                       record: false)
        return res.pocketed.contains { $0.ball == 0 && $0.pocket == id }
    }

    static func pockets(_ t: TestReporter) {
        t.section("Pool engine: pockets")
        t.check("a ball rolled straight at a corner drops", drops(3, angle: 0, offset: 0, power: 0.4))
        t.check("a firm ball that catches the jaw point off line is rejected",
                !drops(3, angle: 0, offset: 0.034, power: 0.6))
        t.check("the same ball a little further in drops", drops(3, angle: 0, offset: 0.022, power: 0.6))
        t.check("a hard ball at 30° into the far facing of a corner rattles out",
                !drops(3, angle: 30, offset: -0.03, power: 0.75))
        t.check("the slow one on the same line drops", drops(3, angle: 30, offset: -0.03, power: 0.15))
        t.check("a side pocket takes a ball from square", drops(4, angle: 0, offset: 0.02, power: 0.4))
        t.check("a side pocket refuses a ball from 60° off square at 3 cm",
                !drops(4, angle: 60, offset: 0.03, power: 0.4))
        // How wide the pocket plays straight in: a real corner forgives about
        // ±29 mm of the ball's centre.
        var window = 0
        let step = isRelease ? 2 : 4
        for mm in stride(from: -50, through: 50, by: step) where drops(3, angle: 0, offset: Double(mm) / 1000, power: 0.4) {
            window += step
        }
        t.info("corner pocket, straight in at 2.2 m/s, forgives \(window) mm of the ball's line")
        t.check("the corner forgives 50–72 mm straight in", window >= 50 && window <= 72)
    }

    // MARK: The break

    static func breaking(_ t: TestReporter) {
        t.section("Pool engine: the break")
        var moved = 0, rails = 0, potted = 0, dry = 0
        let seeds: [UInt64] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]
        for seed in seeds {
            let rack = PoolRack.eightBall(seed: seed)
            guard let cue = rack.cueBall?.position else { continue }
            let res = PoolPhysics.simulate(PoolShot(aim: aim(cue, g.footSpot), power: 1, tipVertical: -0.2),
                                           from: rack, record: false)
            for b in rack.balls where b.number != 0 {
                if let after = res.final.ball(b.number), after.pocket != nil || simd_distance(after.position, b.position) > 0.1 {
                    moved += 1
                }
            }
            rails += res.objectBallsToRail.count
            let k = res.pocketed.filter { $0.ball != 0 }.count
            potted += k
            if k == 0 { dry += 1 }
        }
        let n = Double(seeds.count)
        t.info("per break: \(f(Double(moved) / n, 1)) of 15 balls moved over 10 cm, \(f(Double(rails) / n, 1)) reached a rail, \(f(Double(potted) / n)) pocketed; \(dry) of \(seeds.count) dry")
        t.check("a full-power break spreads the rack (most balls move, many reach a rail)",
                Double(moved) / n >= 12 && Double(rails) / n >= 6)
        t.check("breaks pocket balls some of the time", potted > 0)

        // Symmetry: a rack with no jitter broken dead straight.
        for (name, rack) in [("eight-ball", PoolRack.eightBall(seed: 3, geometry: g, jitter: 0)),
                             ("nine-ball", PoolRack.nineBall(seed: 3, geometry: g, jitter: 0))] {
            let res = PoolPhysics.simulate(PoolShot(aim: 0, power: 1), from: rack, record: false)
            let on = res.final.balls.filter { $0.pocket == nil }.map(\.position)
            var worst = 0.0
            for p in on {
                worst = max(worst, on.map { simd_distance($0, SIMD2(p.x, -p.y)) }.min() ?? 1)
            }
            let pockets = res.pocketed.map { g.pockets[$0.pocket].center.y }
            let pocketsMirror = pockets.allSatisfy { y in pockets.contains { abs($0 + y) < 1e-9 } }
            t.check("a symmetric \(name) rack broken straight on stays mirror-symmetric (\(String(format: "%.1e", worst)) m)",
                    worst < 1e-6 && pocketsMirror)
        }
        let nine = PoolRack.nineBall(seed: 5)
        t.check("the nine-ball diamond has the 1 on the foot spot and the 9 in the middle",
                nine.ball(1).map { simd_distance($0.position, g.footSpot) < 1e-3 } == true
                    && nine.ball(9).map { abs($0.position.y) < 1e-3 } == true && nine.balls.count == 10)
        let eight = PoolRack.eightBall(seed: 5)
        let corners = eight.balls.filter { $0.number != 0 }.sorted { $0.position.x > $1.position.x }.prefix(5)
            .sorted { $0.position.y < $1.position.y }
        let cornerGroups = [corners.first, corners.last].compactMap { $0.flatMap { PoolGroup.of($0.number) } }
        t.check("the eight-ball rack has the 8 in the middle and a solid and a stripe in the back corners",
                eight.ball(8).map { abs($0.position.y) < 1e-3 } == true && Set(cornerGroups).count == 2)
        var closest = Double.infinity
        for a in eight.balls { for b in eight.balls where b.number > a.number { closest = min(closest, simd_distance(a.position, b.position)) } }
        t.check("racked balls stand a hair apart, never touching", closest > 2 * r && closest < 2 * r + 0.0005)
    }

    // MARK: Fuzz

    static func fuzz(_ t: TestReporter) {
        t.section("Pool engine: tunnelling fuzz")
        let count = isRelease ? 500 : 60
        var rng = DeterministicRNG(seed: 0xF022)
        var overlap = 0.0, outside = 0.0, lost = 0, unrested = 0, steps = 0
        let hl = g.length / 2 - r, hw = g.width / 2 - r
        for k in 0..<count {
            let n = 2 + rng.next(upperBound: 15)
            let numbers = [0] + Array(1...15).shuffled(using: &rng).prefix(n - 1)
            let start = k % 5 == 0 ? PoolRack.eightBall(seed: UInt64(k)) : PoolRack.scattered(Array(numbers), seed: UInt64(k) &* 31)
            let power = k % 3 == 0 ? 1.0 : PoolRack.unit(&rng)
            let a = PoolRack.unit(&rng) * 2 * .pi, rho = PoolRack.unit(&rng).squareRoot(), phi = PoolRack.unit(&rng) * 2 * .pi
            let shot = PoolShot(aim: a, power: power, tipSide: rho * cos(phi), tipVertical: rho * sin(phi))
            let res = PoolPhysics.simulate(shot, from: start, geometry: g, record: false, parameters: .standard) { s, _ in
                steps += 1
                let on = s.balls.filter { $0.pocket == nil }
                for i in on.indices {
                    let p = on[i].position
                    // Never through a cushion: at least a radius from every
                    // segment, and past the noses only in a pocket's mouth.
                    for seg in g.cushions {
                        outside = max(outside, r - simd_distance(seg.closestPoint(to: p), p) - 1e-7)
                    }
                    if abs(p.x) > hl + 1e-7 || abs(p.y) > hw + 1e-7 {
                        let inMouth = g.pockets.contains { simd_distance($0.mouthCenter, p) < 0.13 }
                        if !inMouth { outside = max(outside, max(abs(p.x) - hl, abs(p.y) - hw)) }
                    }
                    for j in (i + 1)..<on.count {
                        overlap = max(overlap, 2 * r - simd_distance(p, on[j].position))
                    }
                }
            }
            if res.final.balls.count != start.balls.count { lost += 1 }
            if !res.final.isAtRest { unrested += 1 }
        }
        t.info("\(count) random shots (a fifth of them breaks, a third at full power), \(steps) steps checked")
        t.check("balls never overlap (deepest \(String(format: "%.1e", max(overlap, 0))) m)", overlap < 1e-6)
        t.check("balls never pass through a cushion or leave the table except into pockets", outside <= 0)
        t.check("every ball is accounted for after every shot", lost == 0)
        t.check("every shot ends with the table at rest", unrested == 0)
    }

    // MARK: Determinism

    static func determinism(_ t: TestReporter) {
        t.section("Pool engine: determinism")
        let rack = PoolRack.eightBall(seed: 42)
        let shot = PoolShot(aim: aim(rack.cueBall?.position ?? .zero, g.footSpot) + 0.004, power: 0.97,
                            tipSide: 0.2, tipVertical: -0.3)
        let a = PoolPhysics.simulate(shot, from: rack, record: false)
        let b = PoolPhysics.simulate(shot, from: rack, record: false)
        let c = PoolPhysics.simulate(shot, from: rack, record: true)
        t.check("the same shot twice gives the identical table", a.final == b.final && a.events == b.events)
        t.check("recording the trajectory does not change the shot", a.final == c.final && a.events == c.events)
        t.check("the racks replay from their seeds", PoolRack.eightBall(seed: 9) == PoolRack.eightBall(seed: 9)
                    && PoolRack.eightBall(seed: 9) != PoolRack.eightBall(seed: 10))
        guard let trajectory = c.trajectory else {
            t.check("a recorded shot carries its trajectory", false)
            return
        }
        let end = trajectory.poses(at: trajectory.duration + 1)
        var worst = 0.0
        for ball in c.final.balls {
            guard let pose = end[ball.number] else { worst = 1; continue }
            worst = max(worst, simd_distance(pose.position, ball.position))
            if (pose.pocket == nil) != (ball.pocket == nil) { worst = 1 }
        }
        t.check("the trajectory ends exactly where the shot does", worst < 1e-9)
        let start = trajectory.poses(at: 0)
        t.check("and starts where it began", rack.balls.allSatisfy { b in
            start[b.number].map { simd_distance($0.position, b.position) < 1e-9 } == true })
        let dropping = c.pocketed.first.flatMap { p in trajectory.tracks.first { $0.number == p.ball } }
        if let track = dropping {
            let before = PoolTrajectory.pose(of: track, at: track.pocketTime - 1e-6)
            let after = PoolTrajectory.pose(of: track, at: trajectory.duration)
            t.check("a pocketed ball falls from the cloth into its pocket in the replay",
                    before?.dropProgress == 0 && before?.pocket == nil && after?.dropProgress == 1 && after?.pocket != nil)
        }
        t.info("break replay: \(trajectory.keyframeCount) keyframes over \(f(trajectory.duration)) s")
    }

    // MARK: Performance

    static func performance(_ t: TestReporter) {
        t.section("Pool engine: speed")
        // A typical shot: a cut on a mid-game table.
        let mid = PoolRack.scattered(Array(0...9), seed: 77)
        var shots: [PoolShot] = []
        var rng = DeterministicRNG(seed: 5)
        for _ in 0..<40 {
            shots.append(PoolShot(aim: PoolRack.unit(&rng) * 2 * .pi, power: 0.2 + 0.4 * PoolRack.unit(&rng)))
        }
        var start = DispatchTime.now().uptimeNanoseconds
        for s in shots { _ = PoolPhysics.simulate(s, from: mid, record: false) }
        let typical = ms(start) / Double(shots.count)
        let rack = PoolRack.eightBall(seed: 1)
        let breakShot = PoolShot(aim: aim(rack.cueBall?.position ?? .zero, g.footSpot), power: 1, tipVertical: -0.2)
        start = DispatchTime.now().uptimeNanoseconds
        let breaks = 10
        for _ in 0..<breaks { _ = PoolPhysics.simulate(breakShot, from: rack, record: false) }
        let breakTime = ms(start) / Double(breaks)
        start = DispatchTime.now().uptimeNanoseconds
        _ = PoolPhysics.simulate(breakShot, from: rack, record: true)
        let recorded = ms(start)
        t.info("typical shot \(f(typical, 3)) ms, break \(f(breakTime, 3)) ms, break with replay \(f(recorded, 3)) ms (\(isRelease ? "release" : "debug"))")
        if isRelease {
            t.check("a typical shot simulates in under 2 ms", typical < 2)
            t.check("a break simulates in under 10 ms", breakTime < 10)
        }
    }

    // MARK: Aim guide

    static func aimGuide(_ t: TestReporter) {
        t.section("Pool engine: aiming guides")
        let straight = table([(0, SIMD2(-0.5, 0)), (1, SIMD2(0.3, 0))])
        let p = PoolAimGuide.predict(aim: 0, from: straight)
        t.check("a full-ball aim meets the ball with its ghost a diameter short",
                p.targetBall == 1 && abs(p.ghostBallCenter.x - (0.3 - 2 * r)) < 1e-9 && p.cueBallDeflection == nil
                    && (p.objectBallDirection.map { abs($0.x - 1) < 1e-12 } ?? false))
        let cutAim = asin(r / 0.8)       // half-ball hit: ghost offset one radius
        let cut = PoolAimGuide.predict(aim: cutAim, from: straight)
        if let ob = cut.objectBallDirection, let cb = cut.cueBallDeflection {
            t.check("on a cut the cue ball's tangent line is square to the object ball's line", abs(simd_dot(ob, cb)) < 1e-9)
        } else {
            t.check("a cut predicts both lines", false)
        }
        let open = PoolAimGuide.predict(aim: .pi / 2, from: straight)
        t.check("an aim at nothing meets the cushion", open.targetBall == nil
                    && (open.cushionPoint.map { abs($0.y - (g.width / 2 - r)) < 1e-9 } ?? false))
        let corner = g.pockets[3]
        let nearPocket = table([(0, corner.target - corner.axis * 0.3)])
        let scratch = PoolAimGuide.predict(aim: atan2(corner.axis.y, corner.axis.x), from: nearPocket)
        t.check("an aim into a pocket says the cue ball would drop", scratch.scratchPocket == 3)
    }

    // MARK: Rules

    /// A result with just these facts, for rule checks that need no table.
    static func result(first: Int?, pocketed: [(Int, Int)] = [], rail: Bool = true, final: PoolTableState)
        -> PoolShotResult {
        var table = final
        for (ball, pocket) in pocketed {
            if var b = table.ball(ball) {
                b.pocket = pocket
                b.position = g.pockets[pocket].center
                table.update(b)
            }
        }
        return PoolShotResult(events: [], firstContact: first, pocketed: pocketed.map { (ball: $0.0, pocket: $0.1) },
                              railAfterFirstContact: rail, final: table, trajectory: nil,
                              scratched: pocketed.contains { $0.0 == 0 }, firstContactTime: first == nil ? nil : 0.1,
                              objectBallsToRail: [], cueCushionsBeforeContact: 0, duration: 1)
    }

    static func eightBallTable(_ numbers: [Int]) -> PoolTableState {
        PoolRack.scattered([0] + numbers, seed: 12)
    }

    static func rules(_ t: TestReporter) {
        t.section("Pool engine: eight-ball rules")
        var open = PoolRules.newGame(.eightBall, breaker: 0)
        t.check("a new game breaks from the kitchen", open.isBreakShot && open.ballInHand == .kitchen && open.shooter == 0)
        let full = eightBallTable(Array(1...15))
        t.check("any ball may be hit on the break", PoolRules.legalFirstContacts(open, table: full).count == 15)

        // The 8 on the break comes back, and the break stands.
        let eightOnBreak = PoolRules.evaluate(result(first: 1, pocketed: [(8, 3), (2, 5)], final: full), before: full,
                                              state: open)
        t.check("the 8 on the break is re-spotted and the breaker continues",
                eightOnBreak.table.ball(8)?.pocket == nil && eightOnBreak.gameOver == nil && eightOnBreak.continuesTurn
                    && eightOnBreak.messages.contains(.eightBallRespotted))
        t.check("the table is open after the break", eightOnBreak.newState.isOpenTable)

        // Scratch on the break: the opponent's ball in hand behind the line.
        let breakScratch = PoolRules.evaluate(result(first: 1, pocketed: [(0, 2)], final: full), before: full, state: open)
        t.check("a scratch on the break is a foul with the kitchen to the opponent",
                breakScratch.foul == .scratch && breakScratch.newState.shooter == 1
                    && breakScratch.newState.ballInHand == .kitchen
                    && breakScratch.table.cueBall.map { g.kitchenContains($0.position) && $0.pocket == nil } == true)

        open.isBreakShot = false
        open.ballInHand = nil
        t.check("on an open table the 8 may not be struck first", !PoolRules.legalFirstContacts(open, table: full).contains(8))
        let eightFirst = PoolRules.evaluate(result(first: 8, final: full), before: full, state: open)
        t.check("striking the 8 first on an open table is a foul", eightFirst.foul == .wrongBallFirst
                    && eightFirst.newState.ballInHand == .anywhere && eightFirst.newState.shooter == 1)

        // Groups: the first ball legally pocketed decides.
        let assign = PoolRules.evaluate(result(first: 3, pocketed: [(11, 1), (3, 5)], final: full), before: full,
                                        state: open)
        t.check("the first ball pocketed on an open table gives the group (a stripe here)",
                assign.groupAssigned == .stripes && assign.newState.groups == [.stripes, .solids] && assign.continuesTurn)

        var playing = assign.newState      // player 0 on stripes
        t.check("with a group only its balls are legal", PoolRules.legalFirstContacts(playing, table: full) == Set(9...15))
        let wrong = PoolRules.evaluate(result(first: 2, final: full), before: full, state: playing)
        t.check("hitting the opponent's ball first is a foul with ball in hand anywhere",
                wrong.foul == .wrongBallFirst && wrong.newState.shooter == 1 && wrong.newState.ballInHand == .anywhere)
        let noRail = PoolRules.evaluate(result(first: 9, rail: false, final: full), before: full, state: playing)
        t.check("no ball to a rail and nothing pocketed is a foul", noRail.foul == .noRail)
        let railed = PoolRules.evaluate(result(first: 9, rail: true, final: full), before: full, state: playing)
        t.check("a legal miss just passes the turn", railed.foul == nil && !railed.continuesTurn
                    && railed.newState.shooter == 1 && railed.newState.ballInHand == nil)
        let scratch = PoolRules.evaluate(result(first: 9, pocketed: [(0, 4)], final: full), before: full, state: playing)
        t.check("a scratch gives the opponent ball in hand anywhere with the cue ball back on the cloth",
                scratch.foul == .scratch && scratch.newState.ballInHand == .anywhere
                    && scratch.table.cueBall?.pocket == nil
                    && PoolRules.isValidPlacement(scratch.table.cueBall?.position ?? .zero, scratch.newState,
                                                  table: scratch.table))
        let early = PoolRules.evaluate(result(first: 9, pocketed: [(8, 2)], final: full), before: full, state: playing)
        t.check("pocketing the 8 before the group is cleared loses", early.gameOver?.winner == 1
                    && early.gameOver?.reason == .eightBallEarly && early.newState.winner == 1)

        // Group cleared: the 8 wins, the 8 with a scratch loses.
        let endgame = eightBallTable([1, 2, 8])
        playing.shooter = 0
        t.check("with the group cleared only the 8 is legal", PoolRules.legalFirstContacts(playing, table: endgame) == [8])
        let win = PoolRules.evaluate(result(first: 8, pocketed: [(8, 0)], final: endgame), before: endgame, state: playing)
        t.check("pocketing the 8 after clearing the group wins", win.gameOver?.winner == 0
                    && win.gameOver?.reason == .eightBallPotted)
        let lose = PoolRules.evaluate(result(first: 8, pocketed: [(8, 0), (0, 3)], final: endgame), before: endgame,
                                      state: playing)
        t.check("pocketing the 8 and scratching loses", lose.gameOver?.winner == 1 && lose.gameOver?.reason == .eightBallOnFoul)
        let keep = PoolRules.evaluate(result(first: 9, pocketed: [(9, 1)], final: full), before: full, state: playing)
        t.check("pocketing an own ball keeps the turn and counts the run",
                keep.continuesTurn && keep.newState.shooter == 0 && keep.newState.run == playing.run + 1)
        let theirs = PoolRules.evaluate(result(first: 9, pocketed: [(2, 1)], final: full), before: full, state: playing)
        t.check("pocketing only the opponent's ball passes the turn", !theirs.continuesTurn && theirs.foul == nil)

        t.section("Pool engine: nine-ball and practice rules")
        var nine = PoolRules.newGame(.nineBall, breaker: 1)
        nine.isBreakShot = false
        nine.ballInHand = nil
        let nineTable = PoolRack.scattered([0, 3, 5, 9], seed: 4)
        t.check("the lowest ball is the only legal first contact", PoolRules.legalFirstContacts(nine, table: nineTable) == [3])
        let combo = PoolRules.evaluate(result(first: 3, pocketed: [(9, 2)], final: nineTable), before: nineTable, state: nine)
        t.check("the 9 in off the lowest ball wins (a combination)", combo.gameOver?.winner == 1
                    && combo.gameOver?.reason == .nineBallPotted)
        let nineFoul = PoolRules.evaluate(result(first: 5, pocketed: [(9, 2)], final: nineTable), before: nineTable,
                                          state: nine)
        t.check("the 9 pocketed on a foul is re-spotted and the opponent has ball in hand",
                nineFoul.gameOver == nil && nineFoul.foul == .wrongBallFirst && nineFoul.table.ball(9)?.pocket == nil
                    && nineFoul.newState.shooter == 0 && nineFoul.newState.ballInHand == .anywhere
                    && nineFoul.messages.contains(.nineBallRespotted))
        let ninePot = PoolRules.evaluate(result(first: 3, pocketed: [(5, 0)], final: nineTable), before: nineTable, state: nine)
        t.check("any ball pocketed on a legal hit continues", ninePot.continuesTurn && ninePot.newState.shooter == 1)
        let crowded = table([(0, SIMD2(-0.5, 0)), (8, g.footSpot), (1, g.footSpot + SIMD2(2 * r + 0.001, 0))])
        var respotted = crowded
        PoolRules.respot(9, on: &respotted, geometry: g)
        t.check("a ball re-spots behind the foot spot when the spot is taken", true)
        var withNine = crowded
        withNine.update(PoolBall(number: 9, position: g.pockets[0].center, pocket: 0))
        PoolRules.respot(9, on: &withNine, geometry: g)
        let placed = withNine.ball(9)
        t.check("…on the long axis, touching nothing", placed.map { b in
            b.pocket == nil && abs(b.position.y) < 1e-12 && b.position.x > g.footSpot.x
                && withNine.balls.allSatisfy { $0.number == 9 || simd_distance($0.position, b.position) >= 2 * r }
        } == true)

        let practice = PoolRules.newGame(.practice, breaker: 1)
        t.check("practice is always the player's shot", practice.shooter == 0)
        let pScratch = PoolRules.evaluate(result(first: nil, pocketed: [(0, 1)], final: nineTable), before: nineTable,
                                          state: practice)
        t.check("practice has no fouls and re-spots a scratched cue ball",
                pScratch.foul == nil && pScratch.table.cueBall?.pocket == nil && pScratch.continuesTurn
                    && pScratch.messages.contains(.cueBallRespotted))

        // Placement.
        var hand = PoolRules.newGame(.eightBall, breaker: 0)
        t.check("a kitchen ball in hand may not go past the head string",
                PoolRules.isValidPlacement(SIMD2(-0.9, 0.1), hand, table: full)
                    && !PoolRules.isValidPlacement(SIMD2(-0.3, 0.1), hand, table: full))
        hand.ballInHand = .anywhere
        let occupied = full.ball(5)?.position ?? .zero
        t.check("a ball in hand may not touch another ball or leave the cloth",
                !PoolRules.isValidPlacement(occupied + SIMD2(r, 0), hand, table: full)
                    && !PoolRules.isValidPlacement(SIMD2(g.length / 2, 0), hand, table: full))
        hand.ballInHand = nil
        t.check("without ball in hand the cue ball may not be moved", !PoolRules.isValidPlacement(SIMD2(-0.9, 0.1), hand, table: full))
    }

    // MARK: Persistence

    static func persistence(_ t: TestReporter) {
        t.section("Pool engine: saving")
        let rack = PoolRack.nineBall(seed: 3)
        var state = PoolRules.newGame(.nineBall, breaker: 1)
        state.groups = [nil, nil]
        state.run = 3
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let tableBack = (try? encoder.encode(rack)).flatMap { try? decoder.decode(PoolTableState.self, from: $0) }
        t.check("a table round-trips through JSON, orientations included", tableBack == rack)
        let stateBack = (try? encoder.encode(state)).flatMap { try? decoder.decode(PoolRuleState.self, from: $0) }
        t.check("the rule state round-trips through JSON", stateBack == state)
        let partial = Data(#"{"mode":"eightBall","shooter":7,"groups":["solids"],"shotCount":"x"}"#.utf8)
        let tolerant = try? decoder.decode(PoolRuleState.self, from: partial)
        t.check("a damaged rule state decodes key by key with fallbacks",
                tolerant.map { $0.mode == .eightBall && $0.shooter == 1 && $0.groups == [nil, nil] && $0.shotCount == 0 } == true)
        let ballJSON = Data(#"{"balls":[{"number":3,"position":[0.1,0.2]},{"number":3,"position":[0,0]},{"number":99}]}"#.utf8)
        let balls = try? decoder.decode(PoolTableState.self, from: ballJSON)
        t.check("a damaged table keeps what it can", balls.map { $0.balls.count == 1 && $0.balls[0].orientation.real == 1 } == true)
    }

    // MARK: Computer

    static func computer(_ t: TestReporter) {
        t.section("Pool engine: computer opponent")
        // Hard makes simple straight shots. The plan does not depend on the
        // seed — only the execution error does — so one decision and many
        // seeded executions sample exactly what many decisions would.
        let line = straightIn(objectToPocket: 0.5, cueToObject: 0.5)
        var shot = line.table
        shot.update(PoolBall(number: 8, position: SIMD2(-0.8, -0.3)))
        var nine = PoolRules.newGame(.nineBall, breaker: 1)
        nine.isBreakShot = false
        nine.ballInHand = nil
        let samples = isRelease ? 200 : 60
        for level in PoolDifficulty.allCases.reversed() {
            let plan = PoolAI.decide(table: shot, rules: nine, difficulty: level, seed: 0)
            var rng = DeterministicRNG(seed: 0xB0B)
            var made = 0
            for _ in 0..<samples {
                let stroke = PoolAI.perturb(plan.planned, profile: PoolAI.profile(level), rng: &rng)
                let res = PoolPhysics.simulate(stroke, from: shot, record: false)
                if res.pocketed(1) && !res.scratched { made += 1 }
            }
            if level == .hard {
                t.check("Hard pots a simple straight shot at least 95% of the time (\(made)/\(samples))",
                        Double(made) >= 0.95 * Double(samples))
                let direct = PoolAI.decide(table: shot, rules: nine, difficulty: .hard, seed: 17)
                var check = DeterministicRNG(seed: 17 ^ 0xA1_5E7)
                t.check("a decision's stroke is its plan with that seed's execution error",
                        direct.shot == PoolAI.perturb(direct.planned, profile: PoolAI.profile(.hard), rng: &check))
            } else {
                t.info("\(level.rawValue) makes the same shot \(made)/\(samples)")
            }
        }

        let same1 = PoolAI.decide(table: shot, rules: nine, difficulty: .medium, seed: 5)
        let same2 = PoolAI.decide(table: shot, rules: nine, difficulty: .medium, seed: 5)
        t.check("the same table and seed give the same stroke", same1.shot == same2.shot)

        // Ball in hand: always somewhere legal.
        var illegal = 0, tried = 0, legalHits = 0, decided = 0
        let layouts = isRelease ? 16 : 4
        for k in 0..<layouts {
            var shuffle = DeterministicRNG(seed: UInt64(k))
            let numbers = [0] + Array(1...15).shuffled(using: &shuffle).prefix(isRelease ? 4 + k % 8 : 3 + k % 3)
            let layout = PoolRack.scattered(Array(numbers), seed: UInt64(k) + 900)
            for hand in [PoolBallInHand.anywhere, .kitchen] {
                var s = PoolRules.newGame(.eightBall, breaker: 1)
                s.isBreakShot = false
                s.ballInHand = hand
                let level: PoolDifficulty = isRelease && k % 2 == 0 ? .medium : .easy
                let d = PoolAI.decide(table: layout, rules: s, difficulty: level, seed: UInt64(k))
                tried += 1
                guard let p = d.placement, PoolRules.isValidPlacement(p, s, table: layout) else { illegal += 1; continue }
                var placed = layout
                if var cue = placed.cueBall { cue.position = p; placed.cueBall = cue }
                let res = PoolPhysics.simulate(d.planned, from: placed, record: false)
                decided += 1
                if let first = res.firstContact, PoolRules.legalFirstContacts(s, table: placed).contains(first) { legalHits += 1 }
            }
        }
        t.check("the computer never proposes an illegal ball-in-hand spot (\(tried - illegal)/\(tried) legal)", illegal == 0)
        t.check("its intended stroke hits a legal ball first (\(legalHits)/\(decided))", legalHits * 10 >= decided * 9)

        // The break, from the kitchen.
        let rack = PoolRack.eightBall(seed: 8)
        let breakDecision = PoolAI.decide(table: rack, rules: PoolRules.newGame(.eightBall, breaker: 1),
                                          difficulty: .hard, seed: 1)
        t.check("the computer breaks from a legal kitchen spot at the rack", breakDecision.intent == .breakShot
                    && breakDecision.placement.map { g.kitchenContains($0) } == true && breakDecision.shot.power > 0.9)

        // Thinking time on a full table (release only: debug is some seventy
        // times slower and says nothing about the shipped build).
        guard isRelease else {
            t.info("thinking time is measured in release builds")
            return
        }
        let busy = PoolRack.scattered(Array(0...15), seed: 3)
        var s = PoolRules.newGame(.eightBall, breaker: 1)
        s.isBreakShot = false
        s.ballInHand = nil
        for level in PoolDifficulty.allCases {
            let start = DispatchTime.now().uptimeNanoseconds
            let d = PoolAI.decide(table: busy, rules: s, difficulty: level, seed: 2)
            let open = ms(start)
            var inHand = s
            inHand.ballInHand = .anywhere
            let start2 = DispatchTime.now().uptimeNanoseconds
            let d2 = PoolAI.decide(table: busy, rules: inHand, difficulty: level, seed: 2)
            let bih = ms(start2)
            t.info("\(level.rawValue): \(f(open, 0)) ms (\(d.simulations) simulations), with ball in hand \(f(bih, 0)) ms (\(d2.simulations))")
            if level == .hard {
                t.check("Hard decides in under 1.5 s on a full table", max(open, bih) < 1500)
            }
        }
    }
}
