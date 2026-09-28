//
//  Chips.swift
//  Casino chips: how an amount breaks into them, what each one looks like,
//  and how to count them out loud.
//
//  The denominations are the standard casino set, and so are the colours —
//  white ones, red fives, green quarters, black hundreds, purple five-
//  hundreds, yellow thousands, orange five-thousands — because a player who
//  has sat at a real table reads a stack by colour before reading any number.
//
//  Each denomination divides the next one up, which is what makes the
//  greedy breakdown — as many of the biggest chip as fit, then the next — not
//  just simple but optimal: no other combination uses fewer chips. The
//  self-test checks that against an exhaustive search.
//

import AppKit

enum Chips {

    /// Every chip in the set, smallest first.
    static let denominations: [Int] = [1, 5, 25, 100, 500, 1_000, 5_000]

    /// One line of a breakdown: so many chips of one value.
    struct Count: Equatable {
        let denomination: Int
        let count: Int
    }

    /// `amount` as the fewest chips from `denominations`, biggest first.
    /// Zero or less is no chips. The counts always add back up to `amount`
    /// exactly, as long as the set contains a 1 — the standard one does.
    static func breakdown(_ amount: Int, denominations: [Int] = Chips.denominations) -> [Count] {
        guard amount > 0 else { return [] }
        var remaining = amount
        var result: [Count] = []
        for denomination in denominations.sorted(by: >) where denomination > 0 {
            let count = remaining / denomination
            if count > 0 {
                result.append(Count(denomination: denomination, count: count))
                remaining -= count * denomination
            }
        }
        return result
    }

    /// The amount a breakdown adds up to.
    static func total(_ counts: [Count]) -> Int {
        counts.reduce(0) { $0 + $1.denomination * $1.count }
    }

    /// An amount the way the player reads it: grouped by the locale,
    /// "1,250" or "1 250", no currency — these are chips, not money.
    static func format(_ amount: Int) -> String {
        formatter.string(from: NSNumber(value: amount)) ?? String(amount)
    }

    /// A signed change: "+240", "−75" (a true minus, not a hyphen).
    static func formatChange(_ delta: Int) -> String {
        delta >= 0 ? "+" + format(delta) : "\u{2212}" + format(-delta)
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    /// What's printed on a chip: "25", "500", "1K", "5K".
    static func faceLabel(_ denomination: Int) -> String {
        if denomination >= 1_000 && denomination % 1_000 == 0 {
            return String(format: NSLocalizedString("%dK", comment: "chip face: a value in thousands, e.g. 5K"),
                          denomination / 1_000)
        }
        return String(denomination)
    }
}

/// The colours of one denomination.
struct ChipStyle {
    /// The clay.
    let body: NSColor
    /// The edge spots and the printed ring.
    let insert: NSColor
    /// The value printed in the middle.
    let label: NSColor

    static func of(_ denomination: Int) -> ChipStyle {
        switch denomination {
        case 1:
            return ChipStyle(body: NSColor(srgbRed: 0.925, green: 0.914, blue: 0.886, alpha: 1),
                             insert: NSColor(srgbRed: 0.196, green: 0.325, blue: 0.588, alpha: 1),
                             label: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1))
        case 5:
            return ChipStyle(body: NSColor(srgbRed: 0.694, green: 0.118, blue: 0.133, alpha: 1),
                             insert: NSColor(srgbRed: 0.965, green: 0.953, blue: 0.925, alpha: 1),
                             label: .white)
        case 25:
            return ChipStyle(body: NSColor(srgbRed: 0.090, green: 0.420, blue: 0.247, alpha: 1),
                             insert: NSColor(srgbRed: 0.965, green: 0.953, blue: 0.925, alpha: 1),
                             label: .white)
        case 100:
            return ChipStyle(body: NSColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1),
                             insert: NSColor(srgbRed: 0.945, green: 0.933, blue: 0.905, alpha: 1),
                             label: .white)
        case 500:
            return ChipStyle(body: NSColor(srgbRed: 0.365, green: 0.184, blue: 0.494, alpha: 1),
                             insert: NSColor(srgbRed: 0.965, green: 0.910, blue: 0.690, alpha: 1),
                             label: .white)
        case 1_000:
            return ChipStyle(body: NSColor(srgbRed: 0.918, green: 0.733, blue: 0.231, alpha: 1),
                             insert: NSColor(srgbRed: 0.188, green: 0.149, blue: 0.098, alpha: 1),
                             label: NSColor(srgbRed: 0.20, green: 0.15, blue: 0.07, alpha: 1))
        case 5_000:
            return ChipStyle(body: NSColor(srgbRed: 0.882, green: 0.443, blue: 0.137, alpha: 1),
                             insert: NSColor(srgbRed: 0.965, green: 0.953, blue: 0.925, alpha: 1),
                             label: .white)
        default:
            return ChipStyle(body: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.52, alpha: 1),
                             insert: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1),
                             label: .white)
        }
    }
}
