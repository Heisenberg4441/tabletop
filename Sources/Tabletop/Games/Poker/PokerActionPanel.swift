//
//  PokerActionPanel.swift
//  The player's controls in the action bar: what they may do, sized for the
//  moment.
//
//      your turn         [ Min ½ Pot ¾ Pot Pot All-in ]  Fold · Call 60 · Raise to 180
//                        [ ━━━━━●──────────  180 ]
//      someone else's    Check/Fold (ticked in advance)
//      between hands     Top Up · Deal Next Hand
//
//  Same ids in the same order update in place, so "Call 40" becoming "Call
//  120" moves no buttons; a different set crossfades. The bar is sized for the
//  bet control whether it shows or not, so the table never jumps.
//
//  Keys: F folds, C checks or calls, Return confirms the bet (or deals the
//  next hand), R puts the keyboard on the bet slider, ← and → move the
//  amount by a chip (⇧ by ten) without it, and Escape puts the amount back
//  and the keyboard back on the table.
//

import AppKit

@MainActor
final class PokerActionPanel {

    let bar: ActionBar
    let bet = BetControl(minimum: 1, maximum: 2, step: 1)
    weak var flow: PokerFlow?
    /// The player's choices, for the game to carry out.
    var onAction: ((PokerAction) -> Void)?
    var onDeal: (() -> Void)?
    var onTopUp: (() -> Void)?

    /// What the bar is showing, for tests.
    private(set) var mode: Mode = .hidden
    enum Mode: Equatable { case hidden, turn, waiting, betweenHands }

    private var options: PokerActionOptions?
    private var defaultAmount = 0
    private var isVisible = false
    /// Stood down while the New Game card or a banner is asking the player
    /// something else.
    var isSuppressed = false {
        didSet { if isSuppressed != oldValue { update(animated: true) } }
    }

    init(bar: ActionBar) {
        self.bar = bar
        bet.isHidden = true
        bar.leadingAccessory = bet
        bet.onChange = { [weak self] _ in self?.refreshAggressiveTitle() }
        bar.isHidden = true
    }

    // MARK: Updating

    func update(animated: Bool) {
        guard let flow, !isSuppressed else { return setMode(.hidden, actions: [], animated: animated) }
        let table = flow.table
        switch flow.stage {
        case .humanTurn:
            guard let o = table.options() else { return setMode(.hidden, actions: [], animated: animated) }
            showTurn(o, table: table, animated: animated)
        case .playing, .botThinking:
            // Still in the hand with chips behind: the box to tick in advance.
            if let seat = table.humanSeat, table.players[seat].canAct, table.phase == .betting || table.phase == .streetComplete,
               !flow.autopilot {
                let armed = flow.preAction == .checkFold
                let toggle = ChromeAction(id: "checkFold",
                                          title: NSLocalizedString("Check/Fold", comment: "poker pre-action: check if free, else fold"),
                                          symbolName: armed ? "checkmark" : nil, style: armed ? .primary : .secondary,
                                          accessibilityLabel: armed
                                              ? NSLocalizedString("Check or fold when your turn comes, on", comment: "accessibility")
                                              : NSLocalizedString("Check or fold when your turn comes, off", comment: "accessibility")) { [weak self] in
                    guard let flow = self?.flow else { return }
                    flow.preAction = flow.preAction == .checkFold ? nil : .checkFold
                }
                setMode(.waiting, actions: [toggle], animated: animated)
            } else {
                setMode(.hidden, actions: [], animated: animated)
            }
        case .betweenHands:
            var actions: [ChromeAction] = []
            if flow.canTopUp {
                actions.append(ChromeAction(id: "topUp",
                                            title: String(format: NSLocalizedString("Top Up to %@", comment: "poker: buy back up to a full cash stack"),
                                                          Chips.format(PokerTableConfig.cashStack)),
                                            symbolName: "plus.circle") { [weak self] in self?.onTopUp?() })
            }
            actions.append(ChromeAction(id: "deal", title: NSLocalizedString("Deal Next Hand", comment: "poker: deal the next hand now"),
                                        style: .primary, keyEquivalent: "\r") { [weak self] in self?.onDeal?() })
            setMode(.betweenHands, actions: actions, animated: animated)
        case .idle, .finished:
            setMode(.hidden, actions: [], animated: animated)
        }
    }

    private func showTurn(_ o: PokerActionOptions, table: PokerTable, animated: Bool) {
        options = o
        let unit = max(1, table.chipUnit)
        let canSize = o.canBetOrRaise && o.maxTotal > o.minTotal
        if canSize {
            let fresh = bet.isHidden || bet.minimum != o.minTotal || bet.maximum != o.maxTotal
            bet.minimum = o.minTotal
            bet.maximum = o.maxTotal
            bet.step = unit
            bet.presets = [
                BetControl.Preset(NSLocalizedString("Min", comment: "poker bet preset: the minimum"), o.minTotal),
                BetControl.Preset(NSLocalizedString("½ Pot", comment: "poker bet preset: half the pot"), rounded(o.potFractionTotal(0.5), o, unit)),
                BetControl.Preset(NSLocalizedString("¾ Pot", comment: "poker bet preset: three quarters of the pot"), rounded(o.potFractionTotal(0.75), o, unit)),
                BetControl.Preset(NSLocalizedString("Pot", comment: "poker bet preset: the size of the pot"), rounded(o.potFractionTotal(1), o, unit)),
                BetControl.Preset(NSLocalizedString("All-in", comment: "poker bet preset: every chip"), o.maxTotal),
            ]
            defaultAmount = Self.suggestedTotal(o, table: table)
            if fresh { bet.value = defaultAmount }
        }
        bet.isHidden = !canSize

        let fold = ChromeAction(id: "fold", title: NSLocalizedString("Fold", comment: "poker action button"),
                                keyEquivalent: "f") { [weak self] in self?.onAction?(.fold) }
        let passiveTitle: String
        if o.canCheck {
            passiveTitle = NSLocalizedString("Check", comment: "poker action button")
        } else if o.callIsAllIn {
            passiveTitle = String(format: NSLocalizedString("All-in %@", comment: "poker button: call for every chip, e.g. All-in 340"),
                                  Chips.format(o.callAmount))
        } else {
            passiveTitle = String(format: NSLocalizedString("Call %@", comment: "poker button: call, e.g. Call 60"),
                                  Chips.format(o.callAmount))
        }
        let passive = ChromeAction(id: "passive", title: passiveTitle, keyEquivalent: "c") { [weak self] in
            guard let o = self?.options else { return }
            self?.onAction?(o.passiveAction)
        }
        let aggressive = ChromeAction(id: "aggressive", title: aggressiveTitle(o), style: .primary, keyEquivalent: "\r",
                                      isEnabled: o.canBetOrRaise) { [weak self] in
            guard let self, let o = self.options else { return }
            self.onAction?(self.chosenAction(o))
        }
        setMode(.turn, actions: [fold, passive, aggressive], animated: animated)
    }

