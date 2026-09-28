//
//  KitGallery.swift
//  `Tabletop --shot kit <out.png>`: every piece of the shared kit on one
//  table, in every style and state, photographed off-screen.
//
//  This is how the kit is judged. A button that looks right alone can look
//  wrong next to a seat; a chip that reads at 40 points can turn to mush at
//  24; glass that is fine over green cloth can vanish over slate. Laying
//  everything out together, on the real cloth, at the real sizes, is the
//  only way to see the system as a system — and it is the picture a
//  reviewer (or a game's author, wondering what the kit already has) looks
//  at first.
//
//  Nothing here is interactive and nothing is saved; it builds views, places
//  them, and hands them to the same off-screen renderer as `--shot`.
//

import AppKit

@MainActor
enum KitGallery {

    static let defaultSize = CGSize(width: 1800, height: 1240)

    /// `--shot kit --scenario NAME`: the gallery, or one of three sample
    /// tables composed from nothing but the kit — what a poker, blackjack or
    /// durak table looks like before its game adds anything of its own.
    static let scenarios = ["gallery", "poker", "blackjack", "durak"]

    /// The gallery or a sample table, laid out for `size`, in a window that
    /// is never shown.
    static func makeView(size: CGSize, scenario: String?) -> NSView {
        switch scenario ?? "gallery" {
        case "poker": return KitSampleTable(kind: .poker, frame: CGRect(origin: .zero, size: size))
        case "blackjack": return KitSampleTable(kind: .blackjack, frame: CGRect(origin: .zero, size: size))
        case "durak": return KitSampleTable(kind: .durak, frame: CGRect(origin: .zero, size: size))
        default:
            let table = KitGalleryTable(frame: CGRect(origin: .zero, size: size))
            table.build()
            return table
        }
    }
}

/// A table composed from the kit alone, the way a game would compose it:
/// shape, seats, cards from `TableLayout`, chips, an action bar.
final class KitSampleTable: CardTableView {

    enum Kind { case poker, blackjack, durak }
    let kind: Kind
    private let bar = ActionBar()
    private var seats: [SeatView] = []
    private var chipLayers: [CALayer] = []

