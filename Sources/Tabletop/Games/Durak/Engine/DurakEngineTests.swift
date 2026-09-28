//
//  DurakEngineTests.swift
//  The rules engine and the bots, checked: every rule on a hand-built
//  position, then tens of thousands of games of random legal moves, then the
//  bots against each other, then the endgame solver against brute force.
//
//  The player knows this game from the courtyard, so a rule that is slightly
//  off is a bug they will notice in the first five minutes; and a card that
//  goes missing is invisible until it ruins a game. So the fuzzer checks the
//  deck after every single action, replays the event stream the way a view
//  would and demands it arrive at the same table, and probes every position
//  with illegal actions to prove none is ever accepted.
//
//  The counts are sized for `--selftest`'s few seconds in a debug build;
//  `--selftest durak --durak-full` runs the full spec — 20,000 random games
//  and 2,000 bot games per difficulty — best in a release build.
//

import Foundation

enum DurakEngineTests {

    struct Scale {
        var fuzzGames: Int
        var botGames: Int
        var headToHead: Int
        /// Every pairing and both variants, or just Hard against Easy.
        var allPairings: Bool
        var solverPositions: Int
        var timedEndgames: Int

        static var current: Scale {
            if CommandLine.arguments.contains("--durak-full") {
                return Scale(fuzzGames: 20_000, botGames: 2_000, headToHead: 2_000, allPairings: true,
                             solverPositions: 2_000, timedEndgames: 200)
            }
            #if DEBUG
            return Scale(fuzzGames: 400, botGames: 20, headToHead: 80, allPairings: false,
                         solverPositions: 80, timedEndgames: 10)
            #else
            return Scale(fuzzGames: 3_000, botGames: 100, headToHead: 300, allPairings: true,
                         solverPositions: 300, timedEndgames: 40)
            #endif
        }
    }

    static func run(_ t: TestReporter) {
        let scale = Scale.current
        cards(t)
        dealing(t)
        throwIns(t)
        limits(t)
        bouts(t)
        refill(t)
        goingOut(t)
        transfers(t)
        saving(t)
        fuzz(t, games: scale.fuzzGames)
        solver(t, positions: scale.solverPositions, timed: scale.timedEndgames)
        bots(t, games: scale.botGames)
        headToHead(t, games: scale.headToHead, allPairings: scale.allPairings)
    }

    // MARK: - Helpers

    /// "7c", "10h", "Qs", "Ad": a card by its rank and suit letter.
    static func card(_ text: String) -> Card {
        let suit: Suit
        switch text.last {
        case "c": suit = .clubs
        case "d": suit = .diamonds
        case "h": suit = .hearts
        default: suit = .spades
        }
        let rank: Rank
        switch String(text.dropLast()) {
        case "J": rank = .jack
        case "Q": rank = .queen
        case "K": rank = .king
        case "A": rank = .ace
        case let digits: rank = Rank(rawValue: UInt8(digits) ?? 6) ?? .six
        }
        return Card(suit, rank)
    }

    static func cards(_ text: String) -> [Card] {
        text.split(separator: " ").map { card(String($0)) }
    }

    /// Applies a line of `(seat, action)`s, returning every event, or nil at
    /// the first refusal.
    static func play(_ state: inout DurakState, _ moves: [(Int, DurakAction)]) -> [DurakEvent]? {
        var events: [DurakEvent] = []
        for (seat, action) in moves {
            guard let e = try? state.apply(action, by: seat) else { return nil }
            events += e
        }
        return events
    }

    static func legalSet(_ state: DurakState, _ seat: Int) -> Set<DurakAction> {
        Set(state.legalActions(for: seat))
    }

    // MARK: - Cards

    static func cards(_ t: TestReporter) {
        t.section("Durak: cards")
        t.check("36 cards, six to ace", Card.durakDeck.count == 36 && Set(Card.durakDeck).count == 36
                    && Card.durakDeck.allSatisfy(\.isDurakCard))
        t.check("durak index round trip", Card.durakDeck.enumerated().allSatisfy { $0.element.durakIndex == $0.offset })
        t.check("ranks run six low to ace high",
                card("6c").durakValue == 6 && card("10c").durakValue == 10 && card("Ac").durakValue == 14
                    && card("Kc").durakValue < card("Ac").durakValue)
        let h = Suit.hearts
        t.check("same suit, higher beats", card("9c").durakBeats(card("7c"), trump: h))
        t.check("same suit, lower does not", !card("7c").durakBeats(card("9c"), trump: h))
        t.check("a card does not beat itself", !card("7c").durakBeats(card("7c"), trump: h))
        t.check("any trump beats a plain card", card("6h").durakBeats(card("Ac"), trump: h))
        t.check("higher trump beats lower trump", card("8h").durakBeats(card("7h"), trump: h))
        t.check("lower trump does not beat higher trump", !card("7h").durakBeats(card("8h"), trump: h))
        t.check("a plain card never beats a trump", !card("As").durakBeats(card("6h"), trump: h))
        t.check("another plain suit does not beat", !card("Ad").durakBeats(card("6c"), trump: h))
        var masksAgree = true
        for trump in Suit.allCases {
            for attack in Card.durakDeck {
                let beaters = DurakCardSet.beaters(of: attack, trump: trump)
                for defence in Card.durakDeck where beaters.contains(defence) != defence.durakBeats(attack, trump: trump) {
                    masksAgree = false
                }
            }
        }
        t.check("the beater masks agree with the rule, every card and trump", masksAgree)
        let hand = cards("Ah 7c 6h Ks 7d 10c 9s")
        t.check("hand sorted by suit: suits grouped, trumps at the right",
                Card.durakSorted(hand, trump: .hearts, order: .bySuit) == cards("7c 10c 7d 9s Ks 6h Ah"))
        t.check("hand sorted by rank: low to high, trumps at the right",
                Card.durakSorted(hand, trump: .hearts, order: .byRank) == cards("7c 7d 9s 10c Ks 6h Ah"))
        let set = DurakCardSet(cards("7c 7d Kh As"))
        t.check("card set counts, ranks and iterates",
                set.count == 4 && set.rankMask == (1 << 1 | 1 << 7 | 1 << 8) && Set(set.cards) == Set(cards("7c 7d Kh As")))
    }

    // MARK: - Dealing and the opening