    /// What Return does now: the amount on the slider, or everything when
    /// that is the only raise left.
    func chosenAction(_ o: PokerActionOptions) -> PokerAction {
        guard o.canBetOrRaise else { return o.passiveAction }
        if o.maxTotal <= o.minTotal || bet.isHidden { return .allIn }
        return o.aggressiveAction(to: bet.value)
    }

    private func aggressiveTitle(_ o: PokerActionOptions) -> String {
        guard o.canBetOrRaise else { return NSLocalizedString("Raise", comment: "poker action button, unavailable") }
        let amount = (o.maxTotal <= o.minTotal || bet.isHidden) ? o.maxTotal : bet.value
        if amount >= o.maxTotal {
            return String(format: NSLocalizedString("All-in %@", comment: "poker button: bet every chip, e.g. All-in 1,480"),
                          Chips.format(o.maxTotal))
        }
        if o.canBet {
            return String(format: NSLocalizedString("Bet %@", comment: "poker button: bet, e.g. Bet 40"), Chips.format(amount))
        }
        return String(format: NSLocalizedString("Raise to %@", comment: "poker button: raise to a total, e.g. Raise to 180"),
                      Chips.format(amount))
    }

    private func refreshAggressiveTitle() {
        guard mode == .turn, let o = options else { return }
        bar.setTitle(aggressiveTitle(o), for: "aggressive")
    }

    private func rounded(_ total: Int, _ o: PokerActionOptions, _ unit: Int) -> Int {
        if total >= o.maxTotal { return o.maxTotal }
        return o.clampTotal(Int((Double(total) / Double(unit)).rounded()) * unit)
    }

    /// Where the slider starts: three big blinds to open, three times a raise
    /// to re-raise before the flop, half the pot to bet after it, the
    /// minimum to raise after it.
    static func suggestedTotal(_ o: PokerActionOptions, table: PokerTable) -> Int {
        let bb = table.blinds.bigBlind
        let unit = max(1, table.chipUnit)
        let raw: Int
        if table.street == .preflop {
            raw = o.currentBet <= bb ? bb * 3 : o.currentBet * 3
        } else if o.canBet {
            raw = o.potFractionTotal(0.5)
        } else {
            raw = o.minTotal
        }
        let snapped = Int((Double(raw) / Double(unit)).rounded()) * unit
        return o.clampTotal(snapped)
    }

    private func setMode(_ newMode: Mode, actions: [ChromeAction], animated: Bool) {
        mode = newMode
        if newMode != .turn {
            options = nil
            bet.isHidden = true
        }
        let show = !actions.isEmpty
        let motion = animated && Motion.isEnabled && bar.window != nil
        bar.setActions(actions, animated: motion && isVisible)
        guard show != isVisible else { return }
        isVisible = show
        if show {
            bar.isHidden = false
            if motion { Motion.present(bar, spring: .smooth, from: 0.97, rise: 6) } else { bar.alphaValue = 1 }
        } else if motion {
            Motion.dismiss(bar) { [weak self] in
                guard let self, !self.isVisible else { return }
                self.bar.isHidden = true
            }
        } else {
            bar.isHidden = true
        }
    }

    // MARK: Keys

    /// The table's keys that are the bar's business. True if used.
    func handleKey(_ event: NSEvent) -> Bool {
        guard mode == .turn, !bet.isHidden else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let big = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case 123, 125: bet.step(by: -big); return true      // ← ↓
        case 124, 126: bet.step(by: big); return true       // → ↑
        case 53:                                           // Escape
            cancelBet()
            return true
        default: break
        }
        if chars == "r", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            focusBet()
            return true
        }
        return false
    }

    /// R: the keyboard goes to the slider, where the arrows and Home/End work.
    func focusBet() {
        guard mode == .turn, !bet.isHidden, let slider = bet.subviews.first(where: { $0 is BetSlider }) else { return }
        bet.window?.makeFirstResponder(slider)
    }

    /// Escape: the suggested amount again, and the keyboard back on the table.
    func cancelBet() {
        guard mode == .turn else { return }
        if !bet.isHidden, bet.value != defaultAmount {
            bet.value = defaultAmount
            refreshAggressiveTitle()
        }
        if let window = bar.window, let first = window.firstResponder as? NSView, first.isDescendant(of: bet) {
            window.makeFirstResponder(bar.superview)
        }
    }
}
