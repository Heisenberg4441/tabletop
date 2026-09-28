//
//  DurakScenarios.swift
//  The tables `--shot durak --scenario NAME` photographs.
//
//  Rather than arranging cards by hand — which always looks arranged — each
//  scenario deals seeded games and lets Normal bots play every seat until
//  the table shows the moment wanted: the player about to throw in with
//  four at the table, a half-beaten attack to defend, a taker being piled
//  on. So a screenshot is a position that real play reaches, with a real
//  bito pile, real hand sizes and a real deck count; and the same command
//  always finds the same one.
//

import Foundation

struct DurakScenario {
    var state: DurakState
    var names: [String]
    var scoreboard: DurakScoreboard
    /// A toast the moment would be showing.
    var toast: (text: String, symbol: String)?
    /// The opening's lowest trump, held up.
    var reveal: (seat: Int, card: Card)?
    /// A card of the player's picked up by a click, its targets lit.
    var select: Card?

    /// The five the spec asks for, then three more moments worth checking:
    /// the transfer place, a click that needs a target, the opening's
    /// lowest trump — and the New Game card over an empty table.
    static let names = ["attack", "defend", "take", "endgame", "gameover", "transfer", "choose", "opening", "options"]

    /// The scenario called `name`, or nil if no seed within reach produced it.
    static func make(_ name: String) -> DurakScenario? {
        switch name {
        case "attack":
            // Your attack, four players: two pairs on the table, cards of
            // their ranks in your hand, Bito or throw in.
            return search(players: 4, variant: .podkidnoy, seeds: 1...400) { s in
                s.actor == 0 && s.phase == .throwIn && s.attacker == 0 && s.table.count >= 2 && s.table.count <= 3
                    && s.stockCount >= 6 && s.stockCount <= 12 && s.hands[0].count >= 5
                    && !s.throwInCandidates(for: 0).isEmpty && s.discard.count >= 4
            }.map { scenario(from: $0, toast: (NSLocalizedString("Your attack", comment: "durak toast"), "arrowtriangle.right.fill")) }
        case "defend":
            // Two attacking cards, one beaten; your cards that can beat the
            // other lifted.
            return search(players: 3, variant: .podkidnoy, seeds: 1...400) { s in
                s.actor == 0 && s.phase == .defend && s.defender == 0 && s.table.count == 2
                    && s.table.filter(\.isBeaten).count == 1 && s.stockCount >= 4
                    && s.playableCards(for: 0).count >= 2 && s.hands[0].count >= 5
            }.map { scenario(from: $0, toast: (NSLocalizedString("Defend", comment: "durak toast: it is your turn to beat the cards"),
                                               "shield.lefthalf.filled")) }
        case "take":
            // An opponent has said "Take" and you may pile on.
            return search(players: 3, variant: .podkidnoy, seeds: 1...400) { s in
                s.actor == 0 && s.phase == .pileOn && s.defender != 0 && s.table.count >= 2
                    && s.stockCount >= 3 && !s.throwInCandidates(for: 0).isEmpty
            }.map { s in
                let names = namesFor(s)
                return scenario(from: s, toast: (String(format: NSLocalizedString("%@ takes", comment: "durak toast: the defender picks up («Беру»)"),
                                                        names[s.defender]), "tray.and.arrow.down.fill"))
            }
        case "endgame":
            // The deck is gone, two players left, every card counting.
            return search(players: 2, variant: .podkidnoy, seeds: 1...400) { s in
                s.actor == 0 && s.stockCount == 0 && s.phase == .defend && s.defender == 0
                    && (3...7).contains(s.hands[0].count) && (3...7).contains(s.hands[1].count)
                    && s.table.count >= 2 && s.playableCards(for: 0).count >= 1
            }.map { scenario(from: $0, toast: nil) }
        case "gameover":
            // Four players; somebody at the side is the durak, their hand
            // turned up; you went out first.
            guard let over = search(players: 4, variant: .podkidnoy, seeds: 1...400, predicate: { s in
                guard case .durak(let loser)? = s.result else { return false }
                return loser % 2 == 1 && s.hands[loser].count >= 3 && s.outOrder.first == 0
            }) else { return nil }
            var result = scenario(from: over, toast: nil)
            // A session a few games old, this one included.
            if case .durak(let loser)? = over.result {
                result.scoreboard.games = 5
                result.scoreboard.durakCounts = [1, 1, 1, 0]
                result.scoreboard.durakCounts[loser] += 1
                result.scoreboard.draws = 1
            }
            return result
        case "transfer":
            // Perevodnoy: the attack can be passed on to the next player.
            return search(players: 3, variant: .perevodnoy, seeds: 1...400) { s in
                s.actor == 0 && s.phase == .defend && s.defender == 0 && s.transferTarget != nil
                    && s.legalActions(for: 0).contains { if case .transfer = $0 { return true } else { return false } }
                    && s.stockCount >= 4 && s.table.count >= 1
            }.map { scenario(from: $0, toast: nil) }
        case "choose":
            // Perevodnoy, after a transfer: two cards to beat, and a card in
            // your hand that could beat either — picked up, waiting for you
            // to say which.
            guard let state = search(players: 3, variant: .perevodnoy, seeds: 1...600, predicate: { s in
                guard s.actor == 0, s.phase == .defend, s.defender == 0, s.unbeatenAttacks.count >= 2,
                      s.stockCount >= 3 else { return false }
                return s.hands[0].contains { card in s.attacks(beatableBy: card).count >= 2 }
            }) else { return nil }
            var result = scenario(from: state, toast: nil)
            let candidates = state.hands[0].filter { state.attacks(beatableBy: $0).count >= 2 }
            // The cheapest such card: a person would pick that one up.
            result.select = candidates.min { ($0.suit == state.trump ? 9 : 0) + $0.durakRankIndex
                < ($1.suit == state.trump ? 9 : 0) + $1.durakRankIndex }
            return result
        case "opening":
            // The first deal: a computer player shows the lowest trump.
            for seed in UInt64(1)...200 {
                let game = DurakState.newGame(rules: DurakRules(playerCount: 4), seed: seed)
                guard let shown = game.state.shownTrump, game.state.attacker == 2 else { continue }
                var result = scenario(from: game.state, toast: nil)
                let names = result.names
                result.toast = (String(format: NSLocalizedString("%@ has the %@ and starts", comment: "durak opening: name, lowest trump"),
                                       names[2], shown.description), shown.suit.durakSymbolName)
                result.reveal = (2, shown)
                return result
            }
            return nil
        default:
            return nil
        }
    }

