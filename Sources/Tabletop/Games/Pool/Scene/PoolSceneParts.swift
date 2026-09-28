//
//  PoolSceneParts.swift
//  The things on the table that move: the balls, the cue, and the aiming
//  guides drawn on the cloth.
//

import AppKit
import SceneKit
import simd

// MARK: - A ball

@MainActor
final class PoolBallNode {
    let number: Int
    /// Where the engine says the ball is, turned the way it says.
    let node = SCNNode()
    /// The printed sphere, turned once more by a fixed amount of its own so a
    /// rack does not show every number facing the same way.
    let body: SCNNode
    /// The soft darkening where it touches the cloth. Not a child of the
    /// ball: it must not roll with it.
    let contact: SCNNode
    private let radius: Double

    init(number: Int, radius: Double) {
        self.number = number
        self.radius = radius
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 72
        sphere.materials = [PoolMaterials.ball(number)]
        body = SCNNode(geometry: sphere)
        body.simdOrientation = Self.displayTurn(number)
        body.castsShadow = true
        node.addChildNode(body)
        node.name = "ball-\(number)"

        let blob = SCNPlane(width: CGFloat(radius * 3.4), height: CGFloat(radius * 3.4))
        blob.materials = [PoolMaterials.contactShadow()]
        contact = SCNNode(geometry: blob)
        contact.eulerAngles.x = -.pi / 2
        contact.castsShadow = false
        contact.renderingOrder = 5
    }

    /// A turn for each ball's skin, seeded by its number: its spot tipped up
    /// towards the head of the table by a different amount each time, so in
    /// a fresh rack most numbers can be read from behind the cue ball.
    static func displayTurn(_ number: Int) -> simd_quatf {
        guard number > 0 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        var rng = DeterministicRNG(seed: UInt64(number) &* 0x51F1_5EED)
        func unit() -> Float { Float(rng.next(upperBound: 1001)) / 1000 }
        // The spot (+z in the skin) turned to face up and back along −x.
        let target = simd_normalize(SIMD3<Float>(-0.55 - unit() * 0.5, 0.65 + unit() * 0.5, (unit() - 0.5) * 1.2))
        let from = SIMD3<Float>(0, 0, 1)
        let spin = simd_quatf(angle: (unit() - 0.5) * 1.2, axis: from)
        return simd_quatf(from: from, to: target) * spin
    }

    func place(position: SIMD2<Double>, orientation: simd_quatd) {
        node.isHidden = false
        contact.isHidden = false
        node.simdPosition = PoolSpace.sceneSIMD(position, height: radius)
        node.simdOrientation = PoolSpace.sceneOrientation(orientation)
        contact.simdPosition = PoolSpace.sceneSIMD(position, height: 0.0005)
        contact.opacity = 1
    }

    /// A ball on its way down a pocket: first carried over the lip towards
    /// the middle of the hole, then dropping out of sight.
    func drop(from position: SIMD2<Double>, orientation: simd_quatd, into pocket: PoolPocket, progress p: Double) {
        guard p < 1 else { hide(); return }
        let over = PoolTextures.smoothstep(0, 0.55, p)
        let fall = pow(PoolTextures.smoothstep(0.12, 1, p), 1.6)
        let at = position + (pocket.center - position) * over
        node.isHidden = false
        node.simdPosition = PoolSpace.sceneSIMD(at, height: radius - fall * (radius * 2 + 0.09))
        node.simdOrientation = PoolSpace.sceneOrientation(orientation)
        contact.simdPosition = PoolSpace.sceneSIMD(at, height: 0.0005)
        contact.opacity = CGFloat(1 - PoolTextures.smoothstep(0, 0.35, p))
        contact.isHidden = contact.opacity <= 0.01
    }

    func hide() {
        node.isHidden = true
        contact.isHidden = true
    }
}

// MARK: - The cue

/// A 58-inch cue: blue-chalked tip, ivory ferrule, a maple shaft thickening
/// to the joint, an ebony forearm, a linen wrap between two silver rings, an
/// ebony sleeve and a rubber bumper. Built from the tip backwards along +z,
/// with the tip at the node's origin, so pointing it is `look(at:)`.
@MainActor
final class PoolCueNode {
    let node = SCNNode()
    let length: Double

    /// The shaft's radius `distance` metres back from the tip — for clearing
    /// rails and balls.
    func radius(at distance: Double) -> Double {
        var z = 0.0
        for part in Self.parts {
            if distance <= z + part.length {
                let t = (distance - z) / part.length
                return part.r0 + (part.r1 - part.r0) * t
            }
            z += part.length
        }
        return Self.parts.last?.r1 ?? 0.015
    }

    private struct Part { let length: Double; let r0: Double; let r1: Double; let material: String }

