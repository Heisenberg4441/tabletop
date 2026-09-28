//
//  PoolTween.swift
//  "Move this from here to there over this long" for things SceneKit is not
//  animating by itself: the cue drawn back and struck, the computer's cue
//  swinging round onto its line, the cue ball carried to where the computer
//  placed it.
//
//  Tweens advance only when the game's frame clock ticks, so they stop dead
//  with it when the game leaves the screen and carry on from the same
//  instant when it comes back — nothing is scheduled against the wall clock.
//

import Foundation

final class PoolTween {
    let duration: Double
    private(set) var elapsed = 0.0
    private let curve: (Double) -> Double
    private let update: (Double) -> Void
    private let completion: (() -> Void)?

    init(duration: Double, curve: @escaping (Double) -> Double = PoolTween.easeInOut,
         update: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        self.duration = max(0, duration)
        self.curve = curve
        self.update = update
        self.completion = completion
    }

    var isFinished: Bool { elapsed >= duration }

    /// Moves on by `dt`; returns true once it has reached its end (having
    /// run its completion).
    func advance(_ dt: Double) -> Bool {
        elapsed = min(duration, elapsed + dt)
        let t = duration > 0 ? elapsed / duration : 1
        update(curve(t))
        if elapsed >= duration {
            completion?()
            return true
        }
        return false
    }

    /// Lands at the end at once.
    func finish() {
        guard elapsed < duration || duration == 0 else { return }
        elapsed = duration
        update(1)
        completion?()
    }

    static func easeInOut(_ t: Double) -> Double { t * t * (3 - 2 * t) }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    static func easeIn(_ t: Double) -> Double { t * t * t }
    static func linear(_ t: Double) -> Double { t }
}