    static func dealing(_ t: TestReporter) {
        t.section("Durak: dealing and who starts")
        var shapeOK = true, lowestOK = true, deterministic = true, trumpHeld = true
        for n in 2...4 {
            for seed in 1...300 {
                let (state, events) = DurakState.newGame(rules: DurakRules(playerCount: n), seed: UInt64(seed))
                if state.hands.contains(where: { $0.count != 6 }) || state.stockCount != 36 - 6 * n
                    || state.stock.first != state.trumpCard || !state.isConsistent { shapeOK = false }
                if case .dealt(let hands, let trump)? = events.first, hands == state.hands, trump == state.trumpCard {
                } else { shapeOK = false }
                // The lowest trump in anybody's hand is the first attacker's.
                let trumps = state.hands.enumerated().flatMap { seat, hand in
                    hand.filter { $0.suit == state.trump }.map { (seat, $0) }
                }
                guard let lowest = trumps.min(by: { $0.1.durakValue < $1.1.durakValue }) else { trumpHeld = false; continue }
                if state.attacker != lowest.0 || state.shownTrump != lowest.1 || state.defender != (lowest.0 + 1) % n
                    || state.actor != state.attacker || state.phase != .lead || !state.known[lowest.0].contains(lowest.1) {
                    lowestOK = false
                }
                if DurakState.newGame(rules: DurakRules(playerCount: n), seed: UInt64(seed)).state != state {
                    deterministic = false
                }
            }
        }
        t.check("six each, the rest in the deck, the trump card at its bottom", shapeOK)
        t.check("the lowest trump attacks first, and shows it", lowestOK)
        t.check("somebody always holds a trump (a trumpless deal is redealt)", trumpHeld)
        t.check("the same seed deals the same game", deterministic)
        t.check("different seeds deal different games",
                DurakState.newGame(rules: DurakRules(playerCount: 2), seed: 1).state
                    != DurakState.newGame(rules: DurakRules(playerCount: 2), seed: 2).state)

        // A deck laid out by hand: seat 2 of three has the six of trumps.
        let rules3 = DurakRules(playerCount: 3)
        var deck = Card.durakDeck
        // Seats get deck[i] for i % 3; deck[18] is the trump card.
        let order = cards("7c 8c 6h 9c 10c Jc Qc Kc 7h Ac 7d 8d 9d 10d 9h Jd Qd Kd Ah")
        deck = order + deck.filter { !order.contains($0) }
        if let (state, events) = DurakState.deal(rules: rules3, deck: deck, opening: .lowestTrump) {
            t.check("hand-laid deck: the six of trumps on seat 2 leads",
                    state.trump == .hearts && state.attacker == 2 && state.defender == 0 && state.shownTrump == card("6h"))
            t.check("the opening event names the card shown",
                    events.contains(.opening(attacker: 2, defender: 0, shown: card("6h"))))
            t.check("the first bout is the five-card bout", state.attackLimit == 5 && state.bout == 0)
        } else {
            t.check("hand-laid deck deals", false)
        }
        // Nobody holds a trump: no lowest-trump opening from this deck.
        let plain = Card.durakDeck.filter { $0.suit != .spades }
        let spades = Card.durakDeck.filter { $0.suit == .spades }
        let trumpless = Array(plain[0..<12]) + spades + Array(plain[12...])
        t.check("a deal with no trump in any hand is refused, to be redealt",
                DurakState.deal(rules: DurakRules(playerCount: 2), deck: trumpless, opening: .lowestTrump) == nil)

        // Под дурака: the durak defends first.
        let into = DurakState.newGame(rules: rules3, seed: 7, opening: .intoDurak(2)).state
        let into0 = DurakState.newGame(rules: rules3, seed: 7, opening: .intoDurak(0)).state
        let into2p = DurakState.newGame(rules: DurakRules(playerCount: 2), seed: 7, opening: .intoDurak(0)).state
        t.check("into the durak: the player on the durak's right attacks",
                into.attacker == 1 && into.defender == 2 && into0.attacker == 2 && into0.defender == 0
                    && into2p.attacker == 1 && into2p.defender == 0 && into.shownTrump == nil)
        t.check("the next game opens into the durak, after a draw by lowest trump",
                DurakOpening.following(.durak(1), playerCount: 3) == .intoDurak(1)
                    && DurakOpening.following(.draw, playerCount: 3) == .lowestTrump
                    && DurakOpening.following(nil, playerCount: 3) == .lowestTrump
                    && DurakOpening.following(.durak(3), playerCount: 2) == .lowestTrump)
    }

    // MARK: - Throw-ins

