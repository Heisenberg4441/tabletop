//
//  Design.swift
//  The chrome's vocabulary: type, colour, space, depth, motion and touch.
//
//  `AppleStyle` is the surface — felt, wood, printed stock. This file is the
//  other layer, the modern macOS one that floats over it: the glass panels,
//  the capsule buttons, the labels, the seats. Every control in `Kit/Controls`
//  and `Kit/Seats` is built from these tokens and nothing else, and a game
//  that needs a label or a colour of its own should reach here first, so that
//  five games written by five hands still read as one app.
//
//  The rules the tokens encode, in one place:
//
//  * SF Pro for words, SF Pro Rounded for numbers that stand alone — a chip's
//    value, a bet, a hand total — and monospaced digits for any number that
//    changes while the player watches it, so a counter ticking from 9 to 10
//    does not shuffle the words around it.
//  * White on the felt, at a handful of fixed strengths, and exactly one
//    accent: the warm gold of the hint, which means "look here" and nothing
//    else. The primary action is porcelain — a near-white capsule with dark
//    type — because it is the one colour that reads as "the button" on every
//    cloth the player can pick: a blue primary disappears into blue felt, a
//    green one into green.
//  * One light, from above-left, even here: shadows fall down and a little
//    right, highlights sit on top edges.
//  * Motion settles and stops. Springs are critically damped — they arrive,
//    they do not bounce — and every animation in the kit goes through
//    `Motion.isEnabled`, which is false under Reduce Motion and while a
//    snapshot is being taken.
//

import AppKit
import CoreText

// MARK: - Typography

/// The type scale. Sizes are points; SF Pro switches to its Display cut on
/// its own from 20 points up, which is the whole reason there is no separate
/// "display" family here.
enum Typography {

    /// The library's "Tabletop". 34 pt bold.
    static var largeTitle: NSFont { .systemFont(ofSize: 34, weight: .bold) }
    /// A banner's result line, an options card's heading. 24 pt semibold.
    static var title: NSFont { .systemFont(ofSize: 24, weight: .semibold) }
    /// A tile's name, a panel's heading. 17 pt semibold.
    static var title2: NSFont { .systemFont(ofSize: 17, weight: .semibold) }
    /// Button titles, seat names, row labels. 13 pt semibold.
    static var headline: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    /// Running text. 13 pt regular.
    static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    /// A second line under a heading. 12 pt regular.
    static var callout: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    /// Small print: a players line, a status pill. 11 pt medium.
    static var caption: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// Small capitals over a group — "FEATURED", "ALL GAMES". Use with
    /// `eyebrowKern` and an uppercased string.
    static var eyebrow: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    static let eyebrowKern: CGFloat = 0.9

    /// SF Pro Rounded at `size`: chip values, bet amounts, hand totals — the
    /// numbers that are objects in their own right rather than part of a
    /// sentence.
    static func rounded(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// A number that changes while the player watches: SF Pro Rounded with
    /// every digit the same width, so "1,111" and "8,888" take the same room
    /// and a ticking counter never jostles its neighbours.
    static func number(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        monospacedDigits(rounded(size, weight: weight))
    }

    /// Any font with its digits made tabular.
    static func monospacedDigits(_ font: NSFont) -> NSFont {
        let settings: [[NSFontDescriptor.FeatureKey: Int]] = [[
            .typeIdentifier: kNumberSpacingType,
            .selectorIdentifier: kMonospacedNumbersSelector,
        ]]
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: settings])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Attributes for a string drawn by hand (`NSAttributedString.draw`), with
    /// the kerning an eyebrow wants when `kern` is given.
    static func attributes(_ font: NSFont, _ color: NSColor, kern: CGFloat = 0,
                           alignment: NSTextAlignment = .natural) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ]
        if kern != 0 { attributes[.kern] = kern }
        return attributes
    }

    /// How wide a one-line label has to be to show all of its text.
    ///
    /// `intrinsicContentSize` is the text's typographic width, and a label
    /// framed to exactly that truncates its last few letters — the field's
    /// cell draws with a little inset of its own. Every compact piece of
    /// chrome that sizes itself round a label (a pill, a toast) sizes it with
    /// this instead.
    static func fittingWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.intrinsicContentSize.width) + 6
    }

    /// A non-editable label in the house style: no bezel, no background, one
    /// line, truncating. The workhorse for every piece of text on a table.
    static func label(_ string: String = "", font: NSFont = body,
                      color: NSColor = Palette.textPrimary) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        label.isBordered = false
        return label
    }
}

