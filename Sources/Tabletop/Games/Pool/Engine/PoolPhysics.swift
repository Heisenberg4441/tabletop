//
//  PoolPhysics.swift
//  Pool balls on cloth: the stroke, sliding and rolling, ball–ball and
//  ball–cushion impacts, and pockets that take good balls and spit out bad
//  ones.
//
//  The model is the one the pool-physics literature converged on (Marlow;
//  Leckie & Greenspan; Han's cushion impulse; Alciatore's throw friction):
//
//  * A ball's contact point with the cloth moves at u = v + ω × (−R ẑ).
//    While u ≠ 0 the ball SLIDES: kinetic friction μs·g acts against û, which
//    slows v and spins ω toward rolling. û keeps its direction for the whole
//    slide, so the slide is a parabola in closed form and ends after
//    exactly 2|u|/(7 μs g) — the "2/7 law" (a stun ball ends up rolling at
//    5/7 of its speed) falls out of it.
//  * Once u = 0 the ball ROLLS: only rolling resistance μr·g slows it, in a
//    straight line, until it stops at |v|/(μr g).
//  * Spin about the vertical (english) decays at its own constant rate in
//    every state and never bends the path on the cloth; it acts at cushions
//    and, through friction, on the object ball.
//
//  Because every state has constant acceleration, a ball's position is an
//  exact quadratic in time until its next state change. The simulation
//  advances in steps that never cross a state change (so positions and spins
//  are exact at every step end, never integrated), and never last longer
//  than keeps a ball's path within five microns of its chord. Collisions are
//  found by sweeping those chords — a quadratic per pair, per cushion and per
//  jaw point — so a break-speed ball cannot pass through anything no matter
//  how long the step. The simulation then jumps to the earliest contact,
//  resolves every contact that exists at that instant together, and carries
//  on. Contacts at one instant are solved simultaneously (a small projected
//  Jacobi solve per touching cluster), not one after another, so a symmetric
//  rack broken straight on stays symmetric.
//
//  Everything is plain Double arithmetic in a fixed order, so the same shot
//  from the same table gives the same result bit for bit — the computer
//  opponent's prediction and the shot the player then watches are one and
//  the same simulation. Recording the trajectory reads the state and never
//  feeds back into it.
//

import Foundation
import simd

// MARK: - Result

struct PoolShotResult: Sendable {
    /// Everything that happened, in time order.
    let events: [PoolShotEvent]
    /// The first object ball the cue ball touched, or nil if it touched none.
    let firstContact: Int?
    /// Balls that dropped, in the order they dropped (the cue ball included).
    let pocketed: [(ball: Int, pocket: Int)]
    /// Whether any ball struck a cushion at or after the first contact.
    let railAfterFirstContact: Bool
    /// The table with everything at rest.
    let final: PoolTableState
    /// The motion for playback; nil unless asked for.
    let trajectory: PoolTrajectory?

    /// The cue ball went down.
    let scratched: Bool
    /// When the first contact happened, seconds after the stroke.
    let firstContactTime: Double?
    /// Object balls that struck a cushion at any point (the break's rule of
    /// four is written in these).
    let objectBallsToRail: Set<Int>
    /// Cushions the cue ball struck before its first contact (a kick).
    let cueCushionsBeforeContact: Int
    /// Seconds from the stroke until the last ball stopped.
    let duration: Double

    func pocketed(_ ball: Int) -> Bool { pocketed.contains { $0.ball == ball } }
}

// MARK: - Physics

enum PoolPhysics {

    /// The constants of the model. `standard` is tuned to a clean
    /// tournament cloth and phenolic balls; tests may vary them.
    struct Parameters: Sendable {
        var gravity = 9.81
        /// Ball–cloth sliding friction.
        var slidingFriction = 0.20
        /// Rolling resistance of the cloth.
        var rollingResistance = 0.008
        /// Decay of spin about the vertical (english) against the cloth.
        var spinFriction = 0.025
        /// Ball–ball coefficient of restitution.
        var ballRestitution = 0.96
        /// Ball–cushion friction, which is what lets english change a
        /// rebound angle.
        var cushionFriction = 0.20
        /// Ball mass over cue mass (170 g over 540 g): how much speed an
        /// off-centre hit costs.
        var ballToCueMass = 0.315
        /// Ball mass over the cue's effective end mass, which sets squirt —
        /// how far english pushes the cue ball off the line of the cue. 25
        /// is a modern low-deflection shaft: about 2° at full english.
        var ballToEndMass = 25.0
        /// The tip offset a stroke can use without miscueing, in ball radii.
        var safeTipOffset = 0.5
        /// A shot is cut off after this long, however unlikely.
        var maximumDuration = 120.0

        static let standard = Parameters()

        /// Rebound speed over approach speed, straight into a cushion: lively
        /// for a soft ball, softer for a hard one, and nothing at all for a
        /// ball that barely touches it (else a ball pressed to a rail by its
        /// own spin would bounce for ever in shorter and shorter hops).
        func cushionRestitution(normalSpeed v: Double) -> Double {
            if v < 0.01 { return 0 }
            return min(max(0.84 - 0.035 * v, 0.66), 0.84)
        }

        /// Alciatore's fit for ball–ball friction, which is highest for the
        /// slow, sticky contacts that throw a ball most.
        func ballFriction(slipSpeed v: Double) -> Double {
            9.951e-3 + 0.108 * exp(-1.088 * v)
        }
    }

    // MARK: Entry points

    static func simulate(_ shot: PoolShot, from table: PoolTableState,
                         geometry: PoolTableGeometry = .standard, record: Bool) -> PoolShotResult {
        simulate(shot, from: table, geometry: geometry, record: record, parameters: .standard)
    }

    static func simulate(_ shot: PoolShot, from table: PoolTableState, geometry: PoolTableGeometry,
                         record: Bool, parameters: Parameters,
                         observer: ((PoolTableState, Double) -> Void)? = nil) -> PoolShotResult {
        var sim = PoolSimulator(table: table, geometry: geometry, parameters: parameters, record: record)
        sim.observer = observer
        if let cue = sim.index(of: 0) {
            let (v, w) = strike(shot, geometry: geometry, parameters: parameters)
            sim.balls[cue].v = v
            sim.balls[cue].w = w
            sim.classify(cue)
        }
        sim.run()
        return sim.result()
    }

