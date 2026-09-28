//
//  Theme.swift
//  Colours and card backs. All procedural — the app ships no image assets.
//
//  Shared by every card game in the collection. What the player picks in
//  View ▸ Table Colour and View ▸ Card Back lives in `TablePreferences`; this
//  file is the vocabulary those choices are made in and the colours they turn
//  into.
//

import AppKit

enum TableColor: String, CaseIterable, Codable, Sendable {
    case green, blue, burgundy, slate

    var localizedName: String {
        switch self {
        case .green: return NSLocalizedString("Green Felt", comment: "table")
        case .blue: return NSLocalizedString("Blue Felt", comment: "table")
        case .burgundy: return NSLocalizedString("Burgundy", comment: "table")
        case .slate: return NSLocalizedString("Slate", comment: "table")
        }
    }

    /// Centre and edge of the table's radial vignette. Real felt is never one
    /// flat colour; the gradient is what stops the background looking like
    /// construction paper.
    var gradient: (center: NSColor, edge: NSColor) {
        switch self {
        case .green:
            return (NSColor(srgbRed: 0.176, green: 0.478, blue: 0.322, alpha: 1),
                    NSColor(srgbRed: 0.047, green: 0.216, blue: 0.145, alpha: 1))
        case .blue:
            return (NSColor(srgbRed: 0.145, green: 0.361, blue: 0.549, alpha: 1),
                    NSColor(srgbRed: 0.043, green: 0.145, blue: 0.259, alpha: 1))
        case .burgundy:
            return (NSColor(srgbRed: 0.435, green: 0.169, blue: 0.216, alpha: 1),
                    NSColor(srgbRed: 0.196, green: 0.055, blue: 0.086, alpha: 1))
        case .slate:
            return (NSColor(srgbRed: 0.243, green: 0.267, blue: 0.310, alpha: 1),
                    NSColor(srgbRed: 0.094, green: 0.106, blue: 0.129, alpha: 1))
        }
    }

    /// The same four cloths, dyed for the Apple table — which is the table
    /// every game in the collection is played on.
    ///
    /// Deeper and a touch less bright than the flat versions, because
    /// `AppleStyle` then lays a weave, a grain and a heavy corner vignette over
    /// the top of them. Reusing the flat colours there comes out washed out
    /// and faintly grey: texture only reads as texture when it has somewhere
    /// dark to read against.
    var appleGradient: (center: NSColor, edge: NSColor) {
        switch self {
        case .green:
            return (NSColor(srgbRed: 0.157, green: 0.443, blue: 0.290, alpha: 1),
                    NSColor(srgbRed: 0.020, green: 0.106, blue: 0.071, alpha: 1))
        case .blue:
            return (NSColor(srgbRed: 0.118, green: 0.318, blue: 0.502, alpha: 1),
                    NSColor(srgbRed: 0.016, green: 0.071, blue: 0.145, alpha: 1))
        case .burgundy:
            return (NSColor(srgbRed: 0.404, green: 0.133, blue: 0.180, alpha: 1),
                    NSColor(srgbRed: 0.114, green: 0.024, blue: 0.043, alpha: 1))
        case .slate:
            return (NSColor(srgbRed: 0.224, green: 0.247, blue: 0.290, alpha: 1),
                    NSColor(srgbRed: 0.047, green: 0.055, blue: 0.071, alpha: 1))
        }
    }
}

enum CardBackStyle: String, CaseIterable, Codable, Sendable {
    case lattice, arcs, weave, plain

    var localizedName: String {
        switch self {
        case .lattice: return NSLocalizedString("Lattice", comment: "card back")
        case .arcs: return NSLocalizedString("Arcs", comment: "card back")
        case .weave: return NSLocalizedString("Weave", comment: "card back")
        case .plain: return NSLocalizedString("Plain", comment: "card back")
        }
    }
}

enum CardBackColor: String, CaseIterable, Codable, Sendable {
    case navy, crimson, forest, charcoal, plum

    var localizedName: String {
        switch self {
        case .navy: return NSLocalizedString("Navy", comment: "card back colour")
        case .crimson: return NSLocalizedString("Crimson", comment: "card back colour")
        case .forest: return NSLocalizedString("Forest", comment: "card back colour")
        case .charcoal: return NSLocalizedString("Charcoal", comment: "card back colour")
        case .plum: return NSLocalizedString("Plum", comment: "card back colour")
        }
    }

