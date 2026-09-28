//
//  DurakTableView.swift
//  The durak table: the cards, the seats, and the player's hands on them.
//
//  Built on the kit's `CardTableView`. Every one of the thirty-six cards is
//  a sprite whose id is its `durakIndex`, and where each one lies is worked
//  out from one model — `snapshot`, the table as the player sees it — by
//  `DurakLayout`. So there is one way cards move: change the snapshot, then
//  `sync`, which sends every card whose place changed to its new one. A
//  resize is a `sync` without animation; an attack is a `sync` after the
//  attacking card has left a hand; a deal is a `sync` with each card given
//  its own moment to leave the deck.
//
//  The engine's events arrive in batches (one action can end a bout, refill
//  four hands and start the next); `present` shows them one at a time,
//  paced on the table's scheduler, applying each to the snapshot, and calls
//  back when the table has caught up with the engine.
//
//  PLAYING A CARD
//
//  * Click: a card that can do only one thing does it. A defender's card
//    that could beat more than one attacking card — or beat one and also
//    transfer — is picked up instead: the cards it can beat glow (and, in
//    perevodnoy, the transfer place beside the row), and the next click
//    chooses. Clicking it again, or the cloth, or Escape, puts it back.
//  * Drag: anywhere between the hands to attack or throw in; onto an
//    attacking card to beat that one; onto the transfer place to transfer.
//  * Keys: the action bar's buttons carry T (Take) and Return (Bito, Pass,
//    Done); Space does what Return does.
//

import AppKit
import QuartzCore

/// The player's side of a decision: what they may do, card by card.
struct DurakPrompt {
    let state: DurakState
    let legal: [DurakAction]

    init(state: DurakState, seat: Int = DurakMatch.human) {
        self.state = state
        legal = state.legalActions(for: seat)
    }

    /// Every card that can go on the table now.
    var playable: Set<Card> { Set(legal.compactMap(\.card)) }

    /// The ways `card` can be played: one attack, or a defence against each
    /// attacking card it beats plus a transfer.
    func actions(for card: Card) -> [DurakAction] {
        legal.filter { $0.card == card }
    }

    var canTransfer: Bool {
        legal.contains { if case .transfer = $0 { return true } else { return false } }
    }

    /// The card a Transfer button plays: a plain card before a trump.
    var bestTransfer: DurakAction? {
        let transfers = legal.filter { if case .transfer = $0 { return true } else { return false } }
        return transfers.min { a, b in
            let ca = a.card.map { $0.suit == state.trump ? 1 : 0 } ?? 0
            let cb = b.card.map { $0.suit == state.trump ? 1 : 0 } ?? 0
            return ca < cb
        }
    }
}

@MainActor
final class DurakTableView: CardTableView {

    // MARK: Model

    /// The table as the player sees it.
    private(set) var snapshot: DurakTableSnapshot
    /// Seat 0 is the player ("You").
    private(set) var names: [String] = []
    var handOrder: DurakHandOrder = .bySuit {
        didSet { if handOrder != oldValue { sync(duration: Motion.isEnabled ? 0.34 : 0) } }
    }
    /// Seeds the bito pile's mess, so it lies the same after a relaunch.
    var pileSeed: UInt64 = 1

    /// The player's decision, when it is theirs and nothing is being shown;
    /// nil otherwise. Setting it lifts and lights the playable cards.
    var prompt: DurakPrompt? {
        didSet { promptChanged() }
    }

    /// The player chose an action — by a click, a drag or a key. Returns
    /// whether it was taken; a dropped card that was not flies home.
    var onAction: ((DurakAction) -> Bool)?

    /// The seat whose decision it is, for its ring; and the bot thinking.
    var activeSeat: Int? { didSet { if activeSeat != oldValue { updateSeats() } } }
    var thinkingSeat: Int? { didSet { if thinkingSeat != oldValue { updateSeats() } } }

    /// A defender's card picked up by a click, waiting for its target.
    private(set) var selectedCard: Card?

    // MARK: Chrome

    let actionBar = ActionBar()
    private var seats: [SeatView] = []
    private var deckBadge: TableBadge?
    private let transferZone = CAShapeLayer()
    /// While an attacking card is dragged: the place it will land in.
    private let nextPlace = CAShapeLayer()
    /// Where the pointer is during a drag, for lighting what it is over.
    private var dragPoint: CGPoint?
    private var transferBadge: TableBadge?
    private var speech: [Int: TableBadge] = [:]
    /// The lowest trump being shown at the opening.
    private var reveal: (seat: Int, card: Card)?
    private var dragCard: Card?
    private var dragTargets: Set<Card> = []