// MARK: - Palette

/// Every colour the chrome uses. The table's own colours — the cloth, the
/// card inks — belong to `Theme`; nothing here changes with the View menu.
enum Palette {

    // Text and glyphs on felt or glass. White at fixed strengths: the same
    // four on every cloth, so hierarchy never depends on which one the
    // player chose.
    static let textPrimary = NSColor(white: 1, alpha: 0.96)
    static let textSecondary = NSColor(white: 1, alpha: 0.70)
    static let textTertiary = NSColor(white: 1, alpha: 0.48)
    static let textQuaternary = NSColor(white: 1, alpha: 0.28)

    /// Hairlines and dividers on glass or felt.
    static let separator = NSColor(white: 1, alpha: 0.14)
    /// A quiet fill for a control sitting on glass: a track, an unselected
    /// segment, a secondary button inside a panel.
    static let fillQuiet = NSColor(white: 1, alpha: 0.12)
    static let fillQuietHover = NSColor(white: 1, alpha: 0.18)
    static let fillQuietPressed = NSColor(white: 1, alpha: 0.08)

    /// "Look here." The warm gold of the hint glow, the drop outline, the
    /// active seat's thinking sweep, the winner's halo. The only accent in
    /// the app — used for anything else, it stops meaning anything.
    static let accent = NSColor(srgbRed: 0.980, green: 0.812, blue: 0.392, alpha: 1)
    /// The same gold, paler, for text and thin lines where the full strength
    /// would glare.
    static let accentSoft = NSColor(srgbRed: 1.000, green: 0.898, blue: 0.655, alpha: 1)

    /// The primary action: porcelain, with near-black type on it.
    static let primaryFill = NSColor(srgbRed: 0.965, green: 0.961, blue: 0.949, alpha: 1)
    static let primaryFillHover = NSColor(white: 1, alpha: 1)
    static let primaryFillPressed = NSColor(srgbRed: 0.84, green: 0.835, blue: 0.82, alpha: 1)
    static let primaryLabel = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1)

    /// Leaving, resigning, discarding progress. Said in the words' colour, not
    /// with a slab of red: a destructive button in a bar or a panel is a
    /// quiet capsule with `destructiveText` on it, so it never outshouts the
    /// porcelain primary beside it (Apple's rule — the prominent button is
    /// never the one that loses something).
    static let destructiveText = NSColor(srgbRed: 1.000, green: 0.560, blue: 0.520, alpha: 1)
    /// The filled red, for the last step of a confirmation only ("Leave the
    /// table? · Leave") — `CapsuleButton.Style.destructiveProminent`. A deep,
    /// calm red: it should make the player read the word, not flinch.
    static let destructiveFill = NSColor(srgbRed: 0.620, green: 0.200, blue: 0.190, alpha: 1)
    static let destructiveFillHover = NSColor(srgbRed: 0.680, green: 0.228, blue: 0.214, alpha: 1)

    /// A result going the player's way, and the other way. Pale, like the
    /// solitaire score floats and for the same reason: a mid-tone green or
    /// red laid over dark cloth turns to mud; lightness carries the reading.
    static let positive = NSColor(srgbRed: 0.720, green: 0.960, blue: 0.780, alpha: 1)
    static let negative = NSColor(srgbRed: 1.000, green: 0.706, blue: 0.667, alpha: 1)

    /// The room every table stands in, behind the library and around the
    /// oval and half-moon tables.
    static let room = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.060, alpha: 1)

    /// A darkening laid over a table while a card or panel asks for the
    /// player's full attention.
    static let scrim = NSColor(white: 0, alpha: 0.38)
}

