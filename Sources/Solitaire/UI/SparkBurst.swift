//
//  SparkBurst.swift
//  The burst of sparks a card throws off at the moment it lands.
//
//  A move already animates — the card glides, the shadow swells, the score
//  floats off — but all of that happens *while* the card is travelling, and
//  the arrival itself is silent: the card simply stops. The burst is what marks
//  the landing, and it is the piece that makes a click feel like it connected
//  rather than merely resolved.
//
//  Everything here is a plain `CALayer` with a background colour and a corner
//  radius. Not a `CAShapeLayer` (the play-test recognises the drop-target
//  outline by "a shape layer with a path", and a burst full of them would look
//  exactly like one), and not a `CAEmitterLayer` (a one-shot from an emitter
//  means turning a birth rate on and back off on a timer, which is more moving
//  parts than a dozen circles with three animations each).
//

import AppKit
import QuartzCore

/// One-shot spark bursts, pooled the way the score floats are.
///
/// The pool owns the layers rather than letting each burst delete itself from a
/// callback, for the same reason `ScoreFloatPool` does: the off-screen play-test
/// plays hundreds of moves in a tight loop with no run loop to deliver one, so
/// anything that can only be cleaned up later would simply pile up. Sweeping on
/// the way in costs nothing and cannot be skipped.
final class SparkBurstPool {

    /// How big and how busy a burst is. A card coming to rest on the tableau or
    /// the waste is housekeeping and gets the small one; a card reaching a
    /// foundation is progress, and progress is worth looking at.
    enum Scale {
        case puff
        case burst

        var sparkCount: Int { self == .burst ? 16 : 10 }
        /// How far the sparks travel and how wide the shock ring opens, as a
        /// multiple of the card width — like every other metric in the app, so
        /// the effect is the same design at any window size.
        var reach: CGFloat { self == .burst ? 0.62 : 0.40 }
        var sparkSize: CGFloat { self == .burst ? 0.072 : 0.055 }
        var lifetime: CFTimeInterval { self == .burst ? 0.46 : 0.34 }
        var ringOpacity: Float { self == .burst ? 0.62 : 0.34 }
    }

    private struct Live {
        let layers: [CALayer]
        let expires: CFTimeInterval
    }

    /// A hard ceiling on concurrent bursts. Auto-finish plays a move every
    /// 75ms, and without a cap the end of a game would be a wall of sparks
    /// with the cards invisible behind it. Four deep, the burst being dropped
    /// is already most of the way faded.
    static let maximum = 4

    /// Above every card, including one in flight (`z + 600`) and the drop-target
    /// outline (1000), and below the floating score (1200) and the cards in the
    /// player's hand (2000): sparks are thrown off the table, not held above it.
    ///
    /// Also how the play-test picks the burst's layers out of the board, which
    /// is why it is not private.
    static let zPosition: CGFloat = 1100

    private var live: [Live] = []

    /// Fires a burst at `point`, `delay` seconds from now.
    ///
    /// The delay is why every animation below carries a `beginTime` instead of
    /// the burst being posted to the main queue later: the sparks have to appear
    /// when the card *arrives*, which is one move-duration after the call, and
    /// letting Core Animation hold them means the whole burst is built, and
    /// therefore owned and sweepable, in one transaction now. A queued closure
    /// would also outlive a new deal and scatter sparks over a fresh board.
    ///
    /// `seed` makes a burst reproducible for a given move, so a screenshot of
    /// the same position twice is the same picture.
    func show(_ scale: Scale, at point: CGPoint, cardWidth: CGFloat,
              delay: CFTimeInterval, in root: CALayer, theme: Theme,
              contentsScale: CGFloat, seed: UInt64) {
        sweep(force: live.count >= Self.maximum)

        let start = CACurrentMediaTime() + max(0, delay)
        let radius = cardWidth * scale.reach
        var rng = DeterministicRNG(seed: seed)

        var made: [CALayer] = [ring(scale, at: point, radius: radius, cardWidth: cardWidth,
                                    theme: theme, start: start, contentsScale: contentsScale)]
        for i in 0..<scale.sparkCount {
            made.append(spark(scale, index: i, at: point, radius: radius, cardWidth: cardWidth,
                              theme: theme, start: start, contentsScale: contentsScale, rng: &rng))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        made.forEach(root.addSublayer)
        CATransaction.commit()

        live.append(Live(layers: made, expires: start + scale.lifetime))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + scale.lifetime + 0.05) { [weak self] in
            self?.sweep(force: false)
        }
    }

    // MARK: Pieces

