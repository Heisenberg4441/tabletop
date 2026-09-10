//
//  CardLayer.swift
//  One layer per card, moved around by the compositor.
//

import AppKit
import QuartzCore

final class CardLayer: CALayer {

    private enum Key {
        static let move = "move"
        static let liftOpacity = "liftOpacity"
        static let liftRadius = "liftRadius"
        static let liftOffset = "liftOffset"
        static let pickUp = "pickUp"
        static let spin = "spin"
    }

    /// How much larger a card is drawn while the player is holding it. Enough
    /// to separate it from the pile it came off, not enough to misjudge where
    /// it will land — the hit testing uses `bounds`, which this does not touch.
    private static let heldScale: CGFloat = 1.05

    let card: Card
    private(set) var isFaceUp: Bool = false
    /// True while the player is dragging this card, so layout leaves it alone.
    var isHeld = false

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
        self.card = (layer as? CardLayer)?.card ?? Card(code: 0)
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

    func updateShadow(cornerRadius: CGFloat, lifted: Bool) {
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                            cornerHeight: cornerRadius, transform: nil)
        shadowOpacity = lifted ? 0.45 : 0.28
        shadowRadius = lifted ? bounds.width * 0.09 : max(2, bounds.width * 0.028)
        shadowOffset = CGSize(width: 0, height: lifted ? bounds.width * 0.05 : max(1, bounds.width * 0.012))
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

    /// True while the card is between two piles. Layout uses it to keep a card
    /// that is still in the air out of the ordinary stacking order, even on a
    /// pass that is not itself moving it.
    var isGliding: Bool { animation(forKey: Key.move) != nil }

    /// Ends any move in progress, leaving the card at its destination. Picking
    /// a card up out of mid-flight has to go through here, or the animation
    /// keeps overriding the position the drag is writing.
    func stopGliding() {
        removeAnimation(forKey: Key.move)
        removeAnimation(forKey: Key.pickUp)
        removeAnimation(forKey: Key.liftOpacity)
        removeAnimation(forKey: Key.liftRadius)
        removeAnimation(forKey: Key.liftOffset)
        removeAnimation(forKey: Key.spin)
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

        add(hop("shadowOpacity", from: CGFloat(shadowOpacity), to: 0.45), forKey: Key.liftOpacity)
        add(hop("shadowRadius", from: shadowRadius, to: bounds.width * 0.09), forKey: Key.liftRadius)
        add(hop("shadowOffset.height", from: shadowOffset.height, to: bounds.width * 0.05),
            forKey: Key.liftOffset)
    }

    /// Sends the card round once on its way across the table — brainrot mode's
    /// contribution to the compositor.
    ///
    /// Only ever asked for on a card that is not also turning over: `flip`
    /// drives `transform.scale.x` and this drives `transform.rotation.z`, and
    /// two animations writing different parts of one transform is a fight with
    /// no winner. `BoardView` is where both decisions are made, so that is
    /// where the choice between them is.
    func spin(for duration: CFTimeInterval) {
        guard duration > 0 else { return }
        let roll = CABasicAnimation(keyPath: "transform.rotation.z")
        roll.fromValue = 0
        roll.toValue = 2 * CGFloat.pi
        roll.duration = duration
        roll.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.3, 1)
        add(roll, forKey: Key.spin)
    }

    /// Turns the card over with a horizontal squeeze, swapping the artwork at
    /// the point where the card is edge-on and nothing is visible anyway.
    func flip(to faceUp: Bool, renderer: CardRenderer, duration: CFTimeInterval, completion: (() -> Void)? = nil) {
        guard isFaceUp != faceUp else { return }
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
            self.add(grow, forKey: "flip")
            CATransaction.commit()
        }
        setValue(0.02, forKeyPath: "transform.scale.x")
        add(shrink, forKey: "flip")
        CATransaction.commit()
    }
}
