//
//  PoolTypes.swift
//  The plain values the pool engine trades in: balls, the table, a shot, what
//  happened during it, and how to show it.
//
//  Everything here is a value type with no UI import, so the whole engine can
//  be handed to a background queue (the computer opponent simulates hundreds
//  of shots per decision) and replayed bit-for-bit in tests.
//
//  Coordinates are the table's own, in metres: the origin is the centre of the
//  playing surface, x runs along the long axis (the head string and the
//  kitchen at negative x, the foot spot and the rack at positive x), y along
//  the short axis, and z points up out of the cloth (only spin vectors and the
//  orientation use it). A renderer whose world is y-up converts once, at the
//  boundary.
//

import Foundation
import simd

// MARK: - Balls

/// One ball — the cue ball (number 0) or an object ball (1...15).
struct PoolBall: Codable, Sendable, Equatable {
    /// 0 is the cue ball; 1–7 solids, 8 the black, 9–15 stripes.
    let number: Int
    /// Centre of the ball on the table plane. For a pocketed ball: the centre
    /// of its pocket, so a stale position can never sit on the cloth.
    var position: SIMD2<Double>
    /// Linear velocity on the plane, m/s. Zero for a ball at rest.
    var velocity: SIMD2<Double>
    /// Angular velocity, rad/s, in table axes (z up: positive `spin.z` turns
    /// the ball counter-clockwise seen from above — what right english gives).
    var spin: SIMD3<Double>
    /// Which way the ball's own markings face, for rendering only. Integrated
    /// from `spin` while the ball moves; the physics never reads it.
    var orientation: simd_quatd
    /// The pocket (0–5) the ball went into, or nil while it is on the table.
    var pocket: Int?

    init(number: Int,
         position: SIMD2<Double>,
         velocity: SIMD2<Double> = .zero,
         spin: SIMD3<Double> = .zero,
         orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
         pocket: Int? = nil) {
        self.number = number
        self.position = position
        self.velocity = velocity
        self.spin = spin
        self.orientation = orientation
        self.pocket = pocket
    }

    var isCueBall: Bool { number == 0 }
    var isOnTable: Bool { pocket == nil }
    var isSolid: Bool { (1...7).contains(number) }
    var isStripe: Bool { (9...15).contains(number) }

    // A saved game must survive a build that renamed or added a field, so
    // every key is decoded on its own with a sensible fallback rather than
    // failing the whole file. The quaternion is stored as its four components
    // because simd_quatd has no Codable conformance of its own.
    private enum CodingKeys: String, CodingKey {
        case number, position, velocity, spin, orientation, pocket
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = ((try? c.decodeIfPresent(Int.self, forKey: .number)) ?? nil) ?? 0
        position = ((try? c.decodeIfPresent(SIMD2<Double>.self, forKey: .position)) ?? nil) ?? .zero
        velocity = ((try? c.decodeIfPresent(SIMD2<Double>.self, forKey: .velocity)) ?? nil) ?? .zero
        spin = ((try? c.decodeIfPresent(SIMD3<Double>.self, forKey: .spin)) ?? nil) ?? .zero
        let q = ((try? c.decodeIfPresent(SIMD4<Double>.self, forKey: .orientation)) ?? nil) ?? SIMD4(0, 0, 0, 1)
        // Kept exactly as saved when it is a unit quaternion, so a round trip
        // is lossless; renormalised only if the file was damaged.
        let length = simd_length(q)
        if !(length.isFinite && length > 1e-9) {
            orientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        } else {
            orientation = simd_quatd(vector: abs(length - 1) < 1e-9 ? q : q / length)
        }
        pocket = (try? c.decodeIfPresent(Int.self, forKey: .pocket)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(position, forKey: .position)
        try c.encode(velocity, forKey: .velocity)
        try c.encode(spin, forKey: .spin)
        try c.encode(orientation.vector, forKey: .orientation)
        try c.encodeIfPresent(pocket, forKey: .pocket)
    }

    static func == (a: PoolBall, b: PoolBall) -> Bool {
        a.number == b.number && a.position == b.position && a.velocity == b.velocity
            && a.spin == b.spin && a.orientation.vector == b.orientation.vector && a.pocket == b.pocket
    }
}

// MARK: - The table

/// Every ball, on the table or in a pocket. Kept sorted by number so two
/// states that mean the same thing compare (and encode) the same.
struct PoolTableState: Codable, Sendable, Equatable {
    var balls: [PoolBall]

    init(balls: [PoolBall]) {
        self.balls = balls.sorted { $0.number < $1.number }
    }

    func ball(_ n: Int) -> PoolBall? {
        balls.first { $0.number == n }
    }

    /// The cue ball. Setting it replaces ball 0 (or adds it).
    var cueBall: PoolBall? {
        get { ball(0) }
        set {
            balls.removeAll { $0.number == 0 }
            if let newValue {
                balls.insert(newValue, at: 0)
            }
        }
    }

    /// True when nothing on the cloth moves or turns.
    var isAtRest: Bool {
        balls.allSatisfy { b in
            b.pocket != nil || (simd_length_squared(b.velocity) < 1e-12 && simd_length_squared(b.spin) < 1e-10)
        }
    }

    /// Object balls still on the cloth, in number order.
    var objectBallsOnTable: [Int] {
        balls.compactMap { $0.number != 0 && $0.pocket == nil ? $0.number : nil }
    }

