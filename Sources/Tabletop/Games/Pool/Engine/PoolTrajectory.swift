//
//  PoolTrajectory.swift
//  A shot's motion, kept for the renderer to play back exactly.
//
//  The simulation's steps are uneven (short while balls slide, longer while
//  they roll, cut at every contact), so playback cannot simply replay them.
//  Instead each ball gets its own track of keyframes: one at every contact
//  and change of state (so a bounce is a sharp corner, not a rounded one),
//  enough in between that interpolation stays within a fraction of a
//  millimetre of the true path, and never so far apart that the ball turns
//  more than a radian between two of them — a quaternion slerp takes the
//  short way round, and a ball rolling at speed turns fast.
//
//  After the shot the tracks are thinned: a keyframe that its neighbours
//  already predict is dropped. A break keeps a few thousand; a gentle shot a
//  few dozen.
//

import Foundation
import simd

struct PoolTrajectory: Sendable {

    struct Keyframe: Sendable {
        var time: Double
        var position: SIMD2<Double>
        var orientation: simd_quatd
        var drop: Double
    }

    struct Track: Sendable {
        let number: Int
        var keys: [Keyframe]
        /// The pocket the ball ends in, and when it entered it (−∞ for a
        /// ball that was already down before the shot).
        var pocket: Int?
        var pocketTime: Double
    }

    /// Seconds from the stroke until the last ball stopped or finished
    /// dropping.
    let duration: Double
    let tracks: [Track]

    var keyframeCount: Int { tracks.reduce(0) { $0 + $1.keys.count } }

    /// Every ball's pose at `time`, keyed by ball number.
    func poses(at time: Double) -> [Int: PoolBallPose] {
        var out: [Int: PoolBallPose] = [:]
        out.reserveCapacity(tracks.count)
        for track in tracks {
            if let pose = Self.pose(of: track, at: time) { out[track.number] = pose }
        }
        return out
    }

    func pose(of ball: Int, at time: Double) -> PoolBallPose? {
        guard let track = tracks.first(where: { $0.number == ball }) else { return nil }
        return Self.pose(of: track, at: time)
    }

    static func pose(of track: Track, at time: Double) -> PoolBallPose? {
        let keys = track.keys
        guard let firstKey = keys.first, let lastKey = keys.last else { return nil }
        let pocket = time >= track.pocketTime ? track.pocket : nil
        if time <= firstKey.time || keys.count == 1 {
            return PoolBallPose(position: firstKey.position, orientation: firstKey.orientation,
                                pocket: pocket, dropProgress: firstKey.drop)
        }
        if time >= lastKey.time {
            return PoolBallPose(position: lastKey.position, orientation: lastKey.orientation,
                                pocket: pocket, dropProgress: lastKey.drop)
        }
        // The last keyframe at or before `time`.
        var lo = 0, hi = keys.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if keys[mid].time <= time { lo = mid } else { hi = mid }
        }
        let a = keys[lo], b = keys[hi]
        let span = b.time - a.time
        let f = span > 0 ? (time - a.time) / span : 1
        return PoolBallPose(position: a.position + (b.position - a.position) * f,
                            orientation: simd_slerp(a.orientation, b.orientation, f),
                            pocket: pocket, dropProgress: a.drop + (b.drop - a.drop) * f)
    }
}

/// Collects keyframes while the simulator runs. It only ever reads the
/// simulation's state, so a recorded shot and an unrecorded one are the same
/// shot.
struct PoolTrajectoryRecorder {
    private struct Raw {
        var key: PoolTrajectory.Keyframe
        var pinned: Bool
    }

    private var raw: [[Raw]]
    private var numbers: [Int]
    private var pockets: [Int?]
    private var pocketTimes: [Double]
    /// A keyframe is owed at the end of the current step (the ball moved, or
    /// something happened to it) and whether it must survive thinning.
    private var owed: [Bool]
    private var pin: [Bool]
    private var end = 0.0

    /// The most a ball may turn between two keyframes, radians.
    static let maximumTurn = 1.0

    init(balls: [PoolSimBall], geometry: PoolTableGeometry) {
        numbers = balls.map(\.number)
        pockets = balls.map(\.pocket)
        pocketTimes = balls.map { $0.pocket == nil ? .infinity : -.infinity }
        raw = balls.map { b in
            [Raw(key: .init(time: 0, position: b.p, orientation: b.q, drop: b.pocket == nil ? 0 : 1), pinned: true)]
        }
        owed = Array(repeating: false, count: balls.count)
        pin = owed
    }

