//
//  RNG.swift
//  A deterministic, self-contained random number generator.
//
//  Deal numbers are part of the product: a player can write down "game 40312",
//  come back next year on a different Mac, and get the same cards. That rules
//  out `SystemRandomNumberGenerator` and even `arc4random`, whose output is not
//  guaranteed stable across OS versions. xoshiro256** is 20 lines, fast, and
//  produces the identical stream forever.
//

import Foundation

/// SplitMix64 — used only to expand a single seed into xoshiro's 256-bit state.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// xoshiro256** — the shuffle generator. Deterministic for a given seed.
struct DeterministicRNG: RandomNumberGenerator {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        var sm = SplitMix64(state: seed)
        s = (sm.next(), sm.next(), sm.next(), sm.next())
        // xoshiro is a linear generator: from an all-zero state it produces
        // nothing but zeros, for ever. SplitMix64 will not hand us one in
        // practice, but a hash-derived seed one day might.
        if s.0 == 0 && s.1 == 0 && s.2 == 0 && s.3 == 0 {
            s = (0x9E37_79B9_7F4A_7C15, 1, 2, 3)
        }
    }

    private static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 &- k))
    }

    mutating func next() -> UInt64 {
        let result = Self.rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = Self.rotl(s.3, 45)
        return result
    }

    /// Unbiased integer in `0..<bound` (Lemire's method, without the rejection
    /// loop's worst case mattering here — bounds are tiny).
    mutating func next(upperBound bound: Int) -> Int {
        precondition(bound > 0)
        let b = UInt64(bound)
        var m = next().multipliedFullWidth(by: b)
        if m.low < b {
            let threshold = (0 &- b) % b
            while m.low < threshold {
                m = next().multipliedFullWidth(by: b)
            }
        }
        return Int(m.high)
    }

    /// Fisher-Yates, back to front. Fixed forever: changing the direction or
    /// the bound method would silently renumber every existing deal.
    mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            let j = next(upperBound: i + 1)
            if i != j { array.swapAt(i, j) }
        }
    }
}

/// Deal numbers the player sees. Bounded so they stay comfortable to read and
/// retype, and so the "random deal" picker has a well-defined range.
enum DealNumber {
    static let range: ClosedRange<Int> = 1...1_000_000

    static func random() -> Int {
        Int.random(in: range)
    }

    /// Deal numbers are 1-based for humans; the RNG wants a well-mixed 64-bit
    /// seed, so mix in a constant to avoid the low-entropy start of SplitMix64.
    static func seed(for dealNumber: Int) -> UInt64 {
        UInt64(bitPattern: Int64(dealNumber)) &* 0x2545_F491_4F6C_DD1D &+ 0x1234_5678_9ABC_DEF
    }
}