    static func throwIns(_ t: TestReporter) {
        t.section("Durak: throw-ins")
        let rules = DurakRules(playerCount: 2)
        let stock = cards("6s 6h 7h 8h")
        guard var state = DurakState.position(rules: rules, trumpCard: card("6s"),
                                              hands: [cards("7c 7d 9h Kc 10d Qh"), cards("9c 6d Jh Ad 8s 6c")],
                                              stock: stock, attacker: 0) else {
            t.check("throw-in position builds", false); return
        }
        t.check("the lead may be any card", legalSet(state, 0) == Set(state.hands[0].map { .attack($0) }))
        t.check("only the attacker is asked to lead", state.legalActions(for: 1).isEmpty)
        _ = play(&state, [(0, .attack(card("7c")))])
        t.check("the defender faces it: beat with a higher club or a trump, or take",
                legalSet(state, 1) == [.defend(card("9c"), on: card("7c")), .defend(card("8s"), on: card("7c")), .take])
        _ = play(&state, [(1, .defend(card("9c"), on: card("7c")))])
        t.check("all beaten: the attacker may add sevens and nines only",
                state.phase == .throwIn && state.actor == 0
                    && legalSet(state, 0) == [.attack(card("7d")), .attack(card("9h")), .pass])
        let before = state
        t.check("a king cannot be thrown in", (try? state.apply(.attack(card("Kc")), by: 0)) == nil && state == before)
        t.check("the defender cannot throw in", (try? state.apply(.attack(card("6d")), by: 1)) == nil)
        t.check("the pass is Bito from the main attacker", state.passKind(for: 0) == .bito)

        // Three players: the others throw in once the main attacker passes.
        let rules3 = DurakRules(playerCount: 3)
        guard var three = DurakState.position(rules: rules3, trumpCard: card("6s"),
                                              hands: [cards("7c Kc"), cards("9c 10c Jd Qd"), cards("9d 7h 8d")],
                                              attacker: 0) else {
            t.check("three-player position builds", false); return
        }
        _ = play(&three, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c")))])
        t.check("the main attacker with nothing to add is not asked; the next is",
                three.phase == .throwIn && three.actor == 2 && three.passKind(for: 2) == .pass
                    && legalSet(three, 2) == [.attack(card("9d")), .attack(card("7h")), .pass])
        _ = play(&three, [(2, .attack(card("9d"))), (1, .defend(card("Jd"), on: card("9d")))])
        t.check("a thrown-in card is beaten, then the round starts again from the top",
                three.phase == .throwIn && three.actor == 2)
        let events = play(&three, [(2, .pass)]) ?? []
        t.check("when nobody adds, it is bito", events.contains(where: {
            if case .bito(let c) = $0 { return Set(c) == Set(cards("7c 9c 9d Jd")) }
            return false
        }))

        // A player who passed is asked again only for a new rank.
        guard var again = DurakState.position(rules: rules3, trumpCard: card("6s"),
                                              hands: [cards("7c 7d 10d"), cards("9c 10h Jd Qd As"), cards("7h Kd 8d")],
                                              attacker: 0) else {
            t.check("re-ask position builds", false); return
        }
        _ = play(&again, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c"))), (0, .pass)])
        t.check("after the attacker's pass the co-attacker is asked", again.actor == 2)
        _ = play(&again, [(2, .attack(card("7h"))), (1, .defend(card("10h"), on: card("7h")))])
        t.check("a new rank on the table (ten): the attacker who passed is asked again",
                again.actor == 0 && legalSet(again, 0).contains(.attack(card("10d"))))
        guard var same = DurakState.position(rules: rules3, trumpCard: card("6s"),
                                             hands: [cards("7c 7d Kh"), cards("9c 10c Jd Qd As 9s"), cards("7h 9d 8d")],
                                             attacker: 0) else {
            t.check("no re-ask position builds", false); return
        }
        _ = play(&same, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c"))), (0, .pass),
                         (2, .attack(card("7h"))), (1, .defend(card("9s"), on: card("7h")))])
        t.check("no new rank: the attacker who passed is not asked again",
                same.actor == 2 && legalSet(same, 2) == [.attack(card("9d")), .pass])
    }

    // MARK: - Limits

    static func limits(_ t: TestReporter) {
        t.section("Durak: limits")
        let rules = DurakRules(playerCount: 2)
        // Six attacking cards at most.
        func sixBout(bout: Int) -> (pairs: Int, bito: Bool, spare: Bool) {
            guard var state = DurakState.position(
                rules: rules, trumpCard: card("6s"),
                hands: [cards("7c 7h 7d 9c 9h 9d 10c"), cards("9s 10s Js Qs Ks As 8s")],
                attacker: 0, bout: bout) else { return (0, false, false) }
            var pairs = 0
            var sawBito = false
            // Each beat brings a rank the attacker holds, so only the limit
            // can stop the bout.
            let attacks = cards("7c 7h 7d 9c 9h 9d")
            let beats = cards("9s 10s Js Qs Ks As")
            for i in 0..<attacks.count {
                guard state.legalActions(for: 0).contains(.attack(attacks[i])) else { break }
                guard let e = try? state.apply(.attack(attacks[i]), by: 0),
                      let f = try? state.apply(.defend(beats[i], on: attacks[i]), by: 1) else { break }
                pairs += 1
                if (e + f).contains(where: { if case .bito = $0 { return true }; return false }) { sawBito = true; break }
            }
            return (pairs, sawBito, state.hands[0].contains(where: { $0.rank == .nine || $0.rank == .ten }))
        }
        let six = sixBout(bout: 3)
        t.check("no more than six attacking cards: the sixth beaten is bito though more would fit",
                six.pairs == 6 && six.bito && six.spare)
        let five = sixBout(bout: 0)
        t.check("the first bout of the game stops at five", five.pairs == 5 && five.bito && five.spare)

        // Never more unbeaten cards than the defender holds.
        guard var small = DurakState.position(rules: rules, trumpCard: card("6s"),
                                              hands: [cards("7c 7d 7h 9c"), cards("6d Kh")], attacker: 0) else {
            t.check("small-hand position builds", false); return
        }
        _ = play(&small, [(0, .attack(card("7c"))), (1, .take)])
        t.check("taking with two cards: one more may be piled on",
                small.phase == .pileOn && small.remainingAttackRoom == 1 && small.passKind(for: 0) == .done)
        let taken = play(&small, [(0, .attack(card("7d")))]) ?? []
        t.check("then no more: the defender picks up at once", taken.contains(.took(seat: 1, cards: cards("7c 7d")))
                    && small.hands[1].count == 4 && small.hands[0] == cards("7h 9c"))
        guard var one = DurakState.position(rules: rules, trumpCard: card("6s"),
                                            hands: [cards("7c 7d 7h 8c"), cards("9c 8d")], attacker: 0) else {
            t.check("one-card position builds", false); return
        }
        _ = play(&one, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c")))])
        t.check("a defender with one card left faces one card at a time",
                one.remainingAttackRoom == 1 && one.legalActions(for: 0).contains(.attack(card("7d"))))
        let last = play(&one, [(0, .attack(card("7d"))), (1, .defend(card("8d"), on: card("7d")))]) ?? []
        t.check("and with none left, nothing more: bito", last.contains(where: {
            if case .bito = $0 { return true }; return false
        }))
    }

    // MARK: - Bouts

    static func bouts(_ t: TestReporter) {
        t.section("Durak: bito and take")
        let stock = cards("6s 6h 7h 8h 9h 10h Jh Qh Kh Ah 6d 7d")
        let rules3 = DurakRules(playerCount: 3)
        func threeHands() -> DurakState? {
            DurakState.position(rules: rules3, trumpCard: card("6s"),
                                hands: [cards("8c 8d 9s 10c Jc Qc"), cards("6c 7c 9c Kd Ad Qd"), cards("8s Jd 10d 9d Js Qs")],
                                stock: stock, attacker: 0)
        }
        guard var take = threeHands() else { t.check("take position builds", false); return }
        let events = play(&take, [(0, .attack(card("8c"))), (1, .take)]) ?? []
        t.check("take: the defender says so, then the attackers pile on, main attacker first",
                events.contains(.takes(seat: 1)) && take.phase == .pileOn && take.actor == 0
                    && legalSet(take, 0) == [.attack(card("8d")), .pass])
        _ = play(&take, [(0, .attack(card("8d")))])
        t.check("the main attacker is asked until it is done", take.actor == 2)
        let after = play(&take, [(2, .attack(card("8s")))]) ?? []
        t.check("everything piled on goes to the defender",
                after.contains(.took(seat: 1, cards: cards("8c 8d 8s"))) && take.hands[1].count == 9)
        t.check("take: the defender loses the turn — the player on their left attacks",
                take.attacker == 2 && take.defender == 0 && take.phase == .lead && take.actor == 2)
        t.check("everyone saw what the defender picked up", Set(take.known[1]) == Set(cards("8c 8d 8s")))

        guard var bito = threeHands() else { t.check("bito position builds", false); return }
        let bitoEvents = play(&bito, [(0, .attack(card("8c"))), (1, .defend(card("9c"), on: card("8c"))),
                                      (0, .pass), (2, .pass)]) ?? []
        t.check("bito: the cards go to the discard",
                bitoEvents.contains(.bito(cards: cards("8c 9c"))) && bito.discard.contains(card("8c")))
        t.check("bito: the defender attacks next", bito.attacker == 1 && bito.defender == 2 && bito.actor == 1)

        guard var two = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card("6s"),
                                            hands: [cards("8c 8d 9s 10c Jc Qc"), cards("6c 7c 9c Kd Ad Qd")],
                                            stock: stock, attacker: 0) else { t.check("two-player builds", false); return }
        _ = play(&two, [(0, .attack(card("8c"))), (1, .take), (0, .pass)])
        t.check("two players: after a take the attacker goes again", two.attacker == 0 && two.defender == 1)
        _ = play(&two, [(0, .attack(card("10c"))), (1, .defend(card("Ad"), on: card("10c")))])
        t.check("an ace of another suit cannot beat", two.phase == .defend)
        _ = play(&two, [(1, .take)])
        t.check("take is allowed at any point", two.phase == .pileOn || two.phase == .lead)
    }

    // MARK: - Refill

    static func refill(_ t: TestReporter) {
        t.section("Durak: refill")
        let rules3 = DurakRules(playerCount: 3)
        // Four cards left: the trump card at the bottom, then 7h, 8h, 9h on top.
        guard var state = DurakState.position(
            rules: rules3, trumpCard: card("6h"),
            hands: [cards("8c 8d 10s Jc Qc Kc"), cards("9c 9d Ks Ad As Qd"), cards("Kd 7s 8s 9s Js Qs")],
            stock: cards("6h 7h 8h 9h"), attacker: 0) else { t.check("refill position builds", false); return }
        let events = play(&state, [(0, .attack(card("8c"))), (1, .defend(card("9c"), on: card("8c"))),
                                   (0, .attack(card("8d"))), (1, .defend(card("9d"), on: card("8d"))),
                                   (2, .attack(card("8s"))), (1, .defend(card("Ks"), on: card("8s"))),
                                   (0, .pass), (2, .pass)]) ?? []
        let draws = events.compactMap { event -> (Int, [Card])? in
            if case .drew(let seat, let cards) = event { return (seat, cards) }
            return nil
        }
        t.check("draw order: the attacker, the others clockwise, the defender last",
                draws.map(\.0) == [0, 2, 1])
        t.check("the attacker draws first from the top", draws.first?.1 == cards("9h 8h"))
        t.check("the trump card under the deck is the very last card drawn",
                draws.last?.1 == cards("6h") && draws[safe: 1]?.1 == cards("7h") && state.stock.isEmpty)
        t.check("everyone saw who got the trump card", state.known[1].contains(card("6h")))
        t.check("the deck gone, the trump suit stays", state.trump == .hearts && !state.trumpCardInStock)

        // Not enough for everyone: the defender goes without.
        guard var short = DurakState.position(
            rules: DurakRules(playerCount: 2), trumpCard: card("6h"),
            hands: [cards("8c 8d 10s Jc Qc Kc"), cards("9c 9d Ks Ad As Qd")],
            stock: cards("6h 7h"), attacker: 0) else { t.check("short-deck position builds", false); return }
        let shortEvents = play(&short, [(0, .attack(card("8c"))), (1, .defend(card("9c"), on: card("8c"))),
                                        (0, .attack(card("8d"))), (1, .defend(card("9d"), on: card("8d")))]) ?? []
        t.check("when the deck runs short, the attacker's draw comes first and the defender goes without",
                shortEvents.contains(.drew(seat: 0, cards: cards("7h 6h")))
                    && !shortEvents.contains(where: { if case .drew(1, _) = $0 { return true }; return false })
                    && short.hands[1].count == 4)
    }

    // MARK: - Going out

    static func goingOut(_ t: TestReporter) {
        t.section("Durak: going out, the durak, the draw")
        let two = DurakRules(playerCount: 2)
        guard var durak = DurakState.position(rules: two, trumpCard: card("6s"),
                                              hands: [cards("7c"), cards("9c 6d")], attacker: 0) else {
            t.check("durak position builds", false); return
        }
        let e1 = play(&durak, [(0, .attack(card("7c")))]) ?? []
        t.check("a player who plays their last card with the deck gone is out at once",
                e1.contains(.playerOut(seat: 0, place: 1)) && durak.role(of: 0) == .out)
        let e2 = play(&durak, [(1, .defend(card("9c"), on: card("7c")))]) ?? []
        t.check("the last player holding cards is the durak",
                e2.last == .gameOver(.durak(1)) && durak.result == .durak(1) && durak.isOver && durak.actor == nil
                    && durak.role(of: 1) == .durak)
        guard var draw = DurakState.position(rules: two, trumpCard: card("6s"),
                                             hands: [cards("7c"), cards("9c")], attacker: 0) else {
            t.check("draw position builds", false); return
        }
        let e3 = play(&draw, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c")))]) ?? []
        t.check("both run out on the last beat: a draw",
                e3.last == .gameOver(.draw) && e3.contains(.playerOut(seat: 1, place: 2)))
        guard var took = DurakState.position(rules: two, trumpCard: card("6s"),
                                             hands: [cards("7c"), cards("6d 8d")], attacker: 0) else {
            t.check("take-out position builds", false); return
        }
        let e4 = play(&took, [(0, .attack(card("7c"))), (1, .take)]) ?? []
        t.check("a defender who has to take the last card is the durak", e4.last == .gameOver(.durak(1)))

        // Four players, the deck gone: seats 0 and 1 go out in one bout.
        let four = DurakRules(playerCount: 4)
        guard var skip = DurakState.position(rules: four, trumpCard: card("6s"),
                                             hands: [cards("7c"), cards("9c"), cards("Kd Qd"), cards("Ah 10h")],
                                             attacker: 0) else { t.check("four-player position builds", false); return }
        let e5 = play(&skip, [(0, .attack(card("7c"))), (1, .defend(card("9c"), on: card("7c")))]) ?? []
        t.check("the defender beat with their last card: bito, both out in order",
                e5.contains(.playerOut(seat: 0, place: 1)) && e5.contains(.playerOut(seat: 1, place: 2))
                    && skip.outOrder == [0, 1])
        t.check("the defender is out, so the next player on attacks, and the one after defends",
                skip.attacker == 2 && skip.defender == 3 && !skip.isOver)
        _ = play(&skip, [(2, .attack(card("Kd"))), (3, .take)])
        t.check("after a take, out players are skipped: the attack comes back round to seat 2",
                skip.attacker == 2 && skip.defender == 3 && skip.hands[3].count == 3)
        _ = play(&skip, [(2, .attack(card("Qd"))), (3, .take)])
        t.check("seat 3 is left holding cards", skip.result == .durak(3))

        guard var three = DurakState.position(rules: DurakRules(playerCount: 3), trumpCard: card("6s"),
                                              hands: [cards("7c 7d"), [], cards("9c Jd")], attacker: 2) else {
            t.check("three with one out builds", false); return
        }
        t.check("an out player is skipped when choosing the defender", three.defender == 0)
        _ = play(&three, [(2, .attack(card("9c"))), (0, .take)])
        t.check("after a take the attack passes over the out player",
                three.attacker == 2 && three.defender == 0 && three.throwInOrder.contains(1))
    }

    // MARK: - Perevodnoy

    static func transfers(_ t: TestReporter) {
        t.section("Durak: perevodnoy transfers")
        let rules = DurakRules(playerCount: 3, variant: .perevodnoy)
        guard var state = DurakState.position(
            rules: rules, trumpCard: card("6s"),
            hands: [cards("7c 7s 9h 10h Jh Qh"), cards("7d 8c Ac Kc Qc Jc"), cards("7h 9c 10c 9d 10d Jd")],
            stock: cards("6s 6h 8h"), attacker: 0) else { t.check("transfer position builds", false); return }
        _ = play(&state, [(0, .attack(card("7c")))])
        t.check("the defender may transfer with a card of the same rank",
                legalSet(state, 1).contains(.transfer(card("7d"))) && state.transferTarget == 2)
        let e = play(&state, [(1, .transfer(card("7d")))]) ?? []
        t.check("the next player defends against them all",
                e == [.transferred(seat: 1, card: card("7d"), to: 2)] && state.defender == 2 && state.attacker == 1
                    && state.actor == 2 && state.unbeatenAttacks == cards("7c 7d"))
        t.check("a transferred attack can be transferred again", legalSet(state, 2).contains(.transfer(card("7h"))))
        _ = play(&state, [(2, .transfer(card("7h")))])
        t.check("round the table, back to the first attacker", state.defender == 0 && state.attacker == 2)
        t.check("again, while the next player holds enough", legalSet(state, 0).contains(.transfer(card("7s"))))
        _ = play(&state, [(0, .defend(card("9h"), on: card("7h")))])
        t.check("once a card is beaten, no more transfers",
                state.transferTarget == nil && !legalSet(state, 0).contains(.transfer(card("7s")))
                    && (try? state.apply(.transfer(card("7s")), by: 0)) == nil)

        // Capacity: the next player must hold as many cards as the attack would.
        guard var cap = DurakState.position(
            rules: DurakRules(playerCount: 2, variant: .perevodnoy), trumpCard: card("6s"),
            hands: [cards("7c"), cards("7d 8c Ac")], attacker: 0, bout: 3) else {
            t.check("capacity position builds", false); return
        }
        _ = play(&cap, [(0, .attack(card("7c")))])
        t.check("no transfer to a player who could not face the cards",
                cap.transferTarget == nil && !legalSet(cap, 1).contains(.transfer(card("7d")))
                    && (try? cap.apply(.transfer(card("7d")), by: 1)) == nil)
        guard var back = DurakState.position(
            rules: DurakRules(playerCount: 2, variant: .perevodnoy), trumpCard: card("6s"),
            hands: [cards("7c 7h 9h"), cards("7d 8c Ac Kd")], attacker: 0, bout: 3) else {
            t.check("two-player transfer builds", false); return
        }
        _ = play(&back, [(0, .attack(card("7c")))])
        t.check("two players: the transfer goes back to the attacker", back.transferTarget == 0)
        _ = play(&back, [(1, .transfer(card("7d")))])
        t.check("who may send it back again with room", back.transferTarget == 1 && back.defender == 0)
        t.check("a different rank never transfers", (try? back.apply(.transfer(card("9h")), by: 0)) == nil)

        guard var podkidnoy = DurakState.position(
            rules: DurakRules(playerCount: 3), trumpCard: card("6s"),
            hands: [cards("7c 7s"), cards("7d 8c Ac"), cards("7h 9c 10c")], attacker: 0) else {
            t.check("podkidnoy position builds", false); return
        }
        _ = play(&podkidnoy, [(0, .attack(card("7c")))])
        t.check("podkidnoy has no transfers", podkidnoy.transferTarget == nil
                    && !podkidnoy.legalActions(for: 1).contains(where: { if case .transfer = $0 { return true }; return false }))
    }

    // MARK: - Saving

    static func saving(_ t: TestReporter) {
        t.section("Durak: saving")
        var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: 3, variant: .perevodnoy), seed: 99)
        var rng = DeterministicRNG(seed: 5)
        for _ in 0..<25 {
            let legal = state.legalActions
            guard !legal.isEmpty else { break }
            _ = try? state.apply(legal[rng.next(upperBound: legal.count)], by: state.actor ?? 0)
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(state) else { t.check("a game in progress encodes", false); return }
        let decoded = try? JSONDecoder().decode(DurakState.self, from: data)
        t.check("a game in progress survives a round trip exactly", decoded == state)
        // An older save without the bookkeeping still resumes.
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["known", "passedRanks", "doneSeats", "outOrder", "shownTrump", "actionCount"] {
                object.removeValue(forKey: key)
            }
            let trimmed = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            let restored = try? JSONDecoder().decode(DurakState.self, from: trimmed)
            t.check("a save missing its bookkeeping still loads, key by key",
                    restored?.hands == state.hands && restored?.table == state.table && restored?.isConsistent == true)
            var corrupt = object
            corrupt["discard"] = [["code": 5], ["code": 5]]
            let broken = (try? JSONSerialization.data(withJSONObject: corrupt)) ?? Data()
            t.check("a save whose cards do not add up is refused",
                    (try? JSONDecoder().decode(DurakState.self, from: broken)) == nil)
            // Damage that used to trap on the way in, or as soon as a bot
            // thought for the seat named: each must be refused, quietly.
            func refused(_ change: (inout [String: Any]) -> Void) -> Bool {
                var copy = object
                change(&copy)
                guard let data = try? JSONSerialization.data(withJSONObject: copy) else { return false }
                return (try? JSONDecoder().decode(DurakState.self, from: data)) == nil
            }
            t.check("a save with an impossible number of players is refused",
                    refused { $0["rules"] = ["playerCount": -1, "variant": "perevodnoy"] }
                        && refused { $0["rules"] = ["playerCount": 9, "variant": "perevodnoy"] })
            t.check("a save asking a seat that is not at the table is refused",
                    refused { $0["actor"] = 7 } && refused { $0["actor"] = -2 })
            t.check("a save holding something that is not a card is refused",
                    refused { o in
                        if var hands = o["hands"] as? [[Any]], !hands.isEmpty, !hands[0].isEmpty {
                            hands[0][0] = ["code": 200]
                            o["hands"] = hands
                        }
                    } && refused { $0["trumpCard"] = ["code": 77] })
            t.check("and one whose bookkeeping cannot be read back is refused",
                    refused { $0["passedRanks"] = [99999, -1, -1] } && refused { $0["actionCount"] = -5 }
                        && refused { $0["outOrder"] = [5] } && refused { $0["result"] = ["durak": ["_0": 6]] }
                        && refused { $0["hands"] = [] })
        } else {
            t.check("the save is a JSON object", false)
        }
    }