    // MARK: Presentation

    private var queue: [DurakEvent] = []
    private var finalState: DurakState?
    private var queueCompletion: (() -> Void)?
    private var stepToken: TableScheduler.Token?

    // MARK: Init

    init(playerCount: Int) {
        snapshot = DurakTableSnapshot(emptyTable: playerCount)
        super.init(shape: .rectangular)
        sizePolicy = DurakLayout.sizePolicy
        // The bar never carries an accessory, so its height — and the
        // table's reserve under it — never changes.
        actionBar.minimumContentHeight = ControlHeight.regular
        actionBar.install(in: self)
        actionBar.isHidden = true
        bottomReserve = ActionBar.reservedHeight(contentHeight: ControlHeight.regular)

        for place in [transferZone, nextPlace] {
            place.fillColor = NSColor(white: 1, alpha: 0.05).cgColor
            place.strokeColor = NSColor(white: 1, alpha: 0.42).cgColor
            place.lineWidth = 1.5
            place.lineDashPattern = [6, 5]
            place.isHidden = true
            addTableLayer(place, z: -5)
        }

        configure(names: Self.placeholderNames(playerCount))
        setAccessibilityLabel(NSLocalizedString("Durak table", comment: "accessibility: the durak table"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    static func placeholderNames(_ playerCount: Int) -> [String] {
        [NSLocalizedString("You", comment: "durak: the player's seat")]
            + Array(repeating: "", count: max(0, playerCount - 1))
    }

    /// Seats the players: `names[0]` is the player.
    func configure(names: [String]) {
        guard names != self.names else { return }
        self.names = names
        seats.forEach { $0.removeFromSuperview() }
        seats = names.enumerated().map { seat, name in
            let view = SeatView(name: name, detail: "",
                                avatar: seat == DurakMatch.human ? .symbol("person.fill") : .initials,
                                layout: .inline)
            view.isHidden = name.isEmpty
            return view
        }
        // Under the bar and any banner: seats are part of the table.
        for seat in seats { addSubview(seat, positioned: .below, relativeTo: actionBar) }
        needsLayout = true
        updateSeats()
    }

    /// The table for a new game or a restored one, laid out at once.
    func show(_ snapshot: DurakTableSnapshot) {
        cancelPresentation()
        self.snapshot = snapshot
        reveal = nil
        selectedCard = nil
        hideSpeech()
        sync(duration: 0)
        updateSeats()
    }

    /// Holds the opening's lowest trump up where everyone can see it — the
    /// moment the `opening` screenshot shows.
    func holdReveal(_ seat: Int, _ card: Card) {
        reveal = (seat, card)
        sync(duration: 0)
    }

    // MARK: Geometry

    var layoutModel: DurakLayout {
        DurakLayout(felt: geometry.feltRect, play: playBounds.intersection(geometry.feltRect),
                    cardSize: cardSize, playerCount: snapshot.playerCount)
    }

    private static func id(_ card: Card) -> Int { card.durakIndex }
    private static func card(_ id: Int) -> Card? { (0..<36).contains(id) ? Card.durak(index: id) : nil }

    /// The player's hand, left to right.
    var displayedHand: [Card] {
        guard let trump = snapshot.trumpCard?.suit, let hand = snapshot.hands.first else { return snapshot.hands.first ?? [] }
        return Card.durakSorted(hand, trump: trump, order: handOrder)
    }

    private struct Target {
        var pose: CardPose
        var faceUp: Bool
    }

    /// Where every card belongs right now.
    private func targets(_ layout: DurakLayout) -> [Int: Target] {
        var result: [Int: Target] = [:]
        let deck = snapshot.deckCards
        for (pose, card) in zip(layout.deck(count: deck.count), deck) {
            result[Self.id(card)] = Target(pose: pose, faceUp: false)
        }
        if let trump = snapshot.trumpUnderDeck {
            result[Self.id(trump)] = Target(pose: layout.trumpPose, faceUp: true)
        }
        for (pose, card) in zip(layout.discard(count: snapshot.discard.count, seed: pileSeed), snapshot.discard) {
            result[Self.id(card)] = Target(pose: pose, faceUp: false)
        }
        let pairs = snapshot.table.count
        for (i, pair) in snapshot.table.enumerated() {
            let poses = layout.pair(i, of: pairs, attack: pair.attack, defence: pair.defence)
            result[Self.id(pair.attack)] = Target(pose: poses.attack, faceUp: true)
            if let defence = pair.defence { result[Self.id(defence)] = Target(pose: poses.defence, faceUp: true) }
        }
        for seat in snapshot.hands.indices {
            if seat == DurakMatch.human {
                let hand = displayedHand
                let playable = prompt?.playable ?? []
                let lifted = Set(hand.indices.filter { playable.contains(hand[$0]) })
                for (pose, card) in zip(layout.humanHand(count: hand.count, lifted: lifted), hand) {
                    result[Self.id(card)] = Target(pose: pose, faceUp: true)
                }
            } else if layout.places.indices.contains(seat) {
                let hand = snapshot.hands[seat]
                // At the end the durak's cards are turned up: everyone
                // wants to see what they were left holding.
                let shown = snapshot.result == .durak(seat)
                // Face down, the order does not show; turned up, it is
                // sorted like any hand.
                let cards = shown ? Card.durakSorted(hand, trump: snapshot.trumpCard?.suit ?? .hearts, order: .bySuit) : hand
                for (pose, card) in zip(layout.botHand(layout.places[seat], count: hand.count, seat: seat, shown: shown), cards) {
                    result[Self.id(card)] = Target(pose: pose, faceUp: shown)
                }
            }
        }
        if let reveal, result[Self.id(reveal.card)] != nil {
            result[Self.id(reveal.card)] = Target(pose: layout.revealPose(reveal.seat), faceUp: true)
        }
        return result
    }

    /// Sends every card whose place changed to its new one, taking
    /// `duration`; `delay` staggers each card's departure (a deal, a sweep).
    /// Cards already where they belong are left alone.
    private func sync(duration: CFTimeInterval, delay: (Card) -> CFTimeInterval = { _ in 0 }) {
        let layout = layoutModel
        let animate = Motion.isEnabled && duration > 0
        for (id, target) in targets(layout) {
            guard let card = Self.card(id) else { continue }
            if existingSprite(id) == nil { sprite(id: id, card: card) }
            guard pose(of: id) != target.pose || isFaceUp(id) != target.faceUp
                    || existingSprite(id)?.isHidden == true && !target.pose.isHidden else { continue }
            place(id, pose: target.pose, faceUp: target.faceUp, duration: animate ? duration : 0,
                  delay: animate ? delay(card) : 0)
        }
        placeChrome(layout)
        refreshHighlights()
    }

    // MARK: Layout

    override func layoutTable() {
        sync(duration: 0)
    }

    private func placeChrome(_ layout: DurakLayout) {
        for (seat, view) in seats.enumerated() where layout.places.indices.contains(seat) {
            view.frame = layout.seatFrame(seat)
        }
        // The count under the deck.
        let left = snapshot.trumpTurned ? snapshot.stock.count : 0
        if left > 0 {
            let text = String.localizedStringWithFormat(
                NSLocalizedString("%d", comment: "durak: the number of cards left in the deck, under it"), left)
            if let deckBadge {
                deckBadge.update(text: text)
                deckBadge.move(to: layout.deckCountPoint, anchor: .below)
            } else {
                deckBadge = TableBadge.show(text, in: self, at: layout.deckCountPoint, anchor: .below, animated: false)
            }
            deckBadge?.setAccessibilityLabel(Plural.format(
                left, one: NSLocalizedString("%d card left in the deck", comment: "durak accessibility"),
                other: NSLocalizedString("%d cards left in the deck", comment: "durak accessibility")))
        } else {
            deckBadge?.hide(animated: Motion.isEnabled && window != nil)
            deckBadge = nil
        }
        // The transfer place, when the player may transfer; lit gold while a
        // card that can transfer is dragged over it.
        let showZone = prompt?.canTransfer == true
        let zoneRect = layout.transferZone(count: snapshot.table.count)
        let zoneHot = dragCard.map { card in
            prompt?.actions(for: card).contains(.transfer(card)) == true
                && dragPoint.map { zoneRect.insetBy(dx: -cardSize.width * 0.25, dy: -12).contains($0) } == true
        } ?? false
        style(transferZone, rect: zoneRect, visible: showZone, hot: zoneHot)
        // The next place in the row, while an attacking card is dragged.
        let attacking = dragCard.map { prompt?.actions(for: $0).contains(.attack($0)) == true } ?? false
        style(nextPlace, rect: layout.emptyPlace(count: snapshot.table.count), visible: attacking,
              hot: attacking && dragPoint.map { layout.fightRect.contains($0) } == true)
        if showZone {
            // The word under the place, not in it: the place stays the shape
            // of the card that goes there.
            let point = CGPoint(x: zoneRect.midX, y: zoneRect.maxY + 2)
            if let transferBadge {
                transferBadge.move(to: point, anchor: .below)
            } else {
                transferBadge = TableBadge.show(NSLocalizedString("Transfer", comment: "durak: the place a transfer card goes («Перевести»)"),
                                                symbolName: "arrow.turn.up.right", in: self, at: point, anchor: .below,
                                                animated: Motion.isEnabled && window != nil)
            }
        } else if let transferBadge {
            transferBadge.hide(animated: Motion.isEnabled && window != nil)
            self.transferBadge = nil
        }
        for (seat, badge) in speech {
            let spot = layout.speechPoint(seat)
            badge.move(to: spot.point, anchor: spot.anchor)
        }
    }

    /// A dashed place on the cloth: quiet, or gold while something is over it.
    private func style(_ place: CAShapeLayer, rect: CGRect, visible: Bool, hot: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place.isHidden = !visible
        if visible {
            place.frame = rect
            place.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                cornerWidth: cornerRadius + 3, cornerHeight: cornerRadius + 3, transform: nil)
            place.strokeColor = (hot ? Palette.accent : NSColor(white: 1, alpha: 0.42)).cgColor
            place.fillColor = (hot ? Palette.accent.withAlphaComponent(0.10) : NSColor(white: 1, alpha: 0.05)).cgColor
        }
        CATransaction.commit()
    }

    // MARK: Seats

    /// Names, card counts, and what each seat is doing in the bout.
    func updateSeats() {
        let over = snapshot.result != nil
        for (seat, view) in seats.enumerated() {
            let count = snapshot.hands.indices.contains(seat) ? snapshot.hands[seat].count : 0
            let cards = Plural.format(count, one: NSLocalizedString("%d card", comment: "durak seat: cards in hand"),
                                      other: NSLocalizedString("%d cards", comment: "durak seat: cards in hand"))
            var word: String?
            if case .durak(let loser)? = snapshot.result, loser == seat {
                word = NSLocalizedString("Durak", comment: "durak seat: the loser («Дурак»)")
            } else if snapshot.isOut(seat) {
                word = nil
            } else if !over && snapshot.trumpTurned {
                if seat == snapshot.defender {
                    word = snapshot.takingSeat == seat
                        ? NSLocalizedString("Takes", comment: "durak seat: the defender is picking up («Берёт»)")
                        : NSLocalizedString("Defending", comment: "durak seat status")
                } else if seat == snapshot.attacker {
                    word = NSLocalizedString("Attacking", comment: "durak seat status")
                }
            }
            if !snapshot.trumpTurned {
                view.detail = ""        // nothing dealt yet
            } else if snapshot.isOut(seat) {
                view.detail = NSLocalizedString("Out", comment: "durak seat: no cards left, safe")
            } else if let word {
                view.detail = String(format: NSLocalizedString("%@ · %@", comment: "durak seat: card count · status"),
                                     cards, word)
            } else {
                view.detail = cards
            }
            if over {
                view.state = .waiting
            } else if snapshot.isOut(seat) {
                view.state = .out
            } else {
                view.state = activeSeat == seat ? .active : .waiting
            }
            view.isThinking = thinkingSeat == seat && activeSeat == seat
        }
    }

    // MARK: Highlights and the prompt

    private func promptChanged() {
        if let selectedCard, prompt?.playable.contains(selectedCard) != true { self.selectedCard = nil }
        sync(duration: Motion.isEnabled && window != nil ? 0.22 : 0)
    }

    private func refreshHighlights() {
        var lit = Set<Int>()
        if let prompt, dragCard == nil {
            for card in prompt.playable where snapshot.hands.first?.contains(card) == true { lit.insert(Self.id(card)) }
        }
        for card in selectionTargets.union(dragTargets) { lit.insert(Self.id(card)) }
        setPlayable(lit)
        let selected = selectedCard.map(Self.id)
        for id in selectedSprites where id != selected { setSelected(id, false) }
        if let selected { setSelected(selected, true) }
        setHoverable(Set((snapshot.hands.first ?? []).map(Self.id)))
    }

    /// The attacking cards the selected card can beat.
    private var selectionTargets: Set<Card> {
        guard let selectedCard, let prompt else { return [] }
        return Set(prompt.actions(for: selectedCard).compactMap {
            if case .defend(_, let attack) = $0 { return attack } else { return nil }
        })
    }

    private func select(_ card: Card?) {
        selectedCard = card
        refreshHighlights()
        if card != nil {
            let canTransfer = card.map { prompt?.actions(for: $0).contains(.transfer($0)) == true } ?? false
            toast(canTransfer ? NSLocalizedString("Choose a card to beat, or transfer", comment: "durak hint")
                              : NSLocalizedString("Choose the card to beat", comment: "durak hint"),
                  symbol: "target")
        }
    }

    func clearSelection() {
        guard selectedCard != nil else { return }
        selectedCard = nil
        refreshHighlights()
        Toast.hide(in: self)
    }

    // MARK: Pointer

    @discardableResult
    private func perform(_ action: DurakAction) -> Bool {
        selectedCard = nil
        dragTargets = []
        return onAction?(action) ?? false
    }

    override func spriteClicked(_ id: Int, with event: NSEvent) {
        click(id)
    }

    /// A click on card `id` — the same path VoiceOver's press and the
    /// self-tests take.
    func click(_ id: Int) {
        guard let card = Self.card(id) else { return }
        if snapshot.hands.first?.contains(card) == true {
            clickHandCard(card)
        } else if let selectedCard, let prompt,
                  prompt.actions(for: selectedCard).contains(.defend(selectedCard, on: card)) {
            perform(.defend(selectedCard, on: card))
        } else {
            clearSelection()
        }
    }

    private func clickHandCard(_ card: Card) {
        guard let prompt else { return }
        if selectedCard == card {
            clearSelection()
            return
        }
        let options = prompt.actions(for: card)
        switch options.count {
        case 0: clearSelection()
        case 1: perform(options[0])
        default: select(card)
        }
    }

    override func tableClicked(at point: CGPoint, with event: NSEvent) {
        clickCloth(at: point)
    }

    func clickCloth(at point: CGPoint) {
        if let selectedCard, let prompt, prompt.actions(for: selectedCard).contains(.transfer(selectedCard)),
           layoutModel.transferZone(count: snapshot.table.count).insetBy(dx: -8, dy: -8).contains(point) {
            perform(.transfer(selectedCard))
        } else {
            clearSelection()
        }
    }

    override func draggableSprites(startingAt id: Int) -> [Int]? {
        guard let card = Self.card(id), let prompt, snapshot.hands.first?.contains(card) == true,
              prompt.playable.contains(card) else { return nil }
        selectedCard = nil
        dragCard = card
        dragTargets = Set(prompt.actions(for: card).compactMap {
            if case .defend(_, let attack) = $0 { return attack } else { return nil }
        })
        Toast.hide(in: self)
        refreshHighlights()
        placeChrome(layoutModel)
        return [id]
    }

    override func spritesDragged(_ ids: [Int], to point: CGPoint) {
        dragPoint = point
        placeChrome(layoutModel)
    }

    override func spritesDropped(_ ids: [Int], at point: CGPoint) -> Bool {
        let card = dragCard
        dragCard = nil
        dragPoint = nil
        dragTargets = []
        refreshHighlights()
        placeChrome(layoutModel)
        guard let card, let action = dropAction(for: card, at: point) else { return false }
        return perform(action)
    }

    /// What dropping `card` at `point` means, if anything.
    func dropAction(for card: Card, at point: CGPoint) -> DurakAction? {
        guard let prompt else { return nil }
        let options = prompt.actions(for: card)
        guard !options.isEmpty else { return nil }
        let layout = layoutModel
        if options.contains(.attack(card)) {
            return layout.fightRect.contains(point) ? .attack(card) : nil
        }
        // Onto an attacking card: that one — the card under the pointer, or
        // the nearest one the pointer is close to.
        let targets = options.compactMap { action -> (Card, DurakAction)? in
            if case .defend(_, let attack) = action { return (attack, action) } else { return nil }
        }
        if let id = sprite(at: point), let hit = Self.card(id), let match = targets.first(where: { $0.0 == hit }) {
            return match.1
        }
        let near = targets.compactMap { target -> (CGFloat, DurakAction)? in
            guard let pose = pose(of: Self.id(target.0)) else { return nil }
            let box = TableLayout.boundingBox(of: pose, cardSize: cardSize).insetBy(dx: -cardSize.width * 0.3,
                                                                                 dy: -cardSize.height * 0.2)
            guard box.contains(point) else { return nil }
            return (hypot(point.x - pose.position.x, point.y - pose.position.y), target.1)
        }
        if let best = near.min(by: { $0.0 < $1.0 }) { return best.1 }
        if options.contains(.transfer(card)),
           layout.transferZone(count: snapshot.table.count).insetBy(dx: -cardSize.width * 0.25, dy: -12).contains(point) {
            return .transfer(card)
        }
        // Anywhere else between the hands: only if there is nothing to choose.
        if options.count == 1, layout.fightRect.contains(point) { return options[0] }
        return nil
    }

    /// The kit tells a table when a drag ends in a drop, but not when
    /// Escape cancels it; so a drag's lights are put out here too — on the
    /// Escape itself, and at the next press as a backstop.
    private func endDragLights() {
        guard dragCard != nil else { return }
        dragCard = nil
        dragPoint = nil
        dragTargets = []
        refreshHighlights()
        placeChrome(layoutModel)
    }

    override func mouseDown(with event: NSEvent) {
        endDragLights()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let cancelsDrag = event.keyCode == 53 && dragCard != nil
        super.keyDown(with: event)
        if cancelsDrag { endDragLights() }
    }

    // MARK: Keys

    override func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49:    // Space: whatever Return does in the bar.
            if let button = actionBar.button(for: "pass"), button.isEnabled, !actionBar.isHidden {
                button.performPress()
                return true
            }
            return false
        case 53:    // Escape: put a picked-up card back.
            if selectedCard != nil {
                clearSelection()
                return true
            }
            return false
        default:
            return false
        }
    }