    /// Runs the shot only until the cue ball first touches another ball and
    /// reports what it did: which ball, and how both left the contact. The
    /// computer uses it to correct its aim for throw and squirt — it is the
    /// same simulation as the real shot, so the correction is exact.
    static func firstContact(_ shot: PoolShot, from table: PoolTableState,
                             geometry: PoolTableGeometry = .standard,
                             parameters: Parameters = .standard)
        -> (ball: Int, objectVelocity: SIMD2<Double>, cueVelocity: SIMD2<Double>,
            cuePosition: SIMD2<Double>, cushionsBefore: Int)? {
        var sim = PoolSimulator(table: table, geometry: geometry, parameters: parameters, record: false)
        sim.stopAtFirstCueContact = true
        guard let cue = sim.index(of: 0) else { return nil }
        let (v, w) = strike(shot, geometry: geometry, parameters: parameters)
        sim.balls[cue].v = v
        sim.balls[cue].w = w
        sim.classify(cue)
        sim.run()
        guard let hit = sim.firstContactBall, let obj = sim.index(of: hit) else { return nil }
        return (hit, sim.balls[obj].v, sim.balls[cue].v, sim.balls[cue].p, sim.cueCushionsBeforeContact)
    }

    /// The cue ball's velocity and spin the instant the tip leaves it.
    ///
    /// The tip meets the ball at an offset (a to the side, b up) from the
    /// centre. A centre hit sends the ball off at the power's speed; an
    /// off-centre hit spends some of the stroke on spin (the standard
    /// cue–ball impulse, with the cue's mass in it), spins the ball about
    /// the axis the offset gives — follow, draw, english — and, with side
    /// offset, squirts it a little away from the side the tip struck.
    static func strike(_ shot: PoolShot, geometry: PoolTableGeometry = .standard,
                       parameters prm: Parameters = .standard) -> (SIMD2<Double>, SIMD3<Double>) {
        let r = geometry.ballRadius
        let tip = shot.clampedTip * prm.safeTipOffset          // in radii
        let a = tip.x, b = tip.y
        let centreSpeed = PoolShot.speed(forPower: shot.power)
        let speed = centreSpeed * (1 + prm.ballToCueMass)
            / (1 + prm.ballToCueMass + 2.5 * (a * a + b * b))
        let d = shot.aim.isFinite ? shot.direction : SIMD2(1, 0)
        // Squirt (Alciatore): right english sends the ball left of the cue.
        let side = min(abs(a), 0.99)
        let squirt = atan(2.5 * side * (1 - side * side).squareRoot()
                          / (1 + prm.ballToEndMass + 2.5 * (1 - side * side))) * (a >= 0 ? 1 : -1)
        let c = cos(squirt), s = sin(squirt)
        let travel = SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
        // ω = (r × F)/I with I = 2/5 m R², the offset in radii: side offset
        // spins the ball about the vertical, vertical offset about the
        // horizontal axis square to the stroke.
        let k = 2.5 * speed / r
        let roll = SIMD3(-d.y, d.x, 0)          // ẑ × d, the axis of natural roll
        let w = SIMD3(0, 0, k * a) + roll * (k * b)
        return (travel * speed, w)
    }
}

// MARK: - The simulator

/// A ball's state of motion. Each has constant acceleration, so a ball's
/// path within a state is exact in closed form.
enum PoolMotion: UInt8, Sendable {
    case stationary, spinning, sliding, rolling, pocketed

    var moves: Bool { self == .sliding || self == .rolling }
}

struct PoolSimBall {
    let number: Int
    var p: SIMD2<Double>
    var v: SIMD2<Double>
    var w: SIMD3<Double>
    var q: simd_quatd
    var mode: PoolMotion
    var pocket: Int?

    // The current state's constants, refreshed at the start of every step.
    var accel = SIMD2<Double>.zero        // linear acceleration
    var spinAccel = SIMD2<Double>.zero    // dω/dt about the horizontal axes while sliding
    var transition = Double.infinity      // time left in the current state
    var chord = SIMD2<Double>.zero        // average velocity over the step
    var reach = 0.0                       // |chord| × step
}

struct PoolSimulator {
    let geo: PoolTableGeometry
    let prm: PoolPhysics.Parameters
    var balls: [PoolSimBall]
    var time = 0.0

    var events: [PoolShotEvent] = []
    var pocketedList: [(ball: Int, pocket: Int)] = []
    var firstContactBall: Int?
    var firstContactTime: Double?
    var objectBallsToRail = Set<Int>()
    var cueCushionsBeforeContact = 0
    var railAfterContact = false
    var stopAtFirstCueContact = false
    var observer: ((PoolTableState, Double) -> Void)?
    var recorder: PoolTrajectoryRecorder?

    // Derived constants.
    let r: Double
    let twoR: Double
    let spinDecay: Double          // |dωz/dt|
    let slideDecel: Double
    let rollDecel: Double
    let slideSpin: Double          // 5 μs g / (2R)
    let sinNose: Double, cosNose: Double
    /// Longest step for a sliding and a rolling ball: the chord of a path
    /// with acceleration a over h strays ⅛ a h² from it, held under 5 µm.
    let slideStep: Double, rollStep: Double
    /// Contacts closer than this count as touching.
    static let touch = 1e-9
    /// Slower than this, a touching pair is not approaching.
    static let approach = 1e-7

    init(table: PoolTableState, geometry: PoolTableGeometry, parameters: PoolPhysics.Parameters, record: Bool) {
        geo = geometry
        prm = parameters
        r = geometry.ballRadius
        twoR = 2 * r
        let g = parameters.gravity
        spinDecay = 5 * parameters.spinFriction * g / (2 * r)
        slideDecel = parameters.slidingFriction * g
        rollDecel = parameters.rollingResistance * g
        slideSpin = 5 * parameters.slidingFriction * g / (2 * r)
        sinNose = min(max((geometry.cushionNoseHeight - r) / r, -0.9), 0.9)
        cosNose = (1 - sinNose * sinNose).squareRoot()
        let tolerance = 5e-6
        slideStep = (8 * tolerance / max(slideDecel, 1e-9)).squareRoot()
        rollStep = min((8 * tolerance / max(rollDecel, 1e-9)).squareRoot(), 0.05)

        balls = table.balls.map { b in
            PoolSimBall(number: b.number,
                        p: b.pocket.flatMap { id in geometry.pockets.first { $0.id == id }?.center } ?? b.position,
                        v: b.pocket == nil ? b.velocity : .zero,
                        w: b.pocket == nil ? b.spin : .zero,
                        q: b.orientation, mode: b.pocket == nil ? .stationary : .pocketed, pocket: b.pocket)
        }
        for i in balls.indices where balls[i].mode != .pocketed {
            sanitise(i)
            classify(i)
        }
        separateOverlaps(all: true)
        if record {
            recorder = PoolTrajectoryRecorder(balls: balls, geometry: geometry)
        }
    }

