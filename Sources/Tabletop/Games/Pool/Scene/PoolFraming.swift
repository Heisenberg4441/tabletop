//
//  PoolFraming.swift
//  Fitting what matters into the part of the picture the HUD leaves free.
//
//  A camera looking from a given direction (yaw and pitch) is placed as
//  close as it can be while every point asked for lands inside the view's
//  free area — below the players' plates, above the action bar, between the
//  power meter and the spin control — and the points sit in the middle of
//  that area rather than of the whole view. This is exact, not a guess from
//  a bounding box: each point is projected through the camera, and moving
//  the focus across the view (square to the line of sight) shifts every
//  point on screen without changing its depth, so for a given distance the
//  focus positions that keep everything in frame are an interval on each
//  screen axis. The nearest distance at which both intervals are non-empty
//  is found by bisection, and the focus is put in the middle of both.
//

import CoreGraphics
import simd

enum PoolFraming {

    /// Margins kept clear at each edge of the view, in points.
    struct Insets: Equatable {
        var top: Double
        var left: Double
        var bottom: Double
        var right: Double
    }

    /// The nearest camera looking along `yaw` and `pitch` that shows every
    /// one of `points` (scene coordinates) inside the free part of a
    /// `viewport`-sized view, no nearer than `range`'s lower end. Nil when
    /// even its upper end is not far enough, or the free area is empty.
    static func fit(_ points: [SIMD3<Double>], yaw: Double, pitch: Double, fieldOfView: Double, viewport: CGSize,
                    insets: Insets, distance range: ClosedRange<Double>) -> PoolCameraPose? {
        let w = Double(viewport.width), h = Double(viewport.height)
        guard !points.isEmpty, w > 1, h > 1 else { return nil }
        // The free area in normalised device coordinates, y up.
        let xl = -1 + 2 * insets.left / w, xh = 1 - 2 * insets.right / w
        let yb = -1 + 2 * insets.bottom / h, yt = 1 - 2 * insets.top / h
        guard xl < xh, yb < yt else { return nil }
        let ty = tan(fieldOfView / 2 * .pi / 180), tx = ty * w / h

        let probe = PoolCameraPose(focus: .zero, yaw: yaw, pitch: pitch, distance: 1, fieldOfView: fieldOfView)
        let forward = probe.forward
        let right = SIMD3(cos(yaw), 0, -sin(yaw))
        let up = simd_cross(right, forward)
        var lo = points[0], hi = points[0]
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let centre = (lo + hi) / 2
        let local = points.map { p -> SIMD3<Double> in
            let q = p - centre
            return SIMD3(simd_dot(q, right), simd_dot(q, up), simd_dot(q, forward))
        }

        /// The focus shifts (along `right`, along `up`) that keep every point
        /// in the free area from `distance`, if there are any.
        func shifts(_ distance: Double) -> (a: ClosedRange<Double>, b: ClosedRange<Double>)? {
            var aLo = -Double.infinity, aHi = Double.infinity, bLo = -Double.infinity, bHi = Double.infinity
            for q in local {
                let z = q.z + distance
                guard z > 0.05 else { return nil }
                aLo = max(aLo, q.x - xh * z * tx)
                aHi = min(aHi, q.x - xl * z * tx)
                bLo = max(bLo, q.y - yt * z * ty)
                bHi = min(bHi, q.y - yb * z * ty)
            }
            guard aLo <= aHi, bLo <= bHi else { return nil }
            return (aLo...aHi, bLo...bHi)
        }

        var distance = range.lowerBound
        var found = shifts(distance)
        if found == nil {
            guard shifts(range.upperBound) != nil else { return nil }
            var near = range.lowerBound, far = range.upperBound
            for _ in 0..<40 {
                let mid = (near + far) / 2
                if shifts(mid) != nil { far = mid } else { near = mid }
            }
            distance = far
            found = shifts(far)
        }
        guard let (a, b) = found else { return nil }
        let focus = centre + right * ((a.lowerBound + a.upperBound) / 2) + up * ((b.lowerBound + b.upperBound) / 2)
        return PoolCameraPose(focus: focus, yaw: yaw, pitch: pitch, distance: distance, fieldOfView: fieldOfView)
    }

    /// Where `point` lands on a `viewport`-sized view from `pose`, in points
    /// from the top left, or nil if it is behind the camera.
    static func project(_ point: SIMD3<Double>, from pose: PoolCameraPose, viewport: CGSize) -> CGPoint? {
        let w = Double(viewport.width), h = Double(viewport.height)
        let forward = pose.forward
        let right = SIMD3(cos(pose.yaw), 0, -sin(pose.yaw))
        let up = simd_cross(right, forward)
        let q = point - pose.position
        let z = simd_dot(q, forward)
        guard z > 1e-6 else { return nil }
        let ty = tan(pose.fieldOfView / 2 * .pi / 180), tx = ty * w / h
        let x = simd_dot(q, right) / (z * tx), y = simd_dot(q, up) / (z * ty)
        return CGPoint(x: (x + 1) / 2 * w, y: (1 - y) / 2 * h)
    }
}
