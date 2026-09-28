//
//  Plural.swift
//  Counted nouns — "1 move", "24 moves" — in every language the app speaks.
//
//  English has two forms and Russian three (1 ход, 2 хода, 5 ходов), and
//  `String(format:)` knows about none of them, which is how a status pill
//  once read "1 moves". So a count shown to the player never goes through
//  `String(format: NSLocalizedString("%d moves", …), n)`. It goes through
//  here: the English singular or plural key is picked by the number, and the
//  string is formatted with `String.localizedStringWithFormat` — the call
//  that consults a `.stringsdict` — so the Russian localisation can give each
//  of the two keys its one / few / many / other forms without a line of code
//  changing.
//

import Foundation

enum Plural {

    /// `count` formatted into `one` (for exactly one) or `other`, both
    /// already localised and each containing one `%d`:
    ///
    ///     Plural.format(n, one: NSLocalizedString("%d move", comment: "…"),
    ///                      other: NSLocalizedString("%d moves", comment: "…"))
    ///
    /// Put the count first in the key, and one count per string — a sentence
    /// with two counts is two strings.
    static func format(_ count: Int, one: String, other: String) -> String {
        String.localizedStringWithFormat(count == 1 ? one : other, count)
    }
}