    func index(of number: Int) -> Int? {
        balls.firstIndex { $0.number == number }
    }

    /// A damaged save or a bad input must not poison the arithmetic.
    mutating func sanitise(_ i: Int) {
        if !(balls[i].p.x.isFinite && balls[i].p.y.isFinite) { balls[i].p = geo.headSpot }
        if !(balls[i].v.x.isFinite && balls[i].v.y.isFinite) { balls[i].v = .zero }
        if !(balls[i].w.x.isFinite && balls[i].w.y.isFinite && balls[i].w.z.isFinite) { balls[i].w = .zero }
        let hx = geo.length / 2 - r, hy = geo.width / 2 - r
        balls[i].p = SIMD2(min(max(balls[i].p.x, -hx), hx), min(max(balls[i].p.y, -hy), hy))
    }

    // MARK: States

    /// Velocity of the ball's contact point with the cloth.
    @inline(__always)
    func slip(_ v: SIMD2<Double>, _ w: SIMD3<Double>) -> SIMD2<Double> {
        SIMD2(v.x - r * w.y, v.y + r * w.x)
    }

    /// Picks the state a ball's velocity and spin put it in, and snaps the
    /// spin exactly onto rolling when the slip is only rounding.
    mutating func classify(_ i: Int) {
        guard balls[i].mode != .pocketed else { return }
        let v = balls[i].v, w = balls[i].w
        let u = slip(v, w)
        if simd_length_squared(u) > 1e-12 {
            balls[i].mode = .sliding
        } else if simd_length_squared(v) > 1e-12 {
            balls[i].mode = .rolling
            balls[i].w = SIMD3(-v.y / r, v.x / r, w.z)
        } else if abs(w.z) > 1e-4 {
            balls[i].mode = .spinning
            balls[i].v = .zero
            balls[i].w = SIMD3(0, 0, w.z)
        } else {
            balls[i].mode = .stationary
            balls[i].v = .zero
            balls[i].w = .zero
        }
    }

    /// The constant accelerations of the ball's state and how long it lasts.
    mutating func prepare(_ i: Int) {
        let b = balls[i]
        switch b.mode {
        case .sliding:
            let u = slip(b.v, b.w)
            let len = simd_length(u)
            let dir = u / len
            balls[i].accel = -slideDecel * dir
            balls[i].spinAccel = SIMD2(-dir.y, dir.x) * slideSpin
            balls[i].transition = len / (3.5 * slideDecel)
        case .rolling:
            let len = simd_length(b.v)
            balls[i].accel = -rollDecel * (b.v / len)
            balls[i].spinAccel = .zero
            balls[i].transition = len / rollDecel
        case .spinning:
            balls[i].accel = .zero
            balls[i].spinAccel = .zero
            balls[i].transition = abs(b.w.z) / spinDecay
        case .stationary, .pocketed:
            balls[i].accel = .zero
            balls[i].spinAccel = .zero
            balls[i].transition = .infinity
        }
    }

    /// The vertical spin after `dt`: it decays linearly and stops at zero.
    @inline(__always)
    func decayed(_ wz: Double, _ dt: Double) -> Double {
        let m = abs(wz) - spinDecay * dt
        return m <= 0 ? 0 : (wz < 0 ? -m : m)
    }

    /// Where the ball is and how it is spinning `dt` into its current state
    /// (dt no longer than the state lasts). Exact.
    @inline(__always)
    func state(of b: PoolSimBall, after dt: Double) -> (p: SIMD2<Double>, v: SIMD2<Double>, w: SIMD3<Double>) {
        switch b.mode {
        case .sliding:
            let v = b.v + b.accel * dt
            let wxy = SIMD2(b.w.x, b.w.y) + b.spinAccel * dt
            return (b.p + b.v * dt + b.accel * (0.5 * dt * dt), v, SIMD3(wxy.x, wxy.y, decayed(b.w.z, dt)))
        case .rolling:
            let v = b.v + b.accel * dt
            return (b.p + b.v * dt + b.accel * (0.5 * dt * dt), v, SIMD3(-v.y / r, v.x / r, decayed(b.w.z, dt)))
        case .spinning:
            return (b.p, .zero, SIMD3(0, 0, decayed(b.w.z, dt)))
        case .stationary, .pocketed:
            return (b.p, b.v, b.w)
        }
    }

    /// The ball's orientation `dt` into its state: turned about the mean
    /// angular velocity over the interval, which is exact whenever the axis
    /// holds still (rolling, spinning) and within a hair of it while sliding.
    @inline(__always)
    func orientation(of b: PoolSimBall, after dt: Double) -> simd_quatd {
        guard b.mode != .stationary, b.mode != .pocketed, dt > 0 else { return b.q }
        let mid = state(of: b, after: dt * 0.5).w
        let angle = simd_length(mid) * dt
        guard angle > 1e-12 else { return b.q }
        let turn = simd_quatd(angle: angle, axis: mid / simd_length(mid))
        return simd_normalize(turn * b.q)
    }

    /// Moves a ball `dt` along its state, and into the next state if that is
    /// where the interval ends.
    mutating func advance(_ i: Int, by dt: Double) {
        let b = balls[i]
        guard b.mode != .stationary, b.mode != .pocketed else { return }
        if dt >= b.transition - 1e-13 {
            let t = b.transition
            let s = state(of: b, after: t)
            balls[i].q = orientation(of: b, after: t)
            balls[i].p = s.p
            switch b.mode {
            case .sliding:
                balls[i].v = s.v
                balls[i].w = SIMD3(-s.v.y / r, s.v.x / r, s.w.z)
                balls[i].mode = simd_length_squared(s.v) > 1e-12 ? .rolling : .spinning
                if balls[i].mode == .spinning {
                    balls[i].v = .zero
                    balls[i].w = SIMD3(0, 0, s.w.z)
                }
            case .rolling:
                balls[i].v = .zero
                balls[i].w = SIMD3(0, 0, s.w.z)
                balls[i].mode = .spinning
            case .spinning, .stationary, .pocketed:
                balls[i].w = .zero
                balls[i].mode = .stationary
            }
            if balls[i].mode == .spinning && abs(balls[i].w.z) <= 1e-4 {
                balls[i].w = .zero
                balls[i].mode = .stationary
            }
            // Whatever is left of the interval (rounding only) is spent at
            // rest in the new state; the next step picks it up properly.
            recorder?.mark(i)
        } else {
            let s = state(of: b, after: dt)
            balls[i].q = orientation(of: b, after: dt)
            balls[i].p = s.p
            balls[i].v = s.v
            balls[i].w = s.w
        }
    }