    // MARK: Accessibility

    override func accessibilityLabel(forSprite id: Int) -> String? {
        guard let card = Self.card(id) else { return nil }
        if snapshot.hands.first?.contains(card) == true {
            if prompt?.playable.contains(card) == true {
                return String(format: NSLocalizedString("%@, playable", comment: "durak accessibility: a card you can play"),
                              card.accessibilityName)
            }
            return card.accessibilityName
        }
        if let pair = snapshot.table.first(where: { $0.attack == card }) {
            if let defence = pair.defence {
                return String(format: NSLocalizedString("%@, beaten by %@", comment: "durak accessibility"),
                              card.accessibilityName, defence.accessibilityName)
            }
            return String(format: NSLocalizedString("%@, to beat", comment: "durak accessibility: an unbeaten attack"),
                          card.accessibilityName)
        }
        if snapshot.table.contains(where: { $0.defence == card }) { return nil }
        if snapshot.trumpUnderDeck == card {
            return String(format: NSLocalizedString("Trump: %@", comment: "durak accessibility: the turned trump card"),
                          card.accessibilityName)
        }
        if snapshot.deckCards.last == card {
            return Plural.format(snapshot.stock.count,
                                 one: NSLocalizedString("Deck, %d card", comment: "durak accessibility"),
                                 other: NSLocalizedString("Deck, %d cards", comment: "durak accessibility"))
        }
        if snapshot.discard.last == card {
            return NSLocalizedString("Bito pile", comment: "durak accessibility: the discard pile («Бито»)")
        }
        return nil
    }

