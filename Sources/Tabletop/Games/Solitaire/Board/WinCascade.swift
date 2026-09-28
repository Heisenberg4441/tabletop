//
//  WinCascade.swift
//  The reward: the foundations empty themselves across the table in bouncing
//  arcs that paint over everything, exactly as Windows Solitaire has done since
//  1990. It is the only part of this app that exists purely for delight.
//

import AppKit
import QuartzCore

final class WinCascade {

    private struct Flier {
        var card: Card
        var position: CGPoint
        var velocity: CGVector
    }

    private weak var view: NSView?
    private let cardLayers: [UInt8: CardLayer]
    private let layout: BoardLayout
    private let state: GameState

    private let trailLayer = CALayer()
    private var canvas: CGContext?
    private var fliers: [Flier] = []
    private var queue: [Card] = []
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var launchTimer: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var cardSize: CGSize = .zero

    // Feel, in points per second. Tuned so a card crosses the table in a few
    // hops rather than skittering off instantly.
    private let gravity: CGFloat = 1500
    private let restitution: CGFloat = 0.78
    private let launchInterval: CFTimeInterval = 0.14

    init(view: NSView, cardLayers: [UInt8: CardLayer], layout: BoardLayout, state: GameState) {
        self.view = view
        self.cardLayers = cardLayers
        self.layout = layout
        self.state = state
    }

    func start(completion: @escaping () -> Void) {
        guard let view, let root = view.layer else { completion(); return }
        self.completion = completion
        cardSize = layout.cardSize

        let scale = view.window?.backingScaleFactor ?? 2
        canvas = CGContext(
            data: nil,
            width: max(1, Int(view.bounds.width * scale)),
            height: max(1, Int(view.bounds.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        canvas?.scaleBy(x: scale, y: scale)

        trailLayer.frame = view.bounds
        trailLayer.zPosition = 5000
        trailLayer.contentsScale = scale
        trailLayer.isGeometryFlipped = true
        root.addSublayer(trailLayer)

        // Launch from the top of each foundation downward, cycling suits, so
        // kings go first and the piles come apart evenly.
        var order: [Card] = []
        for rank in stride(from: 13, through: 1, by: -1) {
            for suit in Suit.allCases {
                order.append(Card(suit, Rank(rawValue: UInt8(rank))!))
            }
        }
        queue = order

        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    /// Drops everything the animation needs while it is in flight — the clock,
    /// the scratch bitmap and the cards still to be thrown — but leaves the
    /// painted trails on screen. They are the prize, and they belong under the
    /// "you win" alert until the next deal wipes them.
    private func releaseRunningState() {
        displayLink?.invalidate()
        displayLink = nil
        canvas = nil
        fliers.removeAll()
        queue.removeAll()
    }

    /// Cancels the cascade and clears the table. Safe at any point, including
    /// long after the animation finished by itself, which is the only way the
    /// trails ever come off the board.
    func stop() {
        releaseRunningState()
        completion = nil
        trailLayer.removeFromSuperlayer()
        trailLayer.contents = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let view, let canvas else { finish(); return }

        let now = link.timestamp
        var dt = lastTimestamp == 0 ? 1.0 / 60.0 : now - lastTimestamp
        lastTimestamp = now
        dt = min(dt, 1.0 / 30.0)      // never let a stall throw cards off-screen

        launchTimer -= dt
        if launchTimer <= 0, !queue.isEmpty {
            launchTimer = launchInterval
            launch(queue.removeFirst())
        }

        let bounds = view.bounds
        var stillFlying: [Flier] = []
        stillFlying.reserveCapacity(fliers.count)

        for var flier in fliers {
            flier.velocity.dy += gravity * CGFloat(dt)
            flier.position.x += flier.velocity.dx * CGFloat(dt)
            flier.position.y += flier.velocity.dy * CGFloat(dt)

            let floor = bounds.maxY - cardSize.height
            if flier.position.y > floor {
                flier.position.y = floor
                flier.velocity.dy = -abs(flier.velocity.dy) * restitution
                // A card that has stopped bouncing would sit and jitter, so
                // once the hop is small it is given a shove and allowed to leave.
                if abs(flier.velocity.dy) < 120 {
                    flier.velocity.dy = -260
                }
            }

            stamp(flier, in: canvas)

            if flier.position.x > -cardSize.width * 1.5 && flier.position.x < bounds.maxX + cardSize.width * 1.5 {
                stillFlying.append(flier)
            }
        }
        fliers = stillFlying

        if let image = canvas.makeImage() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            trailLayer.contents = image
            CATransaction.commit()
        }

        if fliers.isEmpty && queue.isEmpty { finish() }
    }

    private func launch(_ card: Card) {
        guard let view else { return }
        let frame = layout.frame(of: .foundation(card.foundationIndex))
        cardLayers[card.code]?.isHidden = true

        // Alternate the direction so the table empties both ways, and vary the
        // speed enough that the arcs never look mechanical.
        var rng = DeterministicRNG(seed: UInt64(card.code) &* 2_654_435_761)
        let spread = CGFloat(rng.next(upperBound: 260)) + 180
        let direction: CGFloat = frame.midX > view.bounds.midX ? -1 : 1
        fliers.append(Flier(
            card: card,
            position: CGPoint(x: frame.minX, y: frame.minY),
            velocity: CGVector(dx: direction * spread, dy: -CGFloat(rng.next(upperBound: 320)) - 60)
        ))
    }

    private func stamp(_ flier: Flier, in ctx: CGContext) {
        guard let cardLayer = cardLayers[flier.card.code],
              let image = cardLayer.contents.map({ $0 as! CGImage }) else { return }
        ctx.saveGState()
        ctx.translateBy(x: flier.position.x, y: flier.position.y + cardSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: cardSize))
        ctx.restoreGState()
    }

    /// Skips to the end: the cards stop where they are, the trails stay, and
    /// the completion runs now. For a cascade the player walked away from —
    /// a display link must not keep ticking for a table nobody is watching.
    func finishNow() {
        guard displayLink != nil else { return }
        finish()
    }

    /// True while the display link exists — the cascade is still flying.
    var isRunning: Bool { displayLink != nil }

    private func finish() {
        releaseRunningState()
        let done = completion
        completion = nil
        done?()
    }
}