    // MARK: - Fuzz

    /// Follows the event stream the way a view would — cards from hand to
    /// table, table to hand or discard, deck to hand — and must arrive at the
    /// engine's own position after every action.
    struct EventReplay {
        var hands: [Set<Card>]
        var table: Set<Card> = []
        var discard = 0
        var stock: Int
        var ok = true
        var attacker = -1, defender = -1
        var result: DurakResult?

        init(players: Int) {
            hands = Array(repeating: [], count: players)
            stock = 36
        }

        mutating func take(_ card: Card, from seat: Int) {
            if hands[seat].remove(card) == nil { ok = false }
        }

        mutating func apply(_ event: DurakEvent) {
            switch event {
            case .dealt(let dealt, let trump):
                for (seat, cards) in dealt.enumerated() { hands[seat] = Set(cards) }
                stock = 36 - dealt.reduce(0) { $0 + $1.count }
                if dealt.flatMap({ $0 }).contains(trump) { ok = false }
            case .opening(let a, let d, _), .boutStarted(let a, let d):
                attacker = a; defender = d
                if !table.isEmpty { ok = false }
            case .attacked(let seat, let card), .threwIn(let seat, let card):
                take(card, from: seat); table.insert(card)
            case .beat(let seat, let card, let attack):
                take(card, from: seat)
                if !table.contains(attack) { ok = false }
                table.insert(card)
            case .transferred(let seat, let card, let to):
                take(card, from: seat); table.insert(card)
                attacker = seat; defender = to
            case .takes, .passed:
                break
            case .took(let seat, let cards):
                if Set(cards) != table { ok = false }
                hands[seat].formUnion(cards); table = []
            case .bito(let cards):
                if Set(cards) != table { ok = false }
                discard += cards.count; table = []
            case .drew(let seat, let cards):
                stock -= cards.count
                hands[seat].formUnion(cards)
                if stock < 0 { ok = false }
            case .playerOut(let seat, _):
                if !hands[seat].isEmpty || stock != 0 { ok = false }
            case .gameOver(let r):
                result = r
            }
        }