    // MARK: Words on the table

    /// A toast just above the player's hand — where the eye already is, and
    /// clear of the opponents across the top.
    func toast(_ text: String, symbol: String? = nil, tint: NSColor = Palette.textSecondary) {
        let layout = layoutModel
        // Clear of a card picked up out of the hand, which rises higher still.
        let offset = max(bottomReserve, bounds.height - (layout.handTop - selectionLift * cardSize.height - 8))
        Toast.show(text, symbolName: symbol, symbolTint: tint, in: self, placement: .bottom(offset: offset))
    }

    /// A word said by `seat` — "Pass", "Done" — pinned beside their hand for
    /// a moment.
    private func say(_ text: String, seat: Int) {
        let spot = layoutModel.speechPoint(seat)
        speech[seat]?.hide(animated: false)
        let badge = TableBadge.show(text, in: self, at: spot.point, anchor: spot.anchor,
                                    animated: Motion.isEnabled && window != nil)
        speech[seat] = badge
        scheduler.after(1.3) { [weak self, weak badge] in
            guard let self, let badge, self.speech[seat] === badge else { return }
            badge.hide(animated: Motion.isEnabled && self.window != nil)
            self.speech[seat] = nil
        }
    }

    private func hideSpeech() {
        for badge in speech.values { badge.hide(animated: false) }
        speech.removeAll()
    }

