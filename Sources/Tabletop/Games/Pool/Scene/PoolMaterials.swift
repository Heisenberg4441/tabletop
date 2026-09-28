//
//  PoolMaterials.swift
//  What the table is made of, physically based throughout: cloth that
//  scatters, walnut under a satin varnish, phenolic balls under a clear
//  coat, mother-of-pearl sights, leather pockets.
//
//  The pictures come from `PoolTextures`; they are made once per process
//  (the balls' skins in parallel) and shared by every scene.
//

import AppKit
import SceneKit
import simd

@MainActor
enum PoolMaterials {

    // MARK: The texture cache

    private static var ballImages: [Int: CGImage] = [:]
    private static var images: [String: CGImage] = [:]

    /// Every ball's skin. The first call makes all sixteen at once, spread
    /// across the cores; it is the most expensive thing the table does.
    static func ballImage(_ number: Int) -> CGImage? {
        if ballImages.isEmpty {
            let made = UnsafeMutableBufferPointer<CGImage?>.allocate(capacity: 16)
            made.initialize(repeating: nil)
            let box = MainThreadBox(made)
            DispatchQueue.concurrentPerform(iterations: 16) { n in
                box.value[n] = PoolTextures.ballImage(n)
            }
            for n in 0..<16 { if let image = made[n] { ballImages[n] = image } }
            made.deinitialize()
            made.deallocate()
        }
        return ballImages[number]
    }

    static func image(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        if let cached = images[key] { return cached }
        let image = make()
        if let image { images[key] = image }
        return image
    }

    // MARK: Cloth

    /// The four cloths of the View menu, dyed the way real tournament cloth
    /// is: green, blue, a deep red for burgundy, a grey for slate.
    static func clothColor(_ table: TableColor) -> SIMD3<Double> {
        switch table {
        case .green: return [0.030, 0.300, 0.130]
        case .blue: return [0.000, 0.125, 0.360]
        case .burgundy: return [0.300, 0.000, 0.018]
        case .slate: return [0.105, 0.115, 0.132]
        }
    }

    static func clothNormal() -> CGImage? { image("cloth-normal") { PoolTextures.clothNormalImage() } }

