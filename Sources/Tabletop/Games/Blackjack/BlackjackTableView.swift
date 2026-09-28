//
//  BlackjackTableView.swift
//  The blackjack table: the kit's half-moon with one betting circle, the
//  dealer's rack along the straight edge, the shoe at the dealer's left and
//  the discard holder at the dealer's right, and the cards and chips of
//  whatever `BlackjackScene` it was last given.
//
//  It knows no rules. `show(_:animated:)` hands it a scene; it works out
//  where everything in it belongs and animates the difference from the last
//  one — see `BlackjackScene` for what each difference means. Because each
//  step of a round changes one thing (a card, a flip, a stack), each call
//  animates one thing, and a round played out step by step looks dealt.
//
//  WHERE THINGS GO
//
//  The dealer's cards sit in an overlapping row in front of the rack, where
//  the kit's geometry leaves them room. The player's hand lies in the card
//  band straight above the circle, cascading a little to the right, each
//  card showing its index; split hands spread either side of it on a gentle
//  curve, each with its bet on the cloth in front of it. The kit lays the
//  printing out so that nothing in the band is ever printed over.
//
//  The dealer's rule line ("DEALER MUST STAND ON SOFT 17") is printed here,
//  on the open cloth between the circle and the rail, rather than by the
//  kit: the kit drops it for room at every common window size, and the rule
//  the dealer plays by — which the player chooses — is a line they must be
//  able to read. So is the table's limit sign, beside the dealer's rack: a
//  player whose 5 chip will not deal should be able to see why.
//

import AppKit
import QuartzCore

final class BlackjackTableView: CardTableView {

    let bar = ActionBar()
    let rack = ChipRackView()

    /// Keys the table itself did not claim — the chips' digits.
    var keyHandler: ((NSEvent) -> Bool)?
    /// An Option-click or right-click on the betting circle: take a chip back.
    var onTakeBack: (() -> Void)?
    /// A plain click on the betting circle.
    var onCircleClicked: (() -> Void)?

    /// What the table is showing.
    private(set) var scene = BlackjackScene()

    /// The dealer's rule, printed on the cloth.
    var dealerRule = BlackjackRules().dealerRuleText {
        didSet { if dealerRule != oldValue { invalidateBackground() } }
    }

    /// The table limits, on the sign beside the rack.
    var limits = (minimum: BlackjackRules().minimumBet, maximum: BlackjackRules().maximumBet) {
        didSet { if limits != oldValue { invalidateBackground() } }
    }

    private let shoeLayer = BlackjackShoeLayer()
    private let discardLayer = BlackjackDiscardLayer()
    private let activeMark = CALayer()
    private var stackLayers: [BlackjackScene.Stack: BlackjackChipStack] = [:]
    /// What each stack draws now, what is flying towards it, and what it is
    /// meant to hold once everything lands.
    private var displayed: [BlackjackScene.Stack: BlackjackAmount] = [:]
    private var incoming: [BlackjackScene.Stack: BlackjackAmount] = [:]
    private var targets: [BlackjackScene.Stack: BlackjackAmount] = [:]
    private var badges: [String: TableBadge] = [:]
    /// Cards on their way to the discard holder, removed when they land.
    private var sweeping: Set<Int> = []
    /// Cards dealt face down that turn over once they have landed.
    private var pendingFlips: Set<Int> = []
    /// Sprite ids for the backs that fly home in a shuffle — far above any
    /// card in an eight-deck shoe.
    private static let transientBase = 100_000

