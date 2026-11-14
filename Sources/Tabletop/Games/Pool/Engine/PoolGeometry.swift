//
//  PoolGeometry.swift
//  The regulation nine-foot table as the physics sees it: cushion noses as
//  line segments, pocket jaws cut at their proper angles, jaw points, the
//  capture region of each pocket, the head string and the spots.
//
//  The renderer extrudes its cushions from exactly these segments, so what a
//  ball visibly bounces off is what the simulation bounced it off.
//
//  Dimensions follow the WPA equipment specifications: a 100 × 50 inch
//  (2.540 × 1.270 m) playing surface between the cushion noses; 2¼ inch
//  balls; corner pocket mouths of 4½–4⅝ inches and side mouths of 5–5⅛,
//  measured between the points where the noses meet the jaws; jaw facings
//  cut at 142° to the nose in the corners and 104° at the sides — which is
//  what makes a corner pocket's throat narrow slightly as the ball goes in
//  and a side pocket's narrow a lot, and so makes pockets reject balls that
//  arrive badly.
//
//  Pocket numbering runs counter-clockwise seen from above (z up), starting
//  in the head-end corner at negative y:
//
//        5 ─────────── 4 ─────────── 3        +y
//        │  kitchen   :                │
//        │   · head   :        · foot  │       (head string at x = −L/4,
//        │     spot   :          spot  │        foot spot at x = +L/4)
//        0 ─────────── 1 ─────────── 2        −y
//      −x                                +x
//
//  Cushion (rail) k runs from pocket k to pocket k + 1: 0 and 1 along −y,
//  2 the foot rail, 3 and 4 along +y, 5 the head rail.
//

import Foundation
#if canImport(simd)
import simd
#endif

/// One straight piece of cushion rubber, seen from above: the nose of a
/// rail, or one facing of a pocket jaw.
struct PoolCushionSegment: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// The long straight nose a ball banks off.
        case nose
        /// A pocket facing, from a jaw point back into the pocket.
        case jaw
    }

    let a: SIMD2<Double>
    let b: SIMD2<Double>
    /// Unit normal on the side balls travel (into the table for a nose, into
    /// the pocket's throat for a jaw facing).
    let normal: SIMD2<Double>
    let kind: Kind
    /// The cushion (0–5) the segment belongs to.
    let rail: Int
    /// Unit vector from `a` to `b`, and the distance between them.
    let tangent: SIMD2<Double>
    let length: Double

    init(a: SIMD2<Double>, b: SIMD2<Double>, openSide: SIMD2<Double>, kind: Kind, rail: Int) {
        self.a = a
        self.b = b
        self.kind = kind
        self.rail = rail
        let d = b - a
        length = simd_length(d)
        tangent = d / length
        var n = SIMD2(-tangent.y, tangent.x)
        if simd_dot(n, openSide - a) < 0 { n = -n }
        normal = n
    }

    /// The point of the segment nearest `p`.
    func closestPoint(to p: SIMD2<Double>) -> SIMD2<Double> {
        let s = min(max(simd_dot(p - a, tangent), 0), length)
        return a + tangent * s
    }
}

typealias PoolPocketKind = PoolPocket.Kind

struct PoolPocket: Sendable, Equatable {
    enum Kind: String, Sendable {
        case corner, side
    }

    /// 0–5, counter-clockwise from the head-end corner at negative y.
    let id: Int
    let kind: Kind
    /// Centre of the capture region — where the ball falls — and of the
    /// pocket's cup for the renderer.
    let center: SIMD2<Double>
    /// A ball whose centre comes within this distance of `center` drops.
    let captureRadius: Double
    /// The two jaw points (where the cushion noses meet the facings); the
    /// line between them is the pocket's mouth.
    let mouth: (SIMD2<Double>, SIMD2<Double>)
    /// Unit vector from the middle of the mouth into the pocket.
    let axis: SIMD2<Double>
    /// Where the computer aims an object ball: just inside the middle of the
    /// mouth, where a ball arriving along the axis is certain to drop.
    let target: SIMD2<Double>

    var mouthCenter: SIMD2<Double> { (mouth.0 + mouth.1) * 0.5 }
    var mouthWidth: Double { simd_distance(mouth.0, mouth.1) }

    static func == (l: PoolPocket, r: PoolPocket) -> Bool {
        l.id == r.id && l.kind == r.kind && l.center == r.center && l.captureRadius == r.captureRadius
            && l.mouth.0 == r.mouth.0 && l.mouth.1 == r.mouth.1
    }
}

