//
//  PokerTableView.swift
//  The poker table: the oval, the seats round it, everyone's cards and
//  chips, the board and the pot — drawn from a `PokerScene`.
//
//  `show(_:)` puts a scene on the table at once; `layoutTable()` does the
//  same after a resize, from the scene already showing. Everything that
//  moves — a deal, a bet sliding out, the pot flying to a winner — is in
//  `PokerTableView+Play.swift`, which changes the scene a step at a time and
//  calls the `transition` below with a duration.
//
//  Sprite ids: the board is 40…44, and seat s holds 10 + 2s and 11 + 2s. A card keeps its id from the deal to the muck, so the view
//  can tell a card that moved from one that is new.
//

import AppKit
import QuartzCore

final class PokerTableView: CardTableView {

    /// What the table shows right now.
    private(set) var scene: PokerScene = .empty
    /// Where everything goes at the current size.
    private(set) var layoutModel: PokerLayout?

    let actionBar = ActionBar()
    /// Keys the table did not use itself — the game's shortcuts.
    var keyHandler: ((NSEvent) -> Bool)?
    /// The pill naming the player's hand (the menu's choice).
    var showsHandStrength = true {
        didSet { if showsHandStrength != oldValue { relayoutTable() } }
    }
    /// Something is being said over the whole table — the tournament's end —
    /// so the hand's own words (the result, the hand names) stand down
    /// rather than show through the glass.
    var isQuiet = false {
        didSet { if isQuiet != oldValue { relayoutTable() } }
    }

    private var seats: [SeatView] = []
    private var betStacks: [ChipStackLayer] = []
    private var potStacks: [ChipStackLayer] = []
    private var potLabels: [PokerCapsuleLabelLayer] = []
    private let dealerPuck = CALayer()
    private var captionBadges: [Int: TableBadge] = [:]
    private var handBadges: [Int: TableBadge] = [:]
    private var handPill: TableBadge?
    let resultPill = PokerResultPill()
    private var dimmed: Set<Int> = []

    static func holeID(seat: Int, card k: Int) -> Int { 10 + seat * 2 + k }
    static func boardID(_ i: Int) -> Int { 40 + i }