    private static let parts: [Part] = [
        Part(length: 0.009, r0: 0.0064, r1: 0.0064, material: "tip"),
        Part(length: 0.024, r0: 0.0064, r1: 0.0066, material: "ferrule"),
        Part(length: 0.700, r0: 0.0066, r1: 0.0106, material: "maple"),
        Part(length: 0.016, r0: 0.0112, r1: 0.0112, material: "silver"),
        Part(length: 0.300, r0: 0.0110, r1: 0.0128, material: "ebony"),
        Part(length: 0.006, r0: 0.0130, r1: 0.0130, material: "silver"),
        Part(length: 0.240, r0: 0.0129, r1: 0.0137, material: "wrap"),
        Part(length: 0.006, r0: 0.0139, r1: 0.0139, material: "silver"),
        Part(length: 0.150, r0: 0.0138, r1: 0.0147, material: "ebony"),
        Part(length: 0.012, r0: 0.0147, r1: 0.0138, material: "bumper"),
    ]

    init() {
        let materials = Self.materials()
        var z = 0.0
        for part in Self.parts {
            // SCNCone runs along y with its top at +y; turned a quarter about
            // x its top points along +z, away from the tip.
            let cone = SCNCone(topRadius: CGFloat(part.r1), bottomRadius: CGFloat(part.r0), height: CGFloat(part.length))
            cone.radialSegmentCount = 40
            if let m = materials[part.material] { cone.materials = [m] }
            let piece = SCNNode(geometry: cone)
            piece.eulerAngles.x = .pi / 2
            piece.position.z = CGFloat(z + part.length / 2)
            piece.castsShadow = true
            node.addChildNode(piece)
            z += part.length
        }
        length = z
        node.name = "cue"
    }

    private static func materials() -> [String: SCNMaterial] {
        func make(_ color: NSColor, roughness: CGFloat, metal: CGFloat = 0, coat: CGFloat = 0) -> SCNMaterial {
            let m = PoolMaterials.pbr()
            m.diffuse.contents = color
            m.roughness.contents = roughness
            m.metalness.contents = metal
            if coat > 0 {
                m.clearCoat.contents = coat
                m.clearCoatRoughness.contents = 0.08
            }
            return m
        }
        let maple = make(NSColor(srgbRed: 0.80, green: 0.67, blue: 0.47, alpha: 1), roughness: 0.4, coat: 0.5)
        // The grain runs the length of the shaft, faint — maple is a pale,
        // close-grained wood.
        maple.diffuse.contents = PoolMaterials.image("maple") {
            PoolTextures.woodImage(width: 64, height: 512, base: [0.78, 0.65, 0.46], seed: 91, grainAlongV: true, contrast: 0.35)
        }
        maple.diffuse.wrapS = .repeat
        let ebony = make(NSColor(srgbRed: 0.055, green: 0.036, blue: 0.028, alpha: 1), roughness: 0.22, coat: 0.9)
        return [
            "tip": make(NSColor(srgbRed: 0.20, green: 0.38, blue: 0.62, alpha: 1), roughness: 0.95),
            "ferrule": make(NSColor(srgbRed: 0.95, green: 0.94, blue: 0.90, alpha: 1), roughness: 0.3, coat: 0.4),
            "maple": maple,
            "silver": make(NSColor(white: 0.86, alpha: 1), roughness: 0.22, metal: 1),
            "ebony": ebony,
            "wrap": make(NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1), roughness: 0.85),
            "bumper": make(NSColor(white: 0.03, alpha: 1), roughness: 0.7),
        ]
    }

    /// Lines the cue up on the cue ball at `centre`: along `aim`, its tip
    /// on the point of the ball the spin control chose, drawn back by
    /// `pullBack` metres, its butt raised by `elevation` radians.
    func place(ballCentre centre: SIMD3<Float>, aim: Double, tipSide: Double, tipVertical: Double,
               radius R: Double, pullBack: Double, elevation: Double) {
        let flat = PoolSpace.direction(aim)
        let e = Float(elevation)
        // Pointing from the butt to the tip: along the aim and a little down.
        let forward = simd_normalize(SIMD3(flat.x * cos(e), -sin(e), flat.z * cos(e)))
        let right = simd_normalize(simd_cross(forward, [0, 1, 0]))
        let up = simd_cross(right, forward)
        let a = Float(tipSide * 0.5 * R), b = Float(tipVertical * 0.5 * R)
        let depth = Float(max(0, R * R - Double(a * a + b * b)).squareRoot())
        let contact = centre + right * a + up * b - forward * depth
        let tip = contact - forward * Float(0.004 + pullBack)
        node.simdPosition = tip
        node.simdLook(at: tip + forward, up: [0, 1, 0], localFront: [0, 0, -1])
    }
}

// MARK: - The aiming guides

/// Drawn on the cloth, like 3D Pool's: a thin line from the cue ball to
/// where it will meet the object ball, a ghost of the cue ball at that
/// moment, the line the object ball will leave on, and a shorter one for
/// where the cue ball will glance off to.
@MainActor
final class PoolGuideNodes {
    let node = SCNNode()
    private let aimLine: SCNNode
    private let objectLine: SCNNode
    private let cueLine: SCNNode
    private let ghost: SCNNode
    private let ghostRing: SCNNode
    private let wallMark: SCNNode
    private let radius: Double
    private static let lift: Float = 0.0009

