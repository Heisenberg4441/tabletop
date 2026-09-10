//
//  Brainrot.swift
//  Brainrot mode: the setting where the game stops respecting the player.
//
//  Every other effect in this app is calibrated — the score float is pale so it
//  does not shout, the landing burst is small because a tableau move is
//  housekeeping. This file is the opposite by design. A card landing sets off a
//  fireball, a shockwave, eight radial rays, a screen shake, a caption, and — if
//  the player is on a run — a firework and a fall of confetti. It is deliberately
//  too much, it is off by default, and it is one file so that it can be deleted
//  in one move if it ever stops being funny.
//
//  Two rules are kept even here, because they are not about taste:
//
//  * Reduce Motion turns the whole thing off. The board asks before calling in,
//    the same way it does for every other animation.
//  * The layer count is capped. A move every 75ms during auto-finish, with a
//    hundred layers per move and nothing sweeping them, would put the window
//    into the ground; `sweep` on the way in is what keeps it playable.
//
//  No sound. Not an oversight: this app ships muted and stays that way.
//

import AppKit
import QuartzCore

final class BrainrotShow {

    /// Everything the show needs to know about the board it is drawing on.
    /// Passed per call rather than held, because the card size and the bounds
    /// change under it whenever the window is resized.
    struct Context {
        var root: CALayer
        var bounds: CGRect
        var cardWidth: CGFloat
        var contentsScale: CGFloat
        var theme: Theme
    }

    private struct Live {
        let layers: [CALayer]
        let expires: CFTimeInterval
    }

    /// Neon, because the tasteful palette in `Theme` is exactly what this mode
    /// is not. Pure hues at full saturation read as "arcade" against every one
    /// of the four felts, and white is in the list so the hottest part of a
    /// fireball has somewhere to go.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.16, blue: 0.53, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.95, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.55, green: 1.00, blue: 0.18, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.86, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.44, blue: 0.05, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.31, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.55, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]

    /// Captions. Short enough to read in the third of a second one is on
    /// screen, and deliberately with nothing to do with solitaire.
    private static let hype = [
        "BOOM", "SHEESH", "NO CAP", "W", "GOATED", "SIGMA MOVE", "LET HIM COOK",
        "SKIBIDI", "GYATT", "+100 RIZZ", "MOGGED", "BUSSIN", "FANUM TAX",
        "OHIO MOVE", "DELULU", "CARD GO BRRR", "CHAT IS THIS REAL", "MEWING",
        "IT'S GIVING ACE", "CERTIFIED HOOD CLASSIC", "RATIO", "TOUCH GRASS",
    ]
    private static let hypeEmoji = ["🔥", "💀", "😭", "💯", "🗿", "🤯", "⚡", "🎉", "🤑", "😳"]
    private static let confettiEmoji = ["🔥", "💀", "💯", "🎉", "🤑", "🗿", "⭐️", "😭"]

    /// The ceiling, in layers rather than in bursts: the pieces here range from
    /// a single caption to a forty-piece firework, so counting bursts would
    /// either starve the small ones or let the big ones through. When the board
    /// is over the line the oldest effects are dropped until it is back under.
    /// Not private: the play-test holds the mode to it over thousands of moves.
    static let layerCeiling = 420

    /// Everything above the cards, below the player's hand. The bands are the
    /// same idea as `SparkBurstPool.zPosition`, just noisier: debris, then
    /// captions over the debris, then the screen flash over everything.
    private enum Z {
        /// Below the cards, unlike everything else here: the wash is the room.
        static let vignette: CGFloat = 1250
        static let debris: CGFloat = 1300
        static let caption: CGFloat = 1450
        static let flash: CGFloat = 1500
    }

    private var live: [Live] = []
    private var rng = DeterministicRNG(seed: 0x8BADF00D)

    /// The two layers that stay on the board for as long as the mode is on,
    /// rather than being thrown and swept like everything else: a wash of
    /// colour over the felt that steps hue on every beat, and an edge glow that
    /// closes in as the combo climbs. Everything else here is an event; these
    /// two are the room the events happen in.
    private let wash = CALayer()
    private let vignette = CAGradientLayer()
    private var beat = 0

    /// Consecutive moves, and when the last one happened. The combo is what
    /// makes the mode escalate instead of being uniformly loud: the first move
    /// of a session gets a fireball, the tenth in a row gets the works.
    private(set) var combo = 0
    private var lastMove: CFTimeInterval = 0
    private var lastNag: CFTimeInterval = 0
    /// Long enough to cross the board and think, short enough that a run has
    /// to actually be a run.
    private static let comboWindow: CFTimeInterval = 4.0

