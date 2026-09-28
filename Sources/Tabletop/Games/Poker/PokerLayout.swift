//
//  PokerLayout.swift
//  Where everything on the poker table goes, worked out as plain numbers
//  from the oval's geometry, the card size and the number of players.
//
//  Pure — geometry in, points out — so `layoutTable()` can place the whole
//  table from it on every resize, and the self-tests can check at several
//  window sizes that nothing lands on anything else.
//
//  THE SEATS. Up to six, spaced evenly by distance along the oval's rail
//  rather than by angle: on a long stadium equal angles bunch the seats at
//  the ends, equal lengths of rail spread them the way a real table's chairs
//  are. The player is always at the bottom centre, and seat numbers go
//  clockwise from there — the way the button and the action move. For each
//  count that gives a balanced table: heads-up across the middle, three
//  players in a triangle, four at the four sides, five and six round the
//  whole oval.
//
//  A seat in the lower half hangs its nameplate outward, over the rail, and
//  keeps its cards and chips in front of it on the cloth. A seat in the upper
//  half would hang its nameplate over the cloth, so it sits further back —
//  the plate lying on the rail with only its edge on the felt — and its cards
//  come just past the plate. The pot sits over the board. There is no deck
//  on the cloth: cards come from the dealer's hands in the middle and folded
//  ones go back there (a deck lying beside the board read as a sixth card).
//

import AppKit

/// One seat's places on the table.
struct PokerSeatSpot: Equatable {
    /// The avatar's centre: where `SeatView.centerAvatar(at:)` puts it.
    var avatar: CGPoint
    /// A unit vector from the seat towards the cloth.
    var inward: CGVector
    /// The seat is in the upper part of the table, its plate over the cloth.
    var platesInward: Bool
    /// The seat view's frame, for keeping things off it.
    var seatFrame: CGRect
    /// The middle of the two hole cards face down, and turned up (larger),
    /// and their turn.
    var hole: CGPoint
    var revealedHole: CGPoint
    var holeRotation: CGFloat
    /// Where the bet's chips stand.
    var bet: CGPoint
    /// The dealer button, when this seat has it.
    var dealer: CGPoint
    /// The action caption ("Raise 120") and the showdown's hand name.
    var caption: CGPoint
    var captionAnchor: TableBadge.Anchor
    var handName: CGPoint
    var handNameAnchor: TableBadge.Anchor
}

struct PokerLayout {

    let geometry: TableGeometry
    /// The table's card size: the player's own cards are drawn at it.
    let cardSize: CGSize
    let seatCount: Int
    let spots: [PokerSeatSpot]

    /// The five board slots.
    let board: [CardPose]
    let boardScale: CGFloat
    /// Opponents' cards face down, and turned up at the showdown (larger, so
    /// they can be read).
    let opponentScale: CGFloat
    let revealedScale: CGFloat
    /// Where the pot's chips stand: the middle of the row of pots.
    let pot: CGPoint
    /// Where the dealer's hands are: cards are dealt from here, and folded
    /// and finished hands go back here.
    let dealFrom: CGPoint
    let muck: CGPoint
    /// The one-line result, in the pot's place once the pot has gone.
    let result: CGPoint
    let betChipDiameter: CGFloat
    let potChipDiameter: CGFloat
    /// The player's hand-strength pill, beside their cards.
    let handPill: CGPoint

    /// The card size the table asks for: large enough that the player's own
    /// two cards read at a glance (the board and the opponents' cards are
    /// drawn smaller from the same artwork, which only ever shrinks).
    static let cardPolicy = CardSizePolicy(widthFraction: 0.068, heightFraction: 0.17,
                                           minimumWidth: 52, maximumWidth: 124)

    /// SeatView's stacked frame relative to its avatar's centre.
    static let seatBox = CGRect(x: -SeatView.stackedSize.width / 2, y: -(4 + SeatView.avatarSize / 2),
                                width: SeatView.stackedSize.width, height: SeatView.stackedSize.height)