    private func name(_ seat: Int) -> String {
        names.indices.contains(seat) ? names[seat] : ""
    }

    // MARK: Presenting events

    /// Whether events are still being shown.
    var isPresenting: Bool { queueCompletion != nil }

    /// Shows `events` one after another, then calls `completion`. `final` is
    /// the engine's position after all of them.
    func present(_ events: [DurakEvent], final: DurakState, completion: @escaping () -> Void) {
        queue.append(contentsOf: events)
        finalState = final
        queueCompletion = completion
        selectedCard = nil
        if stepToken == nil { runNextStep() }
    }

    /// Drops whatever was still to be shown (a new game).
    func cancelPresentation() {
        queue.removeAll()
        queueCompletion = nil
        finalState = nil
        if let stepToken { scheduler.cancel(stepToken) }
        stepToken = nil
        if let dealToken { scheduler.cancel(dealToken) }
        dealToken = nil
        reveal = nil
        dragTargets = []
    }

    private func runNextStep() {
        stepToken = nil
        guard !queue.isEmpty else {
            finishPresentation()
            return
        }
        let event = queue.removeFirst()
        let wait = show(event)
        stepToken = scheduler.after(wait) { [weak self] in self?.runNextStep() }
    }

    private func finishPresentation() {
        if let finalState, !snapshot.matches(finalState) {
            // Never expected; but a table that disagrees with the engine is
            // put right rather than played on.
            snapshot = DurakTableSnapshot(state: finalState)
            reveal = nil
            sync(duration: Motion.cardMove)
            updateSeats()
        }
        finalState = nil
        let done = queueCompletion
        queueCompletion = nil
        done?()
    }