    /// The first position, over `seeds`, that `predicate` accepts, with every
    /// seat played by Normal bots.
    static func search(players: Int, variant: DurakVariant, seeds: ClosedRange<UInt64>,
                       predicate: (DurakState) -> Bool) -> DurakState? {
        let bot = DurakBot(.normal)
        for seed in seeds {
            var state = DurakState.newGame(rules: DurakRules(playerCount: players, variant: variant), seed: seed).state
            for _ in 0..<600 {
                if predicate(state) { return state }
                guard let actor = state.actor else { break }
                guard (try? state.apply(bot.decide(in: state, seat: actor), by: actor)) != nil else { break }
            }
            if predicate(state) { return state }
        }
        return nil
    }

    static func namesFor(_ state: DurakState) -> [String] {
        [NSLocalizedString("You", comment: "durak: the player's seat")]
            + DurakSession.pickNames(state.playerCount - 1, seed: 7)
    }

    private static func scenario(from state: DurakState, toast: (String, String)?) -> DurakScenario {
        var board = DurakScoreboard(playerCount: state.playerCount)
        board.games = 2
        board.durakCounts[1 % state.playerCount] = 1
        board.durakCounts[state.playerCount - 1] += 1
        return DurakScenario(state: state, names: namesFor(state), scoreboard: board,
                             toast: toast.map { (text: $0.0, symbol: $0.1) }, reveal: nil, select: nil)
    }
}
