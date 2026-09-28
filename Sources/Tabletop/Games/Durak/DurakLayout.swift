//
//  DurakLayout.swift
//  Where everything goes on the durak table, as plain numbers: the hands,
//  the seats, the deck and its trump, the fight in the middle, the bito pile.
//
//  Pure — a size and a player count in, points and poses out — so the view
//  can lay out any moment of the game from its model, and the self-tests can
//  check at every window size that nothing overlaps or leaves the cloth.
//
//  THE TABLE, CLOCKWISE FROM THE PLAYER (the engine's seat order)
//
//      2 players    you at the bottom, the opponent across the top
//      3 players    you, then the two opponents across the top, left and
//                   right — the sides stay free for the deck and the pile
//      4 players    you, left, top, right
//
//  The deck lies at the left edge with the trump across under it, and the
//  bito pile grows opposite it at the right edge; with four, where the side
//  players sit at those edges, the two move up into the top corners. The
//  fight is centred between the top hands and yours: up to six pairs in a
//  row, or two rows of three when the window is too narrow for six.
//
//  SIZES. The table's card size is the player's hand — near, large, easy to
//  read. Everything else is drawn smaller from the same artwork: the deck,
//  the fight and the pile at `tableScale`, the opponents' hands, across the
//  table, at `botScale`.
//

import AppKit

/// Where a seat sits on the screen.
enum DurakPlace: Equatable {
    case bottom, left, top, right, topLeft, topRight

    /// Seat order (clockwise) to places, for 2...4 players.
    static func places(for playerCount: Int) -> [DurakPlace] {
        switch playerCount {
        case ...2: return [.bottom, .top]
        case 3: return [.bottom, .topLeft, .topRight]
        default: return [.bottom, .left, .top, .right]
        }
    }

    var handSide: HandSide {
        switch self {
        case .bottom: return .bottom
        case .left: return .left
        case .right: return .right
        case .top, .topLeft, .topRight: return .top
        }
    }
}

struct DurakLayout {

    /// The cloth, inside the wooden frame.
    let felt: CGRect
    /// The cloth above the action bar's reserve.
    let play: CGRect
    let cardSize: CGSize
    let playerCount: Int
    let places: [DurakPlace]

    /// Opponents' hands are drawn at this fraction of the table's card size.
    static let botScale: CGFloat = 0.56
    /// The durak's hand, turned up at the end.
    static let shownScale: CGFloat = 0.66
    /// The deck, the fight and the bito pile.
    static let tableScale: CGFloat = 0.86
    /// The seat's plate: the kit's inline `SeatView`, a little wider so
    /// "12 cards · Defending" fits on its line.
    static let seatSize = CGSize(width: 206, height: 58)

    /// The card size the policy should produce: the player's hand.
    static let sizePolicy = CardSizePolicy(widthFraction: 0.084, heightFraction: 0.182, minimumWidth: 52, maximumWidth: 140)
    /// How far a playable card in the player's hand rises, in card heights.
    static let playableLift: CGFloat = 0.09

    private let edge: CGFloat = 14

    init(felt: CGRect, play: CGRect, cardSize: CGSize, playerCount: Int) {
        self.felt = felt
        self.play = play
        self.cardSize = cardSize
        self.playerCount = min(max(playerCount, 2), 4)
        self.places = DurakPlace.places(for: self.playerCount)
    }

    private var w: CGFloat { cardSize.width }
    private var h: CGFloat { cardSize.height }
    /// A card on the table (deck, fight, pile).
    private var tw: CGFloat { cardSize.width * Self.tableScale }
    private var th: CGFloat { cardSize.height * Self.tableScale }
    private var tableCardSize: CGSize { CGSize(width: tw, height: th) }

    // MARK: The player's hand

    /// Wide enough for the hand, leaving the player's seat room on its left
    /// (and the same on the right, so the hand stays centred).
    var handMaxWidth: CGFloat {
        max(w * 2, felt.width - 2 * (edge + Self.seatSize.width + 22))
    }

