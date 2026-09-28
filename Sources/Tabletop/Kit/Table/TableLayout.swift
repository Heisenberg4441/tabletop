//
//  TableLayout.swift
//  Where cards go on a card table: hands, decks, piles and rows, worked out
//  as plain numbers.
//
//  Every function here is pure — sizes in, poses out — so a game computes
//  where each card belongs from its model, hands the poses to
//  `CardTableView.place`, and the view animates whatever changed. Nothing
//  needs to know whether the change was a deal, a play or a resize, which is
//  the same idea Solitaire's board is built on.
//
//  Coordinates are the table view's: points, origin top-left, y down, angles
//  in radians and positive clockwise.
//

import AppKit

/// Where one card lies: its centre, its turn, its place in the stacking
/// order, and whether it is buried out of sight under the pile it is in.
struct CardPose: Equatable {
    var position: CGPoint
    var rotation: CGFloat = 0
    var z: Int = 0
    /// True for a card so deep in a pile that nothing of it shows. The table
    /// hides it once it has landed, which saves the compositor drawing
    /// thirty identical backs on top of each other.
    var isHidden = false
    /// Drawn this much of the table's card size: an opponent's hand across
    /// the table at 0.7, say. The card keeps its full-size artwork, so it
    /// can grow back to 1 on its way to the middle without going soft.
    var scale: CGFloat = 1

    init(position: CGPoint, rotation: CGFloat = 0, z: Int = 0, isHidden: Bool = false, scale: CGFloat = 1) {
        self.position = position
        self.rotation = rotation
        self.z = z
        self.isHidden = isHidden
        self.scale = scale
    }
}

/// Which edge of the table a hand is held from. The hand's cards point
/// towards the middle of the table.
enum HandSide {
    case bottom, top, left, right

    /// How far the whole hand is turned from one held at the bottom.
    var angle: CGFloat {
        switch self {
        case .bottom: return 0
        case .top: return .pi
        case .left: return .pi / 2
        case .right: return -.pi / 2
        }
    }
}

/// How a hand is fanned.
struct FanStyle: Equatable {
    /// Centre-to-centre distance between neighbours along the arc, as a
    /// fraction of the card's width.
    var spacing: CGFloat
    /// The widest the fan may open, first card to last, in radians.
    var maximumSpread: CGFloat
    /// The arc's radius in card heights: small is a tight fan, large is
    /// nearly a straight row.
    var radius: CGFloat

    /// The player's own hand, face up: open enough to read every index.
    static let open = FanStyle(spacing: 0.56, maximumSpread: 0.70, radius: 3.4)
    /// An opponent's hand, face down: a tidy sliver that still shows how
    /// many cards they hold.
    static let compact = FanStyle(spacing: 0.17, maximumSpread: 0.42, radius: 3.0)
}

/// How big the cards are on a given table.
struct CardSizePolicy: Equatable {
    /// Card width as a fraction of the view's width.
    var widthFraction: CGFloat
    /// Card height as a fraction of the view's height.
    var heightFraction: CGFloat
    var minimumWidth: CGFloat = 46
    var maximumWidth: CGFloat = 148

    /// Width over height for every card in the app.
    static let aspect: CGFloat = 0.70

    /// The largest card that satisfies both fractions and the limits, in
    /// whole points so edges land on pixels.
    func cardSize(for size: CGSize) -> CGSize {
        let byWidth = size.width * widthFraction
        let byHeight = size.height * heightFraction * Self.aspect
        let width = min(maximumWidth, max(minimumWidth, min(byWidth, byHeight))).rounded()
        return CGSize(width: width, height: (width / Self.aspect).rounded())
    }

    /// A table with a hand at the bottom and a few things in the middle.
    static let standard = CardSizePolicy(widthFraction: 0.075, heightFraction: 0.165)
    /// The poker table: seven cards across the middle and six seats around.
    static let poker = CardSizePolicy(widthFraction: 0.066, heightFraction: 0.145, minimumWidth: 44, maximumWidth: 118)
    /// Blackjack: the dealer's hand and one or a few player hands, large.
    static let blackjack = CardSizePolicy(widthFraction: 0.078, heightFraction: 0.170, minimumWidth: 50, maximumWidth: 136)
    /// Durak: a hand of six (often many more) and six pairs on the table.
    static let durak = CardSizePolicy(widthFraction: 0.074, heightFraction: 0.160, minimumWidth: 48, maximumWidth: 130)
}