    // MARK: The loop

    mutating func run() {
        let n = balls.count
        var iterations = 0
        let hx = geo.innerHalfExtent.x, hy = geo.innerHalfExtent.y
        while iterations < 400_000 && time < prm.maximumDuration {
            iterations += 1
            // The step: as long as the chords stay true, never past any
            // ball's change of state.
            var h = 0.05
            var anyMoving = false
            for i in 0..<n {
                let mode = balls[i].mode
                guard mode != .stationary && mode != .pocketed else { continue }
                prepare(i)
                anyMoving = true
                h = min(h, balls[i].transition)
                if mode == .sliding { h = min(h, slideStep) } else if mode == .rolling { h = min(h, rollStep) }
            }
            guard anyMoving else { break }
            h = max(h, 0)
            for i in 0..<n {
                if balls[i].mode.moves {
                    let v = balls[i].v, a = balls[i].accel
                    balls[i].chord = v + a * (0.5 * h)
                    balls[i].reach = simd_length(balls[i].chord) * h
                } else {
                    balls[i].chord = .zero
                    balls[i].reach = 0
                }
            }

            // The earliest contact within the step.
            var first = h
            var hit = false
            for i in 0..<n {
                let bi = balls[i]
                if bi.mode == .pocketed { continue }
                let iMoves = bi.mode.moves
                for j in (i + 1)..<n {
                    let bj = balls[j]
                    if bj.mode == .pocketed || !(iMoves || bj.mode.moves) { continue }
                    let dp = bj.p - bi.p
                    let limit = twoR + bi.reach + bj.reach
                    let d2 = simd_length_squared(dp)
                    if d2 > limit * limit { continue }
                    if let s = pairTime(dp: dp, dc: bj.chord - bi.chord, dv: bj.v - bi.v, distance: twoR, within: first) {
                        if s < first || !hit { first = s; hit = true }
                    }
                }
                guard iMoves else { continue }
                // Near a rail? The inner rectangle is out of every cushion's
                // and pocket's reach.
                let p0 = bi.p, p1 = bi.p + bi.chord * h
                if abs(p0.x) < hx && abs(p0.y) < hy && abs(p1.x) < hx && abs(p1.y) < hy { continue }
                for k in 0..<geo.pockets.count {
                    if let s = captureTime(p: p0, c: bi.chord, pocket: geo.pockets[k], within: first) {
                        if s < first || !hit { first = s; hit = true }
                    }
                }
                for k in 0..<geo.cushions.count {
                    if let s = cushionTime(p: p0, c: bi.chord, v: bi.v, segment: geo.cushions[k], within: first) {
                        if s < first || !hit { first = s; hit = true }
                    }
                }
            }

            // Advance everything to it.
            let dt = hit ? first : h
            if recorder != nil { recordInterior(duration: dt) }
            for i in 0..<n { advance(i, by: dt) }
            time += dt
            if hit {
                resolveContacts()
                if stopAtFirstCueContact && firstContactBall != nil { break }
            }
            separateOverlaps(all: false)
            recorder?.settle(balls: balls, at: time)
            if let observer { observer(tableState(), time) }
        }
        // Whatever the cap cut short comes to rest where it is.
        for i in balls.indices where balls[i].mode != .pocketed && balls[i].mode != .stationary && !stopAtFirstCueContact {
            balls[i].v = .zero
            balls[i].w = .zero
            balls[i].mode = .stationary
        }
        recorder?.settle(balls: balls, at: time)
    }

    /// Keyframes inside a step for balls turning fast (more than a radian in
    /// it), from the exact state, and a keyframe owed at its end for every
    /// ball that moves at all.
    mutating func recordInterior(duration dt: Double) {
        guard dt > 0 else { return }
        for i in balls.indices {
            let b = balls[i]
            guard b.mode != .stationary && b.mode != .pocketed else { continue }
            recorder?.owe(i)
            let turn = simd_length(state(of: b, after: min(dt, b.transition) * 0.5).w) * dt
            let pieces = Int((turn / PoolTrajectoryRecorder.maximumTurn).rounded(.up))
            guard pieces > 1 else { continue }
            for k in 1..<pieces {
                let tau = dt * Double(k) / Double(pieces)
                guard tau < b.transition else { break }
                let at = state(of: b, after: tau).p, turned = orientation(of: b, after: tau)
                recorder?.add(i, time: time + tau, position: at, orientation: turned)
            }
        }
    }

    // MARK: Sweeps

    /// When two balls moving along their chords come within `distance`, if
    /// they do before `limit`. `dp`, `dc`, `dv`: second minus first.
    @inline(__always)
    func pairTime(dp: SIMD2<Double>, dc: SIMD2<Double>, dv: SIMD2<Double>, distance: Double, within limit: Double) -> Double? {
        let c = simd_length_squared(dp) - distance * distance
        if c <= 2 * distance * Self.touch {
            // Already touching: a contact now if they are closing, else none
            // (the overlap pass keeps a resting pair from sinking together).
            let len = simd_length(dp)
            return simd_dot(dp, dv) < -Self.approach * len ? 0 : nil
        }
        let b = simd_dot(dp, dc)
        if b >= 0 { return nil }
        let a = simd_length_squared(dc)
        let disc = b * b - a * c
        if disc < 0 { return nil }
        let s = c / (-b + disc.squareRoot())
        return s <= limit ? s : nil
    }

    /// When a ball's centre enters a pocket's capture circle.
    @inline(__always)
    func captureTime(p: SIMD2<Double>, c: SIMD2<Double>, pocket: PoolPocket, within limit: Double) -> Double? {
        let dp = p - pocket.center
        let cc = simd_length_squared(dp) - pocket.captureRadius * pocket.captureRadius
        if cc <= 0 { return 0 }
        let b = simd_dot(dp, c)
        if b >= 0 { return nil }
        let a = simd_length_squared(c)
        let disc = b * b - a * cc
        if disc < 0 { return nil }
        let s = cc / (-b + disc.squareRoot())
        return s <= limit ? s : nil
    }