    /// `topLimit` is the bottom of the window's strip and `bottomLimit` the
    /// top of the action bar: the seats sat back from the far side, and the
    /// player's plate hanging below the rail, stay between them.
    init(geometry g: TableGeometry, cardSize: CGSize, seatCount: Int, topLimit: CGFloat = 0,
         bottomLimit: CGFloat = .greatestFiniteMagnitude) {
        self.geometry = g
        self.cardSize = cardSize
        self.seatCount = max(2, min(6, seatCount))
        boardScale = 0.84
        opponentScale = 0.50
        revealedScale = 0.66
        betChipDiameter = max(20, (cardSize.width * 0.36).rounded())
        potChipDiameter = max(22, (cardSize.width * 0.40).rounded())

        let rail = g.railWidth
        var human = Self.stadiumPoint(fraction: 0, geometry: g, inset: rail * 0.5)
        human.point.y = min(human.point.y, bottomLimit - Self.seatBox.maxY)

        // The player's cards stand on the cloth straight above their avatar.
        let avatarTop = human.point.y - SeatView.avatarSize / 2 - 8
        let humanHole = CGPoint(x: human.point.x, y: avatarTop - cardSize.height * 0.52)
        let humanHoleBox = CGRect(x: humanHole.x - cardSize.width * 0.95, y: humanHole.y - cardSize.height * 0.56,
                                  width: cardSize.width * 1.9, height: cardSize.height * 1.08)

        // The board, as low as the player's cards allow: the space above it
        // is the pot's and the far seats'.
        let boardSize = CGSize(width: cardSize.width * boardScale, height: cardSize.height * boardScale)
        let boardBottom = min(humanHoleBox.minY - cardSize.height * 0.08, g.center.y + boardSize.height * 0.62)
        let boardCenter = CGPoint(x: g.center.x, y: boardBottom - boardSize.height / 2)
        let boardScale = self.boardScale
        board = TableLayout.row(count: 5, center: boardCenter, cardSize: boardSize, gap: 0.12, baseZ: 40)
            .map { var p = $0; p.scale = boardScale; return p }
        // The pot's chips stand just above the board, their label between.
        let boardTop = boardCenter.y - boardSize.height / 2
        let potLabel = potChipDiameter * 0.62
        pot = CGPoint(x: g.center.x.rounded(), y: (boardTop - potLabel - 6).rounded())
        dealFrom = CGPoint(x: pot.x, y: (pot.y - potChipDiameter * 0.3).rounded())
        muck = dealFrom
        // The result clears the winning cards lifted out of the board.
        result = CGPoint(x: pot.x, y: (boardTop - boardSize.height * 0.13 - 8 - 27).rounded())
        handPill = CGPoint(x: humanHoleBox.maxX + 4, y: humanHole.y - cardSize.height * 0.12)

        var spots: [PokerSeatSpot] = []
        for seat in 0..<self.seatCount {
            let fraction = CGFloat(seat) / CGFloat(self.seatCount)
            if seat == 0 {
                spots.append(Self.humanSpot(avatar: human.point, hole: humanHole, holeBox: humanHoleBox,
                                            cardSize: cardSize, betChip: betChipDiameter))
                continue
            }
            spots.append(Self.opponentSpot(fraction: fraction, geometry: g, cardSize: cardSize,
                                           opponentScale: opponentScale, revealedScale: revealedScale,
                                           betChip: betChipDiameter, topLimit: topLimit))
        }
        self.spots = spots
    }

    // MARK: Seats

    private static func humanSpot(avatar: CGPoint, hole: CGPoint, holeBox: CGRect, cardSize: CGSize,
                                  betChip: CGFloat) -> PokerSeatSpot {
        let frame = seatBox.offsetBy(dx: avatar.x, dy: avatar.y)
        // The bet goes to the left of the cards, the button to their right,
        // low; the caption beside the nameplate.
        let bet = CGPoint(x: holeBox.minX - betChip * 1.6, y: hole.y + cardSize.height * 0.10)
        let dealer = CGPoint(x: holeBox.maxX + 16, y: holeBox.maxY - 14)
        return PokerSeatSpot(avatar: avatar, inward: CGVector(dx: 0, dy: -1), platesInward: false, seatFrame: frame,
                             hole: hole, revealedHole: hole, holeRotation: 0, bet: bet.rounded, dealer: dealer.rounded,
                             caption: CGPoint(x: frame.minX, y: frame.maxY - 29), captionAnchor: .leading,
                             handName: CGPoint(x: holeBox.midX, y: holeBox.minY), handNameAnchor: .above)
    }

