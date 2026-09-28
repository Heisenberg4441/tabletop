//
//  CardLayer.swift
//  One layer per card, moved around by the compositor.
//
//  Shared by Solitaire's board and the kit's `CardTableView`. A card has a
//  resting turn in the plane of the table — a fanned hand, the trump lying
//  across the deck, a discard thrown down at an angle — and every other
//  transform it goes through composes with that turn rather than replacing
//  it: picked up, it grows and leans into the drag *at its angle*; turned
//  over, it flips about its own long axis, still at its angle. The resting
//  transform is a pure rotation about z, with no perspective in it, so a card
//  at rest is still something `CALayer.render(in:)` can photograph.
//

import AppKit
import QuartzCore

final class CardLayer: CALayer {

    private enum Key {
        static let turn = "turn"
        static let move = "move"
        static let liftOpacity = "liftOpacity"
        static let liftRadius = "liftRadius"
        static let liftOffset = "liftOffset"
        static let pickUp = "pickUp"
        static let flip = "flip"
    }

    /// How much larger a card is drawn while the player is holding it. Enough
    /// to separate it from the pile it came off, not enough to misjudge where
    /// it will land — the hit testing uses `bounds`, which this does not touch.
    private static let heldScale: CGFloat = 1.05

    /// The card this layer shows. Changed only through `setCard`, for a
    /// table that reuses one sprite for a different card.
    private(set) var card: Card
    private(set) var isFaceUp: Bool = false

    /// The card's turn in the plane of the table, in radians, clockwise
    /// (the tables are flipped views, y growing downward). Zero is upright.
    private(set) var restingRotation: CGFloat = 0

    /// How much smaller (or larger) than its bounds the card is drawn at
    /// rest — an opponent's hand held further away. 1 is actual size.
    private(set) var restingScale: CGFloat = 1

    /// The transform of a card lying still: its resting turn and size, and
    /// nothing else. Affine on purpose — see the top of the file.
    private var restTransform: CATransform3D {
        var t = CATransform3DIdentity
        if restingRotation != 0 { t = CATransform3DMakeRotation(restingRotation, 0, 0, 1) }
        if restingScale != 1 { t = CATransform3DScale(t, restingScale, restingScale, 1) }
        return t
    }
    /// True while the player is dragging this card, so layout leaves it alone.
    var isHeld = false

    /// The Apple look: a deeper shadow, a card that leans in the hand, and a
    /// turn that goes edge-on in real perspective instead of squeezing flat.
    /// On by default, like `Theme.apple`; whoever owns the layer sets it from
    /// the theme whenever the theme changes.
    var apple = true

    /// How hard the perspective bites, as Core Animation's `m34`.
    ///
    /// Derived from the card rather than fixed, so the effect looks identical
    /// at every window size: a constant eye distance would make a 56-point card
    /// nearly flat and a 168-point one look like it was shot with a fisheye.
    private var eyeDistance: CGFloat { -1 / max(60, bounds.width * 3.2) }

    /// How far the card leans while being dragged, in radians about each axis.
    private var tilt = CGVector.zero
    private var isPickedUp = false