// MARK: - Space and shape

/// Spacing, on a four-point grid. Generous is the house style: when in
/// doubt, take the next step up.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

/// Corner radii. Every rounded rectangle in the chrome uses one of these,
/// with continuous (squircle) corners.
enum Radius {
    /// Segments, small tags.
    static let small: CGFloat = 8
    /// Library tiles' inner elements, text fields.
    static let medium: CGFloat = 12
    /// Library tiles, thumbnails.
    static let large: CGFloat = 18
    /// Glass panels: the options card, a banner.
    static let panel: CGFloat = 26
}

/// Heights of the standard controls, so a button in a game and a button in
/// the kit line up.
enum ControlHeight {
    static let small: CGFloat = 28
    static let regular: CGFloat = 34
    static let large: CGFloat = 44
}

// MARK: - Depth

/// Shadows for things that float over the table. All fall straight down —
/// the light is above — and a little to the right of nothing: a horizontal
/// offset on a floating panel reads as a mistake, not as a lamp.
struct Elevation {
    var opacity: Float
    var radius: CGFloat
    var offset: CGFloat

    /// A card, a chip, a seat's avatar lying on the cloth.
    static let resting = Elevation(opacity: 0.30, radius: 3, offset: 1.5)
    /// A button, a pill.
    static let raised = Elevation(opacity: 0.28, radius: 8, offset: 3)
    /// A panel, a bar, a banner: glass floating well clear of the table.
    static let floating = Elevation(opacity: 0.34, radius: 22, offset: 10)

    /// Writes the shadow into `layer`, with `path` as its shadow path when
    /// given — which it should be for anything that moves: without one Core
    /// Animation renders the shadow off-screen on every frame.
    func apply(to layer: CALayer, path: CGPath? = nil) {
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: -offset)   // layer space is y-up for plain views
        layer.shadowPath = path
    }

    /// The same, for a layer whose geometry is flipped (y grows downward).
    func apply(toFlipped layer: CALayer, path: CGPath? = nil) {
        apply(to: layer, path: path)
        layer.shadowOffset = CGSize(width: 0, height: offset)
    }
}

// MARK: - Continuous corners

/// Rounded rectangles with continuous corners — the squircle every Apple
/// surface has used since iOS 7, where the curvature eases into the straight
/// edge instead of starting abruptly. The difference is small and it is the
/// whole difference between a shape that looks drawn by Apple and one that
/// looks drawn by a toolkit.
///
/// Layers get the same shape from `cornerCurve = .continuous`; this is for
/// Core Graphics — icons, drawn glass, chips' labels.
enum ContinuousShape {

    /// A rounded rectangle with continuous corners. `radius` is the nominal
    /// radius, as in a design tool; the curve starts about 1.53 radii from
    /// each corner. A radius of at least half the short side is a capsule.
    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        // Past this the continuous curves would overlap; a capsule is what
        // was meant, and a capsule's ends are true semicircles.
        if radius >= limit / 1.528665 * 0.999 && radius * 1.528665 >= limit {
            return CGPath(roundedRect: rect, cornerWidth: limit, cornerHeight: limit, transform: nil)
        }
        let r = max(0, radius)
        let p = CGMutablePath()
        let minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY

        // The constants are the ones UIKit's continuous rounded rect uses,
        // measured in units of the radius from each corner.
        let a: CGFloat = 1.528665, b: CGFloat = 1.088493, c: CGFloat = 0.868407
        let d: CGFloat = 0.631494, e: CGFloat = 0.074911, f: CGFloat = 0.372824, g: CGFloat = 0.169060

