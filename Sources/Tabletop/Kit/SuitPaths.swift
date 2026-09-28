//
//  SuitPaths.swift
//  The four suit symbols as bezier outlines.
//
//  Drawing the pips rather than setting ♠♥♦♣ in a system font is a deliberate
//  choice: font glyphs vary in weight and proportion between faces and system
//  versions, they sit on a text baseline rather than in a box, and at pip size
//  the hinting makes hearts and diamonds hard to tell apart. Outlines are the
//  same shape at every size and centre exactly where we put them.
//
//  All paths are described inside the unit square with y increasing downward,
//  which is how the card is drawn, and are scaled into place by the caller.
//

import CoreGraphics

enum SuitPath {

    static func path(for suit: Suit) -> CGPath {
        switch suit {
        case .hearts: return heart
        case .diamonds: return diamond
        case .spades: return spade
        case .clubs: return club
        }
    }

    /// Fits the unit path into `rect`, keeping its proportions and centring it.
    static func path(for suit: Suit, in rect: CGRect, rotated: Bool = false) -> CGPath {
        let side = min(rect.width, rect.height)
        var transform = CGAffineTransform.identity
        if rotated {
            // Rotate about the centre of the destination box.
            transform = transform
                .translatedBy(x: rect.midX, y: rect.midY)
                .rotated(by: .pi)
                .translatedBy(x: -rect.midX, y: -rect.midY)
        }
        transform = transform
            .translatedBy(x: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: side, y: side)
        return path(for: suit).copy(using: &transform) ?? path(for: suit)
    }

    // MARK: Shapes

    /// Two lobes meeting in a dip, drawn down to a single point.
    private static let heart: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.500, y: 0.950))
        p.addCurve(to: CGPoint(x: 0.020, y: 0.340),
                   control1: CGPoint(x: 0.160, y: 0.720), control2: CGPoint(x: 0.020, y: 0.530))
        p.addCurve(to: CGPoint(x: 0.335, y: 0.030),
                   control1: CGPoint(x: 0.020, y: 0.125), control2: CGPoint(x: 0.195, y: 0.030))
        p.addCurve(to: CGPoint(x: 0.500, y: 0.215),
                   control1: CGPoint(x: 0.435, y: 0.030), control2: CGPoint(x: 0.500, y: 0.125))
        p.addCurve(to: CGPoint(x: 0.665, y: 0.030),
                   control1: CGPoint(x: 0.500, y: 0.125), control2: CGPoint(x: 0.565, y: 0.030))
        p.addCurve(to: CGPoint(x: 0.980, y: 0.340),
                   control1: CGPoint(x: 0.805, y: 0.030), control2: CGPoint(x: 0.980, y: 0.125))
        p.addCurve(to: CGPoint(x: 0.500, y: 0.950),
                   control1: CGPoint(x: 0.980, y: 0.530), control2: CGPoint(x: 0.840, y: 0.720))
        p.closeSubpath()
        return p
    }()

    /// A rhombus with very slightly convex sides — dead-straight edges look
    /// mechanical next to the other three shapes.
    private static let diamond: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.500, y: 0.020))
        p.addCurve(to: CGPoint(x: 0.945, y: 0.500),
                   control1: CGPoint(x: 0.625, y: 0.190), control2: CGPoint(x: 0.800, y: 0.375))
        p.addCurve(to: CGPoint(x: 0.500, y: 0.980),
                   control1: CGPoint(x: 0.800, y: 0.625), control2: CGPoint(x: 0.625, y: 0.810))
        p.addCurve(to: CGPoint(x: 0.055, y: 0.500),
                   control1: CGPoint(x: 0.375, y: 0.810), control2: CGPoint(x: 0.200, y: 0.625))
        p.addCurve(to: CGPoint(x: 0.500, y: 0.020),
                   control1: CGPoint(x: 0.200, y: 0.375), control2: CGPoint(x: 0.375, y: 0.190))
        p.closeSubpath()
        return p
    }()

    /// An inverted heart standing on a flared stem.
    private static let spade: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.500, y: 0.025))
        p.addCurve(to: CGPoint(x: 0.075, y: 0.545),
                   control1: CGPoint(x: 0.410, y: 0.215), control2: CGPoint(x: 0.190, y: 0.395))
        p.addCurve(to: CGPoint(x: 0.185, y: 0.760),
                   control1: CGPoint(x: 0.005, y: 0.635), control2: CGPoint(x: 0.040, y: 0.760))
        p.addCurve(to: CGPoint(x: 0.430, y: 0.665),
                   control1: CGPoint(x: 0.300, y: 0.760), control2: CGPoint(x: 0.375, y: 0.720))
        p.addCurve(to: CGPoint(x: 0.305, y: 0.965),
                   control1: CGPoint(x: 0.430, y: 0.800), control2: CGPoint(x: 0.385, y: 0.905))
        p.addLine(to: CGPoint(x: 0.695, y: 0.965))
        p.addCurve(to: CGPoint(x: 0.570, y: 0.665),
                   control1: CGPoint(x: 0.615, y: 0.905), control2: CGPoint(x: 0.570, y: 0.800))
        p.addCurve(to: CGPoint(x: 0.815, y: 0.760),
                   control1: CGPoint(x: 0.625, y: 0.720), control2: CGPoint(x: 0.700, y: 0.760))
        p.addCurve(to: CGPoint(x: 0.925, y: 0.545),
                   control1: CGPoint(x: 0.960, y: 0.760), control2: CGPoint(x: 0.995, y: 0.635))
        p.addCurve(to: CGPoint(x: 0.500, y: 0.025),
                   control1: CGPoint(x: 0.810, y: 0.395), control2: CGPoint(x: 0.590, y: 0.215))
        p.closeSubpath()
        return p
    }()

    /// Three lobes and a stem. Built from circles so the lobes stay perfectly
    /// round, which is what makes a club look right.
    private static let club: CGPath = {
        let p = CGMutablePath()
        let r: CGFloat = 0.235
        p.addEllipse(in: CGRect(x: 0.500 - r, y: 0.055, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: 0.020, y: 0.400, width: r * 2, height: r * 2))
        p.addEllipse(in: CGRect(x: 0.980 - r * 2, y: 0.400, width: r * 2, height: r * 2))
        // Stem: narrow at the lobes, flaring to a flat foot.
        p.move(to: CGPoint(x: 0.425, y: 0.545))
        p.addCurve(to: CGPoint(x: 0.265, y: 0.965),
                   control1: CGPoint(x: 0.455, y: 0.720), control2: CGPoint(x: 0.375, y: 0.880))
        p.addLine(to: CGPoint(x: 0.735, y: 0.965))
        p.addCurve(to: CGPoint(x: 0.575, y: 0.545),
                   control1: CGPoint(x: 0.625, y: 0.880), control2: CGPoint(x: 0.545, y: 0.720))
        p.closeSubpath()
        return p
    }()
}