    private static func opponentSpot(fraction f: CGFloat, geometry g: TableGeometry, cardSize: CGSize,
                                     opponentScale: CGFloat, revealedScale: CGFloat,
                                     betChip: CGFloat, topLimit: CGFloat) -> PokerSeatSpot {
        let rail = g.railWidth
        let feltInset = rail * 1.24
        // The gold betting line printed on the cloth (see TableSurface).
        let lineInset = feltInset + g.feltRect.height * 0.13
        let felt = stadiumPoint(fraction: f, geometry: g, inset: feltInset)
        let n = felt.normal
        let platesInward = n.dy > 0.3

        // How far the seat reaches from its avatar's centre in direction d:
        // the ring round the avatar, or the plate hanging under it.
        let plate = CGRect(x: -SeatView.stackedSize.width / 2, y: SeatView.avatarSize / 2 - 8,
                           width: SeatView.stackedSize.width, height: SeatView.stackedSize.height - SeatView.avatarSize + 4)
        func reach(_ d: CGVector) -> CGFloat {
            let plateReach = max(plate.minX * d.dx, plate.maxX * d.dx) + max(plate.minY * d.dy, plate.maxY * d.dy)
            return max(SeatView.avatarSize / 2 + 4.5, plateReach)
        }
        let seatReach = reach(n)
        var avatar: CGPoint
        var avatarInset: CGFloat
        if platesInward {
            // Sat back: the plate on the rail, its edge a little onto the
            // cloth — further onto it at the corners, where there is room —
            // but never up into the window's strip.
            let overlap: CGFloat = abs(n.dx) > 0.25 ? 18 : 8
            avatarInset = feltInset - (seatReach - overlap)
            avatar = felt.point.offset(n, by: -(seatReach - overlap))
            let lowest = topLimit - seatBox.minY
            if avatar.y < lowest {
                let push = (lowest - avatar.y) / max(0.3, n.dy)
                avatar = avatar.offset(n, by: push)
                avatarInset += push
            }
        } else {
            avatarInset = rail * 0.5
            avatar = stadiumPoint(fraction: f, geometry: g, inset: avatarInset).point
        }
        let frame = seatBox.offsetBy(dx: avatar.x, dy: avatar.y)

        // The two cards just clear of the seat, between it and the betting
        // line; turned up at the showdown they grow away from the seat.
        func extent(_ scale: CGFloat) -> CGFloat {
            abs(n.dx) * cardSize.width * scale * 0.80 + abs(n.dy) * cardSize.height * scale * 0.55
        }
        let near = seatReach + 5
        let hole = avatar.offset(n, by: near + extent(opponentScale))
        let revealedHole = avatar.offset(n, by: near + extent(revealedScale))
        // Turned a little towards the middle of the table, never so far that
        // the cards stop reading upright.
        let rotation = max(-0.22, min(0.22, atan2(n.dx, -n.dy) * 0.25))

        // The bet just inside the betting line, clear of the cards. (Bets and
        // turned-up hands are never on the table together: the bets are
        // gathered before anything is shown.)
        let chipR = betChip / 2
        let betDistance = max(near + 2 * extent(opponentScale) + 10 + chipR, lineInset - avatarInset + chipR + 4)
        let bet = avatar.offset(n, by: betDistance)

        // The button beside the cards, on the side towards the bottom of the
        // table (along the top, to the left).
        var tangent = CGVector(dx: -n.dy, dy: n.dx)
        if tangent.dy < -0.01 || (abs(tangent.dy) <= 0.01 && tangent.dx > 0) {
            tangent = CGVector(dx: -tangent.dx, dy: -tangent.dy)
        }
        // Clear of the cards at their largest, turned up at the showdown.
        let dealerOffset = abs(tangent.dx) * cardSize.width * revealedScale * 1.02
            + abs(tangent.dy) * cardSize.height * revealedScale * 0.62 + betChip * 0.5
        let dealer = CGPoint(x: (hole.x + revealedHole.x) / 2, y: (hole.y + revealedHole.y) / 2)
            .offset(tangent, by: dealerOffset)

        // Captions beside the plate, on the side towards the middle of the
        // table.
        let caption: CGPoint
        let captionAnchor: TableBadge.Anchor
        if avatar.x <= g.center.x + 1 {
            caption = CGPoint(x: frame.maxX, y: frame.maxY - 29)
            captionAnchor = .trailing
        } else {
            caption = CGPoint(x: frame.minX, y: frame.maxY - 29)
            captionAnchor = .leading
        }
        // The hand's name at the showdown, on the far side of the cards from
        // the seat.
        let revealedHalfHeight = cardSize.height * revealedScale * 0.56
        let handName: CGPoint
        let handNameAnchor: TableBadge.Anchor
        if n.dy < -0.3 {
            handName = CGPoint(x: revealedHole.x, y: revealedHole.y - revealedHalfHeight)
            handNameAnchor = .above
        } else {
            handName = CGPoint(x: revealedHole.x, y: revealedHole.y + revealedHalfHeight)
            handNameAnchor = .below
        }
        return PokerSeatSpot(avatar: avatar.rounded, inward: n, platesInward: platesInward, seatFrame: frame,
                             hole: hole.rounded, revealedHole: revealedHole.rounded, holeRotation: rotation,
                             bet: bet.rounded, dealer: dealer.rounded,
                             caption: caption.rounded, captionAnchor: captionAnchor,
                             handName: handName.rounded, handNameAnchor: handNameAnchor)
    }