    init(kind: Kind, frame: CGRect) {
        self.kind = kind
        switch kind {
        case .poker: super.init(shape: .oval)
        case .blackjack: super.init(shape: .halfMoon(HalfMoonPrint(betSpots: 3)))
        case .durak: super.init(shape: .rectangular)
        }
        self.frame = frame
        switch kind {
        case .poker:
            sizePolicy = .poker
            let bet = BetControl(minimum: 40, maximum: 1_480, step: 20, value: 120)
            bet.presets = [BetControl.Preset("Min", 40), BetControl.Preset("½ Pot", 180),
                           BetControl.Preset("Pot", 360), BetControl.Preset("All-in", 1_480)]
            bar.leadingAccessory = bet
            // The bet control comes and goes with the player's turn; the bar
            // keeps its height regardless, so the table never resizes.
            bar.minimumContentHeight = BetControl.height
            bar.setActions([
                ChromeAction(id: "fold", title: "Fold", keyEquivalent: "f") {},
                ChromeAction(id: "call", title: "Call 40", keyEquivalent: "c") {},
                ChromeAction(id: "raise", title: "Raise", style: .primary, keyEquivalent: "r") {},
            ], animated: false)
            let names = ["You", "Anna", "Boris", "Chloé", "Dmitri", "Elena"]
            for (i, name) in names.enumerated() {
                let seat = SeatView(name: name, detail: Chips.format([1_480, 920, 2_310, 0, 1_050, 760][i]),
                                    avatar: i == 0 ? .symbol("person.fill") : .initials)
                seat.state = i == 3 ? .folded : (i == 2 ? .active : .waiting)
                if i == 3 { seat.detail = "Folded" }
                seat.isThinking = i == 2
                seat.isDealer = i == 4
                seats.append(seat)
                addSubview(seat)
            }
        case .blackjack:
            sizePolicy = .blackjack
            bar.setActions([
                ChromeAction(id: "hit", title: "Hit", style: .primary, keyEquivalent: "h") {},
                ChromeAction(id: "stand", title: "Stand", keyEquivalent: "s") {},
                ChromeAction(id: "double", title: "Double", keyEquivalent: "d") {},
                ChromeAction(id: "split", title: "Split", isEnabled: false) {},
            ], animated: false)
        case .durak:
            sizePolicy = .durak
            bar.setActions([
                ChromeAction(id: "take", title: "Take", keyEquivalent: "t") {},
                ChromeAction(id: "done", title: "Done", style: .primary, keyEquivalent: "\r") {},
            ], animated: false)
            for (i, name) in ["Hiro", "Ingrid"].enumerated() {
                let seat = SeatView(name: name, detail: i == 0 ? "6 cards" : "4 cards", layout: .inline)
                seat.state = i == 1 ? .active : .waiting
                seats.append(seat)
                addSubview(seat)
            }
        }
        bar.install(in: self)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func layout() {
        bottomReserve = bar.reservedHeight
        super.layout()
    }

    override func layoutTable() {
        removeAllSprites()
        chipLayers.forEach { $0.removeFromSuperlayer() }
        chipLayers.removeAll()
        badges.forEach { $0.hide(animated: false) }
        badges.removeAll()
        switch kind {
        case .poker: layoutPoker()
        case .blackjack: layoutBlackjack()
        case .durak: layoutDurak()
        }
    }

    private var badges: [TableBadge] = []

    private func chips(_ amount: Int, at point: CGPoint, diameter: CGFloat = 28, label: Bool = true) {
        let stack = ChipStackLayer()
        stack.chipDiameter = diameter
        stack.showsLabel = label
        stack.setAmount(amount, animated: false)
        stack.position = point
        // On the cloth, under every card.
        addTableLayer(stack, z: -10)
        chipLayers.append(stack)
    }

    private func badge(_ text: String, tone: Banner.Tone = .neutral, at point: CGPoint,
                       anchor: TableBadge.Anchor = .above) {
        badges.append(TableBadge.show(text, tone: tone, in: self, at: point, anchor: anchor, animated: false))
    }

    private func layoutPoker() {
        let g = geometry
        var id = 0
        // Seats round the rail, the player at the bottom.
        let angles = TableGeometry.seatAngles(count: seats.count)
        for (seat, angle) in zip(seats, angles) {
            seat.frame.size = SeatView.stackedSize
            seat.centerAvatar(at: g.railPoint(angle: angle, inset: g.railWidth * 0.5))
        }
        func toward(_ point: CGPoint, _ f: CGFloat) -> CGPoint {
            CGPoint(x: point.x + (g.center.x - point.x) * f, y: point.y + (g.center.y - point.y) * f)
        }
        // The board, and the pot above it.
        let board = [Card(.spades, .ace), Card(.hearts, .king), Card(.spades, .ten), Card(.diamonds, .four)]
        let row = TableLayout.row(count: 5, center: CGPoint(x: g.center.x, y: g.center.y + cardSize.height * 0.12),
                                  cardSize: cardSize)
        for (i, pose) in row.enumerated() where i < board.count {
            sprite(id: id, card: board[i])
            place(id, pose: pose, faceUp: true, duration: 0)
            id += 1
        }
        chips(1_240, at: CGPoint(x: g.center.x, y: g.center.y - cardSize.height * 0.62))
        // Everyone's hole cards — the player's large and face up, the rest
        // small and face down — and their bets in front of them.
        for (i, angle) in angles.enumerated() where i != 3 {
            let seat = g.railPoint(angle: angle, inset: g.railWidth * 0.5)
            let mine = i == 0
            var poses: [CardPose]
            if mine {
                // Straight above the player's own seat, standing on the cloth
                // clear of the avatar and of the rail.
                let avatarTop = seat.y - SeatView.avatarSize / 2 - 8
                poses = TableLayout.fan(count: 2, anchor: CGPoint(x: seat.x, y: avatarTop - cardSize.height * 0.5),
                                        cardSize: cardSize, side: .bottom, style: .open, baseZ: 100)
                let box = TableLayout.bounds(of: poses, cardSize: cardSize)
                let lift = box.maxY - min(avatarTop, g.feltRect.maxY - 6)
                if lift > 0 {
                    poses = poses.map { var p = $0; p.position.y -= lift; return p }
                }
            } else {
                poses = TableLayout.fan(count: 2, anchor: toward(seat, 0.30), cardSize: cardSize, side: .bottom,
                                        style: .compact, scale: 0.62, baseZ: 100 + i * 2)
            }
            let hand = [Card(.spades, .king), Card(.spades, .queen)]
            for (j, pose) in poses.enumerated() {
                sprite(id: id, card: hand[j])
                place(id, pose: pose, faceUp: mine, duration: 0)
                id += 1
            }
            if mine {
                let box = TableLayout.bounds(of: poses, cardSize: cardSize)
                badge("Two pair", at: CGPoint(x: box.midX, y: box.minY))
            } else {
                chips([0, 40, 80, 0, 40, 40][i], at: toward(seat, 0.52), diameter: 24)
            }
        }
        // What a seat last did, beside its plate.
        if let raiser = seats[safe: 4] {
            badge("Raise 80", at: CGPoint(x: raiser.frame.minX, y: raiser.frame.maxY - 26), anchor: .leading)
        }
    }

    private func layoutBlackjack() {
        let g = geometry
        var id = 0
        // The dealer: one up, one down.
        let dealer = TableLayout.row(count: 2, center: g.dealerArea, cardSize: cardSize, gap: -0.35)
        for (i, pose) in dealer.enumerated() {
            sprite(id: id, card: i == 0 ? Card(.clubs, .seven) : Card(.diamonds, .ten))
            place(id, pose: pose, faceUp: i == 0, duration: 0)
            id += 1
        }
        let dealerBox = TableLayout.bounds(of: dealer, cardSize: cardSize)
        badge("7", at: CGPoint(x: dealerBox.midX, y: dealerBox.maxY), anchor: .below)
        // The cards still to come, squared up where the shoe stands.
        for pose in TableLayout.deck(count: 8, center: g.shoe, cardSize: cardSize, baseZ: 0) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        // The player's hand in the card band above the middle circle — where
        // the geometry says it goes, clear of every word on the cloth — and
        // the bet in the circle under it.
        if let spot = g.betSpots[safe: 1] {
            chips(150, at: CGPoint(x: spot.x, y: spot.y + g.betSpotRadius * 0.3), diameter: 30, label: false)
            let anchor = g.playerCardAnchor(forBetSpot: 1)
            let hand = TableLayout.cascade(count: 2, start: CGPoint(x: anchor.x - cardSize.width * 0.12,
                                                                    y: anchor.y + cardSize.height * 0.04),
                                           step: CGVector(dx: cardSize.width * 0.24, dy: -cardSize.height * 0.08),
                                           baseZ: 50)
            for (i, pose) in hand.enumerated() {
                sprite(id: id, card: i == 0 ? Card(.spades, .ace) : Card(.hearts, .king))
                place(id, pose: pose, faceUp: true, duration: 0)
                id += 1
            }
            let box = TableLayout.bounds(of: hand, cardSize: cardSize)
            badge("Blackjack", tone: .win, at: CGPoint(x: box.maxX, y: box.midY), anchor: .trailing)
        }
        if let spot = g.betSpots.first {
            chips(25, at: CGPoint(x: spot.x, y: spot.y + g.betSpotRadius * 0.3), diameter: 30, label: false)
        }
    }

    private func layoutDurak() {
        // The cloth inside the frame, below the window's strip and above the
        // bar.
        let play = playBounds.intersection(geometry.feltRect).insetBy(dx: 20, dy: 12)
        var id = 0
        // Two opponents' hands along the top, their seats beside them.
        for (i, seat) in seats.enumerated() {
            let x = play.minX + play.width * (i == 0 ? 0.28 : 0.72)
            let anchor = CGPoint(x: x, y: play.minY + cardSize.height * 0.42)
            for pose in TableLayout.fan(count: i == 0 ? 6 : 4, anchor: anchor, cardSize: cardSize, side: .top,
                                        style: .compact, scale: 0.72, baseZ: 10 * i) {
                sprite(id: id, card: Card(.clubs, .two))
                place(id, pose: pose, faceUp: false, duration: 0)
                id += 1
            }
            seat.frame.size = SeatView.inlineSize
            seat.frame.origin = CGPoint(x: x + cardSize.width * 1.1, y: play.minY + cardSize.height * 0.42 - 29)
        }
        // The deck and the trump, on the left.
        let deck = CGPoint(x: play.minX + cardSize.width * 0.9, y: play.midY - cardSize.height * 0.2)
        sprite(id: id, card: Card(.hearts, .nine))
        place(id, pose: TableLayout.trump(underDeckAt: deck, cardSize: cardSize, z: 0), faceUp: true, duration: 0)
        id += 1
        for pose in TableLayout.deck(count: 12, center: deck, cardSize: cardSize, baseZ: 1) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        // The fight in the middle.
        let fights = [(Card(.clubs, .eight), Card(.clubs, .queen)), (Card(.diamonds, .eight), Card(.hearts, .six)),
                      (Card(.spades, .eight), nil)]
        let pairs = TableLayout.battlePairs(count: fights.count, center: CGPoint(x: play.midX, y: play.midY - cardSize.height * 0.2),
                                            cardSize: cardSize, baseZ: 100)
        for (pair, fight) in zip(pairs, fights) {
            sprite(id: id, card: fight.0)
            place(id, pose: pair.attack, faceUp: true, duration: 0)
            id += 1
            if let defence = fight.1 {
                sprite(id: id, card: defence)
                place(id, pose: pair.defence, faceUp: true, duration: 0)
                id += 1
            }
        }
        // The discard pile, on the right.
        for pose in TableLayout.discardPile(count: 5, center: CGPoint(x: play.maxX - cardSize.width * 0.9, y: play.midY - cardSize.height * 0.2),
                                            cardSize: cardSize, seed: 3) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        // The player's hand.
        let hand: [Card] = [Card(.spades, .six), Card(.spades, .jack), Card(.diamonds, .ten), Card(.clubs, .ace),
                            Card(.hearts, .seven), Card(.hearts, .king), Card(.hearts, .ace)]
        var handIDs: [Int] = []
        for (i, pose) in TableLayout.fan(count: hand.count, anchor: CGPoint(x: play.midX, y: play.maxY - cardSize.height * 0.72),
                                         cardSize: cardSize, baseZ: 200).enumerated() {
            sprite(id: id, card: hand[i])
            place(id, pose: pose, faceUp: true, duration: 0)
            handIDs.append(id)
            id += 1
        }
        setPlayable(Set([handIDs[5], handIDs[6], handIDs[4]]))
    }
}

/// The gallery's table: rectangular cloth with everything on it.
final class KitGalleryTable: CardTableView {