    // MARK: Entry points

    /// One move's worth of nonsense, `delay` seconds from now — the board hands
    /// over the same landing delay the sparks use, so all of it goes off at the
    /// moment the card touches down rather than when it sets off.
    func celebrate(at point: CGPoint, foundation: Bool, delay: CFTimeInterval, in ctx: Context) {
        let now = CACurrentMediaTime()
        combo = (now - lastMove) < Self.comboWindow ? combo + 1 : 1
        lastMove = now
        sweep(force: false)

        // Escalation. Every step is one more thing happening at once, which is
        // the whole joke: the mode does not get better, it gets more.
        let heat = min(combo, 14)
        let big = foundation || heat >= 6

        explosion(at: point, big: big, delay: delay, in: ctx)
        rays(at: point, count: big ? 10 : 7, delay: delay, in: ctx)
        shake(magnitude: (big ? 7 : 4) + CGFloat(heat) * 0.6,
              punch: big ? 0.035 : 0.02, delay: delay, in: ctx)

        if foundation || heat >= 1 {
            caption(Self.hype[rng.next(upperBound: Self.hype.count)]
                        + " " + Self.hypeEmoji[rng.next(upperBound: Self.hypeEmoji.count)],
                    at: CGPoint(x: point.x, y: point.y - ctx.cardWidth * 0.55),
                    size: ctx.cardWidth * (big ? 0.42 : 0.30), delay: delay, in: ctx)
        }
        if heat >= 3 {
            caption("COMBO ×\(combo)" + String(repeating: "🔥", count: min(3, heat / 3)),
                    at: CGPoint(x: ctx.bounds.midX, y: ctx.bounds.minY + ctx.cardWidth * 0.55),
                    size: ctx.cardWidth * (0.34 + CGFloat(heat) * 0.02), delay: delay, in: ctx)
        }
        if foundation || heat >= 5 { firework(delay: delay + 0.04, in: ctx) }
        if (foundation && heat >= 3) || heat >= 8 { confetti(delay: delay, in: ctx) }
        if (foundation && heat >= 6) || heat >= 12 { flash(delay: delay, in: ctx) }
    }

    /// A new deal, greeted the way this mode greets everything.
    func kickoff(in ctx: Context) {
        let middle = CGPoint(x: ctx.bounds.midX, y: ctx.bounds.midY)
        explosion(at: middle, big: true, delay: 0, in: ctx)
        confetti(delay: 0.05, in: ctx)
        caption("NEW GAME LESGO 🔥", at: middle, size: ctx.cardWidth * 0.62,
                delay: 0.05, lifetime: 1.1, in: ctx)
        shake(magnitude: 8, punch: 0.04, delay: 0, in: ctx)
    }

    /// Nags the player for sitting still. Called from the board's beat, and
    /// rate-limited in here rather than at the call site because the thing
    /// being limited is a property of the run, not of the timer.
    func idleNag(in ctx: Context) {
        guard lastMove > 0 else { return }
        let idle = CACurrentMediaTime() - lastMove
        guard idle > 6, CACurrentMediaTime() - lastNag > 5 else { return }
        lastNag = CACurrentMediaTime()
        let nags = ["MOVE 😤", "CHAT HE'S FROZEN", "ARE YOU MEWING", "TAP SOMETHING 💀",
                    "THINKING? IN 2026?", "TIME IS RIZZ"]
        caption(nags[rng.next(upperBound: nags.count)],
                at: CGPoint(x: ctx.bounds.midX, y: ctx.bounds.midY * 0.8),
                size: ctx.cardWidth * 0.44, delay: 0, lifetime: 1.0, in: ctx)
    }

    /// The win. The cascade is already busy throwing the foundations across the
    /// table, so this goes off around it — a barrage of fireworks from both
    /// sides, confetti, and one caption that stays up long enough to read.
    func finale(in ctx: Context) {
        sweep(force: false)
        caption("GG 🔥🔥🔥", at: CGPoint(x: ctx.bounds.midX, y: ctx.bounds.midY),
                size: ctx.cardWidth * 0.9, delay: 0.1, lifetime: 1.6, in: ctx)
        for i in 0..<8 {
            firework(delay: 0.12 * Double(i), in: ctx)
        }
        for i in 0..<3 {
            confetti(delay: 0.25 * Double(i), in: ctx)
        }
        shake(magnitude: 10, punch: 0.05, delay: 0.1, in: ctx)
        flash(delay: 0.1, in: ctx)
    }