enum TableLayout {

    /// A hand of `count` cards fanned about `anchor` — the point the middle
    /// of the hand sits on — held from `side`. The first card is on the
    /// player's left and lowest in the stacking order, so every index stays
    /// readable. `maxWidth` squeezes the fan so the whole hand, card edges
    /// included, fits across that many points (measured along the hand).
    ///
    /// `scale` draws the hand smaller — an opponent across the table — and
    /// spaces it to match.
    static func fan(count: Int, anchor: CGPoint, cardSize: CGSize, side: HandSide = .bottom,
                    style: FanStyle = .open, maxWidth: CGFloat? = nil, scale: CGFloat = 1,
                    baseZ: Int = 0) -> [CardPose] {
        guard count > 0 else { return [] }
        let w = cardSize.width * scale, h = cardSize.height * scale
        var spacing = style.spacing * w
        if let maxWidth, count > 1 {
            spacing = min(spacing, max(1, (maxWidth - w) / CGFloat(count - 1)))
        }
        let radius = max(h, style.radius * h)
        var step = spacing / radius
        if count > 1 { step = min(step, style.maximumSpread / CGFloat(count - 1)) }
        let pivot = CGPoint(x: 0, y: radius)             // below the anchor, before turning
        let turn = side.angle
        let cosT = cos(turn), sinT = sin(turn)

        return (0..<count).map { i in
            let a = (CGFloat(i) - CGFloat(count - 1) / 2) * step
            // On the arc, relative to the anchor, for a hand at the bottom…
            let local = CGPoint(x: pivot.x + radius * sin(a), y: pivot.y - radius * cos(a))
            // …then turned to the side it is held from.
            let turned = CGPoint(x: local.x * cosT - local.y * sinT, y: local.x * sinT + local.y * cosT)
            return CardPose(position: CGPoint(x: anchor.x + turned.x, y: anchor.y + turned.y),
                            rotation: a + turn, z: baseZ + i, scale: scale)
        }
    }

    /// A straight row of `count` cards centred on `center`, `gap` apart
    /// (a fraction of the card's width): the flop, turn and river, a
    /// blackjack hand spread for reading.
    static func row(count: Int, center: CGPoint, cardSize: CGSize, gap: CGFloat = 0.14,
                    baseZ: Int = 0) -> [CardPose] {
        guard count > 0 else { return [] }
        let step = cardSize.width * (1 + gap)
        let first = center.x - step * CGFloat(count - 1) / 2
        return (0..<count).map { i in
            CardPose(position: CGPoint(x: (first + CGFloat(i) * step).rounded(), y: center.y.rounded()), z: baseZ + i)
        }
    }

    /// Cards laid overlapping from `start`, each `step` further on: a
    /// blackjack hand dealt towards the dealer, a column.
    static func cascade(count: Int, start: CGPoint, step: CGVector, baseZ: Int = 0) -> [CardPose] {
        (0..<max(0, count)).map { i in
            CardPose(position: CGPoint(x: start.x + step.dx * CGFloat(i), y: start.y + step.dy * CGFloat(i)),
                     z: baseZ + i)
        }
    }

    /// A deck squared up at `center`, `count` cards, the first the bottom
    /// one. Each card below the top peeks out a fraction of a point down and
    /// to the right — away from the lamp, where a real deck shows its
    /// thickness — up to `visibleThickness` cards; the rest are hidden.
    static func deck(count: Int, center: CGPoint, cardSize: CGSize, visibleThickness: Int = 8,
                     scale: CGFloat = 1, baseZ: Int = 0) -> [CardPose] {
        guard count > 0 else { return [] }
        let unit = cardSize.width * scale / 90
        return (0..<count).map { i in
            let fromTop = count - 1 - i
            let depth = CGFloat(min(fromTop, visibleThickness))
            return CardPose(position: CGPoint(x: center.x + depth * 0.40 * unit, y: center.y + depth * 0.55 * unit),
                            z: baseZ + i, isHidden: fromTop > visibleThickness, scale: scale)
        }
    }

