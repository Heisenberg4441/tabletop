//
//  PokerTypes.swift
//  The vocabulary of a hold'em table: streets, modes, blinds, actions, pots,
//  and the events the table reports as it plays.
//
//  All value types, all `Sendable`, so a copy of the whole table can go to a
//  background thread for a bot to think about while the real one stays on
//  the main thread.
//

import Foundation

// MARK: - Streets and phases

/// The four betting rounds, and the showdown after them.
enum PokerStreet: Int, Codable, Sendable, Comparable, CaseIterable {
    case preflop = 0, flop, turn, river, showdown

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Community cards on the table once this street has been dealt.
    var boardCount: Int {
        switch self {
        case .preflop: return 0
        case .flop: return 3
        case .turn: return 4
        case .river, .showdown: return 5
        }
    }

    var localizedName: String {
        switch self {
        case .preflop: return NSLocalizedString("Preflop", comment: "poker street")
        case .flop: return NSLocalizedString("Flop", comment: "poker street")
        case .turn: return NSLocalizedString("Turn", comment: "poker street")
        case .river: return NSLocalizedString("River", comment: "poker street")
        case .showdown: return NSLocalizedString("Showdown", comment: "poker street")
        }
    }
}

/// What the table is waiting for. The UI's loop is a switch on this.
enum PokerPhase: String, Codable, Sendable {
    /// No hand in progress: before the first hand, or after the last one was
    /// paid. Call `startHand()`. The only phase that is saved to disk.
    case betweenHands
    /// `toAct` must act: `apply(_:)` with one of `options()`'s actions.
    case betting
    /// The betting round is over (or everyone but one folded, or nobody can
    /// bet any more): call `advance()` to gather the bets and deal on — or
    /// to pay the pots.
    case streetComplete
    /// The tournament is decided: one player holds every chip. (A cash
    /// table never gets here; busted players buy back in.)
    case gameOver
}

// MARK: - Configuration

enum PokerMode: String, Codable, Sendable, CaseIterable {
    /// Sit & Go: 1,500 each, blinds up every eight hands, last one standing.
    case tournament
    /// Blinds 5/10 for ever, 1,000 to sit down, top up between hands, bots
    /// rebuy when they bust.
    case cash

    var localizedName: String {
        switch self {
        case .tournament: return NSLocalizedString("Tournament", comment: "poker mode")
        case .cash: return NSLocalizedString("Cash Game", comment: "poker mode")
        }
    }
}

/// How long the bots take over a decision: the thinking ring's time.
enum PokerSpeed: String, Codable, Sendable, CaseIterable {
    case normal, fast

    var localizedName: String {
        switch self {
        case .normal: return NSLocalizedString("Normal", comment: "poker bot speed")
        case .fast: return NSLocalizedString("Fast", comment: "poker bot speed")
        }
    }

    /// The pause for a decision of `deliberation` (0…1, from
    /// `PokerBotDecision`): 0.6–1.8 s, or 0.25–0.6 s when fast. Easy folds
    /// come quickly, a call for the stack takes its time.
    func thinkingTime(deliberation: Double) -> Double {
        let d = max(0, min(1, deliberation))
        switch self {
        case .normal: return 0.6 + 1.2 * d
        case .fast: return 0.25 + 0.35 * d
        }
    }
}

enum PokerDifficulty: String, Codable, Sendable, CaseIterable {
    case casual, standard, sharp

    var localizedName: String {
        switch self {
        case .casual: return NSLocalizedString("Casual", comment: "poker difficulty")
        case .standard: return NSLocalizedString("Standard", comment: "poker difficulty")
        case .sharp: return NSLocalizedString("Sharp", comment: "poker difficulty")
        }
    }
}

/// How a computer player likes to play. Assigned per seat, deterministically
/// from the table's seed, so the same table always has the same characters.
enum PokerPersonality: String, Codable, Sendable, CaseIterable {
    /// Few hands, played hard. The textbook regular.
    case tightAggressive
    /// Many hands, lots of pressure, the most bluffs.
    case looseAggressive
    /// Few hands, rarely raises without the goods. Bets mean something.
    case tightPassive
    /// Likes to see the next card; calls too much, but not everything.
    case callingStation

    var localizedName: String {
        switch self {
        case .tightAggressive: return NSLocalizedString("Tight-aggressive", comment: "poker bot personality")
        case .looseAggressive: return NSLocalizedString("Loose-aggressive", comment: "poker bot personality")
        case .tightPassive: return NSLocalizedString("Tight-passive", comment: "poker bot personality")
        case .callingStation: return NSLocalizedString("Calling station", comment: "poker bot personality")
        }
    }
}

struct PokerBlindLevel: Codable, Hashable, Sendable {
    var smallBlind: Int
    var bigBlind: Int

