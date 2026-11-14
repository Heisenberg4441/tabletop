#if !os(macOS)
import Foundation

struct simd_quatd: Equatable, Sendable {
    var vector: SIMD4<Double>

    init(ix: Double, iy: Double, iz: Double, r: Double) {
        vector = SIMD4(ix, iy, iz, r)
    }

    init(vector: SIMD4<Double>) { self.vector = vector }

    init(angle: Double, axis: SIMD3<Double>) {
        let half = angle * 0.5
        let unit = simd_normalize(axis)
        self.init(ix: unit.x * sin(half), iy: unit.y * sin(half), iz: unit.z * sin(half), r: cos(half))
    }

    var inverse: simd_quatd {
        simd_quatd(vector: SIMD4(-vector.x, -vector.y, -vector.z, vector.w))
    }

    static func * (a: simd_quatd, b: simd_quatd) -> simd_quatd {
        let av = SIMD3(a.vector.x, a.vector.y, a.vector.z)
        let bv = SIMD3(b.vector.x, b.vector.y, b.vector.z)
        let xyz = av * b.vector.w + bv * a.vector.w + simd_cross(av, bv)
        return simd_quatd(ix: xyz.x, iy: xyz.y, iz: xyz.z,
                          r: a.vector.w * b.vector.w - simd_dot(av, bv))
    }
}

func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: Numeric {
    var result = V.Scalar.zero
    for i in a.indices { result += a[i] * b[i] }
    return result
}

func simd_length_squared<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: Numeric {
    simd_dot(v, v)
}

func simd_length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length_squared(v).squareRoot()
}

func simd_distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length(a - b)
}

func simd_distance_squared<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint {
    let d = a - b
    return simd_dot(d, d)
}

func simd_normalize<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint {
    let length = simd_length(v)
    return length > 0 ? v / length : v
}

func simd_normalize(_ q: simd_quatd) -> simd_quatd {
    simd_quatd(vector: simd_normalize(q.vector))
}

func simd_cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func simd_slerp(_ a: simd_quatd, _ b: simd_quatd, _ t: Double) -> simd_quatd {
    var end = b
    var cosine = simd_dot(a.vector, b.vector)
    if cosine < 0 { cosine = -cosine; end = simd_quatd(vector: -b.vector) }
    if cosine > 0.9995 { return simd_normalize(simd_quatd(vector: a.vector + (end.vector - a.vector) * t)) }
    let angle = acos(min(1, max(-1, cosine)))
    let divisor = sin(angle)
    return simd_quatd(vector: a.vector * (sin((1 - t) * angle) / divisor) + end.vector * (sin(t * angle) / divisor))
}
#endif