    private var built = false

    init(frame: CGRect) {
        super.init(shape: .rectangular)
        self.frame = frame
        sizePolicy = CardSizePolicy(widthFraction: 0.040, heightFraction: 0.085, minimumWidth: 56, maximumWidth: 62)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    // Column geometry, shared by `build` and `layoutTable`.
    private var left: CGFloat { 56 }
    private var middle: CGFloat { (bounds.width * 0.355).rounded() }
    private var right: CGFloat { (bounds.width * 0.655).rounded() }
    private var top: CGFloat { TabletopChrome.topInset(for: self) + 34 }

    func build() {
        guard !built else { return }
        built = true
        let columnWidth = bounds.width * 0.30

        // MARK: Buttons
        var y = top
        y = heading("Buttons", x: left, y: y)
        let states: [(String, CapsuleButton.Interaction?, Bool)] = [
            ("Normal", nil, true), ("Hover", .hovered, true), ("Pressed", .pressed, true), ("Disabled", nil, false),
        ]
        let styles: [(String, CapsuleButton.Style, String?)] = [
            ("Primary", .primary, "play.fill"), ("Secondary", .secondary, "arrow.uturn.backward"),
            ("Destructive", .destructive, "xmark"), ("Confirm", .destructiveProminent, nil), ("Plain", .plain, nil),
        ]
        let cell: CGFloat = (columnWidth - 90) / 4
        for (i, state) in states.enumerated() {
            caption(state.0, x: left + 90 + CGFloat(i) * cell, y: y, width: cell - 8, center: true)
        }
        y += 22
        for style in styles {
            caption(style.0, x: left, y: y + 9, width: 88)
            for (i, state) in states.enumerated() {
                let button = CapsuleButton(title: style.0 == "Plain" ? "Details" : buttonTitle(style.1),
                                           symbolName: style.2, style: style.1)
                button.interactionOverride = state.1
                button.isEnabled = state.2
                place(button, x: left + 90 + CGFloat(i) * cell, y: y, width: cell - 12)
            }
            y += ControlHeight.regular + 12
        }
        // Sizes and a symbol-only button.
        y += 4
        caption("Sizes", x: left, y: y + 12, width: 88)
        var x = left + 90
        for (size, title) in [(CapsuleButton.Size.small, "Small"), (.regular, "Regular"), (.large, "Large")] {
            let button = CapsuleButton(title: title, style: .secondary, size: size)
            let width = button.intrinsicContentSize.width
            place(button, x: x, y: y + (ControlHeight.large - size.height) / 2, width: width)
            x += width + 12
        }
        let symbolOnly = CapsuleButton(title: "", symbolName: "lightbulb", style: .secondary, size: .large)
        symbolOnly.accessibilityTitle = "Hint"
        place(symbolOnly, x: x, y: y, width: ControlHeight.large)
        y += ControlHeight.large + 30

        // MARK: Glass, pills, toast
        y = heading("Glass, pills and toasts", x: left, y: y)
        let panel = GlassPanel(cornerRadius: Radius.panel)
        panel.frame = CGRect(x: left, y: y, width: columnWidth * 0.56, height: 104)
        addSubview(panel)
        let panelTitle = Typography.label("Glass panel", font: Typography.title2)
        panelTitle.frame = CGRect(x: 20, y: 18, width: panel.frame.width - 40, height: 22)
        panel.contentView.addSubview(panelTitle)
        let panelBody = Typography.label("Liquid Glass on macOS 26.",
                                         font: Typography.callout, color: Palette.textSecondary)
        panelBody.frame = CGRect(x: 20, y: 44, width: panel.frame.width - 40, height: 18)
        panel.contentView.addSubview(panelBody)
        let tinted = GlassPanel(cornerRadius: Radius.large, tint: NSColor(srgbRed: 0.55, green: 0.12, blue: 0.14, alpha: 1))
        tinted.frame = CGRect(x: panel.frame.maxX + 16, y: y, width: columnWidth - panel.frame.width - 16, height: 104)
        addSubview(tinted)
        let tintLabel = Typography.label("Tinted", font: Typography.headline)
        tintLabel.frame = CGRect(x: 18, y: 18, width: 120, height: 18)
        tinted.contentView.addSubview(tintLabel)
        y += 104 + 18
        var pillX = left
        for item in [StatusPillItem(id: "b", text: "Blinds 10/20", symbolName: "circle.grid.2x1.fill"),
                     StatusPillItem(id: "s", text: "Shoe 62%", symbolName: "rectangle.stack.fill"),
                     StatusPillItem(id: "t", text: "Trumps \u{2665}", isEmphasized: true)] {
            let pill = StatusPillView(item: item)
            let size = pill.intrinsicContentSize
            pill.frame = CGRect(x: pillX, y: y, width: size.width, height: size.height)
            addSubview(pill)
            pillX += size.width + 10
        }
        y += StatusPillView.height + 16
        let toast = Toast.show("Your turn", symbolName: "arrowtriangle.right.fill", in: self, placement: .top, duration: 60)
        toast.frame.origin = CGPoint(x: left, y: y)
        var badgeX = left + toast.frame.width + 16
        for (text, tone) in [("Soft 18", Banner.Tone.neutral), ("+50", .win), ("Bust", .loss)] {
            let badge = TableBadge.show(text, tone: tone, in: self, at: .zero, anchor: .center, animated: false)
            badge.move(to: CGPoint(x: badgeX + badge.frame.width / 2, y: y + 17), anchor: .center)
            badgeX += badge.frame.width + 10
        }
        caption("Table badges", x: badgeX + 4, y: y + 9, width: 120)
        y += 34 + 34

        // MARK: Bet control
        y = heading("Bet control", x: left, y: y)
        let bet = BetControl(minimum: 20, maximum: 1_480, step: 10, value: 360)
        bet.presets = [BetControl.Preset("Min", 20), BetControl.Preset("½ Pot", 180),
                       BetControl.Preset("Pot", 360), BetControl.Preset("All-in", 1_480)]
        let betPanel = GlassPanel(cornerRadius: Radius.large)
        betPanel.frame = CGRect(x: left, y: y, width: BetControl.width + 36, height: BetControl.height + 32)
        addSubview(betPanel)
        bet.frame = CGRect(x: 18, y: 16, width: BetControl.width, height: BetControl.height)
        betPanel.contentView.addSubview(bet)
        // The chip rack, the other way to bet: in a bar, as it would ride.
        let rackBar = ActionBar()
        let rack = ChipRackView()
        rack.available = 480
        rackBar.leadingAccessory = rack
        rackBar.setActions([ChromeAction(id: "deal", title: "Deal", style: .primary) {}], animated: false)
        let rackSize = rackBar.intrinsicContentSize
        rackBar.frame = CGRect(x: betPanel.frame.maxX + 20, y: y + (betPanel.frame.height - rackSize.height) / 2,
                               width: rackSize.width, height: rackSize.height)
        addSubview(rackBar)
        y += BetControl.height + 32 + 30

        // MARK: Table shapes
        y = heading("Table shapes", x: left, y: y)
        let thumbWidth = (columnWidth - 16) / 2
        let thumbHeight = min(thumbWidth * 0.62, bounds.height - y - 210)
        for (i, (shape, cloth)) in [(TableShape.oval, TableColor.blue), (.halfMoon(HalfMoonPrint(betSpots: 3)), .burgundy)]
            .enumerated() {
            let thumbnail = CALayer()
            thumbnail.frame = CGRect(x: left + CGFloat(i) * (thumbWidth + 16), y: y, width: thumbWidth, height: thumbHeight)
            thumbnail.cornerRadius = Radius.large
            thumbnail.cornerCurve = .continuous
            thumbnail.masksToBounds = true
            thumbnail.borderWidth = 0.5
            thumbnail.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
            let scale: CGFloat = 2
            // Painted at twice the thumbnail's size and shown shrunk, so the
            // markings are laid out as a real window would lay them out.
            let paintSize = CGSize(width: thumbWidth * 2.2, height: thumbHeight * 2.2)
            thumbnail.contents = ChipRenderer.render(size: paintSize, scale: scale / 2.2 * 2) { ctx in
                let geometry = TableSurface.geometry(for: shape, in: CGRect(origin: .zero, size: paintSize),
                                                     topInset: 20, bottomReserve: 60, cardWidth: 90)
                TableSurface.paint(geometry, cloth: cloth, context: ctx, cardWidth: 90)
            }
            thumbnail.contentsGravity = .resize
            let frame = thumbnail.frame
            addChrome(layer: thumbnail)
            caption(i == 0 ? "Oval (poker)" : "Half-moon (blackjack)", x: frame.minX, y: frame.maxY + 6, width: thumbWidth)
        }

        // MARK: Action bars, along the bottom where a game puts them
        var barY = bounds.height - 150
        barY = heading("Action bar", x: left, y: barY)
        let bar = ActionBar()
        let barBet = BetControl(minimum: 40, maximum: 2_000, step: 20, value: 120)
        barBet.presets = [BetControl.Preset("Min", 40), BetControl.Preset("½ Pot", 120),
                          BetControl.Preset("Pot", 240), BetControl.Preset("All-in", 2_000)]
        bar.leadingAccessory = barBet
        bar.setActions([
            ChromeAction(id: "fold", title: "Fold", style: .secondary, keyEquivalent: "f") {},
            ChromeAction(id: "call", title: "Call 40", style: .secondary, keyEquivalent: "c") {},
            ChromeAction(id: "raise", title: "Raise", style: .primary, keyEquivalent: "r") {},
        ], animated: false)
        let barSize = bar.intrinsicContentSize
        bar.frame = CGRect(x: left, y: barY, width: barSize.width, height: barSize.height)
        addSubview(bar)
        let simple = ActionBar()
        simple.setActions([
            ChromeAction(id: "hit", title: "Hit", symbolName: "plus", style: .primary, keyEquivalent: "h") {},
            ChromeAction(id: "stand", title: "Stand", symbolName: "hand.raised.fill", style: .secondary) {},
            ChromeAction(id: "double", title: "Double", style: .secondary) {},
            ChromeAction(id: "split", title: "Split", style: .secondary, isEnabled: false) {},
        ], animated: false)
        let simpleSize = simple.intrinsicContentSize
        simple.frame = CGRect(x: bar.frame.maxX + 28, y: barY + (barSize.height - simpleSize.height) / 2,
                              width: simpleSize.width, height: simpleSize.height)
        addSubview(simple)
        let destructive = ActionBar()
        destructive.setActions([
            ChromeAction(id: "take", title: "Take", style: .secondary) {},
            ChromeAction(id: "leave", title: "Leave Table", symbolName: "xmark", style: .destructive) {},
        ], animated: false)
        let destructiveSize = destructive.intrinsicContentSize
        destructive.frame = CGRect(x: simple.frame.maxX + 28, y: barY + (barSize.height - destructiveSize.height) / 2,
                                   width: destructiveSize.width, height: destructiveSize.height)
        addSubview(destructive)

        y = top
        // MARK: Options card and banner
        y = heading("Options card", x: middle, y: y)
        let options = OptionsCard(title: "New Game", subtitle: "Six-max Texas Hold’em. Blinds rise every ten hands.",
                                  rows: [
                                      OptionsCard.Row(id: "opponents", title: "Opponents", options: ["1", "2", "3", "4", "5"], selectedIndex: 4),
                                      OptionsCard.Row(id: "difficulty", title: "Difficulty",
                                                      options: ["Relaxed", "Standard", "Sharp"], selectedIndex: 1),
                                      OptionsCard.Row(id: "stack", title: "Starting stack",
                                                      options: ["500", "1,000", "5,000"], selectedIndex: 1),
                                  ])
        options.onCancel = {}
        options.frame.origin = CGPoint(x: middle, y: y)
        addSubview(options)
        y += options.frame.height + 34
        y = heading("Banner", x: middle, y: y)
        let banner = Banner(title: "You win 1,240", subtitle: "Full house, kings over sevens", symbolName: "crown.fill",
                            tone: .win, actions: [ChromeAction(id: "next", title: "Next Hand", style: .primary) {}])
        banner.frame.origin = CGPoint(x: middle, y: y)
        addSubview(banner)

        // MARK: Seats
        y = top
        y = heading("Seats", x: right, y: y)
        let seats: [(String, String, SeatView.State, Bool, Bool, SeatView.Avatar)] = [
            ("You", "1,480", .active, false, false, .symbol("person.fill")),
            ("Anna", "Thinking…", .active, true, true, .initials),
            ("Boris", "Folded", .folded, false, false, .initials),
            ("Dmitri", "Wins 1,240", .winner, false, false, .initials),
        ]
        let seatGap = ((bounds.width - 40 - right) - SeatView.stackedSize.width * CGFloat(seats.count))
            / CGFloat(seats.count - 1)
        for (i, s) in seats.enumerated() {
            let seat = SeatView(name: s.0, detail: s.1, avatar: s.5)
            seat.state = s.2
            seat.isThinking = s.3
            seat.isDealer = s.4
            seat.frame = CGRect(x: right + CGFloat(i) * (SeatView.stackedSize.width + seatGap), y: y,
                                width: SeatView.stackedSize.width, height: SeatView.stackedSize.height)
            addSubview(seat)
        }
        y += SeatView.stackedSize.height + 14
        let inline = SeatView(name: "Elena", detail: "6 cards", layout: .inline)
        inline.frame = CGRect(x: right, y: y, width: SeatView.inlineSize.width, height: SeatView.inlineSize.height)
        addSubview(inline)
        let inlineOut = SeatView(name: "Chloé", detail: "Out", layout: .inline)
        inlineOut.state = .out
        inlineOut.frame = CGRect(x: right + SeatView.inlineSize.width + 24, y: y,
                                 width: SeatView.inlineSize.width, height: SeatView.inlineSize.height)
        addSubview(inlineOut)
        y += SeatView.inlineSize.height + 30

        // MARK: Chips
        y = heading("Chips", x: right, y: y)
        chipsTop = y
        y += 148
        cardsTop = heading("Cards", x: right, y: y)
    }

    private var chipsTop: CGFloat = 0
    private var cardsTop: CGFloat = 0
    private var chipLayers: [CALayer] = []

    override func layoutTable() {
        guard built else { return }
        // Chips: one of each denomination, then stacks of five amounts.
        chipLayers.forEach { $0.removeFromSuperlayer() }
        chipLayers.removeAll()
        let scale = window?.backingScaleFactor ?? 2
        var x = right + 18
        for denomination in Chips.denominations {
            let chip = CALayer()
            chip.contents = ChipRenderer.chipImage(denomination, diameter: 36, scale: scale)
            chip.bounds = CGRect(x: 0, y: 0, width: 36 * 1.3, height: 36 * 1.3)
            chip.position = CGPoint(x: x, y: chipsTop + 22)
            addTableLayer(chip, z: -10)
            chipLayers.append(chip)
            x += 46
        }
        x = right + 4
        for amount in [37, 260, 1_485, 12_340] {
            let stack = ChipStackLayer()
            stack.chipDiameter = 28
            stack.setAmount(amount, animated: false)
            stack.position = CGPoint(x: x + stack.bounds.width / 2, y: chipsTop + 108)
            addTableLayer(stack, z: -10)
            chipLayers.append(stack)
            x += stack.bounds.width + 10
        }

        // Cards: the community row, a deck with the trump under it, a
        // discard pile; an opponent's hand, a side opponent's, a durak fight;
        // and the player's own hand.
        removeAllSprites()
        let w = cardSize.width, h = cardSize.height
        var id = 0
        let area = CGRect(x: right, y: cardsTop, width: bounds.width - 40 - right, height: bounds.height - 170 - cardsTop)

        let rowY = area.minY + h / 2 + 8
        let board = [Card(.spades, .ace), Card(.hearts, .king), Card(.spades, .ten), Card(.diamonds, .four), Card(.spades, .queen)]
        let rowWidth = w * 5 + w * 0.14 * 4
        for (i, pose) in TableLayout.row(count: 5, center: CGPoint(x: area.minX + rowWidth / 2 + 4, y: rowY),
                                         cardSize: cardSize).enumerated() {
            sprite(id: id, card: board[i])
            place(id, pose: pose, faceUp: true, duration: 0)
            id += 1
        }
        let deckCenter = CGPoint(x: area.minX + rowWidth + w * 1.0, y: rowY)
        sprite(id: id, card: Card(.hearts, .nine))
        place(id, pose: TableLayout.trump(underDeckAt: deckCenter, cardSize: cardSize, z: 0), faceUp: true, duration: 0)
        id += 1
        for pose in TableLayout.deck(count: 12, center: deckCenter, cardSize: cardSize, baseZ: 1) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        let discard = [Card(.clubs, .seven), Card(.diamonds, .queen), Card(.hearts, .eight), Card(.spades, .king)]
        for (i, pose) in TableLayout.discardPile(count: discard.count, center: CGPoint(x: area.maxX - w * 0.7, y: rowY),
                                                  cardSize: cardSize, seed: 7).enumerated() {
            sprite(id: id, card: discard[i])
            place(id, pose: pose, faceUp: i == discard.count - 1, duration: 0)
            id += 1
        }

        let midY = rowY + h * 1.35
        for pose in TableLayout.fan(count: 6, anchor: CGPoint(x: area.minX + w * 1.3, y: midY),
                                    cardSize: cardSize, side: .top, style: .compact) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        for pose in TableLayout.fan(count: 5, anchor: CGPoint(x: area.minX + w * 3.4, y: midY),
                                    cardSize: cardSize, side: .left, style: .compact) {
            sprite(id: id, card: Card(.clubs, .two))
            place(id, pose: pose, faceUp: false, duration: 0)
            id += 1
        }
        let pairs = TableLayout.battlePairs(count: 2, center: CGPoint(x: area.maxX - w * 2.0, y: midY),
                                            cardSize: cardSize, baseZ: 50)
        let fights = [(Card(.clubs, .eight), Card(.clubs, .queen)), (Card(.diamonds, .eight), Card(.hearts, .six))]
        for (pair, fight) in zip(pairs, fights) {
            sprite(id: id, card: fight.0)
            place(id, pose: pair.attack, faceUp: true, duration: 0)
            id += 1
            sprite(id: id, card: fight.1)
            place(id, pose: pair.defence, faceUp: true, duration: 0)
            id += 1
        }

        let hand: [Card] = [Card(.spades, .six), Card(.spades, .jack), Card(.diamonds, .ten),
                            Card(.clubs, .ace), Card(.hearts, .king), Card(.hearts, .ace)]
        let handAnchor = CGPoint(x: area.midX - w * 0.6, y: min(area.maxY - h * 0.55, midY + h * 1.45))
        var handIDs: [Int] = []
        for (i, pose) in TableLayout.fan(count: hand.count, anchor: handAnchor, cardSize: cardSize).enumerated() {
            sprite(id: id, card: hand[i])
            place(id, pose: pose, faceUp: true, duration: 0)
            handIDs.append(id)
            id += 1
        }
        setPlayable([handIDs[1], handIDs[3]])
        setSelected(handIDs[4], true)
        if handCaption == nil {
            handCaption = caption("Hand: two playable, one selected", x: handAnchor.x + w * 2.3, y: handAnchor.y - 8,
                                  width: 200)
        }
    }

    private var handCaption: NSTextField?

    // MARK: Helpers

    private func buttonTitle(_ style: CapsuleButton.Style) -> String {
        switch style {
        case .primary: return "Play"
        case .secondary: return "Undo"
        case .destructive: return "Leave"
        case .destructiveProminent: return "Leave"
        case .plain: return "Details"
        }
    }

    @discardableResult
    private func heading(_ text: String, x: CGFloat, y: CGFloat) -> CGFloat {
        let label = Typography.label("", font: Typography.eyebrow, color: Palette.textSecondary)
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: Typography.attributes(
            Typography.eyebrow, Palette.textSecondary, kern: Typography.eyebrowKern))
        label.sizeToFit()
        label.frame.origin = CGPoint(x: x, y: y)
        addSubview(label)
        return y + label.frame.height + 12
    }

    @discardableResult
    private func caption(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, center: Bool = false) -> NSTextField {
        let label = Typography.label(text, font: Typography.caption, color: Palette.textTertiary)
        label.alignment = center ? .center : .left
        label.frame = CGRect(x: x, y: y, width: width, height: 16)
        addSubview(label)
        return label
    }

    private func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat) {
        view.frame = CGRect(x: x, y: y, width: width, height: view.intrinsicContentSize.height)
        addSubview(view)
    }

    /// A layer that belongs to the gallery's chrome rather than the cloth.
    private func addChrome(layer: CALayer) {
        let host = NSView(frame: layer.frame)
        host.wantsLayer = true
        layer.frame = host.bounds
        host.layer?.addSublayer(layer)
        addSubview(host)
    }
}
