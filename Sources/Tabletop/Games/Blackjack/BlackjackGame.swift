//
//  BlackjackGame.swift
//  Blackjack against the dealer: the controller that owns the table's
//  engine, keeps its time, answers the player and the Blackjack menu, and
//  keeps the record.
//
//  THE LOOP
//
//  Everything the player does goes to the engine first, which says yes or no
//  and changes at once; the table is then shown the new `BlackjackScene` and
//  animates the difference. When the engine is waiting on the dealer —
//  cards going out, the peek, the hole card, the dealer's draws, the payout —
//  `pump()` schedules its next step on the table's scheduler, a beat apart,
//  and the same thing happens again. The scheduler is the only clock: it is
//  suspended whenever the game leaves the front of a key window (so a hand
//  half dealt simply waits, and nothing ticks), cancelled on a new shoe, and
//  run at once for a screenshot or a test, where the whole round lands
//  synchronously.
//
//  The table is saved after every round and whenever the game goes out of
//  view, round in play and all, so quitting mid-hand costs nothing.
//

import AppKit

final class BlackjackGame: NSViewController, TabletopGame, NSMenuItemValidation {

    static var info: GameInfo {
        GameInfo(
            id: .blackjack,
            title: NSLocalizedString("Blackjack", comment: "game title"),
            subtitle: NSLocalizedString("Beat the dealer to twenty-one", comment: "blackjack subtitle"),
            detail: NSLocalizedString("1 player · vs the dealer", comment: "blackjack players"),
            symbolName: "suit.diamond.fill",
            accent: NSColor(srgbRed: 0.545, green: 0.153, blue: 0.188, alpha: 1),
            keyEquivalent: "3"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Get closer to twenty-one than the dealer without going over.

        • Number cards count their number, court cards count ten, and an ace \
        counts one or eleven, whichever helps. An ace and a ten-card as your \
        first two cards is a blackjack, and pays three to two.
        • Click the chips at the bottom to build a bet in the circle — keys 1 \
        to 5 do the same — and Option-click (or right-click) to take one \
        back. Deal (Return) starts the hand; on an empty circle it deals \
        your last bet again.
        • Hit (H) takes a card and Stand (S) keeps what you have. Double (D) \
        doubles the bet for exactly one more card. Split (P) makes two hands \
        of a pair, each with its own bet. Surrender (R), as your first \
        decision, gives up the hand for half the bet back.
        • When the dealer shows an ace you are offered insurance, which pays \
        two to one if the dealer has blackjack — or, holding a blackjack \
        yourself, even money.
        • The dealer draws to sixteen and stands on seventeen, or hits a \
        soft seventeen if the table says so. Choose the rules with New Game.

        With the coach on, the Hint button (?) lights the play basic \
        strategy recommends.
        """, comment: "blackjack help text")
    }

    // MARK: State

    private(set) var engine: BlackjackEngine
    private(set) var coach: BlackjackCoachLevel
    private(set) var statistics: BlackjackStatistics
    private var shoesStarted: Int
    private(set) var table: BlackjackTableView!

    /// On screen, in front, in a key and visible window.
    private var isActive = false
    /// A dealer's step is waiting on the scheduler.
    private var stepScheduled = false
    /// The chips in the circle, in the order they went on, for taking the
    /// last one back.
    private var betChips: [Int] = []
    /// A settled round's winnings have gone from the circle to the player.
    private var chipsCollected = false
    private var collectToken: TableScheduler.Token?
    /// The play the Hint button lit, until the player acts.
    private(set) var hinted: BlackjackAction?
    private var insurancePrompt: BlackjackPrompt?
    private var brokeBanner: Banner?
    private var confirmBanner: Banner?
    private var optionsCard: OptionsCard?
    private let hintButton = CapsuleButton(title: "", symbolName: "questionmark", style: .secondary)

    /// The rack's chips, and the digit keys that pick them.
    static let chipValues = [5, 25, 100, 500, 1_000]

    init() {
        if let saved = BlackjackSavedTable.load() {
            engine = saved.engine
            coach = saved.coach
            shoesStarted = max(1, saved.shoesStarted)
        } else {
            engine = BlackjackEngine(seed: Self.seed(forShoe: 1))
            coach = .hints
            shoesStarted = 1
        }
        statistics = BlackjackStatistics.load()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    /// A shoe's shuffle seed: random at a real table, numbered in the harness
    /// so tests and screenshots deal the same cards every run.
    private static func seed(forShoe n: Int) -> UInt64 {
        TabletopEnvironment.isHarness ? 0xB1AC_4ACC_0000 &+ UInt64(n) &* 0x9E37_79B9 : UInt64.random(in: .min ... .max)
    }

    override func loadView() {
        let table = BlackjackTableView()
        table.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        self.table = table
        view = table
        table.rack.onPick = { [weak self] value in self?.pickChip(value) }
        table.rack.onRemove = { [weak self] value in self?.takeBack(value) }
        table.onTakeBack = { [weak self] in self?.takeBackLast() }
        table.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        hintButton.keyEquivalent = "?"
        hintButton.accessibilityTitle = NSLocalizedString("Hint", comment: "blackjack: show the basic-strategy play")
        hintButton.handler = { [weak self] in self?.showHint(nil) }
        table.dealerRule = engine.rules.dealerRuleText
        // Nothing runs until the game is in front.
        if !table.scheduler.isImmediate { table.scheduler.suspend() }
        betChips = Self.chips(for: engine.pendingBet)
        // A round restored settled has long since paid out.
        chipsCollected = engine.phase == .settled
        table.resetTable(to: currentScene)
        refreshChrome(animated: false)
    }

    var preferredFirstResponder: NSView? { table }

    // MARK: Lifecycle

    func gameDidBecomeActive() {
        isActive = true
        guard isViewLoaded else { return }
        table.scheduler.resume()
        refreshChrome(animated: false)
        pump()
    }

    func gameWillResignActive() {
        isActive = false
        guard isViewLoaded else { return }
        // A step already scheduled keeps the time it had left and runs when
        // the player comes back.
        table.scheduler.suspend()
        save()
    }

    func prepareToQuit() {
        save()
        statistics.save()
    }

    private func save() {
        BlackjackSavedTable(engine: engine, coach: coach, shoesStarted: shoesStarted).save()
    }

    // MARK: Betting

    /// Puts a chip in the circle — collecting a finished round first.
    func pickChip(_ value: Int) {
        guard confirmBanner == nil, beginBetting(), engine.addToBet(value) else { return }
        hideTransientPrompts()
        betChips.append(value)
        var origin: CGPoint?
        if let frame = table.rack.chipFrame(for: value), table.rack.superview != nil {
            let rect = table.convert(frame, from: table.rack)
            origin = CGPoint(x: rect.midX, y: rect.midY)
        }
        render(chipOrigin: origin)
    }

    /// Takes one chip of `value` back out of the circle.
    func takeBack(_ value: Int) {
        guard engine.phase == .betting, engine.removeFromBet(value) else { return }
        if let index = betChips.lastIndex(of: value) { betChips.remove(at: index) } else {
            betChips = Self.chips(for: engine.pendingBet)
        }
        render()
    }

    /// Takes back the chip that went on last.
    func takeBackLast() {
        guard engine.phase == .betting, let last = betChips.last ?? Self.chips(for: engine.pendingBet).last else { return }
        takeBack(last)
    }

    func clearBet() {
        guard engine.phase == .betting, engine.pendingBet > 0 else { return }
        engine.clearBet()
        betChips = []
        render()
    }

    func rebet() {
        guard beginBetting(), engine.rebet() else { return }
        betChips = Self.chips(for: engine.pendingBet)
        render()
    }

    /// Deals the bet in the circle — or, on an empty circle, the last bet.
    func deal() {
        guard confirmBanner == nil, beginBetting() else { return }
        if engine.pendingBet == 0 && engine.canRebet {
            engine.rebet()
        }
        guard engine.deal() else {
            render()
            return
        }
        betChips = []
        hinted = nil
        hideTransientPrompts()
        // Saved as dealt: a round interrupted by anything short of a quit
        // resumes from its first card, on the same cards.
        save()
        render()
        pump()
    }

    /// Whether Deal would do anything now.
    private var canDealNow: Bool {
        switch engine.phase {
        case .betting: return engine.canDeal || (engine.pendingBet == 0 && engine.canRebet)
        case .settled: return engine.canRebet
        default: return false
        }
    }

    /// A settled round is cleared off the table the moment the player starts
    /// the next bet.
    private func beginBetting() -> Bool {
        switch engine.phase {
        case .betting:
            return true
        case .settled:
            collectRound()
            return engine.phase == .betting
        default:
            return false
        }
    }

    private func collectRound() {
        if let collectToken { table.scheduler.cancel(collectToken) }
        collectToken = nil
        chipsCollected = false
        let shuffled = engine.collect()
        betChips = []
        render()
        if shuffled {
            Toast.show(NSLocalizedString("A fresh shoe, shuffled", comment: "blackjack: the shoe was reshuffled"),
                       symbolName: "rectangle.stack", in: table, placement: .top)
        }
        save()
    }

    /// The fewest chips making `amount`, in the order a player would put
    /// them down — the biggest first.
    static func chips(for amount: Int) -> [Int] {
        Chips.breakdown(amount, denominations: chipValues).flatMap { Array(repeating: $0.denomination, count: $0.count) }
    }

    // MARK: Playing

    /// The player's decision on the hand in front of them.
    func play(_ action: BlackjackAction) {
        guard let hand = engine.activeHand, let up = engine.round?.upCard else { return }
        let legal = engine.legalActions()
        guard legal.contains(action) else { return }
        let advice = BlackjackStrategy.recommendation(for: hand, upCard: up, rules: engine.rules, legal: legal)
        engine.perform(action)
        hinted = nil
        if coach == .coach && action != advice {
            showCoachNote(String(format: NSLocalizedString("Basic strategy: %@", comment: "blackjack coach, e.g. Basic strategy: Double"),
                                 advice.title))
        }
        render()
        pump()
    }

    func decideInsurance(take: Bool) {
        let evenMoney = engine.isEvenMoneyOffer
        guard engine.decideInsurance(take: take) else { return }
        insurancePrompt?.dismiss()
        insurancePrompt = nil
        if coach == .coach && take != BlackjackStrategy.takesInsurance {
            showCoachNote(evenMoney
                ? NSLocalizedString("Basic strategy: no even money", comment: "blackjack coach")
                : NSLocalizedString("Basic strategy: no insurance", comment: "blackjack coach"))
        }
        render()
        pump()
    }

    /// The basic-strategy play for the hand in front of the player.
    var recommendation: BlackjackAction? {
        guard let hand = engine.activeHand, let up = engine.round?.upCard else { return nil }
        return BlackjackStrategy.recommendation(for: hand, upCard: up, rules: engine.rules, legal: engine.legalActions())
    }

    @objc func showHint(_ sender: Any?) {
        guard let advice = recommendation else { return }
        hinted = advice
        refreshChrome(animated: true)
        Toast.show(String(format: NSLocalizedString("Basic strategy: %@", comment: "blackjack coach, e.g. Basic strategy: Double"),
                          advice.title),
                   symbolName: "lightbulb", symbolTint: Palette.accent, in: table,
                   placement: .bottom(offset: table.bar.reservedHeight + Spacing.s))
    }

    private func showCoachNote(_ text: String) {
        Toast.show(text, symbolName: "lightbulb", in: table,
                   placement: .bottom(offset: table.bar.reservedHeight + Spacing.s), duration: 2.4)
    }

    // MARK: The dealer's clock

    /// Schedules the dealer's next step, if the table is waiting on one.
    private func pump() {
        guard isViewLoaded, !stepScheduled, engine.needsAdvance else { return }
        // Off screen nothing moves; the step is taken when the player is back.
        guard isActive || table.scheduler.isImmediate else { return }
        stepScheduled = true
        table.scheduler.after(delayBeforeStep) { [weak self] in
            guard let self else { return }
            self.stepScheduled = false
            self.step()
        }
    }

    private func step() {
        guard engine.needsAdvance else {
            refreshChrome()
            return
        }
        let step = engine.advance()
        if step == .settled, let round = engine.round {
            statistics.record(round, bankroll: engine.bankroll)
            statistics.save()
            save()
            // The payout lands in the circle; a beat later the chips slide
            // to the player. The cards and the results stay until the next
            // bet.
            chipsCollected = false
            collectToken = table.scheduler.after(1.3) { [weak self] in
                guard let self, self.engine.phase == .settled else { return }
                self.collectToken = nil
                self.chipsCollected = true
                self.render()
            }
        }
        render()
        pump()
    }

    /// The beat before the dealer's next step: quick for the opening cards,
    /// longer before the hole card turns and between the dealer's draws, so
    /// each can be read.
    private var delayBeforeStep: TimeInterval {
        guard let round = engine.round else { return 0 }
        switch round.phase {
        case .dealing: return round.dealer.isEmpty && round.hands[0].cards.isEmpty ? 0.15 : 0.30
        case .peek: return 0.55
        case .playerTurn: return 0.34
        case .dealerTurn: return round.isHoleRevealed ? 0.62 : 0.48
        case .settling: return 0.45
        case .betting, .insurance, .settled: return 0
        }
    }

    // MARK: Drawing

    /// What the table should be showing now.
    var currentScene: BlackjackScene { BlackjackScene(engine: engine, chipsCollected: chipsCollected) }

    private func render(chipOrigin: CGPoint? = nil, animated: Bool = true) {
        guard isViewLoaded else { return }
        table.show(currentScene, animated: animated, chipOrigin: chipOrigin)
        refreshChrome(animated: animated)
    }

    /// The bar, the pills and the prompts, for the state the table is in.
    private func refreshChrome(animated: Bool = true) {
        guard isViewLoaded else { return }
        let animated = animated && table.window != nil
        let phase = engine.phase
        let bar = table.bar
        // While a confirmation is asking, its Return is the only Return.
        let asking = confirmBanner != nil
        var actions: [ChromeAction] = []
        switch phase {
        case .betting, .settled:
            if bar.leadingAccessory !== table.rack { bar.leadingAccessory = table.rack }
            if bar.trailingAccessory != nil { bar.trailingAccessory = nil }
            table.rack.available = phase == .settled ? min(engine.rules.maximumBet, engine.bankroll) : engine.betHeadroom
            table.rack.isEnabled = !engine.isBroke && !asking
            actions = [
                ChromeAction(id: "clear", title: NSLocalizedString("Clear", comment: "blackjack: take the bet back"),
                             keyEquivalent: "\u{7f}", isEnabled: phase == .betting && engine.pendingBet > 0 && !asking) { [weak self] in
                    self?.clearBet()
                },
                ChromeAction(id: "rebet", title: NSLocalizedString("Rebet", comment: "blackjack: bet the last bet again"),
                             keyEquivalent: "b", isEnabled: engine.canRebet && !asking) { [weak self] in self?.rebet() },
                ChromeAction(id: "deal", title: NSLocalizedString("Deal", comment: "blackjack: deal the hand"),
                             style: .primary, keyEquivalent: "\r", isEnabled: canDealNow && !asking) { [weak self] in self?.deal() },
            ]
        default:
            if bar.leadingAccessory != nil { bar.leadingAccessory = nil }
            let wantsHint = coach != .off
            if wantsHint, bar.trailingAccessory !== hintButton { bar.trailingAccessory = hintButton }
            if !wantsHint, bar.trailingAccessory != nil { bar.trailingAccessory = nil }
            hintButton.isEnabled = engine.activeHand != nil
            let legal = engine.legalActions()
            let keys: [BlackjackAction: String] = [.hit: "h", .stand: "s", .double: "d", .split: "p", .surrender: "r"]
            for action in BlackjackAction.allCases where action != .surrender || engine.rules.surrenderAllowed {
                actions.append(ChromeAction(id: action.rawValue, title: action.title,
                                            style: hinted == action ? .primary : .secondary,
                                            keyEquivalent: keys[action] ?? "", isEnabled: legal.contains(action)) { [weak self] in
                    self?.play(action)
                })
            }
        }
        bar.setActions(actions, animated: animated)
        refreshPills()
        refreshPrompts()
    }

    private func refreshPills() {
        let shoe = engine.shoe
        let scene = table.scene
        // Winnings still lying in the circle are not in front of the player
        // yet; they join the bankroll when they are collected.
        let uncollected = engine.phase == .settled ? (chipsCollected ? 0 : scene.chipsOnCloth)
            : (engine.round?.insuranceReturned ?? 0) > 0 ? (engine.round?.insuranceReturned ?? 0) : 0
        let bankroll = max(0, engine.bankroll - uncollected)
        var items = [StatusPillItem(id: "bankroll",
                                    text: String(format: NSLocalizedString("Bankroll %@", comment: "blackjack pill, e.g. Bankroll 1,000"),
                                                 Chips.format(bankroll)),
                                    symbolName: "circle.dashed.inset.filled")]
        if shoe.isCutCardOut {
            items.append(StatusPillItem(id: "shoe", text: NSLocalizedString("Shuffle after this hand", comment: "blackjack pill: the cut card is out"),
                                        symbolName: "rectangle.stack", isEmphasized: true))
        } else {
            items.append(StatusPillItem(id: "shoe",
                                        text: String(format: NSLocalizedString("Shoe %d%%", comment: "blackjack pill: share of the shoe left, e.g. Shoe 74%"),
                                                     Int((shoe.remainingFraction * 100).rounded())),
                                        symbolName: "rectangle.stack"))
        }
        TopBarStatus.set(items, for: .blackjack)
    }

    /// The insurance question and the out-of-chips offer.
    private func refreshPrompts() {
        if engine.phase == .insurance {
            if insurancePrompt?.isShowing != true { presentInsurance() }
        } else if let prompt = insurancePrompt {
            prompt.dismiss()
            insurancePrompt = nil
        }
        if engine.isBroke {
            if brokeBanner == nil { presentBroke() }
        } else if let banner = brokeBanner {
            banner.dismiss(notify: false)
            brokeBanner = nil
        }
    }

    private func presentInsurance() {
        let even = engine.isEvenMoneyOffer
        let title = even ? NSLocalizedString("Even money?", comment: "blackjack prompt: even money for a natural")
            : NSLocalizedString("Insurance?", comment: "blackjack prompt")
        let detail = even
            ? NSLocalizedString("1 to 1 now, whatever the dealer has", comment: "blackjack even money prompt")
            : String(format: NSLocalizedString("%@ pays 2 to 1 against a blackjack", comment: "blackjack insurance prompt, e.g. 50 pays 2 to 1"),
                     Chips.format(engine.insuranceCost))
        let prompt = BlackjackPrompt(title: title, detail: detail, actions: [
            ChromeAction(id: "take", title: even ? NSLocalizedString("Even Money", comment: "blackjack: take even money")
                            : NSLocalizedString("Take Insurance", comment: "blackjack: take insurance"),
                         keyEquivalent: even ? "e" : "i") { [weak self] in self?.decideInsurance(take: true) },
            ChromeAction(id: "decline", title: NSLocalizedString("No Thanks", comment: "blackjack: decline insurance"),
                         style: .primary, keyEquivalent: "\r") { [weak self] in self?.decideInsurance(take: false) },
        ])
        prompt.present(in: table, at: table.promptPoint)
        table.prompt = prompt
        insurancePrompt = prompt
    }

    /// The insurance question is on the table.
    var isAskingInsurance: Bool { insurancePrompt?.isShowing == true }

    private func presentBroke() {
        let banner = Banner.show(
            in: table, title: NSLocalizedString("Out of chips", comment: "blackjack: bankroll below the minimum"),
            subtitle: String(format: NSLocalizedString("Your bankroll is below the table minimum of %@.", comment: "blackjack"),
                             Chips.format(engine.rules.minimumBet)),
            symbolName: "circle.dashed", actions: [
                ChromeAction(id: "reset", title: String(format: NSLocalizedString("New Bankroll of %@", comment: "blackjack: e.g. New Bankroll of 1,000"),
                                                        Chips.format(BlackjackRules.startingBankroll)),
                             style: .primary, keyEquivalent: "\r") { [weak self] in self?.resetBankroll() },
            ], verticalPosition: table.promptPosition)
        brokeBanner = banner
    }

    private func hideTransientPrompts() {
        guard let banner = confirmBanner else { return }
        banner.dismiss(notify: false)
        confirmBanner = nil
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let digit = Int(characters), (1...Self.chipValues.count).contains(digit),
              event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        guard OptionsCard.presentedCards.isEmpty, Banner.banners(in: table).isEmpty, !isAskingInsurance else { return true }
        let value = Self.chipValues[digit - 1]
        if event.modifierFlags.contains(.option) { takeBack(value) } else if table.rack.isChipEnabled(value) { pickChip(value) }
        return true
    }

    // MARK: The Blackjack menu

    func makeGameMenu() -> NSMenu {
        let menu = NSMenu(title: Self.info.title)
        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.tag = tag
            item.target = nil
            menu.addItem(item)
            return item
        }
        add(menu, NSLocalizedString("New Game…", comment: "blackjack menu: a new shoe at chosen rules"), #selector(newGame(_:)), "n")
        add(menu, NSLocalizedString("Reset Bankroll…", comment: "blackjack menu"), #selector(resetBankrollFromMenu(_:)))
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Deal", comment: "blackjack menu"), #selector(dealFromMenu(_:)), "\r")
        add(menu, NSLocalizedString("Rebet", comment: "blackjack menu"), #selector(rebetFromMenu(_:)), "b")
        add(menu, NSLocalizedString("Clear Bet", comment: "blackjack menu"), #selector(clearBetFromMenu(_:)), "\u{8}")
        menu.addItem(.separator())
        // ⌘H is Hide, so the hint lives on ⌘/ — and the bar takes a bare ?.
        add(menu, NSLocalizedString("Show Hint", comment: "blackjack menu"), #selector(showHint(_:)), "/")
        let coachItem = NSMenuItem(title: NSLocalizedString("Coach", comment: "blackjack menu: how much help"), action: nil,
                                   keyEquivalent: "")
        let coachMenu = NSMenu(title: coachItem.title)
        for level in BlackjackCoachLevel.allCases {
            add(coachMenu, level.title, #selector(setCoach(_:)), tag: level.rawValue)
        }
        coachItem.submenu = coachMenu
        menu.addItem(coachItem)
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Statistics…", comment: ""), #selector(showStatistics(_:)), "s", modifiers: [.command, .option])
        return menu
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard isViewLoaded else { return false }
        let between = engine.phase == .betting || engine.phase == .settled
        switch item.action {
        case #selector(resetBankrollFromMenu(_:)): return between
        case #selector(dealFromMenu(_:)): return canDealNow
        case #selector(rebetFromMenu(_:)): return engine.canRebet
        case #selector(clearBetFromMenu(_:)): return engine.phase == .betting && engine.pendingBet > 0
        case #selector(showHint(_:)): return recommendation != nil
        case #selector(setCoach(_:)):
            item.state = coach.rawValue == item.tag ? .on : .off
            return true
        default: return true
        }
    }

    @objc func dealFromMenu(_ sender: Any?) { deal() }
    @objc func rebetFromMenu(_ sender: Any?) { rebet() }
    @objc func clearBetFromMenu(_ sender: Any?) { clearBet() }

    @objc func setCoach(_ sender: NSMenuItem) {
        guard let level = BlackjackCoachLevel(rawValue: sender.tag) else { return }
        coach = level
        if level == .off { hinted = nil }
        refreshChrome()
        save()
    }

    @objc func showStatistics(_ sender: Any?) {
        BlackjackStatistics.present(statistics, in: view.window) { [weak self] in
            guard let self else { return }
            self.statistics = BlackjackStatistics()
            self.statistics.peakBankroll = self.engine.bankroll
            self.statistics.save()
        }
    }

    // MARK: New game

    /// The table rules, on the kit's New Game card.
    @objc func newGame(_ sender: Any?) {
        guard optionsCard?.isPresented != true else { return }
        let rules = engine.rules
        let inPlay = engine.round != nil && engine.phase != .settled
        let card = OptionsCard(
            title: NSLocalizedString("New Game", comment: "blackjack options card title"),
            subtitle: inPlay
                ? NSLocalizedString("A fresh shoe. The hand in play is forfeited.", comment: "blackjack options")
                : NSLocalizedString("A fresh shoe. Your bankroll stays with you.", comment: "blackjack options"),
            rows: [
                OptionsCard.Row(id: "decks", title: NSLocalizedString("Decks", comment: "blackjack option"),
                                options: BlackjackRules.deckChoices.map(String.init),
                                selectedIndex: BlackjackRules.deckChoices.firstIndex(of: rules.decks) ?? 2),
                OptionsCard.Row(id: "soft17", title: NSLocalizedString("Soft 17", comment: "blackjack option: the dealer's rule"),
                                options: [NSLocalizedString("Dealer Stands", comment: "blackjack option: S17"),
                                          NSLocalizedString("Dealer Hits", comment: "blackjack option: H17")],
                                selectedIndex: rules.dealerHitsSoft17 ? 1 : 0),
                OptionsCard.Row(id: "surrender", title: NSLocalizedString("Surrender", comment: "blackjack option"),
                                options: [NSLocalizedString("On", comment: "option on"), NSLocalizedString("Off", comment: "option off")],
                                selectedIndex: rules.surrenderAllowed ? 0 : 1),
                OptionsCard.Row(id: "coach", title: NSLocalizedString("Coach", comment: "blackjack option"),
                                options: BlackjackCoachLevel.allCases.map(\.title), selectedIndex: coach.rawValue),
            ],
            startTitle: NSLocalizedString("Deal a New Shoe", comment: "blackjack options card: start"))
        card.onStart = { [weak self] choices in self?.startNewShoe(choices) }
        card.onCancel = {}
        optionsCard = card
        card.present(in: table)
    }

    private func startNewShoe(_ choices: [String: Int]) {
        var rules = engine.rules
        rules.decks = BlackjackRules.deckChoices[safe: choices["decks"] ?? 2] ?? 6
        rules.dealerHitsSoft17 = choices["soft17"] == 1
        rules.surrenderAllowed = choices["surrender"] != 1
        coach = BlackjackCoachLevel(rawValue: choices["coach"] ?? 1) ?? .hints
        if let round = engine.round, round.phase != .settled {
            statistics.recordForfeit(hands: round.hands.filter { !$0.isSettled }.count, staked: round.chipsAtRisk)
            statistics.save()
        }
        shoesStarted += 1
        restart(with: rules)
    }

    /// A clean table at `rules`: everything scheduled is dropped, the old
    /// round forfeited, a new shoe shuffled.
    private func restart(with rules: BlackjackRules) {
        table.scheduler.cancelAll()
        stepScheduled = false
        Banner.dismissAll(in: table)
        insurancePrompt?.dismiss(animated: false)
        insurancePrompt = nil
        brokeBanner = nil
        confirmBanner = nil
        hinted = nil
        betChips = []
        engine.startShoe(rules: rules, seed: Self.seed(forShoe: shoesStarted))
        chipsCollected = false
        collectToken = nil
        table.dealerRule = rules.dealerRuleText
        table.resetTable(to: currentScene)
        refreshChrome(animated: false)
        save()
        Toast.show(String(format: NSLocalizedString("%@ · a fresh shoe", comment: "blackjack: e.g. 6 decks · a fresh shoe"),
                          Plural.format(rules.decks, one: NSLocalizedString("%d deck", comment: "count of decks"),
                                        other: NSLocalizedString("%d decks", comment: "count of decks"))),
                   symbolName: "rectangle.stack", in: table, placement: .top)
    }

    // MARK: Bankroll

    @objc func resetBankrollFromMenu(_ sender: Any?) {
        guard engine.phase == .betting || engine.phase == .settled, confirmBanner == nil else { return }
        confirmBanner = Banner.show(
            in: table, title: NSLocalizedString("Start again with a new bankroll?", comment: "blackjack confirmation"),
            subtitle: String(format: NSLocalizedString("Your bankroll goes back to %@. Your statistics are kept.", comment: "blackjack"),
                             Chips.format(BlackjackRules.startingBankroll)),
            actions: [
                ChromeAction(id: "cancel", title: NSLocalizedString("Cancel", comment: ""), keyEquivalent: "\u{1b}") { [weak self] in
                    self?.confirmBanner = nil
                    self?.refreshChrome()
                },
                ChromeAction(id: "confirm", title: NSLocalizedString("Reset", comment: "blackjack: reset the bankroll"),
                             style: .destructiveProminent, keyEquivalent: "\r") { [weak self] in
                    self?.confirmBanner = nil
                    self?.resetBankroll()
                },
            ], verticalPosition: table.promptPosition)
        refreshChrome()
    }

    func resetBankroll() {
        brokeBanner?.dismiss(notify: false)
        brokeBanner = nil
        engine.resetBankroll()
        betChips = []
        render()
        save()
    }

    // MARK: Screenshots

    static var screenshotScenarios: [String] { ["betting", "decision", "split", "insurance", "settled", "new-game", "cut-card"] }

    func prepareForScreenshot(scenario: String?) {
        loadViewIfNeeded()
        BlackjackScreenshots.prepare(self, scenario: scenario ?? "betting")
    }

    /// Puts the table in `engine`'s state at once — the screenshots' way in.
    func adoptForScreenshot(_ engine: BlackjackEngine, coach: BlackjackCoachLevel) {
        table.scheduler.cancelAll()
        stepScheduled = false
        Banner.dismissAll(in: table)
        insurancePrompt?.dismiss(animated: false)
        insurancePrompt = nil
        brokeBanner = nil
        self.engine = engine
        self.coach = coach
        betChips = Self.chips(for: engine.pendingBet)
        // Photographed the moment the payout lands, before it is collected.
        chipsCollected = false
        collectToken = nil
        table.dealerRule = engine.rules.dealerRuleText
        table.resetTable(to: currentScene)
        refreshChrome(animated: false)
    }

    /// For the play test: the scheduler runs every step at once.
    func runDealerForTesting() {
        table.scheduler.runPendingImmediately()
    }

    /// For the play test: the next cards out of the shoe.
    func stackShoeForTesting(_ cards: [Card]) {
        engine.stackShoe(cards)
    }

    // MARK: Library tile

    /// A natural on the betting circle, the dealer beyond the printed arcs. See `BlackjackArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        BlackjackArtwork.draw(in: ctx, rect: rect)
    }

    // MARK: Self-tests

    static func runSelfTests(_ t: TestReporter) {
        BlackjackTests.run(t)
    }
}