        p.move(to: CGPoint(x: minX + a * r, y: minY))
        // Top edge, top-right corner.
        p.addLine(to: CGPoint(x: maxX - a * r, y: minY))
        p.addCurve(to: CGPoint(x: maxX - d * r, y: minY + e * r),
                   control1: CGPoint(x: maxX - b * r, y: minY), control2: CGPoint(x: maxX - c * r, y: minY))
        p.addCurve(to: CGPoint(x: maxX - e * r, y: minY + d * r),
                   control1: CGPoint(x: maxX - f * r, y: minY + g * r), control2: CGPoint(x: maxX - g * r, y: minY + f * r))
        p.addCurve(to: CGPoint(x: maxX, y: minY + a * r),
                   control1: CGPoint(x: maxX, y: minY + c * r), control2: CGPoint(x: maxX, y: minY + b * r))
        // Right edge, bottom-right corner.
        p.addLine(to: CGPoint(x: maxX, y: maxY - a * r))
        p.addCurve(to: CGPoint(x: maxX - e * r, y: maxY - d * r),
                   control1: CGPoint(x: maxX, y: maxY - b * r), control2: CGPoint(x: maxX, y: maxY - c * r))
        p.addCurve(to: CGPoint(x: maxX - d * r, y: maxY - e * r),
                   control1: CGPoint(x: maxX - g * r, y: maxY - f * r), control2: CGPoint(x: maxX - f * r, y: maxY - g * r))
        p.addCurve(to: CGPoint(x: maxX - a * r, y: maxY),
                   control1: CGPoint(x: maxX - c * r, y: maxY), control2: CGPoint(x: maxX - b * r, y: maxY))
        // Bottom edge, bottom-left corner.
        p.addLine(to: CGPoint(x: minX + a * r, y: maxY))
        p.addCurve(to: CGPoint(x: minX + d * r, y: maxY - e * r),
                   control1: CGPoint(x: minX + b * r, y: maxY), control2: CGPoint(x: minX + c * r, y: maxY))
        p.addCurve(to: CGPoint(x: minX + e * r, y: maxY - d * r),
                   control1: CGPoint(x: minX + f * r, y: maxY - g * r), control2: CGPoint(x: minX + g * r, y: maxY - f * r))
        p.addCurve(to: CGPoint(x: minX, y: maxY - a * r),
                   control1: CGPoint(x: minX, y: maxY - c * r), control2: CGPoint(x: minX, y: maxY - b * r))
        // Left edge, top-left corner.
        p.addLine(to: CGPoint(x: minX, y: minY + a * r))
        p.addCurve(to: CGPoint(x: minX + e * r, y: minY + d * r),
                   control1: CGPoint(x: minX, y: minY + b * r), control2: CGPoint(x: minX, y: minY + c * r))
        p.addCurve(to: CGPoint(x: minX + d * r, y: minY + e * r),
                   control1: CGPoint(x: minX + g * r, y: minY + f * r), control2: CGPoint(x: minX + f * r, y: minY + g * r))
        p.addCurve(to: CGPoint(x: minX + a * r, y: minY),
                   control1: CGPoint(x: minX + c * r, y: minY), control2: CGPoint(x: minX + b * r, y: minY))
        p.closeSubpath()
        return p
    }

    /// A capsule: a rounded rectangle whose ends are semicircles.
    static func capsule(_ rect: CGRect) -> CGPath {
        let r = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

// MARK: - Motion

/// Durations, springs, and the one switch every animation in the app obeys.
///
/// The constants are plain values usable anywhere; the functions that touch
/// layers and views are main-actor, like the rest of AppKit.
enum Motion {

    /// False under Reduce Motion, while a snapshot is being taken, and
    /// whenever a test has forced it off. Check it before adding any
    /// animation at all; when it is false, set the final state directly.
    @MainActor static var isEnabled: Bool { TabletopEnvironment.animationsEnabled }

    // MARK: Durations, in seconds

    /// A hover, a press, a highlight fading in.
    static let quick: CFTimeInterval = 0.14
    /// A panel appearing, a bar swapping its buttons.
    static let standard: CFTimeInterval = 0.26
    /// A result banner arriving; the library's screen change.
    static let relaxed: CFTimeInterval = 0.42
    /// One card sliding across the table.
    static let cardMove: CFTimeInterval = 0.30
    /// One card turning over.
    static let cardFlip: CFTimeInterval = 0.24
    /// Time between two cards of a deal leaving the deck.
    static let dealStagger: CFTimeInterval = 0.085
    /// Chips sliding into a pot or out to a winner.
    static let chipFlight: CFTimeInterval = 0.46

    /// Leaves briskly, arrives softly — the curve every card move uses.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.24, 1.0)
    /// For things leaving the screen: gathers speed and goes.
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.5, 0.0, 0.9, 0.5)
    static let easeInOut = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.25, 1.0)

    // MARK: Springs

    /// A spring described the way a designer thinks about it: how long it
    /// takes to settle, and how much it may overshoot (zero here, always).
    /// Stiffness and damping are derived, critically damped, so "settles
    /// without wobble" is a property of the type rather than of every call
    /// site remembering the right numbers.
    struct Spring {
        let stiffness: CGFloat
        let damping: CGFloat
        let mass: CGFloat = 1

        /// Critically damped — the fastest approach that never overshoots.
        init(stiffness: CGFloat) {
            self.stiffness = stiffness
            self.damping = 2 * stiffness.squareRoot()
        }

        /// Hover and press: tight, over in about a quarter of a second.
        static let snappy = Spring(stiffness: 420)
        /// Panels, bars, cards settling into a hand.
        static let smooth = Spring(stiffness: 240)
        /// A banner or an options card arriving: unhurried.
        static let gentle = Spring(stiffness: 140)
    }

    /// A spring animation of `keyPath` from `from` to `to`, lasting exactly
    /// as long as the spring takes to settle.
    static func spring(_ keyPath: String, from: Any?, to: Any?, spring: Spring = .smooth) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = spring.mass
        animation.stiffness = spring.stiffness
        animation.damping = spring.damping
        animation.initialVelocity = 0
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    /// Sets `keyPath` on `layer` to `value`, springing there from wherever it
    /// is on screen right now — or simply setting it when motion is off.
    /// Implicit actions are suppressed either way.
    @MainActor
    static func spring(_ layer: CALayer, _ keyPath: String, to value: Any, spring: Spring = .smooth) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        if isEnabled {
            layer.add(Motion.spring(keyPath, from: from, to: value, spring: spring), forKey: "motion." + keyPath)
        } else {
            layer.removeAnimation(forKey: "motion." + keyPath)
        }
        CATransaction.commit()
    }

    /// Runs `changes` inside an AppKit animation group — `view.animator()`
    /// changes and constraint changes with implicit animation allowed — or
    /// straight away when motion is off. `completion` runs either way.
    @MainActor
    static func animate(duration: CFTimeInterval = standard, timing: CAMediaTimingFunction = easeOut,
                        _ changes: () -> Void, completion: (() -> Void)? = nil) {
        guard isEnabled else {
            changes()
            completion?()
            return
        }
        let finished = MainThreadBox(completion)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = timing
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: {
            MainActor.assumeIsolated { finished.value?() }
        })
    }

    /// A transform that scales a layer-backed view's layer about its centre
    /// (AppKit anchors a view's layer at its corner, not its middle).
    static func scale(_ s: CGFloat, about bounds: CGRect, dy: CGFloat = 0) -> CATransform3D {
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY + dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    /// Brings a floating view in: from transparent, a hair small and a few
    /// points low, springing to rest. The way every panel, banner and toast
    /// in the kit arrives. Under Reduce Motion it simply appears.
    ///
    /// Safe on a view that was dismissed before — the same options card shown
    /// for every new game: whatever is left of an earlier `dismiss` (a fade
    /// still running, or one that finished and was held at zero) is taken off
    /// first, so it can never sit over the new arrival and keep the view
    /// invisible while it is up and taking the keyboard.
    @MainActor
    static func present(_ view: NSView, spring: Spring = .gentle, from scale: CGFloat = 0.96, rise: CGFloat = 8) {
        view.isHidden = false
        view.alphaValue = 1
        if let layer = view.layer { clearDismissal(from: layer) }
        guard isEnabled, let layer = view.layer else { return }
        let start = Motion.scale(scale, about: view.bounds, dy: view.isFlipped ? rise : -rise)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(Motion.spring("transform", from: NSValue(caTransform3D: start),
                                to: NSValue(caTransform3D: CATransform3DIdentity), spring: spring),
                  forKey: "motion.present.transform")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = standard
        fade.timingFunction = easeOut
        layer.add(fade, forKey: "motion.present.opacity")
        CATransaction.commit()
    }

    /// Takes a floating view away: a quick fade and a slight shrink, then
    /// `completion` (which usually removes it). Immediate under Reduce Motion.
    ///
    /// When it is over the view is left transparent in its model (alpha 0)
    /// with no animation attached, so presenting it again — or simply setting
    /// its alpha back — is all it takes to bring it back.
    ///
    /// A `present` of the same view before the fade has finished cancels the
    /// dismissal outright: the fade is taken off and `completion` never runs,
    /// so a banner shown again at once is not removed from under the player
    /// by the tail of its previous exit.
    @MainActor
    static func dismiss(_ view: NSView, completion: (() -> Void)? = nil) {
        guard isEnabled, let layer = view.layer, !view.isHidden else {
            view.alphaValue = 0
            if let layer = view.layer { clearDismissal(from: layer) }
            completion?()
            return
        }
        layer.removeAnimation(forKey: "motion.present.transform")
        layer.removeAnimation(forKey: "motion.present.opacity")
        dismissalCounter &+= 1
        let token = dismissalCounter
        layer.setValue(token, forKey: dismissalTokenKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak view] in
            MainActor.assumeIsolated {
                // Superseded by a `present`: the view is back, leave it be.
                guard let view, let layer = view.layer,
                      (layer.value(forKey: dismissalTokenKey) as? Int) == token else { return }
                // The fade held its last frame until now; hand the end state
                // to the model and let go of the animations, so nothing
                // lingers on the layer to fight a later `present`.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                view.alphaValue = 0
                layer.opacity = 0
                layer.transform = CATransform3DIdentity
                clearDismissal(from: layer)
                CATransaction.commit()
                completion?()
            }
        }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: Motion.scale(0.97, about: view.bounds))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        for animation in [shrink, fade] {
            animation.duration = quick * 1.2
            animation.timingFunction = easeIn
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(shrink, forKey: "motion.dismiss.transform")
        layer.add(fade, forKey: "motion.dismiss.opacity")
        CATransaction.commit()
    }

    /// Removes what `dismiss` attaches to a layer, cancelling a dismissal
    /// still under way.
    @MainActor
    private static func clearDismissal(from layer: CALayer) {
        layer.setValue(nil, forKey: dismissalTokenKey)
        layer.removeAnimation(forKey: "motion.dismiss.transform")
        layer.removeAnimation(forKey: "motion.dismiss.opacity")
    }

    @MainActor private static var dismissalCounter = 0
    private static let dismissalTokenKey = "motion.dismissal"
}

// MARK: - Haptics

/// A light touch through a Force Touch trackpad — for a card snapping onto a
/// valid pile mid-drag, a slider crossing a preset. Felt, never heard; this
/// app makes no interface sounds. Does nothing on a mouse, in the harness, or
/// while motion is off (a player who asked for less motion asked for less of
/// everything that moves on its own).
@MainActor
enum Haptics {

    /// Something lined up: a drag found a place to land, a slider hit a
    /// preset.
    static func alignment() { perform(.alignment) }

    /// A value stepped: the bet went up a chip, a segment was chosen.
    static func levelChange() { perform(.levelChange) }

    /// Anything else worth a touch.
    static func generic() { perform(.generic) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard !TabletopEnvironment.isHarness, Motion.isEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

// MARK: - Plumbing

/// Carries a main-thread-only value through an API that insists on a
/// `@Sendable` closure — an AppKit completion handler, a dispatch block —
/// when the caller knows the closure runs on the main thread anyway. Read
/// `value` only inside `MainActor.assumeIsolated`.
struct MainThreadBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