    init(_ smallBlind: Int, _ bigBlind: Int) {
        self.smallBlind = smallBlind
        self.bigBlind = bigBlind
    }
}

/// The New Game card's choices, plus the numbers the modes are made of.
struct PokerTableConfig: Codable, Hashable, Sendable {
    var mode: PokerMode = .tournament
    /// Computer players: 1…5 beside the human, 2…6 at an all-bot table.
    var opponents: Int = 5
    var difficulty: PokerDifficulty = .standard
    /// The player's choice of pace. The engine does not use it; it is here
    /// so the whole setup saves and restores as one value.
    var speed: PokerSpeed = .normal
    /// False only for tests and simulations: every seat is a bot.
    var includesHuman: Bool = true

    static let tournamentStack = 1_500
    static let cashStack = 1_000
    static let cashBlinds = PokerBlindLevel(5, 10)
    static let handsPerLevel = 8
    static let tournamentLevels: [PokerBlindLevel] = [
        PokerBlindLevel(10, 20), PokerBlindLevel(15, 30), PokerBlindLevel(25, 50), PokerBlindLevel(50, 100),
        PokerBlindLevel(75, 150), PokerBlindLevel(100, 200), PokerBlindLevel(150, 300), PokerBlindLevel(200, 400),
        PokerBlindLevel(300, 600), PokerBlindLevel(400, 800), PokerBlindLevel(600, 1_200), PokerBlindLevel(1_000, 2_000),
    ]

    /// Everyone's stack when they sit down.
    var startingStack: Int { mode == .tournament ? Self.tournamentStack : Self.cashStack }

    /// Seats at the table, the player's included: two to six.
    var playerCount: Int {
        includesHuman ? Self.clampedOpponents(opponents, includesHuman: true) + 1
            : Self.clampedOpponents(opponents, includesHuman: false)
    }

    static func clampedOpponents(_ n: Int, includesHuman: Bool) -> Int {
        includesHuman ? max(1, min(5, n)) : max(2, min(6, n))
    }

    init(mode: PokerMode = .tournament, opponents: Int = 5, difficulty: PokerDifficulty = .standard,
         speed: PokerSpeed = .normal, includesHuman: Bool = true) {
        self.mode = mode
        self.opponents = opponents
        self.difficulty = difficulty
        self.speed = speed
        self.includesHuman = includesHuman
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.pokerDecode(.mode, .tournament)
        difficulty = c.pokerDecode(.difficulty, .standard)
        speed = c.pokerDecode(.speed, .normal)
        includesHuman = c.pokerDecode(.includesHuman, true)
        opponents = Self.clampedOpponents(c.pokerDecode(.opponents, 5), includesHuman: includesHuman)
    }
}

// MARK: - Actions

/// What a player does when it is their turn. Amounts are the player's TOTAL
/// bet on this street after the action ("raise to 180"), not the chips added —
/// which is what the bet slider shows and what makes min-raise arithmetic
/// read like the rulebook.
enum PokerAction: Hashable, Codable, Sendable {
    case fold
    case check
    /// Match the current bet, or put in everything if that is less.
    case call
    /// Open the betting on a street where nobody has bet: `bet(to:)`.
    case bet(Int)
    /// Raise a bet: `raise(to:)`.
    case raise(Int)
    /// Everything. A call, a bet or a raise depending on the stack; always
    /// legal when it is a call, legal as a bet/raise when raising is.
    case allIn
}

/// One thing a player did, as the table records it — including posting a
/// blind, which is not a choice but moves chips all the same.
struct PokerActionRecord: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case smallBlind, bigBlind, fold, check, call, bet, raise
    }

    let seat: Int
    let street: PokerStreet
    let kind: Kind
    /// The player's total bet on the street afterwards ("Raise 120", "Call 60").
    let total: Int
    /// Chips that moved from the stack into the bet with this action.
    let added: Int
    /// The action put the player's last chip in.
    let isAllIn: Bool
    /// A bet or raise of at least the minimum, which reopens the betting.
    /// False for a short all-in raise.
    let isFullRaise: Bool

    /// True for anything that put chips in beyond matching: a bet or a raise.
    var isAggressive: Bool { kind == .bet || kind == .raise }

    /// The seat's caption for a moment after acting: "Raise 120", "Call 60",
    /// "Check", "All-in". Calm words, no exclamation marks.
    var caption: String {
        if isAllIn && kind != .fold {
            return NSLocalizedString("All-in", comment: "poker action caption")
        }
        switch kind {
        case .smallBlind:
            return String(format: NSLocalizedString("Small blind %@", comment: "poker caption: posted the small blind"),
                          Chips.format(total))
        case .bigBlind:
            return String(format: NSLocalizedString("Big blind %@", comment: "poker caption: posted the big blind"),
                          Chips.format(total))
        case .fold: return NSLocalizedString("Fold", comment: "poker action caption")
        case .check: return NSLocalizedString("Check", comment: "poker action caption")
        case .call:
            return String(format: NSLocalizedString("Call %@", comment: "poker caption: called, e.g. Call 60"),
                          Chips.format(added))
        case .bet:
            return String(format: NSLocalizedString("Bet %@", comment: "poker caption: bet, e.g. Bet 40"),
                          Chips.format(total))
        case .raise:
            return String(format: NSLocalizedString("Raise %@", comment: "poker caption: raised to, e.g. Raise 120"),
                          Chips.format(total))
        }
    }
}

