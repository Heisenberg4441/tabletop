import Foundation

/// Names for computer players, and a deterministic way to seat them.
enum BotRoster {
    static var names: [String] {
        [
            NSLocalizedString("Anna", comment: "computer player's name"),
            NSLocalizedString("Boris", comment: "computer player's name"),
            NSLocalizedString("Chloé", comment: "computer player's name"),
            NSLocalizedString("Dmitri", comment: "computer player's name"),
            NSLocalizedString("Elena", comment: "computer player's name"),
            NSLocalizedString("Felix", comment: "computer player's name"),
            NSLocalizedString("Grace", comment: "computer player's name"),
            NSLocalizedString("Hiro", comment: "computer player's name"),
            NSLocalizedString("Ingrid", comment: "computer player's name"),
            NSLocalizedString("Jonas", comment: "computer player's name"),
            NSLocalizedString("Kofi", comment: "computer player's name"),
            NSLocalizedString("Lena", comment: "computer player's name"),
            NSLocalizedString("Marco", comment: "computer player's name"),
            NSLocalizedString("Nadia", comment: "computer player's name"),
            NSLocalizedString("Oscar", comment: "computer player's name"),
            NSLocalizedString("Priya", comment: "computer player's name"),
        ]
    }

    static func pick(_ count: Int, seed: UInt64) -> [String] {
        var pool = names
        var rng = DeterministicRNG(seed: seed &+ 0xB075)
        rng.shuffle(&pool)
        return Array(pool.prefix(max(0, min(count, pool.count))))
    }
}