    /// Replaces the ball with the same number (or adds it).
    mutating func update(_ ball: PoolBall) {
        if let i = balls.firstIndex(where: { $0.number == ball.number }) {
            balls[i] = ball
        } else {
            balls.append(ball)
            balls.sort { $0.number < $1.number }
        }
    }

    private enum CodingKeys: String, CodingKey { case balls }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = ((try? c.decodeIfPresent([PoolBall].self, forKey: .balls)) ?? nil) ?? []
        // Drop duplicates and impossible numbers a damaged file could hold.
        var seen = Set<Int>()
        let clean = decoded.filter { (0...15).contains($0.number) && seen.insert($0.number).inserted }
        self.init(balls: clean)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(balls, forKey: .balls)
    }
}

// MARK: - A shot

/// What the player (or the computer) asks the cue to do.
struct PoolShot: Codable, Sendable, Equatable {
    /// Direction of the stroke in the table plane, radians; 0 is +x.
    var aim: Double
    /// 0...1. Mapped to the cue ball's speed off a centre hit by
    /// `PoolShot.speed(forPower:)`, about 0.3 m/s (a touch) to 8 m/s (a break).
    var power: Double
    /// −1...1, a fraction of the safe tip offset (half the ball's radius);
    /// positive is right english.
    var tipSide: Double
    /// −1...1; positive is follow (top), negative is draw (screw).
    var tipVertical: Double

    init(aim: Double, power: Double, tipSide: Double = 0, tipVertical: Double = 0) {
        self.aim = aim
        self.power = power
        self.tipSide = tipSide
        self.tipVertical = tipVertical
    }

    static let minimumSpeed = 0.3
    static let maximumSpeed = 8.0

    /// Power is not linear in speed: most shots in pool are soft, and a
    /// linear meter would crowd them into its bottom third. `p^1.5` gives the
    /// first half of the meter the speeds from a touch to a firm pot (0.3 to
    /// 3 m/s) and keeps the break at the top.
    static func speed(forPower power: Double) -> Double {
        let p = min(max(power.isFinite ? power : 0, 0), 1)
        return minimumSpeed + (maximumSpeed - minimumSpeed) * pow(p, 1.5)
    }

    static func power(forSpeed speed: Double) -> Double {
        let s = min(max(speed, minimumSpeed), maximumSpeed)
        return pow((s - minimumSpeed) / (maximumSpeed - minimumSpeed), 1.0 / 1.5)
    }

    /// The tip offset actually used: the requested one, pulled back onto the
    /// safe circle when it lies outside it (a real tip there would miscue).
    var clampedTip: SIMD2<Double> {
        var t = SIMD2(tipSide.isFinite ? tipSide : 0, tipVertical.isFinite ? tipVertical : 0)
        let r = simd_length(t)
        if r > 1 { t /= r }
        return t
    }

    /// Unit vector of the aim.
    var direction: SIMD2<Double> { SIMD2(cos(aim), sin(aim)) }

    private enum CodingKeys: String, CodingKey { case aim, power, tipSide, tipVertical }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aim = ((try? c.decodeIfPresent(Double.self, forKey: .aim)) ?? nil) ?? 0
        power = ((try? c.decodeIfPresent(Double.self, forKey: .power)) ?? nil) ?? 0.5
        tipSide = ((try? c.decodeIfPresent(Double.self, forKey: .tipSide)) ?? nil) ?? 0
        tipVertical = ((try? c.decodeIfPresent(Double.self, forKey: .tipVertical)) ?? nil) ?? 0
    }
}

// MARK: - What happened

/// One thing that happened during a shot, in time order.
enum PoolShotEvent: Sendable, Equatable {
    /// Two balls touched. The lower number first.
    case ballBall(Int, Int, time: Double)
    /// A ball struck a cushion (a nose, a pocket jaw or a jaw point).
    case cushion(Int, time: Double)
    /// A ball dropped into a pocket (0–5).
    case pocketed(Int, pocket: Int, time: Double)

    var time: Double {
        switch self {
        case .ballBall(_, _, let t), .cushion(_, let t), .pocketed(_, _, let t): return t
        }
    }
}

/// Where a ball is and how it is turned at one moment of a replay.
struct PoolBallPose: Sendable, Equatable {
    var position: SIMD2<Double>
    var orientation: simd_quatd
    /// The pocket the ball has entered, from the moment it crossed into it.
    var pocket: Int?
    /// 0 while on the cloth, rising to 1 as the ball falls into its pocket.
    var dropProgress: Double

    static func == (a: PoolBallPose, b: PoolBallPose) -> Bool {
        a.position == b.position && a.orientation.vector == b.orientation.vector
            && a.pocket == b.pocket && a.dropProgress == b.dropProgress
    }
}

// MARK: - Game settings

enum PoolMode: String, Codable, Sendable, CaseIterable {
    case eightBall, nineBall, practice
}

enum PoolDifficulty: String, Codable, Sendable, CaseIterable {
    case easy, medium, hard
}

enum PoolGroup: String, Codable, Sendable, CaseIterable {
    case solids, stripes

    var opposite: PoolGroup { self == .solids ? .stripes : .solids }

    func contains(_ number: Int) -> Bool {
        self == .solids ? (1...7).contains(number) : (9...15).contains(number)
    }

    var numbers: ClosedRange<Int> { self == .solids ? 1...7 : 9...15 }

    static func of(_ number: Int) -> PoolGroup? {
        if (1...7).contains(number) { return .solids }
        if (9...15).contains(number) { return .stripes }
        return nil
    }
}