        func matches(_ state: DurakState) -> Bool {
            ok && hands == state.hands.map { Set($0) } && table == Set(state.tableCards)
                && discard == state.discard.count && stock == state.stockCount
                && attacker == state.attacker && defender == state.defender && result == state.result
        }
    }

    /// Everything a stray click or a confused bot might try.
    static func randomProbe(_ state: DurakState, rng: inout DeterministicRNG) -> (Int, DurakAction) {
        let seat = rng.next(upperBound: state.playerCount + 1) == 0
            ? rng.next(upperBound: state.playerCount) : (state.actor ?? 0)
        let pick = { (rng: inout DeterministicRNG) -> Card in
            // Mostly cards that matter here — the seat's own, the table's.
            let pool = state.hands[seat] + state.tableCards
            if !pool.isEmpty && rng.next(upperBound: 3) != 0 { return pool[rng.next(upperBound: pool.count)] }
            return Card.durakDeck[rng.next(upperBound: 36)]
        }
        switch rng.next(upperBound: 5) {
        case 0: return (seat, .attack(pick(&rng)))
        case 1: return (seat, .defend(pick(&rng), on: pick(&rng)))
        case 2: return (seat, .transfer(pick(&rng)))
        case 3: return (seat, .take)
        default: return (seat, .pass)
        }
    }

