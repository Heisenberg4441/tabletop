//
//  PoolCameraRig.swift
//  Where the camera is, and how it gets somewhere else.
//
//  The camera is described the way a player thinks about it — a point it is
//  looking at, which way round it is (yaw), how steeply it looks down
//  (pitch), how far back it stands and how wide it sees — and every one of
//  those follows its goal on a critically damped spring. So a change of view
//  is always a single calm glide that arrives without overshooting, whatever
//  it was doing when the goal moved, and looking straight down (the top
//  view) is just a pitch of 90° rather than the singularity a look-at
//  camera has there.
//

import Foundation
import simd

struct PoolCameraPose: Equatable {
    /// The point looked at, in scene coordinates.
    var focus: SIMD3<Double>
    /// Which way the camera faces, round the vertical: 0 looks along −z (the
    /// table's +y); `aim − π/2` looks along a shot at `aim`.
    var yaw: Double
    /// How far below the horizon it looks: 0 level, π/2 straight down.
    var pitch: Double
    var distance: Double
    /// Vertical field of view, degrees.
    var fieldOfView: Double

    static func yaw(forAim aim: Double) -> Double { aim - .pi / 2 }

    /// The direction the camera looks.
    var forward: SIMD3<Double> {
        SIMD3(-sin(yaw) * cos(pitch), -sin(pitch), -cos(yaw) * cos(pitch))
    }

    var position: SIMD3<Double> { focus - forward * distance }

    var orientation: simd_quatf {
        simd_quatf(angle: Float(yaw), axis: [0, 1, 0]) * simd_quatf(angle: Float(-pitch), axis: [1, 0, 0])
    }
}

/// One value on a critically damped spring, integrated implicitly so it is
/// stable at any frame rate.
struct PoolSpring {
    var value: Double
    var velocity = 0.0

    init(_ value: Double) { self.value = value }

    mutating func step(to target: Double, omega: Double, dt: Double) {
        let f = 1 + 2 * dt * omega
        let oo = omega * omega
        let hoo = dt * oo
        let hhoo = dt * hoo
        let inverse = 1 / (f + hhoo)
        let x = f * value + dt * velocity + hhoo * target
        let v = velocity + hoo * (target - value)
        value = x * inverse
        velocity = v * inverse
    }

    func isSettled(at target: Double, tolerance: Double) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 4
    }
}

struct PoolCameraRig {
    private(set) var goal: PoolCameraPose
    private var fx, fy, fz, yaw, pitch, distance, fov: PoolSpring
    /// How quickly the camera closes on its goal, per second. About 0.7 s
    /// from start to rest.
    var omega = 7.5

    init(_ pose: PoolCameraPose) {
        goal = pose
        fx = PoolSpring(pose.focus.x)
        fy = PoolSpring(pose.focus.y)
        fz = PoolSpring(pose.focus.z)
        yaw = PoolSpring(pose.yaw)
        pitch = PoolSpring(pose.pitch)
        distance = PoolSpring(pose.distance)
        fov = PoolSpring(pose.fieldOfView)
    }

    var current: PoolCameraPose {
        PoolCameraPose(focus: [fx.value, fy.value, fz.value], yaw: yaw.value, pitch: pitch.value,
                       distance: distance.value, fieldOfView: fov.value)
    }

    /// Sets where the camera should go. `immediately` cuts there — for
    /// Reduce Motion, a snapshot, or a drag the camera must follow exactly.
    mutating func set(_ pose: PoolCameraPose, immediately: Bool) {
        var pose = pose
        // Round the short way: a goal yaw is taken to within half a turn of
        // where the camera is facing now.
        let delta = atan2(sin(pose.yaw - yaw.value), cos(pose.yaw - yaw.value))
        pose.yaw = yaw.value + delta
        goal = pose
        if immediately { snap() }
    }

    /// Advances by `dt` seconds. Returns true while still moving.
    @discardableResult
    mutating func step(_ dt: Double) -> Bool {
        guard !isSettled else { return false }
        fx.step(to: goal.focus.x, omega: omega, dt: dt)
        fy.step(to: goal.focus.y, omega: omega, dt: dt)
        fz.step(to: goal.focus.z, omega: omega, dt: dt)
        yaw.step(to: goal.yaw, omega: omega, dt: dt)
        pitch.step(to: goal.pitch, omega: omega, dt: dt)
        distance.step(to: goal.distance, omega: omega, dt: dt)
        fov.step(to: goal.fieldOfView, omega: omega, dt: dt)
        if isSettled { snap(); return false }
        return true
    }

    /// Lands on the goal, keeping the rig's speed setting.
    private mutating func snap() {
        let speed = omega
        self = PoolCameraRig(goal)
        omega = speed
    }

    var isSettled: Bool {
        // Half a millimetre and a few hundredths of a degree: closer than a
        // pixel, so the last frames of the approach are never drawn for
        // nothing.
        fx.isSettled(at: goal.focus.x, tolerance: 5e-4) && fy.isSettled(at: goal.focus.y, tolerance: 5e-4)
            && fz.isSettled(at: goal.focus.z, tolerance: 5e-4) && yaw.isSettled(at: goal.yaw, tolerance: 5e-4)
            && pitch.isSettled(at: goal.pitch, tolerance: 5e-4) && distance.isSettled(at: goal.distance, tolerance: 5e-4)
            && fov.isSettled(at: goal.fieldOfView, tolerance: 2e-3)
    }
}