    /// One spark: a small round dot that flies out along a ballistic arc,
    /// shrinking and fading as it goes.
    ///
    /// The model values are the ones the layer holds when nothing is animating —
    /// position at the impact point, opacity zero. That is what makes the delay
    /// work in both directions: before `start` the animations have not begun and
    /// after they finish they are removed, and in both cases what is left is an
    /// invisible dot sitting exactly where it will be needed.
    private func spark(_ scale: Scale, index: Int, at point: CGPoint, radius: CGFloat,
                       cardWidth: CGFloat, theme: Theme, start: CFTimeInterval,
                       contentsScale: CGFloat, rng: inout DeterministicRNG) -> CALayer {
        // Spread evenly around the circle and then jittered, rather than at
        // random angles: pure randomness clumps, and a clumped burst reads as a
        // handful of dots thrown in one direction.
        let slice = 2 * CGFloat.pi / CGFloat(scale.sparkCount)
        let angle = (CGFloat(index) + CGFloat(rng.next(upperBound: 70)) / 100 - 0.35) * slice
        let distance = radius * (0.62 + CGFloat(rng.next(upperBound: 80)) / 100)
        let side = cardWidth * scale.sparkSize * (0.7 + CGFloat(rng.next(upperBound: 70)) / 100)

        // The board is a flipped view, so +y is down the screen: the sparks fall
        // by *adding* to y, and the arc's control point sits above the straight
        // line by subtracting from it.
        let end = CGPoint(x: point.x + cos(angle) * distance,
                          y: point.y + sin(angle) * distance + radius * 0.42)
        let arc = CGMutablePath()
        arc.move(to: point)
        arc.addQuadCurve(to: end, control: CGPoint(x: (point.x + end.x) / 2,
                                                   y: (point.y + end.y) / 2 - radius * 0.34))

        let colour = index % 3 == 0 ? theme.sparkAccentColor : theme.sparkColor
        let spark = CALayer()
        spark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spark.position = point
        spark.cornerRadius = side / 2
        spark.backgroundColor = colour.cgColor
        spark.opacity = 0
        spark.zPosition = Self.zPosition
        spark.contentsScale = contentsScale
        // A glow rather than a drop shadow: offset zero, so the dot reads as
        // hot instead of as a tiny object casting a shadow on the felt.
        spark.shadowColor = colour.cgColor
        spark.shadowOffset = .zero
        spark.shadowRadius = side * 0.9
        spark.shadowOpacity = 0.85

        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = arc
        travel.calculationMode = .paced
        travel.duration = scale.lifetime
        travel.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.72, 0.25, 1)

        // Held at full strength over the first third, so the burst has a moment
        // of being solid before it thins out.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.35, 1]
        fade.duration = scale.lifetime

        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.15
        shrink.toValue = 0.2
        shrink.duration = scale.lifetime
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)

        for animation in [travel, fade, shrink] as [CAAnimation] {
            animation.beginTime = start
        }
        spark.add(travel, forKey: "travel")
        spark.add(fade, forKey: "fade")
        spark.add(shrink, forKey: "shrink")
        return spark
    }

    /// The shock ring: a thin circle that snaps open and vanishes. It lasts
    /// about half as long as the sparks, which is what gives the burst an
    /// impact at the front rather than a uniform puff.
    private func ring(_ scale: Scale, at point: CGPoint, radius: CGFloat, cardWidth: CGFloat,
                      theme: Theme, start: CFTimeInterval, contentsScale: CGFloat) -> CALayer {
        let side = radius * 2.1
        let ring = CALayer()
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = point
        ring.cornerRadius = side / 2
        ring.borderWidth = max(1, cardWidth * 0.022)
        ring.borderColor = theme.sparkColor.cgColor
        ring.opacity = 0
        ring.zPosition = Self.zPosition
        ring.contentsScale = contentsScale

        let open = CABasicAnimation(keyPath: "transform.scale")
        open.fromValue = 0.25
        open.toValue = 1.0
        open.duration = scale.lifetime * 0.62
        open.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.8, 0.2, 1)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [scale.ringOpacity, scale.ringOpacity * 0.7, 0]
        fade.keyTimes = [0, 0.45, 1]
        fade.duration = scale.lifetime * 0.62

        for animation in [open, fade] as [CAAnimation] {
            animation.beginTime = start
        }
        ring.add(open, forKey: "open")
        ring.add(fade, forKey: "fade")
        return ring
    }

    // MARK: Pool

    /// Drops every burst whose time is up. `force` also drops the oldest one
    /// still running, which is how the ceiling is kept.
    private func sweep(force: Bool) {
        let now = CACurrentMediaTime()
        var survivors: [Live] = []
        for entry in live {
            if entry.expires <= now {
                entry.layers.forEach { $0.removeFromSuperlayer() }
            } else {
                survivors.append(entry)
            }
        }
        if force, let oldest = survivors.first {
            oldest.layers.forEach { $0.removeFromSuperlayer() }
            survivors.removeFirst()
        }
        live = survivors
    }

    func removeAll() {
        live.forEach { $0.layers.forEach { $0.removeFromSuperlayer() } }
        live.removeAll()
    }
}