    /// Puts the wash and the vignette on the board, and moves them to fit if
    /// the window has been resized since. Idempotent — called on every beat.
    private func installBackdrop(in ctx: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if wash.superlayer !== ctx.root {
            wash.zPosition = -1
            wash.opacity = 0
            // Under the cards but over the felt. The felt is whatever
            // `draw(_:)` painted, which AppKit parks in a private sublayer of
            // its own, so the wash is inserted directly above it where one
            // exists; `sortSublayers` keeps that order afterwards. If it ever
            // cannot be found the wash simply ends up invisible, which is a
            // missing tint and not a broken board.
            let felt = (ctx.root.sublayers ?? []).first {
                !($0 is CardLayer) && $0.zPosition <= 0 && $0 !== wash
            }
            if let felt {
                ctx.root.insertSublayer(wash, above: felt)
            } else {
                ctx.root.addSublayer(wash)
            }

            vignette.type = .radial
            vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
            vignette.endPoint = CGPoint(x: 1.15, y: 1.15)
            vignette.locations = [0.45, 1.0]
            vignette.zPosition = Z.vignette
            vignette.opacity = 0
            ctx.root.addSublayer(vignette)
        }
        wash.frame = ctx.bounds
        vignette.frame = ctx.bounds
        CATransaction.commit()
    }

    /// One beat of the backdrop: the wash steps to the next colour and throbs,
    /// and the vignette is set to whatever the combo has earned.
    ///
    /// Driven by a timer on the board rather than by the audio, so the mode
    /// looks the same with the music off. It is a colour throb and not a
    /// metronome, so a few milliseconds of timer drift against the kick is
    /// beneath noticing.
    func pulse(in ctx: Context) {
        installBackdrop(in: ctx)
        beat += 1
        sweep(force: false)

        let tint = Self.palette[beat % Self.palette.count]
        let base: Float = 0.10 + Float(min(combo, 12)) * 0.006
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.backgroundColor = tint.cgColor
        CATransaction.commit()

        let throb = CAKeyframeAnimation(keyPath: "opacity")
        throb.values = [base * 2.2, base]
        throb.keyTimes = [0, 1]
        throb.duration = BrainrotAudio.beatInterval
        throb.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wash.opacity = base
        wash.add(throb, forKey: "throb")

        // The edge glow is the combo meter: nothing at all for the first few
        // moves, closing in and reddening from there.
        let heat = min(combo, 14)
        let edge = Self.palette[(beat / 2) % Self.palette.count]
        vignette.colors = [NSColor.clear.cgColor, edge.cgColor]
        let strength = heat < 3 ? 0 : Float(heat - 2) * 0.055
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [min(0.75, strength * 1.5), strength]
        glow.keyTimes = [0, 1]
        glow.duration = BrainrotAudio.beatInterval
        vignette.opacity = strength
        vignette.add(glow, forKey: "glow")
    }

    /// A couple of emoji drifting down the board, on and on, whether or not
    /// anything is happening. This is the part that makes the mode feel like a
    /// phone rather than a card table.
    func drizzle(in ctx: Context) {
        let start = CACurrentMediaTime()
        let lifetime: CFTimeInterval = 2.2
        var made: [CALayer] = []
        for _ in 0..<(1 + rng.next(upperBound: 2)) {
            let size = ctx.cardWidth * (0.22 + CGFloat(rng.next(upperBound: 20)) / 100)
            let x = ctx.bounds.minX + ctx.bounds.width * CGFloat(rng.next(upperBound: 100)) / 100
            let piece = label(Self.confettiEmoji[rng.next(upperBound: Self.confettiEmoji.count)],
                              size: size, colour: .white, in: ctx)
            piece.zPosition = Z.debris
            let from = CGPoint(x: x, y: ctx.bounds.minY - size)
            let to = CGPoint(x: x + CGFloat(rng.next(upperBound: 120)) - 60,
                             y: ctx.bounds.maxY + size)
            piece.position = from
            piece.opacity = 0
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat(rng.next(upperBound: 6)) - 3
            spin.duration = lifetime
            spin.beginTime = start
            animate(piece, [
                travel(from: from, to: to, lift: 0, duration: lifetime, start: start,
                       timing: CAMediaTimingFunction(name: .linear)),
                opacity(values: [0, 0.85, 0.85, 0], keyTimes: [0, 0.1, 0.8, 1],
                        duration: lifetime, start: start),
                spin,
            ])
            made.append(piece)
        }
        add(made, start: start, lifetime: lifetime, in: ctx)
    }

