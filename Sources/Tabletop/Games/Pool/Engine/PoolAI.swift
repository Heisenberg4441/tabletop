//
//  PoolAI.swift
//  The computer opponent: it looks at the table the way a player does, tries
//  its likely shots on the real physics, and then misses the way a player of
//  its level would.
//
//  1. Lines. For every ball it may hit and every pocket, the ghost-ball aim:
//     rejected if the cut is thinner than about 80°, the pocket cannot be
//     entered from that side, or a ball stands in the cue ball's path or the
//     object ball's (corridors a ball wide). Each surviving line gets a
//     make-probability from geometry: how much aiming error the pocket
//     forgives at that distance and cut, against the level's own error.
//  2. Trials. The likeliest lines are tried at a few speeds and spins
//     (stun, follow, draw; english on Hard). Each is first corrected for
//     throw and squirt by simulating up to the first contact and nudging the
//     aim until the object ball leaves exactly on its line, then simulated
//     to rest and scored: a win, a loss, a foul, the turn kept (and how good
//     the next shot will be from where the cue ball stops) or the turn lost
//     (and how good the table is left for the opponent).
//  3. Safety. When nothing is likely enough, legal contacts at soft speeds
//     are tried for the one that leaves the opponent least; when no ball can
//     be hit directly, kicks off the rails are sampled.
//  4. Ball in hand: cue-ball spots behind the likeliest lines are tried the
//     same way and the best kept — always one where the ball may legally go.
//  5. Execution. The chosen stroke is spoiled by Gaussian error in aim,
//     speed and tip position, from a seeded generator, so a given table and
//     seed always produce the same shot.
//
//  Everything is a pure function of value types, safe to run on a background
//  queue.
//
//  Difficulty is mostly that error. The spec's σ (1.2° / 0.45° / 0.12°)
//  reads as an error in the object ball's direction; on the cue it would
//  have Easy missing nearly everything, because a cue angle is multiplied
//  some twenty times into the object ball's direction over a metre of
//  travel. The cue errors below are chosen instead to give those levels the
//  intended feel — Easy makes the easy ones, Hard makes almost everything
//  it chooses — and Hard more than meets the ≥95% straight-shot bar.
//

import Foundation
import simd

enum PoolAIIntent: Sendable, Equatable {
    case breakShot
    case pot(ball: Int, pocket: Int)
    case safety(ball: Int)
    case kick
}

struct PoolAIDecision: Sendable {
    /// Where to put the cue ball first (only with ball in hand).
    var placement: SIMD2<Double>?
    /// The stroke to play, execution error included.
    var shot: PoolShot
    /// The stroke the computer meant.
    var planned: PoolShot
    var intent: PoolAIIntent
    /// How good it expected the shot to be (for tests and tuning).
    var expectedValue: Double
    /// Simulations run to decide.
    var simulations: Int
}

enum PoolAI {

    struct Profile: Sendable {
        /// Standard deviation of the stroke's error: aim in radians, speed
        /// as a fraction, tip offset in tip units.
        let aimError: Double
        let speedError: Double
        let tipError: Double
        let breakPower: Double
        /// Speed multipliers and tip offsets each line is tried with.
        let variants: [(speed: Double, side: Double, vertical: Double)]
        /// How many lines are tried on the physics.
        let lines: Int
        /// How many cue-ball spots are tried with ball in hand.
        let placements: Int
        /// Weight of the next shot in a line's value (0: ignores position).
        let position: Double
        let playsSafe: Bool
        /// Re-checks the best trials with the stroke a little off.
        let checksRobustness: Bool
    }

    static func profile(_ d: PoolDifficulty) -> Profile {
        let degree = Double.pi / 180
        switch d {
        case .easy:
            return Profile(aimError: 0.30 * degree, speedError: 0.10, tipError: 0.10, breakPower: 0.86,
                           variants: [(1.0, 0, 0), (1.35, 0, 0)], lines: 5, placements: 3, position: 0,
                           playsSafe: false, checksRobustness: false)
        case .medium:
            return Profile(aimError: 0.12 * degree, speedError: 0.05, tipError: 0.05, breakPower: 0.94,
                           variants: [(1.0, 0, 0), (1.0, 0, 0.55), (1.0, 0, -0.55), (1.4, 0, 0), (1.4, 0, 0.55),
                                      (1.4, 0, -0.55)],
                           lines: 8, placements: 6, position: 0.6, playsSafe: true, checksRobustness: false)
        case .hard:
            return Profile(aimError: 0.045 * degree, speedError: 0.02, tipError: 0.02, breakPower: 1.0,
                           variants: [(0.9, 0, 0), (0.9, 0, 0.6), (0.9, 0, -0.6), (1.25, 0, 0), (1.25, 0, 0.6),
                                      (1.25, 0, -0.6), (1.25, 0.5, 0), (1.25, -0.5, 0), (1.7, 0, 0), (1.7, 0, 0.6),
                                      (1.7, 0, -0.6)],
                           lines: 12, placements: 10, position: 1.0, playsSafe: true, checksRobustness: true)
        }
    }