    init() {
        super.init(shape: .halfMoon(Self.print))
        sizePolicy = .blackjack
        bar.minimumContentHeight = ChipRackView.height
        bar.install(in: self)
        // The bar's tallest configuration — the chips during the betting —
        // reserved once, so nothing on the table moves when it changes.
        bottomReserve = ActionBar.reservedHeight(contentHeight: ChipRackView.height)
        addTableLayer(discardLayer, z: -30)
        addTableLayer(shoeLayer, z: -30)
        activeMark.backgroundColor = Palette.accent.withAlphaComponent(0.85).cgColor
        activeMark.shadowColor = Palette.accent.cgColor
        activeMark.shadowOpacity = 0.9
        activeMark.shadowRadius = 5
        activeMark.shadowOffset = .zero
        activeMark.opacity = 0
        addTableLayer(activeMark, z: -8)
        setAccessibilityLabel(NSLocalizedString("Blackjack table", comment: "accessibility: the table"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    /// One circle and the rack; the rule line is ours (see the top).
    private static var print: HalfMoonPrint {
        var print = HalfMoonPrint(betSpots: 1, showsChipTray: true)
        print.rule = ""
        return print
    }

    // MARK: Showing a scene

    /// Shows `scene`, animating what changed since the last one. A chip that
    /// has just gone onto the bet flies from `chipOrigin` (the chip in the
    /// rack the player clicked) rather than from the player's chips at large.
    func show(_ scene: BlackjackScene, animated: Bool, chipOrigin: CGPoint? = nil) {
        let previous = self.scene
        self.scene = scene
        apply(previous: previous, animated: animated, chipOrigin: chipOrigin)
    }

    /// Everything lands where it is going, at once — for a new game.
    func resetTable(to scene: BlackjackScene) {
        for id in spriteIDs { remove(id) }
        sweeping.removeAll()
        pendingFlips.removeAll()
        for layer in stackLayers.values { layer.removeFromSuperlayer() }
        stackLayers.removeAll()
        displayed.removeAll()
        incoming.removeAll()
        targets.removeAll()
        TableBadge.hideAll(in: self)
        badges.removeAll()
        self.scene = scene
        relayoutTable()
    }

    override func layoutTable() {
        apply(previous: scene, animated: false, chipOrigin: nil)
    }

    override func tableThemeDidChange() {
        updateFurniture()
    }

    // MARK: Layout

    private struct Layout {
        var cards: [Int: (pose: CardPose, faceUp: Bool, card: Card)] = [:]
        var dealerBox = CGRect.null
        var handBoxes: [CGRect] = []
        /// Where each hand's capsule is pinned, and on which side.
        var badges: [(point: CGPoint, anchor: TableBadge.Anchor)] = []
        var stackPoints: [BlackjackScene.Stack: CGPoint] = [:]
        /// The hands' chips stand as one mixed column each: the round is split.
        var mixedStacks = false
        /// Where the word about the bet goes: over the circle.
        var noticePoint = CGPoint.zero
        /// The glow under the active hand: its middle, length and turn.
        var mark: (center: CGPoint, length: CGFloat, rotation: CGFloat)?
    }

    /// One chip, across, on this table.
    private var chipDiameter: CGFloat {
        max(22, min(34, geometry.betSpotRadius * 0.66)).rounded()
    }

    /// The room `amount` takes on the cloth: its chips, or the capsule under
    /// them if that is wider.
    private func footprint(_ amount: BlackjackAmount, _ label: BlackjackChipStack.Label, mixed: Bool) -> CGFloat {
        max(BlackjackChipStack.chipsWidth(of: amount, diameter: chipDiameter, mixed: mixed),
            BlackjackChipStack.labelWidth(of: amount, diameter: chipDiameter, label: label))
    }

    private func layout(for scene: BlackjackScene) -> Layout {
        let g = geometry
        let w = cardSize.width, h = cardSize.height
        var layout = Layout()

        // The dealer: an overlapping row in front of the rack.
        let dealerPoses = TableLayout.row(count: scene.dealer.count, center: g.dealerArea, cardSize: cardSize,
                                          gap: -0.38, baseZ: 100)
        for (placed, pose) in zip(scene.dealer, dealerPoses) {
            layout.cards[placed.card.id] = (pose, placed.faceUp, placed.card.card)
        }
        layout.dealerBox = TableLayout.bounds(of: dealerPoses, cardSize: cardSize)

        // The player's hands. One lies in the card band straight above the
        // circle; split hands spread either side of it along a gentle curve —
        // flatter than the table's own, so the outer hands turn only a little
        // — each with its bet on the cloth in front of it, the way a dealer
        // sets a split bet beside the first.
        let spot = g.betSpots.first ?? CGPoint(x: g.center.x, y: g.center.y + h)
        let anchor = g.playerCardAnchor(forBetSpot: 0)
        let band = g.markings?.handBand ?? 0...0
        let curve = max(1, (band.lowerBound + band.upperBound) / 2) * 2.2
        let chipDrop = spot.y + g.betSpotRadius * 0.30 - anchor.y
        let hands = scene.hands
        let gap = w * 0.34
        let dy = h * 0.035
        // Each hand's bet point and the way along the curve.
        var fronts: [(point: CGPoint, along: CGVector)] = []

        func local(_ hand: BlackjackScene.Hand, dx: CGFloat) -> (cards: [(CGPoint, CGFloat)], box: CGRect) {
            var cards: [(CGPoint, CGFloat)] = []
            var box = CGRect.null
            for (k, placed) in hand.cards.enumerated() {
                let point: CGPoint
                let turn: CGFloat
                if placed.sideways, let previous = cards.last {
                    // A double-down card, crosswise across the end of the
                    // hand, the way a dealer marks one.
                    point = CGPoint(x: previous.0.x + dx * 1.15 + (h - w) / 2, y: previous.0.y + h * 0.04)
                    turn = .pi / 2
                } else {
                    point = CGPoint(x: CGFloat(k) * dx, y: -CGFloat(k) * dy)
                    // A breath of disorder, the same for the same card every
                    // time: cards put down by hand are never quite square.
                    turn = CGFloat(placed.card.id % 7 - 3) * 0.006
                }
                cards.append((point, turn))
                let half = placed.sideways ? CGSize(width: h / 2, height: w / 2) : CGSize(width: w / 2, height: h / 2)
                box = box.union(CGRect(x: point.x - half.width, y: point.y - half.height,
                                       width: half.width * 2, height: half.height * 2))
            }
            return (cards, box)
        }

        // Squeeze the cascades if the hands would not fit across the table.
        let span = bounds.width * 0.80
        var dx = w * 0.30
        var locals = hands.map { local($0, dx: dx) }
        func totalWidth() -> CGFloat {
            locals.reduce(0) { $0 + $1.box.width } + gap * CGFloat(max(0, locals.count - 1))
        }
        while totalWidth() > span && dx > w * 0.17 {
            dx -= w * 0.02
            locals = hands.map { local($0, dx: dx) }
        }

        // Centred on the circle: the middle hand of an odd number sits
        // straight above it (its bet in the circle), an even number either
        // side of it.
        var middles: [CGFloat] = []
        var run: CGFloat = 0
        for shape in locals {
            middles.append(run + shape.box.width / 2)
            run += shape.box.width + gap
        }
        let n = locals.count
        let pivot: CGFloat = n == 0 ? 0 : n % 2 == 1 ? middles[n / 2]
            : (middles[n / 2 - 1] + locals[n / 2 - 1].box.width / 2 + middles[n / 2] - locals[n / 2].box.width / 2) / 2
        for (i, (hand, shape)) in zip(hands, locals).enumerated() {
            let middle = middles[i] - pivot
            // Positive `middle` is to the player's right, where the curve
            // rises towards the dealer.
            let a = middle / curve
            let turn = -a
            let c = cos(turn), sn = sin(turn)
            let center = CGPoint(x: anchor.x + curve * sin(a), y: anchor.y - curve * (1 - cos(a)))
            let offset = CGPoint(x: shape.box.midX, y: shape.box.midY)
            func onTable(_ p: CGPoint) -> CGPoint {
                let x = p.x - offset.x, y = p.y - offset.y
                return CGPoint(x: center.x + x * c - y * sn, y: center.y + x * sn + y * c)
            }
            var poses: [CardPose] = []
            for (k, (point, cardTurn)) in shape.cards.enumerated() {
                let pose = CardPose(position: onTable(point), rotation: turn + cardTurn, z: 200 + i * 20 + k)
                poses.append(pose)
                let placed = hand.cards[k]
                layout.cards[placed.card.id] = (pose, placed.faceUp, placed.card.card)
            }
            layout.handBoxes.append(TableLayout.bounds(of: poses, cardSize: cardSize))
            // The total: beside a lone hand. Over each split hand, on the
            // cloth towards the dealer, where it cannot be mistaken for a
            // neighbour's: on the cards the glass would sit on white and lose
            // its contrast, and in front of them is the bet.
            if hands.count == 1 {
                let box = TableLayout.bounds(of: poses, cardSize: cardSize)
                layout.badges.append((CGPoint(x: box.maxX, y: box.midY), .trailing))
            } else {
                // Over the upright cards, not a crosswise double.
                let upright = zip(hand.cards, shape.cards).filter { !$0.0.sideways }.map(\.1.0.x)
                let topX = upright.isEmpty ? shape.box.midX : ((upright.min() ?? 0) + (upright.max() ?? 0)) / 2
                layout.badges.append((onTable(CGPoint(x: topX, y: shape.box.minY)), .above))
            }

            // The bet on the cloth in front of the hand: in the circle for a
            // lone hand, in front of each split hand.
            let chip = CGPoint(x: center.x - chipDrop * sn, y: center.y + chipDrop * c)
            layout.stackPoints[.bet(i)] = chip
            fronts.append((chip, CGVector(dx: c, dy: sn)))

            if hand.isActive {
                let bottom = shape.box.maxY + 5
                layout.mark = (onTable(CGPoint(x: shape.box.midX, y: bottom)), shape.box.width * 0.78, turn)
            }
        }
        // Winnings beside each bet, along the curve and far enough along
        // that the two capsules under them stay apart — but never into the
        // next hand's bet. A split round's chips stand in mixed columns, so
        // four hands' worth fit side by side.
        let d = chipDiameter
        let mixed = hands.count > 1
        layout.mixedStacks = mixed
        for (i, front) in fronts.enumerated() {
            let bet = scene.stacks[.bet(i)]?.amount ?? .zero
            let payout = scene.stacks[.payout(i)]?.amount ?? .zero
            let betChips = BlackjackChipStack.chipsWidth(of: bet, diameter: d, mixed: mixed)
            let payoutChips = BlackjackChipStack.chipsWidth(of: payout, diameter: d, mixed: mixed)
            var along = max(betChips / 2 + d * 0.30 + payoutChips / 2,
                            (footprint(bet, .amount, mixed: mixed) + footprint(payout, .gain, mixed: mixed)) / 2 + 6)
            if let next = fronts[safe: i + 1] {
                let nextBet = scene.stacks[.bet(i + 1)]?.amount ?? .zero
                let room = hypot(next.point.x - front.point.x, next.point.y - front.point.y)
                    - footprint(nextBet, .amount, mixed: mixed) / 2 - footprint(payout, .gain, mixed: mixed) / 2 - 6
                along = min(along, max(d * 0.8, room))
            }
            layout.stackPoints[.payout(i)] = CGPoint(x: front.point.x + along * front.along.dx,
                                                     y: front.point.y + along * front.along.dy)
        }
        // Before the deal the bet is in the circle.
        if hands.isEmpty {
            layout.stackPoints[.bet(0)] = CGPoint(x: spot.x, y: spot.y + g.betSpotRadius * 0.30)
        }
        layout.noticePoint = CGPoint(x: spot.x, y: spot.y - g.betSpotRadius)

        // Insurance on its band, in front of the circle and a little towards
        // the dealer, its capsule clear of the player's two cards.
        let insurance = g.insuranceSpot(forBetSpot: 0) ?? CGPoint(x: spot.x, y: spot.y - h * 1.4)
        let handTop = anchor.y - h * 0.52 - 2
        let insurancePoint = CGPoint(x: insurance.x - d * 0.7,
                                     y: min(insurance.y - d * 0.3, handTop - BlackjackChipStack.labelDrop(diameter: d) - 4))
        layout.stackPoints[.insurance] = insurancePoint
        let insured = scene.stacks[.insurance]?.amount ?? .zero
        let paid = scene.stacks[.insurancePayout]?.amount ?? .zero
        let insuranceAlong = max(BlackjackChipStack.chipsWidth(of: insured, diameter: d, mixed: false) / 2 + d * 0.3
                                    + BlackjackChipStack.chipsWidth(of: paid, diameter: d, mixed: false) / 2,
                                 (footprint(insured, .amount, mixed: false) + footprint(paid, .gain, mixed: false)) / 2 + 6)
        layout.stackPoints[.insurancePayout] = CGPoint(x: insurancePoint.x + insuranceAlong, y: insurancePoint.y)
        return layout
    }

    /// Where the player's own chips are: the rack in the bar while it is
    /// showing, the middle of the bar otherwise.
    private var bankrollPoint: CGPoint {
        if rack.window != nil, rack.superview != nil, !rack.isHiddenOrHasHiddenAncestor {
            let frame = convert(rack.bounds, from: rack)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        let frame = bar.frame.isEmpty ? CGRect(x: bounds.midX, y: bounds.maxY - 40, width: 0, height: 0) : bar.frame
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Where the dealer's chips are.
    private var trayPoint: CGPoint {
        guard let tray = geometry.chipTray else { return geometry.dealerArea }
        return CGPoint(x: tray.midX, y: tray.midY)
    }

    /// The question on the table, kept pinned between the hands.
    weak var prompt: BlackjackPrompt?

    /// Where the insurance question goes, and whether it has to fold its
    /// two lines into one to fit. On a big table there is open cloth under
    /// the dealer's total, above the lettering, and it goes there; otherwise
    /// over the printed insurance band, between the dealer's hand and the
    /// player's — both stay in view while the player decides.
    var promptPlacement: (point: CGPoint, compact: Bool) {
        let g = geometry
        let h = cardSize.height
        let handTop = g.playerCardAnchor(forBetSpot: 0).y - h * 0.52 - 2
        let dealerBottom = g.dealerArea.y + h / 2 + TableBadge.height + 10
        let headline = g.arcCenter.y + (g.markings?.headlineRadius ?? 0)
        let lettersTop = headline - (g.markings?.size ?? 16)
        let full = BlackjackPrompt.height
        if lettersTop - dealerBottom >= full + 8 {
            return (CGPoint(x: g.dealerArea.x, y: (dealerBottom + 2 + full / 2).rounded()), false)
        }
        let compact = handTop - dealerBottom < full + 4
        let half = (compact ? BlackjackPrompt.compactHeight : full) / 2
        let y = min(max(dealerBottom + half, (headline + handTop) / 2), handTop - half - 2)
        return (CGPoint(x: g.dealerArea.x, y: y.rounded()), compact)
    }

    /// Where a banner between the dealer's cards and the player's belongs, as
    /// a fraction of the view's height.
    var promptPosition: CGFloat {
        let g = geometry
        let top = g.dealerArea.y + cardSize.height / 2
        let bottom = g.playerCardAnchor(forBetSpot: 0).y - cardSize.height / 2
        return max(0.2, min(0.7, ((top + bottom) / 2) / max(1, bounds.height)))
    }

    // MARK: Applying

    private func apply(previous: BlackjackScene, animated: Bool, chipOrigin: CGPoint?) {
        let animate = animated && Motion.isEnabled && window != nil
        // The card sounds follow the cards, not the animation: under Reduce
        // Motion a card still goes from the shoe to the hand. (Never for a
        // relayout, where nothing moved at all.)
        let audible = animated && window != nil
        let layout = layout(for: scene)

        // Cards that have left the scene are swept into the discard holder,
        // turning face down on the way.
        var swept = 0
        var collected = 0
        for id in spriteIDs.sorted() where id < Self.transientBase && layout.cards[id] == nil && !sweeping.contains(id) {
            pendingFlips.remove(id)
            collected += 1
            guard animate else {
                remove(id)
                continue
            }
            sweeping.insert(id)
            var landing = discardLayer.landingPose
            landing.z = 900 + swept
            place(id, pose: landing, faceUp: false, duration: 0.42, delay: Double(swept) * 0.035) { [weak self] in
                guard let self, self.sweeping.contains(id) else { return }
                self.sweeping.remove(id)
                self.remove(id)
            }
            swept += 1
        }
        if collected > 0 && audible { Sound.play(.slide) }

        // Cards new to the scene come out of the shoe, land face down, and
        // turn over where they lie; the rest move to where they now belong.
        var dealt = 0
        for (id, spec) in layout.cards.sorted(by: { $0.value.pose.z < $1.value.pose.z }) {
            if sweeping.contains(id) {
                // Back from the tray before it arrived (a fresh shoe dealt at
                // once): start it over from the shoe.
                sweeping.remove(id)
                remove(id)
            }
            guard existingSprite(id) != nil else {
                sprite(id: id, card: spec.card)
                place(id, pose: shoeLayer.dealPose, faceUp: false, duration: 0)
                if audible { Sound.play(.deal) }
                if animate {
                    let delay = Double(dealt) * Motion.dealStagger
                    dealt += 1
                    if spec.faceUp { pendingFlips.insert(id) }
                    place(id, pose: spec.pose, faceUp: false, duration: 0.32, delay: delay) { [weak self] in
                        guard let self, self.pendingFlips.contains(id) else { return }
                        self.pendingFlips.remove(id)
                        guard self.layout(for: self.scene).cards[id]?.faceUp == true else { return }
                        self.flip(id, faceUp: true, duration: Motion.cardFlip)
                    }
                } else {
                    place(id, pose: spec.pose, faceUp: spec.faceUp, duration: 0)
                }
                continue
            }
            let moved = pose(of: id) != spec.pose
            let turning = isFaceUp(id) != spec.faceUp && !pendingFlips.contains(id)
            if !animate { pendingFlips.remove(id) }
            guard moved || turning || !animate else { continue }
            if turning && audible { Sound.play(.flip) }
            let faceUp = pendingFlips.contains(id) ? isFaceUp(id) : spec.faceUp
            place(id, pose: spec.pose, faceUp: animate ? faceUp : spec.faceUp,
                  duration: animate ? (turning && !moved ? Motion.cardFlip * 1.5 : Motion.cardMove) : 0)
        }

        // A fresh shoe: a few backs fly from the tray into the shoe.
        let shuffled = previous.discardCount > 0 && scene.discardCount == 0 && scene.shoeRemaining >= 0.999
        if shuffled && audible { Sound.play(.shuffle) }
        if animate && shuffled {
            let from = discardLayer.landingPose
            for k in 0..<6 {
                let id = Self.transientBase + k
                sprite(id: id, card: Card(.spades, .ace))
                place(id, pose: CardPose(position: from.position, rotation: from.rotation, z: 950 + k), faceUp: false,
                      duration: 0)
                place(id, pose: shoeLayer.dealPose, faceUp: false, duration: 0.5, delay: 0.25 + Double(k) * 0.06) { [weak self] in
                    self?.remove(id)
                }
            }
        }

        applyStacks(layout, animate: animate, chipOrigin: chipOrigin)
        applyBadges(layout, animate: animate)
        applyMark(layout, animate: animate)
        updateFurniture()
        if let prompt {
            let placement = promptPlacement
            prompt.move(to: placement.point, compact: placement.compact)
        }
    }

    private func applyStacks(_ layout: Layout, animate: Bool, chipOrigin: CGPoint?) {
        let d = chipDiameter
        let keys = Set(scene.stacks.keys).union(stackLayers.keys)
        for key in keys {
            let target = scene.stacks[key]?.amount ?? .zero
            let lost = scene.stacks[key]?.lost ?? false
            targets[key] = target
            let point = layout.stackPoints[key] ?? stackLayers[key]?.position ?? bankrollPoint
            let label: BlackjackChipStack.Label
            let mixed: Bool
            switch key {
            case .bet: (label, mixed) = (.amount, layout.mixedStacks)
            case .payout: (label, mixed) = (.gain, layout.mixedStacks)
            case .insurance: (label, mixed) = (.amount, false)
            case .insurancePayout: (label, mixed) = (.gain, false)
            }
            let layer: BlackjackChipStack
            if let existing = stackLayers[key] {
                layer = existing
                layer.chipDiameter = d
                layer.label = label
                // A split: the bet restacks itself as the player's column.
                layer.setMixed(mixed, animated: animate)
                if hypot(existing.position.x - point.x, existing.position.y - point.y) > 0.5 {
                    if animate && (displayed[key] ?? .zero) > .zero {
                        let slide = CABasicAnimation(keyPath: "position")
                        slide.fromValue = NSValue(point: existing.presentation()?.position ?? existing.position)
                        slide.toValue = NSValue(point: point)
                        slide.duration = Motion.cardMove
                        slide.timingFunction = Motion.easeOut
                        existing.add(slide, forKey: "slide")
                    }
                    existing.position = point
                }
            } else {
                guard target > .zero else { continue }
                layer = BlackjackChipStack()
                layer.chipDiameter = d
                layer.label = label
                layer.isMixed = mixed
                layer.position = point
                addTableLayer(layer, z: -10)
                stackLayers[key] = layer
            }

            let shown = displayed[key] ?? .zero
            let flying = incoming[key] ?? .zero
            let delta = target - (shown + flying)
            if delta > .zero {
                guard animate else {
                    displayed[key] = target - flying
                    layer.setAmount(target - flying, animated: false)
                    continue
                }
                incoming[key] = flying + delta
                let from: CGPoint
                switch key {
                case .payout, .insurancePayout: from = trayPoint
                case .bet(0) where chipOrigin != nil: from = chipOrigin ?? bankrollPoint
                default: from = bankrollPoint
                }
                // A lone half flies as the smallest chip there is.
                ChipFlight.fly(amount: max(1, delta.wholeChips), from: from, to: point, in: tableLayer,
                               chipDiameter: d) { [weak self, weak layer] in
                    guard let self, let layer else { return }
                    self.incoming[key] = max(.zero, (self.incoming[key] ?? .zero) - delta)
                    let now = max(.zero, (self.targets[key] ?? .zero) - (self.incoming[key] ?? .zero))
                    self.displayed[key] = now
                    layer.setAmount(now, animated: true)
                }
            } else if delta < .zero {
                let now = max(.zero, target - flying)
                displayed[key] = now
                layer.setAmount(now, animated: animate)
                if animate {
                    ChipFlight.fly(amount: max(1, (-delta).wholeChips), from: layer.position, to: lost ? trayPoint : bankrollPoint,
                                   in: tableLayer, chipDiameter: d)
                }
            } else if !animate && layer.amount != shown {
                layer.setAmount(shown, animated: false)
            }
        }
    }

    private func applyBadges(_ layout: Layout, animate: Bool) {
        func set(_ key: String, _ text: String?, tone: Banner.Tone, at point: CGPoint, anchor: TableBadge.Anchor) {
            if let text {
                if let badge = badges[key] {
                    badge.update(text: text, tone: tone)
                    badge.move(to: point, anchor: anchor)
                } else {
                    badges[key] = TableBadge.show(text, tone: tone, in: self, at: point, anchor: anchor, animated: animate)
                }
            } else if let badge = badges.removeValue(forKey: key) {
                badge.hide(animated: animate)
            }
        }
        let dealer = layout.dealerBox
        set("dealer", dealer.isNull ? nil : scene.dealerLabel, tone: scene.dealerTone,
            at: CGPoint(x: dealer.midX, y: dealer.maxY), anchor: .below)
        for i in 0..<4 {
            guard let hand = scene.hands[safe: i], let pin = layout.badges[safe: i] else {
                set("hand\(i)", nil, tone: .neutral, at: .zero, anchor: .above)
                continue
            }
            set("hand\(i)", hand.label, tone: hand.tone, at: pin.point, anchor: pin.anchor)
        }
        set("notice", scene.notice, tone: .neutral, at: layout.noticePoint, anchor: .above)
    }

    private func applyMark(_ layout: Layout, animate: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(Motion.standard)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        if let mark = layout.mark {
            let appearing = activeMark.opacity == 0
            if appearing {
                CATransaction.setDisableActions(true)
            }
            activeMark.bounds = CGRect(x: 0, y: 0, width: mark.length, height: 3)
            activeMark.cornerRadius = 1.5
            activeMark.position = mark.center
            activeMark.setAffineTransform(CGAffineTransform(rotationAngle: mark.rotation))
            activeMark.shadowPath = CGPath(roundedRect: activeMark.bounds, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            if appearing && animate {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                fade.duration = Motion.standard
                activeMark.add(fade, forKey: "fade")
            }
            activeMark.opacity = 1
        } else {
            activeMark.opacity = 0
        }
        CATransaction.commit()
    }

    /// The shoe and the discard holder, drawn for the scene's counts.
    private func updateFurniture() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let back = renderer.backImage()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shoeLayer.position = geometry.shoe
        discardLayer.position = geometry.discardTray
        CATransaction.commit()
        shoeLayer.update(remaining: scene.shoeRemaining, cut: scene.cutFraction, cutCardOut: scene.isCutCardOut,
                         cardSize: cardSize, back: back, scale: scale)
        discardLayer.update(count: scene.discardCount, shoeSize: scene.shoeSize, cardSize: cardSize, back: back, scale: scale)
    }

    // MARK: The printed rule

    override func backgroundSignature() -> String { "\(dealerRule)|\(limits.minimum)|\(limits.maximum)" }

    override func paintBackground(in ctx: CGContext, rect: CGRect) {
        super.paintBackground(in: ctx, rect: rect)
        let g = geometry
        guard let markings = g.markings, let spot = g.betSpots.first else { return }
        // On the open cloth between the circle and the rail, centred in it,
        // set small and quiet like the kit's own rule line.
        let size = max(8.5, markings.size * 0.52)
        let capHeight = size * 0.72
        let circleBottom = hypot(spot.x - g.arcCenter.x, spot.y - g.arcCenter.y) + g.betSpotRadius
        let room = g.feltRadius - circleBottom
        guard room > capHeight * 2.4 else { return }
        let radius = circleBottom + (room + capHeight) / 2 - room * 0.06
        ctx.saveGState()
        ctx.addPath(g.feltPath)
        ctx.clip()
        AppleStyle.inked(ctx, width: markings.size * 20) { ctx in
            TableSurface.drawArcText(dealerRule, center: g.arcCenter, radius: radius,
                                     font: .systemFont(ofSize: size, weight: .semibold),
                                     color: NSColor(white: 1, alpha: 0.46), kern: size * 0.24, context: ctx)
        }
        ctx.restoreGState()
        paintLimitSign(in: ctx)
    }

    /// The table limits on a small smoked-acrylic sign, standing between the
    /// discard holder and the dealer's rack where a casino puts its own —
    /// left out on a window too narrow to give it room.
    private func paintLimitSign(in ctx: CGContext) {
        let g = geometry
        guard let tray = g.chipTray, let markings = g.markings else { return }
        let size = max(9, min(13, markings.size * 0.56))
        let labelFont = NSFont.systemFont(ofSize: size * 0.80, weight: .semibold)
        let valueFont = Typography.number(size * 1.08, weight: .semibold)
        let rows = [(NSLocalizedString("MIN", comment: "blackjack limit sign: the minimum bet"), Chips.format(limits.minimum)),
                    (NSLocalizedString("MAX", comment: "blackjack limit sign: the maximum bet"), Chips.format(limits.maximum))]
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .kern: size * 0.12,
                                                              .foregroundColor: NSColor(white: 1, alpha: 0.56)]
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor(white: 1, alpha: 0.90)]
        let labelWidth = rows.map { ($0.0 as NSString).size(withAttributes: labelAttributes).width }.max() ?? 0
        let valueWidth = rows.map { ($0.1 as NSString).size(withAttributes: valueAttributes).width }.max() ?? 0
        let lineHeight = ceil(valueFont.ascender - valueFont.descender)
        let pad = size * 0.75
        let width = ceil(pad * 2 + labelWidth + size * 0.9 + valueWidth)
        let height = ceil(pad * 1.5 + lineHeight * 2 + size * 0.15)
        // The holder's right edge, allowing for its turn, to the rack's left.
        let holderRight = g.discardTray.x + cardSize.width / 2 + 12 + cardSize.height * 0.06
        guard tray.minX - holderRight >= width + 20 else { return }
        let sign = CGRect(x: ((holderRight + tray.minX - width) / 2).rounded(), y: (tray.minY + 2).rounded(),
                          width: width, height: height)
        let path = ContinuousShape.roundedRect(sign, radius: size * 0.45)
        ctx.saveGState()
        // Standing on the cloth, lit from above left: its shadow falls down and right.
        ctx.setShadow(offset: CGSize(width: size * 0.2, height: size * 0.45), blur: size * 0.9,
                      color: NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        AppleStyle.fillVertical(sign, context: ctx, [(NSColor(white: 0.17, alpha: 1), 0), (NSColor(white: 0.06, alpha: 1), 1)])
        ctx.restoreGState()
        AppleStyle.gloss(path, in: sign, context: ctx, strength: 0.8)
        AppleStyle.bevel(path, in: sign, context: ctx, width: 1, top: NSColor(white: 1, alpha: 0.26),
                         bottom: NSColor(white: 0, alpha: 0.5))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        var y = sign.minY + pad * 0.75
        for (label, value) in rows {
            let labelSize = (label as NSString).size(withAttributes: labelAttributes)
            (label as NSString).draw(at: CGPoint(x: sign.minX + pad, y: y + (lineHeight - labelSize.height) / 2 + size * 0.05),
                                     withAttributes: labelAttributes)
            let valueSize = (value as NSString).size(withAttributes: valueAttributes)
            (value as NSString).draw(at: CGPoint(x: sign.maxX - pad - valueSize.width, y: y + (lineHeight - valueSize.height) / 2),
                                     withAttributes: valueAttributes)
            y += lineHeight + size * 0.15
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Input

    override func handleKeyDown(_ event: NSEvent) -> Bool {
        keyHandler?(event) ?? false
    }

    private func isOnCircle(_ point: CGPoint) -> Bool {
        guard let spot = geometry.betSpots.first else { return false }
        return hypot(point.x - spot.x, point.y - spot.y) <= geometry.betSpotRadius + 4
    }

    override func tableClicked(at point: CGPoint, with event: NSEvent) {
        guard isOnCircle(point) else { return }
        if event.modifierFlags.contains(.option) { onTakeBack?() } else { onCircleClicked?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isOnCircle(point) { onTakeBack?() } else { super.rightMouseDown(with: event) }
    }

    override func accessibilityLabel(forSprite id: Int) -> String? {
        guard id < Self.transientBase, !sweeping.contains(id) else { return nil }
        return super.accessibilityLabel(forSprite: id)
    }

    // MARK: For the tests

    /// Stack amounts as drawn, once everything has landed.
    func stackAmountForTesting(_ key: BlackjackScene.Stack) -> BlackjackAmount { displayed[key] ?? .zero }

    /// Where a stack stands, and its layer's size — for the layout checks.
    func stackFrameForTesting(_ key: BlackjackScene.Stack) -> CGRect? {
        guard let layer = stackLayers[key], (displayed[key] ?? .zero) > .zero else { return nil }
        return layer.frame
    }

    func badgeFrameForTesting(_ key: String) -> CGRect? { badges[key]?.frame }

    /// Card sprites that belong to the scene (not ones on their way out).
    var sceneSpriteCount: Int {
        spriteIDs.filter { $0 < Self.transientBase && !sweeping.contains($0) }.count
    }

    func badgeTextForTesting(_ key: String) -> String? { badges[key]?.text }
}