/// Everything the player to act may do, and the numbers the controls need.
struct PokerActionOptions: Hashable, Sendable {
    let seat: Int
    /// Folding is always allowed on your turn, even when checking is free —
    /// the UI may prefer to hide it then.
    let canFold: Bool
    let canCheck: Bool
    let canCall: Bool
    /// Chips a call adds — capped at the stack, in which case the call is an
    /// all-in (`callIsAllIn`).
    let callAmount: Int
    let callIsAllIn: Bool
    /// Nobody has bet this street: the aggressive action is a bet.
    let canBet: Bool
    /// Somebody has bet and you may raise it. False when a short all-in did
    /// not reopen the betting to you, when you cannot cover more than a call,
    /// or when nobody is left who could call a raise.
    let canRaise: Bool
    /// The smallest legal bet/raise total. Equal to `maxTotal` when the only
    /// raise left is all-in for less than a full raise.
    let minTotal: Int
    /// All-in: the player's bet so far plus the whole stack.
    let maxTotal: Int
    /// The bet to match on this street, and what the player has in already.
    let currentBet: Int
    let playerBet: Int
    let stack: Int
    /// Every chip in the middle: pots gathered on earlier streets plus every
    /// bet in front of every player now. The base for "½ Pot".
    let pot: Int

    var canBetOrRaise: Bool { canBet || canRaise }

    /// A bet or raise total of `fraction` of the pot, the usual way: a
    /// pot-sized raise is a call plus the pot after that call. Clamped to
    /// what is legal.
    func potFractionTotal(_ fraction: Double) -> Int {
        let toCall = currentBet - playerBet
        let raw = Double(currentBet) + fraction * Double(pot + max(0, toCall))
        return clampTotal(Int(raw.rounded()))
    }

    /// `total` pulled into the legal range.
    func clampTotal(_ total: Int) -> Int {
        max(minTotal, min(maxTotal, total))
    }

    /// The legal action that bets or raises to `total` (clamped): `.allIn`
    /// at the top of the range. Falls back to check or call when neither a
    /// bet nor a raise is allowed.
    func aggressiveAction(to total: Int) -> PokerAction {
        guard canBetOrRaise else { return canCheck ? .check : .call }
        let t = clampTotal(total)
        if t >= maxTotal { return .allIn }
        return canBet ? .bet(t) : .raise(t)
    }

    /// Check if that is free, else call.
    var passiveAction: PokerAction { canCheck ? .check : .call }
}

// MARK: - Pots and results

/// Chips in the middle that a particular set of players can win. The first
/// pot is the main pot; each all-in for less makes the next one a side pot.
struct PokerPot: Hashable, Codable, Sendable {
    var amount: Int
    /// Seats that can win it, in seat order.
    var eligible: [Int]
}

/// One player's share of one pot.
struct PokerPotShare: Hashable, Codable, Sendable {
    let seat: Int
    let amount: Int
}

/// A pot paid out.
struct PokerPotAward: Hashable, Codable, Sendable {
    /// 0 is the main pot, then the side pots in order.
    let potIndex: Int
    let amount: Int
    /// The winners' shares. An odd chip of a split goes to the first winner
    /// left of the button, so shares can differ by one.
    let shares: [PokerPotShare]
    /// The winning hand, or nil when everybody else folded (nothing shown).
    let hand: PokerHandResult?

    var winners: [Int] { shares.map(\.seat) }
    var isUncontested: Bool { hand == nil }
}

/// A hand turned face up at the showdown (or before an all-in runout).
struct PokerShownHand: Hashable, Codable, Sendable {
    let seat: Int
    let holeCards: [Card]
    /// Best hand with the final board; nil before the board is complete.
    let result: PokerHandResult?
}

/// How a hand ended, for the banner, the stats and the log.
struct PokerHandSummary: Hashable, Codable, Sendable {
    let handNumber: Int
    let board: [Card]
    let awards: [PokerPotAward]
    /// Hands shown at the showdown; empty when the hand ended in folds.
    let shown: [PokerShownHand]
    /// Every seat's change in chips over the hand (index = seat).
    let netChange: [Int]
    /// Every chip paid out this hand, all pots together.
    var totalPot: Int { awards.reduce(0) { $0 + $1.amount } }