    /// The player's fan, anchored so its lowest corner sits just above the
    /// action bar. `lifted` indices rise out of the fan (playable cards).
    func humanHand(count: Int, lifted: Set<Int> = []) -> [CardPose] {
        guard count > 0 else { return [] }
        var poses = TableLayout.fan(count: count, anchor: .zero, cardSize: cardSize, side: .bottom,
                                    style: .open, maxWidth: handMaxWidth, baseZ: 800)
        let box = TableLayout.bounds(of: poses, cardSize: cardSize)
        let dx = felt.midX - (box.minX + box.maxX) / 2
        let dy = play.maxY - 4 - box.maxY
        let lift = Self.playableLift * h
        for i in poses.indices {
            poses[i].position.x += dx
            poses[i].position.y += dy
            if lifted.contains(i) {
                poses[i].position.x += sin(poses[i].rotation) * lift
                poses[i].position.y -= cos(poses[i].rotation) * lift
            }
            poses[i].position.x = poses[i].position.x.rounded()
            poses[i].position.y = poses[i].position.y.rounded()
        }
        return poses
    }

    /// The top of the player's hand (a six-card hand, lifted), which the fight
    /// keeps clear of.
    var handTop: CGFloat {
        TableLayout.bounds(of: humanHand(count: 6), cardSize: cardSize).minY - Self.playableLift * h
    }

    // MARK: Opponents

    /// `count` face-down cards held by the seat at `place`.
    /// `shown` is the durak's hand at the end, turned up and opened out
    /// enough to read.
    func botHand(_ place: DurakPlace, count: Int, seat: Int, shown: Bool = false) -> [CardPose] {
        botHand(place, count: count, seat: seat, shown: shown, clearOfPlate: true)
    }

    private func botHand(_ place: DurakPlace, count: Int, seat: Int, shown: Bool, clearOfPlate: Bool) -> [CardPose] {
        guard count > 0 else { return [] }
        let baseZ = 600 + seat * 60
        let style = shown ? FanStyle(spacing: 0.40, maximumSpread: 0.60, radius: 3.2) : .compact
        var poses = TableLayout.fan(count: count, anchor: .zero, cardSize: cardSize, side: place.handSide,
                                    style: style, maxWidth: shown ? handMaxWidth * 0.8 : nil,
                                    scale: shown ? Self.shownScale : Self.botScale, baseZ: baseZ)
        let box = TableLayout.bounds(of: poses, cardSize: cardSize)
        let target = botHandCenter(place)
        // Pinned to the edge the hand is held from, so it grows towards the
        // middle rather than off the table.
        var dx = target.x - (box.minX + box.maxX) / 2
        var dy = target.y - (box.minY + box.maxY) / 2
        switch place.handSide {
        case .top: dy = felt.minY + edge - box.minY
        case .left: dx = felt.minX + edge - box.minX
        case .right: dx = felt.maxX - edge - box.maxX
        case .bottom: break
        }
        if clearOfPlate {
            // A big hand (or the durak's, opened out at the end) is wider than
            // the six-card one the seat's plate was placed beside: it moves
            // off the plate rather than over it.
            let plate = seatFrame(seat).insetBy(dx: -10, dy: -8)
            let moved = box.offsetBy(dx: dx, dy: dy)
            switch place {
            case .top, .topRight: dx -= max(0, moved.maxX - plate.minX)
            case .topLeft: dx += max(0, plate.maxX - moved.minX)
            case .left, .right: dy -= max(0, moved.maxY - plate.minY)
            case .bottom: break
            }
        }
        for i in poses.indices {
            poses[i].position.x = (poses[i].position.x + dx).rounded()
            poses[i].position.y = (poses[i].position.y + dy).rounded()
        }
        return poses
    }

    /// Where the middle of a hand at `place` goes.
    private func botHandCenter(_ place: DurakPlace) -> CGPoint {
        let side = CGFloat(Self.botScale) * h
        switch place {
        case .bottom: return CGPoint(x: felt.midX, y: play.maxY - h / 2)
        case .top: return CGPoint(x: felt.midX, y: felt.minY + edge + side / 2)
        case .topLeft: return CGPoint(x: felt.minX + felt.width * 0.30, y: felt.minY + edge + side / 2)
        case .topRight: return CGPoint(x: felt.minX + felt.width * 0.70, y: felt.minY + edge + side / 2)
        case .left: return CGPoint(x: felt.minX + edge + side / 2, y: sideHandY)
        case .right: return CGPoint(x: felt.maxX - edge - side / 2, y: sideHandY)
        }
    }

    /// The side players' hands sit a little above the fight's middle, so
    /// their seats fit underneath.
    private var sideHandY: CGFloat { battleCenter.y - h * 0.30 }

    /// A six-card hand at `place`, whatever the seat holds now — seats and
    /// words are placed against this, so they do not wander as hands grow.
    func referenceHandBox(_ place: DurakPlace) -> CGRect {
        TableLayout.bounds(of: botHand(place, count: 6, seat: 0, shown: false, clearOfPlate: false), cardSize: cardSize)
    }

