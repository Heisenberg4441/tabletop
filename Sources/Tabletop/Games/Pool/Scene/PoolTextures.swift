//
//  PoolTextures.swift
//  Every picture the pool table is dressed in, made in code: the balls'
//  printed skins, the cloth and its weave, the walnut, the room the balls
//  reflect, the soft contact shadows.
//
//  All of it is pixels written into plain bitmaps — no drawing that depends
//  on the screen, nothing random that is not seeded — so a screenshot comes
//  out the same every time, and the whole set can be made off the main
//  thread while the scene is being put together.
//

import AppKit
import CoreText
import simd

/// A straightforward RGBA bitmap: written texel by texel, then turned into a
/// `CGImage` once.
struct PoolBitmap {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int, fill: SIMD4<Double> = [0, 0, 0, 1]) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        let r = Self.byte(fill.x * fill.w), g = Self.byte(fill.y * fill.w), b = Self.byte(fill.z * fill.w)
        let a = Self.byte(fill.w)
        for i in 0..<(width * height) {
            pixels[i * 4] = r
            pixels[i * 4 + 1] = g
            pixels[i * 4 + 2] = b
            pixels[i * 4 + 3] = a
        }
    }

    static func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    /// Sets an opaque texel (components 0…1, sRGB).
    mutating func set(_ x: Int, _ y: Int, _ c: SIMD3<Double>) {
        let i = (y * width + x) * 4
        pixels[i] = Self.byte(c.x)
        pixels[i + 1] = Self.byte(c.y)
        pixels[i + 2] = Self.byte(c.z)
        pixels[i + 3] = 255
    }

    /// Sets a texel with coverage, premultiplied.
    mutating func set(_ x: Int, _ y: Int, _ c: SIMD3<Double>, alpha: Double) {
        let i = (y * width + x) * 4
        pixels[i] = Self.byte(c.x * alpha)
        pixels[i + 1] = Self.byte(c.y * alpha)
        pixels[i + 2] = Self.byte(c.z * alpha)
        pixels[i + 3] = Self.byte(alpha)
    }

    func get(_ x: Int, _ y: Int) -> SIMD3<Double> {
        let i = (y * width + x) * 4
        return SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / 255
    }

    func makeImage(linear: Bool = false) -> CGImage? {
        let space = linear ? CGColorSpace(name: CGColorSpace.linearSRGB) : CGColorSpace(name: CGColorSpace.sRGB)
        guard let space, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

enum PoolTextures {

    // MARK: Small maths

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * t }

    static func rgb(_ color: NSColor) -> SIMD3<Double> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// Smooth value noise, deterministic, in roughly −1…1.
    static func noise(_ x: Double, _ y: Double, seed: UInt32 = 0) -> Double {
        func hash(_ i: Int, _ j: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: i &* 374_761_393 &+ j &* 668_265_263) &+ seed &* 2_246_822_519
            h = (h ^ (h >> 13)) &* 1_274_126_177
            h ^= h >> 16
            return Double(h & 0xFFFF) / 32767.5 - 1
        }
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    static func fbm(_ x: Double, _ y: Double, octaves: Int = 4, seed: UInt32 = 0) -> Double {
        var sum = 0.0, amplitude = 0.5, frequency = 1.0
        for o in 0..<octaves {
            sum += noise(x * frequency, y * frequency, seed: seed &+ UInt32(o) &* 31) * amplitude
            amplitude *= 0.5
            frequency *= 2.02
        }
        return sum
    }

    // MARK: Balls

    /// The texture's equirectangular mapping, which is SCNSphere's: `u`
    /// runs once round the equator, `v` from the north pole (+y) down.
    /// Longitude grows towards −z from +x when seen from above, which is the
    /// direction SceneKit wraps a sphere; the numbers read the right way
    /// round because of it.
    static func sphereDirection(u: Double, v: Double) -> SIMD3<Double> {
        let lon = u * 2 * .pi
        let lat = .pi / 2 - v * .pi
        return SIMD3(-cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon))
    }

    /// Where the two number spots sit on a ball, in the sphere's own frame:
    /// on the equator, opposite each other.
    static let spotDirections: [SIMD3<Double>] = [[0, 0, 1], [0, 0, -1]]
    static let spotRadius = 21.0 * Double.pi / 180
    /// Half-height of a stripe's coloured band, as a latitude.
    static let stripeBand = 40.0 * Double.pi / 180

    /// Ball `number`'s printed skin, 2:1, for an `SCNSphere`: the colour or
    /// the stripe, and the number in its white spot on two opposite sides,
    /// drawn undistorted by projecting each texel of the spot onto the plane
    /// that touches the ball there.
    static func ballImage(_ number: Int, width W: Int = 1024) -> CGImage? {
        let H = W / 2
        let ivory = rgb(TableArt.poolBallColor(0))
        let color = rgb(TableArt.poolBallColor(number))
        let spotWhite = SIMD3(0.975, 0.968, 0.940)
        let ink = SIMD3(0.075, 0.072, 0.080)
        var bitmap = PoolBitmap(width: W, height: H)
        let texel = Double.pi / Double(H)

        for j in 0..<H {
            let lat = .pi / 2 - (Double(j) + 0.5) / Double(H) * .pi
            var c = number > 8 ? ivory : color
            if number > 8 {
                c = mix(ivory, color, smoothstep(stripeBand + texel, stripeBand - texel, abs(lat)))
            }
            if number == 0 { c = ivory }
            for i in 0..<W { bitmap.set(i, j, c) }
        }
        guard number > 0, let glyph = glyphCoverage(number, size: 192) else { return bitmap.makeImage() }

        let k = tan(spotRadius)                       // the spot's half-size on its tangent plane
        let up = SIMD3<Double>(0, 1, 0)
        for centre in spotDirections {
            // Seen from outside, the viewer's right is (−c) × up.
            let right = simd_cross(-centre, up)
            // The texels that can fall inside the spot: a box in longitude
            // and latitude around it.
            let reach = spotRadius + 3 * texel
            let rows = Int(ceil(reach / texel)) + 1
            let centreRow = H / 2
            // The column of the spot's centre.
            let lon = atan2(centre.z, -centre.x)
            let centreColumn = Int(((lon < 0 ? lon + 2 * .pi : lon) / (2 * .pi) * Double(W)).rounded())
            let columns = Int(ceil(reach / (2 * .pi) * Double(W))) + 2
            for dj in -rows...rows {
                let j = centreRow + dj
                guard j >= 0, j < H else { continue }
                for di in -columns...columns {
                    let i = ((centreColumn + di) % W + W) % W
                    let d = sphereDirection(u: (Double(i) + 0.5) / Double(W), v: (Double(j) + 0.5) / Double(H))
                    let cosine = simd_dot(d, centre)
                    guard cosine > 0.5 else { continue }
                    let angle = acos(min(1, cosine))
                    let spot = smoothstep(spotRadius + texel * 0.8, spotRadius - texel * 0.8, angle)
                    guard spot > 0 else { continue }
                    // Gnomonic projection onto the tangent plane.
                    let q = d / cosine - centre
                    let s = simd_dot(q, right) / k, t = simd_dot(q, up) / k
                    let coverage = glyph.sample(x: (s + 1) / 2, y: (1 - t) / 2)
                    let base = bitmap.get(i, j)
                    let printed = mix(spotWhite, ink, coverage)
                    bitmap.set(i, j, mix(base, printed, spot))
                }
            }
        }
        return bitmap.makeImage()
    }

    /// A number's coverage, white on nothing, in a square that stands for
    /// the whole spot. Six and nine are underlined, as on a real set.
    struct Coverage {
        let size: Int
        let values: [Double]
        func sample(x: Double, y: Double) -> Double {
            let fx = x * Double(size) - 0.5, fy = y * Double(size) - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let wx = fx - Double(x0), wy = fy - Double(y0)
            func at(_ i: Int, _ j: Int) -> Double {
                guard i >= 0, j >= 0, i < size, j < size else { return 0 }
                return values[j * size + i]
            }
            let top = at(x0, y0) * (1 - wx) + at(x0 + 1, y0) * wx
            let bottom = at(x0, y0 + 1) * (1 - wx) + at(x0 + 1, y0 + 1) * wx
            return top * (1 - wy) + bottom * wy
        }
    }

    static func glyphCoverage(_ number: Int, size: Int) -> Coverage? {
        guard let space = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let text = String(number)
        let s = CGFloat(size)
        var font = Typography.rounded(s * 0.62, weight: .bold)
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]))
        var bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        // Two digits have to fit across the spot, not just up it.
        let widest = s * 0.74
        if bounds.width > widest {
            font = Typography.rounded(s * 0.62 * widest / bounds.width, weight: .bold)
            line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: CGColor(gray: 1, alpha: 1),
            ]))
            bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        let underline = number == 6 || number == 9
        let lift = underline ? s * 0.05 : 0
        ctx.textPosition = CGPoint(x: (s - bounds.width) / 2 - bounds.minX,
                                   y: (s - bounds.height) / 2 - bounds.minY + lift)
        CTLineDraw(line, ctx)
        if underline {
            let w = bounds.width * 0.62
            ctx.fill(CGRect(x: (s - w) / 2, y: (s - bounds.height) / 2 + lift - s * 0.10, width: w, height: s * 0.055))
        }
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: size * size)
        var values = [Double](repeating: 0, count: size * size)
        // A bitmap context's memory starts with its top row, like the
        // coverage.
        for i in 0..<(size * size) { values[i] = Double(bytes[i]) / 255 }
        return Coverage(size: size, values: values)
    }

    // MARK: The room

    /// What every ball reflects: the lamp's long diffuser straight overhead,
    /// the dark ceiling and walls of the room around it, and below the
    /// horizon the cloth the ball sits on, lit by the lamp. Equirectangular,
    /// for `SCNScene.lightingEnvironment`; the same mapping as the balls'.
    static func environmentImage(cloth: SIMD3<Double>, lampHeight: Double, lampLength: Double, lampWidth: Double,
                                 width W: Int = 1024) -> CGImage? {
        let H = W / 2
        var bitmap = PoolBitmap(width: W, height: H)
        let warm = SIMD3(1.0, 0.93, 0.80)
        let wall = SIMD3(0.105, 0.092, 0.082)
        // As bright as the cloth really looks under the lamp — the balls
        // reflect it along their lower halves.
        let clothLit = simd_min(cloth * 1.7 + SIMD3(repeating: 0.02), SIMD3(repeating: 1))
        for j in 0..<H {
            for i in 0..<W {
                let d = sphereDirection(u: (Double(i) + 0.5) / Double(W), v: (Double(j) + 0.5) / Double(H))
                var c = wall
                if d.y > 0.02 {
                    // The ceiling plane at lamp height.
                    let p = SIMD2(d.x, d.z) * (lampHeight / d.y)
                    let edge = 0.035
                    let inX = smoothstep(lampLength / 2 + edge, lampLength / 2 - edge, abs(p.x))
                    let inZ = smoothstep(lampWidth / 2 + edge, lampWidth / 2 - edge, abs(p.y))
                    // Three bulbs behind the diffuser, a little brighter.
                    var glow = 0.82
                    for bulb in [-lampLength / 3, 0, lampLength / 3] {
                        glow += 0.18 * exp(-pow((p.x - bulb) / (lampLength * 0.12), 2))
                    }
                    let lamp = inX * inZ
                    // The dark hood around the diffuser, then a faint spill
                    // of light on the ceiling.
                    let hood = smoothstep(lampLength / 2 + 0.16, lampLength / 2 + 0.05, abs(p.x))
                        * smoothstep(lampWidth / 2 + 0.12, lampWidth / 2 + 0.04, abs(p.y))
                    let spill = 0.06 * exp(-simd_length(p) / 1.4)
                    let ceiling = SIMD3(0.075, 0.068, 0.062) * (1 - hood) + SIMD3(repeating: 0.012) * hood
                    c = mix(ceiling + warm * spill, warm * min(1, glow), lamp)
                    // Towards the horizon the ceiling gives way to the walls.
                    c = mix(wall, c, smoothstep(0.02, 0.30, d.y))
                } else {
                    // Below the horizon: the lit cloth, darkening away from
                    // the lamp's pool, then the far walls right at the rim.
                    let fall = smoothstep(0.0, -0.5, d.y)
                    c = mix(wall, clothLit, fall)
                }
                // Soft panels on the walls, so the balls' sides are not a
                // featureless black.
                if abs(d.y) < 0.45 {
                    let angle = atan2(d.z, d.x)
                    for (centre, strength) in [(0.6, 0.05), (2.4, 0.035), (-1.9, 0.04), (-0.4, 0.025)] {
                        var delta = angle - centre
                        delta = atan2(sin(delta), cos(delta))
                        let panel = smoothstep(0.30, 0.18, abs(delta)) * smoothstep(0.42, 0.20, abs(d.y - 0.12))
                        c += SIMD3(0.95, 0.88, 0.78) * strength * 4 * panel
                    }
                }
                bitmap.set(i, j, c)
            }
        }
        return bitmap.makeImage()
    }

    // MARK: Cloth

    /// The playing surface's colour across the whole bed: the dye, and very
    /// slow unevenness — a cloth brushed in one direction, stretched by hand —
    /// that the eye takes for felt without ever seeing a pattern.
    static func clothImage(_ base: SIMD3<Double>, width W: Int = 1024, height H: Int = 512) -> CGImage? {
        var bitmap = PoolBitmap(width: W, height: H)
        for j in 0..<H {
            for i in 0..<W {
                let x = Double(i) / Double(W), y = Double(j) / Double(H)
                let blotch = fbm(x * 9, y * 5, octaves: 4, seed: 11) * 0.030
                // The nap: faint streaks running the length of the table.
                let nap = fbm(x * 1.5, y * 70, octaves: 2, seed: 23) * 0.014
                let fleck = noise(Double(i) * 0.9, Double(j) * 0.9, seed: 5) * 0.012
                bitmap.set(i, j, base * (1 + blotch + nap + fleck))
            }
        }
        return bitmap.makeImage()
    }

    /// The weave, as a tangent-space normal map that tiles: warp and weft a
    /// few texels apart, and fibre noise over them. Kept shallow — it should
    /// catch the light at a grazing angle and disappear head-on.
    static func clothNormalImage(size N: Int = 256) -> CGImage? {
        var height = [Double](repeating: 0, count: N * N)
        for j in 0..<N {
            for i in 0..<N {
                let x = Double(i), y = Double(j)
                let warp = sin(x / 4 * 2 * .pi) * 0.5 + 0.5
                let weft = sin(y / 4 * 2 * .pi) * 0.5 + 0.5
                // The threads cross over and under each other.
                let over = (Int(x / 4) + Int(y / 4)) % 2 == 0 ? warp : weft
                let fibre = noise(x * 0.7, y * 0.7, seed: 77) * 0.5 + noise(x * 0.23, y * 0.23, seed: 78) * 0.5
                height[j * N + i] = over * 0.6 + fibre * 0.4
            }
        }
        var bitmap = PoolBitmap(width: N, height: N)
        let strength = 0.9
        for j in 0..<N {
            for i in 0..<N {
                let l = height[j * N + (i + N - 1) % N], r = height[j * N + (i + 1) % N]
                let u = height[((j + N - 1) % N) * N + i], d = height[((j + 1) % N) * N + i]
                let n = simd_normalize(SIMD3((l - r) * strength, (d - u) * strength, 1))
                bitmap.set(i, j, n * 0.5 + SIMD3(repeating: 0.5))
            }
        }
        return bitmap.makeImage(linear: true)
    }

    // MARK: Wood

    static let walnut = SIMD3(0.215, 0.118, 0.062)

    /// Walnut with its grain running along `u`, for the table's sides and the
    /// cue's butt: long wavering lines, a few dark enough to read as the edge
    /// of a growth ring, and slow changes of tone.
    static func woodImage(width W: Int = 1024, height H: Int = 256, base: SIMD3<Double> = walnut, seed: UInt32 = 3,
                          grainAlongV: Bool = false, contrast: Double = 1) -> CGImage? {
        var bitmap = PoolBitmap(width: W, height: H)
        for j in 0..<H {
            for i in 0..<W {
                let x = Double(i) / Double(W), y = Double(j) / Double(H)
                let c = grainAlongV ? woodColor(x: y * 4, y: x, base: base, seed: seed, contrast: contrast)
                    : woodColor(x: x * 4, y: y, base: base, seed: seed, contrast: contrast)
                bitmap.set(i, j, c)
            }
        }
        return bitmap.makeImage()
    }

    /// One point of walnut, with `x` along the grain and `y` across it.
    static func woodColor(x: Double, y: Double, base: SIMD3<Double>, seed: UInt32, contrast: Double = 1) -> SIMD3<Double> {
        let warp = fbm(x * 1.3, y * 3, octaves: 3, seed: seed) * 0.35
        let rings = y * 38 + warp * 6
        let band = sin(rings * 2 * .pi) * 0.5 + 0.5
        let fine = noise(x * 60, y * 420, seed: seed &+ 9) * 0.5 + 0.5
        let tone = fbm(x * 0.8, y * 1.5, octaves: 2, seed: seed &+ 4) * 0.12
        let dark = (pow(band, 6) * 0.35 + fine * 0.10) * contrast
        return base * (1 + tone * contrast - dark + 0.08 * contrast)
    }

    /// The rail's top, as one picture over its whole bounding box: four
    /// lengths of walnut mitred at the corners, each with its grain along its
    /// own length — the way the kit's flat tables draw their frame.
    /// `inner` and `outer` are half-extents in metres; the picture is
    /// `pixelsPerMetre` dense.
    static func railImage(inner: SIMD2<Double>, outer: SIMD2<Double>, pixelsPerMetre: Double = 700) -> CGImage? {
        let W = Int(outer.x * 2 * pixelsPerMetre), H = Int(outer.y * 2 * pixelsPerMetre)
        var bitmap = PoolBitmap(width: W, height: H)
        for j in 0..<H {
            for i in 0..<W {
                // Table coordinates of the texel (image rows run from +y down).
                let p = SIMD2((Double(i) + 0.5) / pixelsPerMetre - outer.x,
                              outer.y - (Double(j) + 0.5) / pixelsPerMetre)
                // Which piece: the long rails own everything nearer their
                // edge than the mitre line through the corner.
                let dx = outer.x - abs(p.x), dy = outer.y - abs(p.y)
                let long = dy < dx
                let along = long ? p.x : p.y
                let across = long ? dy / (outer.y - inner.y) : dx / (outer.x - inner.x)
                let piece: UInt32 = long ? (p.y > 0 ? 1 : 2) : (p.x > 0 ? 3 : 4)
                var c = woodColor(x: along * 1.6, y: across * 0.9, base: walnut, seed: piece &* 17)
                // The mitre, as a hairline.
                if abs(dx - dy) < 0.0018 { c *= 0.72 }
                bitmap.set(i, j, c)
            }
        }
        return bitmap.makeImage()
    }

    // MARK: Shadows and glows

    /// A soft dark disc for under a ball, where it meets the cloth: the
    /// contact shadow no light in the scene is small enough to cast.
    static func contactShadowImage(size N: Int = 128) -> CGImage? {
        var bitmap = PoolBitmap(width: N, height: N, fill: [0, 0, 0, 0])
        for j in 0..<N {
            for i in 0..<N {
                let x = (Double(i) + 0.5) / Double(N) * 2 - 1, y = (Double(j) + 0.5) / Double(N) * 2 - 1
                let r = (x * x + y * y).squareRoot()
                let core = pow(max(0, 1 - smoothstep(0, 0.55, r)), 1.5) * 0.55
                let halo = pow(max(0, 1 - r), 2) * 0.28
                bitmap.set(i, j, .zero, alpha: min(0.85, core + halo))
            }
        }
        return bitmap.makeImage()
    }

    /// A line that fades out towards its far end (`u` = 1), for the guides.
    static func fadeImage(width W: Int = 256) -> CGImage? {
        var bitmap = PoolBitmap(width: W, height: 4, fill: [0, 0, 0, 0])
        for i in 0..<W {
            let t = Double(i) / Double(W - 1)
            let alpha = 1 - smoothstep(0.35, 1, t)
            for j in 0..<4 { bitmap.set(i, j, SIMD3(repeating: 1), alpha: alpha) }
        }
        return bitmap.makeImage()
    }

    /// The floor under the table: dark boards, barely there.
    static func floorImage(size N: Int = 512) -> CGImage? {
        var bitmap = PoolBitmap(width: N, height: N)
        let base = SIMD3(0.060, 0.048, 0.040)
        for j in 0..<N {
            for i in 0..<N {
                let board = Double(j / 64)
                let x = Double(i) / Double(N), y = Double(j % 64) / 64
                var c = woodColor(x: x * 2 + board * 0.37, y: y * 0.3 + board * 0.11, base: base, seed: UInt32(board) &+ 40)
                if j % 64 == 0 { c *= 0.6 }
                bitmap.set(i, j, c)
            }
        }
        return bitmap.makeImage()
    }
}
