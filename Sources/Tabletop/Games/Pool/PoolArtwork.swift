//
//  PoolArtwork.swift
//  Pool's cover: the rack under the lamp, seen from behind the cue ball.
//
//  The library's hero, so it is the one picture in the app drawn in
//  perspective rather than straight down: a real table in table units — 100
//  by 50 of cloth, cushions, a walnut rail with its diamonds, six pockets —
//  projected through a simple pinhole camera standing at the head of the
//  table. The camera is placed so the far rail sits near the top of the
//  picture and the cloth runs off the bottom, whatever shape the picture is:
//  a wide hero sees the table from lower down, a tile from higher up.
//
//  Everything else is the house style: one lamp over the rack, balls lit
//  from above and to the left, texture barely there, nothing but gradients
//  and paths.
//

import AppKit

enum PoolArtwork {

    /// A pinhole camera over the table. Table coordinates: `u` across
    /// (−25…25), `v` along, away from the camera (0 at the head cushion,
    /// 100 at the foot), `h` up from the cloth.
    private struct Camera {
        let focal: CGFloat
        let height: CGFloat
        let distance: CGFloat
        let horizon: CGFloat
        let centerX: CGFloat

        func depth(_ v: CGFloat) -> CGFloat { v + distance }

        func project(u: CGFloat, v: CGFloat, h: CGFloat = 0) -> CGPoint {
            let z = max(0.5, depth(v))
            return CGPoint(x: centerX + focal * u / z, y: horizon + focal * (height - h) / z)
        }

