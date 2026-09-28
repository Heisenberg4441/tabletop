//
//  BlackjackAmount.swift
//  Chips, to the half chip.
//
//  A blackjack pays three to two and a surrender hands back half the bet,
//  so a bet of 25 — the rack's own green chip — wins 37½ and surrenders for
//  12½. Rounding those down would quietly break the promise printed on the
//  felt, and every rounding would go the house's way. So the table counts in
//  half chips: every bet is whole chips (they come off the rack, and a
//  double or a split matches them), and every payout is exact.
//
//  Underneath, an amount is a number of half chips; on the outside it is
//  chips. Integer and decimal literals mean chips (`25`, `37.5`), it adds,
//  subtracts and compares like a number, and it is saved as a plain JSON
//  number — `1000` or `1037.5` — so a file written in whole chips reads back
//  exactly as it was.
//

import Foundation

struct BlackjackAmount: Hashable, Comparable, AdditiveArithmetic, Codable, CustomStringConvertible,
                        ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {

    /// The amount in half chips.
    private(set) var halves: Int

    init(halves: Int) {
        self.halves = halves
    }

    /// `chips` whole chips.
    init(_ chips: Int) {
        halves = chips * 2
    }

    init(integerLiteral value: Int) {
        self.init(value)
    }

    init(floatLiteral value: Double) {
        halves = Int((value * 2).rounded())
    }

    static let zero = BlackjackAmount(halves: 0)

    /// The whole chips in it, rounded down.
    var wholeChips: Int { halves >= 0 ? halves / 2 : (halves - 1) / 2 }

    /// There is half a chip in it.
    var hasHalf: Bool { halves % 2 != 0 }

    /// The amount as a plain number of chips, for arithmetic that leaves
    /// the table (a return over twenty thousand rounds).
    var chips: Double { Double(halves) / 2 }

    /// Half of it, to the half chip below — exact for any whole number of
    /// chips, which every bet is.
    var half: BlackjackAmount { BlackjackAmount(halves: halves / 2) }

    static func + (lhs: BlackjackAmount, rhs: BlackjackAmount) -> BlackjackAmount {
        BlackjackAmount(halves: lhs.halves + rhs.halves)
    }

    static func - (lhs: BlackjackAmount, rhs: BlackjackAmount) -> BlackjackAmount {
        BlackjackAmount(halves: lhs.halves - rhs.halves)
    }

    static prefix func - (amount: BlackjackAmount) -> BlackjackAmount {
        BlackjackAmount(halves: -amount.halves)
    }

    static func * (lhs: BlackjackAmount, rhs: Int) -> BlackjackAmount {
        BlackjackAmount(halves: lhs.halves * rhs)
    }

    static func < (lhs: BlackjackAmount, rhs: BlackjackAmount) -> Bool {
        lhs.halves < rhs.halves
    }

    /// `self`, kept within `range`.
    func clamped(to range: ClosedRange<BlackjackAmount>) -> BlackjackAmount {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }

    // MARK: Words

    /// The amount the way the player reads it: grouped by the locale, a
    /// half as a decimal — "1,250", "37.5".
    var formatted: String {
        Self.formatter.string(from: NSNumber(value: chips)) ?? description
    }

    /// A signed change: "+37.5", "−12.5" (a true minus, not a hyphen).
    var formattedChange: String {
        halves >= 0 ? "+" + formatted : "\u{2212}" + (-self).formatted
    }

    var description: String {
        hasHalf ? String(format: "%.1f", chips) : String(halves / 2)
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    // MARK: Saving

    /// Far beyond any table, and far inside `Int`: a hand-edited file can
    /// never make the sums overflow.
    private static let decodable = -1_000_000_000_000.0...1_000_000_000_000.0

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let chips = try? c.decode(Int.self) {
            let bounded = Swift.max(Int(Self.decodable.lowerBound), Swift.min(Int(Self.decodable.upperBound), chips))
            self.init(bounded)
        } else {
            let chips = try c.decode(Double.self)
            guard chips.isFinite else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a number of chips")
            }
            self.init(floatLiteral: Swift.max(Self.decodable.lowerBound, Swift.min(Self.decodable.upperBound, chips)))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if hasHalf { try c.encode(chips) } else { try c.encode(halves / 2) }
    }
}