struct PoolTableGeometry: Sendable {
    /// Playing surface between the cushion noses, metres.
    let length: Double
    let width: Double
    let ballRadius: Double
    /// Height of the cushion nose above the cloth. A little above the ball's
    /// centre (63.5% of its diameter), which is why a ball comes off a rail
    /// with some of its topspin turned around.
    let cushionNoseHeight: Double
    /// How far the cushion rubber reaches back from its nose, for the
    /// renderer. The jaw facings end on this line.
    let cushionWidth: Double
    /// Every cushion segment in order around the table (counter-clockwise):
    /// for each rail its opening jaw facing, its nose, its closing facing.
    let cushions: [PoolCushionSegment]
    /// The twelve jaw points, two per pocket.
    let jawTips: [SIMD2<Double>]
    let pockets: [PoolPocket]
    /// The outline of each of the six cushions in plan view, counter-
    /// clockwise, for extrusion: back of the rubber, jaw point, jaw point,
    /// back of the rubber.
    let cushionOutlines: [[SIMD2<Double>]]
    /// The diamond sights on the rail tops, set back `sightInset` from the
    /// noses: seven along each long rail between the pockets, three on each
    /// end rail.
    let sights: [SIMD2<Double>]
    let sightInset: Double

    /// The head string (x of the line the kitchen lies behind).
    let headStringX: Double
    let footSpot: SIMD2<Double>
    let headSpot: SIMD2<Double>

    static let standard = PoolTableGeometry()

