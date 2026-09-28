//
//  BoardView.swift
//  The table: draws the felt and the empty slots, owns one layer per card, and
//  turns clicks and drags into moves.
//
//  The animation strategy is a single idea applied everywhere. `BoardLayout`
//  turns a game state into a list of card positions, so after any change at all
//  — a move, an undo, a restart, a resize — the view recomputes the list and
//  glides every layer to where it now belongs. Nothing needs to know what kind
//  of change happened, which is why undo animates as nicely as a move does.
//

import AppKit
import QuartzCore

protocol BoardViewDelegate: AnyObject {
    func boardViewDidChangeGame(_ view: BoardView)
    func boardView(_ view: BoardView, didFinishWinAnimation: Bool)
}

final class BoardView: NSView {

    weak var delegate: BoardViewDelegate?

    private(set) var game: Game
    var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            renderer.update(theme: theme, size: boardLayout.cardSize, scale: backingScale)
            for cardLayer in cardLayers.values {
                cardLayer.apple = theme.apple
                cardLayer.refreshImage(renderer: renderer)
                // The mode changes how deep a card sits above the table, and
                // the resting shadow is written once rather than per frame —
                // so switching modes has to rewrite it here or every card keeps
                // the old depth until something else moves it.
                cardLayer.updateShadow(cornerRadius: boardLayout.cornerRadius,
                                       lifted: cardLayer.isHeld)
            }
            layer?.backgroundColor = feltEdgeColor
            updateDropGlow()
            needsDisplay = true
        }
    }

    private(set) var boardLayout: BoardLayout
    private var renderer: CardRenderer
    private var cardLayers: [UInt8: CardLayer] = [:]
    private var placements: [CardPlacement] = []

    /// Cards the player is currently dragging, bottom of the run first.
    private var heldCards: [Card] = []
    private var heldOrigin: [UInt8: CGPoint] = [:]
    private var heldSource: PileID?
    private var dragStart: CGPoint = .zero
    private var pendingTarget: ClickTarget = .nothing
    private var isDragging = false
    private var dropHighlight: PileID?
    /// Where the pointer was at the previous mouse-moved event, and the rolling
    /// average of how fast it is travelling. Only Apple mode reads them, to
    /// lean the cards it is carrying.
    private var lastDragPoint: CGPoint = .zero
    private var dragLean: CGVector = .zero

    /// Synthetic elements standing in for the piles, since the board is drawn
    /// into layers and has no subviews for VoiceOver to find.
    var pileAccessibilityElements: [PileAccessibilityElement] = []

    /// Fingerprint of everything the background actually depends on. The felt
    /// is a radial gradient across the whole window and the empty slots are
    /// drawn on top of it; repainting that costs several million pixels, and
    /// none of it changes when a card moves. Comparing this before invalidating
    /// turns a full-window redraw on every single move into one that happens
    /// only when a pile empties or fills.
    private var backgroundSignature: Int?

    private var hintedCards: Set<UInt8> = []
    private var hintCycle = 0

    /// The outline that follows the cards around while they are being dragged.
    /// It lives in a layer of its own rather than in `draw(_:)` so that showing
    /// and hiding it costs one small composite instead of repainting the felt
    /// across the whole window.
    private let dropGlow = CAShapeLayer()
    private let scoreFloats = ScoreFloatPool()

    /// Set while the auto-finish or win cascade is running so input is ignored.
    private(set) var isPerformingSequence = false

    /// True while the player has cards in hand. The model must not be changed
    /// underneath a live drag, or the card being held stops matching the card
    /// the game thinks is moving.
    var isInteracting: Bool { isDragging || !heldCards.isEmpty }

    // Timings, in seconds. Fast enough to feel instant, slow enough to follow.
    private enum Timing {
        static let move = 0.17
        static let flip = 0.20
        static let deal = 0.26
        static let dealStagger = 0.018
        static let snapBack = 0.20
        static let autoFinishStep = 0.075
        static let pickUp = 0.13
        static let glowFade = 0.13
    }

    /// Ease-out with a long tail: cards leave briskly and settle rather than
    /// stopping dead, which is what makes a 0.17s move readable at all.
    private static let moveCurve = CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.24, 1.0)

    /// Bumped by every layout pass, so a pass that finishes after a newer one
    /// has started can tell that it has been superseded.
    private var generation = 0

    /// Off under Reduce Motion and while `--shot` is photographing the board:
    /// every move then lands in place at once, which is both what the setting
    /// asks for and what makes a screenshot deterministic.
    var animationsEnabled: Bool { TabletopEnvironment.animationsEnabled }

    /// How far down the window the table starts: the strip under the
    /// transparent titlebar belongs to the window (see `TabletopChrome`). It
    /// is painted as the dark room the table stands in — every screen's top
    /// band is the same quiet surface for the chrome to sit on — and the
    /// table's frame begins below it.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            needsLayout = true
            backgroundSignature = nil
            needsDisplay = true
        }
    }

    /// How much of the bottom of the view the floating action bar covers.
    /// The felt runs under it, the cards stop above it.
    var bottomInset: CGFloat = 0 {
        didSet {
            guard bottomInset != oldValue else { return }
            needsLayout = true
            backgroundSignature = nil
            needsDisplay = true
        }
    }

    /// The part of the view the cards are laid out in.
    private var layoutBounds: CGRect {
        var rect = bounds
        rect.origin.y += topInset
        rect.size.height = max(1, rect.height - topInset - bottomInset)
        return rect
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: Init

    init(game: Game, theme: Theme) {
        self.game = game
        self.theme = theme
        self.boardLayout = BoardLayout(bounds: CGRect(x: 0, y: 0, width: 900, height: 640))
        self.renderer = CardRenderer(theme: theme, size: boardLayout.cardSize, scale: 2)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawSubviewsIntoLayer = false
        layer?.masksToBounds = true
        // The felt is painted by `draw(_:)` into a sublayer of its own. The
        // layer underneath is painted the darkest felt colour, so that a live
        // resize — which can show the layer a frame before the felt catches
        // up — shows more table rather than a flash of bare window.
        layer?.backgroundColor = feltEdgeColor
    }

    /// The darkest colour on the table, painted behind everything.
    private var feltEdgeColor: CGColor {
        (theme.apple ? theme.table.appleGradient.edge : theme.table.gradient.edge).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        rebuildLayers()
        relayout(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.update(theme: theme, size: boardLayout.cardSize, scale: backingScale)
        for layer in cardLayers.values {
            layer.contentsScale = backingScale
            layer.refreshImage(renderer: renderer)
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    // MARK: Game plumbing

    func replaceGame(_ newGame: Game, dealAnimation: Bool) {
        // A new deal arriving mid-cascade has to cancel it, or the old
        // animation keeps flying over the new board and eventually reports a
        // win that belongs to the game that just ended.
        stopWinAnimation()
        game = newGame
        heldCards.removeAll()
        hintedCards.removeAll()
        dropHighlight = nil
        updateDropGlow()
        isPerformingSequence = false
        rebuildLayers()
        if dealAnimation && animationsEnabled {
            runDealAnimation()
        } else {
            relayout(animated: false)
        }
        delegate?.boardViewDidChangeGame(self)
    }

    private func rebuildLayers() {
        cardLayers.values.forEach { $0.removeFromSuperlayer() }
        cardLayers.removeAll()
        scoreFloats.removeAll()
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installDropGlow(in: root)
        for card in Card.full {
            let cardLayer = CardLayer(card: card)
            cardLayer.apple = theme.apple
            cardLayer.contentsScale = backingScale
            // Every card starts face down, and has to look it. Layout only
            // paints a card when it turns over, so a card that is dealt face
            // down and stays that way would otherwise keep a layer with
            // nothing in it — which is exactly what a new deal under Reduce
            // Motion used to show: the face-up cards floating over bare felt.
            cardLayer.setFace(false, renderer: renderer)
            cardLayers[card.code] = cardLayer
            root.addSublayer(cardLayer)
        }
        CATransaction.commit()
    }

    /// Above every card that is lying on the table, including one in flight,
    /// and below the cards in the player's hand — the outline belongs to the
    /// pile, so the cards being dropped on it have to pass over the top.
    private func installDropGlow(in root: CALayer) {
        dropGlow.fillColor = nil
        dropGlow.lineWidth = 2.5
        dropGlow.opacity = 0
        dropGlow.zPosition = 1000
        dropGlow.shadowOffset = .zero
        dropGlow.shadowOpacity = 0.9
        if dropGlow.superlayer !== root { root.addSublayer(dropGlow) }
    }

    // MARK: Layout

    private func relayout(animated: Bool, duration: CFTimeInterval = Timing.move) {
        let newLayout = BoardLayout(bounds: layoutBounds)
        let sizeChanged = newLayout.cardSize != boardLayout.cardSize
        boardLayout = newLayout
        if sizeChanged {
            renderer.update(theme: theme, size: boardLayout.cardSize, scale: backingScale)
            for cardLayer in cardLayers.values { cardLayer.refreshImage(renderer: renderer) }
            needsDisplay = true
        }
        placements = boardLayout.placements(for: game.state)
        apply(placements, animated: animated && animationsEnabled, duration: duration)
        // A resize in the middle of a drag moves the pile the outline is drawn
        // around, and the outline has to go with it.
        if dropHighlight != nil { updateDropGlow() }
        rebuildAccessibilityElements()
    }

    private func apply(_ placements: [CardPlacement], animated: Bool, duration: CFTimeInterval) {
        generation &+= 1
        let thisPass = generation

        CATransaction.begin()
        // Every animation here is written out by hand, so the implicit ones
        // stay off: a resize would otherwise send fifty-two cards sliding to
        // their new sizes at once.
        CATransaction.setDisableActions(true)

        for placement in placements {
            guard let cardLayer = cardLayers[placement.card.code], !cardLayer.isHeld else { continue }
            let destination = CGPoint(x: placement.frame.midX, y: placement.frame.midY)
            let moved = abs(cardLayer.position.x - destination.x) > 0.5
                || abs(cardLayer.position.y - destination.y) > 0.5

            if cardLayer.bounds.size != placement.frame.size {
                cardLayer.bounds = CGRect(origin: .zero, size: placement.frame.size)
                cardLayer.cornerRadius = boardLayout.cornerRadius
                cardLayer.updateShadow(cornerRadius: boardLayout.cornerRadius, lifted: false)
            }
            // A card in flight has to pass over the piles it crosses, so it is
            // lifted out of the normal stacking order until it lands. A card
            // already in the air counts even when this pass is not the one
            // moving it: auto-finish plays a move every 75ms, and without the
            // second half of this test the card from the previous step drops
            // behind the table half way through its own flight.
            let inFlight = animated && (moved || cardLayer.isGliding)
            cardLayer.zPosition = CGFloat(placement.z) + (inFlight ? 600 : 0)

            if animated {
                cardLayer.glide(to: destination, duration: duration, timing: Self.moveCurve)
                if inFlight { cardLayer.lift(for: duration) }
            } else {
                cardLayer.stopGliding()
                cardLayer.position = destination
            }

            if cardLayer.isFaceUp != placement.faceUp {
                if animated {
                    cardLayer.flip(to: placement.faceUp, renderer: renderer, duration: Timing.flip)
                } else {
                    cardLayer.setFace(placement.faceUp, renderer: renderer)
                }
            }
            cardLayer.isHidden = false
        }

        // Dropping the cards back into the ordinary stacking order, and hiding
        // the ones that ended up buried, has to wait until they have landed.
        // A pass that has already been overtaken by a newer one skips this
        // entirely: its idea of where the cards belong is out of date, and
        // acting on it would drop a card that is still in the air behind the
        // pile it is flying towards.
        let settle = { [weak self] in
            guard let self, thisPass == self.generation else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for placement in placements {
                guard let cardLayer = self.cardLayers[placement.card.code], !cardLayer.isHeld else { continue }
                cardLayer.zPosition = CGFloat(placement.z)
            }
            self.hideCoveredCards(placements)
            CATransaction.commit()
        }
        if animated {
            CATransaction.setCompletionBlock(settle)
        }
        CATransaction.commit()
        if !animated { settle() }

        sortSublayers(by: placements)
    }

    /// Takes the cards nobody can see out of the compositor's way.
    ///
    /// The stock is two dozen cards stacked at exactly the same point, a
    /// foundation is up to thirteen, and the waste collects everything turned
    /// over. Only the top of each is ever visible, yet Core Animation still
    /// composites every one of them, shadow and all, on every frame. Hiding
    /// them is free to look at and removes most of the layers from the frame
    /// — and, for the waste, the near-black halo twenty shadows stacked on one
    /// spot used to paint round the top card.
    ///
    /// One card below what shows stays visible, so that drawing from the stock
    /// or playing off the waste has something to reveal underneath (on the
    /// waste, what shows is the fanned cards of a draw-three). This runs only
    /// once an animation has finished — hiding a card mid-flight would make a
    /// recycle look like a single card flying back instead of the whole packet.
    private func hideCoveredCards(_ placements: [CardPlacement]) {
        var topmostAt: [String: Int] = [:]
        let stacked: Set<PileKind> = [.stock, .foundation, .waste]
        for placement in placements where stacked.contains(placement.pile.kind) {
            let key = "\(placement.pile.kind)-\(placement.pile.index)"
            topmostAt[key] = max(topmostAt[key] ?? -1, placement.indexInPile)
        }
        // How many waste cards are fanned out to the right of the pile's slot:
        // all of them are on show, the one under the lowest as well.
        let wasteBase = boardLayout.frame(of: .waste).minX
        let fannedWaste = placements.filter { $0.pile.kind == .waste && $0.frame.minX > wasteBase + 0.5 }.count + 1
        for placement in placements {
            guard let cardLayer = cardLayers[placement.card.code], !cardLayer.isHeld else { continue }
            let key = "\(placement.pile.kind)-\(placement.pile.index)"
            guard let top = topmostAt[key] else {
                cardLayer.isHidden = false
                continue
            }
            let showing = placement.pile.kind == .waste ? fannedWaste : 1
            cardLayer.isHidden = placement.indexInPile < top - showing
        }
    }

    /// Keeps the sublayer array in the same order as `zPosition`.
    ///
    /// The compositor honours `zPosition` on screen, so this changes nothing
    /// visually — but `CALayer.render(in:)`, which is how the board is captured
    /// off-screen, walks the sublayer array and ignores `zPosition` entirely.
    /// Without this the two disagree and a screenshot shows cards stacked in
    /// the wrong order.
    ///
    /// The cards are not the only sublayers. AppKit parks whatever `draw(_:)`
    /// painted — the felt — in a private sublayer of its own, and the win
    /// cascade adds one for its trails. Overwriting `sublayers` with just the
    /// cards throws those away, which is what left the table grey after
    /// practically every move. So the foreign layers are kept, split around the
    /// cards by the same `zPosition` this whole function exists to agree with.
    private func sortSublayers(by placements: [CardPlacement]) {
        guard let root = layer else { return }
        let ordered = placements.compactMap { cardLayers[$0.card.code] }
        guard ordered.count == cardLayers.count else { return }

        let cards = Set(cardLayers.values.map(ObjectIdentifier.init))
        let foreign = (root.sublayers ?? []).filter { !cards.contains(ObjectIdentifier($0)) }
        let desired = foreign.filter { $0.zPosition <= 0 }
            + ordered
            + foreign.filter { $0.zPosition > 0 }

        guard root.sublayers?.count != desired.count
            || !zip(root.sublayers ?? [], desired).allSatisfy({ $0 === $1 }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = desired
        CATransaction.commit()
    }

    /// Marks the background for redraw, but only if it would come out
    /// different from what is already on screen.
    private func invalidateBackgroundIfNeeded() {
        var hasher = Hasher()
        hasher.combine(bounds.width)
        hasher.combine(bounds.height)
        hasher.combine(topInset)
        hasher.combine(bottomInset)
        hasher.combine(theme.table)
        hasher.combine(game.state.stock.isEmpty)
        hasher.combine(game.state.hasRedealsRemaining)
        for foundation in game.state.foundations { hasher.combine(foundation > 0) }
        for column in game.state.tableau { hasher.combine(column.isEmpty) }
        let signature = hasher.finalize()
        guard signature != backgroundSignature else { return }
        backgroundSignature = signature
        needsDisplay = true
    }

    // MARK: Background

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawFelt(in: ctx)
        drawEmptySlots(in: ctx)
    }

    private func drawFelt(in ctx: CGContext) {
        let band = min(topInset, bounds.height)
        TableSurface.paintTopBand(in: bounds, height: band, context: ctx)
        let table = CGRect(x: bounds.minX, y: bounds.minY + band, width: bounds.width,
                           height: max(1, bounds.height - band))
        if theme.apple {
            AppleStyle.drawTable(theme.table, in: table, context: ctx,
                                 cardWidth: boardLayout.cardWidth)
            return
        }
        let (center, edge) = theme.table.gradient
        ctx.setFillColor(edge.cgColor)
        ctx.fill(table)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [center.cgColor, edge.cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        let mid = CGPoint(x: table.midX, y: table.midY)
        ctx.saveGState()
        ctx.clip(to: table)
        ctx.drawRadialGradient(
            gradient,
            startCenter: mid, startRadius: 0,
            endCenter: mid, endRadius: max(table.width, table.height) * 0.72,
            options: [.drawsAfterEndLocation]
        )
        ctx.restoreGState()
    }

    private func drawEmptySlots(in ctx: CGContext) {
        for slot in boardLayout.pileSlots {
            let occupied: Bool
            switch slot.pile.kind {
            case .stock: occupied = !game.state.stock.isEmpty
            case .waste: occupied = !game.state.waste.isEmpty
            case .foundation: occupied = game.state.foundations[slot.pile.index] > 0
            case .tableau: occupied = !game.state.tableau[slot.pile.index].isEmpty
            }
            if occupied && slot.pile.kind != .stock { continue }

            let rect = slot.frame.insetBy(dx: 1, dy: 1)
            let path = CGPath(roundedRect: rect, cornerWidth: boardLayout.cornerRadius,
                              cornerHeight: boardLayout.cornerRadius, transform: nil)
            if !occupied {
                if theme.apple {
                    AppleStyle.drawSlot(path, in: rect, context: ctx)
                } else {
                    ctx.addPath(path)
                    ctx.setFillColor(theme.emptySlotFill.cgColor)
                    ctx.fillPath()
                    ctx.addPath(path)
                    ctx.setStrokeColor(theme.emptySlotStroke.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.strokePath()
                }
            }

            switch slot.pile.kind {
            case .foundation where !occupied:
                // A ghost of the suit that belongs here, so the player never has
                // to remember which foundation is which.
                let suit = Suit(rawValue: UInt8(slot.pile.index))!
                let side = rect.width * 0.42
                let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                 width: side, height: side)
                let glyph = SuitPath.path(for: suit, in: box)
                if theme.apple {
                    AppleStyle.engrave(glyph, in: rect, context: ctx)
                } else {
                    ctx.addPath(glyph)
                    ctx.setFillColor(theme.emptySlotGlyph.cgColor)
                    ctx.fillPath()
                }
            case .stock where !occupied:
                drawStockGlyph(in: rect, context: ctx)
            default:
                break
            }
        }
    }

    // MARK: Drop target

    /// The outline a tableau highlight needs is the whole column, not the one
    /// slot at the top of it, so the fan has to be measured back out.
    private func dropGlowPath(for pile: PileID) -> CGPath {
        var rect = boardLayout.frame(of: pile)
        if pile.kind == .tableau {
            let column = game.state.tableau[pile.index]
            let (down, up) = boardLayout.fanOffsets(column: column)
            rect.size.height += CGFloat(column.down.count) * down
                + CGFloat(max(0, column.up.count - 1)) * up
        }
        return CGPath(roundedRect: rect.insetBy(dx: -2, dy: -2),
                      cornerWidth: boardLayout.cornerRadius + 2,
                      cornerHeight: boardLayout.cornerRadius + 2, transform: nil)
    }

    /// Fades the outline in over the pile the cards would land on, and out
    /// again when they would not land anywhere.
    ///
    /// The path is set even while fading out, because a shape layer with no
    /// path has nothing to fade — dropping it would make the outline vanish
    /// rather than dim.
    private func updateDropGlow() {
        let colour = (theme.apple ? theme.appleDropTargetColor : theme.dropTargetColor).cgColor
        dropGlow.strokeColor = colour
        dropGlow.shadowColor = colour
        dropGlow.shadowRadius = boardLayout.cornerRadius * 0.9

        CATransaction.begin()
        CATransaction.setDisableActions(!animationsEnabled)
        CATransaction.setAnimationDuration(Timing.glowFade)
        if let highlight = dropHighlight {
            dropGlow.path = dropGlowPath(for: highlight)
        }
        dropGlow.opacity = dropHighlight == nil ? 0 : 1
        CATransaction.commit()
    }

    /// A circular arrow when the waste can be turned back over, a plain cross
    /// when the deal has run out of passes.
    private func drawStockGlyph(in rect: CGRect, context ctx: CGContext) {
        let side = rect.width * 0.40
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side / 2
        let width = max(1.6, rect.width * 0.030)

        // Built as a path rather than stroked straight onto the context, so
        // Apple mode can cut the same shape into the felt instead of painting
        // it on. The geometry has one description either way.
        let glyph = CGMutablePath()
        if game.state.hasRedealsRemaining {
            glyph.addArc(center: center, radius: radius,
                         startAngle: -.pi * 0.35, endAngle: .pi * 1.15, clockwise: false)
            // Arrow head at the open end of the arc.
            let tip = CGPoint(x: center.x + radius * cos(-.pi * 0.35),
                              y: center.y + radius * sin(-.pi * 0.35))
            let barb = radius * 0.42
            glyph.move(to: CGPoint(x: tip.x - barb * 0.2, y: tip.y - barb))
            glyph.addLine(to: tip)
            glyph.addLine(to: CGPoint(x: tip.x + barb, y: tip.y + barb * 0.1))
        } else {
            glyph.move(to: CGPoint(x: center.x - radius, y: center.y - radius))
            glyph.addLine(to: CGPoint(x: center.x + radius, y: center.y + radius))
            glyph.move(to: CGPoint(x: center.x + radius, y: center.y - radius))
            glyph.addLine(to: CGPoint(x: center.x - radius, y: center.y + radius))
        }

        if theme.apple {
            AppleStyle.engrave(glyph, in: rect, context: ctx, stroke: width)
            return
        }
        ctx.addPath(glyph)
        ctx.setStrokeColor(theme.emptySlotGlyph.cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard !isPerformingSequence else { return }
        clearHint()
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        lastDragPoint = point
        dragLean = .zero
        isDragging = false
        pendingTarget = boardLayout.target(at: point, state: game.state, placements: placements)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isPerformingSequence else { return }
        let point = convert(event.locationInWindow, from: nil)

        if !isDragging {
            guard hypot(point.x - dragStart.x, point.y - dragStart.y) > 3.5 else { return }
            guard beginDrag(from: pendingTarget) else { return }
            isDragging = true
        }

        let dx = point.x - dragStart.x
        let dy = point.y - dragStart.y
        // Apple mode leans the cards into the direction of travel. The velocity
        // is smoothed heavily before it is used: the raw step between two mouse
        // events is noisy enough that feeding it straight in makes the card
        // shiver rather than lean.
        if theme.apple {
            let step = CGVector(dx: point.x - lastDragPoint.x, dy: point.y - lastDragPoint.y)
            dragLean = CGVector(dx: dragLean.dx * 0.72 + step.dx * 0.28,
                                dy: dragLean.dy * 0.72 + step.dy * 0.28)
        }
        lastDragPoint = point

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for card in heldCards {
            guard let cardLayer = cardLayers[card.code], let origin = heldOrigin[card.code] else { continue }
            cardLayer.position = CGPoint(x: origin.x + dx, y: origin.y + dy)
            if theme.apple { cardLayer.setDragLean(dx: dragLean.dx, dy: dragLean.dy) }
        }
        CATransaction.commit()

        let newHighlight = currentDropTarget()
        if newHighlight != dropHighlight {
            dropHighlight = newHighlight
            updateDropGlow()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isPerformingSequence else { return }
        defer {
            isDragging = false
            dropHighlight = nil
            updateDropGlow()
        }

        if isDragging {
            finishDrag()
            invalidateBackgroundIfNeeded()
            return
        }

        // A plain click. This is the way the game is meant to be played: the
        // card works out where it should go and goes there.
        guard let move = game.autoMove(for: pendingTarget) else {
            shake(pendingTarget)
            return
        }
        perform(move)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isPerformingSequence else { return }
        // Right-click always means "send it up", never "build the tableau".
        let point = convert(event.locationInWindow, from: nil)
        let target = boardLayout.target(at: point, state: game.state, placements: placements)
        switch target {
        case .tableauCard(let column, 0):
            if game.state.isLegal(.tableauToFoundation(column: column)) {
                perform(.tableauToFoundation(column: column))
            }
        case .waste:
            if game.state.isLegal(.wasteToFoundation) { perform(.wasteToFoundation) }
        default:
            break
        }
    }

    // MARK: Dragging

    private func beginDrag(from target: ClickTarget) -> Bool {
        var cards: [Card] = []
        switch target {
        case .waste:
            guard let card = game.state.waste.last else { return false }
            cards = [card]
            heldSource = .waste
        case .tableauCard(let column, let depth):
            let up = game.state.tableau[column].up
            guard depth < up.count else { return false }
            cards = Array(up.suffix(depth + 1))
            heldSource = .tableau(column)
        case .foundation(let index):
            guard let card = game.state.foundationTop(index) else { return false }
            cards = [card]
            heldSource = .foundation(index)
        case .stock, .emptyTableau, .nothing:
            return false
        }

        heldCards = cards
        heldOrigin.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, card) in cards.enumerated() {
            guard let cardLayer = cardLayers[card.code] else { continue }
            // A card can still be settling from the move before this one. The
            // drag has to take it over from a standstill, or the leftover
            // animation keeps writing over the position the mouse is setting.
            cardLayer.stopGliding()
            cardLayer.isHeld = true
            cardLayer.zPosition = 2000 + CGFloat(i)
            cardLayer.updateShadow(cornerRadius: boardLayout.cornerRadius, lifted: true)
            heldOrigin[card.code] = cardLayer.position
            cardLayer.setPickedUp(true, duration: animationsEnabled ? Timing.pickUp : 0)
        }
        CATransaction.commit()
        return true
    }

    private func currentDropTarget() -> PileID? {
        guard let first = heldCards.first, let cardLayer = cardLayers[first.code] else { return nil }
        let rect = CGRect(x: cardLayer.position.x - cardLayer.bounds.width / 2,
                          y: cardLayer.position.y - cardLayer.bounds.height / 2,
                          width: cardLayer.bounds.width, height: cardLayer.bounds.height)
        guard let pile = boardLayout.dropTarget(for: rect, state: game.state) else { return nil }
        return move(to: pile) == nil ? nil : pile
    }

    /// The move that dropping the held cards on `pile` would make, if legal.
    private func move(to pile: PileID) -> Move? {
        guard let source = heldSource, let bottom = heldCards.first else { return nil }
        let count = heldCards.count
        switch (source.kind, pile.kind) {
        case (.waste, .foundation):
            return game.state.isLegal(.wasteToFoundation) ? .wasteToFoundation : nil
        case (.waste, .tableau):
            let move = Move.wasteToTableau(column: pile.index)
            return game.state.isLegal(move) ? move : nil
        case (.tableau, .foundation):
            guard count == 1 else { return nil }
            let move = Move.tableauToFoundation(column: source.index)
            return game.state.isLegal(move) ? move : nil
        case (.tableau, .tableau):
            let move = Move.tableauToTableau(from: source.index, to: pile.index, count: count)
            return game.state.isLegal(move) ? move : nil
        case (.foundation, .tableau):
            let move = Move.foundationToTableau(suit: bottom.suit, column: pile.index)
            return game.state.isLegal(move) ? move : nil
        default:
            return nil
        }
    }

    private func finishDrag() {
        let target = currentDropTarget()
        releaseHeldCards()

        if let target, let move = move(to: target) {
            heldCards.removeAll()
            heldSource = nil
            perform(move)
            return
        }
        heldCards.removeAll()
        heldSource = nil
        relayout(animated: true, duration: Timing.snapBack)
    }

    private func releaseHeldCards() {
        for card in heldCards {
            guard let cardLayer = cardLayers[card.code] else { continue }
            cardLayer.isHeld = false
            cardLayer.updateShadow(cornerRadius: boardLayout.cornerRadius, lifted: false)
            cardLayer.setPickedUp(false, duration: animationsEnabled ? Timing.pickUp : 0)
        }
    }

    // MARK: Performing moves

    @discardableResult
    func perform(_ move: Move) -> Bool {
        // Both have to be read before the move: the score to difference
        // against, and the destination because a move to "a foundation" does
        // not say which one until you look at the card still on the source.
        let scoreBefore = game.score
        let destination = move.destination(in: game.state)

        guard let record = game.perform(move) else { return false }
        Sound.play(for: move)
        announceMove(record)
        relayout(animated: true)
        showScoreChange(game.score - scoreBefore, at: destination, movedCard: record.movedCard)
        invalidateBackgroundIfNeeded()
        delegate?.boardViewDidChangeGame(self)
        if game.isWon { startWinAnimation() }
        return true
    }

    /// Floats the change off the card that earned it.
    ///
    /// The difference in `game.score` is used rather than the nominal points,
    /// because standard scoring refuses to go below zero: a −100 recycle at a
    /// score of 40 costs 40, and showing the player −100 for it would not match
    /// the number they are watching in the status bar.
    private func showScoreChange(_ delta: Int, at destination: PileID, movedCard: Card?) {
        guard delta != 0, animationsEnabled, let root = layer else { return }
        // Prefer the card itself: on a fanned tableau column the pile's slot is
        // at the top and the card landed a long way below it.
        let frame = movedCard
            .flatMap { card in placements.first { $0.card == card }?.frame }
            ?? boardLayout.frame(of: destination)
        scoreFloats.show(
            delta,
            currency: game.options.scoring.isCurrency,
            at: CGPoint(x: frame.midX, y: frame.minY - boardLayout.cardSize.height * 0.14),
            size: max(11, boardLayout.cardSize.width * 0.26),
            in: root,
            theme: theme,
            scale: backingScale
        )
    }

    func undo() {
        guard !isPerformingSequence, game.undo() else { return }
        stopWinAnimation()
        Sound.play(.slide)
        relayout(animated: true)
        invalidateBackgroundIfNeeded()
        delegate?.boardViewDidChangeGame(self)
    }

    func redo() {
        guard !isPerformingSequence, game.redo() else { return }
        stopWinAnimation()
        Sound.play(.slide)
        relayout(animated: true)
        invalidateBackgroundIfNeeded()
        delegate?.boardViewDidChangeGame(self)
        if game.isWon { startWinAnimation() }
    }

    // MARK: Hint

    func showHint() {
        guard !isPerformingSequence else { return }
        clearHint()
        guard let move = game.hint() else {
            NSSound.beep()
            return
        }
        var cards: [Card] = []
        switch move {
        case .wasteToFoundation, .wasteToTableau:
            if let card = game.state.waste.last { cards = [card] }
        case .tableauToFoundation(let column):
            if let card = game.state.tableau[column].topCard { cards = [card] }
        case .tableauToTableau(let from, _, let count):
            cards = Array(game.state.tableau[from].up.suffix(count))
        case .foundationToTableau(let suit, _):
            if let card = game.state.foundationTop(Int(suit.rawValue)) { cards = [card] }
        case .draw, .recycle:
            cards = game.state.stock.suffix(1)
        }
        hintedCards = Set(cards.map(\.code))
        pulse(cards)
    }

    private func pulse(_ cards: [Card]) {
        for card in cards {
            guard let cardLayer = cardLayers[card.code] else { continue }
            let glow = CABasicAnimation(keyPath: "shadowColor")
            glow.fromValue = NSColor.black.cgColor
            glow.toValue = theme.hintColor.cgColor
            glow.autoreverses = true
            glow.duration = 0.42
            glow.repeatCount = 2
            let strength = CABasicAnimation(keyPath: "shadowOpacity")
            strength.fromValue = cardLayer.shadowOpacity
            strength.toValue = 1.0
            strength.autoreverses = true
            strength.duration = 0.42
            strength.repeatCount = 2
            let radius = CABasicAnimation(keyPath: "shadowRadius")
            radius.fromValue = cardLayer.shadowRadius
            radius.toValue = cardLayer.bounds.width * 0.18
            radius.autoreverses = true
            radius.duration = 0.42
            radius.repeatCount = 2
            cardLayer.add(glow, forKey: "hintColor")
            cardLayer.add(strength, forKey: "hintOpacity")
            cardLayer.add(radius, forKey: "hintRadius")
        }
    }

    private func clearHint() {
        for code in hintedCards {
            cardLayers[code]?.removeAnimation(forKey: "hintColor")
            cardLayers[code]?.removeAnimation(forKey: "hintOpacity")
            cardLayers[code]?.removeAnimation(forKey: "hintRadius")
        }
        hintedCards.removeAll()
    }

    /// Refuses a move with a short horizontal shake, which reads as "no"
    /// without needing a sound or a dialog.
    private func shake(_ target: ClickTarget) {
        let card: Card?
        switch target {
        case .waste: card = game.state.waste.last
        case .tableauCard(let column, let depth):
            let up = game.state.tableau[column].up
            card = depth < up.count ? up[up.count - 1 - depth] : nil
        default: card = nil
        }
        guard let card, let cardLayer = cardLayers[card.code], animationsEnabled else { return }
        let shake = CAKeyframeAnimation(keyPath: "position.x")
        let x = cardLayer.position.x
        shake.values = [x, x - 5, x + 4, x - 3, x + 2, x]
        shake.keyTimes = [0, 0.15, 0.35, 0.55, 0.78, 1]
        shake.duration = 0.26
        cardLayer.add(shake, forKey: "shake")
    }

    // MARK: Sequences

    private func runDealAnimation() {
        isPerformingSequence = true
        boardLayout = BoardLayout(bounds: layoutBounds)
        placements = boardLayout.placements(for: game.state)
        let stockFrame = boardLayout.frame(of: .stock)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for placement in placements {
            guard let cardLayer = cardLayers[placement.card.code] else { continue }
            cardLayer.bounds = CGRect(origin: .zero, size: placement.frame.size)
            cardLayer.cornerRadius = boardLayout.cornerRadius
            cardLayer.updateShadow(cornerRadius: boardLayout.cornerRadius, lifted: false)
            cardLayer.setFace(false, renderer: renderer)
            cardLayer.position = CGPoint(x: stockFrame.midX, y: stockFrame.midY)
            cardLayer.zPosition = CGFloat(placement.z)
        }
        CATransaction.commit()
        needsDisplay = true

        // Deal in the order the cards land, so the table fills the way a dealer
        // would fill it.
        let dealt = placements.filter { $0.pile.kind == .tableau }
            .sorted { ($0.indexInPile, $0.pile.index) < ($1.indexInPile, $1.pile.index) }

        for (i, placement) in dealt.enumerated() {
            guard let cardLayer = cardLayers[placement.card.code] else { continue }
            let delay = Double(i) * Timing.dealStagger
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                cardLayer.zPosition = CGFloat(placement.z) + 600
                cardLayer.glide(
                    to: CGPoint(x: placement.frame.midX, y: placement.frame.midY),
                    duration: Timing.deal,
                    timing: CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
                )
                cardLayer.lift(for: Timing.deal)
                CATransaction.setCompletionBlock {
                    cardLayer.zPosition = CGFloat(placement.z)
                    if placement.faceUp {
                        cardLayer.flip(to: true, renderer: self.renderer, duration: Timing.flip)
                    }
                }
                CATransaction.commit()
                Sound.play(.deal)
            }
        }

        let total = Double(dealt.count) * Timing.dealStagger + Timing.deal + Timing.flip
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            guard let self else { return }
            self.isPerformingSequence = false
            self.relayout(animated: false)
        }
    }

    /// Plays every remaining card to the foundations, one step at a time so the
    /// player can watch the board empty out. The whole run is a single undo.
    func autoFinish() {
        guard !isPerformingSequence, game.canAutoFinish else { return }
        isPerformingSequence = true
        isAutoFinishing = true
        idleStockMoves = 0
        game.beginUndoGroup()
        stepAutoFinish()
    }

    /// True from the first step of an auto-finish to its end.
    private var isAutoFinishing = false

    /// Whether a sequence may start something that runs on its own for a
    /// while — the win cascade's display link. The game turns it off while it
    /// is not the active screen of a key, visible window (the energy rule),
    /// and a win that lands meanwhile is reported at once instead, trails and
    /// all skipped.
    var allowsLiveAnimation = true

    /// Plays whatever is left of a running auto-finish at once, with no
    /// animation, and closes its undo group — for a player who walks away
    /// from the table mid-sequence. Nothing is left ticking behind them.
    func finishAutoFinishNow() {
        guard isAutoFinishing else { return }
        while idleStockMoves <= game.state.stock.count + game.state.waste.count + 2,
              let move = game.state.autoFinishMove(), game.perform(move) != nil {
            idleStockMoves = move.isStockCycling ? idleStockMoves + 1 : 0
        }
        relayout(animated: false)
        invalidateBackgroundIfNeeded()
        endAutoFinish()
    }

    /// Consecutive stock draws and recycles without a card reaching a
    /// foundation. Auto-finish is allowed to turn cards over looking for one,
    /// but if a whole pass goes by with no progress something is wrong and the
    /// sequence stops rather than spinning for ever.
    private var idleStockMoves = 0

    private func stepAutoFinish() {
        // Finished early by `finishAutoFinishNow`; this is the step that was
        // already waiting when it did.
        guard isAutoFinishing else { return }
        let cycleAllowance = game.state.stock.count + game.state.waste.count + 2
        guard idleStockMoves <= cycleAllowance, let move = game.state.autoFinishMove() else {
            endAutoFinish()
            return
        }
        guard game.perform(move) != nil else {
            endAutoFinish()
            return
        }
        idleStockMoves = move.isStockCycling ? idleStockMoves + 1 : 0
        Sound.play(for: move)
        let duration = Timing.autoFinishStep * 1.6
        relayout(animated: true, duration: duration)
        invalidateBackgroundIfNeeded()
        delegate?.boardViewDidChangeGame(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.autoFinishStep) { [weak self] in
            self?.stepAutoFinish()
        }
    }

    /// Closes the undo group and hands the board back to the player. Every way
    /// out of the sequence — nothing left to play, a move the rules refused,
    /// or a cycle that got nowhere — ends here.
    private func endAutoFinish() {
        guard isAutoFinishing else { return }
        isAutoFinishing = false
        game.endUndoGroup()
        isPerformingSequence = false
        delegate?.boardViewDidChangeGame(self)
        if game.isWon { startWinAnimation() }
    }

    // MARK: Win

    private var cascade: WinCascade?

    private func startWinAnimation() {
        guard animationsEnabled, allowsLiveAnimation else {
            delegate?.boardView(self, didFinishWinAnimation: true)
            return
        }
        isPerformingSequence = true
        Sound.play(.win)
        let cascade = WinCascade(view: self, cardLayers: cardLayers, layout: boardLayout, state: game.state)
        self.cascade = cascade
        cascade.start { [weak self] in
            guard let self else { return }
            self.isPerformingSequence = false
            // The cascade is deliberately kept alive here. It has freed
            // everything expensive, and what is left of it is the one handle on
            // the trails still painted across the table — release it and they
            // stay there for the rest of the session.
            self.delegate?.boardView(self, didFinishWinAnimation: true)
        }
    }

    /// Brings a win animation that is still flying to its end at once, as if
    /// it had finished on its own — the win is reported, the trails stay.
    func finishWinAnimationNow() {
        cascade?.finishNow()
    }

    /// Takes the win animation off the board, whether it is still flying or
    /// finished minutes ago. Every route out of a won game goes through here.
    func stopWinAnimation() {
        cascade?.stop()
        cascade = nil
        isPerformingSequence = false
    }

    /// Whether the win cascade's display link exists right now. For the
    /// harness's energy checks.
    var isWinAnimationRunning: Bool { cascade?.isRunning ?? false }

    // MARK: Keyboard

    /// Bare keys are handled here rather than as menu key equivalents. A menu
    /// key equivalent is dispatched ahead of the responder chain, so a bare
    /// "h" or space would be swallowed before it could reach the deal-number
    /// field in a dialog.
    override func keyDown(with event: NSEvent) {
        guard !isPerformingSequence, !event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            if !game.state.stock.isEmpty {
                perform(.draw(count: game.options.drawCount))
            } else if game.state.canRecycle {
                perform(.recycle)
            } else {
                NSSound.beep()
            }
        case "h":
            showHint()
        case "\u{1b}":      // Escape cancels a drag in progress
            cancelDrag()
        default:
            super.keyDown(with: event)
        }
    }

    private func cancelDrag() {
        guard isDragging else { return }
        releaseHeldCards()
        heldCards.removeAll()
        heldSource = nil
        isDragging = false
        dropHighlight = nil
        updateDropGlow()
        relayout(animated: true, duration: Timing.snapBack)
    }

    // MARK: Accessibility

    override func accessibilityLabel() -> String? {
        NSLocalizedString("Solitaire table", comment: "accessibility")
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityChildren() -> [Any]? { pileAccessibilityElements }
}
