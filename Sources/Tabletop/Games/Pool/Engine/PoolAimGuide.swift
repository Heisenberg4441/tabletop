//
//  PoolAimGuide.swift
//  The aiming lines: where the cue ball meets the first thing in its path,
//  the ghost ball there, and where each ball heads off afterwards.
//
//  This is geometry, not physics — cheap enough to run on every mouse move.
//  The lines are the textbook ones a player learns (the object ball leaves
//  along the line of centres; a stun cue ball along the tangent line, square
//  to it), so they are honest about the angle and silent about throw,
//  squirt and spin, which the player learns by feel as they would at a real
//  table.
//

import Foundation
import simd

struct PoolAimPrediction: Sendable, Equatable {
    /// Where the cue ball's centre is when it first touches something: the
    /// ghost ball against an object ball, or the point it meets a cushion.
    var ghostBallCenter: SIMD2<Double>
    /// The object ball it meets first, if any.
    var targetBall: Int?
    /// Unit direction the object ball leaves in (the line of centres).
    var objectBallDirection: SIMD2<Double>?
    /// Unit direction a stun cue ball leaves in (the tangent line); nil for a
    /// dead-straight hit, where it has none.
    var cueBallDeflection: SIMD2<Double>?
    /// Where the cue ball's centre meets a cushion, if it meets one before
    /// any ball.
    var cushionPoint: SIMD2<Double>?

    /// The pocket the cue ball would drop into before touching anything.
    var scratchPocket: Int?
    /// The cut angle, radians (0 is full ball).
    var cutAngle: Double?
    /// The mirror-image direction off `cushionPoint`, for a one-rail line.
    var reflectedDirection: SIMD2<Double>?
    /// Where the object ball's line meets a cushion or pocket, so a guide can
    /// be drawn to it without running past the rail.
    var objectBallStop: SIMD2<Double>?
    /// Distance from the cue ball to `ghostBallCenter`.
    var travel: Double
}

enum PoolAimGuide {

    static func predict(aim: Double, from table: PoolTableState,
                        geometry g: PoolTableGeometry = .standard) -> PoolAimPrediction {
        let direction = SIMD2(cos(aim), sin(aim))
        guard let cue = table.cueBall, cue.pocket == nil else {
            return PoolAimPrediction(ghostBallCenter: .zero, travel: 0)
        }
        let r = g.ballRadius
        let start = cue.position
        let far = 10.0

        // First ball in the path.
        var best = far
        var target: Int?
        for b in table.balls where b.number != 0 && b.pocket == nil {
            if let t = rayCircle(from: start, direction: direction, center: b.position, radius: 2 * r), t < best {
                best = t
                target = b.number
            }
        }
        // First cushion or pocket.
        let wall = rayWall(from: start, direction: direction, geometry: g)
        if let w = wall, w.distance < best {
            let point = start + direction * w.distance
            var reflected: SIMD2<Double>?
            if let n = w.normal {
                reflected = direction - 2 * simd_dot(direction, n) * n
            }
            return PoolAimPrediction(ghostBallCenter: point, cushionPoint: w.pocket == nil ? point : nil,
                                     scratchPocket: w.pocket, reflectedDirection: reflected, travel: w.distance)
        }
        guard let hit = target, let ball = table.ball(hit) else {
            return PoolAimPrediction(ghostBallCenter: start + direction * far, travel: far)
        }
        let ghost = start + direction * best
        let line = simd_normalize(ball.position - ghost)
        let along = simd_dot(direction, line)
        let tangent = direction - line * along
        let tangentLength = simd_length(tangent)
        let stop = rayWall(from: ball.position, direction: line, geometry: g).map { ball.position + line * $0.distance }
        return PoolAimPrediction(ghostBallCenter: ghost, targetBall: hit, objectBallDirection: line,
                                 cueBallDeflection: tangentLength > 1e-6 ? tangent / tangentLength : nil,
                                 cutAngle: acos(min(max(along, -1), 1)), objectBallStop: stop, travel: best)
    }

    /// Distance along a ray from `from` to where it comes within `radius`
    /// of `center`, if it does ahead of the start.
    static func rayCircle(from p: SIMD2<Double>, direction d: SIMD2<Double>, center: SIMD2<Double>,
                          radius: Double) -> Double? {
        let rel = p - center
        let b = simd_dot(rel, d)
        let c = simd_length_squared(rel) - radius * radius
        if c <= 0 { return b < 0 ? 0 : nil }       // already touching: only if heading into it
        if b >= 0 { return nil }
        let disc = b * b - c
        if disc < 0 { return nil }
        return -b - disc.squareRoot()
    }

    /// Where a ball's centre travelling along the ray first meets a cushion
    /// (its face or a jaw point) or drops into a pocket.
    static func rayWall(from p: SIMD2<Double>, direction d: SIMD2<Double>, geometry g: PoolTableGeometry)
        -> (distance: Double, normal: SIMD2<Double>?, pocket: Int?)? {
        let r = g.ballRadius
        var best: (distance: Double, normal: SIMD2<Double>?, pocket: Int?)?
        for s in g.cushions {
            let rel = p - s.a
            let d0 = simd_dot(s.normal, rel)
            let dn = simd_dot(s.normal, d)
            if d0 > r && dn < 0 {
                let t = (d0 - r) / -dn
                let at = simd_dot(s.tangent, rel + d * t)
                if at >= 0 && at <= s.length && t < (best?.distance ?? .infinity) {
                    best = (t, s.normal, nil)
                }
            }
            for e in [s.a, s.b] {
                if let t = rayCircle(from: p, direction: d, center: e, radius: r), t < (best?.distance ?? .infinity) {
                    let n = simd_normalize(p + d * t - e)
                    best = (t, n, nil)
                }
            }
        }
        for pocket in g.pockets {
            if let t = rayCircle(from: p, direction: d, center: pocket.center, radius: pocket.captureRadius),
               t < (best?.distance ?? .infinity) {
                best = (t, nil, pocket.id)
            }
        }
        return best
    }
}
