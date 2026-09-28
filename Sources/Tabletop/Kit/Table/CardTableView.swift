//
//  CardTableView.swift
//  The base every card table in the collection is built on — Poker's,
//  Blackjack's, Durak's. (Solitaire's board predates it and keeps its own.)
//
//  WHAT IT DOES FOR A GAME
//
//  * Paints the table. The cloth, the rail and the room are painted once per
//    size and cloth colour into a bitmap and blitted from then on; a move
//    never repaints them. `shape` picks the table (`.rectangular`, `.oval`,
//    `.halfMoon()`), `paintBackground(in:rect:)` is the hook for printing
//    something of the game's own on top, and the View menu's cloth is
//    followed live.
//  * Holds the cards. Each card on the table is a sprite — a `CardLayer` —
//    under an `Int` id the game chooses (a six-deck shoe has six aces of
//    spades, so the card itself cannot be the key). `place` sends a sprite
//    somewhere, turned and face up or down, animated or not; the view works
//    out the rest: the flight over other cards, the flip at the right moment,
//    the stacking order once it lands.
//  * Answers the pointer. Clicks, hovers and drags arrive at overridable
//    hooks with sprite ids attached (`spriteClicked`, `draggableSprites`,
//    `spritesDropped`, …); hit testing respects each card's turn and height.
//  * Keeps time. `scheduler` is where deal sequences and bots' pauses go, so
//    a new game cancels the old one's in one call, and nothing ticks while
//    the table is out of sight.
//
//  HOW TO USE IT
//
//  Subclass it (prefix the name: `PokerTableView`), set `shape` and
//  `sizePolicy` in `init`, and override `layoutTable()` to place every
//  sprite from the game's model — it runs on every resize with animation
//  forced off. For moves, call `place` with a duration. Chrome goes on top as
//  subviews (`ActionBar.install(in:)`, `SeatView`, banners, `TableBadge`):
//  anything added with `addSubview` sits above the cards. Chips and other
//  drawn things that belong *on* the cloth go in through
//  `addTableLayer(_:z:)` — z below zero for under the cards (see
//  `tableLayer` for the ranges).
//
//  Keep `bottomReserve` constant for a table's life if you can: it is part of
//  the layout, and changing it resizes every card. With an `ActionBar`, set
//  its `minimumContentHeight` to the tallest accessory it will ever carry and
//  feed its `reservedHeight` in once.
//
//  Everything here also renders correctly through `CALayer.render(in:)`, so
//  `--shot` pictures of a table are faithful.
//

import AppKit
import QuartzCore

class CardTableView: NSView {

    // MARK: Configuration

    /// Which table to paint. Changing it repaints and relays the table.
    var shape: TableShape = .rectangular {
        didSet { if shape != oldValue { needsLayout = true; invalidateBackground() } }
    }

    /// Points along the bottom kept clear of the table itself — an action
    /// bar's `reservedHeight`. The oval and half-moon shrink to fit above it.
    ///
    /// A change here is a new layout: every card is resized and re-drawn,
    /// the table moves, and cards still in flight land where they were
    /// going. So reserve for the tallest bar you will ever show
    /// (`ActionBar.minimumContentHeight`) rather than following the bar up
    /// and down as its accessories come and go.
    var bottomReserve: CGFloat = 0 {
        didSet { if bottomReserve != oldValue { needsLayout = true; invalidateBackground() } }
    }

    /// How big the cards are for the view's size.
    var sizePolicy = CardSizePolicy.standard {
        didSet { if sizePolicy != oldValue { needsLayout = true } }
    }

    /// The table's measurements for the current size: the cloth, its middle,
    /// the rail, the betting circles. Up to date inside `layoutTable()`.
    private(set) var geometry: TableGeometry

    /// What the View menu says the table and the cards look like.
    private(set) var theme: Theme

    /// Draws the cards. Its size is `cardSize`.
    private(set) var renderer: CardRenderer

    /// The size every card on the table is drawn at, from `sizePolicy`.
    var cardSize: CGSize { renderer.size }