    init(radius: Double) {
        self.radius = radius
        func line(_ alpha: CGFloat, fade: Bool, width: CGFloat) -> SCNNode {
            let box = SCNBox(width: 1, height: 0.0002, length: width, chamferRadius: 0)
            box.materials = [PoolMaterials.guide(.white, alpha: alpha, fade: fade)]
            let n = SCNNode(geometry: box)
            n.castsShadow = false
            n.renderingOrder = 10
            return n
        }
        aimLine = line(0.62, fade: false, width: 0.0021)
        objectLine = line(0.70, fade: true, width: 0.0024)
        cueLine = line(0.42, fade: true, width: 0.0019)

        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 48
        let glass = PoolMaterials.guide(.white, alpha: 0.16)
        glass.readsFromDepthBuffer = true
        glass.fresnelExponent = 1
        sphere.materials = [glass]
        ghost = SCNNode(geometry: sphere)
        ghost.castsShadow = false
        ghost.renderingOrder = 11

        let ring = SCNTube(innerRadius: CGFloat(radius - 0.0011), outerRadius: CGFloat(radius + 0.0002), height: 0.0003)
        ring.radialSegmentCount = 64
        ring.materials = [PoolMaterials.guide(.white, alpha: 0.75)]
        ghostRing = SCNNode(geometry: ring)
        ghostRing.castsShadow = false
        ghostRing.renderingOrder = 10

        let mark = SCNTube(innerRadius: CGFloat(radius * 0.35), outerRadius: CGFloat(radius * 0.35 + 0.0012), height: 0.0003)
        mark.radialSegmentCount = 48
        mark.materials = [PoolMaterials.guide(.white, alpha: 0.6)]
        wallMark = SCNNode(geometry: mark)
        wallMark.castsShadow = false

        for n in [aimLine, objectLine, cueLine, ghost, ghostRing, wallMark] { node.addChildNode(n) }
        node.name = "guides"
    }

    private func lay(_ line: SCNNode, from a: SIMD2<Double>, to b: SIMD2<Double>) {
        let length = simd_distance(a, b)
        guard length > 0.002 else { line.isHidden = true; return }
        line.isHidden = false
        let mid = (a + b) / 2
        line.simdPosition = PoolSpace.sceneSIMD(mid, height: Double(Self.lift))
        line.simdScale = SIMD3(Float(length), 1, 1)
        line.simdEulerAngles = SIMD3(0, Float(atan2(b.y - a.y, b.x - a.x)), 0)
    }

    /// Shows the guides for a shot from `cue` along `aim`, as the engine
    /// predicts it, reaching `objectReach` and `cueReach` metres past the
    /// contact (0 hides them), clipped to the cloth.
    func show(cue: SIMD2<Double>, prediction: PoolAimPrediction, objectBall: SIMD2<Double>?,
              objectReach: Double, cueReach: Double, dimensions d: PoolTableDimensions) {
        node.isHidden = false
        let direction = simd_normalize(prediction.ghostBallCenter - cue)
        let start = cue + (simd_length(direction) > 0 ? direction * radius : .zero)
        let ghostAt = prediction.ghostBallCenter
        lay(aimLine, from: start, to: ghostAt - (simd_length(direction) > 0 ? direction * radius : .zero))
        ghost.simdPosition = PoolSpace.sceneSIMD(ghostAt, height: radius)
        ghostRing.simdPosition = PoolSpace.sceneSIMD(ghostAt, height: Double(Self.lift) + 0.0002)
        ghost.isHidden = prediction.targetBall == nil
        ghostRing.isHidden = false

        if let target = objectBall, let out = prediction.objectBallDirection, objectReach > 0 {
            let from = target + out * radius
            lay(objectLine, from: from, to: clipToCloth(from, out, objectReach, d))
        } else {
            objectLine.isHidden = true
        }
        if let glance = prediction.cueBallDeflection, cueReach > 0, simd_length(glance) > 0.01 {
            let from = ghostAt + glance * radius
            lay(cueLine, from: from, to: clipToCloth(from, glance, cueReach, d))
        } else {
            cueLine.isHidden = true
        }
        if prediction.targetBall == nil, let wall = prediction.cushionPoint {
            wallMark.isHidden = false
            wallMark.simdPosition = PoolSpace.sceneSIMD(wall, height: Double(Self.lift))
        } else {
            wallMark.isHidden = true
        }
    }

    func hide() { node.isHidden = true }

    /// Where a line from `p` along `u` for `reach` metres leaves the cloth.
    private func clipToCloth(_ p: SIMD2<Double>, _ u: SIMD2<Double>, _ reach: Double, _ d: PoolTableDimensions) -> SIMD2<Double> {
        var t = reach
        let hx = d.halfLength - radius, hy = d.halfWidth - radius
        if u.x > 1e-9 { t = min(t, (hx - p.x) / u.x) }
        if u.x < -1e-9 { t = min(t, (-hx - p.x) / u.x) }
        if u.y > 1e-9 { t = min(t, (hy - p.y) / u.y) }
        if u.y < -1e-9 { t = min(t, (-hy - p.y) / u.y) }
        return p + u * max(0, t)
    }
}