        /// A circle lying on the cloth, as the camera sees it.
        func disc(u: CGFloat, v: CGFloat, radius r: CGFloat, h: CGFloat = 0) -> CGPath {
            let path = CGMutablePath()
            for i in 0...36 {
                let a = CGFloat(i) / 36 * 2 * .pi
                let p = project(u: u + r * cos(a), v: v + r * sin(a), h: h)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            return path
        }

        func quad(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat, h: CGFloat = 0) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: [project(u: u0, v: v0, h: h), project(u: u1, v: v0, h: h),
                                    project(u: u1, v: v1, h: h), project(u: u0, v: v1, h: h)])
            path.closeSubpath()
            return path
        }
    }

    // The table, in table units.
    private static let halfWidth: CGFloat = 25
    private static let length: CGFloat = 100
    private static let cushion: CGFloat = 2.3
    private static let rail: CGFloat = 5.6
    private static let pocket: CGFloat = 2.25
    private static let ball: CGFloat = 1.55             // a touch over true scale, so a tile can read them

    static let cloth = NSColor(srgbRed: 0.075, green: 0.405, blue: 0.470, alpha: 1)
    static let clothEdge = NSColor(srgbRed: 0.016, green: 0.150, blue: 0.190, alpha: 1)

    static func draw(in ctx: CGContext, rect: CGRect) {
        let aspect = rect.width / max(1, rect.height)
        // Frame the far half of the table: the foot rail near the top, the
        // cloth just in front of the cue ball at the bottom edge, and the
        // table a little wider than the picture at the bottom.
        let bottomV: CGFloat = 40
        let topV = length + cushion + rail
        let distance: CGFloat = 22
        let span = 1 / (bottomV + distance) - 1 / (topV + distance)
        let g = (rect.height * 1.02) / span                    // focal × camera height
        let outer = halfWidth + cushion + rail
        let focal = rect.width * (aspect > 2 ? 1.10 : 1.04) * (bottomV + distance) / (outer * 2)
        let height = g / focal
        let horizon = rect.minY + rect.height * 0.085 - g / (topV + distance)
        let camera = Camera(focal: focal, height: height, distance: distance, horizon: horizon,
                            centerX: rect.midX + (aspect > 2 ? rect.width * 0.165 : 0))

        ctx.saveGState()
        ctx.clip(to: rect)

        // The room, and the lamp's glow above the far end.
        ctx.setFillColor(Palette.room.cgColor)
        ctx.fill(rect)
        let lampSpot = camera.project(u: 0, v: 74)
        if let glow = AppleStyle.gradient([(NSColor(srgbRed: 0.20, green: 0.19, blue: 0.17, alpha: 1), 0),
                                           (Palette.room, 1)]) {
            ctx.drawRadialGradient(glow, startCenter: lampSpot, startRadius: 0, endCenter: lampSpot,
                                   endRadius: max(rect.width, rect.height) * 0.75, options: [.drawsAfterEndLocation])
        }

        // The table's shadow on the floor, then the rail.
        let railPath = camera.quad(-outer, -30, outer, topV)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: rect.height * 0.04), blur: rect.height * 0.10,
                      color: NSColor(white: 0, alpha: 0.9).cgColor)
        ctx.addPath(railPath)
        ctx.setFillColor(NSColor(srgbRed: 0.22, green: 0.13, blue: 0.07, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        paintRail(camera: camera, path: railPath, outer: outer, topV: topV, rect: rect, context: ctx)

        // Cushions: the cloth-covered rubber inside the rail, a shade darker.
        let cushionPath = camera.quad(-halfWidth - cushion, -30, halfWidth + cushion, length + cushion)
        ctx.addPath(cushionPath)
        ctx.setFillColor((clothEdge.blended(withFraction: 0.35, of: cloth) ?? clothEdge).cgColor)
        ctx.fillPath()

        // The cloth, under the lamp.
        let clothPath = camera.quad(-halfWidth, -30, halfWidth, length)
        ctx.saveGState()
        ctx.addPath(clothPath)
        ctx.clip()
        ctx.setFillColor(clothEdge.cgColor)
        ctx.fill(rect)
        if let pool = AppleStyle.gradient([(cloth.blended(withFraction: 0.18, of: .white) ?? cloth, 0),
                                           (cloth, 0.30), (clothEdge, 1)]) {
            ctx.drawRadialGradient(pool, startCenter: lampSpot, startRadius: 0, endCenter: lampSpot,
                                   endRadius: rect.width * 0.62, options: [.drawsAfterEndLocation])
        }
        AppleStyle.grain(in: rect, context: ctx, alpha: 0.12, spread: 24)
        ctx.restoreGState()
        // The cushions' lip throws a thin shadow onto the cloth.
        AppleStyle.innerShadow(clothPath, in: clothPath.boundingBox, context: ctx,
                               color: NSColor(white: 0, alpha: 0.55), radius: rect.height * 0.012,
                               offset: CGSize(width: 0, height: rect.height * 0.004))

        // Pockets: two at the far corners, two at the middle of the sides.
        for (u, v) in [(-halfWidth - 0.4, length + 0.4), (halfWidth + 0.4, length + 0.4),
                       (-halfWidth - 1.2, length / 2), (halfWidth + 1.2, length / 2)] {
            let hole = camera.disc(u: u, v: v, radius: pocket)
            ctx.addPath(camera.disc(u: u, v: v, radius: pocket * 1.22))
            ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.06, blue: 0.045, alpha: 1).cgColor)
            ctx.fillPath()
            ctx.addPath(hole)
            ctx.setFillColor(NSColor(white: 0.015, alpha: 1).cgColor)
            ctx.fillPath()
            AppleStyle.innerShadow(hole, in: hole.boundingBox, context: ctx, color: NSColor(white: 0, alpha: 0.9),
                                   radius: 3, offset: CGSize(width: 0, height: 1.5))
        }

        // The balls: the rack on the foot spot, apex towards the camera, and
        // the cue ball waiting. Far to near, so the nearer ones overlap.
        var balls: [(number: Int, u: CGFloat, v: CGFloat)] = []
        // A legal eight-ball rack, row by row from the apex: the one on the
        // spot, the eight in the middle of the third row, and — the rule a
        // careful racker keeps — one solid and one stripe in the two back
        // corners. Solids and stripes alternate elsewhere, so the triangle
        // reads as a rack and not a heap.
        let rows: [[Int]] = [
            [1],
            [10, 3],
            [14, 8, 5],
            [4, 11, 7, 13],
            [9, 6, 15, 12, 2],
        ]
        // Balls just touching, a hair of gap so each keeps its own outline.
        let pitch = ball * 2 * 1.004
        let rowStep = pitch * 3.0.squareRoot() / 2
        for (row, numbers) in rows.enumerated() {
            for (i, number) in numbers.enumerated() {
                balls.append((number, (CGFloat(i) - CGFloat(row) / 2) * pitch, 75 + CGFloat(row) * rowStep))
            }
        }
        // Up the table from the bottom edge, a little to the left, the cue
        // lined up on the head ball — room below it for the cue to show.
        let cueBall = (u: CGFloat(-5.5), v: CGFloat(56))
        balls.append((0, cueBall.u, cueBall.v))
        balls.sort { $0.v > $1.v }

        for b in balls {
            let c = camera.project(u: b.u, v: b.v, h: ball)
            let r = camera.focal * ball / camera.depth(b.v)
            TableArt.poolBallShadow(center: c, radius: r, away: CGVector(dx: 0.35, dy: 0.25), squash: 0.42, context: ctx)
        }
        for (i, b) in balls.enumerated() {
            let c = camera.project(u: b.u, v: b.v, h: ball)
            let r = camera.focal * ball / camera.depth(b.v)
            TableArt.poolBall(b.number, center: c, radius: r, turn: CGFloat((i * 37) % 11) * 0.09 - 0.45, context: ctx)
        }

        paintCue(camera: camera, from: cueBall, aim: (u: 0, v: 75), rect: rect, context: ctx)
        ctx.restoreGState()
    }

    /// The walnut rail: dark wood, grain running along its length, lit on
    /// its top face, with mother-of-pearl diamonds let into it.
    private static func paintRail(camera: Camera, path: CGPath, outer: CGFloat, topV: CGFloat, rect: CGRect,
                                  context ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        AppleStyle.fillVertical(rect, context: ctx, [
            (NSColor(srgbRed: 0.30, green: 0.18, blue: 0.10, alpha: 1), 0),
            (NSColor(srgbRed: 0.38, green: 0.24, blue: 0.13, alpha: 1), 1),
        ])
        // Grain: lines running along the rail, converging with it.
        var rng = DeterministicRNG(seed: 0x9001)
        for i in 0..<42 {
            let t = CGFloat(i) / 41
            let u = -outer + t * outer * 2
            let dark = rng.next(upperBound: 100) < 55
            ctx.move(to: camera.project(u: u, v: -30))
            ctx.addLine(to: camera.project(u: u, v: topV))
            ctx.setStrokeColor(NSColor(white: dark ? 0 : 1, alpha: CGFloat(rng.next(upperBound: 60)) / 1000 + 0.02).cgColor)
            ctx.setLineWidth(0.6 + CGFloat(rng.next(upperBound: 10)) / 10)
            ctx.strokePath()
        }
        for i in 0..<14 {
            let v = topV - CGFloat(i) * 0.45
            ctx.move(to: camera.project(u: -outer, v: v))
            ctx.addLine(to: camera.project(u: outer, v: v))
            ctx.setStrokeColor(NSColor(white: rng.next(upperBound: 2) == 0 ? 0 : 1, alpha: 0.04).cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        }
        AppleStyle.grain(in: rect, context: ctx, alpha: 0.10, spread: 36)
        ctx.restoreGState()

        // The diamonds: three on each side between the pockets, three on the
        // foot rail.
        let railMiddle = halfWidth + cushion + rail * 0.5
        var sights: [(CGFloat, CGFloat)] = []
        for v in [62.5, 75, 87.5] as [CGFloat] { sights.append((-railMiddle, v)); sights.append((railMiddle, v)) }
        for u in [-12.5, 0, 12.5] as [CGFloat] { sights.append((u, length + cushion + rail * 0.5)) }
        for (u, v) in sights {
            let s: CGFloat = 0.55
            let diamond = CGMutablePath()
            diamond.addLines(between: [camera.project(u: u, v: v - s * 1.6), camera.project(u: u + s, v: v),
                                       camera.project(u: u, v: v + s * 1.6), camera.project(u: u - s, v: v)])
            diamond.closeSubpath()
            ctx.addPath(diamond)
            ctx.setFillColor(NSColor(srgbRed: 0.94, green: 0.93, blue: 0.88, alpha: 0.85).cgColor)
            ctx.fillPath()
        }
    }

    /// The cue, lined up on the cue ball and drawn back a little, coming
    /// up out of the bottom of the picture the way a player holds it: blue
    /// tip, ivory ferrule, a long maple shaft thickening to a silver joint,
    /// an ebony forearm with pale inlaid points. Each piece is lit round its
    /// girth from the lamp's side, and the cue lays a soft shadow on the
    /// cloth that is darkest under the tip, where it nearly touches.
    private static func paintCue(camera: Camera, from ball: (u: CGFloat, v: CGFloat), aim: (u: CGFloat, v: CGFloat),
                                 rect: CGRect, context ctx: CGContext) {
        let dx = ball.u - aim.u, dy = ball.v - aim.v
        let norm = max(0.001, hypot(dx, dy))
        let back = CGVector(dx: dx / norm, dy: dy / norm)
        // Along the cue from the tip, in table units (a real cue is about 58).
        let gap: CGFloat = 2.4
        // Stop well in front of the lens: a pinhole camera blows up anything
        // right at it.
        let reach = min(40, (ball.v - 8) / max(0.2, -back.dy))
        func axis(_ s: CGFloat) -> (centre: CGPoint, radius: CGFloat, ground: CGPoint) {
            let u = ball.u + back.dx * (gap + s), v = ball.v + back.dy * (gap + s)
            // The butt is held higher than the tip: about five degrees.
            let h = PoolArtwork.ball * 0.92 + s * 0.09
            // 13 mm at the tip, 21 at the joint (two thirds of the way), 30
            // at the butt — in table units, a touch over scale like the balls.
            let t = s / 58
            let radius = 0.40 + t * 0.72 + max(0, t - 0.62) * 1.1
            let centre = camera.project(u: u, v: v, h: h)
            let screen = camera.focal * radius / max(0.5, camera.depth(v))
            let ground = camera.project(u: u + 0.35 + s * 0.02, v: v + 0.25, h: 0)
            return (centre, screen, ground)
        }
        // The cue's direction on screen, for its outline and its shading.
        let a = axis(0).centre, b = axis(reach).centre
        let length = max(1, hypot(b.x - a.x, b.y - a.y))
        let along = CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
        let across = CGVector(dx: -along.dy, dy: along.dx)

        func band(_ s0: CGFloat, _ s1: CGFloat, scale: CGFloat = 1, useGround: Bool = false) -> CGPath {
            let steps = max(2, Int((s1 - s0) / 0.6))
            var left: [CGPoint] = [], right: [CGPoint] = []
            for k in 0...steps {
                let s = s0 + (s1 - s0) * CGFloat(k) / CGFloat(steps)
                let p = axis(s)
                let c = useGround ? p.ground : p.centre
                let r = p.radius * scale
                left.append(CGPoint(x: c.x + across.dx * r, y: c.y + across.dy * r))
                right.append(CGPoint(x: c.x - across.dx * r, y: c.y - across.dy * r))
            }
            let path = CGMutablePath()
            path.addLines(between: left + right.reversed())
            path.closeSubpath()
            return path
        }

        // The shadow first, fading towards the butt, which is held high.
        for k in 0..<24 {
            let s0 = reach * CGFloat(k) / 24, s1 = reach * CGFloat(k + 1) / 24
            ctx.addPath(band(s0, s1, scale: 1.25, useGround: true))
            ctx.setFillColor(NSColor(white: 0, alpha: 0.22 * pow(1 - CGFloat(k) / 24, 1.8)).cgColor)
            ctx.fillPath()
        }

        let pieces: [(CGFloat, CGFloat, NSColor)] = [
            (0, 0.45, NSColor(srgbRed: 0.22, green: 0.42, blue: 0.66, alpha: 1)),        // chalked tip
            (0.45, 1.4, NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1)),      // ferrule
            (1.4, 28.5, NSColor(srgbRed: 0.86, green: 0.74, blue: 0.54, alpha: 1)),      // maple shaft
            (28.5, 29.4, NSColor(srgbRed: 0.84, green: 0.85, blue: 0.87, alpha: 1)),     // silver joint
            (29.4, reach, NSColor(srgbRed: 0.10, green: 0.065, blue: 0.045, alpha: 1)),  // ebony forearm
        ]
        for (s0, s1, color) in pieces where s0 < reach {
            let path = band(s0, min(s1, reach))
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(color.cgColor)
            ctx.fill(path.boundingBoxOfPath)
            // Round: lit along the lamp's side, falling into shade on the
            // other, with a thin bright line where the lamp is reflected.
            let mid = axis((s0 + min(s1, reach)) / 2)
            let r = mid.radius
            let from = CGPoint(x: mid.centre.x + across.dx * r, y: mid.centre.y + across.dy * r)
            let to = CGPoint(x: mid.centre.x - across.dx * r, y: mid.centre.y - across.dy * r)
            if let shade = AppleStyle.gradient([
                (NSColor(white: 1, alpha: 0.10), 0), (NSColor(white: 1, alpha: 0.42), 0.26),
                (NSColor(white: 1, alpha: 0.0), 0.5), (NSColor(white: 0, alpha: 0.38), 1),
            ]) {
                // The lamp is up and to the left: whichever edge faces it is lit.
                let litFirst = across.dx < 0 || (across.dx == 0 && across.dy < 0)
                ctx.drawLinearGradient(shade, start: litFirst ? from : to, end: litFirst ? to : from,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
        // The forearm's inlaid points: four slim maple spears reaching up
        // from the butt towards the joint (two show from this side).
        if reach > 30 {
            for side in [-0.45, 0.45] as [CGFloat] {
                let tipAt = axis(29.9), baseAt = axis(min(reach, 38))
                let path = CGMutablePath()
                let tip = CGPoint(x: tipAt.centre.x + across.dx * tipAt.radius * side, y: tipAt.centre.y + across.dy * tipAt.radius * side)
                let b1 = CGPoint(x: baseAt.centre.x + across.dx * baseAt.radius * (side - 0.22),
                                 y: baseAt.centre.y + across.dy * baseAt.radius * (side - 0.22))
                let b2 = CGPoint(x: baseAt.centre.x + across.dx * baseAt.radius * (side + 0.22),
                                 y: baseAt.centre.y + across.dy * baseAt.radius * (side + 0.22))
                path.addLines(between: [tip, b1, b2])
                path.closeSubpath()
                ctx.saveGState()
                ctx.addPath(band(29.4, reach))
                ctx.clip()
                ctx.addPath(path)
                ctx.setFillColor(NSColor(srgbRed: 0.84, green: 0.72, blue: 0.52, alpha: 0.85).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
    }
}