    /// Deal sequences, bots' pauses, the beat before a result: schedule them
    /// here. Suspend it in `gameWillResignActive`, resume it in
    /// `gameDidBecomeActive`, `cancelAll()` it on a new game.
    let scheduler = TableScheduler()

    /// The layer the cards live in. Chip stacks, drop highlights and anything
    /// else that lies on the cloth go in here too — through
    /// `addTableLayer(_:z:)` — and everything in it, cards included, is
    /// stacked by one `zPosition`:
    ///
    ///     below 0          on the cloth, under every card: bet stacks, the
    ///                      pot, a drop target's outline, printed markers
    ///     0 … 9 999        resting cards — a pose's `z` (TableLayout's
    ///                      helpers start at `baseZ`, 0 by default)
    ///     5 000            `ChipFlight`'s chips in the air
    ///     10 000 + z       a card in flight (the view lifts it there)
    ///     20 000 +         cards being dragged
    ///
    /// So a stack at z −10 is always under the hand that overlaps it; put
    /// something at z 500 and it lies on top of every card below 500.
    var tableLayer: CALayer { surface.layer ?? CALayer() }

    /// Adds `layer` to the cloth at `z` (see `tableLayer` for the ranges),
    /// drawn at the window's backing scale and kept at it when the window
    /// changes display, and stacked in z order in screenshots too. The way to
    /// put a `ChipStackLayer` on the table.
    func addTableLayer(_ layer: CALayer, z: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = z
        layer.contentsScale = backingScale
        tableLayer.addSublayer(layer)
        CATransaction.commit()
        zOrderDirty = true
        needsLayout = true
    }

    /// The part of the view the game may play in: below the window's top
    /// strip, above `bottomReserve`.
    var playBounds: CGRect {
        let top = TabletopChrome.topInset(for: self)
        return CGRect(x: bounds.minX, y: bounds.minY + top, width: bounds.width,
                      height: max(1, bounds.height - top - bottomReserve))
    }

    // MARK: State

    private struct Sprite {
        let layer: CardLayer
        var pose: CardPose
        var faceUp: Bool
        var isPlayable = false
        var isSelected = false
        var isHoverable = false
        /// Bumped by every `place`, so a landing that has been overtaken by a
        /// newer move knows not to settle the card.
        var generation = 0
    }

    private let surface = CardSurfaceView()
    private var sprites: [Int: Sprite] = [:]
    private var hovered: Int?
    private var zOrderDirty = false
    private var isLayingOut = false
    /// Everything `layoutTable()` depends on, as of the last time it ran.
    private var lastLayoutKey = ""
    private var preferencesObserver: NSObjectProtocol?

    private var background: CGImage?
    private var backgroundKey = ""
    /// The backing scale the table's own layers were last drawn at.
    private var tableLayerScale: CGFloat = 0

    // Pointer
    private var pressedSprite: Int?
    private var pressPoint: CGPoint = .zero
    private var dragging: [Int] = []
    private var dragOrigins: [Int: CGPoint] = [:]
    private var lastDragPoint: CGPoint = .zero
    private var dragLean = CGVector.zero

    /// How far a hovered card rises, and a selected one, as fractions of the
    /// card's height — along the card's own "up", so a card in a fan rises
    /// out of the fan rather than straight up the screen.
    var hoverLift: CGFloat = 0.07
    var selectionLift: CGFloat = 0.16

    // MARK: Init