    static func bedCloth(_ table: TableColor) -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = image("cloth-\(table.rawValue)") { PoolTextures.clothImage(clothColor(table), width: 512, height: 256) }
        applyNap(m, repeat: [180, 100])
        m.roughness.contents = 0.9
        // The room's light reaches the cloth only faintly; the lamp's pool
        // is what lights it, and keeps its falloff towards the rails.
        m.ambientOcclusion.contents = NSColor(white: 0.35, alpha: 1)
        return m
    }

    /// The same cloth on the cushions, where the big bed picture would
    /// stretch: the plain dye, with the weave.
    static func cushionCloth(_ table: TableColor) -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = color(clothColor(table) * 0.86)
        applyNap(m, repeat: [60, 60])
        m.roughness.contents = 0.88
        m.ambientOcclusion.contents = NSColor(white: 0.35, alpha: 1)
        return m
    }

    private static func applyNap(_ m: SCNMaterial, repeat r: SIMD2<Float>) {
        m.normal.contents = clothNormal()
        m.normal.intensity = 0.35
        m.normal.wrapS = .repeat
        m.normal.wrapT = .repeat
        m.normal.contentsTransform = SCNMatrix4MakeScale(CGFloat(r.x), CGFloat(r.y), 1)
        m.normal.mipFilter = .linear
        m.diffuse.mipFilter = .linear
    }

    // MARK: Wood and trim

    static func railTop(_ d: PoolTableDimensions) -> SCNMaterial {
        let m = varnishedWood()
        m.diffuse.contents = image("rail") {
            PoolTextures.railImage(inner: [d.backX, d.backY], outer: [d.outerX, d.outerY])
        }
        return m
    }

    /// The cabinet and legs under the rail, which the lamp never reaches:
    /// dark wood, unlit, so the room's light cannot tint it.
    static func woodInShadow() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image("wood") { PoolTextures.woodImage(width: 512, height: 128) }
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.multiply.contents = NSColor(white: 0.22, alpha: 1)
        return m
    }

    /// A satin varnish: enough coat to catch the lamp, not so much that
    /// the rail's edge mirrors the room.
    private static func varnishedWood() -> SCNMaterial {
        let m = pbr()
        m.roughness.contents = 0.56
        m.clearCoat.contents = 0.16
        m.clearCoatRoughness.contents = 0.3
        m.diffuse.mipFilter = .linear
        return m
    }

    static func pearl() -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = NSColor(srgbRed: 0.93, green: 0.92, blue: 0.87, alpha: 1)
        m.roughness.contents = 0.22
        m.clearCoat.contents = 1
        m.clearCoatRoughness.contents = 0.05
        return m
    }

    static func leather() -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = NSColor(white: 0.03, alpha: 1)
        m.roughness.contents = 0.7
        // Inside a pocket the room's light hardly reaches; without this the
        // leather mirrors the cloth.
        m.ambientOcclusion.contents = NSColor(white: 0.12, alpha: 1)
        return m
    }

    static func pocketDepth() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(white: 0.006, alpha: 1)
        return m
    }

    /// Boards about 15 cm wide over a plane `span` metres across, fading
    /// out to nothing towards its edge.
    static func floor(span: Double) -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = image("floor") { PoolTextures.floorImage(size: 256) }
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        let repeats = CGFloat(span / (4 * 0.15))           // four boards to a tile
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
        m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.8
        m.transparent.contents = image("floor-fade") { PoolTextures.radialFadeImage() }
        m.transparencyMode = .aOne
        m.blendMode = .alpha
        m.isDoubleSided = false
        return m
    }

    static func hood() -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = NSColor(srgbRed: 0.035, green: 0.060, blue: 0.050, alpha: 1)
        m.metalness.contents = 0.55
        m.roughness.contents = 0.38
        return m
    }

    static func brass() -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = NSColor(srgbRed: 0.78, green: 0.62, blue: 0.36, alpha: 1)
        m.metalness.contents = 1
        m.roughness.contents = 0.3
        return m
    }

    static func diffuser() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor(srgbRed: 1.0, green: 0.95, blue: 0.84, alpha: 1)
        return m
    }

    // MARK: Balls

    static func ball(_ number: Int) -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = ballImage(number)
        m.diffuse.mipFilter = .linear
        m.roughness.contents = 0.14
        m.clearCoat.contents = 1
        m.clearCoatRoughness.contents = 0.025
        return m
    }

    static func contactShadow() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image("contact") { PoolTextures.contactShadowImage() }
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = false
        return m
    }

    // MARK: Guides

    /// An unlit overlay colour for a guide: drawn on top of the cloth,
    /// never lit, never shadowed, never writing depth.
    static func guide(_ color: NSColor, alpha: CGFloat, fade: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        if fade {
            m.diffuse.contents = image("fade") { PoolTextures.fadeImage() }
            m.multiply.contents = color
        } else {
            m.diffuse.contents = color
        }
        m.transparency = alpha
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }

    /// The cue ball's stand-in where it may not be put down: a lit,
    /// see-through red ball.
    static func deniedBall() -> SCNMaterial {
        let m = pbr()
        m.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.24, blue: 0.22, alpha: 1)
        m.roughness.contents = 0.25
        m.clearCoat.contents = 0.6
        m.clearCoatRoughness.contents = 0.05
        m.blendMode = .alpha
        m.isDoubleSided = false
        m.writesToDepthBuffer = false
        return m
    }

    // MARK: Plumbing

    static func pbr() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.metalness.contents = 0
        return m
    }

    static func color(_ c: SIMD3<Double>) -> NSColor {
        NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
}