    init(length: Double = 2.540, width: Double = 1.270, ballRadius: Double = 0.028575,
         cushionNoseHeight: Double = 0.0363, cornerMouth: Double = 0.116, sideMouth: Double = 0.130,
         cushionWidth: Double = 0.050) {
        self.length = length
        self.width = width
        self.ballRadius = ballRadius
        self.cushionNoseHeight = cushionNoseHeight
        self.cushionWidth = cushionWidth
        headStringX = -length / 4
        footSpot = SIMD2(length / 4, 0)
        headSpot = SIMD2(-length / 4, 0)
        let hl = length / 2, hw = width / 2

        // Build one corner and one side pocket in the (+x, +y) quadrant and
        // mirror them, so the table is exactly symmetric in floating point —
        // a straight-on break must spread the same way to both sides.
        let d = cornerMouth / 2.squareRoot()          // jaw point to the corner of the noses
        let cornerFacing = 38.0 * .pi / 180            // 180° − 142°, off the nose line
        let sideFacing = 76.0 * .pi / 180              // 180° − 104°
        let cornerShelf = 0.036, cornerCup = 0.062     // mouth to the drop, and the cup's radius
        let sideShelf = 0.010, sideCup = 0.062

        struct Quadrant { let sx: Double; let sy: Double }
        func m(_ p: SIMD2<Double>, _ q: Quadrant) -> SIMD2<Double> { SIMD2(p.x * q.sx, p.y * q.sy) }

        // Corner at (+hl, +hw): jaw point on the long rail, on the end rail.
        let cLong = SIMD2(hl - d, hw), cEnd = SIMD2(hl, hw - d)
        let cLongBack = cLong + SIMD2(cos(cornerFacing), sin(cornerFacing)) * (cushionWidth / sin(cornerFacing))
        let cEndBack = cEnd + SIMD2(sin(cornerFacing), cos(cornerFacing)) * (cushionWidth / sin(cornerFacing))
        let cAxis = simd_normalize(SIMD2(1.0, 1.0))
        let cMouth = (cLong + cEnd) * 0.5
        let cCenter = cMouth + cAxis * (cornerShelf + cornerCup)
        let cTarget = cMouth + cAxis * 0.010
        // Side at (0, +hw): jaw points either side of x = 0.
        let sRight = SIMD2(sideMouth / 2, hw), sLeft = SIMD2(-sideMouth / 2, hw)
        let sRightBack = sRight + SIMD2(-cos(sideFacing), sin(sideFacing)) * (cushionWidth / sin(sideFacing))
        let sLeftBack = sLeft + SIMD2(cos(sideFacing), sin(sideFacing)) * (cushionWidth / sin(sideFacing))
        let sAxis = SIMD2(0.0, 1.0)
        let sCenter = SIMD2(0, hw) + sAxis * (sideShelf + sideCup)
        let sTarget = SIMD2(0, hw) + sAxis * 0.012

        // Per pocket, in counter-clockwise order: the jaw point the arriving
        // rail ends on and its facing's back end, then the point the leaving
        // rail starts from and its back end. The corner quadrants alternate
        // between arriving along a long rail (2, 5) and along an end rail
        // (0, 3); the sides are met from −x at pocket 1 and from +x at 4.
        let corners: [Int: (q: Quadrant, arrivesOnLongRail: Bool)] = [
            0: (Quadrant(sx: -1, sy: -1), false), 2: (Quadrant(sx: 1, sy: -1), true),
            3: (Quadrant(sx: 1, sy: 1), false), 5: (Quadrant(sx: -1, sy: 1), true),
        ]
        var pockets: [PoolPocket] = []
        var jaws: [(first: SIMD2<Double>, firstBack: SIMD2<Double>,
                    second: SIMD2<Double>, secondBack: SIMD2<Double>)] = []
        for id in 0..<6 {
            if let corner = corners[id] {
                let q = corner.q
                let long = (m(cLong, q), m(cLongBack, q)), end = (m(cEnd, q), m(cEndBack, q))
                let (first, second) = corner.arrivesOnLongRail ? (long, end) : (end, long)
                jaws.append((first.0, first.1, second.0, second.1))
                pockets.append(PoolPocket(id: id, kind: .corner, center: m(cCenter, q), captureRadius: cornerCup,
                                          mouth: (first.0, second.0), axis: m(cAxis, q), target: m(cTarget, q)))
            } else {
                let q = Quadrant(sx: 1, sy: id == 1 ? -1 : 1)
                let right = (m(sRight, q), m(sRightBack, q)), left = (m(sLeft, q), m(sLeftBack, q))
                let (first, second) = id == 1 ? (left, right) : (right, left)
                jaws.append((first.0, first.1, second.0, second.1))
                pockets.append(PoolPocket(id: id, kind: .side, center: m(sCenter, q), captureRadius: sideCup,
                                          mouth: (first.0, second.0), axis: m(sAxis, q), target: m(sTarget, q)))
            }
        }

        var cushions: [PoolCushionSegment] = []
        var outlines: [[SIMD2<Double>]] = []
        var tips: [SIMD2<Double>] = []
        for rail in 0..<6 {
            let from = pockets[rail], to = pockets[(rail + 1) % 6]
            let start = jaws[rail], end = jaws[(rail + 1) % 6]
            let tipA = start.second, backA = start.secondBack
            let tipB = end.first, backB = end.firstBack
            // Balls come at the facings from inside each pocket's throat and
            // at the nose from the table: the centre of the table is on the
            // open side of every nose, the pocket's centre on the open side
            // of its facings.
            cushions.append(PoolCushionSegment(a: backA, b: tipA, openSide: from.center, kind: .jaw, rail: rail))
            cushions.append(PoolCushionSegment(a: tipA, b: tipB, openSide: .zero, kind: .nose, rail: rail))
            cushions.append(PoolCushionSegment(a: tipB, b: backB, openSide: to.center, kind: .jaw, rail: rail))
            // Seen from above the chain runs clockwise round the rubber;
            // outlines are given counter-clockwise.
            outlines.append([backB, tipB, tipA, backA])
            tips.append(tipA)
            tips.append(tipB)
        }
        self.cushions = cushions
        self.cushionOutlines = outlines
        self.jawTips = tips
        self.pockets = pockets

        // Diamonds: every eighth of the length and quarter of the width,
        // skipping the pocket positions, set back onto the rail top.
        let inset = cushionWidth + 0.045
        var sights: [SIMD2<Double>] = []
        for i in 1..<8 where i != 4 {
            let x = -hl + length * Double(i) / 8
            sights.append(SIMD2(x, -hw - inset))
            sights.append(SIMD2(x, hw + inset))
        }
        for j in 1..<4 {
            let y = -hw + width * Double(j) / 4
            sights.append(SIMD2(-hl - inset, y))
            sights.append(SIMD2(hl + inset, y))
        }
        self.sights = sights
        self.sightInset = inset
    }

    /// Where the cue ball may be placed for a kitchen ball-in-hand: wholly on
    /// the cloth and with its centre behind the head string.
    func kitchenContains(_ p: SIMD2<Double>) -> Bool {
        p.x < headStringX && fitsOnCloth(p)
    }

    /// Whether a ball centred at `p` lies wholly on the playing surface,
    /// clear of the cushions and not over a pocket.
    func fitsOnCloth(_ p: SIMD2<Double>) -> Bool {
        guard p.x.isFinite, p.y.isFinite else { return false }
        let r = ballRadius
        return abs(p.x) <= length / 2 - r && abs(p.y) <= width / 2 - r
    }

    /// The ball centre stays inside this rectangle whenever it cannot touch a
    /// cushion or reach a pocket — the physics skips the cushion tests there.
    var innerHalfExtent: SIMD2<Double> {
        SIMD2(length / 2 - ballRadius, width / 2 - ballRadius)
    }
}