    var base: NSColor {
        switch self {
        case .navy: return NSColor(srgbRed: 0.114, green: 0.243, blue: 0.451, alpha: 1)
        case .crimson: return NSColor(srgbRed: 0.482, green: 0.106, blue: 0.161, alpha: 1)
        case .forest: return NSColor(srgbRed: 0.106, green: 0.361, blue: 0.235, alpha: 1)
        case .charcoal: return NSColor(srgbRed: 0.180, green: 0.196, blue: 0.227, alpha: 1)
        case .plum: return NSColor(srgbRed: 0.322, green: 0.161, blue: 0.412, alpha: 1)
        }
    }

    var highlight: NSColor {
        base.blended(withFraction: 0.30, of: .white) ?? base
    }

    var shade: NSColor {
        base.blended(withFraction: 0.32, of: .black) ?? base
    }
}

/// Everything the renderer needs to know about how the board should look.
struct Theme: Equatable {
    var table: TableColor = .green
    var backStyle: CardBackStyle = .lattice
    var backColor: CardBackColor = .navy
    /// Four-colour deck: the standard accommodation for players who cannot
    /// tell red from black. Off by default, and worth offering prominently.
    var fourColorDeck: Bool = false
    /// The Apple look: cloth over a wooden table, printed card stock under a
    /// varnish, piles pressed into the felt, and cards that turn over edge-on
    /// in real perspective. Purely a surface treatment — see `AppleStyle`.
    ///
    /// On, always, in the app: the whole collection is dressed this way and
    /// there is no longer a switch for it. The flat rendering it replaced is
    /// kept behind `false` because the play-test compares the two — a surface
    /// treatment that silently stopped reaching the renderer would otherwise
    /// look like nothing at all had gone wrong.
    var apple: Bool = true

    // Card face
    let faceColor = NSColor(srgbRed: 0.992, green: 0.992, blue: 0.980, alpha: 1)
    let faceEdge = NSColor(srgbRed: 0.65, green: 0.64, blue: 0.62, alpha: 1)

    func color(for suit: Suit) -> NSColor {
        // Printed ink rather than screen colour: a real deck's red is a warm
        // vermilion laid on cream stock, and its black is a soft-edged charcoal
        // that never reaches the value a monitor can. The four-colour deck is
        // left alone — its whole job is to be told apart at a glance, and
        // muting it for the sake of the material would be the wrong trade.
        if apple && !fourColorDeck {
            return suit.isRed
                ? NSColor(srgbRed: 0.722, green: 0.106, blue: 0.145, alpha: 1)
                : NSColor(srgbRed: 0.114, green: 0.110, blue: 0.114, alpha: 1)
        }
        if fourColorDeck {
            switch suit {
            case .spades: return NSColor(srgbRed: 0.102, green: 0.102, blue: 0.118, alpha: 1)
            case .hearts: return NSColor(srgbRed: 0.769, green: 0.118, blue: 0.227, alpha: 1)
            case .diamonds: return NSColor(srgbRed: 0.059, green: 0.384, blue: 0.784, alpha: 1)
            case .clubs: return NSColor(srgbRed: 0.078, green: 0.475, blue: 0.267, alpha: 1)
            }
        }
        return suit.isRed
            ? NSColor(srgbRed: 0.769, green: 0.118, blue: 0.227, alpha: 1)   // cardinal, not fire-engine
            : NSColor(srgbRed: 0.102, green: 0.102, blue: 0.118, alpha: 1)   // near-black reads softer
    }

    /// Outline of an empty pile.
    let emptySlotStroke = NSColor(white: 1, alpha: 0.22)
    let emptySlotFill = NSColor(white: 0, alpha: 0.10)
    let emptySlotGlyph = NSColor(white: 1, alpha: 0.20)

    /// Feedback colours.
    let hintColor = NSColor(srgbRed: 1.0, green: 0.843, blue: 0.286, alpha: 1)
    let dropTargetColor = NSColor(white: 1, alpha: 0.85)
    /// The same outline on the Apple table, where a flat white halo reads
    /// as a rendering artefact against cloth and wood. Warm light instead, in
    /// the same family as the hint — all the "look here" feedback in the app
    /// belongs to one colour.
    let appleDropTargetColor = NSColor(srgbRed: 1.0, green: 0.898, blue: 0.612, alpha: 0.95)

    /// Floating score changes. Both are pale rather than saturated: every table
    /// colour is a dark, fairly saturated field, and a mid-tone green or red
    /// laid over it turns to mud. Lightness is what carries the reading, hue
    /// only says which way the number went.
    let scoreGainColor = NSColor(srgbRed: 0.780, green: 1.0, blue: 0.847, alpha: 1)
    let scoreLossColor = NSColor(srgbRed: 1.0, green: 0.706, blue: 0.667, alpha: 1)

    /// A cache key that changes whenever a drawn card would look different.
    var cardCacheToken: String {
        "\(backStyle.rawValue)-\(backColor.rawValue)-\(fourColorDeck)-\(apple)"
    }
}