    /// After-images strung out along the path a card just took.
    ///
    /// They sit above the cards rather than behind the one that is moving:
    /// a trail is translucent enough that the order does not read, and the
    /// alternative is threading a z-position between "every card at rest" and
    /// "the card in flight", which are two numbers apart.
    func ghosts(of contents: Any?, size: CGSize, cornerRadius: CGFloat,
                from: CGPoint, to: CGPoint, duration: CFTimeInterval, in ctx: Context) {
        guard contents != nil else { return }
        let start = CACurrentMediaTime()
        var made: [CALayer] = []
        for step in 1...3 {
            let fraction = CGFloat(step) / 4
            let ghost = CALayer()
            ghost.bounds = CGRect(origin: .zero, size: size)
            ghost.contents = contents
            ghost.cornerRadius = cornerRadius
            ghost.masksToBounds = true
            ghost.position = CGPoint(x: from.x + (to.x - from.x) * fraction,
                                     y: from.y + (to.y - from.y) * fraction)
            ghost.opacity = 0
            ghost.zPosition = Z.debris - 10
            ghost.contentsScale = ctx.contentsScale
            let show = duration * Double(fraction)
            animate(ghost, [
                opacity(values: [0.5, 0], keyTimes: [0, 1], duration: duration * 0.8,
                        start: start + show),
                scale(from: 1, to: 0.82, duration: duration * 0.8, start: start + show,
                      timing: CAMediaTimingFunction(name: .easeOut)),
            ])
            made.append(ghost)
        }
        add(made, start: start, lifetime: duration * 1.8, in: ctx)
    }

    /// The board saying no. Fires where the refused card is, instead of the
    /// explosion a legal move would have got.
    func refuse(at point: CGPoint, in ctx: Context) {
        let phrase = ["NUH UH 💀", "SKILL ISSUE", "NAH 🚫", "L + RATIO", "BRO 😭"]
        caption(phrase[rng.next(upperBound: phrase.count)],
                at: point, size: ctx.cardWidth * 0.34, delay: 0, lifetime: 0.7, in: ctx)
    }

    /// Clears the table and forgets the run. Called when the mode is switched
    /// off, and on every new deal.
    func stop() {
        live.forEach { $0.layers.forEach { $0.removeFromSuperlayer() } }
        live.removeAll()
        wash.removeAllAnimations()
        vignette.removeAllAnimations()
        wash.removeFromSuperlayer()
        vignette.removeFromSuperlayer()
        combo = 0
        lastMove = 0
        lastNag = 0
        beat = 0
    }

    /// Layers currently on the board, for the play-test's leak check.
    var liveLayerCount: Int { live.reduce(0) { $0 + $1.layers.count } }

    // MARK: Explosion

    /// Fireball: a white core, two expanding shockwave rings and a spray of
    /// debris that arcs and falls.
    private func explosion(at point: CGPoint, big: Bool, delay: CFTimeInterval, in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let radius = ctx.cardWidth * (big ? 1.15 : 0.75)
        let lifetime: CFTimeInterval = big ? 0.62 : 0.44
        var made: [CALayer] = []

        // Core: one hot disc that blooms and is gone before the debris lands.
        let core = disc(diameter: radius * 0.9, colour: .white, in: ctx)
        core.position = point
        core.shadowRadius = radius * 0.5
        core.shadowOpacity = 1
        core.shadowColor = Self.palette[3].cgColor
        animate(core, [
            scale(from: 0.2, to: 1.35, duration: lifetime * 0.4, start: start,
                  timing: CAMediaTimingFunction(controlPoints: 0, 0.9, 0.2, 1)),
            opacity(values: [1, 0.85, 0], keyTimes: [0, 0.35, 1],
                    duration: lifetime * 0.4, start: start),
        ])
        made.append(core)

        for (i, tint) in [Self.palette[3], Self.palette[4]].enumerated() {
            let wave = ring(diameter: radius * 2, width: ctx.cardWidth * (big ? 0.05 : 0.035),
                            colour: tint, in: ctx)
            wave.position = point
            let span = lifetime * (0.55 + 0.2 * Double(i))
            animate(wave, [
                scale(from: 0.15, to: 1 + 0.35 * CGFloat(i), duration: span, start: start,
                      timing: CAMediaTimingFunction(controlPoints: 0, 0.85, 0.25, 1)),
                opacity(values: [0.95, 0.5, 0], keyTimes: [0, 0.4, 1], duration: span, start: start),
            ])
            made.append(wave)
        }

        for i in 0..<(big ? 26 : 16) {
            let angle = (CGFloat(i) + CGFloat(rng.next(upperBound: 80)) / 100)
                * (2 * .pi / CGFloat(big ? 26 : 16))
            let distance = radius * (0.55 + CGFloat(rng.next(upperBound: 110)) / 100)
            let side = ctx.cardWidth * 0.075 * (0.6 + CGFloat(rng.next(upperBound: 90)) / 100)
            let bit = disc(diameter: side, colour: Self.palette[rng.next(upperBound: Self.palette.count)],
                           in: ctx)
            bit.position = point
            // +y is down the screen on this board, so debris falls by gaining
            // y and the arc's control point sits above the chord.
            let end = CGPoint(x: point.x + cos(angle) * distance,
                              y: point.y + sin(angle) * distance + radius * 0.55)
            animate(bit, [
                travel(from: point, to: end, lift: radius * 0.4, duration: lifetime, start: start),
                opacity(values: [1, 1, 0], keyTimes: [0, 0.45, 1], duration: lifetime, start: start),
                scale(from: 1.2, to: 0.15, duration: lifetime, start: start,
                      timing: CAMediaTimingFunction(name: .easeIn)),
            ])
            made.append(bit)
        }

        add(made, start: start, lifetime: lifetime, in: ctx)
    }