    init() {
        super.init(shape: .oval)
        sizePolicy = PokerLayout.cardPolicy
        hoverLift = 0.06
        // The bet control comes and goes with the player's turn; the bar
        // keeps its height regardless, so the table never resizes.
        actionBar.minimumContentHeight = BetControl.height
        actionBar.install(in: self)
        dealerPuck.contentsGravity = .resizeAspect
        dealerPuck.isHidden = true
        addTableLayer(dealerPuck, z: -6)
        addSubview(resultPill)
        setAccessibilityLabel(NSLocalizedString("Poker table", comment: "accessibility: the poker table"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func layout() {
        bottomReserve = actionBar.reservedHeight
        super.layout()
    }

    // MARK: Showing a scene

    /// Puts `scene` on the table at once, nothing animated.
    func show(_ scene: PokerScene) {
        let seatsChanged = scene.seats.count != self.scene.seats.count
            || zip(scene.seats, self.scene.seats).contains { $0.name != $1.name || $0.isHuman != $1.isHuman }
        self.scene = scene
        if seatsChanged { rebuildSeats() }
        relayoutTable()
    }

    override func layoutTable() {
        let layout = makeLayout()
        layoutModel = layout
        transition(to: scene, duration: 0)
        positionChrome(layout)
    }

    private func makeLayout() -> PokerLayout {
        // The bar's top edge, a few points of air above it.
        let barTop = bounds.maxY - actionBar.reservedHeight + Spacing.m - 6
        return PokerLayout(geometry: geometry, cardSize: cardSize, seatCount: max(2, scene.seats.count),
                           topLimit: playBounds.minY + 4, bottomLimit: barTop)
    }

    /// The cloth, with the board's five places printed on it faintly in the
    /// betting line's gold — so a flop of three reads as three of five, not
    /// as a row that has slipped to the left.
    override func paintBackground(in ctx: CGContext, rect: CGRect) {
        super.paintBackground(in: ctx, rect: rect)
        let layout = makeLayout()
        let w = cardSize.width * layout.boardScale + 7
        let h = cardSize.height * layout.boardScale + 7
        let radius = cornerRadius * layout.boardScale + 3.5
        ctx.saveGState()
        ctx.setLineWidth(1.1)
        ctx.setStrokeColor(NSColor(srgbRed: 0.95, green: 0.83, blue: 0.56, alpha: 0.17).cgColor)
        for pose in layout.board {
            let box = CGRect(x: pose.position.x - w / 2, y: pose.position.y - h / 2, width: w, height: h)
            ctx.addPath(ContinuousShape.roundedRect(box.insetBy(dx: 0.5, dy: 0.5), radius: radius))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Moves the table to `newScene`: cards that changed place glide there
    /// (new ones come from the dealer, gone ones go back), and the
    /// plates, chips and words change to match. `delays` holds up individual
    /// cards — a deal goes round the table one card at a time.
    func transition(to newScene: PokerScene, duration: CFTimeInterval, delays: [Int: CFTimeInterval] = [:],
                    muckDuration: CFTimeInterval? = nil) {
        let old = scene
        scene = newScene
        if newScene.seats.count != seats.count { rebuildSeats() }
        guard let layout = layoutModel else { return }

        var wanted = Set<Int>()
        let dealPose = layout.dealPose

        func put(_ id: Int, card: Card, pose: CardPose, faceUp: Bool) {
            wanted.insert(id)
            let isNew = existingSprite(id) == nil
            let layer = sprite(id: id, card: card)
            if isNew {
                // From the dealer's hands, face down.
                var start = dealPose
                start.z = pose.z
                place(id, pose: start, faceUp: false, duration: 0)
                layer.isHidden = false
            }
            let delay = delays[id] ?? 0
            if pose != self.pose(of: id) || faceUp != isFaceUp(id) || isNew {
                place(id, pose: pose, faceUp: faceUp, duration: duration, delay: delay)
            }
        }

        for (seat, s) in newScene.seats.enumerated() {
            let poses = layout.holePoses(seat: seat, revealed: s.revealed)
            for (k, card) in s.cards.prefix(2).enumerated() {
                put(Self.holeID(seat: seat, card: k), card: card, pose: lifted(poses[k], card: card), faceUp: s.faceUp)
            }
        }
        for (i, card) in newScene.board.prefix(5).enumerated() {
            put(Self.boardID(i), card: card, pose: lifted(layout.board[i], card: card), faceUp: true)
        }
        // Cards no longer in the scene go to the muck.
        for id in spriteIDs where !wanted.contains(id) {
            if duration > 0 {
                remove(id, animatedTo: layout.muck, duration: muckDuration ?? duration)
            } else {
                remove(id)
            }
        }
        // The player's own cards rise a touch under the pointer, the way a
        // player lifts a corner to look.
        let mine = newScene.seats.first.map { $0.isHuman && $0.cards.count == 2 } ?? false
        setHoverable(mine ? [Self.holeID(seat: 0, card: 0), Self.holeID(seat: 0, card: 1)] : [])
        applyHighlight(newScene)
        updateSeats(animated: duration > 0)
        updateChips(layout, animated: duration > 0)
        updateBadges(layout, old: old, animated: duration > 0)
        updateDealer(layout, animated: duration > 0 && old.button != newScene.button && old.button != nil)
        resultPill.show(isQuiet ? nil : newScene.result, at: layout.result, animated: duration > 0)
    }

    /// A winning card rises out of its place a little, along its own "up".
    private func lifted(_ pose: CardPose, card: Card) -> CardPose {
        guard scene.highlight.contains(card) else { return pose }
        var p = pose
        let distance = cardSize.height * pose.scale * 0.13
        p.position.x += sin(pose.rotation) * distance
        p.position.y -= cos(pose.rotation) * distance
        p.z += 200
        return p
    }

    // MARK: Seats

    private func rebuildSeats() {
        seats.forEach { $0.removeFromSuperview() }
        betStacks.forEach { $0.removeFromSuperlayer() }
        seats = scene.seats.map { s in
            let seat = SeatView(name: s.name, detail: Chips.format(s.stack),
                                avatar: s.isHuman ? .symbol("person.fill") : .initials)
            seat.frame.size = SeatView.stackedSize
            // Under the bar and the banners, over the cards.
            addSubview(seat, positioned: .below, relativeTo: actionBar)
            return seat
        }
        betStacks = scene.seats.map { _ in
            let stack = ChipStackLayer()
            stack.maximumStacks = 4
            stack.maximumChipsPerStack = 8
            addTableLayer(stack, z: -10)
            return stack
        }
        for badge in captionBadges.values { badge.hide(animated: false) }
        for badge in handBadges.values { badge.hide(animated: false) }
        captionBadges.removeAll()
        handBadges.removeAll()
    }

    private func updateSeats(animated: Bool) {
        for (i, s) in scene.seats.enumerated() {
            guard let seat = seats[safe: i] else { continue }
            seat.name = s.name
            seat.detail = Self.detail(for: s)
            let state: SeatView.State
            if s.status == .out {
                state = .out
            } else if s.isWinner {
                state = .winner
            } else if s.status == .folded {
                state = .folded
            } else if scene.toAct == i {
                state = .active
            } else {
                state = .waiting
            }
            seat.state = state
            seat.isThinking = scene.thinking == i
        }
    }

    /// The line under a seat's name: the stack, or what has become of it.
    static func detail(for s: PokerSeatScene) -> String {
        if let place = s.place, s.status == .out {
            return String(format: NSLocalizedString("Out · %@", comment: "poker seat: out of the tournament, e.g. Out · 4th"),
                          ordinal(place))
        }
        if s.status == .allIn { return NSLocalizedString("All-in", comment: "poker seat: has bet every chip") }
        return Chips.format(s.stack)
    }

    /// "1st", "4th" — in the language the app is showing, which is not
    /// always the system's: the words round it are localised, so the
    /// ordinal must match them ("You finished 4th", not "…4-й").
    static func ordinal(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: Chips

    private func updateChips(_ layout: PokerLayout, animated: Bool) {
        for (i, s) in scene.seats.enumerated() {
            guard let stack = betStacks[safe: i], let spot = layout.spots[safe: i] else { continue }
            stack.chipDiameter = layout.betChipDiameter
            stack.setAmount(s.bet, animated: animated)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stack.position = spot.bet
            stack.isHidden = s.bet == 0
            CATransaction.commit()
        }

        // One stack per pot, labelled underneath.
        let amounts = scene.pots
        while potStacks.count < amounts.count {
            let stack = ChipStackLayer()
            stack.showsLabel = false
            stack.maximumStacks = 5
            addTableLayer(stack, z: -10)
            potStacks.append(stack)
            let label = PokerCapsuleLabelLayer()
            addTableLayer(label, z: -9)
            potLabels.append(label)
        }
        let labelSize = max(10.5, layout.potChipDiameter * 0.40)
        for (i, stack) in potStacks.enumerated() {
            let amount = amounts[safe: i] ?? 0
            stack.chipDiameter = layout.potChipDiameter
            stack.setAmount(amount, animated: animated)
            potLabels[i].set(Self.potTitle(index: i, count: amounts.count, amount: amount), fontSize: labelSize)
        }
        let widths = potStacks.indices.map { i -> CGFloat in
            max(potStacks[i].bounds.width, potLabels[i].bounds.width)
        }
        let points = layout.potPositions(count: amounts.count, widths: widths)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, stack) in potStacks.enumerated() {
            let visible = i < amounts.count && amounts[i] > 0
            stack.isHidden = !visible
            potLabels[i].isHidden = !visible
            guard visible, let point = points[safe: i] else { continue }
            stack.position = point
            potLabels[i].position = CGPoint(x: point.x, y: point.y + labelSize * 0.5 + 6)
        }
        CATransaction.commit()
    }

    static func potTitle(index: Int, count: Int, amount: Int) -> String {
        let chips = Chips.format(amount)
        if count <= 1 {
            return String(format: NSLocalizedString("Pot %@", comment: "poker: the pot's label, e.g. Pot 1,240"), chips)
        }
        if index == 0 {
            return String(format: NSLocalizedString("Main pot %@", comment: "poker: the main pot's label"), chips)
        }
        if count == 2 {
            return String(format: NSLocalizedString("Side pot %@", comment: "poker: the one side pot's label"), chips)
        }
        return String(format: NSLocalizedString("Side pot %1$d · %2$@", comment: "poker: a numbered side pot, e.g. Side pot 2 · 300"),
                      index, chips)
    }

    /// Where pot `index` stands now, for a flight out of it.
    func potPoint(_ index: Int) -> CGPoint {
        if let stack = potStacks[safe: index], !stack.isHidden { return stack.position }
        return layoutModel?.pot ?? geometry.center
    }

    // MARK: The dealer button

    private func updateDealer(_ layout: PokerLayout, animated: Bool) {
        let d = max(18, (layout.betChipDiameter * 0.86).rounded())
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let button = scene.button, let spot = layout.spots[safe: button] else {
            dealerPuck.isHidden = true
            return
        }
        let target = spot.dealer
        let from = dealerPuck.presentation()?.position ?? dealerPuck.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dealerPuck.contents = AvatarRenderer.dealerButton(diameter: d, scale: scale)
        dealerPuck.contentsScale = scale
        dealerPuck.bounds = CGRect(x: 0, y: 0, width: d + 6, height: d + 6)
        dealerPuck.position = target
        let wasHidden = dealerPuck.isHidden
        dealerPuck.isHidden = false
        CATransaction.commit()
        guard animated, !wasHidden, Motion.isEnabled, window != nil else { return }
        // The button slides round the table to its next seat.
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: target)
        slide.duration = Motion.relaxed
        slide.timingFunction = Motion.easeInOut
        dealerPuck.add(slide, forKey: "slide")
    }

    // MARK: Highlight

    /// The winning five glow and everything else darkens a shade.
    private func applyHighlight(_ scene: PokerScene) {
        var lit = Set<Int>()
        var shade = Set<Int>()
        for id in spriteIDs {
            guard let layer = existingSprite(id) else { continue }
            if scene.highlight.contains(layer.card) && isFaceUp(id) {
                lit.insert(id)
            } else if scene.dimsOthers {
                shade.insert(id)
            }
        }
        setPlayable(lit)
        for id in dimmed.union(shade) {
            guard let layer = existingSprite(id) else { continue }
            setDim(shade.contains(id), on: layer)
        }
        dimmed = shade
    }

    private func setDim(_ on: Bool, on layer: CardLayer) {
        let name = "poker.dim"
        let existing = layer.sublayers?.first { $0.name == name }
        guard on else {
            existing?.removeFromSuperlayer()
            return
        }
        let veil = existing ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        veil.name = name
        veil.frame = layer.bounds
        veil.cornerRadius = cornerRadius
        veil.cornerCurve = .continuous
        veil.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        if existing == nil { layer.addSublayer(veil) }
        CATransaction.commit()
        if existing == nil && Motion.isEnabled && window != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Motion.standard
            veil.add(fade, forKey: "fade")
        }
    }

    // MARK: Badges

    private func updateBadges(_ layout: PokerLayout, old: PokerScene, animated: Bool) {
        for (i, s) in scene.seats.enumerated() {
            guard let spot = layout.spots[safe: i] else { continue }
            sync(&captionBadges, key: i, text: isQuiet ? nil : s.caption, tone: .neutral, at: spot.caption,
                 anchor: spot.captionAnchor, animated: animated)
            let won = s.isWinner
            sync(&handBadges, key: i, text: isQuiet ? nil : s.handName, tone: won ? .win : .neutral, at: spot.handName,
                 anchor: spot.handNameAnchor, animated: animated)
        }
        for key in captionBadges.keys where key >= scene.seats.count {
            captionBadges.removeValue(forKey: key)?.hide(animated: false)
        }
        for key in handBadges.keys where key >= scene.seats.count {
            handBadges.removeValue(forKey: key)?.hide(animated: false)
        }
        // The player's hand, beside their cards.
        var pill: [Int: TableBadge] = handPill.map { [0: $0] } ?? [:]
        sync(&pill, key: 0, text: showsHandStrength && !isQuiet ? scene.humanHand : nil, tone: scene.humanHandIsWinner ? .win : .neutral,
             at: layout.handPill, anchor: .trailing, animated: animated)
        handPill = pill[0]
    }

    private func sync(_ badges: inout [Int: TableBadge], key: Int, text: String?, tone: Banner.Tone,
                      at point: CGPoint, anchor: TableBadge.Anchor, animated: Bool) {
        if let text {
            if let badge = badges[key] {
                badge.update(text: text, tone: tone)
                badge.move(to: point, anchor: anchor)
            } else {
                badges[key] = TableBadge.show(text, tone: tone, in: self, at: point, anchor: anchor, animated: animated)
            }
        } else if let badge = badges.removeValue(forKey: key) {
            badge.hide(animated: animated)
        }
    }

    // MARK: Chrome

    private func positionChrome(_ layout: PokerLayout) {
        for (i, seat) in seats.enumerated() {
            guard let spot = layout.spots[safe: i] else { continue }
            seat.frame.size = SeatView.stackedSize
            seat.centerAvatar(at: spot.avatar)
        }
        resultPill.move(to: layout.result)
        // A card resized with the table takes its veil with it.
        for id in dimmed {
            guard let layer = existingSprite(id),
                  let veil = layer.sublayers?.first(where: { $0.name == "poker.dim" }) else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            veil.frame = layer.bounds
            veil.cornerRadius = cornerRadius
            CATransaction.commit()
        }
    }

    // MARK: Seats for the choreography

    /// Where a seat's chips leave from and arrive at: its avatar.
    func seatPoint(_ seat: Int) -> CGPoint {
        layoutModel?.spots[safe: seat]?.avatar ?? geometry.center
    }

    func betPoint(_ seat: Int) -> CGPoint {
        layoutModel?.spots[safe: seat]?.bet ?? geometry.center
    }

    func seatView(_ seat: Int) -> SeatView? { seats[safe: seat] }

    // MARK: Keys and accessibility

    override func handleKeyDown(_ event: NSEvent) -> Bool {
        keyHandler?(event) ?? false
    }

    override func accessibilityLabel(forSprite id: Int) -> String? {
        guard let layer = existingSprite(id) else { return nil }
        if id >= 40 {
            return String(format: NSLocalizedString("Board: %@", comment: "accessibility: a community card"),
                          layer.card.accessibilityName)
        }
        let seat = (id - 10) / 2
        let name = scene.seats[safe: seat]?.name ?? ""
        if isFaceUp(id) {
            return String(format: NSLocalizedString("%1$@: %2$@", comment: "accessibility: a player's card, e.g. Anna: Ace of Spades"),
                          name, layer.card.accessibilityName)
        }
        return String(format: NSLocalizedString("%@: face-down card", comment: "accessibility: a player's hidden card"), name)
    }
}