/// Small ornaments that mark the three court ranks apart from one another.
enum CourtOrnament {

    static func path(for rank: Rank, in rect: CGRect) -> CGPath? {
        let unit: CGPath?
        switch rank {
        case .king: unit = crown(points: 5)
        case .queen: unit = crown(points: 3)
        case .jack: unit = pennant
        default: unit = nil
        }
        guard let unit else { return nil }
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width, y: rect.height)
        return unit.copy(using: &t)
    }

    /// A coronet: a flat band with `points` spikes rising from it.
    private static func crown(points: Int) -> CGPath {
        let p = CGMutablePath()
        let n = max(3, points)
        let bandTop: CGFloat = 0.72
        p.move(to: CGPoint(x: 0.02, y: 1.0))
        p.addLine(to: CGPoint(x: 0.02, y: 0.38))
        // Alternate spike tips and valleys across the width.
        let steps = n * 2 - 1
        for i in 0...steps {
            let x = 0.02 + (0.96 * CGFloat(i) / CGFloat(steps))
            let isTip = i % 2 == 0
            p.addLine(to: CGPoint(x: x, y: isTip ? 0.06 : bandTop))
        }
        p.addLine(to: CGPoint(x: 0.98, y: 1.0))
        p.closeSubpath()
        return p
    }

    /// A small swallow-tailed flag on a staff.
    private static let pennant: CGPath = {
        let p = CGMutablePath()
        p.addRect(CGRect(x: 0.10, y: 0.00, width: 0.11, height: 1.00))
        p.move(to: CGPoint(x: 0.21, y: 0.08))
        p.addLine(to: CGPoint(x: 0.98, y: 0.08))
        p.addLine(to: CGPoint(x: 0.78, y: 0.36))
        p.addLine(to: CGPoint(x: 0.98, y: 0.64))
        p.addLine(to: CGPoint(x: 0.21, y: 0.64))
        p.closeSubpath()
        return p
    }()
}
