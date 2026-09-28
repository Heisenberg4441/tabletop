//
//  PokerStats.swift
//  The player's record, and where the table and the record live on disk.
//

import Foundation

/// Hands and tournaments over the player's whole history at the table.
struct PokerStats: Codable, Equatable, Sendable {
    var handsPlayed = 0
    /// Hands where the player took at least part of a pot.
    var handsWon = 0
    /// The most the player has taken in a single hand.
    var biggestPot = 0
    var tournamentsPlayed = 0
    var tournamentsWon = 0
    /// Best tournament place, 1 for a win; nil before the first finish.
    var bestFinish: Int?
    /// Cash games: chips won or lost over every hand the player sat in.
    var cashNet = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handsPlayed = max(0, c.pokerDecode(.handsPlayed, 0))
        handsWon = max(0, c.pokerDecode(.handsWon, 0))
        biggestPot = max(0, c.pokerDecode(.biggestPot, 0))
        tournamentsPlayed = max(0, c.pokerDecode(.tournamentsPlayed, 0))
        tournamentsWon = max(0, c.pokerDecode(.tournamentsWon, 0))
        bestFinish = c.pokerDecode(.bestFinish, nil)
        cashNet = c.pokerDecode(.cashNet, 0)
    }

    /// Counts a finished hand the player was dealt into.
    mutating func record(_ summary: PokerHandSummary, humanSeat: Int, mode: PokerMode) {
        handsPlayed += 1
        let won = summary.winnings[humanSeat] ?? 0
        if won > 0 {
            handsWon += 1
            biggestPot = max(biggestPot, won)
        }
        if mode == .cash { cashNet += summary.netChange[safe: humanSeat] ?? 0 }
    }

    /// Counts a tournament the player finished in `place`.
    mutating func recordTournament(place: Int) {
        tournamentsPlayed += 1
        if place == 1 { tournamentsWon += 1 }
        bestFinish = min(bestFinish ?? place, place)
    }
}

/// The two files: the table, and the record.
///
/// The table is saved whole, a hand in progress included — its deck and all
/// — and resumes exactly where it stood. Anything less would let a player
/// quit a hand gone wrong and have the chips back, or quit after the flop
/// and be dealt the same cards again knowing the board.
enum PokerStorage {

    static var tableFile: String { Storage.fileName("table.json", for: .poker) }
    static var statsFile: String { Storage.fileName("stats.json", for: .poker) }

    /// The saved table, if there is one worth resuming — mid-hand or not.
    /// Anything that does not add up is ignored.
    static func loadTable() -> PokerTable? {
        guard var table = Storage.load(PokerTable.self, from: tableFile) else { return nil }
        // A hand whose state does not hold together is given back to its
        // players, rather than the whole table lost.
        if !table.isConsistent && !table.isAtHandBoundary { table.abandonHandInProgress() }
        return table.isConsistent ? table : nil
    }

    static func save(_ table: PokerTable) {
        Storage.save(table, to: tableFile)
    }

    static func removeTable() {
        Storage.remove(tableFile)
    }

    static func loadStats() -> PokerStats {
        Storage.load(PokerStats.self, from: statsFile) ?? PokerStats()
    }

    static func save(_ stats: PokerStats) {
        Storage.save(stats, to: statsFile)
    }
}