    // MARK: Cards

    /// The two hole cards of `seat`: the player's large and open, everyone
    /// else's small and tucked together — or open and larger once turned up.
    func holePoses(seat: Int, revealed: Bool) -> [CardPose] {
        guard let spot = spots[safe: seat] else { return [] }
        if seat == 0 {
            return TableLayout.fan(count: 2, anchor: spot.hole, cardSize: cardSize, side: .bottom,
                                   style: FanStyle(spacing: 0.58, maximumSpread: 0.30, radius: 3.2), baseZ: 300)
        }
        let scale = revealed ? revealedScale : opponentScale
        let anchor = revealed ? spot.revealedHole : spot.hole
        let style = revealed ? FanStyle(spacing: 0.62, maximumSpread: 0.26, radius: 3.4)
                             : FanStyle(spacing: 0.30, maximumSpread: 0.22, radius: 3.0)
        let fan = TableLayout.fan(count: 2, anchor: anchor, cardSize: cardSize, side: .bottom, style: style,
                                  scale: scale, baseZ: 100 + seat * 4)
        // The fan is built upright about its anchor; turn it as a whole.
        let c = cos(spot.holeRotation), s = sin(spot.holeRotation)
        return fan.map { pose in
            var p = pose
            let dx = pose.position.x - anchor.x, dy = pose.position.y - anchor.y
            p.position = CGPoint(x: anchor.x + dx * c - dy * s, y: anchor.y + dx * s + dy * c)
            p.rotation += spot.holeRotation
            return p
        }
    }

    /// A card in the dealer's hands, about to be dealt.
    var dealPose: CardPose {
        CardPose(position: dealFrom, rotation: 0, z: 30, scale: opponentScale * 0.9)
    }

    /// Where the pots stand, main pot first, in one row centred over the
    /// board.
    func potPositions(count: Int, widths: [CGFloat]) -> [CGPoint] {
        guard count > 0 else { return [] }
        let gap = potChipDiameter * 0.9
        let total = widths.prefix(count).reduce(0, +) + gap * CGFloat(count - 1)
        var x = pot.x - total / 2
        var points: [CGPoint] = []
        for i in 0..<count {
            let w = widths[safe: i] ?? potChipDiameter
            points.append(CGPoint(x: (x + w / 2).rounded(), y: pot.y))
            x += w + gap
        }
        return points
    }

    // MARK: The rail

    /// A point on the stadium `inset` points inside the table's outer edge,
    /// `fraction` of the way round it from the bottom centre, clockwise on
    /// screen (left along the bottom, up the left end, right along the top…),
    /// and the unit normal there pointing into the table.
    static func stadiumPoint(fraction: CGFloat, geometry g: TableGeometry,
                             inset: CGFloat) -> (point: CGPoint, normal: CGVector) {
        let rect = g.tableRect
        let r = max(1, rect.height / 2 - inset)
        let s = g.straight
        let cx = rect.midX, cy = rect.midY
        let perimeter = 4 * s + 2 * .pi * r
        var u = (fraction - floor(fraction)) * perimeter
        // Bottom, from the middle leftwards.
        if u <= s { return (CGPoint(x: cx - u, y: cy + r), CGVector(dx: 0, dy: -1)) }
        u -= s
        // The left end, from the bottom round to the top.
        if u <= .pi * r {
            let a = .pi / 2 + u / r
            return (CGPoint(x: cx - s + r * cos(a), y: cy + r * sin(a)), CGVector(dx: -cos(a), dy: -sin(a)))
        }
        u -= .pi * r
        // Along the top, left to right.
        if u <= 2 * s { return (CGPoint(x: cx - s + u, y: cy - r), CGVector(dx: 0, dy: 1)) }
        u -= 2 * s
        // The right end, from the top round to the bottom.
        if u <= .pi * r {
            let a = -.pi / 2 + u / r
            return (CGPoint(x: cx + s + r * cos(a), y: cy + r * sin(a)), CGVector(dx: -cos(a), dy: -sin(a)))
        }
        u -= .pi * r
        // Bottom again, from the right back to the middle.
        return (CGPoint(x: cx + s - u, y: cy + r), CGVector(dx: 0, dy: -1))
    }
}

extension CGPoint {
    /// On whole points, so layers and labels land on pixels.
    fileprivate var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }

    fileprivate func offset(_ d: CGVector, by distance: CGFloat) -> CGPoint {
        CGPoint(x: x + d.dx * distance, y: y + d.dy * distance)
    }
}