    /// The seat's plate for `seat`.
    func seatFrame(_ seat: Int) -> CGRect {
        let size = Self.seatSize
        let place = places[seat]
        let origin: CGPoint
        switch place {
        case .bottom:
            origin = CGPoint(x: felt.minX + edge + 4, y: play.maxY - size.height - 6)
        case .top, .topRight:
            // Beside the hand, on the side away from the middle (the only
            // side there is room on for two players across the top).
            let box = referenceHandBox(place)
            origin = CGPoint(x: box.maxX + 14, y: box.midY - size.height / 2)
        case .topLeft:
            let box = referenceHandBox(place)
            origin = CGPoint(x: box.minX - 14 - size.width, y: box.midY - size.height / 2)
        case .left:
            let box = referenceHandBox(place)
            origin = CGPoint(x: felt.minX + edge, y: box.maxY + 12)
        case .right:
            let box = referenceHandBox(place)
            origin = CGPoint(x: felt.maxX - edge - size.width, y: box.maxY + 12)
        }
        return CGRect(origin: origin, size: size).integral
    }

    /// Where a word from `seat` ("Pass", "Take") is pinned: between the hand
    /// and the middle of the table.
    func speechPoint(_ seat: Int) -> (point: CGPoint, anchor: TableBadge.Anchor) {
        let place = places[seat]
        switch place {
        case .bottom:
            let box = TableLayout.bounds(of: humanHand(count: 6), cardSize: cardSize)
            return (CGPoint(x: box.midX, y: box.minY - 10), .above)
        case .top, .topLeft, .topRight:
            let box = referenceHandBox(place)
            return (CGPoint(x: box.midX, y: box.maxY + 4), .below)
        case .left:
            let box = referenceHandBox(place)
            return (CGPoint(x: box.maxX + 4, y: box.midY), .trailing)
        case .right:
            let box = referenceHandBox(place)
            return (CGPoint(x: box.minX - 4, y: box.midY), .leading)
        }
    }

    /// Where the lowest trump is held up for everyone to see at the opening:
    /// out of the seat's hand, a third of the way to the middle.
    func revealPose(_ seat: Int) -> CardPose {
        let place = places[seat]
        let from: CGPoint
        switch place {
        case .bottom:
            let box = TableLayout.bounds(of: humanHand(count: 6), cardSize: cardSize)
            from = CGPoint(x: box.midX, y: box.midY)
        default:
            let box = referenceHandBox(place)
            from = CGPoint(x: box.midX, y: box.midY)
        }
        let to = battleCenter
        let p = CGPoint(x: from.x + (to.x - from.x) * 0.42, y: from.y + (to.y - from.y) * 0.42)
        return CardPose(position: CGPoint(x: p.x.rounded(), y: p.y.rounded()), rotation: 0, z: 950)
    }

    // MARK: Deck and pile

    /// The deck's middle. The trump sticks out to its right.
    var deckCenter: CGPoint {
        let x = felt.minX + edge + 12 + tw / 2
        if playerCount >= 4 {
            return CGPoint(x: x.rounded(), y: (felt.minY + edge + 8 + th / 2).rounded())
        }
        return CGPoint(x: x.rounded(), y: (battleCenter.y - th * 0.06).rounded())
    }

    var trumpPose: CardPose {
        var pose = TableLayout.trump(underDeckAt: deckCenter, cardSize: tableCardSize, towardsRight: true, z: 99)
        pose.scale = Self.tableScale
        pose.position = CGPoint(x: pose.position.x.rounded(), y: pose.position.y.rounded())
        return pose
    }

    /// Under the deck, for the count of cards left.
    var deckCountPoint: CGPoint {
        CGPoint(x: deckCenter.x, y: (deckCenter.y + th / 2 + 12).rounded())
    }

    /// Cards on the deck, bottom first; the turned trump is `trumpPose`.
    func deck(count: Int) -> [CardPose] {
        TableLayout.deck(count: count, center: deckCenter, cardSize: cardSize, visibleThickness: 7,
                         scale: Self.tableScale, baseZ: 100)
    }

    var discardCenter: CGPoint {
        let x = felt.maxX - edge - 18 - tw * 0.55
        if playerCount >= 4 {
            return CGPoint(x: x.rounded(), y: (felt.minY + edge + 10 + th * 0.55).rounded())
        }
        return CGPoint(x: x.rounded(), y: (battleCenter.y - th * 0.06).rounded())
    }

