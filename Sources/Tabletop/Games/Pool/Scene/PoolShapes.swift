//
//  PoolShapes.swift
//  The table's outlines, worked out in the plane of the cloth and handed to
//  SceneKit as extruded shapes: the cushions from the engine's own segments,
//  the rail with a bite taken out for every pocket, the bed with its holes.
//
//  Paths are in table coordinates (metres, x along the table, y across).
//  An `SCNShape` extrudes along its own z; turned a quarter over about x,
//  that z points up and the path's y points along the scene's −z — exactly
//  the engine-to-scene mapping in `PoolSpace` — so a path point lands on the
//  cloth where the engine has it.
//

import AppKit
import SceneKit
import simd

enum PoolShapes {

    typealias Point = SIMD2<Double>

    // MARK: Paths and nodes

    static func path(_ polygons: [[Point]]) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        for polygon in polygons where polygon.count >= 3 {
            path.move(to: CGPoint(x: polygon[0].x, y: polygon[0].y))
            for p in polygon.dropFirst() { path.line(to: CGPoint(x: p.x, y: p.y)) }
            path.close()
        }
        path.flatness = 0.0005
        return path
    }

    /// A quarter round, for chamfers: the edge rolls over instead of being
    /// cut at 45°.
    static let roundedProfile: NSBezierPath = {
        let profile = NSBezierPath()
        profile.move(to: CGPoint(x: 0, y: 1))
        for i in 1...12 {
            let a = Double(i) / 12 * Double.pi / 2
            profile.line(to: CGPoint(x: sin(a), y: cos(a)))
        }
        return profile
    }()

    /// `polygons` extruded from `bottom` up to `top`, with the top edge
    /// rounded over by `chamfer`.
    static func extrusion(_ polygons: [[Point]], bottom: Double, top: Double, chamfer: Double = 0,
                          materials: [SCNMaterial]) -> SCNNode {
        let shape = SCNShape(path: path(polygons), extrusionDepth: CGFloat(top - bottom))
        if chamfer > 0 {
            shape.chamferRadius = CGFloat(chamfer)
            shape.chamferMode = .front
            shape.chamferProfile = roundedProfile
        }
        shape.materials = materials
        let node = SCNNode(geometry: shape)
        node.eulerAngles.x = -.pi / 2
        node.position.y = CGFloat((top + bottom) / 2)
        return node
    }

    // MARK: Polygons

    static func circle(_ c: Point, _ r: Double, segments: Int = 96) -> [Point] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return c + Point(cos(a), sin(a)) * r
        }
    }

    static func rectangle(_ hx: Double, _ hy: Double) -> [Point] {
        [[-hx, -hy], [hx, -hy], [hx, hy], [-hx, hy]]
    }

    static func roundedRectangle(_ hx: Double, _ hy: Double, radius r: Double) -> [Point] {
        var points: [Point] = []
        let corners: [(Point, Double)] = [([hx - r, -hy + r], -.pi / 2), ([hx - r, hy - r], 0),
                                          ([-hx + r, hy - r], .pi / 2), ([-hx + r, -hy + r], .pi)]
        for (c, start) in corners {
            for i in 0...8 {
                let a = start + Double(i) / 8 * .pi / 2
                points.append(c + Point(cos(a), sin(a)) * r)
            }
        }
        return points
    }

    /// `polygon` (convex) with everything on the far side of the line
    /// through `a` with normal `n` cut away: the part where
    /// `dot(p − a, n) >= 0` is kept.
    static func clip(_ polygon: [Point], keepingSideOf a: Point, normal n: Point) -> [Point] {
        var out: [Point] = []
        for i in polygon.indices {
            let p = polygon[i], q = polygon[(i + 1) % polygon.count]
            let dp = simd_dot(p - a, n), dq = simd_dot(q - a, n)
            if dp >= 0 { out.append(p) }
            if (dp >= 0) != (dq >= 0) {
                let t = dp / (dp - dq)
                out.append(p + (q - p) * t)
            }
        }
        return out
    }

    // MARK: The table's outlines

    /// One cushion, as the engine draws it: a run of segments that join end
    /// to end (a jaw, the long nose, the other jaw), and the polygon that run
    /// makes closed along the back line, where the cushion meets the rail.
    struct CushionRun {
        var chain: [Point]
        var polygon: [Point]
        /// True for a cushion along a long rail (its back line is at ±backY).
        var alongX: Bool
        var backCoordinate: Double

        func back(_ p: Point) -> Point { alongX ? Point(p.x, backCoordinate) : Point(backCoordinate, p.y) }
        func isOnBackLine(_ p: Point) -> Bool {
            abs((alongX ? p.y : p.x) - backCoordinate) < 1e-4
        }
        var interior: Point { polygon.reduce(Point.zero, +) / Double(polygon.count) }
    }

    static func cushionRuns(_ d: PoolTableDimensions) -> [CushionRun] {
        var runs: [[Point]] = []
        for segment in d.geometry.cushions {
            if var last = runs.last, let end = last.last, simd_distance(end, segment.a) < 1e-6 {
                last.append(segment.b)
                runs[runs.count - 1] = last
            } else {
                runs.append([segment.a, segment.b])
            }
        }
        // The engine's list is a loop: the last run may continue into the first.
        if runs.count > 1, let first = runs.first?.first, let end = runs.last?.last, simd_distance(first, end) < 1e-6 {
            let tail = runs.removeLast()
            runs[0] = tail + runs[0].dropFirst()
        }
        return runs.compactMap { run in
            guard run.count >= 2, let first = run.first, let last = run.last else { return nil }
            // Which rail this cushion lies along: the one its longest
            // segment runs beside.
            var longest = (run[0], run[1])
            for i in 0..<(run.count - 1) where simd_distance(run[i], run[i + 1]) > simd_distance(longest.0, longest.1) {
                longest = (run[i], run[i + 1])
            }
            let middle = (longest.0 + longest.1) / 2
            let alongX = abs(longest.1.x - longest.0.x) > abs(longest.1.y - longest.0.y)
            let coordinate = alongX ? (middle.y > 0 ? d.backY : -d.backY) : (middle.x > 0 ? d.backX : -d.backX)
            var result = CushionRun(chain: run, polygon: run, alongX: alongX, backCoordinate: coordinate)
            let b1 = result.back(last), b0 = result.back(first)
            if simd_distance(b1, last) > 1e-4 { result.polygon.append(b1) }
            if simd_distance(b0, first) > 1e-4 { result.polygon.append(b0) }
            return result
        }
    }

    /// The hole in the bed under a pocket: the pocket's opening, stopped a
    /// hair short of the mouth so no part of the hole lies on the playing
    /// surface.
    static func holePolygon(_ pocket: PoolPocket, _ d: PoolTableDimensions) -> [Point] {
        let hole = circle(pocket.center, d.cut(pocket))
        let (m0, m1) = pocket.mouth
        let along = m1 - m0
        var n = simd_normalize(Point(-along.y, along.x))
        if simd_dot(pocket.center - m0, n) < 0 { n = -n }
        return clip(hole, keepingSideOf: m0 + n * 0.002, normal: n)
    }

    /// The inside edge of the rail: the back line all the way round, with a
    /// round bite out of it wherever a pocket opens — the boundary of the
    /// back rectangle and every pocket's opening taken together.
    static func railInnerBoundary(_ d: PoolTableDimensions) -> [Point] {
        let hx = d.backX, hy = d.backY
        let cuts = d.geometry.pockets.map { (c: $0.center, r: d.cut($0)) }
        let perimeter = 4 * (hx + hy)
        // A point on the back rectangle, counter-clockwise from the middle
        // of the bottom-left half of the bottom edge, where no pocket is.
        let start = -hx / 2
        func point(_ s: Double) -> Point {
            var s = (s + (start + hx)).truncatingRemainder(dividingBy: perimeter)
            if s < 0 { s += perimeter }
            if s < 2 * hx { return [-hx + s, -hy] }
            s -= 2 * hx
            if s < 2 * hy { return [hx, -hy + s] }
            s -= 2 * hy
            if s < 2 * hx { return [hx - s, hy] }
            s -= 2 * hx
            return [-hx, hy - s]
        }
        func inside(_ p: Point) -> Int? {
            cuts.firstIndex { simd_distance(p, $0.c) < $0.r }
        }
        func outsideRect(_ p: Point) -> Bool { abs(p.x) > hx + 1e-9 || abs(p.y) > hy + 1e-9 }
        /// The exact crossing of circle `k` between two parameters.
        func crossing(_ a: Double, _ b: Double, _ k: Int) -> Double {
            var lo = a, hi = b
            let aInside = simd_distance(point(a), cuts[k].c) < cuts[k].r
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                if (simd_distance(point(mid), cuts[k].c) < cuts[k].r) == aInside { lo = mid } else { hi = mid }
            }
            return (lo + hi) / 2
        }

        let step = 0.004
        let count = Int(perimeter / step)
        var out: [Point] = []
        var s = 0.0
        var i = 0
        while i < count {
            let p = point(s)
            if inside(p) == nil {
                out.append(p)
                let next = s + step
                if let k = inside(point(next)) {
                    // Into a pocket's opening: round the bite and come out
                    // the other side.
                    let entry = crossing(s, next, k)
                    var t = next
                    while simd_distance(point(t), cuts[k].c) < cuts[k].r && t < s + perimeter { t += step }
                    let exit = crossing(t - step, t, k)
                    let c = cuts[k].c, r = cuts[k].r
                    let e = point(entry) - c, x = point(exit) - c
                    let a0 = atan2(e.y, e.x)
                    var a1 = atan2(x.y, x.x)
                    // Go round the side of the circle that lies outside the
                    // rectangle.
                    var sweep = a1 - a0
                    if sweep <= 0 { sweep += 2 * .pi }
                    let midway = c + Point(cos(a0 + sweep / 2), sin(a0 + sweep / 2)) * r
                    if !outsideRect(midway) { sweep -= 2 * .pi }
                    a1 = a0 + sweep
                    let pieces = max(8, Int(abs(sweep) / (3 * Double.pi / 180)))
                    for j in 0...pieces {
                        let a = a0 + sweep * Double(j) / Double(pieces)
                        out.append(c + Point(cos(a), sin(a)) * r)
                    }
                    let skipped = Int(((t - s) / step).rounded(.up))
                    i += skipped
                    s = t
                    continue
                }
            }
            s += step
            i += 1
        }
        return out
    }

    /// The leather that lines a pocket's opening in the rail: the part of
    /// the opening's circle that runs through wood, as a thin band `inset`
    /// to `outset` from the circle.
    static func linerPolygon(_ pocket: PoolPocket, _ d: PoolTableDimensions, inset: Double, outset: Double) -> [Point] {
        let c = pocket.center, r = d.cut(pocket)
        let samples = 180
        var angles: [Double] = []
        for i in 0..<samples {
            let a = Double(i) / Double(samples) * 2 * .pi
            let p = c + Point(cos(a), sin(a)) * r
            if abs(p.x) > d.backX || abs(p.y) > d.backY { angles.append(a) }
        }
        guard angles.count >= 2 else { return [] }
        // The kept angles form one run round the circle; find where it starts.
        var startIndex = 0
        for i in angles.indices {
            let previous = angles[(i + angles.count - 1) % angles.count]
            var gap = angles[i] - previous
            if gap < 0 { gap += 2 * .pi }
            if gap > 2 * .pi / Double(samples) * 1.5 { startIndex = i }
        }
        let run = (0..<angles.count).map { angles[(startIndex + $0) % angles.count] }
        var unwrapped: [Double] = []
        for a in run {
            var a = a
            if let last = unwrapped.last { while a < last { a += 2 * .pi } }
            unwrapped.append(a)
        }
        let outer = unwrapped.map { c + Point(cos($0), sin($0)) * (r + outset) }
        let inner = unwrapped.reversed().map { c + Point(cos($0), sin($0)) * (r - inset) }
        return outer + inner
    }
}
