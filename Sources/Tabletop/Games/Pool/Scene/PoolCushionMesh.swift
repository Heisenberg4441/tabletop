//
//  PoolCushionMesh.swift
//  The cushions, modelled the way they are made: a rubber profile with a
//  nose that overhangs the cloth — the edge a ball actually strikes, at the
//  engine's nose height — rounding over onto a flat top, swept along each of
//  the engine's cushion runs (jaw, long nose, jaw) with mitred corners.
//
//  An extruded outline would give a vertical wall; the undercut is what
//  makes a cushion read as a cushion from behind the cue ball — a thin line
//  of shadow under the nose, and light rolling over the top.
//

import SceneKit
import simd

enum PoolCushionMesh {

    typealias Point = SIMD2<Double>

    /// The profile, as (distance back from the nose line, height), from the
    /// cloth up round the nose to where the flat top begins.
    static func profile(nose: Double, top: Double) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = [[0.010, 0], [0.0035, nose * 0.62], [0, nose]]
        let round = 0.011
        for i in 1...8 {
            let a = Double(i) / 8 * Double.pi / 2
            points.append([round * (1 - cos(a)), nose + (top - nose) * sin(a)])
        }
        return points
    }

    /// One cushion: `chain` is a run of the engine's nose segments; the body
    /// lies on the side of the chain towards `interior` (any point inside
    /// the cushion's outline) and is closed off by the back line, where
    /// `back` takes a point.
    static func geometry(chain: [Point], interior: Point, onBackLine: (Point) -> Bool, back: (Point) -> Point,
                         nose: Double, top: Double, material: SCNMaterial) -> SCNGeometry? {
        guard chain.count >= 2 else { return nil }
        let profile = profile(nose: nose, top: top)
        let depth = profile.last?.x ?? 0.011

        // Each segment's normal into the body.
        var normals: [Point] = []
        for i in 0..<(chain.count - 1) {
            let d = simd_normalize(chain[i + 1] - chain[i])
            var n = Point(-d.y, d.x)
            if simd_dot(interior - chain[i], n) < 0 { n = -n }
            normals.append(n)
        }
        // How to step back from each chain vertex by one unit of profile
        // depth: along the mitre inside, along the back line at an end that
        // sits on it (so the profile finishes flush against the rail).
        var steps: [Point] = []
        for i in chain.indices {
            if i == 0 || i == chain.count - 1 {
                let n = i == 0 ? normals[0] : normals[normals.count - 1]
                if onBackLine(chain[i]) {
                    let along = back(chain[i] + n * 0.05) - chain[i]
                    let b = simd_length(along) > 1e-9 ? simd_normalize(along) : n
                    let k = simd_dot(b, n)
                    steps.append(k > 0.05 ? b / k : n)
                } else {
                    steps.append(n)
                }
            } else {
                let m = simd_normalize(normals[i - 1] + normals[i])
                steps.append(m / max(0.2, simd_dot(m, normals[i])))
            }
        }

        var vertices: [SCNVector3] = []
        var vertexNormals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [UInt32] = []
        func scene(_ p: Point, _ h: Double) -> SIMD3<Double> { [p.x, h, -p.y] }
        func add(_ p: SIMD3<Double>, _ n: SIMD3<Double>, _ uv: CGPoint) -> UInt32 {
            vertices.append(SCNVector3(p.x, p.y, p.z))
            vertexNormals.append(SCNVector3(n.x, n.y, n.z))
            uvs.append(uv)
            return UInt32(vertices.count - 1)
        }
        /// A triangle wound so its face points along `hint`.
        func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, facing hint: SIMD3<Double>) {
            let pa = vertices[Int(a)], pb = vertices[Int(b)], pc = vertices[Int(c)]
            let u = SIMD3<Double>(Double(pb.x - pa.x), Double(pb.y - pa.y), Double(pb.z - pa.z))
            let v = SIMD3<Double>(Double(pc.x - pa.x), Double(pc.y - pa.y), Double(pc.z - pa.z))
            if simd_dot(simd_cross(u, v), hint) >= 0 { indices += [a, b, c] } else { indices += [a, c, b] }
        }

        // The profile's outward normals, per point, in (back, up) terms —
        // smoothed over the round of the nose, sharp where the undercut
        // meets it.
        func edgeNormal(_ k: Int) -> SIMD2<Double> {
            let e = profile[k + 1] - profile[k]
            return simd_normalize(SIMD2(-e.y, e.x))              // pointing towards −back / up
        }
        var along = 0.0
        for i in 0..<(chain.count - 1) {
            let a = chain[i], b = chain[i + 1]
            let n = normals[i]
            let length = simd_distance(a, b)
            for k in 0..<(profile.count - 1) {
                let p0 = profile[k], p1 = profile[k + 1]
                let n0 = k == 0 || k == 2 ? edgeNormal(k) : simd_normalize(edgeNormal(k - 1) + edgeNormal(k))
                let n1 = k + 1 == profile.count - 1 || k + 1 == 2 ? edgeNormal(k)
                    : simd_normalize(edgeNormal(k) + edgeNormal(k + 1))
                // A profile normal (back, up) in the scene: "back" is `n`.
                func world(_ q: SIMD2<Double>) -> SIMD3<Double> { SIMD3(n.x * q.x, q.y, -n.y * q.x) }
                let na = simd_normalize(world(n0)), nb = simd_normalize(world(n1))
                let v00 = add(scene(a + steps[i] * p0.x, p0.y), na, CGPoint(x: along / 0.03, y: p0.y / 0.03))
                let v01 = add(scene(a + steps[i] * p1.x, p1.y), nb, CGPoint(x: along / 0.03, y: p1.y / 0.03))
                let v10 = add(scene(b + steps[i + 1] * p0.x, p0.y), na, CGPoint(x: (along + length) / 0.03, y: p0.y / 0.03))
                let v11 = add(scene(b + steps[i + 1] * p1.x, p1.y), nb, CGPoint(x: (along + length) / 0.03, y: p1.y / 0.03))
                let facing = simd_normalize(na + nb)
                triangle(v00, v10, v11, facing: facing)
                triangle(v00, v11, v01, facing: facing)
            }
            along += length
        }

        // The flat top, from the end of the round back to the rail.
        var outline = chain.indices.map { chain[$0] + steps[$0] * depth }
        if let last = outline.last, !onBackLine(last) { outline.append(back(last)) }
        if let first = outline.first, !onBackLine(first) { outline.append(back(first)) }
        let centre = outline.reduce(Point.zero, +) / Double(outline.count)
        let up = SIMD3<Double>(0, 1, 0)
        let c = add(scene(centre, top), up, CGPoint(x: centre.x / 0.03, y: centre.y / 0.03))
        let ring = outline.map { add(scene($0, top), up, CGPoint(x: $0.x / 0.03, y: $0.y / 0.03)) }
        for i in ring.indices {
            triangle(c, ring[i], ring[(i + 1) % ring.count], facing: up)
        }

        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices),
                                             SCNGeometrySource(normals: vertexNormals),
                                             SCNGeometrySource(textureCoordinates: uvs)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return geometry
    }
}