    /// Scale, resting turn, lean and perspective, applied in that order. One
    /// place builds this, because two animations writing different parts of
    /// one transform is a fight with no winner.
    ///
    /// Each `CATransform3DRotate` below goes on *before* what is already
    /// there, so the list reads backwards: the card is scaled first, then
    /// turned to its resting angle, then leaned — the lean is about the
    /// screen's axes, the direction the hand is moving, not the card's.
    private var heldTransform: CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = eyeDistance
        // The view's geometry is flipped, which leaves the x and z axes alone:
        // a positive turn about y still brings the right edge towards the eye,
        // and a positive turn about x still brings the lower edge forward. So
        // both leans are simply "into the direction of travel".
        t = CATransform3DRotate(t, tilt.dy, 1, 0, 0)
        t = CATransform3DRotate(t, tilt.dx, 0, 1, 0)
        if restingRotation != 0 { t = CATransform3DRotate(t, restingRotation, 0, 0, 1) }
        let scale = (isPickedUp ? Self.heldScale : 1) * restingScale
        return CATransform3DScale(t, scale, scale, 1)
    }

    /// Turned over by `angle` about the card's own long axis, at its resting
    /// turn `rotation`, in perspective. The flip is applied first, so the card
    /// turns about itself and not about the screen's vertical.
    private func flipTransform(_ angle: CGFloat, rotation: CGFloat, scale: CGFloat = 1) -> CATransform3D {
        var t = CATransform3DIdentity
        t.m34 = eyeDistance
        if rotation != 0 { t = CATransform3DRotate(t, rotation, 0, 0, 1) }
        if scale != 1 { t = CATransform3DScale(t, scale, scale, 1) }
        return CATransform3DRotate(t, angle, 0, 1, 0)
    }

    init(card: Card) {
        self.card = card
        super.init()
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // A shadow path costs nothing; without one Core Animation renders the
        // shadow off-screen every frame for every card, which is exactly the
        // kind of thing that makes a card game heat up a laptop.
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.28
        shadowRadius = 3
        shadowOffset = CGSize(width: 0, height: 1.5)
        magnificationFilter = .trilinear
        minificationFilter = .trilinear
    }

    override init(layer: Any) {
        let other = layer as? CardLayer
        self.card = other?.card ?? Card(code: 0)
        self.restingRotation = other?.restingRotation ?? 0
        self.restingScale = other?.restingScale ?? 1
        self.isFaceUp = other?.isFaceUp ?? false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Core Animation animates every property change by default, which fights
    /// with our own explicit transactions. Turning implicit animation off means
    /// nothing moves unless we say so.
    override class func defaultAction(forKey event: String) -> CAAction? {
        NSNull()
    }

    override func action(forKey event: String) -> CAAction? { nil }

    func setFace(_ faceUp: Bool, renderer: CardRenderer) {
        isFaceUp = faceUp
        contents = faceUp ? renderer.faceImage(for: card) : renderer.backImage()
    }

    func refreshImage(renderer: CardRenderer) {
        contents = isFaceUp ? renderer.faceImage(for: card) : renderer.backImage()
    }

    /// Makes this layer show `card` instead — a sprite id reused for another
    /// card. Face and position are kept.
    func setCard(_ card: Card, renderer: CardRenderer) {
        guard card != self.card else { return }
        self.card = card
        refreshImage(renderer: renderer)
    }

    func updateShadow(cornerRadius: CGFloat, lifted: Bool) {
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                            cornerHeight: cornerRadius, transform: nil)
        shadowOpacity = Float(lifted ? liftedShadow.opacity : restingShadow.opacity)
        shadowRadius = lifted ? liftedShadow.radius : restingShadow.radius
        shadowOffset = CGSize(width: 0, height: lifted ? liftedShadow.offset : restingShadow.offset)
    }

    /// A card lying on the table. Apple mode spends more on this than anything
    /// else here: a soft shadow with real offset is the single cue that says
    /// "this object is above that surface", and the flat deck deliberately
    /// keeps it tight so the board reads as a diagram instead.
    private var restingShadow: (opacity: CGFloat, radius: CGFloat, offset: CGFloat) {
        apple
            ? (0.34, max(2, bounds.width * 0.050), max(1, bounds.width * 0.022))
            : (0.28, max(2, bounds.width * 0.028), max(1, bounds.width * 0.012))
    }

    /// The same card in the player's hand, or half way across the table.
    private var liftedShadow: (opacity: CGFloat, radius: CGFloat, offset: CGFloat) {
        apple
            ? (0.50, bounds.width * 0.17, bounds.width * 0.105)
            : (0.45, bounds.width * 0.09, bounds.width * 0.05)
    }

    /// Glides the card to `point` instead of jumping there.
    ///
    /// Implicit animation is off for this class, so the movement every other
    /// part of the board relies on has to be spelled out here. The `from` value
    /// is taken from the presentation layer rather than the model one, and that
    /// is the whole reason this is a method and not two lines at the call site:
    /// a card redirected while it is still flying — the player clicking faster
    /// than the animation, auto-finish stepping on its own tail — sets off from
    /// where it actually is on screen instead of snapping back to the place it
    /// was heading and starting again.
    func glide(to point: CGPoint, duration: CFTimeInterval, timing: CAMediaTimingFunction) {
        let from = animation(forKey: Key.move) != nil
            ? (presentation()?.position ?? position)
            : position
        position = point

        guard duration > 0, abs(from.x - point.x) > 0.5 || abs(from.y - point.y) > 0.5 else {
            removeAnimation(forKey: Key.move)
            return
        }

        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: point)
        slide.duration = duration
        slide.timingFunction = timing
        add(slide, forKey: Key.move)
    }

    /// Grows the card into the player's hand and sets it back down again.
    ///
    /// `flip` drives `transform.scale.x` on the same layer, so the two would
    /// fight — but a card cannot be held and turning over at once: layout skips
    /// held cards entirely, and the card underneath the one being lifted is a
    /// different layer.
    func setPickedUp(_ pickedUp: Bool, duration: CFTimeInterval) {
        if apple {
            setPickedUpInPerspective(pickedUp, duration: duration)
            return
        }
        let target = pickedUp ? Self.heldScale : 1.0
        // KVC hands back an NSNumber here, and `as? CGFloat` on one is not a
        // bridge that can be relied on; go through the number.
        let scaleX = (presentation() ?? self).value(forKeyPath: "transform.scale.x") as? NSNumber
        let current = CGFloat(scaleX?.doubleValue ?? 1.0)
        setValue(target, forKeyPath: "transform.scale")

        guard duration > 0, abs(current - target) > 0.001 else {
            removeAnimation(forKey: Key.pickUp)
            return
        }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = current
        grow.toValue = target
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        add(grow, forKey: Key.pickUp)
    }

    /// Apple mode's version of the same thing, written as one whole transform
    /// rather than through `transform.scale`.
    ///
    /// It has to be the whole matrix, because the lean and the perspective live
    /// in components that no key path reaches. Interpolating a matrix the way
    /// Core Animation does — component by component — is only safe over small
    /// angles, and this one never turns more than a few degrees; the flip,
    /// which goes all the way to edge-on, samples its rotation instead.
    private func setPickedUpInPerspective(_ pickedUp: Bool, duration: CFTimeInterval) {
        guard pickedUp != isPickedUp || (!pickedUp && tilt != .zero) else { return }
        let from = presentation()?.transform ?? transform
        isPickedUp = pickedUp
        if !pickedUp { tilt = .zero }
        let target = pickedUp ? heldTransform : restTransform
        transform = target

        guard duration > 0 else {
            removeAnimation(forKey: Key.pickUp)
            return
        }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: from)
        grow.toValue = NSValue(caTransform3D: target)
        grow.duration = duration
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        add(grow, forKey: Key.pickUp)
    }

    /// Leans the card into the direction the hand is moving it.
    ///
    /// Called on every mouse-moved event while a drag is live, so it writes the
    /// transform straight out with no animation of its own — the smoothing is
    /// in the caller, which feeds it a rolling average rather than the raw jump
    /// between two events. A card that snapped to each frame's velocity would
    /// jitter rather than lean.
    func setDragLean(dx: CGFloat, dy: CGFloat) {
        guard apple, isPickedUp else { return }
        let limit: CGFloat = 0.18                    // about ten degrees
        let perPoint: CGFloat = 0.010
        tilt = CGVector(dx: max(-limit, min(limit, dx * perPoint)),
                        dy: max(-limit, min(limit, dy * perPoint)))
        // Written straight to the model, and deliberately without cancelling a
        // pick-up that is still running. Cancelling it makes the card snap to
        // full size instead of growing into the hand, which is a far more
        // visible fault than the one this leaves behind: for the 130ms the
        // hand takes to close, the grow is heading for a target a couple of
        // degrees stale, and it lands on the leaned one the moment it ends.
        transform = heldTransform
    }

    /// True while the card is between two piles. Layout uses it to keep a card
    /// that is still in the air out of the ordinary stacking order, even on a
    /// pass that is not itself moving it.
    var isGliding: Bool { animation(forKey: Key.move) != nil }

    /// Ends any move in progress, leaving the card at its destination. Picking
    /// a card up out of mid-flight has to go through here, or the animation
    /// keeps overriding the position the drag is writing.
    func stopGliding() {
        removeAnimation(forKey: Key.move)
        removeAnimation(forKey: Key.turn)
        removeAnimation(forKey: Key.pickUp)
        removeAnimation(forKey: Key.liftOpacity)
        removeAnimation(forKey: Key.liftRadius)
        removeAnimation(forKey: Key.liftOffset)
    }

    /// Swells the shadow for the length of a move and sets it back down again,
    /// so a card in flight reads as travelling over the table rather than
    /// sliding along it. The resting values are the ones `updateShadow` left
    /// behind, so this composes with whatever size the card currently is.
    func lift(for duration: CFTimeInterval) {
        guard duration > 0 else { return }

        func hop(_ keyPath: String, from rest: CGFloat, to peak: CGFloat) -> CAKeyframeAnimation {
            let hop = CAKeyframeAnimation(keyPath: keyPath)
            hop.values = [rest, peak, rest]
            hop.keyTimes = [0, 0.5, 1]
            hop.duration = duration
            hop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return hop
        }

        let peak = liftedShadow
        add(hop("shadowOpacity", from: CGFloat(shadowOpacity), to: peak.opacity), forKey: Key.liftOpacity)
        add(hop("shadowRadius", from: shadowRadius, to: peak.radius), forKey: Key.liftRadius)
        add(hop("shadowOffset.height", from: shadowOffset.height, to: peak.offset),
            forKey: Key.liftOffset)
    }

    /// Turns the card over with a horizontal squeeze, swapping the artwork at
    /// the point where the card is edge-on and nothing is visible anyway.
    func flip(to faceUp: Bool, renderer: CardRenderer, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        guard isFaceUp != faceUp else { return }
        if apple {
            flipInPerspective(to: faceUp, renderer: renderer, duration: duration, completion: completion)
            return
        }
        let half = duration / 2

        let shrink = CABasicAnimation(keyPath: "transform.scale.x")
        shrink.fromValue = 1.0
        shrink.toValue = 0.02
        shrink.duration = half
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.setFace(faceUp, renderer: renderer)
            let grow = CABasicAnimation(keyPath: "transform.scale.x")
            grow.fromValue = 0.02
            grow.toValue = 1.0
            grow.duration = half
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { completion?() }
            self.setValue(1.0, forKeyPath: "transform.scale.x")
            self.add(grow, forKey: Key.flip)
            CATransaction.commit()
        }
        setValue(0.02, forKeyPath: "transform.scale.x")
        add(shrink, forKey: Key.flip)
        CATransaction.commit()
    }

    /// Turns the card over the way a hand turns one over: about its long axis,
    /// in perspective, going properly edge-on half way through.
    ///
    /// Two phases, because a card has two sides and a layer has one. The first
    /// takes it to edge-on, where it is a line and nothing can be read off it;
    /// the artwork is swapped at exactly that moment and the second phase
    /// brings it back down, continuing the same apparent direction of travel —
    /// which is why the second phase starts at +90° rather than carrying on
    /// past −90° into a mirror image of the new face.
    ///
    /// The rotation is sampled into a keyframe rather than animated as one
    /// matrix. Core Animation interpolates a `transform` component by
    /// component, and over a full quarter turn that is not a rotation at all —
    /// it is a squash through a degenerate matrix, which is exactly the flat
    /// flip this mode exists to replace.
    private func flipInPerspective(to faceUp: Bool, renderer: CardRenderer,
                                   duration: CFTimeInterval, completion: (() -> Void)?) {
        let half = duration / 2

        let rotation = restingRotation
        let scale = restingScale
        func turn(_ angle: CGFloat) -> CATransform3D { flipTransform(angle, rotation: rotation, scale: scale) }

        func phase(from: CGFloat, to: CGFloat, ease: CAMediaTimingFunctionName) -> CAKeyframeAnimation {
            let steps = 12
            let sweep = CAKeyframeAnimation(keyPath: "transform")
            sweep.values = (0...steps).map { i in
                NSValue(caTransform3D: turn(from + (to - from) * CGFloat(i) / CGFloat(steps)))
            }
            sweep.duration = half
            sweep.timingFunction = CAMediaTimingFunction(name: ease)
            sweep.fillMode = .forwards
            return sweep
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.setFace(faceUp, renderer: renderer)
            CATransaction.begin()
            CATransaction.setCompletionBlock { completion?() }
            self.transform = self.restTransform
            self.add(phase(from: .pi / 2, to: 0, ease: .easeOut), forKey: Key.flip)
            CATransaction.commit()
        }
        // Parked edge-on for the swap; the second phase puts it back.
        transform = turn(-.pi / 2)
        add(phase(from: 0, to: -.pi / 2, ease: .easeIn), forKey: Key.flip)
        CATransaction.commit()
    }

    // MARK: Moving on a card table

    /// The resting turn as it is on screen right now, mid-animation included.
    private var presentedRotation: CGFloat {
        guard animation(forKey: Key.turn) != nil || animation(forKey: Key.flip) != nil,
              let value = presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber else {
            return restingRotation
        }
        return CGFloat(value.doubleValue)
    }

    /// Sends the card to `point`, turned to `rotation`, showing `faceUp`, in
    /// one move: the slide, the turn in the plane and the flip all start after
    /// `delay` and run together, so a card dealt face down can be flying,
    /// squaring up to the table and turning over at once — which is what a
    /// dealer's hand actually does.
    ///
    /// The flip swaps the artwork at the moment the card is edge-on through a
    /// discrete keyframe on `contents`, all inside this one transaction, so
    /// `completion` really does run after everything has landed and the model
    /// (`isFaceUp`, `position`, `restingRotation`) is final the moment this
    /// returns. With `duration` zero everything is simply set.
    func move(to point: CGPoint, rotation: CGFloat, scale: CGFloat = 1, faceUp: Bool, renderer: CardRenderer,
              duration: CFTimeInterval, delay: CFTimeInterval = 0, flipDuration: CFTimeInterval = 0.24,
              timing: CAMediaTimingFunction, lift: Bool = true, completion: (() -> Void)? = nil) {
        let fromPosition = animation(forKey: Key.move) != nil ? (presentation()?.position ?? position) : position
        let fromRotation = presentedRotation
        let fromScale = restingScale
        let flipping = faceUp != isFaceUp
        let oldContents = contents

        let animated = duration > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // An instant move reports back synchronously, below, rather than
        // whenever Core Animation gets round to an empty transaction's
        // completion — a snapshot or a test has to see the result at once.
        if animated { CATransaction.setCompletionBlock { completion?() } }

        position = point
        restingRotation = rotation
        restingScale = max(0.05, scale)
        if flipping { setFace(faceUp, renderer: renderer) }
        if !isPickedUp { transform = restTransform }

        let begin = CACurrentMediaTime() + max(0, delay)
        let moved = abs(fromPosition.x - point.x) > 0.5 || abs(fromPosition.y - point.y) > 0.5

        if animated && moved {
            let slide = CABasicAnimation(keyPath: "position")
            slide.fromValue = NSValue(point: fromPosition)
            slide.toValue = NSValue(point: point)
            slide.duration = duration
            slide.timingFunction = timing
            slide.beginTime = begin
            slide.fillMode = .backwards
            add(slide, forKey: Key.move)
            if lift { liftShadow(duration: duration, beginTime: begin) }
        } else {
            removeAnimation(forKey: Key.move)
        }

        let turning = abs(fromRotation - rotation) > 0.001 || abs(fromScale - restingScale) > 0.001
        if animated && !isPickedUp && (flipping || turning) {
            // Sampled rather than interpolated as one matrix: Core Animation
            // interpolates a transform component by component, which over a
            // quarter turn is a squash, not a rotation.
            let steps = 24
            let length = flipping ? min(duration, flipDuration) : duration
            // A flip starts a little into the flight — the card leaves the
            // deck before it turns — and ends well before it lands.
            let flipStart = flipping ? max(0, (duration - length) * 0.25) : 0
            let total = max(duration, flipStart + length)
            let swapAt = flipping ? (flipStart + length / 2) / total : 2

            // Where the card is in its flip at `u` of the whole animation:
            // easing in to edge-on (−90°), then easing out from the other
            // edge (+90°) back to flat, so the second half carries on in the
            // same direction instead of showing a mirror image.
            func flipAngle(_ u: Double, side: Double) -> CGFloat {
                guard flipping else { return 0 }
                let f = max(0, min(1, (u * total - flipStart) / length))
                if side < 0 { return -(.pi / 2) * CGFloat(pow(f / 0.5, 2)) }
                return (.pi / 2) * CGFloat(pow((1 - f) / 0.5, 2))
            }
            func rotationAt(_ u: Double) -> CGFloat {
                let eased = 1 - (1 - u) * (1 - u)
                return fromRotation + (rotation - fromRotation) * CGFloat(eased)
            }
            let toScale = restingScale
            func scaleAt(_ u: Double) -> CGFloat {
                let eased = 1 - (1 - u) * (1 - u)
                return fromScale + (toScale - fromScale) * CGFloat(eased)
            }
            var samples: [(time: Double, flip: CGFloat)] = []
            for i in 0...steps {
                let u = Double(i) / Double(steps)
                guard abs(u - swapAt) > 0.0001 else { continue }
                samples.append((u, flipAngle(u, side: u < swapAt ? -1 : 1)))
            }
            if flipping {
                samples.append((swapAt, -.pi / 2))
                samples.append((swapAt, .pi / 2))
                samples.sort { $0.time < $1.time || ($0.time == $1.time && $0.flip < $1.flip) }
            }
            let values = samples.map {
                NSValue(caTransform3D: flipTransform($0.flip, rotation: rotationAt($0.time), scale: scaleAt($0.time)))
            }
            let times = samples.map { NSNumber(value: $0.time) }
            let sweep = CAKeyframeAnimation(keyPath: "transform")
            sweep.values = values
            sweep.keyTimes = times
            sweep.duration = total
            sweep.beginTime = begin
            sweep.fillMode = .backwards
            add(sweep, forKey: Key.turn)
            removeAnimation(forKey: Key.flip)

            if flipping, let oldContents {
                // The picture changes exactly when the card is edge-on.
                let swap = CAKeyframeAnimation(keyPath: "contents")
                swap.values = [oldContents, contents as Any]
                swap.keyTimes = [0, NSNumber(value: swapAt), 1]
                swap.calculationMode = .discrete
                swap.duration = total
                swap.beginTime = begin
                swap.fillMode = .backwards
                add(swap, forKey: Key.flip)
            }
        } else if !animated {
            removeAnimation(forKey: Key.turn)
            removeAnimation(forKey: Key.flip)
            removeAnimation(forKey: Key.liftOpacity)
            removeAnimation(forKey: Key.liftRadius)
            removeAnimation(forKey: Key.liftOffset)
        }
        CATransaction.commit()
        if !animated { completion?() }
    }

    /// `lift(for:)` with a start time, for a move that waits its turn.
    private func liftShadow(duration: CFTimeInterval, beginTime: CFTimeInterval) {
        func hop(_ keyPath: String, from rest: CGFloat, to peak: CGFloat) -> CAKeyframeAnimation {
            let hop = CAKeyframeAnimation(keyPath: keyPath)
            hop.values = [rest, peak, rest]
            hop.keyTimes = [0, 0.5, 1]
            hop.duration = duration
            hop.beginTime = beginTime
            hop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return hop
        }
        let peak = liftedShadow
        add(hop("shadowOpacity", from: CGFloat(shadowOpacity), to: peak.opacity), forKey: Key.liftOpacity)
        add(hop("shadowRadius", from: shadowRadius, to: peak.radius), forKey: Key.liftRadius)
        add(hop("shadowOffset.height", from: shadowOffset.height, to: peak.offset), forKey: Key.liftOffset)
    }

    /// Turns the card to `rotation` where it lies, without moving it.
    func setRestingRotation(_ rotation: CGFloat, renderer: CardRenderer, duration: CFTimeInterval,
                            timing: CAMediaTimingFunction) {
        move(to: position, rotation: rotation, scale: restingScale, faceUp: isFaceUp, renderer: renderer,
             duration: duration, timing: timing, lift: false)
    }

    /// The card's corners as they lie on the table, for hit testing: `point`
    /// in the superlayer's coordinates is on the card if, turned back by the
    /// resting angle about the card's centre, it falls inside the bounds.
    func restingContains(_ point: CGPoint, at center: CGPoint? = nil) -> Bool {
        let c = center ?? position
        let dx = point.x - c.x, dy = point.y - c.y
        let cosA = cos(-restingRotation), sinA = sin(-restingRotation)
        let x = dx * cosA - dy * sinA
        let y = dx * sinA + dy * cosA
        return abs(x) <= bounds.width * restingScale / 2 && abs(y) <= bounds.height * restingScale / 2
    }
}