    /// When a ball meets a cushion segment: its face, or either end.
    @inline(__always)
    func cushionTime(p: SIMD2<Double>, c: SIMD2<Double>, v: SIMD2<Double>, segment g: PoolCushionSegment,
                     within limit: Double) -> Double? {
        var best: Double?
        let rel = p - g.a
        let d0 = simd_dot(g.normal, rel)
        let along = simd_dot(g.tangent, rel)
        if d0 - r <= Self.touch {
            if d0 > -r && along >= 0 && along <= g.length && simd_dot(g.normal, v) < -Self.approach { return 0 }
        } else {
            let dn = simd_dot(g.normal, c)
            if dn < 0 {
                let s = (d0 - r) / -dn
                if s <= limit {
                    let at = along + simd_dot(g.tangent, c) * s
                    if at >= 0 && at <= g.length { best = s }
                }
            }
        }
        let lim = best ?? limit
        if let s = pairTime(dp: g.a - p, dc: -c, dv: -v, distance: r, within: lim) { best = min(best ?? s, s) }
        if let s = pairTime(dp: g.b - p, dc: -c, dv: -v, distance: r, within: best ?? limit) { best = min(best ?? s, s) }
        return best
    }

    // MARK: Contacts

    struct Contact {
        var i: Int
        var j: Int                 // -1: a cushion
        var normal: SIMD2<Double>  // from i toward j (or into the cushion)
        var approach: Double       // closing speed along the normal, > 0
    }

    /// Resolves everything touching at this instant: pockets first, then
    /// every closing contact, each touching cluster solved together.
    mutating func resolveContacts() {
        let n = balls.count
        // Pockets.
        for i in 0..<n where balls[i].mode.moves || balls[i].mode == .spinning {
            for pocket in geo.pockets {
                let d = simd_length_squared(balls[i].p - pocket.center)
                if d <= pocket.captureRadius * pocket.captureRadius * (1 + 1e-12) {
                    capture(i, in: pocket)
                    break
                }
            }
        }
        // Closing contacts.
        var contacts: [Contact] = []
        let hx = geo.innerHalfExtent.x - 1e-6, hy = geo.innerHalfExtent.y - 1e-6
        for i in 0..<n {
            let bi = balls[i]
            if bi.mode == .pocketed { continue }
            for j in (i + 1)..<n {
                let bj = balls[j]
                if bj.mode == .pocketed || (bi.mode == .stationary && bj.mode == .stationary) { continue }
                let dp = bj.p - bi.p
                let d2 = simd_length_squared(dp)
                let reach = twoR + Self.touch
                if d2 > reach * reach { continue }
                let len = d2.squareRoot()
                guard len > 1e-12 else { continue }
                let nrm = dp / len
                let closing = simd_dot(bi.v - bj.v, nrm)
                if closing > Self.approach {
                    contacts.append(Contact(i: i, j: j, normal: nrm, approach: closing))
                }
            }
            guard bi.mode.moves, abs(bi.p.x) >= hx || abs(bi.p.y) >= hy else { continue }
            var mine: [SIMD2<Double>] = []
            for g in geo.cushions {
                let q = g.closestPoint(to: bi.p)
                let dp = q - bi.p
                let d2 = simd_length_squared(dp)
                let reach = r + Self.touch
                if d2 > reach * reach { continue }
                let len = d2.squareRoot()
                guard len > 1e-12 else { continue }
                let nrm = dp / len
                let closing = simd_dot(bi.v, nrm)
                // A jaw point is the end of two segments; count it once.
                if closing > Self.approach && !mine.contains(where: { simd_distance_squared($0, q) < 1e-18 }) {
                    mine.append(q)
                    contacts.append(Contact(i: i, j: -1, normal: nrm, approach: closing))
                }
            }
        }
        guard !contacts.isEmpty else { return }

        // Log them in a fixed order, then solve.
        for c in contacts {
            if c.j >= 0 {
                note(ballBall: c.i, c.j)
            } else {
                note(cushion: c.i)
            }
        }
        if needsSoftContact(contacts) {
            runSoftPhase(contacts)
            return
        }
        // Contacts that share no ball are independent; each touching cluster
        // is solved on its own, a lone contact by its exact model.
        for cluster in clusters(of: contacts) {
            if cluster.count == 1 {
                let c = cluster[0]
                if c.j >= 0 { collide(c.i, c.j, normal: c.normal) } else { bounce(c.i, normal: c.normal) }
            } else {
                solveTogether(cluster)
            }
        }
        for c in contacts {
            classify(c.i)
            if c.j >= 0 { classify(c.j) }
            recorder?.mark(c.i)
            if c.j >= 0 { recorder?.mark(c.j) }
        }
    }