    /// Shows one event; returns how long to let it breathe before the next.
    private func show(_ event: DurakEvent) -> TimeInterval {
        let motion = Motion.isEnabled && window != nil
        func pace(_ t: TimeInterval) -> TimeInterval { motion ? t : 0 }

        switch event {
        case .dealt(let hands, let trump):
            return deal(hands, trump: trump, motion: motion)

        case .opening(let attacker, _, let shown):
            snapshot.apply(event)
            updateSeats()
            guard let shown else { return pace(0.2) }
            let text = attacker == DurakMatch.human
                ? String(format: NSLocalizedString("You have the %@ and start", comment: "durak opening: your lowest trump"),
                         shown.description)
                : String(format: NSLocalizedString("%@ has the %@ and starts", comment: "durak opening: name, lowest trump"),
                         name(attacker), shown.description)
            reveal = (attacker, shown)
            sync(duration: 0.36)
            toast(text, symbol: shown.suit.durakSymbolName, tint: Palette.accent)
            // The reveal is information, not decoration: it holds long
            // enough to read even with motion off.
            return 2.1

        case .boutStarted(let attacker, _):
            snapshot.apply(event)
            let wasRevealing = reveal != nil
            reveal = nil
            sync(duration: 0.36)
            updateSeats()
            if attacker == DurakMatch.human, !wasRevealing {
                toast(NSLocalizedString("Your attack", comment: "durak toast"), symbol: "arrowtriangle.right.fill")
            }
            return pace(wasRevealing ? 0.4 : 0.2)

        case .attacked(let seat, _), .threwIn(let seat, _):
            snapshot.apply(event)
            sync(duration: Motion.cardMove)
            updateSeats()
            Sound.play(.place)
            if case .attacked = event, snapshot.defender == DurakMatch.human, seat != DurakMatch.human {
                toast(NSLocalizedString("Defend", comment: "durak toast: it is your turn to beat the cards"),
                      symbol: "shield.lefthalf.filled")
            }
            return pace(0.42)

        case .beat:
            snapshot.apply(event)
            sync(duration: Motion.cardMove)
            updateSeats()
            Sound.play(.place)
            return pace(0.40)

        case .transferred(let seat, _, let to):
            snapshot.apply(event)
            sync(duration: Motion.cardMove)
            updateSeats()
            Sound.play(.place)
            let text: String
            if to == DurakMatch.human {
                text = String(format: NSLocalizedString("%@ transfers to you", comment: "durak toast («переводит»)"), name(seat))
            } else if seat == DurakMatch.human {
                text = String(format: NSLocalizedString("Transferred to %@", comment: "durak toast"), name(to))
            } else {
                text = String(format: NSLocalizedString("%@ transfers to %@", comment: "durak toast"), name(seat), name(to))
            }
            toast(text, symbol: "arrow.turn.up.right")
            return pace(0.55)

        case .takes(let seat):
            snapshot.apply(event)
            updateSeats()
            if seat != DurakMatch.human {
                toast(String(format: NSLocalizedString("%@ takes", comment: "durak toast: the defender picks up («Беру»)"),
                             name(seat)), symbol: "tray.and.arrow.down.fill")
            }
            return pace(0.45)

        case .passed(let seat):
            let word = snapshot.passWord(for: seat)
            snapshot.apply(event)
            if seat != DurakMatch.human {
                say(word == .done ? NSLocalizedString("Done", comment: "durak: nothing more to pile on")
                                  : NSLocalizedString("Pass", comment: "durak: nothing to throw in («Пас»)"), seat: seat)
            }
            return pace(0.3)

        case .took(_, let cards):
            snapshot.apply(event)
            let order = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1, $0) })
            sync(duration: 0.44) { card in Double(order[card] ?? 0) * 0.035 }
            updateSeats()
            Sound.play(.slide)
            return pace(0.5 + Double(cards.count) * 0.035)

        case .bito(let cards):
            snapshot.apply(event)
            let order = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1, $0) })
            sync(duration: 0.46) { card in Double(order[card] ?? 0) * 0.035 }
            updateSeats()
            Sound.play(.slide)
            toast(NSLocalizedString("Bito", comment: "durak toast: every attack beaten, cards discarded («Бито»)"),
                  symbol: "checkmark")
            return pace(0.55 + Double(cards.count) * 0.035)

        case .drew(_, let cards):
            snapshot.apply(event)
            let order = Dictionary(uniqueKeysWithValues: cards.enumerated().map { ($1, $0) })
            sync(duration: Motion.cardMove) { card in Double(order[card] ?? 0) * Motion.dealStagger }
            updateSeats()
            if motion { Sound.play(.deal) }
            return pace(0.22 + Double(cards.count) * Motion.dealStagger)

        case .playerOut(let seat, _):
            snapshot.apply(event)
            updateSeats()
            if snapshot.result == nil && !queue.contains(where: { if case .gameOver = $0 { return true } else { return false } }) {
                toast(seat == DurakMatch.human
                      ? NSLocalizedString("You're out — no cards left", comment: "durak toast")
                      : String(format: NSLocalizedString("%@ is out", comment: "durak toast"), name(seat)),
                      symbol: "checkmark.circle")
            }
            return pace(0.45)

        case .gameOver:
            snapshot.apply(event)
            // The durak's cards turn up and open out, one after another.
            sync(duration: 0.5) { card in
                Double(self.snapshot.hands.firstIndex { $0.contains(card) }.flatMap { seat in
                    self.snapshot.hands[seat].firstIndex(of: card) } ?? 0) * 0.05
            }
            updateSeats()
            return 0
        }
    }

    /// The deal: every card gathered into the deck face down, then dealt one
    /// at a time round the table from the top, and the trump turned up and
    /// slid under the deck.
    private func deal(_ hands: [[Card]], trump: Card, motion: Bool) -> TimeInterval {
        let stockAfter = finalState?.stock ?? []
        snapshot = DurakTableSnapshot(beforeDealing: hands, trump: trump,
                                      stockAfter: stockAfter.isEmpty ? [trump] : stockAfter)
        reveal = nil
        // Cards left on the table from the last game are gathered first —
        // and the deal waits for them to land, since a card sent off again
        // mid-flight would skip the gathering altogether.
        let gathering = motion && targets(layoutModel).contains { id, target in
            guard let sprite = existingSprite(id), !sprite.isHidden else { return false }
            return pose(of: id) != target.pose
        }
        sync(duration: gathering ? 0.38 : 0)
        updateSeats()
        Sound.play(.shuffle)

        var order: [Card: Int] = [:]
        let longest = hands.map(\.count).max() ?? 0
        var k = 0
        for i in 0..<longest {
            for seat in hands.indices where i < hands[seat].count {
                order[hands[seat][i]] = k
                k += 1
            }
        }
        let trumpDelay = 0.1 + Double(k) * Motion.dealStagger + 0.15
        let dealNow = { [weak self] in
            guard let self else { return }
            self.dealToken = nil
            self.snapshot.apply(.dealt(hands: hands, trump: trump))
            self.sync(duration: Motion.cardMove) { card in
                if card == trump { return trumpDelay }
                return order[card].map { 0.1 + Double($0) * Motion.dealStagger } ?? 0
            }
            self.updateSeats()
        }
        let wait: TimeInterval = gathering ? 0.45 : 0
        if wait > 0 {
            dealToken = scheduler.after(wait, dealNow)
        } else {
            dealNow()
        }
        return motion ? wait + trumpDelay + 0.5 : 0
    }

    /// The deal's second half, waiting for the gathering to land.
    private var dealToken: TableScheduler.Token?

    // MARK: Testing

    /// The table's cards against the engine's position: every card a sprite,
    /// face up exactly where the player may see it.
    func spritesAgree(with state: DurakState) -> Bool {
        guard snapshot.matches(state) else { return false }
        for card in Card.durakDeck {
            let id = Self.id(card)
            guard existingSprite(id) != nil else { return false }
            let seat = state.hands.firstIndex { $0.contains(card) }
            let onTable = state.tableCards.contains(card)
            let shouldBeUp = seat == DurakMatch.human || onTable || (state.trumpCardInStock && state.stock.first == card)
                || (seat != nil && state.result == .durak(seat ?? -1))
            if isFaceUp(id) != shouldBeUp { return false }
        }
        return true
    }

    /// The pose a card rests at, for the self-tests' drops.
    func restingPose(of card: Card) -> CardPose? { pose(of: Self.id(card)) }
}