    init(shape: TableShape = .rectangular) {
        let theme = TablePreferences.current.theme
        self.theme = theme
        self.shape = shape
        let initialSize = CardSizePolicy.standard.cardSize(for: CGSize(width: 1200, height: 800))
        self.renderer = CardRenderer(theme: theme, size: initialSize, scale: 2)
        self.geometry = TableSurface.geometry(for: shape, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        super.init(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.backgroundColor = Palette.room.cgColor

        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: TablePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Hooks for subclasses

    /// Place every sprite where the game's model says it belongs. Called
    /// after every resize, backing-scale change and theme change, with
    /// `geometry` and `cardSize` already updated, and with animation forced
    /// off — any `place` made in here lands at once. Call it yourself (or
    /// `needsLayout = true`) is not needed after moves; use `place` with a
    /// duration for those.
    func layoutTable() {}

    /// Paints the table into the cached background. The default paints
    /// `shape` in the chosen cloth; override to add the game's own markings
    /// and call `super` first. `ctx` is top-left origin, in points.
    func paintBackground(in ctx: CGContext, rect: CGRect) {
        TableSurface.paint(geometry, cloth: theme.table, context: ctx, cardWidth: cardSize.width)
    }

    /// Anything else the painted background depends on — say, how many
    /// betting circles are marked. When it changes, call
    /// `invalidateBackground()`.
    func backgroundSignature() -> String { "" }

    /// The View menu changed the cloth or the cards. Sprites and background
    /// are already re-dressed; this is for anything the game painted itself.
    func tableThemeDidChange() {}

    /// A click on a card that did not turn into a drag: pressed on the card
    /// and released on it. Pressing a card and sliding off it before letting
    /// go is how a Mac user backs out of a click, and calls nothing.
    func spriteClicked(_ id: Int, with event: NSEvent) {}

    /// A click on the cloth, away from every card: pressed and released on
    /// bare cloth.
    func tableClicked(at point: CGPoint, with event: NSEvent) {}

    /// The pointer moved onto a card (`id`) or off every card (nil). Called
    /// for every card, hoverable or not.
    func spriteHoverChanged(to id: Int?) {}

    /// The player has started dragging card `id`. Return the ids to pick up
    /// — the card and everything that travels with it, bottom first — or nil
    /// if it cannot be dragged.
    func draggableSprites(startingAt id: Int) -> [Int]? { nil }

    /// The dragged cards moved; `point` is the pointer. For highlighting a
    /// drop target.
    func spritesDragged(_ ids: [Int], to point: CGPoint) {}

    /// The dragged cards were let go at `point`. Place them where they now
    /// belong and return true; return false and they fly back to where they
    /// were picked up from.
    func spritesDropped(_ ids: [Int], at point: CGPoint) -> Bool { false }

    /// A key the table did not claim for dragging. Return true if handled.
    /// Unhandled keys go to any `CapsuleButton` on the table whose key
    /// equivalent matches, then up the responder chain.
    func handleKeyDown(_ event: NSEvent) -> Bool { false }

    /// What VoiceOver calls card `id`. The default names face-up cards and
    /// calls face-down ones face-down; return nil to leave a card out.
    func accessibilityLabel(forSprite id: Int) -> String? {
        guard let sprite = sprites[id] else { return nil }
        return sprite.faceUp ? sprite.layer.card.accessibilityName
            : NSLocalizedString("Face-down card", comment: "accessibility: a card lying face down")
    }

    // MARK: Sprites

    /// All sprite ids, in no particular order.
    var spriteIDs: [Int] { Array(sprites.keys) }

    /// The layer for `id`, creating it for `card` if there is none, or
    /// switching an existing one to `card` if it shows something else. A new
    /// sprite starts face down at the middle of the table, out of sight until
    /// it is first placed.
    @discardableResult
    func sprite(id: Int, card: Card) -> CardLayer {
        if let existing = sprites[id] {
            existing.layer.setCard(card, renderer: renderer)
            return existing.layer
        }
        let layer = CardLayer(card: card)
        layer.apple = true
        layer.contentsScale = backingScale
        layer.bounds = CGRect(origin: .zero, size: cardSize)
        layer.cornerRadius = cornerRadius
        layer.updateShadow(cornerRadius: cornerRadius, lifted: false)
        layer.setFace(false, renderer: renderer)
        layer.position = geometry.center
        layer.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.addSublayer(layer)
        CATransaction.commit()
        sprites[id] = Sprite(layer: layer, pose: CardPose(position: geometry.center), faceUp: false)
        zOrderDirty = true
        needsLayout = true
        return layer
    }

    /// The layer for `id`, if there is one.
    func existingSprite(_ id: Int) -> CardLayer? { sprites[id]?.layer }

    /// Where `id` rests — its last placed pose, not wherever it is mid-flight.
    func pose(of id: Int) -> CardPose? { sprites[id]?.pose }

    /// Whether `id` is face up (or will be, once its current move lands).
    func isFaceUp(_ id: Int) -> Bool { sprites[id]?.faceUp ?? false }

    /// Sends `id` to `position`, turned `rotation` radians, stacked at `z`
    /// (nil keeps its current z), face up or down (nil keeps it). Starts
    /// after `delay`; takes `duration` — zero, or motion off, or a call from
    /// inside `layoutTable()`, and it lands at once. `completion` runs when
    /// it has landed. The card flies above everything else and drops into
    /// its stacking order when it lands.
    func place(_ id: Int, at position: CGPoint, rotation: CGFloat = 0, z: Int? = nil, faceUp: Bool? = nil,
               scale: CGFloat = 1, duration: CFTimeInterval = Motion.cardMove, delay: CFTimeInterval = 0,
               completion: (() -> Void)? = nil) {
        guard let current = sprites[id] else {
            completion?()
            return
        }
        var pose = CardPose(position: position, rotation: rotation, z: z ?? current.pose.z, scale: scale)
        pose.isHidden = false
        place(id, pose: pose, faceUp: faceUp, duration: duration, delay: delay, completion: completion)
    }

    /// `place` with a `CardPose` — straight from one of `TableLayout`'s
    /// helpers. A pose marked `isHidden` hides the card once it lands.
    func place(_ id: Int, pose: CardPose, faceUp: Bool? = nil, duration: CFTimeInterval = Motion.cardMove,
               delay: CFTimeInterval = 0, completion: (() -> Void)? = nil) {
        guard var sprite = sprites[id] else {
            completion?()
            return
        }
        sprite.pose = pose
        if let faceUp { sprite.faceUp = faceUp }
        sprite.generation += 1
        let generation = sprite.generation
        sprites[id] = sprite

        let animated = duration > 0 && Motion.isEnabled && !isLayingOut && window != nil
        let layer = sprite.layer
        if !pose.isHidden { layer.isHidden = false }
        // In flight, above everything that is lying still.
        layer.zPosition = animated ? CGFloat(10_000 + pose.z) : CGFloat(pose.z)
        zOrderDirty = true
        needsLayout = true

        let landed: () -> Void = { [weak self] in
            guard let self, let now = self.sprites[id], now.generation == generation else {
                completion?()
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            now.layer.zPosition = CGFloat(now.pose.z)
            now.layer.isHidden = now.pose.isHidden
            CATransaction.commit()
            self.zOrderDirty = true
            self.needsLayout = true
            completion?()
        }
        layer.move(to: effectivePosition(of: sprite), rotation: pose.rotation, scale: pose.scale, faceUp: sprite.faceUp,
                   renderer: renderer, duration: animated ? duration : 0, delay: animated ? delay : 0,
                   flipDuration: Motion.cardFlip, timing: Motion.easeOut, lift: animated, completion: landed)
    }

    /// Turns `id` over where it lies.
    func flip(_ id: Int, faceUp: Bool, duration: CFTimeInterval = Motion.cardFlip, delay: CFTimeInterval = 0,
              completion: (() -> Void)? = nil) {
        guard let sprite = sprites[id] else {
            completion?()
            return
        }
        place(id, pose: sprite.pose, faceUp: faceUp, duration: duration, delay: delay, completion: completion)
    }

    /// Takes `id` off the table — flying it to `point` and fading it on the
    /// way if given (a card going back into the shoe, a hand swept away).
    /// The id is free for reuse the moment this returns.
    func remove(_ id: Int, animatedTo point: CGPoint? = nil, duration: CFTimeInterval = Motion.cardMove,
                delay: CFTimeInterval = 0, completion: (() -> Void)? = nil) {
        guard let sprite = sprites.removeValue(forKey: id) else {
            completion?()
            return
        }
        if hovered == id { hovered = nil }
        let layer = sprite.layer
        guard let point, duration > 0, Motion.isEnabled, window != nil else {
            layer.removeFromSuperlayer()
            completion?()
            return
        }
        layer.zPosition = CGFloat(10_000 + sprite.pose.z)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration * 0.45
        fade.beginTime = CACurrentMediaTime() + delay + duration * 0.55
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "fadeOut")
        layer.move(to: point, rotation: sprite.pose.rotation, scale: sprite.pose.scale, faceUp: sprite.faceUp,
                   renderer: renderer, duration: duration, delay: delay, timing: Motion.easeIn, lift: true) {
            layer.removeFromSuperlayer()
            completion?()
        }
    }

    /// Takes every card off the table at once.
    func removeAllSprites() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sprite in sprites.values { sprite.layer.removeFromSuperlayer() }
        CATransaction.commit()
        sprites.removeAll()
        hovered = nil
        dragging.removeAll()
        pressedSprite = nil
    }

    // MARK: Highlights

    /// Marks exactly `ids` as playable — a warm glow under each, the kit's
    /// "you can play this". Every other card loses it.
    func setPlayable(_ ids: Set<Int>) {
        for (id, var sprite) in sprites where sprite.isPlayable != ids.contains(id) {
            sprite.isPlayable = ids.contains(id)
            sprites[id] = sprite
            applyGlow(sprite)
        }
    }

    /// Selects or deselects `id`: it rises out of its hand a little and
    /// takes a gold outline.
    func setSelected(_ id: Int, _ selected: Bool) {
        guard var sprite = sprites[id], sprite.isSelected != selected else { return }
        sprite.isSelected = selected
        sprites[id] = sprite
        applyGlow(sprite)
        reposition(id, duration: Motion.quick * 1.4)
    }

    /// The selected sprites.
    var selectedSprites: [Int] { sprites.filter { $0.value.isSelected }.map(\.key).sorted() }

    /// Which cards rise under the pointer — usually the player's own hand.
    func setHoverable(_ ids: Set<Int>) {
        for (id, var sprite) in sprites where sprite.isHoverable != ids.contains(id) {
            sprite.isHoverable = ids.contains(id)
            sprites[id] = sprite
            if !sprite.isHoverable && hovered == id {
                hovered = nil
                reposition(id, duration: Motion.quick)
            }
        }
    }

    private func applyGlow(_ sprite: Sprite) {
        let layer = sprite.layer
        CATransaction.begin()
        CATransaction.setDisableActions(!Motion.isEnabled)
        CATransaction.setAnimationDuration(Motion.quick)
        if sprite.isPlayable || sprite.isSelected {
            layer.shadowColor = Palette.accent.cgColor
            layer.shadowOpacity = sprite.isSelected ? 0.95 : 0.80
            layer.shadowRadius = cardSize.width * (sprite.isSelected ? 0.13 : 0.10)
            layer.shadowOffset = .zero
        } else {
            layer.shadowColor = NSColor.black.cgColor
            layer.updateShadow(cornerRadius: cornerRadius, lifted: false)
        }
        CATransaction.commit()
        setOutline(sprite.isSelected, on: layer)
    }

    /// The gold outline of a selected card: a sublayer, so it turns with the
    /// card.
    private func setOutline(_ visible: Bool, on layer: CardLayer) {
        let name = "tabletop.selection"
        let outline = layer.sublayers?.first { $0.name == name } as? CAShapeLayer
        guard visible else {
            outline?.removeFromSuperlayer()
            return
        }
        let ring = outline ?? CAShapeLayer()
        ring.name = name
        ring.fillColor = nil
        ring.strokeColor = Palette.accent.cgColor
        ring.lineWidth = max(1.5, cardSize.width * 0.028)
        ring.frame = layer.bounds
        let inset = -ring.lineWidth / 2
        ring.path = CGPath(roundedRect: layer.bounds.insetBy(dx: inset, dy: inset),
                           cornerWidth: cornerRadius - inset, cornerHeight: cornerRadius - inset, transform: nil)
        if outline == nil { layer.addSublayer(ring) }
    }

    /// Where a sprite actually sits: its pose, lifted along its own "up" if
    /// it is selected or under the pointer.
    private func effectivePosition(of sprite: Sprite) -> CGPoint {
        var lift: CGFloat = 0
        if sprite.isSelected { lift += selectionLift }
        if hovered.map({ sprites[$0]?.layer === sprite.layer }) == true && sprite.isHoverable { lift += hoverLift }
        guard lift > 0 else { return sprite.pose.position }
        let distance = lift * cardSize.height * sprite.pose.scale
        // "Up" for a card turned by r is (sin r, −cos r) in a y-down view.
        return CGPoint(x: sprite.pose.position.x + sin(sprite.pose.rotation) * distance,
                       y: sprite.pose.position.y - cos(sprite.pose.rotation) * distance)
    }

    /// Moves a sprite to its effective position without touching its pose —
    /// a hover or a selection changed.
    private func reposition(_ id: Int, duration: CFTimeInterval) {
        guard let sprite = sprites[id], !dragging.contains(id) else { return }
        let animated = Motion.isEnabled && window != nil
        sprite.layer.move(to: effectivePosition(of: sprite), rotation: sprite.pose.rotation, scale: sprite.pose.scale,
                          faceUp: sprite.faceUp, renderer: renderer, duration: animated ? duration : 0,
                          timing: Motion.easeOut, lift: false)
    }

    // MARK: Hit testing

    /// The topmost card at `point` (view coordinates), respecting each
    /// card's turn and stacking order, or nil for bare cloth. Hidden cards
    /// and cards being dragged are ignored.
    func sprite(at point: CGPoint) -> Int? {
        var best: (id: Int, z: CGFloat)?
        for (id, sprite) in sprites where !sprite.layer.isHidden && !dragging.contains(id) {
            let center = effectivePosition(of: sprite)
            guard sprite.layer.restingContains(point, at: center) else { continue }
            let z = CGFloat(sprite.pose.z)
            if best == nil || z > best!.z || (z == best!.z && id > best!.id) { best = (id, z) }
        }
        return best?.id
    }

    // MARK: Layout

    var cornerRadius: CGFloat { max(3, cardSize.width * 0.062) }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        let top = TabletopChrome.topInset(for: self)
        let newSize = sizePolicy.cardSize(for: playBounds.size)
        geometry = TableSurface.geometry(for: shape, in: bounds, topInset: top, bottomReserve: bottomReserve,
                                         cardWidth: newSize.width)
        let sizeChanged = newSize != cardSize || renderer.scale != backingScale
        let layoutKey = "\(bounds.size)|\(newSize)|\(shape)|\(bottomReserve)|\(top)|\(backingScale)"
        if tableLayerScale != backingScale {
            tableLayerScale = backingScale
            rescaleTableLayers()
        }
        if sizeChanged || layoutKey != lastLayoutKey {
            lastLayoutKey = layoutKey
            if sizeChanged { resizeCards(to: newSize) }
            isLayingOut = true
            layoutTable()
            isLayingOut = false
            invalidateBackgroundIfNeeded()
        }
        if zOrderDirty { sortSublayers() }
    }

    private func resizeCards(to size: CGSize) {
        renderer.update(theme: theme, size: size, scale: backingScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sprite in sprites.values {
            sprite.layer.contentsScale = backingScale
            sprite.layer.bounds = CGRect(origin: .zero, size: size)
            sprite.layer.cornerRadius = cornerRadius
            if !(sprite.isPlayable || sprite.isSelected) {
                sprite.layer.updateShadow(cornerRadius: cornerRadius, lifted: false)
            } else {
                sprite.layer.shadowPath = CGPath(roundedRect: sprite.layer.bounds, cornerWidth: cornerRadius,
                                                 cornerHeight: cornerRadius, transform: nil)
                applyGlow(sprite)
            }
            sprite.layer.refreshImage(renderer: renderer)
        }
        CATransaction.commit()
    }

    /// The game's own layers on the cloth follow the window to a display of
    /// another scale; a `ChipStackLayer` redraws itself when told.
    private func rescaleTableLayers() {
        let cards = Set(sprites.values.map { ObjectIdentifier($0.layer) })
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in tableLayer.sublayers ?? [] where !cards.contains(ObjectIdentifier(layer)) {
            layer.contentsScale = backingScale
        }
        CATransaction.commit()
    }

    /// Relays the whole table from the model, instantly. For after a new
    /// game has been set up, or anything else that moved everything.
    func relayoutTable() {
        isLayingOut = true
        layoutTable()
        isLayingOut = false
    }

    /// Keeps the sublayer array in `zPosition` order. The compositor honours
    /// `zPosition` on screen by itself, but `CALayer.render(in:)` — how a
    /// table is photographed — walks the array and ignores it.
    private func sortSublayers() {
        zOrderDirty = false
        guard let root = surface.layer, let layers = root.sublayers, layers.count > 1 else { return }
        let sorted = layers.enumerated().sorted {
            ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset)
        }.map(\.element)
        guard !zip(layers, sorted).allSatisfy({ $0 === $1 }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers = sorted
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        invalidateBackground()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidateBackground()
    }

    private func preferencesChanged() {
        theme = TablePreferences.current.theme
        renderer.update(theme: theme, size: cardSize, scale: backingScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sprite in sprites.values { sprite.layer.refreshImage(renderer: renderer) }
        CATransaction.commit()
        invalidateBackground()
        tableThemeDidChange()
    }

    // MARK: Background

    /// Repaints the table on the next display. Cheap to call; the painting
    /// itself only happens if the result would differ.
    func invalidateBackground() {
        backgroundKey = ""
        needsDisplay = true
    }

    private var currentBackgroundKey: String {
        let b = bounds.size
        return "\(shape)|\(Int(b.width))x\(Int(b.height))|\(theme.table.rawValue)|\(backingScale)|\(Int(cardSize.width))|\(Int(bottomReserve))|\(Int(TabletopChrome.topInset(for: self)))|\(backgroundSignature())"
    }

    private func invalidateBackgroundIfNeeded() {
        if currentBackgroundKey != backgroundKey { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let key = currentBackgroundKey
        // Dragging the window wider stretches the last picture rather than
        // painting a new table on every frame; the real one is painted when
        // the drag ends.
        if key != backgroundKey && !(inLiveResize && background != nil) {
            background = ChipRenderer.render(size: bounds.size, scale: backingScale) { ctx in
                self.paintBackground(in: ctx, rect: self.bounds)
            }
            backgroundKey = key
        }
        guard let background else { return }
        ctx.interpolationQuality = .medium
        TableArt.draw(background, in: bounds, context: ctx)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited,
                                                               .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    private func updateHover(at point: CGPoint?) {
        guard dragging.isEmpty else { return }
        let id = point.flatMap { sprite(at: $0) }
        guard id != hovered else { return }
        let previous = hovered
        hovered = id
        if let previous, sprites[previous]?.isHoverable == true { reposition(previous, duration: Motion.quick) }
        if let id, sprites[id]?.isHoverable == true { reposition(id, duration: Motion.quick) }
        spriteHoverChanged(to: id)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = point
        lastDragPoint = point
        dragLean = .zero
        pressedSprite = sprite(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragging.isEmpty {
            guard let id = pressedSprite, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4,
                  let ids = draggableSprites(startingAt: id), !ids.isEmpty else { return }
            beginDrag(ids)
        }
        let step = CGVector(dx: point.x - lastDragPoint.x, dy: point.y - lastDragPoint.y)
        dragLean = CGVector(dx: dragLean.dx * 0.72 + step.dx * 0.28, dy: dragLean.dy * 0.72 + step.dy * 0.28)
        lastDragPoint = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in dragging {
            guard let layer = sprites[id]?.layer, let origin = dragOrigins[id] else { continue }
            layer.position = CGPoint(x: origin.x + point.x - pressPoint.x, y: origin.y + point.y - pressPoint.y)
            layer.setDragLean(dx: dragLean.dx, dy: dragLean.dy)
        }
        CATransaction.commit()
        spritesDragged(dragging, to: point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !dragging.isEmpty {
            endDrag(at: point, cancelled: false)
            return
        }
        if let id = pressedSprite, sprites[id] != nil {
            // Released on the card it was pressed on (or near enough that it
            // never left it): a click. Slid off it first: nothing.
            if sprite(at: point) == id || hypot(point.x - pressPoint.x, point.y - pressPoint.y) <= 4 {
                spriteClicked(id, with: event)
            }
        } else if sprite(at: point) == nil {
            tableClicked(at: point, with: event)
        }
        pressedSprite = nil
    }

    private func beginDrag(_ ids: [Int]) {
        dragging = ids.filter { sprites[$0] != nil }
        dragOrigins.removeAll()
        hovered = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, id) in dragging.enumerated() {
            guard let layer = sprites[id]?.layer else { continue }
            let here = layer.presentation()?.position ?? layer.position
            layer.stopGliding()
            layer.position = here
            layer.isHeld = true
            layer.zPosition = CGFloat(20_000 + i)
            layer.updateShadow(cornerRadius: cornerRadius, lifted: true)
            layer.setPickedUp(true, duration: Motion.isEnabled ? 0.13 : 0)
            dragOrigins[id] = here
        }
        CATransaction.commit()
        zOrderDirty = true
        needsLayout = true
    }

    private func endDrag(at point: CGPoint, cancelled: Bool) {
        let ids = dragging
        for id in ids {
            guard let sprite = sprites[id] else { continue }
            sprite.layer.isHeld = false
            sprite.layer.setPickedUp(false, duration: Motion.isEnabled ? 0.13 : 0)
            if sprite.isPlayable || sprite.isSelected { applyGlow(sprite) }
            else { sprite.layer.updateShadow(cornerRadius: cornerRadius, lifted: false) }
        }
        dragging.removeAll()
        pressedSprite = nil
        let handled = !cancelled && spritesDropped(ids, at: point)
        if !handled {
            for id in ids {
                guard let sprite = sprites[id] else { continue }
                place(id, pose: sprite.pose, duration: 0.22)
            }
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !dragging.isEmpty {      // Escape puts a drag back
            endDrag(at: lastDragPoint, cancelled: true)
            return
        }
        if handleKeyDown(event) { return }
        // Bare-key buttons on the table (Fold, Hit…) get their say before the
        // key walks off up the responder chain.
        if performKeyEquivalent(with: event) { return }
        super.keyDown(with: event)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = subviews.filter { $0 !== surface }
        let ordered = sprites.sorted { ($0.value.pose.z, $0.key) < ($1.value.pose.z, $1.key) }
        for (id, sprite) in ordered where !sprite.layer.isHidden {
            guard let label = accessibilityLabel(forSprite: id) else { continue }
            let element = CardSpriteAccessibilityElement()
            element.table = self
            element.spriteID = id
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(label)
            element.setAccessibilityFrameInParentSpace(
                TableLayout.boundingBox(of: CardPose(position: effectivePosition(of: sprite),
                                                     rotation: sprite.pose.rotation, scale: sprite.pose.scale),
                                        cardSize: cardSize))
            children.append(element)
        }
        return children
    }

    /// VoiceOver pressed a card: the same as clicking it.
    fileprivate func accessibilityPress(_ id: Int) -> Bool {
        guard sprites[id] != nil,
              let event = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 0) else { return false }
        spriteClicked(id, with: event)
        return true
    }
}

/// The view the card layers live in: the first subview of every table, so
/// anything a game adds with `addSubview` sits above the cards. Clicks go
/// straight through it to the table.
final class CardSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One card, for VoiceOver.
final class CardSpriteAccessibilityElement: NSAccessibilityElement {
    weak var table: CardTableView?
    var spriteID = 0
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { table?.accessibilityPress(spriteID) ?? false }
    }
}