    /// What each seat won in total across the pots (seat → chips).
    var winnings: [Int: Int] {
        var result: [Int: Int] = [:]
        for award in awards { for share in award.shares { result[share.seat, default: 0] += share.amount } }
        return result
    }

    /// The seat that took the most, the first of them left of the button
    /// when two took the same (the awards are already in that order).
    var biggestWinner: Int? {
        let won = winnings
        var best: Int?
        for award in awards {
            for share in award.shares where best == nil || (won[share.seat] ?? 0) > (won[best ?? 0] ?? 0) {
                best = share.seat
            }
        }
        return best
    }

    /// The banner's two lines: "Maria wins 1,240" (or "You win 1,240", or
    /// "Maria and Hiro split 1,240") and the hand that did it, "Flush, Ace
    /// high" — empty when everybody else folded. `names` is indexed by seat;
    /// `humanSeat` gets the second-person sentence.
    func headline(names: [String], humanSeat: Int?) -> (title: String, subtitle: String) {
        guard let winner = biggestWinner else { return ("", "") }
        let won = winnings
        let amount = Chips.format(won[winner] ?? 0)
        // A split of the pot the winner took is a split; side pots going
        // different ways are not — the banner names the one who took most.
        let mainShare = awards.first { $0.winners.contains(winner) }
        let hand = mainShare?.hand?.localizedDescription ?? ""
        if let split = mainShare, split.shares.count == 2 {
            let a = names[safe: split.shares[0].seat] ?? "", b = names[safe: split.shares[1].seat] ?? ""
            let total = Chips.format(split.amount)
            if split.shares[0].seat == humanSeat || split.shares[1].seat == humanSeat {
                let other = split.shares[0].seat == humanSeat ? b : a
                return (String(format: NSLocalizedString("You and %@ split %@", comment: "poker banner: a split pot with the player"),
                               other, total), hand)
            }
            return (String(format: NSLocalizedString("%@ and %@ split %@", comment: "poker banner: two players split a pot"),
                           a, b, total), hand)
        }
        if let split = mainShare, split.shares.count > 2 {
            return (String(format: NSLocalizedString("Split pot of %@", comment: "poker banner: a pot split three or more ways"),
                           Chips.format(split.amount)), hand)
        }
        if winner == humanSeat {
            return (String(format: NSLocalizedString("You win %@", comment: "poker banner: the player wins chips"), amount), hand)
        }
        return (String(format: NSLocalizedString("%@ wins %@", comment: "poker banner: a player wins chips, e.g. Maria wins 1,240"),
                       names[safe: winner] ?? "", amount), hand)
    }
}

// MARK: - Events

/// What just happened, in order, for the UI to animate. Every mutating call
/// on `PokerTable` returns the events it caused; the table's state afterwards
/// is already final, so a UI that skips the animation just renders it.
enum PokerEvent: Hashable, Sendable {
    /// Tournament: a new level begins with this hand.
    case blindsRaised(level: Int, blinds: PokerBlindLevel)
    /// Cash: a busted player bought back in (bots) or topped up.
    case rebought(seat: Int, amount: Int)
    /// The button has moved; blinds are about to be posted.
    case handStarted(number: Int, button: Int)
    /// A blind posted or an action taken: chips from the stack to the bet.
    case acted(PokerActionRecord)
    /// Hole cards, two rounds of one card each, in this seat order.
    case dealtHoleCards(order: [Int])
    /// The street's betting is over; nothing moves yet. Emitted once per
    /// street, when the last needed action lands.
    case bettingRoundEnded(street: PokerStreet)
    /// The part of a bet nobody matched goes back to its owner's stack.
    case uncalledBetReturned(seat: Int, amount: Int)
    /// Every bet slides into the middle; `pots` is the result, main pot first.
    case betsCollected(pots: [PokerPot])
    /// Nobody can bet any more (all-in): these seats turn their cards up now,
    /// before the rest of the board is dealt.
    case handsRevealed([PokerShownHand])
    case dealtCommunity(street: PokerStreet, cards: [Card])
    /// The river is done: these hands are shown, best hands worked out.
    case showdown([PokerShownHand])
    case potAwarded(PokerPotAward)
    case handEnded(PokerHandSummary)
    /// Tournament: out of chips, finishing in `place` (1 = winner).
    case eliminated(seat: Int, place: Int)
    case tournamentEnded(winner: Int)
}

enum PokerEngineError: Error, Equatable {
    /// `apply` outside `.betting`.
    case notBetting
    /// The action is not in `options()` for the player to act.
    case illegalAction(PokerAction)
}

// MARK: - Tolerant decoding

extension KeyedDecodingContainer {

    /// The value under `key`, or `fallback` if it is missing or unreadable —
    /// so a save from an older build (or a hand-edited file) loses one field,
    /// never the whole table.
    func pokerDecode<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
