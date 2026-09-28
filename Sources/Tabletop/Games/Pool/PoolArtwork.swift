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
        // A legal eight-ball rack: the eight in the middle of the third row,
        // and one solid and one stripe in the two back corners.
        let order = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 15, 7]
        var n = 0
        let rowStep = ball * 2 * 0.866 * 1.01
        for row in 0..<5 {
            for i in 0...row {
                balls.append((order[n], (CGFloat(i) - CGFloat(row) / 2) * ball * 2.02, 75 + CGFloat(row) * rowStep))
                n += 1
            }
        }
        let cueBall = (u: CGFloat(-8.5), v: CGFloat(49))
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

    /// The cue, lined up on the cue ball: a maple shaft with its white
    /// ferrule and blue tip, into an ebony butt, rising towards the camera
    /// the way a cue is held.
    private static func paintCue(camera: Camera, from ball: (u: CGFloat, v: CGFloat), aim: (u: CGFloat, v: CGFloat),
                                 rect: CGRect, context ctx: CGContext) {
        // Lined up on the shot: from the cue ball straight back, away from
        // the apex of the rack.
        let dx = ball.u - aim.u, dy = ball.v - aim.v
        let norm = max(0.001, hypot(dx, dy))
        let direction = CGVector(dx: dx / norm, dy: dy / norm)
        // Long enough to leave the picture at the bottom, short enough that
        // its near end stays well in front of the camera — a pinhole
        // projection of a point almost at the lens is all but infinite.
        let lengthOnTable: CGFloat = (ball.v - 12) / max(0.2, -direction.dy)
        let gap: CGFloat = 3.0
        let steps = 40
        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        var centres: [CGPoint] = []
        var shadowTop: [CGPoint] = []
        var shadowBottom: [CGPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let d = gap + t * lengthOnTable
            let u = ball.u + direction.dx * d
            let v = ball.v + direction.dy * d
            let h = PoolArtwork.ball + t * 5.5
            // A real cue swells from a 13 mm tip to a butt three times as
            // thick; anything thinner reads, at this size, as a line.
            let radius = 0.30 + t * 0.95
            let center = camera.project(u: u, v: v, h: h)
            let halfWidth = camera.focal * radius / max(0.5, camera.depth(v))
            centres.append(center)
            top.append(CGPoint(x: center.x - halfWidth, y: center.y))
            bottom.append(CGPoint(x: center.x + halfWidth, y: center.y))
            // Its shadow on the cloth, cast away from the lamp — close under
            // the tip, where the cue is low, and further off towards the butt
            // as it rises; narrowing to the tip like the cue itself.
            let s = camera.project(u: u + 0.25 + t * 0.6, v: v + 0.3, h: 0)
            let sw = halfWidth * (1.05 + t * 0.35)
            shadowTop.append(CGPoint(x: s.x - sw, y: s.y))
            shadowBottom.append(CGPoint(x: s.x + sw, y: s.y))
        }
        func band(_ from: Int, _ to: Int) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: Array(top[from...to]) + Array(bottom[from...to]).reversed())
            path.closeSubpath()
            return path
        }
        // The shadow is darkest under the tip, where the cue nearly touches
        // the cloth, and fades out towards the butt, which is held well above
        // it — so it reads as the cue's shadow, not a stripe of its own.
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let piece = CGMutablePath()
            piece.addLines(between: [shadowTop[i], shadowTop[i + 1], shadowBottom[i + 1], shadowBottom[i]])
            piece.closeSubpath()
            ctx.addPath(piece)
            ctx.setFillColor(NSColor(white: 0, alpha: 0.18 * pow(1 - t, 1.6)).cgColor)
            ctx.fillPath()
        }

        let tipEnd = 1, ferruleEnd = 2, shaftEnd = Int(CGFloat(steps) * 0.62)
        let parts: [(Int, Int, NSColor)] = [
            (0, tipEnd, NSColor(srgbRed: 0.24, green: 0.44, blue: 0.66, alpha: 1)),
            (tipEnd, ferruleEnd, NSColor(white: 0.95, alpha: 1)),
            (ferruleEnd, shaftEnd, NSColor(srgbRed: 0.86, green: 0.74, blue: 0.53, alpha: 1)),
            (shaftEnd, shaftEnd + 1, NSColor(srgbRed: 0.93, green: 0.90, blue: 0.84, alpha: 1)),
            (shaftEnd + 1, steps, NSColor(srgbRed: 0.13, green: 0.08, blue: 0.05, alpha: 1)),
        ]
        for (from, to, color) in parts {
            ctx.addPath(band(from, to))
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
        // Round: a highlight down the side towards the lamp, starting behind
        // the ferrule and square-ended, so it never runs past the tip as a
        // pale cap.
        let highlight = CGMutablePath()
        for (i, c) in centres.enumerated() where i >= ferruleEnd {
            let p = CGPoint(x: (c.x + top[i].x * 2) / 3, y: (c.y + top[i].y * 2) / 3)
            if i == ferruleEnd { highlight.move(to: p) } else { highlight.addLine(to: p) }
        }
        ctx.saveGState()
        ctx.addPath(band(ferruleEnd, steps))
        ctx.clip()
        ctx.addPath(highlight)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.30).cgColor)
        ctx.setLineWidth(max(1, (bottom[steps].x - top[steps].x) * 0.12))
        ctx.setLineCap(.butt)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
