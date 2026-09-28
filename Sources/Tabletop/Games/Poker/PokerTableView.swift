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
//  Sprite ids: the board is 40…44, and seat s holds 10 + 2s and 11 + 2s. A
//  card keeps its id from the deal to the muck, so the view can tell a card
//  that moved from one that is new.
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
        didSet {
            guard isQuiet != oldValue else { return }
            relayoutTable()
            setScrim(isQuiet)
        }
    }
    private var scrim: NSView?

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
            let inward = layout.spots[safe: seat]?.inward
            for (k, card) in s.cards.prefix(2).enumerated() {
                put(Self.holeID(seat: seat, card: k), card: card,
                    pose: lifted(poses[k], card: card, towards: inward, human: seat == 0), faceUp: s.faceUp)
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
        resultPill.show(isQuiet ? nil : newScene.result, at: layout.result, maxWidth: layout.resultMaxWidth,
                        animated: duration > 0)
    }

    /// A winning card rises out of its place a little: a board card along
    /// its own "up", a player's card towards the middle of the table — for
    /// the seat across the table that is down, away from its plate, where
    /// "up" would have lifted the cards onto it.
    private func lifted(_ pose: CardPose, card: Card, towards inward: CGVector? = nil, human: Bool = false) -> CardPose {
        guard scene.highlight.contains(card) else { return pose }
        var p = pose
        let distance = cardSize.height * pose.scale * (human ? PokerLayout.humanWinningLift : PokerLayout.winningLift)
        if let inward {
            p.position.x += inward.dx * distance
            p.position.y += inward.dy * distance
        } else {
            p.position.x += sin(pose.rotation) * distance
            p.position.y -= cos(pose.rotation) * distance
        }
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
            stack.maximumStacks = PokerLayout.betStacks
            stack.maximumChipsPerStack = Self.betChipsPerStack
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
            stack.position = s.bet > 0 ? betPoint(i, amount: s.bet) : spot.bet
            stack.isHidden = s.bet == 0
            CATransaction.commit()
        }

        // One stack per pot, labelled underneath, in a row no wider than the
        // board: more pots than fit get fewer stacks each, then shorter
        // words, then just their amounts (see `potRow`).
        let amounts = scene.pots
        while potStacks.count < amounts.count {
            let stack = ChipStackLayer()
            stack.showsLabel = false
            stack.maximumChipsPerStack = PokerLayout.potChipsPerStack
            addTableLayer(stack, z: -10)
            potStacks.append(stack)
            let label = PokerCapsuleLabelLayer()
            addTableLayer(label, z: -9)
            potLabels.append(label)
        }
        let labelSize = max(10.5, layout.potChipDiameter * 0.40)
        let row = Self.potRow(amounts, chip: layout.potChipDiameter, fontSize: labelSize, width: layout.potBand.width)
        for (i, stack) in potStacks.enumerated() {
            let amount = amounts[safe: i] ?? 0
            stack.chipDiameter = layout.potChipDiameter
            stack.maximumStacks = row.stacks
            stack.setAmount(amount, animated: animated)
            potLabels[i].set(Self.potTitle(index: i, count: amounts.count, amount: amount, words: row.words),
                             fontSize: labelSize)
        }
        let points = layout.potPositions(widths: row.widths, gap: row.gap)
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

    /// How the row of pots is drawn: stacks per pot, how the labels read,
    /// the gap, and each pot's width (a pot already paid keeps its place, so
    /// the others do not shuffle while the chips go out).
    struct PotRow: Equatable {
        var stacks: Int
        var words: PotWords
        var gap: CGFloat
        var widths: [CGFloat]
    }

    enum PotWords { case full, short, amount }

    /// The roomiest way of drawing `amounts` as a row that fits in `width`.
    static func potRow(_ amounts: [Int], chip d: CGFloat, fontSize: CGFloat, width: CGFloat) -> PotRow {
        let ladder: [(stacks: Int, words: PotWords, gap: CGFloat)] = [
            (amounts.count <= 1 ? 5 : 3, .full, 0.9), (2, .full, 0.5), (2, .short, 0.4), (1, .amount, 0.35),
        ]
        var row = PotRow(stacks: 1, words: .amount, gap: d * 0.35, widths: [])
        for step in ladder {
            let widths = amounts.enumerated().map { i, amount -> CGFloat in
                let stacks = ChipStackLayer.stacks(for: amount, maximumPerStack: PokerLayout.potChipsPerStack,
                                                   maximumStacks: step.stacks).count
                let chips = CGFloat(max(1, stacks)) * d * 1.1 - d * 0.1 + d * 0.5
                let label = PokerCapsuleLabelLayer.width(of: potTitle(index: i, count: amounts.count, amount: amount,
                                                                      words: step.words), fontSize: fontSize)
                return max(chips, label)
            }
            row = PotRow(stacks: step.stacks, words: step.words, gap: (d * step.gap).rounded(), widths: widths)
            let total = widths.reduce(0, +) + row.gap * CGFloat(max(0, widths.count - 1))
            if total <= width { break }
        }
        return row
    }

    static func potTitle(index: Int, count: Int, amount: Int, words: PotWords = .full) -> String {
        let chips = Chips.format(amount)
        switch words {
        case .full: break
        case .amount: return chips
        case .short:
            if count <= 1 { break }
            return index == 0
                ? String(format: NSLocalizedString("Main %@", comment: "poker: the main pot's label when many pots crowd the row"), chips)
                : String(format: NSLocalizedString("Side %@", comment: "poker: a side pot's label when many pots crowd the row"), chips)
        }
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
        let d = layout.dealerDiameter
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
        // The player's hand, beside their cards — in full when there is the
        // room before the next seat's cards, by its kind when not.
        var pill: [Int: TableBadge] = handPill.map { [0: $0] } ?? [:]
        var words = scene.humanHand
        if let full = words, PokerLayout.badgeWidth(full) > layout.handPillMaxWidth { words = scene.humanHandShort ?? full }
        sync(&pill, key: 0, text: showsHandStrength && !isQuiet ? words : nil, tone: scene.humanHandIsWinner ? .win : .neutral,
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

    /// The table dimmed under something said over all of it, the way the
    /// New Game card dims it — and, in a screenshot's drawn glass, so the
    /// board does not show through the words.
    private func setScrim(_ on: Bool) {
        if on {
            let view = scrim ?? PokerScrimView(frame: bounds)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)        // on top now; the banner comes after it
            scrim = view
            if Motion.isEnabled && window != nil {
                view.alphaValue = 0
                Motion.animate(duration: Motion.standard) { view.animator().alphaValue = 1 }
            } else {
                view.alphaValue = 1
            }
        } else if let view = scrim {
            scrim = nil
            view.removeFromSuperview()
        }
    }

    private func positionChrome(_ layout: PokerLayout) {
        for (i, seat) in seats.enumerated() {
            guard let spot = layout.spots[safe: i] else { continue }
            seat.frame.size = SeatView.stackedSize
            seat.centerAvatar(at: spot.avatar)
        }
        resultPill.move(to: layout.result, maxWidth: layout.resultMaxWidth)
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

    /// Where `seat`'s bet of `amount` (the one on the table, by default)
    /// stands: in the place the layout keeps for the largest bet, drawn over
    /// towards the seat's cards by however much narrower this one is — so a
    /// single chip sits by the cards rather than out in the middle of the
    /// room kept for four stacks, and never leaves that room.
    func betPoint(_ seat: Int, amount: Int? = nil) -> CGPoint {
        guard let layout = layoutModel, let spot = layout.spots[safe: seat] else { return geometry.center }
        let chips = amount ?? scene.seats[safe: seat]?.bet ?? 0
        let d = layout.betChipDiameter
        let stacks = CGFloat(max(1, ChipStackLayer.stacks(for: chips, maximumPerStack: Self.betChipsPerStack,
                                                         maximumStacks: PokerLayout.betStacks).count))
        let font = Typography.number(max(10, d * 0.34), weight: .semibold)
        let label = ceil((Chips.format(chips) as NSString).size(withAttributes: [.font: font]).width + d * 0.55)
        // Measured as the layout measures the largest: chips, and a sliver of
        // their shadow either side.
        let half = max(stacks * d + (stacks - 1) * d * 0.1, label) / 2 + d * 0.06
        let room = max(0, PokerLayout.betRect(at: .zero, chip: d).width / 2 - half)
        let cards = TableLayout.bounds(of: layout.holePoses(seat: seat, revealed: false), cardSize: cardSize).midX
        let dx = max(-room, min(room, cards - spot.bet.x))
        return CGPoint(x: (spot.bet.x + dx).rounded(), y: spot.bet.y)
    }

    /// A bet's stacks: a denomination past this many starts another.
    static let betChipsPerStack = 8

    func seatView(_ seat: Int) -> SeatView? { seats[safe: seat] }

    // The layers and badges on show, for `footprints()`.
    var betStackLayers: [ChipStackLayer] { betStacks }
    var potStackLayers: [ChipStackLayer] { potStacks }
    var potLabelLayers: [PokerCapsuleLabelLayer] { potLabels }
    var captionBadgeViews: [Int: TableBadge] { captionBadges }
    var handBadgeViews: [Int: TableBadge] { handBadges }
    var handPillView: TableBadge? { handPill }
    var dealerPuckLayer: CALayer? { dealerPuck }

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

// MARK: - Footprints

/// One thing on the table as the player sees it — for the checks that
/// nothing lies on anything else.
struct PokerFootprint: Equatable {
    enum Kind: String { case seat, cards, board, bet, pot, potLabel, caption, handName, handPill, dealer, result }
    var kind: Kind
    /// The seat it belongs to (the pot's index, for a pot and its label).
    var owner: Int?
    var rect: CGRect
}

extension PokerTableView {

    /// Everything on show, each as the rectangle it covers: a card's turned
    /// corners, a chip stack's chips and amount without the room left for
    /// its shadow, a badge's capsule.
    func footprints() -> [PokerFootprint] {
        var out: [PokerFootprint] = []
        for i in scene.seats.indices {
            guard let seat = seatView(i), !seat.isHidden else { continue }
            // The ring round the avatar, and the plate under it — not the
            // empty corners of the view's frame beside the avatar.
            let f = seat.frame
            let ring = SeatView.avatarSize / 2 + 4.5
            let center = CGPoint(x: f.midX, y: f.minY + 4 + SeatView.avatarSize / 2)
            out.append(PokerFootprint(kind: .seat, owner: i,
                                      rect: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)))
            let plateTop = center.y + SeatView.avatarSize / 2 - 8
            out.append(PokerFootprint(kind: .seat, owner: i,
                                      rect: CGRect(x: f.minX, y: plateTop, width: f.width, height: f.maxY - plateTop)))
        }
        for id in spriteIDs.sorted() {
            guard let pose = pose(of: id), !pose.isHidden, let layer = existingSprite(id), !layer.isHidden else { continue }
            let box = TableLayout.boundingBox(of: pose, cardSize: cardSize)
            if id >= Self.boardID(0) {
                out.append(PokerFootprint(kind: .board, owner: nil, rect: box))
            } else {
                out.append(PokerFootprint(kind: .cards, owner: (id - 10) / 2, rect: box))
            }
        }
        func chips(_ layer: ChipStackLayer) -> CGRect {
            let room = layer.chipDiameter * 0.2
            let f = layer.frame
            return CGRect(x: f.minX + room, y: f.minY + room, width: f.width - room * 2,
                          height: f.height - room - (layer.showsLabel ? 0 : room))
        }
        for (i, stack) in betStackLayers.enumerated() where !stack.isHidden {
            out.append(PokerFootprint(kind: .bet, owner: i, rect: chips(stack)))
        }
        for (i, stack) in potStackLayers.enumerated() where !stack.isHidden {
            out.append(PokerFootprint(kind: .pot, owner: i, rect: chips(stack)))
        }
        for (i, label) in potLabelLayers.enumerated() where !label.isHidden {
            out.append(PokerFootprint(kind: .potLabel, owner: i, rect: label.frame))
        }
        for (seat, badge) in captionBadgeViews { out.append(PokerFootprint(kind: .caption, owner: seat, rect: badge.frame)) }
        for (seat, badge) in handBadgeViews { out.append(PokerFootprint(kind: .handName, owner: seat, rect: badge.frame)) }
        if let pill = handPillView { out.append(PokerFootprint(kind: .handPill, owner: 0, rect: pill.frame)) }
        if let puck = dealerPuckLayer, !puck.isHidden {
            out.append(PokerFootprint(kind: .dealer, owner: scene.button, rect: puck.frame.insetBy(dx: 3, dy: 3)))
        }
        if !resultPill.isHidden { out.append(PokerFootprint(kind: .result, owner: nil, rect: resultPill.frame)) }
        return out
    }

    /// The pairs of footprints that lie on each other, described.
    static func overlaps(in footprints: [PokerFootprint], tolerance: CGFloat = 1.5) -> [String] {
        var problems: [String] = []
        for (i, a) in footprints.enumerated() {
            for b in footprints[(i + 1)...] {
                // A hand's own two cards fan over each other; a pot's label
                // sits under its chips.
                if a.kind == b.kind && [.cards, .board, .seat].contains(a.kind) && a.owner == b.owner { continue }
                if Set([a.kind, b.kind]) == [.pot, .potLabel] && a.owner == b.owner { continue }
                let x = a.rect.intersection(b.rect)
                guard !x.isNull, x.width > tolerance, x.height > tolerance else { continue }
                func name(_ f: PokerFootprint) -> String { f.kind.rawValue + (f.owner.map { " \($0)" } ?? "") }
                problems.append("\(name(a)) on \(name(b))")
            }
        }
        return problems
    }
}

/// The dimming under a table-wide message. Takes the clicks meant for the
/// table under it.
final class PokerScrimView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.scrim.cgColor
    }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}