    mutating func owe(_ i: Int) { owed[i] = true }

    mutating func mark(_ i: Int) {
        owed[i] = true
        pin[i] = true
    }

    mutating func add(_ i: Int, time: Double, position: SIMD2<Double>, orientation: simd_quatd, pinned: Bool = false) {
        if let last = raw[i].last, last.key.time >= time {
            // Same instant (a contact right at a step end): the newer state
            // wins, and it stays pinned if either was.
            let keep = last.pinned || pinned
            raw[i][raw[i].count - 1] = Raw(key: .init(time: time, position: position, orientation: orientation, drop: 0),
                                           pinned: keep)
            return
        }
        raw[i].append(Raw(key: .init(time: time, position: position, orientation: orientation, drop: 0), pinned: pinned))
    }

    /// Pays every keyframe owed for the step that just ended.
    mutating func settle(balls: [PoolSimBall], at time: Double) {
        for i in balls.indices where owed[i] {
            if balls[i].mode != .pocketed {
                add(i, time: time, position: balls[i].p, orientation: balls[i].q, pinned: pin[i])
            }
            owed[i] = false
            pin[i] = false
        }
        end = max(end, time)
    }

    /// The ball crossed into a pocket: it runs on to the cup's centre and
    /// falls, over a time that shrinks with its speed.
    mutating func drop(_ i: Int, ball: PoolSimBall, into pocket: PoolPocket, at time: Double) {
        add(i, time: time, position: ball.p, orientation: ball.q, pinned: true)
        let distance = simd_distance(ball.p, pocket.center)
        let speed = max(simd_length(ball.v), 0.6)
        let fall = min(max(distance / speed, 0.10), 0.30)
        raw[i].append(Raw(key: .init(time: time + fall, position: pocket.center, orientation: ball.q, drop: 1),
                          pinned: true))
        pockets[i] = pocket.id
        pocketTimes[i] = time
        owed[i] = false
        pin[i] = false
        end = max(end, time + fall)
    }

    func trajectory() -> PoolTrajectory {
        var tracks: [PoolTrajectory.Track] = []
        for i in raw.indices {
            tracks.append(.init(number: numbers[i], keys: Self.thin(raw[i]), pocket: pockets[i],
                                pocketTime: pocketTimes[i]))
        }
        return PoolTrajectory(duration: end, tracks: tracks)
    }

    /// Drops every keyframe the kept ones on either side already predict:
    /// within a fifth of a millimetre and a hundredth of a radian, and never
    /// spanning more than two radians of turn.
    private static func thin(_ keys: [Raw]) -> [PoolTrajectory.Keyframe] {
        guard keys.count > 2 else { return keys.map(\.key) }
        var out: [PoolTrajectory.Keyframe] = [keys[0].key]
        var anchor = 0
        var k = 1
        while k < keys.count - 1 {
            if keys[k].pinned {
                out.append(keys[k].key)
                anchor = k
                k += 1
                continue
            }
            // Could the anchor reach the next keyframe directly, predicting
            // everything in between?
            let a = keys[anchor].key, b = keys[k + 1].key
            // A long run is checked in full each time; cap it so a slow roll
            // across the table cannot make thinning quadratic.
            var fits = k - anchor < 48 && angle(a.orientation, b.orientation) < 2.0
            if fits {
                for m in (anchor + 1)...k {
                    let c = keys[m].key
                    let span = b.time - a.time
                    let f = span > 0 ? (c.time - a.time) / span : 0
                    let p = a.position + (b.position - a.position) * f
                    if simd_distance(p, c.position) > 2e-4 { fits = false; break }
                    let q = simd_slerp(a.orientation, b.orientation, f)
                    if angle(q, c.orientation) > 0.01 { fits = false; break }
                }
            }
            if !fits {
                out.append(keys[k].key)
                anchor = k
            }
            k += 1
        }
        if let last = keys.last { out.append(last.key) }
        return out
    }

    private static func angle(_ a: simd_quatd, _ b: simd_quatd) -> Double {
        let d = min(abs(simd_dot(a.vector, b.vector)), 1)
        return 2 * acos(d)
    }
}