    /// The bito pile: thrown down messily, deterministically. Only the top
    /// dozen or so are drawn; the rest could not show anyway.
    func discard(count: Int, seed: UInt64) -> [CardPose] {
        var poses = TableLayout.discardPile(count: count, center: discardCenter, cardSize: tableCardSize, seed: seed,
                                            maxAngle: 0.42, baseZ: 200)
        for i in poses.indices {
            poses[i].scale = Self.tableScale
            if i < count - 14 { poses[i].isHidden = true }
        }
        return poses
    }

    // MARK: The fight

    /// The top of the space the fight has: below the hands across the top.
    private var fightTop: CGFloat {
        var top = felt.minY + edge
        for place in places where place.handSide == .top {
            top = max(top, referenceHandBox(place).maxY + 10)
        }
        return top
    }

    var battleCenter: CGPoint {
        CGPoint(x: felt.midX.rounded(), y: ((fightTop + handTop) / 2).rounded())
    }

    /// Centre to centre of two neighbouring pairs.
    var pitchX: CGFloat { (tw * 1.52).rounded() }
    var pitchY: CGFloat { (th * 1.18).rounded() }

    /// How much of the cloth's width each side keeps for itself at the
    /// fight's height: the deck and the trump on the left, or the side
    /// players and their seats.
    private var sideReserve: CGFloat {
        if playerCount >= 4 { return edge + Self.seatSize.width + 16 }
        return edge + 12 + tw / 2 + th * 0.30 + th / 2 + 16
    }

    /// Six pairs in a row, or two rows of three when six do not fit.
    var perRow: Int {
        let rowOfSix = 5 * pitchX + tw * 1.45
        return rowOfSix + 2 * sideReserve <= felt.width ? 6 : 3
    }

    /// The middle of pair `i` of `count` on the table (and of the empty place
    /// after the last, for `i == count`). A single row stays centred as it
    /// grows; two rows keep three fixed columns, so nothing shifts under the
    /// player's pointer.
    func slotCenter(_ i: Int, of count: Int) -> CGPoint {
        let c = battleCenter
        if perRow >= 6 {
            let x = c.x + (CGFloat(i) - CGFloat(max(count, 1) - 1) / 2) * pitchX
            return CGPoint(x: x.rounded(), y: c.y)
        }
        let row = i / 3, column = i % 3
        return CGPoint(x: (c.x + CGFloat(column - 1) * pitchX).rounded(),
                       y: (c.y + (CGFloat(row) - 0.5) * pitchY).rounded())
    }

    /// The attacking card of pair `i`, and the card that beats it: lying over
    /// it a little down and to the right, turned about twelve degrees. Each
    /// card gets a hair of its own turn, so the row looks put down by hand.
    func pair(_ i: Int, of count: Int, attack: Card, defence: Card?) -> (attack: CardPose, defence: CardPose) {
        let c = slotCenter(i, of: count)
        let a = CardPose(position: CGPoint(x: (c.x - tw * 0.10).rounded(), y: (c.y - th * 0.06).rounded()),
                         rotation: -0.03 + Self.jitter(attack) * 0.045, z: 400 + i * 2, scale: Self.tableScale)
        let d = CardPose(position: CGPoint(x: (c.x + tw * 0.14).rounded(), y: (c.y + th * 0.09).rounded()),
                         rotation: 0.21 + Self.jitter(defence ?? attack) * 0.035, z: 400 + i * 2 + 1,
                         scale: Self.tableScale)
        return (a, d)
    }

    /// The transfer zone (perevodnoy): the empty place after the last
    /// attacking card, where a card of the same rank passes the attack on.
    func transferZone(count: Int) -> CGRect {
        let c = slotCenter(count, of: count)
        let x = c.x - tw * 0.10, y = c.y - th * 0.06
        return CGRect(x: x - tw / 2, y: y - th / 2, width: tw, height: th).insetBy(dx: -4, dy: -4).integral
    }

    /// Where a card dropped counts as "put on the table": everything between
    /// the hands.
    var fightRect: CGRect {
        CGRect(x: felt.minX + edge, y: fightTop - 6, width: felt.width - 2 * edge,
               height: max(40, handTop - fightTop + 6))
    }

    /// -1...1, the same for a card every time.
    static func jitter(_ card: Card) -> CGFloat {
        var rng = DeterministicRNG(seed: UInt64(card.durakIndex) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1CE)
        return CGFloat(rng.next(upperBound: 2001)) / 1000 - 1
    }
}