    static func fuzz(_ t: TestReporter, games: Int) {
        t.section("Durak: \(games) games of random legal moves")
        var rng = DeterministicRNG(seed: 0xD0_0DAC)
        var inconsistent = 0, unterminated = 0, illegalAccepted = 0, legalRefused = 0, replayMismatch = 0
        var noDecision = 0, roundTrips = 0, roundTripFailures = 0
        var actions = 0, durak = 0, draws = 0, transfers = 0, takes = 0
        let started = Date()
        for game in 0..<games {
            let n = 2 + game % 3
            let variant: DurakVariant = (game / 3) % 2 == 0 ? .podkidnoy : .perevodnoy
            let opening: DurakOpening = game % 7 == 0 ? .intoDurak(game % n) : .lowestTrump
            var (state, events) = DurakState.newGame(rules: DurakRules(playerCount: n, variant: variant),
                                                     seed: UInt64(game) &* 7919 &+ 1, opening: opening)
            var replay = EventReplay(players: n)
            events.forEach { replay.apply($0) }
            if !replay.matches(state) { replayMismatch += 1 }
            var steps = 0
            while !state.isOver {
                guard let actor = state.actor else { noDecision += 1; break }
                let legal = state.legalActions(for: actor)
                guard !legal.isEmpty else { noDecision += 1; break }
                // Probe with a few actions from anywhere; the engine must
                // accept exactly the legal ones and leave the rest untouched.
                for _ in 0..<3 {
                    let (seat, probe) = randomProbe(state, rng: &rng)
                    var copy = state
                    let accepted = (try? copy.apply(probe, by: seat)) != nil
                    let isLegal = seat == actor && legal.contains(probe)
                    if accepted && !isLegal { illegalAccepted += 1 }
                    if !accepted && isLegal { legalRefused += 1 }
                    if !accepted && copy != state { illegalAccepted += 1 }
                }
                if steps % 16 == 0 {
                    for action in legal {
                        var copy = state
                        if (try? copy.apply(action, by: actor)) == nil { legalRefused += 1 }
                    }
                }
                // Random, but take a little less often than the other options
                // so games reach their endings rather than trading pick-ups.
                var action = legal[rng.next(upperBound: legal.count)]
                if action == .take && legal.count > 1 && rng.next(upperBound: 2) == 0 {
                    action = legal[rng.next(upperBound: legal.count)]
                }
                if case .transfer = action { transfers += 1 }
                if action == .take { takes += 1 }
                guard let e = try? state.apply(action, by: actor) else { legalRefused += 1; break }
                e.forEach { replay.apply($0) }
                if !replay.matches(state) { replayMismatch += 1; break }
                if !state.isConsistent { inconsistent += 1; break }
                steps += 1
                actions += 1
                if steps > 3_000 { unterminated += 1; break }
                if game % 97 == 0 && steps % 11 == 0 {
                    roundTrips += 1
                    let data = try? JSONEncoder().encode(state)
                    if data.flatMap({ try? JSONDecoder().decode(DurakState.self, from: $0) }) != state {
                        roundTripFailures += 1
                    }
                }
            }
            switch state.result {
            case .durak?: durak += 1
            case .draw?: draws += 1
            case nil: break
            }
        }
        t.check("exactly 36 cards accounted for after every action", inconsistent == 0)
        t.check("every game terminates", unterminated == 0 && noDecision == 0 && durak + draws == games)
        t.check("no illegal action is ever accepted (and a refusal changes nothing)", illegalAccepted == 0)
        t.check("every listed legal action is accepted", legalRefused == 0)
        t.check("the event stream alone rebuilds the table, every step", replayMismatch == 0)
        t.check("positions round-trip through JSON (\(roundTrips) checked)", roundTripFailures == 0)
        t.check("the fuzz reached transfers and takes", transfers > 0 && takes > 0)
        t.info(String(format: "%d actions, %d durak, %d draws, %d transfers, in %.2f s",
                      actions, durak, draws, transfers, Date().timeIntervalSince(started)))
    }

    // MARK: - The endgame solver

    /// What makes two positions the same position, for spotting a repeat:
    /// the cards and whose move it is, not the move count or the memory.
    struct PositionKey: Hashable {
        var hands: [DurakCardSet]
        var table: DurakCardSet
        var unbeaten: DurakCardSet
        var attacker: Int, defender: Int, actor: Int
        var phase: DurakPhase
        var passed: Int

        init(_ s: DurakState) {
            hands = s.hands.map { DurakCardSet($0) }
            table = DurakCardSet(s.tableCards)
            unbeaten = DurakCardSet(s.unbeatenAttacks)
            attacker = s.attacker; defender = s.defender; actor = s.actor ?? -1
            phase = s.phase
            passed = s.actor.map { s.throwInPassMask(for: $0) } ?? -1
        }
    }

    /// Plain minimax on the engine itself, no pruning, no memory: the value of
    /// `state` for `seat` with both sides playing perfectly. A position that
    /// comes round again on the line being searched (perevodnoy can loop) is
    /// scored a draw, which gives the starting position the same value as
    /// "endless play is a draw".
    static func bruteForce(_ state: DurakState, for seat: Int, nodes: inout Int) -> Int {
        var line = Set<PositionKey>()
        return bruteForce(state, for: seat, nodes: &nodes, line: &line)
    }

    /// Brute force gives up (returning nil from `exactValue`) past this many
    /// nodes: without memory it is exponential, and a handful of loopy
    /// perevodnoy positions would otherwise take minutes.
    static let bruteForceCap = 60_000

    static func exactValue(_ state: DurakState, for seat: Int, nodes: inout Int) -> Int? {
        var used = 0
        let value = bruteForce(state, for: seat, nodes: &used)
        nodes += used
        return used > bruteForceCap ? nil : value
    }

    static func bruteForce(_ state: DurakState, for seat: Int, nodes: inout Int, line: inout Set<PositionKey>) -> Int {
        nodes += 1
        if nodes > bruteForceCap { return 0 }
        if let result = state.result {
            switch result {
            case .draw: return 0
            case .durak(let loser): return loser == seat ? -1 : 1
            }
        }
        guard let actor = state.actor else { return 0 }
        let key = PositionKey(state)
        guard line.insert(key).inserted else { return 0 }
        defer { line.remove(key) }
        let maximising = actor == seat
        var best = maximising ? -2 : 2
        for action in state.legalActions(for: actor) {
            var next = state
            guard (try? next.apply(action, by: actor)) != nil else { continue }
            let value = bruteForce(next, for: seat, nodes: &nodes, line: &line)
            best = maximising ? max(best, value) : min(best, value)
        }
        return best
    }

    static func randomEndgame(_ rng: inout DeterministicRNG, maxCards: Int) -> DurakState? {
        var deck = Card.durakDeck
        rng.shuffle(&deck)
        let players = 2 + rng.next(upperBound: 2)
        let variant: DurakVariant = rng.next(upperBound: 2) == 0 ? .podkidnoy : .perevodnoy
        let a = 1 + rng.next(upperBound: maxCards)
        let b = 1 + rng.next(upperBound: maxCards)
        // Concentrate the cards on few ranks, so throw-ins and transfers happen.
        let ranks = Set(deck.prefix(3).map(\.rank))
        var pool = deck.filter { ranks.contains($0.rank) } + deck.filter { !ranks.contains($0.rank) }
        pool = Array(pool.prefix(14))
        rng.shuffle(&pool)
        guard pool.count >= a + b else { return nil }
        var hands = [Array(pool[0..<a]), Array(pool[a..<(a + b)])]
        // With three seats, one is already out, so seat numbers are not
        // simply "me" and "the other".
        if players == 3 { hands.insert([], at: rng.next(upperBound: 3)) }
        let active = hands.indices.filter { !hands[$0].isEmpty }
        let attacker = active[rng.next(upperBound: active.count)]
        return DurakState.position(rules: DurakRules(playerCount: players, variant: variant),
                                   trumpCard: deck[35], hands: hands, attacker: attacker, bout: 1 + rng.next(upperBound: 3))
    }