    /// The spokes. Each one is a bar pinned at the impact point by its own
    /// anchor and rotated into place in the model transform, so the animation
    /// only has to stretch `bounds` — a rotation and a scale animation on one
    /// transform fight, a rotation and a bounds animation do not.
    private func rays(at point: CGPoint, count: Int, delay: CFTimeInterval, in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let lifetime: CFTimeInterval = 0.32
        let length = ctx.cardWidth * 1.5
        let thickness = max(1.5, ctx.cardWidth * 0.03)
        var made: [CALayer] = []

        for i in 0..<count {
            let angle = CGFloat(i) * (2 * .pi / CGFloat(count))
                + CGFloat(rng.next(upperBound: 50)) / 100
            let ray = CALayer()
            ray.anchorPoint = CGPoint(x: 0, y: 0.5)
            ray.bounds = CGRect(x: 0, y: 0, width: length * 0.2, height: thickness)
            ray.position = point
            ray.backgroundColor = Self.palette[rng.next(upperBound: Self.palette.count)].cgColor
            ray.cornerRadius = thickness / 2
            ray.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            ray.opacity = 0
            ray.zPosition = Z.debris
            ray.contentsScale = ctx.contentsScale

            let stretch = CABasicAnimation(keyPath: "bounds.size.width")
            stretch.fromValue = length * 0.2
            stretch.toValue = length
            stretch.duration = lifetime
            // Set before it is handed over: `add` copies the animation, so a
            // `beginTime` written afterwards would be written to nothing and
            // the ray would fire the moment the move started.
            stretch.beginTime = start
            stretch.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0.9, 0.2, 1)
            animate(ray, [stretch, opacity(values: [0.9, 0], keyTimes: [0, 1],
                                           duration: lifetime, start: start)])
            made.append(ray)
        }
        add(made, start: start, lifetime: lifetime, in: ctx)
    }

    // MARK: Fireworks and confetti

    /// A shell that climbs from the bottom edge and opens in the upper half of
    /// the board, trail and all.
    private func firework(delay: CFTimeInterval, in ctx: Context) {
        let riseTime: CFTimeInterval = 0.45
        let burstTime: CFTimeInterval = 0.85
        let start = CACurrentMediaTime() + delay
        let launch = CGPoint(x: ctx.bounds.minX + ctx.bounds.width
                                * CGFloat(15 + rng.next(upperBound: 70)) / 100,
                             y: ctx.bounds.maxY)
        let peak = CGPoint(x: launch.x + CGFloat(rng.next(upperBound: 200)) - 100,
                           y: ctx.bounds.minY + ctx.bounds.height
                               * CGFloat(12 + rng.next(upperBound: 33)) / 100)
        let tint = Self.palette[rng.next(upperBound: Self.palette.count)]
        var made: [CALayer] = []

        let shell = disc(diameter: ctx.cardWidth * 0.09, colour: .white, in: ctx)
        shell.position = launch
        shell.shadowColor = tint.cgColor
        shell.shadowRadius = ctx.cardWidth * 0.12
        shell.shadowOpacity = 1
        animate(shell, [
            travel(from: launch, to: peak, lift: 0, duration: riseTime, start: start,
                   timing: CAMediaTimingFunction(name: .easeOut)),
            opacity(values: [0.2, 1, 1, 0], keyTimes: [0, 0.1, 0.85, 1],
                    duration: riseTime, start: start),
        ])
        made.append(shell)

        // The shell opens where it ran out of climb.
        let flashRing = ring(diameter: ctx.cardWidth * 1.6, width: ctx.cardWidth * 0.04,
                             colour: tint, in: ctx)
        flashRing.position = peak
        animate(flashRing, [
            scale(from: 0.1, to: 1.2, duration: burstTime * 0.5, start: start + riseTime,
                  timing: CAMediaTimingFunction(controlPoints: 0, 0.9, 0.2, 1)),
            opacity(values: [1, 0], keyTimes: [0, 1], duration: burstTime * 0.5,
                    start: start + riseTime),
        ])
        made.append(flashRing)

        for i in 0..<28 {
            let angle = CGFloat(i) * (2 * .pi / 28) + CGFloat(rng.next(upperBound: 40)) / 100
            let distance = ctx.cardWidth * (1.0 + CGFloat(rng.next(upperBound: 90)) / 100)
            let star = disc(diameter: ctx.cardWidth * 0.06,
                            colour: i % 4 == 0 ? .white : tint, in: ctx)
            star.position = peak
            star.shadowColor = tint.cgColor
            star.shadowRadius = ctx.cardWidth * 0.08
            star.shadowOpacity = 0.9
            let end = CGPoint(x: peak.x + cos(angle) * distance,
                              y: peak.y + sin(angle) * distance + ctx.cardWidth * 0.9)
            animate(star, [
                travel(from: peak, to: end, lift: ctx.cardWidth * 0.25,
                       duration: burstTime, start: start + riseTime),
                opacity(values: [1, 1, 0], keyTimes: [0, 0.5, 1],
                        duration: burstTime, start: start + riseTime),
                scale(from: 1, to: 0.2, duration: burstTime, start: start + riseTime,
                      timing: CAMediaTimingFunction(name: .easeIn)),
            ])
            made.append(star)
        }
        add(made, start: start, lifetime: riseTime + burstTime, in: ctx)
    }

    /// Paper and emoji from the top edge, tumbling as they fall past the board.
    private func confetti(delay: CFTimeInterval, in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let lifetime: CFTimeInterval = 1.5
        var made: [CALayer] = []

        for i in 0..<26 {
            let x = ctx.bounds.minX + ctx.bounds.width * CGFloat(rng.next(upperBound: 100)) / 100
            let from = CGPoint(x: x, y: ctx.bounds.minY - ctx.cardWidth * 0.3)
            let to = CGPoint(x: x + CGFloat(rng.next(upperBound: 220)) - 110,
                             y: ctx.bounds.maxY + ctx.cardWidth * 0.4)
            let span = lifetime * (0.65 + Double(rng.next(upperBound: 40)) / 100)

            // Every fourth piece is an emoji rather than paper, which is the
            // detail that stops it reading as a party popper and starts it
            // reading as a phone screen.
            let piece: CALayer
            if i % 4 == 0 {
                let size = ctx.cardWidth * 0.30
                piece = label(Self.confettiEmoji[rng.next(upperBound: Self.confettiEmoji.count)],
                              size: size, colour: .white, in: ctx)
            } else {
                let w = ctx.cardWidth * 0.11, h = ctx.cardWidth * 0.16
                let paper = CALayer()
                paper.bounds = CGRect(x: 0, y: 0, width: w, height: h)
                paper.backgroundColor = Self.palette[rng.next(upperBound: Self.palette.count)].cgColor
                paper.cornerRadius = w * 0.2
                paper.contentsScale = ctx.contentsScale
                piece = paper
            }
            piece.position = from
            piece.opacity = 0
            piece.zPosition = Z.debris

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat(rng.next(upperBound: 12)) - 6
            spin.duration = span
            spin.beginTime = start

            animate(piece, [
                travel(from: from, to: to, lift: -ctx.cardWidth * 0.6, duration: span, start: start,
                       timing: CAMediaTimingFunction(name: .easeIn)),
                opacity(values: [1, 1, 0], keyTimes: [0, 0.75, 1], duration: span, start: start),
                spin,
            ])
            made.append(piece)
        }
        add(made, start: start, lifetime: lifetime * 1.05, in: ctx)
    }

    // MARK: Captions, flash, shake

    /// A caption that punches in, hangs, and drifts off.
    ///
    /// Two layers: the outer one holds the tilt in its model transform and the
    /// inner one does the bouncing. One layer would need a rotation *and* a
    /// scale on the same transform, which is exactly the fight the rays avoid.
    private func caption(_ text: String, at point: CGPoint, size: CGFloat,
                         delay: CFTimeInterval, lifetime: CFTimeInterval = 0.85,
                         in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let tilt = (CGFloat(rng.next(upperBound: 24)) - 12) * .pi / 180
        let tint = Self.palette[rng.next(upperBound: Self.palette.count - 1)]

        let holder = CALayer()
        holder.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        holder.position = point
        holder.transform = CATransform3DMakeRotation(tilt, 0, 0, 1)
        holder.zPosition = Z.caption
        // The board's root layer is geometry-flipped, because the view is, and
        // the holder has to say the same thing or the space inside it flips
        // back: the caption would then be rendered upside down by its own
        // `isGeometryFlipped`, and would drift down the screen instead of up.
        holder.isGeometryFlipped = true

        let body = label(text, size: size, colour: tint, in: ctx)
        body.position = .zero
        body.opacity = 0
        holder.addSublayer(body)

        animate(body, [
            keyframeScale(values: [0.2, 1.3, 0.95, 1.0], keyTimes: [0, 0.45, 0.7, 1],
                          duration: lifetime * 0.5, start: start),
            opacity(values: [1, 1, 0], keyTimes: [0, 0.6, 1], duration: lifetime, start: start),
            travel(from: .zero, to: CGPoint(x: 0, y: -size * 0.9), lift: 0,
                   duration: lifetime, start: start,
                   timing: CAMediaTimingFunction(name: .easeOut)),
        ])
        add([holder], start: start, lifetime: lifetime, in: ctx)
    }

    /// One frame of white over the whole board. Kept brief and well short of
    /// opaque: this is a punctuation mark, not a strobe.
    private func flash(delay: CFTimeInterval, in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let sheet = CALayer()
        sheet.frame = ctx.bounds
        sheet.backgroundColor = NSColor.white.cgColor
        sheet.opacity = 0
        sheet.zPosition = Z.flash
        animate(sheet, [opacity(values: [0.42, 0], keyTimes: [0, 1], duration: 0.2, start: start)])
        add([sheet], start: start, lifetime: 0.2, in: ctx)
    }

    /// Kicks the whole board sideways and lets it settle.
    ///
    /// Driven through the root layer's `sublayerTransform`, which moves the felt
    /// and every card together with one animation and — unlike moving the view —
    /// cannot desynchronise from hit testing, because hit testing never looks at
    /// the layers. The board's own background colour is what shows in the sliver
    /// the shake opens at the edge, which is why `BoardView` paints it felt.
    private func shake(magnitude: CGFloat, punch: CGFloat, delay: CFTimeInterval, in ctx: Context) {
        let start = CACurrentMediaTime() + delay
        let centre = CGPoint(x: ctx.bounds.midX, y: ctx.bounds.midY)
        let steps: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 1), (-0.9, 0.5, 1 + punch), (0.75, -0.6, 1 + punch * 0.6),
            (-0.5, 0.35, 1 + punch * 0.3), (0.3, -0.2, 1), (0, 0, 1),
        ]
        let frames = steps.map { dx, dy, s -> NSValue in
            // Scale about the middle of the board rather than its top-left
            // corner, which is where the anchor of a flipped root layer is.
            var t = CATransform3DMakeTranslation(centre.x + dx * magnitude,
                                                 centre.y + dy * magnitude, 0)
            t = CATransform3DScale(t, s, s, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(t, -centre.x, -centre.y, 0))
        }
        let kick = CAKeyframeAnimation(keyPath: "sublayerTransform")
        kick.values = frames
        kick.duration = 0.34
        kick.beginTime = start
        kick.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ctx.root.add(kick, forKey: "brainrotShake")
        CATransaction.commit()
    }

    // MARK: Layer factory

    private func disc(diameter: CGFloat, colour: NSColor, in ctx: Context) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = colour.cgColor
        layer.shadowColor = colour.cgColor
        layer.shadowOffset = .zero
        layer.shadowRadius = diameter * 0.6
        layer.shadowOpacity = 0.9
        layer.opacity = 0
        layer.zPosition = Z.debris
        layer.contentsScale = ctx.contentsScale
        return layer
    }

    private func ring(diameter: CGFloat, width: CGFloat, colour: NSColor, in ctx: Context) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.borderWidth = width
        layer.borderColor = colour.cgColor
        layer.opacity = 0
        layer.zPosition = Z.debris
        layer.contentsScale = ctx.contentsScale
        return layer
    }

    /// Text as an attributed string rather than a plain one, so Core Text can
    /// fall back to the emoji face: a `CATextLayer` handed a system font and an
    /// emoji draws a row of boxes.
    private func label(_ text: String, size: CGFloat, colour: NSColor, in ctx: Context) -> CATextLayer {
        let plain = NSFont.systemFont(ofSize: size, weight: .black)
        let font = NSFont(descriptor: plain.fontDescriptor.withDesign(.rounded) ?? plain.fontDescriptor,
                          size: size) ?? plain
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.75)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.06)
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: colour, .shadow: shadow,
        ])

        let layer = CATextLayer()
        layer.string = string
        layer.alignmentMode = .center
        layer.isWrapped = false
        layer.contentsScale = ctx.contentsScale
        layer.zPosition = Z.caption
        // A flipped board would otherwise draw every caption upside down.
        layer.isGeometryFlipped = true
        let measured = string.size()
        layer.bounds = CGRect(x: 0, y: 0,
                              width: (measured.width + size).rounded(),
                              height: (measured.height + size * 0.4).rounded())
        return layer
    }

    // MARK: Animation helpers

    /// Every animation here is held back with `beginTime` and leaves the layer
    /// at its model values — invisible — before it starts and after it is
    /// removed. That is what lets a whole burst be built, and therefore owned
    /// and sweepable, in one pass now for something that happens later.
    private func animate(_ layer: CALayer, _ animations: [CAAnimation]) {
        for (i, animation) in animations.enumerated() {
            layer.add(animation, forKey: "brainrot\(i)")
        }
    }

    private func opacity(values: [Float], keyTimes: [NSNumber], duration: CFTimeInterval,
                         start: CFTimeInterval) -> CAKeyframeAnimation {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = values
        fade.keyTimes = keyTimes
        fade.duration = duration
        fade.beginTime = start
        return fade
    }

    private func scale(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
                       start: CFTimeInterval, timing: CAMediaTimingFunction) -> CABasicAnimation {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = from
        grow.toValue = to
        grow.duration = duration
        grow.beginTime = start
        grow.timingFunction = timing
        return grow
    }

    private func keyframeScale(values: [CGFloat], keyTimes: [NSNumber], duration: CFTimeInterval,
                               start: CFTimeInterval) -> CAKeyframeAnimation {
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = values
        pop.keyTimes = keyTimes
        pop.duration = duration
        pop.beginTime = start
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return pop
    }

    /// Movement along an arc rather than a straight line — `lift` bows the path
    /// against the direction of travel, which is what makes debris look thrown
    /// and confetti look like it is caught in the air.
    private func travel(from: CGPoint, to: CGPoint, lift: CGFloat, duration: CFTimeInterval,
                        start: CFTimeInterval,
                        timing: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.72, 0.25, 1))
        -> CAKeyframeAnimation {
        let path = CGMutablePath()
        path.move(to: from)
        path.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2,
                                                   y: (from.y + to.y) / 2 - lift))
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        move.duration = duration
        move.beginTime = start
        move.timingFunction = timing
        return move
    }

    // MARK: Pool

    private func add(_ layers: [CALayer], start: CFTimeInterval, lifetime: CFTimeInterval,
                     in ctx: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.forEach(ctx.root.addSublayer)
        CATransaction.commit()

        live.append(Live(layers: layers, expires: start + lifetime))
        sweep(force: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + (start - CACurrentMediaTime())
                                        + lifetime + 0.05) { [weak self] in
            self?.sweep(force: false)
        }
    }

    /// Drops everything whose time is up, then keeps dropping the oldest until
    /// the board is back under the ceiling. The second half is the part that
    /// matters: the cleanup above is scheduled on the main queue, and a run of
    /// moves fast enough — auto-finish, or a player on a tear — outpaces it.
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
        var total = survivors.reduce(0) { $0 + $1.layers.count }
        while total > Self.layerCeiling || (force && !survivors.isEmpty) {
            let oldest = survivors.removeFirst()
            oldest.layers.forEach { $0.removeFromSuperlayer() }
            total -= oldest.layers.count
            if force { break }
        }
        live = survivors
    }
}