    /// Groups contacts into clusters that share balls (union–find over the
    /// balls), each cluster in the original order.
    func clusters(of contacts: [Contact]) -> [[Contact]] {
        if contacts.count == 1 { return [contacts] }
        var parent = Array(0..<balls.count)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { x = parent[x] }
            return x
        }
        for c in contacts where c.j >= 0 {
            let a = root(c.i), b = root(c.j)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        var order: [Int] = []
        var groups: [Int: [Contact]] = [:]
        for c in contacts {
            let key = root(c.i)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
        return order.compactMap { groups[$0] }
    }

    mutating func note(ballBall i: Int, _ j: Int) {
        let a = balls[i].number, b = balls[j].number
        events.append(.ballBall(min(a, b), max(a, b), time: time))
        if firstContactBall == nil && (a == 0 || b == 0) {
            firstContactBall = a == 0 ? b : a
            firstContactTime = time
        }
    }

    mutating func note(cushion i: Int) {
        let number = balls[i].number
        events.append(.cushion(number, time: time))
        if number != 0 { objectBallsToRail.insert(number) }
        if firstContactBall != nil {
            railAfterContact = true
        } else if number == 0 {
            cueCushionsBeforeContact += 1
        }
    }

    mutating func capture(_ i: Int, in pocket: PoolPocket) {
        recorder?.drop(i, ball: balls[i], into: pocket, at: time)
        balls[i].mode = .pocketed
        balls[i].pocket = pocket.id
        balls[i].p = pocket.center
        balls[i].v = .zero
        balls[i].w = .zero
        events.append(.pocketed(balls[i].number, pocket: pocket.id, time: time))
        pocketedList.append((balls[i].number, pocket.id))
    }

    /// Two balls, one contact: restitution along the line of centres, then
    /// friction between the surfaces (throw and spin transfer), limited to
    /// what stops their slip.
    mutating func collide(_ i: Int, _ j: Int, normal n: SIMD2<Double>) {
        let closing = simd_dot(balls[i].v - balls[j].v, n)
        guard closing > 0 else { return }
        let e = closing < 0.005 ? 0 : prm.ballRestitution
        let jn = (1 + e) * closing / 2
        let f = friction(i, j, normal: n, normalImpulse: jn)
        balls[i].v -= n * jn
        balls[j].v += n * jn
        apply(f, i, j)
    }

    typealias Friction = (dvi: SIMD2<Double>, dwi: SIMD3<Double>, dvj: SIMD2<Double>, dwj: SIMD3<Double>)

    /// The friction impulse between two touching balls, per unit mass, from
    /// their velocities before the impact (Alciatore's throw model): it acts
    /// against the slip of the surfaces at the contact, up to μ times the
    /// normal impulse or whatever stops the slip, whichever is smaller.
    func friction(_ i: Int, _ j: Int, normal n2: SIMD2<Double>, normalImpulse jn: Double) -> Friction {
        let n = SIMD3(n2.x, n2.y, 0)
        let bi = balls[i], bj = balls[j]
        let vi = SIMD3(bi.v.x, bi.v.y, 0), vj = SIMD3(bj.v.x, bj.v.y, 0)
        let rel = (vi + simd_cross(bi.w, n * r)) - (vj + simd_cross(bj.w, -n * r))
        let tangential = rel - n * simd_dot(rel, n)
        let slip = simd_length(tangential)
        guard slip > 1e-9 else { return (.zero, .zero, .zero, .zero) }
        let jt = min(prm.ballFriction(slipSpeed: slip) * jn, slip / 7)
        let impulse = -tangential / slip * jt            // on ball i
        // The cloth takes the vertical part of the linear impulse; the torque
        // it carries still acts.
        let torque = simd_cross(n * r, impulse) * (2.5 / (r * r))
        return (SIMD2(impulse.x, impulse.y), torque, SIMD2(-impulse.x, -impulse.y), torque)
    }

    mutating func apply(_ f: Friction, _ i: Int, _ j: Int) {
        balls[i].v += f.dvi
        balls[i].w += f.dwi
        balls[j].v += f.dvj
        balls[j].w += f.dwj
    }

    /// A ball into a cushion, jaw or jaw point (Han's impulse model). The
    /// nose meets the ball above its equator, so the impulse leans down into
    /// the cloth: part of the ball's topspin or draw is turned around by the
    /// rail, and english grips the rubber — running english opens the angle,
    /// reverse english closes it.
    mutating func bounce(_ i: Int, normal n: SIMD2<Double>) {
        let vx = simd_dot(balls[i].v, n)
        guard vx > 0 else { return }
        let horizontal = (1 + prm.cushionRestitution(normalSpeed: vx)) * vx
        let change = cushionImpulse(v: balls[i].v, w: balls[i].w, normal: n, horizontalImpulse: horizontal)
        balls[i].v += change.dv
        balls[i].w += change.dw
    }

    /// The velocity and spin change of a cushion impact whose normal impulse
    /// takes `horizontalImpulse` (per unit mass) off the ball's speed into
    /// the cushion. The friction at the contact is bounded by μ times the
    /// full (inclined) normal impulse, or by what stops the contact slipping.
    func cushionImpulse(v: SIMD2<Double>, w: SIMD3<Double>, normal n: SIMD2<Double>,
                        horizontalImpulse: Double) -> (dv: SIMD2<Double>, dw: SIMD3<Double>) {
        // Cushion frame: x into the cushion, y along it, z up. The contact
        // point is at R(c, 0, s) from the centre.
        let ex = n, ey = SIMD2(-n.y, n.x)
        let vx = simd_dot(v, ex), vy = simd_dot(v, ey)
        let wx = w.x * ex.x + w.y * ex.y
        let wy = w.x * ey.x + w.y * ey.y
        let s = sinNose, c = cosNose
        // The impulse along the line through the centre whose horizontal part
        // is the one asked for.
        let pn = horizontalImpulse / c
        // Slip of the contact point, in the tangent plane: along the cushion,
        // and along (−s, 0, c).
        let slipY = vy + r * (w.z * c - wx * s)
        let slipT = -vx * s - r * wy
        let slip = (slipY * slipY + slipT * slipT).squareRoot()
        var py = 0.0, pt = 0.0
        if slip > 1e-12 {
            let jt = min(prm.cushionFriction * pn, slip / 3.5)
            py = -jt * slipY / slip
            pt = -jt * slipT / slip
        }
        // Total impulse −pn(c, 0, s) + py ŷ + pt(−s, 0, c); the cloth absorbs
        // its vertical part, its torque about the centre is (r_I × P)/I.
        let px = -pn * c - pt * s
        let pz = -pn * s + pt * c
        let k = 2.5 / r
        let dwx = -k * s * py
        let dwy = k * (s * px - c * pz)
        let dwz = k * c * py
        return (ex * px + ey * py, SIMD3(ex.x * dwx + ey.x * dwy, ex.y * dwx + ey.y * dwy, dwz))
    }

    /// Several contacts at one instant sharing balls — a rack being struck,
    /// a ball pinned to a rail — solved as one: normal impulses by projected
    /// Jacobi iteration to each contact's own restitution target (the same
    /// for every contact in a mirror image, so symmetric input gives
    /// symmetric output), then each contact's friction from the solved
    /// impulses, all applied at once.
    mutating func solveTogether(_ contacts: [Contact]) {
        let m = contacts.count
        var degree = [Int](repeating: 0, count: balls.count)
        for c in contacts {
            degree[c.i] += 1
            if c.j >= 0 { degree[c.j] += 1 }
        }
        var targets = [Double](repeating: 0, count: m)
        for (k, c) in contacts.enumerated() {
            let e = c.j >= 0
                ? (c.approach < 0.005 ? 0 : prm.ballRestitution)
                : prm.cushionRestitution(normalSpeed: c.approach)
            targets[k] = -e * c.approach
        }
        var v = balls.map(\.v)
        let v0 = v
        var lambda = [Double](repeating: 0, count: m)
        var delta = [Double](repeating: 0, count: m)
        for _ in 0..<400 {
            var worst = 0.0
            for (k, c) in contacts.enumerated() {
                let rel = c.j >= 0 ? simd_dot(v[c.i] - v[c.j], c.normal) : simd_dot(v[c.i], c.normal)
                let residual = rel - targets[k]
                let inverseMass = c.j >= 0 ? 2.0 : 1.0
                let split = Double(max(degree[c.i], c.j >= 0 ? degree[c.j] : 1))
                let next = max(0, lambda[k] + residual / inverseMass / split)
                delta[k] = next - lambda[k]
                if lambda[k] > 0 || residual > 0 { worst = max(worst, abs(residual)) }
            }
            var changes: [Int: [SIMD2<Double>]] = [:]
            for (k, c) in contacts.enumerated() where delta[k] != 0 {
                lambda[k] += delta[k]
                changes[c.i, default: []].append(-c.normal * delta[k])
                if c.j >= 0 { changes[c.j, default: []].append(c.normal * delta[k]) }
            }
            for (i, list) in changes { v[i] += Self.orderedSum(list) }
            if worst < 1e-10 { break }
        }
        // Friction from the pre-impact state, then everything at once.
        var dv: [Int: [SIMD2<Double>]] = [:]
        var dw: [Int: [SIMD3<Double>]] = [:]
        for (k, c) in contacts.enumerated() where lambda[k] > 0 {
            if c.j >= 0 {
                let f = friction(c.i, c.j, normal: c.normal, normalImpulse: lambda[k])
                dv[c.i, default: []].append(f.dvi); dw[c.i, default: []].append(f.dwi)
                dv[c.j, default: []].append(f.dvj); dw[c.j, default: []].append(f.dwj)
            } else {
                // The cushion's own model with its normal impulse given; only
                // its tangential and spin parts are added — the normal part
                // is the one just solved.
                let change = cushionImpulse(v: v0[c.i], w: balls[c.i].w, normal: c.normal,
                                            horizontalImpulse: lambda[k])
                dv[c.i, default: []].append(change.dv - c.normal * simd_dot(change.dv, c.normal))
                dw[c.i, default: []].append(change.dw)
            }
        }
        for i in balls.indices where balls[i].mode != .pocketed {
            balls[i].v = v[i] + Self.orderedSum(dv[i] ?? [])
            balls[i].w += Self.orderedSum(dw[i] ?? [])
        }
    }

    // MARK: Soft contact

    /// An impact takes about 200 µs. A struck ball that is nearer another
    /// than it travels in that time touches it before the first impact is
    /// over — a rack, a frozen pair, a ball against a cluster — and treating
    /// such impacts as instants in sequence sends all the energy down the
    /// first straight line of balls like a Newton's cradle, which is not how
    /// a rack breaks. Those impacts are integrated through their duration
    /// instead, every touching pair a stiff damped spring.
    static let contactDuration = 2e-4
    static let softStep = 4e-6

    func needsSoftContact(_ contacts: [Contact]) -> Bool {
        for c in contacts where c.j >= 0 && c.approach > 0.3 {
            let reach = twoR + c.approach * Self.contactDuration * 2 + 1e-4
            let reach2 = reach * reach
            for k in balls.indices where k != c.i && k != c.j && balls[k].mode != .pocketed {
                if simd_distance_squared(balls[k].p, balls[c.i].p) < reach2
                    || simd_distance_squared(balls[k].p, balls[c.j].p) < reach2 { return true }
            }
        }
        return false
    }

    /// Integrates every ball–ball contact as a spring–dashpot (stiffness for
    /// a 200 µs impact, damping for the ball restitution, surface friction
    /// as in the impulse model) in 4 µs steps, until nothing touches. The
    /// cloth still acts on every ball between steps; cushions stay instant.
    ///
    /// Each ball's pushes are summed in a fixed order (smallest first, the
    /// negative of a tie first), so a ball squeezed symmetrically from two
    /// sides feels exactly no sideways push, and mirror-image balls feel
    /// mirror-image pushes, bit for bit.
    mutating func runSoftPhase(_ start: [Contact]) {
        let n = balls.count
        let omega = Double.pi / Self.contactDuration
        let lnE = log(max(prm.ballRestitution, 0.05))
        let zeta = -lnE / (Double.pi * Double.pi + lnE * lnE).squareRoot()
        let stiffness = omega * omega / 2, damping = zeta * omega
        let dt = Self.softStep
        let k = 8
        var touching = [Bool](repeating: false, count: n * n)
        for c in start where c.j >= 0 { touching[c.i * n + c.j] = true }
        var cdv = [SIMD2<Double>](repeating: .zero, count: n * k)
        var cdw = [SIMD3<Double>](repeating: .zero, count: n * k)
        var count = [Int](repeating: 0, count: n)
        let hx = geo.innerHalfExtent.x - 1e-6, hy = geo.innerHalfExtent.y - 1e-6
        var steps = 0
        while steps < 10_000 {
            steps += 1
            for i in 0..<n { count[i] = 0 }
            // A contact is a pair overlapping, or touching and closing (the
            // step that brings it into overlap); the phase lasts while any
            // contact is still lively.
            var anyContact = false
            var lively = false
            let reach = twoR + Self.touch
            for i in 0..<n where balls[i].mode != .pocketed {
                for j in (i + 1)..<n where balls[j].mode != .pocketed {
                    let dp = balls[j].p - balls[i].p
                    let d2 = simd_length_squared(dp)
                    if d2 >= reach * reach {
                        touching[i * n + j] = false
                        continue
                    }
                    let d = d2.squareRoot()
                    guard d > 1e-12 else { continue }
                    let nrm = dp / d
                    let overlap = twoR - d
                    let closing = simd_dot(balls[i].v - balls[j].v, nrm)
                    if overlap <= 0 && closing <= 0 {
                        touching[i * n + j] = false
                        continue
                    }
                    anyContact = true
                    if !touching[i * n + j] {
                        touching[i * n + j] = true
                        note(ballBall: i, j)
                        recorder?.mark(i)
                        recorder?.mark(j)
                    }
                    if closing > 0.02 || overlap > 2e-5 { lively = true }
                    guard overlap > 0 else { continue }
                    let jn = max(0, stiffness * overlap + damping * closing) * dt
                    guard jn > 0 else { continue }
                    let f = friction(i, j, normal: nrm, normalImpulse: jn)
                    if count[i] < k {
                        cdv[i * k + count[i]] = f.dvi - nrm * jn
                        cdw[i * k + count[i]] = f.dwi
                        count[i] += 1
                    }
                    if count[j] < k {
                        cdv[j * k + count[j]] = f.dvj + nrm * jn
                        cdw[j * k + count[j]] = f.dwj
                        count[j] += 1
                    }
                }
            }
            if !anyContact || !lively { break }
            for i in 0..<n where count[i] > 0 {
                balls[i].v += SIMD2(Self.orderedSum(cdv, i * k, count[i]) { $0.x },
                                    Self.orderedSum(cdv, i * k, count[i]) { $0.y })
                balls[i].w += SIMD3(Self.orderedSum(cdw, i * k, count[i]) { $0.x },
                                    Self.orderedSum(cdw, i * k, count[i]) { $0.y },
                                    Self.orderedSum(cdw, i * k, count[i]) { $0.z })
                classify(i)
            }
            // Cushions and pockets, instant as ever.
            for i in 0..<n where balls[i].mode.moves {
                let p = balls[i].p
                guard abs(p.x) >= hx || abs(p.y) >= hy else { continue }
                if let pocket = geo.pockets.first(where: {
                    simd_distance_squared(p, $0.center) <= $0.captureRadius * $0.captureRadius }) {
                    capture(i, in: pocket)
                    continue
                }
                var met: [SIMD2<Double>] = []
                for g in geo.cushions {
                    let q = g.closestPoint(to: balls[i].p)
                    let dp = q - balls[i].p
                    let d2 = simd_length_squared(dp)
                    guard d2 <= r * r, d2 > 1e-24 else { continue }
                    let nrm = dp / d2.squareRoot()
                    if simd_dot(balls[i].v, nrm) > Self.approach && !met.contains(where: { simd_distance_squared($0, q) < 1e-18 }) {
                        met.append(q)
                        note(cushion: i)
                        bounce(i, normal: nrm)
                        classify(i)
                        recorder?.mark(i)
                    }
                }
            }
            // The cloth, for one step.
            if recorder != nil && steps % 25 == 0 {
                for i in 0..<n where balls[i].mode != .stationary && balls[i].mode != .pocketed { recorder?.owe(i) }
            }
            for i in 0..<n where balls[i].mode != .stationary && balls[i].mode != .pocketed {
                prepare(i)
                advance(i, by: min(dt, balls[i].transition))
            }
            time += dt
            if steps % 25 == 0 { recorder?.settle(balls: balls, at: time) }
        }
        // Whatever still touches is resting contact now; the instant model
        // takes it from here. Every pair is separated — a ball the spring
        // stopped is as squeezed as one it did not.
        separateOverlaps(all: true)
        for i in 0..<n where balls[i].mode != .pocketed {
            classify(i)
            if balls[i].mode != .stationary { recorder?.mark(i) }
        }
    }

    /// Sums one component of a ball's pushes in an order that does not
    /// depend on which neighbour happened to be visited first: by size,
    /// and for two of equal size the negative first.
    static func orderedSum(_ items: [SIMD2<Double>]) -> SIMD2<Double> {
        if items.count <= 1 { return items.first ?? .zero }
        return SIMD2(orderedSum(items, 0, items.count) { $0.x }, orderedSum(items, 0, items.count) { $0.y })
    }

    static func orderedSum(_ items: [SIMD3<Double>]) -> SIMD3<Double> {
        if items.count <= 1 { return items.first ?? .zero }
        return SIMD3(orderedSum(items, 0, items.count) { $0.x }, orderedSum(items, 0, items.count) { $0.y },
                     orderedSum(items, 0, items.count) { $0.z })
    }

    static func orderedSum<T>(_ items: [T], _ start: Int, _ count: Int, _ component: (T) -> Double) -> Double {
        if count == 1 { return component(items[start]) }
        var values = [Double](repeating: 0, count: count)
        for m in 0..<count { values[m] = component(items[start + m]) }
        values.sort { abs($0) < abs($1) || (abs($0) == abs($1) && $0 < $1) }
        var total = 0.0
        for v in values { total += v }
        return total
    }

    // MARK: Overlaps

    /// Rounding and resting contacts can leave two balls a hair inside each
    /// other, or a ball a hair inside a cushion; push them apart so the
    /// invariant holds at every step. Every push in a pass is worked out
    /// from the same positions and summed in a fixed order, so the pass
    /// does not depend on which pair it visits first.
    mutating func separateOverlaps(all: Bool) {
        let n = balls.count
        let hx = geo.innerHalfExtent.x - 1e-9, hy = geo.innerHalfExtent.y - 1e-9
        // A ball at rest is only checked once something has pushed it: a
        // push can shove it into a neighbour that is also at rest.
        var involved = balls.map { all || ($0.mode != .stationary && $0.mode != .pocketed) }
        for _ in 0..<24 {
            var pushes: [Int: [SIMD2<Double>]] = [:]
            for i in 0..<n where balls[i].mode != .pocketed {
                let iActive = involved[i]
                for j in (i + 1)..<n where balls[j].mode != .pocketed {
                    if !iActive && !involved[j] { continue }
                    let dp = balls[j].p - balls[i].p
                    let d2 = simd_length_squared(dp)
                    let least = twoR - 1e-10
                    if d2 >= least * least { continue }
                    let len = d2.squareRoot()
                    let nrm = len > 1e-12 ? dp / len : SIMD2<Double>(1, 0)
                    let push = (twoR - len) / 2 + 1e-12
                    pushes[i, default: []].append(-nrm * push)
                    pushes[j, default: []].append(nrm * push)
                }
                guard iActive else { continue }
                let p = balls[i].p
                guard abs(p.x) >= hx || abs(p.y) >= hy else { continue }
                for g in geo.cushions {
                    let rel = p - g.a
                    let along = simd_dot(rel, g.tangent)
                    if along > 0 && along < g.length {
                        // Beside the face: out along the normal, to the open
                        // side, whichever side rounding left it on.
                        let d = simd_dot(rel, g.normal)
                        if d < r - 1e-10 && d > -r {
                            pushes[i, default: []].append(g.normal * (r - d + 1e-12))
                        }
                    } else {
                        let q = along <= 0 ? g.a : g.b
                        let dp = p - q
                        let d2 = simd_length_squared(dp)
                        let least = r - 1e-10
                        if d2 >= least * least { continue }
                        let len = d2.squareRoot()
                        let nrm = len > 1e-12 ? dp / len : g.normal
                        pushes[i, default: []].append(nrm * (r - len + 1e-12))
                    }
                }
            }
            if pushes.isEmpty { break }
            for (i, list) in pushes {
                balls[i].p += Self.orderedSum(list)
                involved[i] = true
            }
        }
    }

    // MARK: Output

    func tableState() -> PoolTableState {
        PoolTableState(balls: balls.map { b in
            PoolBall(number: b.number, position: b.p, velocity: b.v, spin: b.w, orientation: b.q, pocket: b.pocket)
        })
    }

    func result() -> PoolShotResult {
        PoolShotResult(events: events, firstContact: firstContactBall, pocketed: pocketedList,
                       railAfterFirstContact: railAfterContact, final: tableState(),
                       trajectory: recorder?.trajectory(), scratched: pocketedList.contains { $0.ball == 0 },
                       firstContactTime: firstContactTime, objectBallsToRail: objectBallsToRail,
                       cueCushionsBeforeContact: cueCushionsBeforeContact, duration: time)
    }
}
