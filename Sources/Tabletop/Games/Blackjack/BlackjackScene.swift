//
//  BlackjackScene.swift
//  What the table shows for a given state of the engine: every card and
//  which way up, every stack of chips and how much is in it, every label.
//
//  Pure and derived — the engine is the truth, this is its picture — so the
//  table view never has to know a rule. It compares the scene it is given
//  with the one it last showed and animates the difference: a card that is
//  new comes out of the shoe, one that has gone is swept to the tray, a stack
//  that grew was pushed out from the player's chips (or, for a payout, from
//  the dealer's rack), a stack that shrank went back where the scene says —
//  to the house if it was lost, to the player if not.
//

import AppKit

struct BlackjackScene: Equatable {

    struct Placed: Equatable {
        let card: BlackjackCard
        var faceUp: Bool
        /// A double-down card, laid crosswise the way a dealer marks it.
        var sideways = false
    }

    struct Hand: Equatable {
        var cards: [Placed]
        var label: String?
        var tone: Banner.Tone = .neutral
        /// The hand the player is on, when there is more than one.
        var isActive = false
    }

    /// A stack of chips on the cloth.
    enum Stack: Hashable {
        /// A hand's bet — hand 0's is also the bet being built before the deal.
        case bet(Int)
        /// A hand's winnings, set beside its bet.
        case payout(Int)
        case insurance
        case insurancePayout
    }

    struct StackAmount: Equatable {
        var amount: Int
        /// Chips leaving this stack go to the dealer's rack, not the player.
        var lost = false
    }

    var dealer: [Placed] = []
    var dealerLabel: String?
    var dealerTone: Banner.Tone = .neutral
    var hands: [Hand] = []
    var stacks: [Stack: StackAmount] = [:]
    var shoeRemaining: Double = 1
    var cutFraction: Double = 0.25
    var isCutCardOut = false
    var discardCount = 0
    var shoeSize = 312

    init() {}

    init(engine: BlackjackEngine) {
        let shoe = engine.shoe
        shoeRemaining = shoe.remainingFraction
        cutFraction = shoe.cutFraction
        isCutCardOut = shoe.isCutCardOut
        discardCount = shoe.discard.count
        shoeSize = shoe.size
        guard let round = engine.round else {
            stacks[.bet(0)] = StackAmount(amount: engine.pendingBet)
            return
        }

        // The dealer: the hole card face down until it is turned.
        dealer = round.dealer.enumerated().map { Placed(card: $1, faceUp: $0 != 1 || round.isHoleRevealed) }
        if !round.dealer.isEmpty {
            let visible = round.isHoleRevealed ? round.dealer : [round.dealer[0]]
            let total = BlackjackTotal(visible)
            if round.isHoleRevealed && round.dealerHasBlackjack {
                dealerLabel = NSLocalizedString("Blackjack", comment: "blackjack hand label: a natural")
                dealerTone = .loss
            } else if total.isBust {
                dealerLabel = NSLocalizedString("Bust", comment: "blackjack hand label: over 21")
                dealerTone = .win
            } else {
                dealerLabel = Self.totalText(total)
            }
        }

        let several = round.hands.count > 1
        for (i, hand) in round.hands.enumerated() {
            var placed = hand.cards.map { Placed(card: $0, faceUp: true) }
            if hand.isDoubled, !placed.isEmpty { placed[placed.count - 1].sideways = true }
            var shown = Hand(cards: placed)
            shown.isActive = several && round.phase == .playerTurn && i == round.active
            (shown.label, shown.tone) = Self.label(for: hand, dealt: hand.cards.count >= 2)

            // Chips: the bet while it rides; after settling, what is left of
            // it and the winnings beside it until the player collects.
            if let result = hand.result {
                switch result {
                case .win, .evenMoney:
                    stacks[.bet(i)] = StackAmount(amount: hand.bet)
                    stacks[.payout(i)] = StackAmount(amount: hand.returned - hand.bet)
                case .blackjack:
                    stacks[.bet(i)] = StackAmount(amount: hand.bet)
                    stacks[.payout(i)] = StackAmount(amount: hand.returned - hand.bet)
                case .push:
                    stacks[.bet(i)] = StackAmount(amount: hand.bet)
                case .surrender:
                    stacks[.bet(i)] = StackAmount(amount: hand.returned, lost: true)
                case .lose, .bust:
                    stacks[.bet(i)] = StackAmount(amount: 0, lost: true)
                }
            } else if hand.isBust {
                // A busted bet is taken at once, as a dealer does.
                stacks[.bet(i)] = StackAmount(amount: 0, lost: true)
            } else {
                stacks[.bet(i)] = StackAmount(amount: hand.bet)
            }
            hands.append(shown)
        }

        if round.insurance > 0 {
            switch round.insuranceReturned {
            case nil:
                stacks[.insurance] = StackAmount(amount: round.insurance)
            case .some(0):
                stacks[.insurance] = StackAmount(amount: 0, lost: true)
            case .some(let returned):
                stacks[.insurance] = StackAmount(amount: round.insurance)
                stacks[.insurancePayout] = StackAmount(amount: returned - round.insurance)
            }
        }
    }

    /// What's in the circles, all told.
    var chipsOnCloth: Int { stacks.values.reduce(0) { $0 + $1.amount } }

    // MARK: Words

    /// "17", "Soft 17".
    static func totalText(_ total: BlackjackTotal) -> String {
        if total.isSoft && total.total < 21 {
            return String(format: NSLocalizedString("Soft %d", comment: "blackjack hand total with an ace counting 11"),
                          total.total)
        }
        return String(total.total)
    }

    /// A hand's capsule: its total while it is played, its result after.
    static func label(for hand: BlackjackHand, dealt: Bool) -> (String?, Banner.Tone) {
        guard !hand.cards.isEmpty else { return (nil, .neutral) }
        if let result = hand.result {
            let net = hand.returned - hand.bet
            switch result {
            case .blackjack:
                return (String(format: NSLocalizedString("Blackjack %@", comment: "blackjack result: a natural, e.g. Blackjack +75"),
                               Chips.formatChange(net)), .win)
            case .evenMoney:
                return (String(format: NSLocalizedString("Even Money %@", comment: "blackjack result, e.g. Even Money +50"),
                               Chips.formatChange(net)), .win)
            case .win:
                return (String(format: NSLocalizedString("Win %@", comment: "blackjack result, e.g. Win +50"),
                               Chips.formatChange(net)), .win)
            case .push:
                return (NSLocalizedString("Push", comment: "blackjack result: a tie"), .neutral)
            case .lose:
                return (NSLocalizedString("Lose", comment: "blackjack result"), .loss)
            case .bust:
                return (NSLocalizedString("Bust", comment: "blackjack hand label: over 21"), .loss)
            case .surrender:
                return (String(format: NSLocalizedString("Surrender %@", comment: "blackjack result, e.g. Surrender −25"),
                               Chips.formatChange(net)), .loss)
            }
        }
        if hand.isSurrendered {
            return (NSLocalizedString("Surrendered", comment: "blackjack hand label"), .neutral)
        }
        if hand.isBlackjack { return (NSLocalizedString("Blackjack", comment: "blackjack hand label: a natural"), .win) }
        if hand.isBust { return (NSLocalizedString("Bust", comment: "blackjack hand label: over 21"), .loss) }
        guard dealt else { return (nil, .neutral) }
        return (totalText(hand.total), .neutral)
    }
}