    /// The trump in durak: turned face up and lying across under the deck,
    /// sticking out to one side by a little under half its length so its
    /// index shows. Stack it one below the deck's `baseZ`.
    static func trump(underDeckAt deck: CGPoint, cardSize: CGSize, towardsRight: Bool = true, z: Int = -1) -> CardPose {
        let reach = cardSize.height * 0.30
        return CardPose(position: CGPoint(x: deck.x + (towardsRight ? reach : -reach), y: deck.y),
                        rotation: .pi / 2, z: z)
    }

    /// A discard pile: cards thrown down at `center`, each at its own small
    /// angle and offset. Deterministic — the same `seed` and index always
    /// give the same card the same place — so the pile does not reshuffle
    /// itself every time the table is laid out.
    static func discardPile(count: Int, center: CGPoint, cardSize: CGSize, seed: UInt64 = 1,
                            maxAngle: CGFloat = 0.30, baseZ: Int = 0) -> [CardPose] {
        (0..<max(0, count)).map { i in
            var rng = DeterministicRNG(seed: seed &* 0x9E37_79B9 &+ UInt64(i) &* 0x2545_F491)
            func unit() -> CGFloat { CGFloat(rng.next(upperBound: 2001)) / 1000 - 1 }   // -1...1
            let angle = unit() * maxAngle
            let dx = unit() * cardSize.width * 0.10
            let dy = unit() * cardSize.height * 0.07
            return CardPose(position: CGPoint(x: center.x + dx, y: center.y + dy), rotation: angle, z: baseZ + i)
        }
    }

    /// Durak's table: pairs of attacking and beating cards, the beating card
    /// lying over its attacker a little down and to the right, turned a few
    /// degrees. Laid out in rows of up to `perRow` pairs centred on `center`.
    /// Returns (attack, defence) poses for each pair index.
    static func battlePairs(count: Int, center: CGPoint, cardSize: CGSize, perRow: Int = 3,
                            baseZ: Int = 0) -> [(attack: CardPose, defence: CardPose)] {
        guard count > 0 else { return [] }
        let columns = min(count, max(1, perRow))
        let rows = (count + columns - 1) / columns
        let pitchX = cardSize.width * 1.55
        let pitchY = cardSize.height * 1.08
        return (0..<count).map { i in
            let row = i / columns
            let inRow = min(columns, count - row * columns)
            let column = i % columns
            let x = center.x + (CGFloat(column) - CGFloat(inRow - 1) / 2) * pitchX
            let y = center.y + (CGFloat(row) - CGFloat(rows - 1) / 2) * pitchY
            let attack = CardPose(position: CGPoint(x: x - cardSize.width * 0.08, y: y - cardSize.height * 0.04),
                                  rotation: -0.035, z: baseZ + i * 2)
            let defence = CardPose(position: CGPoint(x: x + cardSize.width * 0.16, y: y + cardSize.height * 0.10),
                                   rotation: 0.16, z: baseZ + i * 2 + 1)
            return (attack, defence)
        }
    }

    /// The smallest rectangle containing every card in `poses` — a whole
    /// hand, drooping ends and turned corners included. A hand anchored at
    /// the bottom of a table should be lifted by however far this pokes
    /// past the edge.
    static func bounds(of poses: [CardPose], cardSize: CGSize) -> CGRect {
        guard let first = poses.first else { return .null }
        return poses.dropFirst().reduce(boundingBox(of: first, cardSize: cardSize)) {
            $0.union(boundingBox(of: $1, cardSize: cardSize))
        }
    }

    /// The smallest rectangle containing a card at `pose` — its corners
    /// turned with it. For keeping a layout inside the table.
    static func boundingBox(of pose: CardPose, cardSize: CGSize) -> CGRect {
        let w = cardSize.width * pose.scale / 2, h = cardSize.height * pose.scale / 2
        let c = cos(pose.rotation), s = sin(pose.rotation)
        let ex = abs(w * c) + abs(h * s)
        let ey = abs(w * s) + abs(h * c)
        return CGRect(x: pose.position.x - ex, y: pose.position.y - ey, width: ex * 2, height: ey * 2)
    }
}