    /// The cue's aim error together with the squirt its tip error causes
    /// (about 0.044 rad of squirt per unit of accidental english): the error
    /// a line's make-probability is judged against.
    static func effectiveAimError(_ p: Profile) -> Double {
        let squirt = 0.044 * p.tipError
        return (p.aimError * p.aimError + squirt * squirt).squareRoot()
    }

    /// The aim error the computer assumes of the player when it judges what
    /// it leaves them: a competent amateur.
    static let playerAimError = 0.10 * Double.pi / 180

    // MARK: Entry point

    static func decide(table: PoolTableState, rules: PoolRuleState, difficulty: PoolDifficulty,
                       seed: UInt64) -> PoolAIDecision {
        decide(table: table, rules: rules, difficulty: difficulty, seed: seed, geometry: .standard)
    }

    static func decide(table: PoolTableState, rules: PoolRuleState, difficulty: PoolDifficulty, seed: UInt64,
                       geometry g: PoolTableGeometry) -> PoolAIDecision {
        var planner = PoolAIPlanner(geometry: g, rules: rules, profile: profile(difficulty))
        var rng = DeterministicRNG(seed: seed ^ 0xA1_5E7)
        var decision = planner.plan(table: table)
        decision.shot = perturb(decision.planned, profile: planner.profile, rng: &rng)
        decision.simulations = planner.simulations
        return decision
    }

    /// The stroke as a player of this level would actually deliver it.
    static func perturb(_ shot: PoolShot, profile p: Profile, rng: inout DeterministicRNG) -> PoolShot {
        var s = shot
        s.aim += gaussian(&rng) * p.aimError
        s.power = min(max(PoolShot.power(forSpeed: PoolShot.speed(forPower: shot.power)
                                            * (1 + gaussian(&rng) * p.speedError)), 0), 1)
        s.tipSide = min(max(s.tipSide + gaussian(&rng) * p.tipError, -1), 1)
        s.tipVertical = min(max(s.tipVertical + gaussian(&rng) * p.tipError, -1), 1)
        return s
    }