    static func solver(_ t: TestReporter, positions: Int, timed timedGames: Int) {
        t.section("Durak: exact endgame solver against brute force")
        var rng = DeterministicRNG(seed: 0x50_1BE5)
        var compared = 0, disagreements = 0, moveDisagreements = 0, notSolved = 0, reconstruction = 0
        var bruteNodes = 0, solverNodes = 0, tooBig = 0
        let started = Date()
        var attempts = 0
        while compared < positions && attempts < positions * 4 {
            attempts += 1
            guard var state = randomEndgame(&rng, maxCards: attempts % 3 == 0 ? 4 : 3) else { continue }
            // Walk a few random moves in, so mid-bout positions — throw-ins,
            // pile-ons, transfers — are compared as well as leads.
            for _ in 0..<rng.next(upperBound: 4) {
                guard let actor = state.actor else { break }
                let legal = state.legalActions(for: actor)
                _ = try? state.apply(legal[rng.next(upperBound: legal.count)], by: actor)
            }
            guard !state.isOver, let actor = state.actor else { continue }
            let seat = state.activeSeats.first { $0 != actor } ?? actor
            let me = rng.next(upperBound: 2) == 0 ? actor : seat
            guard let (position, opponent) = DurakEndgameSolver.position(of: state, for: me) else {
                reconstruction += 1; continue
            }
            if DurakCardSet(bits: position.hand1) != DurakCardSet(state.hands[opponent]) { reconstruction += 1 }
            guard let exact = exactValue(state, for: me, nodes: &bruteNodes) else { tooBig += 1; continue }
            var solver = DurakEndgameSolver(trump: state.trump, transfers: state.rules.variant == .perevodnoy)
            guard let value = solver.value(of: state, for: me) else { notSolved += 1; continue }
            solverNodes += solver.nodes
            if value != exact { disagreements += 1 }
            // And move by move, for the side to act.
            if me == actor, let values = solver.evaluateMoves(in: state, for: me) {
                for (action, v) in values {
                    var next = state
                    _ = try? next.apply(action, by: me)
                    if let exact = exactValue(next, for: me, nodes: &bruteNodes), exact != v { moveDisagreements += 1 }
                }
                if Set(values.map(\.action)) != Set(state.legalActions(for: me)) { moveDisagreements += 1 }
            }
            compared += 1
        }
        t.check("\(compared) small endgames: the solver's value equals brute force", disagreements == 0 && compared > 0)
        t.check("and so does every move's value, over exactly the legal moves", moveDisagreements == 0)
        t.check("the opponent's hand is rebuilt from public information alone", reconstruction == 0)
        t.check("every small endgame solved within the budget", notSolved == 0)
        t.info(String(format: "brute force %d nodes, solver %d, %d too big for brute force, in %.2f s",
                      bruteNodes, solverNodes, tooBig, Date().timeIntervalSince(started)))

        // A full-size endgame straight after the deck runs out, for timing.
        var timed = 0, solved = 0
        var slowest = 0.0
        var seedRNG = DeterministicRNG(seed: 77)
        for game in 0..<timedGames {
            var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: 2), seed: UInt64(game) + 900)
            let bot = DurakBot(.normal)
            while !state.isOver && state.stockCount > 0, let actor = state.actor {
                _ = try? state.apply(bot.decide(in: state, seat: actor), by: actor)
            }
            guard !state.isOver, let actor = state.actor else { continue }
            _ = seedRNG.next()
            let clock = Date()
            var solver = DurakEndgameSolver(trump: state.trump, transfers: false)
            if solver.evaluateMoves(in: state, for: actor) != nil { solved += 1 }
            slowest = max(slowest, Date().timeIntervalSince(clock))
            timed += 1
        }
        t.info(String(format: "real endgames as the deck runs out: %d of %d solved outright, slowest %.0f ms",
                      solved, timed, slowest * 1000))
    }

    // MARK: - Bots

    static func bots(_ t: TestReporter, games: Int) {
        t.section("Durak: bots, \(games) games per difficulty")
        for difficulty in DurakDifficulty.allCases {
            let bot = DurakBot(difficulty)
            var fellBack = 0, refused = 0, unterminated = 0, inconsistent = 0, durak = 0, draws = 0
            var decisions = 0
            let started = Date()
            for game in 0..<games {
                let n = 2 + game % 3
                let variant: DurakVariant = (game / 3) % 2 == 0 ? .podkidnoy : .perevodnoy
                var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: n, variant: variant),
                                                    seed: UInt64(game) &* 104_729 &+ 3)
                var steps = 0
                while !state.isOver, let actor = state.actor {
                    let (action, fell) = bot.decideReporting(in: state, seat: actor)
                    if fell { fellBack += 1 }
                    decisions += 1
                    guard (try? state.apply(action, by: actor)) != nil else { refused += 1; break }
                    if !state.isConsistent { inconsistent += 1; break }
                    steps += 1
                    if steps > 2_000 { unterminated += 1; break }
                }
                if case .durak? = state.result { durak += 1 }
                if state.result == .draw { draws += 1 }
            }
            let name = difficulty.rawValue
            t.check("\(name): every decision legal, none from the fallback", refused == 0 && fellBack == 0)
            t.check("\(name): every game ends, the deck intact", unterminated == 0 && inconsistent == 0
                        && durak + draws == games)
            t.info(String(format: "%@: %d decisions, %d draws, %.0f µs a decision", name, decisions, draws,
                          Date().timeIntervalSince(started) * 1_000_000 / Double(max(decisions, 1))))
        }

        // The bots never peek: swap two cards the bot cannot see, and nothing
        // it decides may change.
        var rng = DeterministicRNG(seed: 4242)
        var compared = 0, peeked = 0, unstable = 0
        for game in 0..<60 {
            let n = 2 + game % 3
            var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: n, variant: game % 2 == 0 ? .podkidnoy : .perevodnoy),
                                                seed: UInt64(game) + 31)
            let driver = DurakBot(.normal)
            for _ in 0..<(4 + rng.next(upperBound: 30)) {
                guard let actor = state.actor else { break }
                _ = try? state.apply(driver.decide(in: state, seat: actor), by: actor)
            }
            guard let actor = state.actor else { continue }
            let hidden = Card.durakDeck.filter { card in
                !state.hands[actor].contains(card) && !state.tableCards.contains(card) && !state.discard.contains(card)
                    && !state.known.joined().contains(card) && card != state.trumpCard
            }
            guard hidden.count >= 2 else { continue }
            let a = hidden[rng.next(upperBound: hidden.count)]
            let b = hidden[rng.next(upperBound: hidden.count)]
            guard let twin = state.exchangingUnseen(a, b, from: actor) else { continue }
            for difficulty in DurakDifficulty.allCases {
                let bot = DurakBot(difficulty)
                let one = bot.decide(in: state, seat: actor)
                if bot.decide(in: state, seat: actor) != one { unstable += 1 }
                if bot.decide(in: twin, seat: actor) != one { peeked += 1 }
                compared += 1
            }
        }
        t.check("the same position always gets the same decision", unstable == 0)
        t.check("no bot's decision depends on a card it cannot see (\(compared) twins)", peeked == 0 && compared > 0)

        var delaysOK = true
        var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: 4), seed: 5)
        for _ in 0..<200 {
            guard let actor = state.actor else { break }
            let delay = DurakBot.thinkingDelay(in: state, seat: actor)
            if delay < 0.5 || delay > 1.2 { delaysOK = false }
            _ = try? state.apply(DurakBot(.easy).decide(in: state, seat: actor), by: actor)
        }
        t.check("thinking delays stay between half a second and 1.2 s", delaysOK)

        // A few positions where the right play is not in doubt.
        if let lead = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card("6h"),
                                          hands: [cards("6c 6d Ks Ah 9s Jc"), cards("7c 8d Qs Kd 10h Jd")],
                                          stock: cards("6h 7h 8h 9h Qh"), attacker: 0) {
            let choices = DurakDifficulty.allCases.map { DurakBot($0).decide(in: lead, seat: 0) }
            t.check("with the deck full, every bot leads a low plain card, not the trump ace",
                    choices.allSatisfy { $0 == .attack(card("6c")) || $0 == .attack(card("6d")) })
        }
        if var early = DurakState.position(rules: DurakRules(playerCount: 3, variant: .perevodnoy), trumpCard: card("6h"),
                                           hands: [cards("6c 7s Ks As 9s Jc"), cards("6d Qh Ah Kd 10c Jd"),
                                                   cards("8c 8d Qs Qd 10s Js")],
                                           stock: Array(cards("6h 7h 8h 9h 10h Jh Kh 7c 9c Qc Kc Ac 7d 9d 10d Ad 6s 8s")),
                                           attacker: 0) {
            _ = try? early.apply(.attack(card("6c")), by: 0)
            let normal = DurakBot(.normal).decide(in: early, seat: 1)
            t.check("offered a cheap transfer, Normal passes the six on rather than spend a trump",
                    normal == .transfer(card("6d")))
        }
        // The courtyard's endings: two players, deck gone, and one lead wins
        // where the natural cheap one loses — the defender beats it with
        // their last card and is out. Normal counts these; so does Hard.
        let endings: [(mine: String, theirs: String, trump: String, win: [String])] = [
            ("Kd Qc Ac", "10c", "6c", ["Qc"]),
            ("As 10c Qc Kc Ac", "Jc", "6c", ["Qc"]),
            ("8h Kh Qs Ks", "9s 10s", "6s", ["Kh", "Qs", "Ks"]),
        ]
        var endingsWon = 0, endingsChecked = 0
        for ending in endings {
            guard let state = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card(ending.trump),
                                                  hands: [cards(ending.mine), cards(ending.theirs)], attacker: 0)
            else { continue }
            var solver = DurakEndgameSolver(trump: state.trump, transfers: false)
            let wins = Set((solver.evaluateMoves(in: state, for: 0) ?? []).filter { $0.value == 1 }.map(\.action))
            let expected = Set(ending.win.map { DurakAction.attack(card($0)) })
            for difficulty in [DurakDifficulty.normal, .hard] {
                endingsChecked += 1
                if wins == expected && expected.contains(DurakBot(difficulty).decide(in: state, seat: 0)) { endingsWon += 1 }
            }
        }
        t.check("Normal and Hard win the classic endings: lead what the last card cannot beat (\(endingsWon) of \(endingsChecked))",
                endingsWon == endingsChecked && endingsChecked == 6)

        // Twenty takes in a row, two players, the deck still on: no loop is
        // possible, so the bots go on punishing the taker — a cheap eight is
        // piled on, not held back as if the table were stuck.
        if var piling = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card("7s"),
                                            hands: [cards("9c 10c Jc Qd 9h 10h"), cards("8c 6d 8d Js Ks As")],
                                            stock: cards("7s 6h"), attacker: 1),
           (try? piling.apply(.attack(card("8c")), by: 1)) != nil, (try? piling.apply(.take, by: 0)) != nil,
           var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(piling))) as? [String: Any] {
            object["boutsWithoutBito"] = 20
            if let data = try? JSONSerialization.data(withJSONObject: object),
               let stuck = try? JSONDecoder().decode(DurakState.self, from: data) {
                let choices = DurakDifficulty.allCases.filter { $0 != .easy }.map { DurakBot($0).decide(in: stuck, seat: 1) }
                t.check("after twenty takes with the deck still on, a taker is still piled on (\(choices))",
                        choices.allSatisfy { $0 == .attack(card("8d")) })
            } else {
                t.check("the piling position round-trips", false)
            }
        }

        // Normal never throws away a won two-player ending it can count out:
        // every decision with eight cards or fewer in play, deck gone, keeps
        // the exact value the position had.
        var counted = 0, thrownAway = 0
        let normal = DurakBot(.normal)
        for game in 0..<max(20, games) {
            let variant: DurakVariant = game % 3 == 2 ? .perevodnoy : .podkidnoy
            var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: 2, variant: variant), seed: UInt64(game) &+ 6_100)
            var steps = 0
            while !state.isOver, let actor = state.actor, steps < 2_000 {
                steps += 1
                let action = normal.decide(in: state, seat: actor)
                if state.stockCount == 0, let (root, _) = DurakEndgameSolver.position(of: state, for: actor),
                   (root.hand0 | root.hand1 | root.table).nonzeroBitCount <= 8, state.legalActions(for: actor).count > 1 {
                    var solver = DurakEndgameSolver(trump: state.trump, transfers: variant == .perevodnoy)
                    if let values = solver.evaluateMoves(in: state, for: actor), let best = values.map(\.value).max(),
                       let chosen = values.first(where: { $0.action == action })?.value {
                        counted += 1
                        if chosen < best { thrownAway += 1 }
                    }
                }
                guard (try? state.apply(action, by: actor)) != nil else { break }
            }
        }
        t.check("Normal keeps every small two-player ending's value (\(thrownAway) of \(counted) decisions lost some)",
                thrownAway == 0 && counted > 0)

        if var take = DurakState.position(rules: DurakRules(playerCount: 2), trumpCard: card("6h"),
                                          hands: [cards("7c 7d 8s 9s 10s Js"), cards("Qh Ah Kh 6s 6d Jd")],
                                          stock: Array(cards("6h 7h 8h 9h 10h Jh 6c 8c 9c 10c Jc Qc Kc Ac 8d 9d 10d Qd")),
                                          attacker: 0) {
            _ = try? take.apply(.attack(card("7c")), by: 0)
            let normal = DurakBot(.normal).decide(in: take, seat: 1)
            t.check("early on, a seven of clubs is taken rather than beaten with the queen of trumps",
                    normal == .take)
        }
    }

    // MARK: - Head to head

    static func headToHead(_ t: TestReporter, games: Int, allPairings: Bool) {
        t.section("Durak: head to head, \(games) two-player games a pairing")
        func match(_ a: DurakDifficulty, _ b: DurakDifficulty, variant: DurakVariant, seedBase: UInt64)
            -> (aDurak: Int, bDurak: Int, draws: Int) {
            var aDurak = 0, bDurak = 0, draws = 0
            var previous: DurakResult?
            for game in 0..<games {
                // Swap seats every game so neither bot always opens.
                let aSeat = game % 2
                let bots = aSeat == 0 ? [DurakBot(a), DurakBot(b)] : [DurakBot(b), DurakBot(a)]
                let opening = DurakOpening.following(previous, playerCount: 2)
                var (state, _) = DurakState.newGame(rules: DurakRules(playerCount: 2, variant: variant),
                                                    seed: seedBase &+ UInt64(game / 2), opening: game % 2 == 0 ? .lowestTrump : opening)
                var steps = 0
                while !state.isOver, let actor = state.actor, steps < 2_000 {
                    _ = try? state.apply(bots[actor].decide(in: state, seat: actor), by: actor)
                    steps += 1
                }
                previous = state.result
                switch state.result {
                case .durak(let loser)?: if loser == aSeat { aDurak += 1 } else { bDurak += 1 }
                case .draw?: draws += 1
                case nil: break
                }
            }
            return (aDurak, bDurak, draws)
        }
        func rate(_ x: Int) -> Double { Double(x) * 100 / Double(max(games, 1)) }
        let started = Date()
        let hardEasy = match(.hard, .easy, variant: .podkidnoy, seedBase: 10_000)
        t.info(String(format: "podkidnoy  Hard vs Easy:   Hard durak %.1f%%, Easy durak %.1f%%, draws %.1f%%",
                      rate(hardEasy.aDurak), rate(hardEasy.bDurak), rate(hardEasy.draws)))
        t.check("Hard beats Easy clearly (podkidnoy): Easy is the durak far more often",
                rate(hardEasy.bDurak) >= rate(hardEasy.aDurak) + 15)
        if allPairings {
            let hardEasyP = match(.hard, .easy, variant: .perevodnoy, seedBase: 20_000)
            t.info(String(format: "perevodnoy Hard vs Easy:   Hard durak %.1f%%, Easy durak %.1f%%, draws %.1f%%",
                          rate(hardEasyP.aDurak), rate(hardEasyP.bDurak), rate(hardEasyP.draws)))
            let normalEasy = match(.normal, .easy, variant: .podkidnoy, seedBase: 30_000)
            t.info(String(format: "podkidnoy  Normal vs Easy: Normal durak %.1f%%, Easy durak %.1f%%, draws %.1f%%",
                          rate(normalEasy.aDurak), rate(normalEasy.bDurak), rate(normalEasy.draws)))
            let hardNormal = match(.hard, .normal, variant: .podkidnoy, seedBase: 40_000)
            t.info(String(format: "podkidnoy  Hard vs Normal: Hard durak %.1f%%, Normal durak %.1f%%, draws %.1f%%",
                          rate(hardNormal.aDurak), rate(hardNormal.bDurak), rate(hardNormal.draws)))
            t.check("Hard beats Easy clearly (perevodnoy)", rate(hardEasyP.bDurak) >= rate(hardEasyP.aDurak) + 15)
            t.check("Normal beats Easy", normalEasy.bDurak > normalEasy.aDurak)
            t.check("Hard beats Normal", hardNormal.aDurak < hardNormal.bDurak)
        }
        t.info(String(format: "head to head in %.2f s", Date().timeIntervalSince(started)))
    }
}
