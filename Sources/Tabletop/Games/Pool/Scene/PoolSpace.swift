//
//  PoolSpace.swift
//  Between the engine's table and SceneKit's world.
//
//  The engine works in the plane of the cloth: metres from the centre, x
//  along the table (the head string at negative x), y across it, z up.
//  SceneKit is y-up. So a point (x, y) on the cloth at height h is the scene
//  point (x, h, −y) — a proper rotation, which keeps every orientation the
//  engine integrates for a rolling ball the right way round on screen.
//
//  And the table's dimensions that are the presentation's own — how deep a
//  cushion is, how wide the rail, where each pocket's hole is cut — are all
//  derived here from `PoolTableGeometry`, so what the physics sees is
//  exactly what is drawn.
//

import SceneKit
import simd

enum PoolSpace {

    static func scene(_ p: SIMD2<Double>, height: Double = 0) -> SCNVector3 {
        SCNVector3(CGFloat(p.x), CGFloat(height), CGFloat(-p.y))
    }

    static func sceneSIMD(_ p: SIMD2<Double>, height: Double = 0) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(height), Float(-p.y))
    }

    static func table(_ v: SCNVector3) -> SIMD2<Double> {
        SIMD2(Double(v.x), Double(-v.z))
    }

    static func table(_ v: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2(Double(v.x), Double(-v.z))
    }

    /// An engine orientation as a scene one: the same rotation, with its
    /// axis carried across (x, y, z) → (x, z, −y).
    static func sceneOrientation(_ q: simd_quatd) -> simd_quatf {
        let v = q.vector
        return simd_normalize(simd_quatf(ix: Float(v.x), iy: Float(v.z), iz: Float(-v.y), r: Float(v.w)))
    }

    /// The unit vector along `aim` (radians in the table plane) in the scene.
    static func direction(_ aim: Double) -> SIMD3<Float> {
        SIMD3(Float(cos(aim)), 0, Float(-sin(aim)))
    }

    static func tableDirection(_ aim: Double) -> SIMD2<Double> { SIMD2(cos(aim), sin(aim)) }
}

/// The table as drawn: the engine's geometry, and the parts of a real table
/// the engine does not need to know about.
struct PoolTableDimensions {
    let geometry: PoolTableGeometry
    /// Half the playing surface.
    let halfLength: Double
    let halfWidth: Double
    /// Where the cushions meet the wooden rail: the cushion's back.
    let backX: Double
    let backY: Double
    let railWidth: Double
    /// The rail's outside edge.
    let outerX: Double
    let outerY: Double
    /// Height of the cushion's top and of the rail's.
    let cushionTop: Double
    let railTop: Double
    /// Each pocket's opening through the rail and the bed, by pocket id.
    let cutRadius: [Int: Double]

    init(_ g: PoolTableGeometry) {
        geometry = g
        halfLength = g.length / 2
        halfWidth = g.width / 2
        // The cushions end at the back line; take it from the engine's own
        // segments, and never thinner than a real cushion.
        var depthX = 0.0, depthY = 0.0
        for segment in g.cushions {
            for p in [segment.a, segment.b] {
                depthX = max(depthX, abs(p.x) - g.length / 2)
                depthY = max(depthY, abs(p.y) - g.width / 2)
            }
        }
        let depth = max(0.045, min(0.07, max(depthX, depthY)))
        backX = halfLength + depth
        backY = halfWidth + depth
        railWidth = 0.125
        outerX = backX + railWidth
        outerY = backY + railWidth
        cushionTop = g.cushionNoseHeight + 0.0065
        railTop = cushionTop + 0.0065

        // A pocket's hole is wide enough to take every cushion end that
        // turns into it (the jaws' backs), and at least as wide as the
        // engine's capture circle.
        var cuts: [Int: Double] = [:]
        for pocket in g.pockets {
            var r = pocket.captureRadius
            for segment in g.cushions {
                for p in [segment.a, segment.b] {
                    let d = simd_distance(p, pocket.center)
                    let isBack = abs(p.x) >= backX - 0.002 || abs(p.y) >= backY - 0.002
                    if isBack && d < 0.16 { r = max(r, d + 0.004) }
                }
            }
            cuts[pocket.id] = min(0.085, r)
        }
        cutRadius = cuts
    }

    func cut(_ pocket: PoolPocket) -> Double { cutRadius[pocket.id] ?? pocket.captureRadius }

    /// Whether a point of the table plane is on the cushion band or the
    /// rail rather than on the cloth — where the cue has to clear them.
    func isOverCushion(_ p: SIMD2<Double>) -> Bool {
        abs(p.x) > halfLength - 0.002 || abs(p.y) > halfWidth - 0.002
    }

    func isOverRail(_ p: SIMD2<Double>) -> Bool {
        (abs(p.x) > backX && abs(p.x) < outerX + 0.02 && abs(p.y) < outerY + 0.02)
            || (abs(p.y) > backY && abs(p.y) < outerY + 0.02 && abs(p.x) < outerX + 0.02)
    }
}