    /// A standard normal deviate (Box–Muller).
    static func gaussian(_ rng: inout DeterministicRNG) -> Double {
        let u1 = max(PoolRack.unit(&rng), 1e-12), u2 = PoolRack.unit(&rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

// MARK: - Planning

/// One ghost-ball line: this ball into that pocket from here.
struct PoolAILine {
    let target: Int
    let pocket: Int
    let ghost: SIMD2<Double>
    let aim: Double
    /// Direction the object ball must leave in.
    let direction: SIMD2<Double>
    let cut: Double
    let cueTravel: Double
    let objectTravel: Double
    let probability: Double
}

struct PoolAIPlanner {
    let g: PoolTableGeometry
    let rules: PoolRuleState
    let profile: PoolAI.Profile
    let me: Int
    var simulations = 0

    init(geometry: PoolTableGeometry, rules: PoolRuleState, profile: PoolAI.Profile) {
        g = geometry
        self.rules = rules
        self.profile = profile
        me = rules.shooter
    }

    mutating func plan(table: PoolTableState) -> PoolAIDecision {
        if rules.isBreakShot { return breakShot(table: table) }
        if let hand = rules.ballInHand { return ballInHand(hand, table: table) }
        return best(from: table, lines: profile.lines, variants: profile.variants, safety: profile.playsSafe)
            ?? fallback(table: table)
    }

    // MARK: Break

    mutating func breakShot(table: PoolTableState) -> PoolAIDecision {
        var t = table
        var spot = PoolRack.breakCueSpot(g)
        // Nine-ball is broken from a little off the axis, the stronger break
        // for the corner pockets; eight-ball from the middle.
        if rules.mode == .nineBall { spot.y = -0.18 }
        if rules.ballInHand != nil && !PoolRules.isValidPlacement(spot, rules, table: table, geometry: g) {
            spot = anyPlacement(table: table) ?? spot
        }
        if rules.ballInHand != nil, var cue = t.cueBall {
            cue.position = spot
            cue.pocket = nil
            t.cueBall = cue
        }
        let cue = t.cueBall?.position ?? spot
        let apex = t.balls.filter { $0.number != 0 && $0.pocket == nil }
            .min { simd_distance($0.position, g.footSpot) < simd_distance($1.position, g.footSpot) }?.position ?? g.footSpot
        let d = apex - cue
        let shot = PoolShot(aim: atan2(d.y, d.x), power: profile.breakPower, tipSide: 0, tipVertical: -0.15)
        return PoolAIDecision(placement: rules.ballInHand != nil ? spot : nil, shot: shot, planned: shot,
                              intent: .breakShot, expectedValue: 0, simulations: 0)
    }

    // MARK: Ball in hand

    mutating func ballInHand(_ hand: PoolBallInHand, table: PoolTableState) -> PoolAIDecision {
        let legal = PoolRules.legalFirstContacts(rules, table: table)
        var spots: [(SIMD2<Double>, Double)] = []
        let r = g.ballRadius
        for n in legal {
            guard let ball = table.ball(n) else { continue }
            for pocket in g.pockets {
                let toPocket = pocket.target - ball.position
                let dist = simd_length(toPocket)
                guard dist > 1e-6 else { continue }
                let dir = toPocket / dist
                guard entryAllowed(dir, pocket) else { continue }
                if corridorBlocked(from: ball.position, to: pocket.target, width: 2 * r, table: table,
                                   ignoring: [n, 0]) { continue }
                let ghost = ball.position - dir * 2 * r
                // Straight behind the ghost, and turned a little to either
                // side for position, at a comfortable distance.
                for back in [0.22, 0.42] {
                    for turn in [0.0, 0.22, -0.22, 0.42, -0.42] {
                        let c = cos(turn), s = sin(turn)
                        let away = SIMD2(-dir.x * c + dir.y * s, -dir.x * s - dir.y * c)
                        let spot = ghost + away * back
                        guard PoolRules.isValidPlacement(spot, rules, table: table, geometry: g) else { continue }
                        var t = table
                        place(spot, on: &t)
                        if corridorBlocked(from: spot, to: ghost, width: 2 * r, table: t, ignoring: [n, 0]) { continue }
                        let p = probability(cue: spot, ghost: ghost, target: ball.position, pocket: pocket,
                                            error: PoolAI.effectiveAimError(profile))
                        spots.append((spot, p - 0.02 * abs(turn) - 0.03 * back))
                    }
                }
            }
        }
        spots.sort { $0.1 > $1.1 }
        var bestDecision: PoolAIDecision?
        var seen: [SIMD2<Double>] = []
        for (spot, _) in spots {
            if seen.contains(where: { simd_distance($0, spot) < 0.05 }) { continue }
            seen.append(spot)
            if seen.count > profile.placements { break }
            var t = table
            place(spot, on: &t)
            let variants = Array(profile.variants.prefix(profile.variants.count > 3 ? 6 : profile.variants.count))
            if var d = best(from: t, lines: 3, variants: variants, safety: false) {
                d.placement = spot
                if d.expectedValue > (bestDecision?.expectedValue ?? -.infinity) { bestDecision = d }
            }
        }
        if var chosen = bestDecision, let spot = chosen.placement {
            // Play the chosen spot with the full repertoire.
            var t = table
            place(spot, on: &t)
            if let full = best(from: t, lines: profile.lines, variants: profile.variants, safety: profile.playsSafe),
               full.expectedValue >= chosen.expectedValue {
                chosen = full
                chosen.placement = spot
            }
            return chosen
        }
        // Nothing to pot from anywhere: put the ball somewhere legal and
        // play safe or kick from there.
        let spot = anyPlacement(table: table) ?? table.cueBall?.position ?? g.headSpot
        var t = table
        place(spot, on: &t)
        var d = best(from: t, lines: profile.lines, variants: profile.variants, safety: true) ?? fallback(table: t)
        d.placement = spot
        return d
    }

    func place(_ spot: SIMD2<Double>, on t: inout PoolTableState) {
        var cue = t.cueBall ?? PoolBall(number: 0, position: spot)
        cue.position = spot
        cue.pocket = nil
        cue.velocity = .zero
        cue.spin = .zero
        t.cueBall = cue
    }

    /// Any legal spot for the cue ball: the head spot, the break spot, or the
    /// first free point of a coarse grid.
    func anyPlacement(table: PoolTableState) -> SIMD2<Double>? {
        let candidates = [g.headSpot, PoolRack.breakCueSpot(g), SIMD2(g.headStringX - 0.2, 0.3),
                          SIMD2(g.headStringX - 0.2, -0.3)]
        for c in candidates where PoolRules.isValidPlacement(c, rules, table: table, geometry: g) { return c }
        for i in 0..<24 {
            for j in 0..<12 {
                let p = SIMD2(-g.length / 2 + 0.05 + Double(i) * 0.1, -g.width / 2 + 0.05 + Double(j) * 0.1)
                if PoolRules.isValidPlacement(p, rules, table: table, geometry: g) { return p }
            }
        }
        return nil
    }

    // MARK: Choosing a shot

    /// The best shot from this table: the likeliest pots tried on the
    /// physics, a safety when nothing is likely, a kick when nothing can be
    /// hit. Nil only when there is no cue ball.
    mutating func best(from table: PoolTableState, lines count: Int,
                       variants: [(speed: Double, side: Double, vertical: Double)], safety: Bool) -> PoolAIDecision? {
        guard let cue = table.cueBall, cue.pocket == nil else { return nil }
        let candidates = lines(from: table).prefix(count)
        var trials: [(shot: PoolShot, value: Double, line: PoolAILine)] = []
        for line in candidates {
            for v in variants {
                let objectSpeed = objectBallSpeed(for: line) * v.speed
                let speed = strokeSpeed(for: line, objectSpeed: objectSpeed)
                guard speed <= PoolShot.maximumSpeed * 1.02 else { continue }
                let first = PoolShot(aim: line.aim, power: PoolShot.power(forSpeed: speed), tipSide: v.side,
                                     tipVertical: v.vertical)
                guard let shot = refined(first, line: line, objectSpeed: objectSpeed, table: table) else { continue }
                let result = simulate(shot, table)
                let value = value(of: result, before: table, line: line)
                trials.append((shot, value, line))
            }
        }
        trials.sort { $0.value > $1.value }
        if profile.checksRobustness {
            // A shot that only works dead on is worth less than it looks:
            // try the best few a little off either side.
            for k in 0..<min(4, trials.count) {
                var worst = trials[k].value
                for (off, slower) in [(-1.3, 0.0), (1.3, 0.0), (0.0, 1.5)] {
                    var s = trials[k].shot
                    s.aim += off * profile.aimError
                    s.power = PoolShot.power(forSpeed: PoolShot.speed(forPower: s.power) * (1 - slower * profile.speedError))
                    let result = simulate(s, table)
                    worst = min(worst, value(of: result, before: table, line: trials[k].line))
                }
                trials[k].value = 0.65 * trials[k].value + 0.35 * worst
            }
            trials.sort { $0.value > $1.value }
        }
        var decision = trials.first.map {
            PoolAIDecision(placement: nil, shot: $0.shot, planned: $0.shot,
                           intent: .pot(ball: $0.line.target, pocket: $0.line.pocket),
                           expectedValue: $0.value, simulations: 0)
        }
        if safety && (decision?.expectedValue ?? -.infinity) < 35 {
            if let safe = safetyShot(from: table), safe.expectedValue > (decision?.expectedValue ?? -.infinity) {
                decision = safe
            }
        }
        if decision == nil || (decision?.expectedValue ?? -.infinity) < -100 {
            if let kick = kickShot(from: table), kick.expectedValue > (decision?.expectedValue ?? -.infinity) {
                decision = kick
            }
        }
        return decision
    }

    /// Something legal-looking when every search came up empty: straight at
    /// the nearest ball it may hit, at a medium pace.
    func fallback(table: PoolTableState) -> PoolAIDecision {
        let cue = table.cueBall?.position ?? g.headSpot
        let legal = PoolRules.legalFirstContacts(rules, table: table)
        let target = table.balls.filter { legal.contains($0.number) && $0.pocket == nil }
            .min { simd_distance($0.position, cue) < simd_distance($1.position, cue) }
        let d = (target?.position ?? g.footSpot) - cue
        let shot = PoolShot(aim: atan2(d.y, d.x), power: 0.4)
        return PoolAIDecision(placement: nil, shot: shot, planned: shot, intent: .kick, expectedValue: -200,
                              simulations: 0)
    }

    mutating func simulate(_ shot: PoolShot, _ table: PoolTableState) -> PoolShotResult {
        simulations += 1
        return PoolPhysics.simulate(shot, from: table, geometry: g, record: false)
    }

    // MARK: Lines

    /// Every open ghost-ball line for the shooter, likeliest first.
    func lines(from table: PoolTableState, for rulesState: PoolRuleState? = nil,
               error: Double? = nil) -> [PoolAILine] {
        let s = rulesState ?? rules
        guard let cue = table.cueBall, cue.pocket == nil else { return [] }
        let legal = PoolRules.legalFirstContacts(s, table: table)
        let r = g.ballRadius
        var out: [PoolAILine] = []
        for n in legal.sorted() {
            guard let ball = table.ball(n), ball.pocket == nil else { continue }
            for pocket in g.pockets {
                let toPocket = pocket.target - ball.position
                let objectTravel = simd_length(toPocket)
                guard objectTravel > 1e-6 else { continue }
                let dir = toPocket / objectTravel
                guard entryAllowed(dir, pocket) else { continue }
                let ghost = ball.position - dir * 2 * r
                let toGhost = ghost - cue.position
                let cueTravel = simd_length(toGhost)
                guard cueTravel > 1e-6 else { continue }
                let along = simd_dot(toGhost / cueTravel, dir)
                guard along > cos(80 * Double.pi / 180) else { continue }
                if corridorBlocked(from: cue.position, to: ghost, width: 2 * r, table: table, ignoring: [0, n]) {
                    continue
                }
                if corridorBlocked(from: ball.position, to: pocket.target, width: 2 * r, table: table,
                                   ignoring: [0, n]) { continue }
                let p = probability(cue: cue.position, ghost: ghost, target: ball.position, pocket: pocket,
                                    error: error ?? PoolAI.effectiveAimError(profile))
                out.append(PoolAILine(target: n, pocket: pocket.id, ghost: ghost, aim: atan2(toGhost.y, toGhost.x),
                                      direction: dir, cut: acos(min(max(along, -1), 1)), cueTravel: cueTravel,
                                      objectTravel: objectTravel, probability: p))
            }
        }
        return out.sorted { $0.probability > $1.probability }
    }

    /// Whether a ball arriving along `dir` can drop in this pocket at all: a
    /// corner takes anything within its right angle, a side pocket only
    /// what comes within about 55° of square.
    func entryAllowed(_ dir: SIMD2<Double>, _ pocket: PoolPocket) -> Bool {
        let c = simd_dot(dir, pocket.axis)
        return pocket.kind == .corner ? c > cos(47 * Double.pi / 180) : c > cos(55 * Double.pi / 180)
    }

    /// Whether any ball but those ignored stands within `width` of the
    /// segment.
    func corridorBlocked(from a: SIMD2<Double>, to b: SIMD2<Double>, width: Double, table: PoolTableState,
                         ignoring: Set<Int>) -> Bool {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        for ball in table.balls where ball.pocket == nil && !ignoring.contains(ball.number) {
            let t = len2 > 0 ? min(max(simd_dot(ball.position - a, ab) / len2, 0), 1) : 0
            if simd_distance(a + ab * t, ball.position) < width - 1e-6 { return true }
        }
        return false
    }

    /// The chance that a stroke with this aim error pots the ball: the
    /// pocket forgives an object-ball error of about its effective
    /// half-width over the distance to it, and the cue's error reaches the
    /// object ball multiplied by (1 + travel / (2R cos cut)).
    func probability(cue: SIMD2<Double>, ghost: SIMD2<Double>, target: SIMD2<Double>, pocket: PoolPocket,
                     error: Double) -> Double {
        let toPocket = pocket.target - target
        let distance = max(simd_length(toPocket), 0.02)
        let dir = toPocket / distance
        let entry = acos(min(max(simd_dot(dir, pocket.axis), -1), 1))
        let halfWidth: Double
        if pocket.kind == .corner {
            halfWidth = 0.029 * max(0.45, 1 - pow(entry / (60 * Double.pi / 180), 2))
        } else {
            halfWidth = 0.038 * max(0.05, 1 - pow(entry / (62 * Double.pi / 180), 2))
        }
        let tolerance = atan(halfWidth / distance)
        let toGhost = ghost - cue
        let travel = simd_length(toGhost)
        let cosCut = max(simd_dot(toGhost / max(travel, 1e-9), dir), 0.08)
        let gain = 1 + travel / (2 * g.ballRadius * cosCut)
        let allowed = tolerance / gain
        return erf(allowed / (max(error, 1e-6) * 2.0.squareRoot()))
    }

    // MARK: Strokes

    /// How fast the object ball must leave the contact to roll into the
    /// pocket and arrive at a firm walking pace.
    func objectBallSpeed(for line: PoolAILine) -> Double {
        let roll = PoolPhysics.Parameters.standard.rollingResistance * 9.81
        let arrive = 0.6
        // It leaves sliding and rolls on at 5/7 of that speed.
        return ((arrive * arrive + 2 * roll * line.objectTravel) / (25.0 / 49)).squareRoot()
    }

    /// A first guess at the stroke speed for that: the cue ball hands the
    /// object ball cos(cut) of its speed (a little less, the collision is
    /// not perfectly elastic), after sliding for 0.125 v² metres — losing
    /// 2/7 of its speed — and rolling the rest of the way. `refined` then
    /// makes it exact on the physics, spin and all.
    func strokeSpeed(for line: PoolAILine, objectSpeed: Double) -> Double {
        let contact = objectSpeed / max(cos(line.cut), 0.2) / 0.98
        var lo = PoolShot.minimumSpeed, hi = PoolShot.maximumSpeed
        for _ in 0..<40 {
            let v0 = (lo + hi) / 2
            if arrivalSpeed(from: v0, over: line.cueTravel) < contact { lo = v0 } else { hi = v0 }
        }
        return hi
    }

    func arrivalSpeed(from v0: Double, over d: Double) -> Double {
        let slide = PoolPhysics.Parameters.standard.slidingFriction * 9.81
        let roll = PoolPhysics.Parameters.standard.rollingResistance * 9.81
        let slideDistance = v0 * v0 / slide * 12 / 49
        if d <= slideDistance { return (max(v0 * v0 - 2 * slide * d, 0)).squareRoot() }
        let rolling = v0 * 5 / 7
        return max(rolling * rolling - 2 * roll * (d - slideDistance), 0).squareRoot()
    }

    /// The stroke that sends the object ball exactly along the line at the
    /// speed asked for, found by simulating to the first contact (so throw,
    /// squirt, draw's long slide — everything — is in it) and correcting aim
    /// by the secant method and speed in proportion. Nil if the cue ball
    /// meets some other ball, or a cushion, first.
    mutating func refined(_ start: PoolShot, line: PoolAILine, objectSpeed: Double,
                          table: PoolTableState) -> PoolShot? {
        let desired = atan2(line.direction.y, line.direction.x)
        var shot = start
        var previous: (aim: Double, error: Double)?
        for _ in 0..<5 {
            simulations += 1
            guard let contact = PoolPhysics.firstContact(shot, from: table, geometry: g),
                  contact.ball == line.target, contact.cushionsBefore == 0 else { return nil }
            let leaving = simd_length(contact.objectVelocity)
            guard leaving > 1e-6 else { return nil }
            let error = Self.angle(atan2(contact.objectVelocity.y, contact.objectVelocity.x) - desired)
            let speedRatio = objectSpeed / leaving
            if abs(error) < 2e-5 && abs(speedRatio - 1) < 0.01 { return shot }
            var slope: Double
            if let p = previous, abs(shot.aim - p.aim) > 1e-9 {
                slope = (error - p.error) / (shot.aim - p.aim)
            } else {
                // The ghost-ball gain, with the sign of a cut: turning the
                // aim toward the ball's centre thickens the hit.
                let side = simd_cross(SIMD3(cos(shot.aim), sin(shot.aim), 0),
                                      SIMD3(line.direction.x, line.direction.y, 0)).z
                slope = -(1 + line.cueTravel / (2 * g.ballRadius * max(cos(line.cut), 0.1))) * (side >= 0 ? 1 : -1)
            }
            previous = (shot.aim, error)
            if slope.isFinite && abs(slope) > 1e-6 && abs(error) >= 2e-5 { shot.aim -= error / slope }
            let speed = PoolShot.speed(forPower: shot.power) * min(max(speedRatio, 0.6), 1.6)
            shot.power = PoolShot.power(forSpeed: speed)
        }
        return shot
    }

    static func angle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi }
        if x < -.pi { x += 2 * .pi }
        return x
    }

    // MARK: Values

    /// What a simulated shot is worth to the computer: the rules' verdict,
    /// then position (its next shot) or leave (the opponent's), weighted by
    /// how likely it is to be executed as simulated.
    func value(of result: PoolShotResult, before: PoolTableState, line: PoolAILine?) -> Double {
        let outcome = PoolRules.evaluate(result, before: before, state: rules, geometry: g)
        if let over = outcome.gameOver { return over.winner == me ? 1000 : -1000 }
        if outcome.foul != nil { return -160 }
        var value: Double
        if outcome.continuesTurn {
            let next = nextShotQuality(outcome.table, outcome.newState, error: PoolAI.effectiveAimError(profile))
            value = 100 + profile.position * 60 * next
            // Pocketing the opponent's balls is doing their work for them.
            if rules.mode == .eightBall, let mine = outcome.newState.group(of: me) {
                value -= 4 * Double(result.pocketed.filter { mine.opposite.contains($0.ball) }.count)
            }
            if let line {
                // The simulation is the stroke played perfectly; a real one
                // succeeds about as often as the geometry says.
                let p = line.probability
                value = p * value + (1 - p) * -35
            }
        } else {
            let leave = nextShotQuality(outcome.table, outcome.newState, error: PoolAI.playerAimError)
            value = -70 * leave
        }
        return value
    }

    /// How good the best shot is for whoever shoots next, 0…1.
    func nextShotQuality(_ table: PoolTableState, _ state: PoolRuleState, error: Double) -> Double {
        if state.isOver { return 0 }
        let planner = PoolAIPlanner(geometry: g, rules: state, profile: profile)
        let found = planner.lines(from: table, for: state, error: error)
        guard let first = found.first else { return state.ballInHand != nil ? 0.9 : 0 }
        let second = found.dropFirst().first(where: { $0.target != first.target })?.probability ?? 0
        return min(1, first.probability + 0.15 * second)
    }

    // MARK: Safety and kicks

    /// Soft legal contacts, thin to full on each ball it may hit, for the one
    /// that leaves the opponent the least.
    mutating func safetyShot(from table: PoolTableState) -> PoolAIDecision? {
        guard let cue = table.cueBall?.position else { return nil }
        let legal = PoolRules.legalFirstContacts(rules, table: table)
        var best: PoolAIDecision?
        for n in legal.sorted() {
            guard let ball = table.ball(n), ball.pocket == nil else { continue }
            let d = ball.position - cue
            let dist = simd_length(d)
            guard dist > 2 * g.ballRadius else { continue }
            let centre = atan2(d.y, d.x)
            for thickness in [-0.8, -0.45, 0.0, 0.45, 0.8] {
                let offset = asin(min(max(thickness * 2 * g.ballRadius / dist, -1), 1))
                for power in [0.2, 0.3, 0.42] {
                    let shot = PoolShot(aim: centre + offset, power: power)
                    let result = simulate(shot, table)
                    guard result.firstContact == n else { continue }
                    let v = value(of: result, before: table, line: nil)
                    if v > (best?.expectedValue ?? -.infinity) {
                        best = PoolAIDecision(placement: nil, shot: shot, planned: shot, intent: .safety(ball: n),
                                              expectedValue: v, simulations: 0)
                    }
                }
            }
        }
        return best
    }

    /// Strokes all round the compass at two speeds, for a legal hit when no
    /// ball can be struck directly.
    mutating func kickShot(from table: PoolTableState) -> PoolAIDecision? {
        var best: PoolAIDecision?
        let count = 96
        for k in 0..<count {
            let aim = Double(k) / Double(count) * 2 * .pi
            for power in [0.4, 0.58] {
                let shot = PoolShot(aim: aim, power: power)
                let result = simulate(shot, table)
                let v = value(of: result, before: table, line: nil)
                if v > (best?.expectedValue ?? -.infinity) {
                    best = PoolAIDecision(placement: nil, shot: shot, planned: shot, intent: .kick,
                                          expectedValue: v, simulations: 0)
                }
            }
        }
        return best
    }
}
