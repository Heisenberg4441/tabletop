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
//  come just past the plate. The pot sits over the board, the hand's result
//  in the same place once the pot has gone. There is no deck on the cloth:
//  cards come from the dealer's hands in the middle and folded ones go back
//  there (a deck lying beside the board read as a sixth card).
//
//  FOOTPRINTS. Everything that can show at the same time as something else
//  is given its largest footprint — a bet of four stacks with its amount, the
//  tallest pot, the longest hand name — and the things that can sit in more
//  than one place (a bet, a shown hand's name, the dealer button) take the
//  first place clear of everything already put down. So a bet by the seat
//  across the table goes beside its cards rather than onto the pot, the two
//  seats at one end of the oval push their chips towards the board rather
//  than into each other, and nothing depends on the amount on the table
//  being small. The self-tests then check the real layers of real hands.
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
    /// The middle of the two hole cards face down, and turned up, and their
    /// turn.
    var hole: CGPoint
    var revealedHole: CGPoint
    /// How large the cards are turned up: larger than face down, so they can
    /// be read, as far as the room between the seat and the pot allows.
    var revealedScale: CGFloat
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
    /// Opponents' cards face down, and at most this large turned up at the
    /// showdown (each seat's own `revealedScale` may be less).
    let opponentScale: CGFloat
    let revealedScale: CGFloat
    /// Where the pot's chips stand: the middle of the row of pots.
    let pot: CGPoint
    /// The band over the board the pots keep to: as wide as the board, from
    /// the top of the tallest pot to the board's edge. Nothing else that can
    /// be on the table with a pot comes into it.
    let potBand: CGRect
    /// Where the dealer's hands are: cards are dealt from here, and folded
    /// and finished hands go back here.
    let dealFrom: CGPoint
    let muck: CGPoint
    /// The one-line result, in the pot's place once the pot has gone, and
    /// how wide it may be before it would reach a shown hand.
    let result: CGPoint
    let resultMaxWidth: CGFloat
    let betChipDiameter: CGFloat
    let potChipDiameter: CGFloat
    let dealerDiameter: CGFloat
    /// The player's hand-strength pill, beside their cards, and the room it
    /// has before the next seat's cards.
    let handPill: CGPoint
    let handPillMaxWidth: CGFloat

    /// The card size the table asks for: large enough that the player's own
    /// two cards read at a glance (the board and the opponents' cards are
    /// drawn smaller from the same artwork, which only ever shrinks).
    static let cardPolicy = CardSizePolicy(widthFraction: 0.068, heightFraction: 0.17,
                                           minimumWidth: 52, maximumWidth: 124)

    /// SeatView's stacked frame relative to its avatar's centre.
    static let seatBox = CGRect(x: -SeatView.stackedSize.width / 2, y: -(4 + SeatView.avatarSize / 2),
                                width: SeatView.stackedSize.width, height: SeatView.stackedSize.height)

    /// How far a winning card rises out of its place, in its own heights:
    /// towards the middle of the table (see `PokerTableView.lifted`) — the
    /// player's own less, since theirs are the largest and nearest the board.
    static let winningLift: CGFloat = 0.13
    static let humanWinningLift: CGFloat = 0.07

    /// The result's glass capsule is one line of this height.
    static let resultHeight: CGFloat = 34
    /// The pots stand no taller than this many chips a stack (more of a
    /// denomination starts another stack), so the pot's band has a known top.
    static let potChipsPerStack = 6
    /// A bet's stacks, at most: four side by side (see `ChipStackLayer`).
    static let betStacks = 4

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
        let betChip = max(20, (cardSize.width * 0.36).rounded())
        betChipDiameter = betChip
        potChipDiameter = max(22, (cardSize.width * 0.40).rounded())
        dealerDiameter = max(18, (betChip * 0.86).rounded())

        let rail = g.railWidth
        var human = Self.stadiumPoint(fraction: 0, geometry: g, inset: rail * 0.5)
        human.point.y = min(human.point.y, bottomLimit - Self.seatBox.maxY)

        // The player's cards stand on the cloth straight above their avatar.
        let avatarTop = human.point.y - SeatView.avatarSize / 2 - 8
        let humanHole = CGPoint(x: human.point.x, y: avatarTop - cardSize.height * 0.52)
        let humanHoleBox = TableLayout.bounds(of: Self.humanPoses(anchor: humanHole, cardSize: cardSize),
                                              cardSize: cardSize)

        // The board, as low as the player's cards allow: the space above it
        // is the pot's and the far seats'.
        let boardSize = CGSize(width: cardSize.width * boardScale, height: cardSize.height * boardScale)
        let boardBottom = min(humanHoleBox.minY - cardSize.height * 0.08, g.center.y + boardSize.height * 0.62)
        let boardCenter = CGPoint(x: g.center.x, y: boardBottom - boardSize.height / 2)
        let boardScale = self.boardScale
        board = TableLayout.row(count: 5, center: boardCenter, cardSize: boardSize, gap: 0.12, baseZ: 40)
            .map { var p = $0; p.scale = boardScale; return p }
        let boardRect = TableLayout.bounds(of: board, cardSize: cardSize)
        // The winning cards rise out of their places at the showdown.
        let lifted = CGRect(x: boardRect.minX, y: boardRect.minY - boardSize.height * 0.14,
                            width: boardRect.width, height: boardRect.height + boardSize.height * 0.14)
        // The pot's chips stand just above the board, their label between.
        let potChip = potChipDiameter
        let potLabel = potChip * 0.62
        pot = CGPoint(x: g.center.x.rounded(), y: (boardRect.minY - potLabel - 6).rounded())
        let potTop = pot.y - ChipRenderer.stackHeight(count: Self.potChipsPerStack, radius: potChip / 2) - potChip * 0.12
        potBand = CGRect(x: boardRect.minX, y: potTop, width: boardRect.width, height: boardRect.minY - potTop)
        dealFrom = CGPoint(x: pot.x, y: (pot.y - potChip * 0.3).rounded())
        muck = dealFrom
        // The result just clear of the winning cards lifted out of the board.
        result = CGPoint(x: pot.x, y: (lifted.minY - 4 - Self.resultHeight / 2).rounded())
        let resultBand = CGRect(x: g.feltRect.minX, y: result.y - Self.resultHeight / 2,
                                width: g.feltRect.width, height: Self.resultHeight)
        handPill = CGPoint(x: humanHoleBox.maxX + 4, y: (humanHole.y - cardSize.height * 0.12).rounded())

        // 1. The seats and their cards.
        var drafts: [Draft] = []
        for seat in 0..<self.seatCount {
            if seat == 0 {
                drafts.append(Self.humanDraft(avatar: human.point, hole: humanHole, holeBox: humanHoleBox))
                continue
            }
            let fraction = CGFloat(seat) / CGFloat(self.seatCount)
            // Turned-up cards stop short of the middle column — the pot, and
            // the result after it — where a runout or a showdown would have
            // them lying on the chips or under the words.
            let middle = CGRect(x: pot.x - 200, y: potBand.minY - 4, width: 400, height: lifted.minY - potBand.minY + 4)
            drafts.append(Self.opponentDraft(seat: seat, fraction: fraction, geometry: g, cardSize: cardSize,
                                             opponentScale: opponentScale, revealedScale: revealedScale,
                                             keepClearOf: middle, topLimit: topLimit))
        }

        let seatFrames = drafts.map(\.frame)
        let hiddenBoxes = drafts.map(\.holeBox)
        let revealedBoxes = drafts.map(\.revealedBox)
        let humanPillReserve = CGRect(x: handPill.x + 6, y: handPill.y - TableBadge.height / 2,
                                      width: 90, height: TableBadge.height)

        // 1b. The action captions beside the plates, room for the longest.
        // The seat in the middle of the far side goes last: its neighbours'
        // captions come towards it from both sides, and it takes whichever
        // place they leave.
        var captionSpots = drafts.map { $0.captionCandidates[0] }
        var captions = [CGRect](repeating: .null, count: drafts.count)
        let order = drafts.indices.sorted { a, b in
            let ma = drafts[a].isMiddleOfFarSide(g), mb = drafts[b].isMiddleOfFarSide(g)
            return ma != mb ? !ma : a < b
        }
        for i in order {
            let obstacles = [lifted, potBand, humanPillReserve] + seatFrames.enumerated().filter { $0.offset != i }.map(\.element)
                + hiddenBoxes + captions
            let choice = Self.bestPlace(drafts[i].captionCandidates, obstacles: obstacles, geometry: g) {
                Self.badgeRect(at: $0.point, anchor: $0.anchor, width: Self.captionWidth)
            }
            captionSpots[i] = choice
            captions[i] = Self.badgeRect(at: choice.point, anchor: choice.anchor, width: Self.captionWidth)
        }

        // 2. The names of the hands shown at the showdown, beside or beyond
        // the turned-up cards — never on the pot (the names come up a beat
        // before it is pushed), the result's place, a plate or other cards.
        var handNames: [(point: CGPoint, anchor: TableBadge.Anchor)] = []
        var handNameRects: [CGRect] = []
        let resultReserve = CGRect(x: pot.x - 150, y: resultBand.minY, width: 300, height: resultBand.height)
        for (i, d) in drafts.enumerated() {
            if i == 0 {
                handNames.append((CGPoint(x: humanHoleBox.midX, y: humanHoleBox.minY), .above))
                handNameRects.append(.null)
                continue
            }
            var obstacles = [lifted, potBand, resultReserve, humanHoleBox, humanPillReserve]
            obstacles += seatFrames + revealedBoxes.enumerated().filter { $0.offset != i }.map(\.element)
            obstacles += handNameRects
            let choice = Self.bestPlace(d.handNameCandidates, obstacles: obstacles, geometry: g) {
                Self.badgeRect(at: $0.point, anchor: $0.anchor, width: Self.handNameWidth)
            }
            handNames.append(choice)
            handNameRects.append(Self.badgeRect(at: choice.point, anchor: choice.anchor, width: Self.handNameWidth))
        }

        // 3. How wide the result may be: out to the nearest shown hand, its
        // name, or plate on either side of the middle.
        var left = g.feltRect.minX + rail, right = g.feltRect.maxX - rail
        for r in revealedBoxes + handNameRects + seatFrames where !r.isNull && r.minY < resultBand.maxY && r.maxY > resultBand.minY {
            if r.maxX <= pot.x { left = max(left, r.maxX) } else if r.minX >= pot.x { right = min(right, r.minX) }
        }
        resultMaxWidth = max(200, 2 * min(pot.x - left, right - pot.x) - 16)

        // 4. The player's pill has the room up to the next thing on its right.
        let pillStart = handPill.x + 6
        var pillEnd = min(g.feltRect.maxX - rail, pillStart + 300)
        let pillBand = CGRect(x: pillStart, y: handPill.y - TableBadge.height / 2 - 2, width: 1, height: TableBadge.height + 4)
        for r in seatFrames.dropFirst() + hiddenBoxes.dropFirst() + revealedBoxes.dropFirst() + handNameRects.dropFirst()
            where !r.isNull && r.minY < pillBand.maxY && r.maxY > pillBand.minY && r.maxX > pillStart {
            pillEnd = min(pillEnd, r.minX - 6)
        }
        handPillMaxWidth = max(60, pillEnd - pillStart)
        // What the pill can actually cover: its room, or the longest words it
        // can say, whichever is less — so a wide table does not hold the
        // whole row beside the cards for it.
        let pill = CGRect(x: pillStart, y: pillBand.minY, width: min(handPillMaxWidth, Self.longestHandWidth),
                          height: pillBand.height)

        // 5. The bets: the player's to the left of their cards, everyone
        // else's between their cards and the board — or beside the cards,
        // when the way to the board is the pot's.
        var bets: [CGPoint] = []
        var betRects: [CGRect] = []
        let boardMiddle = CGPoint(x: boardRect.midX, y: boardRect.midY)
        for (i, d) in drafts.enumerated() {
            let obstacles = [lifted, potBand, pill] + seatFrames + hiddenBoxes + betRects + captions
            let candidates = i == 0
                ? Self.humanBetCandidates(holeBox: humanHoleBox, hole: humanHole, cardSize: cardSize, chip: betChip)
                : Self.betCandidates(d, towards: boardMiddle, center: g.center, chip: betChip)
            let point = Self.bestPlace(candidates, obstacles: obstacles, geometry: g, feltInset: rail * 1.24) {
                Self.betRect(at: $0, chip: betChip)
            }
            bets.append(point)
            betRects.append(Self.betRect(at: point, chip: betChip))
        }

        // 6. The dealer button, beside its seat's cards, clear of all of it.
        let resultRect = CGRect(x: pot.x - resultMaxWidth / 2, y: resultBand.minY, width: resultMaxWidth,
                                height: resultBand.height)
        var dealers: [CGPoint] = []
        var dealerRects: [CGRect] = []
        let dealerSize = dealerDiameter
        for d in drafts {
            var obstacles = [lifted, potBand, resultRect, pill] + seatFrames + hiddenBoxes + revealedBoxes
            obstacles += handNameRects + captions + betRects + dealerRects
            let point = Self.bestPlace(d.dealerCandidates(size: dealerSize), obstacles: obstacles, geometry: g,
                                       feltInset: rail * 1.1) {
                Self.dealerRect(at: $0, diameter: dealerSize)
            }
            dealers.append(point)
            dealerRects.append(Self.dealerRect(at: point, diameter: dealerSize))
        }

        spots = drafts.indices.map { i in
            let d = drafts[i]
            return PokerSeatSpot(avatar: d.avatar.rounded, inward: d.inward, platesInward: d.platesInward,
                                 seatFrame: d.frame, hole: d.hole.rounded, revealedHole: d.revealedHole.rounded,
                                 revealedScale: d.revealedScale, holeRotation: d.rotation,
                                 bet: bets[i].rounded, dealer: dealers[i].rounded,
                                 caption: captionSpots[i].point.rounded, captionAnchor: captionSpots[i].anchor,
                                 handName: handNames[i].point.rounded, handNameAnchor: handNames[i].anchor)
        }
    }

    // MARK: Footprints

    /// The largest a bet standing at `p` covers: four stacks of five chips,
    /// the amount under them.
    static func betRect(at p: CGPoint, chip d: CGFloat) -> CGRect {
        let up = ChipRenderer.stackHeight(count: 5, radius: d / 2) + d * 0.08
        let label = ceil(max(10, d * 0.34) * 1.25 + d * 0.14)
        let down = d * 0.26 + label + 2
        let half = (CGFloat(betStacks) * d + CGFloat(betStacks - 1) * d * 0.1) / 2 + d * 0.06
        return CGRect(x: p.x - half, y: p.y - up, width: half * 2, height: up + down)
    }

    static func dealerRect(at p: CGPoint, diameter d: CGFloat) -> CGRect {
        CGRect(x: p.x - d / 2 - 2, y: p.y - d / 2 - 2, width: d + 4, height: d + 4)
    }

    /// Where a `TableBadge` of `width` pinned at `point` lies.
    static func badgeRect(at point: CGPoint, anchor: TableBadge.Anchor, width: CGFloat) -> CGRect {
        let h = TableBadge.height, gap: CGFloat = 6
        switch anchor {
        case .above: return CGRect(x: point.x - width / 2, y: point.y - gap - h, width: width, height: h)
        case .below: return CGRect(x: point.x - width / 2, y: point.y + gap, width: width, height: h)
        case .leading: return CGRect(x: point.x - gap - width, y: point.y - h / 2, width: width, height: h)
        case .trailing: return CGRect(x: point.x + gap, y: point.y - h / 2, width: width, height: h)
        case .center: return CGRect(x: point.x - width / 2, y: point.y - h / 2, width: width, height: h)
        }
    }

    /// The width of a `TableBadge` saying `text` (its own measure: the
    /// words' fitting width, and 22 points of capsule round them).
    static func badgeWidth(_ text: String) -> CGFloat {
        let words = ceil((text as NSString).size(withAttributes: [.font: badgeFont]).width + 4) + 6
        return max(TableBadge.height, words + 22)
    }

    /// `TableBadge`'s type, for measuring before a badge exists.
    static let badgeFont = Typography.monospacedDigits(.systemFont(ofSize: 12.5, weight: .semibold))

    /// The longest name a shown hand can have.
    static let handNameWidth: CGFloat = {
        let names = PokerHandCategory.allCases.map(\.localizedName)
            + [NSLocalizedString("Royal Flush", comment: "poker hand category")]
        return names.map(badgeWidth).max() ?? 120
    }()

    /// The widest the player's pill can be: the longest description of any
    /// made hand ("Full House, Queens over Sevens"), measured over every kind
    /// and pair of ranks in the language the table is showing.
    static let longestHandWidth: CGFloat = {
        var widest: CGFloat = 0
        for category in PokerHandCategory.allCases {
            for a in 0..<13 {
                for b in 0..<13 where b != a {
                    let raw = UInt32(category.rawValue) << 20 | UInt32(a + 1) << 16 | UInt32(b + 1) << 12
                    widest = max(widest, badgeWidth(PokerHandValue(raw: raw).localizedDescription))
                }
            }
        }
        return widest
    }()

    /// Room for an action caption with a five-digit amount.
    static let captionWidth: CGFloat = {
        let amount = Chips.format(88_888)
        let words = [String(format: NSLocalizedString("Raise %@", comment: "poker caption: raised to, e.g. Raise 120"), amount),
                     String(format: NSLocalizedString("Call %@", comment: "poker caption: called, e.g. Call 60"), amount),
                     NSLocalizedString("All-in", comment: "poker action caption")]
        return words.map(badgeWidth).max() ?? 110
    }()

    /// The first of `candidates` whose footprint lies on the cloth (when
    /// `feltInset` is given) and clear of every obstacle — or, when none is,
    /// the one that covers least of them (a tiny window can be too small for
    /// everything at its largest; the first choice is a last resort only).
    private static func bestPlace<C>(_ candidates: [C], obstacles: [CGRect], geometry g: TableGeometry,
                                     feltInset: CGFloat? = nil, footprint: (C) -> CGRect) -> C {
        let solid = obstacles.filter { !$0.isNull && !$0.isEmpty }
        var best = candidates[0]
        var bestCost = CGFloat.greatestFiniteMagnitude
        for c in candidates {
            let r = footprint(c)
            var cost: CGFloat = 0
            if let inset = feltInset {
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                               CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                cost += CGFloat(corners.filter { !g.contains($0, inset: inset) }.count) * 10_000
            }
            for o in solid where o.intersects(r) {
                let x = o.intersection(r)
                cost += max(1, x.width * x.height)
            }
            if cost == 0 { return c }
            if cost < bestCost { best = c; bestCost = cost }
        }
        return best
    }

    // MARK: Seats

    /// A seat worked out as far as it can be on its own: plate, cards,
    /// caption, and the places its other things may go.
    private struct Draft {
        var avatar: CGPoint
        var inward: CGVector
        var platesInward: Bool
        var frame: CGRect
        var hole: CGPoint
        var holeBox: CGRect
        var revealedHole: CGPoint
        var revealedScale: CGFloat
        var revealedBox: CGRect
        var rotation: CGFloat
        /// Beside the plate towards the middle of the table first.
        var captionCandidates: [(point: CGPoint, anchor: TableBadge.Anchor)]
        var handNameCandidates: [(point: CGPoint, anchor: TableBadge.Anchor)]
        /// Along the rail's normal, inside the betting line: where a bet went
        /// before anything else was known.
        var fallbackBet: CGPoint
        /// Which way is "along the rail", towards the bottom of the table.
        var tangent: CGVector
        var atEnd: Bool
        var isHuman: Bool

        /// The seat across the table from the player, in the middle of the
        /// far side: its left and right are both "towards the middle".
        func isMiddleOfFarSide(_ g: TableGeometry) -> Bool {
            !isHuman && platesInward && abs(avatar.x - g.center.x) < 20
        }

        /// The button beside the cards, on the side towards the bottom of the
        /// table first, then the other side, then beyond them.
        func dealerCandidates(size d: CGFloat) -> [CGPoint] {
            let box = holeBox.union(revealedBox)
            if isHuman {
                return [CGPoint(x: box.maxX + 16, y: box.maxY - 14),
                        CGPoint(x: box.maxX + d, y: box.maxY - d * 0.5),
                        CGPoint(x: box.minX - d, y: box.maxY - d * 0.5)]
            }
            let middle = CGPoint(x: box.midX, y: box.midY)
            func out(_ v: CGVector) -> CGFloat {
                abs(v.dx) * box.width / 2 + abs(v.dy) * box.height / 2 + d * 0.5 + 5
            }
            var points: [CGPoint] = []
            for side in [tangent, CGVector(dx: -tangent.dx, dy: -tangent.dy)] {
                for reach in [1, 1.4] as [CGFloat] {
                    for along in [0, 0.35, -0.35, 0.7, -0.7] as [CGFloat] {
                        let base = middle.offset(side, by: out(side) * reach)
                        points.append(base.offset(inward, by: along * out(inward)))
                    }
                }
            }
            points.append(middle.offset(inward, by: out(inward)))
            points.append(middle.offset(inward, by: -out(inward)))
            return points
        }
    }

    private static func humanPoses(anchor: CGPoint, cardSize: CGSize) -> [CardPose] {
        TableLayout.fan(count: 2, anchor: anchor, cardSize: cardSize, side: .bottom,
                        style: FanStyle(spacing: 0.58, maximumSpread: 0.30, radius: 3.2), baseZ: 300)
    }

    private static func humanDraft(avatar: CGPoint, hole: CGPoint, holeBox: CGRect) -> Draft {
        let frame = seatBox.offsetBy(dx: avatar.x, dy: avatar.y)
        // The caption beside the nameplate.
        return Draft(avatar: avatar, inward: CGVector(dx: 0, dy: -1), platesInward: false, frame: frame,
                     hole: hole, holeBox: holeBox, revealedHole: hole, revealedScale: 1, revealedBox: holeBox,
                     rotation: 0, captionCandidates: [(CGPoint(x: frame.minX, y: frame.maxY - 29), .leading)],
                     handNameCandidates: [(CGPoint(x: holeBox.midX, y: holeBox.minY), .above)],
                     fallbackBet: CGPoint(x: holeBox.minX - 60, y: hole.y),
                     tangent: CGVector(dx: 1, dy: 0), atEnd: false, isHuman: true)
    }

    /// The player's bet stands to the left of their cards, low: the right
    /// is where the pill naming their hand and the dealer button go.
    private static func humanBetCandidates(holeBox: CGRect, hole: CGPoint, cardSize: CGSize, chip: CGFloat) -> [CGPoint] {
        let half = betRect(at: .zero, chip: chip).width / 2
        let y = hole.y + cardSize.height * 0.10
        return [0, 12, 24, 36].map { (extra: CGFloat) in CGPoint(x: holeBox.minX - 4 - half - extra, y: y) }
            + [CGPoint(x: holeBox.minX - 4 - half, y: y - chip)]
    }

    /// An opponent's bet: on the way from its cards to the board, as close
    /// to the cards as it can stand — which fans the bets of neighbouring
    /// seats out towards the middle instead of along the rail's normals,
    /// which meet at the centre of each end of the oval. Where that way is
    /// the pot's (the seats along the far side), beside the cards instead:
    /// first on the side towards the middle of the table, then the other.
    private static func betCandidates(_ d: Draft, towards target: CGPoint, center: CGPoint, chip: CGFloat) -> [CGPoint] {
        let from = CGPoint(x: d.holeBox.midX, y: d.holeBox.midY)
        let dx = target.x - from.x, dy = target.y - from.y
        let length = max(1, hypot(dx, dy))
        let heading = atan2(dy, dx)
        func along(_ turn: CGFloat) -> [CGPoint] {
            let ray = CGVector(dx: cos(heading + turn), dy: sin(heading + turn))
            return stride(from: CGFloat(0), through: length, by: 3).map { from.offset(ray, by: $0) }
        }
        var points = along(0) + along(0.2) + along(-0.2)

        let footprint = betRect(at: .zero, chip: chip)
        // Level with the cards: the footprint's middle on theirs.
        let level = d.holeBox.midY - footprint.midY
        // Sideways: towards the middle of the table first — for the seat in
        // the middle, to its own left (the right on screen), mirroring the
        // player's chips across the table.
        let towardsMiddle: CGFloat = from.x > center.x + 20 ? -1 : 1
        let lifts: [CGFloat] = [0, -0.1, 0.1, -0.2, 0.2, -0.3, 0.3, -0.45, 0.45, -0.6, 0.6]
        for sign in [towardsMiddle, -towardsMiddle] {
            let x = sign > 0 ? d.holeBox.maxX + 6 + footprint.width / 2 : d.holeBox.minX - 6 - footprint.width / 2
            for lift in lifts {
                points.append(CGPoint(x: x, y: level + lift * d.holeBox.height))
            }
        }
        points += along(0.4) + along(-0.4)
        points.append(d.fallbackBet)
        return points
    }

    private static func opponentDraft(seat: Int, fraction f: CGFloat, geometry g: TableGeometry, cardSize: CGSize,
                                      opponentScale: CGFloat, revealedScale: CGFloat, keepClearOf middle: CGRect,
                                      topLimit: CGFloat) -> Draft {
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
        // Turned a little towards the middle of the table, never so far that
        // the cards stop reading upright.
        let rotation = max(-0.22, min(0.22, atan2(n.dx, -n.dy) * 0.25))
        // The seat as drawn: the ring round the avatar and the plate under it.
        let ring = SeatView.avatarSize / 2 + 6
        let seatShapes = [CGRect(x: avatar.x - ring, y: avatar.y - ring, width: ring * 2, height: ring * 2),
                          CGRect(x: frame.minX - 2, y: avatar.y + SeatView.avatarSize / 2 - 10,
                                 width: frame.width + 4, height: frame.maxY - (avatar.y + SeatView.avatarSize / 2 - 10) + 2)]
        /// The cards at `scale`, just clear of the seat: where the reach
        /// puts them, and further along the normal if a turned corner would
        /// still touch the plate.
        func cards(scale: CGFloat, revealed: Bool) -> (anchor: CGPoint, box: CGRect) {
            var distance = near + extent(scale)
            var anchor = avatar.offset(n, by: distance)
            var box = CGRect.null
            for _ in 0..<40 {
                anchor = avatar.offset(n, by: distance)
                box = TableLayout.bounds(of: opponentPoses(anchor: anchor, scale: scale, rotation: rotation,
                                                           revealed: revealed, cardSize: cardSize, baseZ: 0),
                                         cardSize: cardSize)
                if !seatShapes.contains(where: { $0.intersects(box) }) { break }
                distance += 2
            }
            return (anchor, box)
        }
        let (hole, holeBox) = cards(scale: opponentScale, revealed: false)
        // Turned up, as large as they can be without reaching the middle —
        // lifted towards it, too, when they are among the winning five.
        var scale = revealedScale
        var shown = cards(scale: scale, revealed: true)
        while scale > opponentScale {
            let lift = cardSize.height * scale * PokerLayout.winningLift
            let reach = shown.box.union(shown.box.offsetBy(dx: n.dx * lift, dy: n.dy * lift))
            if !reach.intersects(middle) { break }
            scale = max(opponentScale, scale - 0.01)
            shown = cards(scale: scale, revealed: true)
        }
        let revealedHole = shown.anchor
        // Everything the turned-up cards can cover, lifted or not: what the
        // hand's name, the button and the result keep clear of.
        let lift = cardSize.height * scale * PokerLayout.winningLift
        let revealedBox = shown.box.union(shown.box.offsetBy(dx: n.dx * lift, dy: n.dy * lift))

        // Where the bet stood along the rail's normal, just inside the
        // betting line — the last resort.
        let chipReach = abs(n.dx) * cardSize.width * 0.63 + abs(n.dy) * cardSize.width * 0.25
        let betDistance = max(near + 2 * extent(opponentScale) + 8 + chipReach,
                              lineInset - avatarInset + cardSize.width * 0.18 + 4)
        let fallbackBet = avatar.offset(n, by: betDistance)
        // At the ends of the oval the plate hangs beside the cards rather
        // than behind them.
        let atEnd = abs(n.dx) > 0.9

        // The button's first choice: beside the cards, on the side towards
        // the bottom of the table (along the top, to the left). At the ends,
        // below the cards is the plate, so it goes above.
        var tangent = CGVector(dx: -n.dy, dy: n.dx)
        if tangent.dy < -0.01 || (abs(tangent.dy) <= 0.01 && tangent.dx > 0) {
            tangent = CGVector(dx: -tangent.dx, dy: -tangent.dy)
        }
        if atEnd { tangent = CGVector(dx: -tangent.dx, dy: -tangent.dy) }

        // Captions beside the plate, on the side towards the middle of the
        // table — level with the plate, or failing that with the avatar, or
        // on the other side. At the ends, beside the plate is where the cards
        // are, and under it is clear.
        let leftOfMiddle = avatar.x <= g.center.x + 1
        let plateLevel = frame.maxY - 29
        let beside: [(point: CGPoint, anchor: TableBadge.Anchor)] = [
            (CGPoint(x: frame.maxX, y: plateLevel), .trailing), (CGPoint(x: frame.minX, y: plateLevel), .leading),
            (CGPoint(x: frame.maxX, y: avatar.y), .trailing), (CGPoint(x: frame.minX, y: avatar.y), .leading),
        ]
        let captionCandidates: [(point: CGPoint, anchor: TableBadge.Anchor)]
        if atEnd {
            captionCandidates = [(CGPoint(x: avatar.x, y: frame.maxY), .below)]
        } else if leftOfMiddle {
            captionCandidates = [beside[0], beside[2], beside[1], beside[3]]
        } else {
            captionCandidates = [beside[1], beside[3], beside[0], beside[2]]
        }

        // The hand's name at the showdown: beyond the cards from the seat
        // where that is open cloth, beside them (towards the middle) where
        // beyond is the pot's — first choice first.
        let towards: (point: CGPoint, anchor: TableBadge.Anchor) = leftOfMiddle
            ? (CGPoint(x: revealedBox.maxX, y: revealedBox.midY), .trailing)
            : (CGPoint(x: revealedBox.minX, y: revealedBox.midY), .leading)
        let away: (point: CGPoint, anchor: TableBadge.Anchor) = leftOfMiddle
            ? (CGPoint(x: revealedBox.minX, y: revealedBox.midY), .leading)
            : (CGPoint(x: revealedBox.maxX, y: revealedBox.midY), .trailing)
        let below = (point: CGPoint(x: revealedBox.midX, y: revealedBox.maxY), anchor: TableBadge.Anchor.below)
        let above = (point: CGPoint(x: revealedBox.midX, y: revealedBox.minY), anchor: TableBadge.Anchor.above)
        let names: [(point: CGPoint, anchor: TableBadge.Anchor)]
        if atEnd {
            names = [towards, above, below, away]
        } else if n.dy < -0.3 {
            names = [above, towards, below, away]
        } else if abs(n.dx) < 0.3 {
            names = [towards, away, below, above]
        } else {
            names = [below, towards, above, away]
        }

        return Draft(avatar: avatar, inward: n, platesInward: platesInward, frame: frame, hole: hole, holeBox: holeBox,
                     revealedHole: revealedHole, revealedScale: scale, revealedBox: revealedBox, rotation: rotation,
                     captionCandidates: captionCandidates, handNameCandidates: names,
                     fallbackBet: fallbackBet, tangent: tangent, atEnd: atEnd, isHuman: false)
    }

    // MARK: Cards

    /// The two hole cards of `seat`: the player's large and open, everyone
    /// else's small and tucked together — or open and larger once turned up.
    func holePoses(seat: Int, revealed: Bool) -> [CardPose] {
        guard let spot = spots[safe: seat] else { return [] }
        if seat == 0 { return Self.humanPoses(anchor: spot.hole, cardSize: cardSize) }
        return Self.opponentPoses(anchor: revealed ? spot.revealedHole : spot.hole,
                                  scale: revealed ? spot.revealedScale : opponentScale,
                                  rotation: spot.holeRotation, revealed: revealed, cardSize: cardSize,
                                  baseZ: 100 + seat * 4)
    }

    private static func opponentPoses(anchor: CGPoint, scale: CGFloat, rotation: CGFloat, revealed: Bool,
                                      cardSize: CGSize, baseZ: Int) -> [CardPose] {
        let style = revealed ? FanStyle(spacing: 0.62, maximumSpread: 0.26, radius: 3.4)
                             : FanStyle(spacing: 0.30, maximumSpread: 0.22, radius: 3.0)
        let fan = TableLayout.fan(count: 2, anchor: anchor, cardSize: cardSize, side: .bottom, style: style,
                                  scale: scale, baseZ: baseZ)
        // The fan is built upright about its anchor; turn it as a whole.
        let c = cos(rotation), s = sin(rotation)
        return fan.map { pose in
            var p = pose
            let dx = pose.position.x - anchor.x, dy = pose.position.y - anchor.y
            p.position = CGPoint(x: anchor.x + dx * c - dy * s, y: anchor.y + dx * s + dy * c)
            p.rotation += rotation
            return p
        }
    }

    /// A card in the dealer's hands, about to be dealt.
    var dealPose: CardPose {
        CardPose(position: dealFrom, rotation: 0, z: 30, scale: opponentScale * 0.9)
    }

    /// Where the pots stand, main pot first, in one row centred over the
    /// board, `gap` apart.
    func potPositions(widths: [CGFloat], gap: CGFloat) -> [CGPoint] {
        guard !widths.isEmpty else { return [] }
        let total = widths.reduce(0, +) + gap * CGFloat(widths.count - 1)
        var x = pot.x - total / 2
        var points: [CGPoint] = []
        for w in widths {
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
