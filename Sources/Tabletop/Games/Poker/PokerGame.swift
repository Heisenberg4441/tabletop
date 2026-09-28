//
//  PokerGame.swift
//  No-limit Texas Hold'em against computer players, as one game in the
//  collection: the table, the New Game card, the menu, the record, and
//  saving between hands.
//
//  The pieces, and who owns what:
//
//    PokerTable (Engine/)     the rules; the only source of truth
//    PokerFlow                runs the table: turns, bots' pauses, dealing
//    PokerTableView           draws it, and plays the engine's events out
//    PokerActionPanel         the player's buttons and bet control
//    PokerGame (this)         everything round the edge — lifecycle, menu,
//                             options, banners, pills, storage, statistics
//
//  ENERGY. The flow's every pause is on the table's scheduler, which runs
//  only while the game is in front in a key window and no New Game card is
//  up: suspended from `gameWillResignActive` to `gameDidBecomeActive`, so a
//  bot halfway through its thinking stops there and carries on with the
//  time it had left. The seats' thinking sweep watches the window itself.
//

import AppKit

final class PokerGame: NSViewController, TabletopGame, NSMenuItemValidation, PokerFlowDelegate {

    // MARK: Identity

    static var info: GameInfo {
        GameInfo(
            id: .poker,
            title: NSLocalizedString("Poker", comment: "game title"),
            subtitle: NSLocalizedString("Texas Hold’em against the table", comment: "poker subtitle"),
            detail: NSLocalizedString("1 player · vs computer", comment: "poker players"),
            symbolName: "suit.spade.fill",
            accent: NSColor(srgbRed: 0.145, green: 0.318, blue: 0.557, alpha: 1),
            keyEquivalent: "2"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        No-limit Texas Hold’em against one to five computer players. Each \
        player gets two cards face down; five more are dealt face up in the \
        middle for everyone to share — three on the flop, one on the turn, \
        one on the river — with a round of betting before each and after the \
        last.

        • Make the best five-card hand from your two cards and the five on \
        the table. The pill beside your cards names your hand as it stands.
        • Fold, check or call, or bet and raise any amount up to everything \
        you have in front of you. The best hand at the showdown takes the pot \
        — unless everyone else folded first.
        • Tournament: everyone starts with 1,500 and the blinds go up every \
        eight hands, until one player has every chip. Cash game: blinds \
        5/10, and you can top up to 1,000 between hands.

        Keyboard: F folds, C checks or calls, R moves to the bet amount (← \
        and → change it, ⇧ for bigger steps), Return bets or raises — or \
        deals the next hand — and Escape puts the amount back. ⌘N starts a \
        new game.
        """, comment: "poker help text")
    }

    // MARK: State

    private lazy var tableView = PokerTableView()
    private lazy var flow = PokerFlow(table: PokerTable(config: preferences.config, seed: 1),
                                      scheduler: tableView.scheduler, decider: PokerWorkerDecider())
    private lazy var panel = PokerActionPanel(bar: tableView.actionBar)
    private var preferences = PokerPreferences.load()
    private var stats = PokerStorage.loadStats()
    private var optionsCard: OptionsCard?
    /// The player's finish in the tournament at the table has been counted.
    private var tournamentRecorded = false
    /// In front, in a key and visible window.
    private var isActive = false
    private var preferencesObserver: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    override func loadView() {
        view = tableView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Nothing ticks until the game is actually in front.
        syncScheduler()
        flow.view = tableView
        flow.delegate = self
        flow.speed = preferences.speed
        tableView.showsHandStrength = preferences.showsHandStrength
        panel.flow = flow
        panel.onAction = { [weak self] action in self?.flow.act(action) }
        panel.onDeal = { [weak self] in self?.flow.dealNextHand() }
        panel.onTopUp = { [weak self] in self?.flow.topUp() }
        tableView.keyHandler = { [weak self] event in self?.panel.handleKey(event) ?? false }

        // Reduce Motion can change while the table is up; the next thing
        // that moves reads it, and the bar follows at once.
        preferencesObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.update(animated: false) }
        }

        if let saved = PokerStorage.loadTable() {
            resume(saved)
        } else {
            flow.start(PokerTable(config: preferences.config, seed: 1), dealNow: false, frozen: true)
            presentOptions(allowCancel: false, animated: false)
        }
    }

    var preferredFirstResponder: NSView? { tableView }

    private func resume(_ table: PokerTable) {
        tournamentRecorded = table.humanPlace != nil
        flow.start(table, dealNow: false)
    }

    // MARK: Lifecycle

    func gameDidBecomeActive() {
        isActive = true
        guard isViewLoaded else { return }
        syncScheduler()
        publishStatus()
    }

    func gameWillResignActive() {
        isActive = false
        guard isViewLoaded else { return }
        syncScheduler()
        save()
    }

    func prepareToQuit() {
        guard isViewLoaded else { return }
        save()
        PokerStorage.save(stats)
        preferences.save()
    }

    /// The table's clock runs only while the player can see it and no New
    /// Game card is asking them something.
    private func syncScheduler() {
        let run = isActive && optionsCard?.isPresented != true
        if run { tableView.scheduler.resume() } else { tableView.scheduler.suspend() }
    }

    private func save() {
        // Between hands only: a hand half played cannot be animated back, so
        // the last hand boundary is what a relaunch resumes.
        PokerStorage.save(flow.table)
    }

    // MARK: New games

    private func presentOptions(allowCancel: Bool, animated: Bool = true) {
        optionsCard?.dismiss(animated: false)
        let p = preferences
        let rows = [
            OptionsCard.Row(id: "mode", title: NSLocalizedString("Game", comment: "poker options row"),
                            options: PokerMode.allCases.map(\.localizedName),
                            selectedIndex: PokerMode.allCases.firstIndex(of: p.mode) ?? 0),
            OptionsCard.Row(id: "opponents", title: NSLocalizedString("Opponents", comment: "poker options row"),
                            options: (1...5).map { Chips.format($0) }, selectedIndex: p.opponents - 1),
            OptionsCard.Row(id: "difficulty", title: NSLocalizedString("Difficulty", comment: "poker options row"),
                            options: PokerDifficulty.allCases.map(\.localizedName),
                            selectedIndex: PokerDifficulty.allCases.firstIndex(of: p.difficulty) ?? 1),
            OptionsCard.Row(id: "speed", title: NSLocalizedString("Speed", comment: "poker options row"),
                            options: PokerSpeed.allCases.map(\.localizedName),
                            selectedIndex: PokerSpeed.allCases.firstIndex(of: p.speed) ?? 0),
        ]
        let card = OptionsCard(
            title: NSLocalizedString("New Game", comment: "poker options card title"),
            subtitle: NSLocalizedString("No-limit Texas Hold’em. A tournament starts everyone on 1,500 with the blinds rising every eight hands; a cash game plays 5/10 for as long as you like.",
                                        comment: "poker options card subtitle"),
            rows: rows,
            startTitle: NSLocalizedString("Deal", comment: "poker options card: start the game"))
        card.onStart = { [weak self] chosen in
            guard let self else { return }
            var p = self.preferences
            p.mode = PokerMode.allCases[safe: chosen["mode"] ?? 0] ?? .tournament
            p.opponents = max(1, min(5, (chosen["opponents"] ?? 4) + 1))
            p.difficulty = PokerDifficulty.allCases[safe: chosen["difficulty"] ?? 1] ?? .standard
            p.speed = PokerSpeed.allCases[safe: chosen["speed"] ?? 0] ?? .normal
            self.preferences = p
            p.save()
            self.optionsCard = nil
            self.panel.isSuppressed = false
            self.startNewGame(p.config)
        }
        if allowCancel {
            card.onCancel = { [weak self] in
                self?.optionsCard = nil
                self?.panel.isSuppressed = false
                self?.syncScheduler()
            }
        }
        optionsCard = card
        card.present(in: tableView, animated: animated)
        panel.isSuppressed = true
        syncScheduler()
    }

    private func startNewGame(_ config: PokerTableConfig) {
        countAbandonedTournament()
        Banner.dismissAll(in: tableView)
        Toast.hide(in: tableView, animated: false)
        tableView.isQuiet = false
        let seed = TabletopEnvironment.isHarness ? 0x5EED_0001 : UInt64.random(in: 1...UInt64.max)
        let table = PokerTable(config: config, seed: seed)
        tournamentRecorded = false
        // Saved before the first deal, so a relaunch comes back to this game
        // rather than the one it replaced.
        PokerStorage.save(table)
        flow.speed = preferences.speed
        flow.start(table, dealNow: true)
        syncScheduler()
        view.window?.makeFirstResponder(tableView)
    }

    /// Walking away from a tournament still counts it as played — otherwise
    /// the record is whatever the player wants it to be.
    private func countAbandonedTournament() {
        let table = flow.table
        guard table.config.mode == .tournament, table.handNumber > 0, table.humanPlace == nil,
              !tournamentRecorded else { return }
        stats.tournamentsPlayed += 1
        PokerStorage.save(stats)
    }

    // MARK: Flow

    func flowDidChangeState(_ flow: PokerFlow) {
        panel.update(animated: true)
        publishStatus()
    }

    func flow(_ flow: PokerFlow, didFinishHand summary: PokerHandSummary) {
        let table = flow.table
        if let seat = table.humanSeat, table.players[seat].holeCards.count == 2 {
            stats.record(summary, humanSeat: seat, mode: table.config.mode)
        }
        if table.config.mode == .tournament, let place = table.humanPlace, !tournamentRecorded {
            tournamentRecorded = true
            stats.recordTournament(place: place)
        }
        PokerStorage.save(stats)
        save()
    }

    func flow(_ flow: PokerFlow, tournamentOverWithPlace place: Int) {
        showTournamentResult(place: place)
    }

    private func showTournamentResult(place: Int) {
        Banner.dismissAll(in: tableView)
        tableView.isQuiet = true
        let table = flow.table
        let title = place == 1
            ? NSLocalizedString("You won the tournament", comment: "poker banner: the player won the tournament")
            : String(format: NSLocalizedString("You finished %@", comment: "poker banner: the player's place, e.g. You finished 4th"),
                     PokerTableView.ordinal(place))
        let players = Plural.format(table.players.count,
                                    one: NSLocalizedString("%d player", comment: "poker banner: player count, one"),
                                    other: NSLocalizedString("%d players", comment: "poker banner: player count, many"))
        let hands = Plural.format(table.handNumber,
                                  one: NSLocalizedString("%d hand", comment: "poker banner: hands played, one"),
                                  other: NSLocalizedString("%d hands", comment: "poker banner: hands played, many"))
        let config = table.config
        Banner.show(in: tableView, title: title, subtitle: "\(players) · \(hands)",
                    symbolName: place == 1 ? "trophy.fill" : "flag.checkered",
                    tone: place == 1 ? .win : .neutral,
                    actions: [
                        ChromeAction(id: "settings", title: NSLocalizedString("Change Settings…", comment: "poker banner button")) { [weak self] in
                            self?.presentOptions(allowCancel: false)
                        },
                        ChromeAction(id: "again", title: NSLocalizedString("New Tournament", comment: "poker banner button"),
                                     style: .primary, keyEquivalent: "\r") { [weak self] in
                            self?.startNewGame(config)
                        },
                    ],
                    scheduler: tableView.scheduler, verticalPosition: 0.40)
    }

    // MARK: Status pills

    private func publishStatus() {
        let table = flow.table
        var items: [StatusPillItem] = []
        let blinds = table.blinds
        items.append(StatusPillItem(id: "blinds",
                                    text: String(format: NSLocalizedString("Blinds %1$@/%2$@", comment: "poker status pill, e.g. Blinds 10/20"),
                                                 Chips.format(blinds.smallBlind), Chips.format(blinds.bigBlind)),
                                    symbolName: "circle.grid.2x1"))
        if table.config.mode == .tournament, table.handNumber > 0 {
            if let left = table.handsUntilNextLevel {
                if left == 0 {
                    items.append(StatusPillItem(id: "level",
                                                text: NSLocalizedString("Blinds up next hand", comment: "poker status pill"),
                                                symbolName: "arrow.up.circle", isEmphasized: true))
                } else {
                    items.append(StatusPillItem(id: "level",
                                                text: Plural.format(left,
                                                                    one: NSLocalizedString("Next level in %d hand", comment: "poker status pill, one"),
                                                                    other: NSLocalizedString("Next level in %d hands", comment: "poker status pill, many")),
                                                symbolName: "arrow.up.circle"))
                }
            } else {
                items.append(StatusPillItem(id: "level", text: NSLocalizedString("Top level", comment: "poker status pill: the blinds will rise no more"),
                                            symbolName: "arrow.up.circle"))
            }
        }
        if table.handNumber > 0 {
            items.append(StatusPillItem(id: "hand",
                                        text: String(format: NSLocalizedString("Hand %@", comment: "poker status pill, e.g. Hand 14"),
                                                     Chips.format(table.handNumber)),
                                        symbolName: "number"))
        }
        TopBarStatus.set(items, for: .poker)
    }

    // MARK: Menu

    func makeGameMenu() -> NSMenu {
        let menu = NSMenu(title: Self.info.title)
        @discardableResult
        func add(_ title: String, _ action: Selector, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.target = nil      // the responder chain brings it here
            menu.addItem(item)
            return item
        }
        add(NSLocalizedString("New Game…", comment: "poker menu"), #selector(newGame(_:)), "n")
        add(NSLocalizedString("New Game with Same Settings", comment: "poker menu"), #selector(newGameSameSettings(_:)), "n",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(NSLocalizedString("Deal Next Hand", comment: "poker menu"), #selector(dealNextHand(_:)), "d")
        add(String(format: NSLocalizedString("Top Up to %@", comment: "poker menu: buy back up to a full cash stack"),
                   Chips.format(PokerTableConfig.cashStack)), #selector(topUp(_:)), "t")
        menu.addItem(.separator())
        add(NSLocalizedString("Fast Opponents", comment: "poker menu: the computer players take less time"),
            #selector(toggleFastOpponents(_:)))
        add(NSLocalizedString("Show Hand Strength", comment: "poker menu: the pill naming the player's hand"),
            #selector(toggleHandStrength(_:)))
        menu.addItem(.separator())
        add(NSLocalizedString("Statistics…", comment: "poker menu"), #selector(showStatistics(_:)), "s",
            modifiers: [.command, .option])
        return menu
    }

    @objc func newGame(_ sender: Any?) {
        presentOptions(allowCancel: true)
    }

    @objc func newGameSameSettings(_ sender: Any?) {
        optionsCard?.dismiss(animated: false)
        optionsCard = nil
        startNewGame(preferences.config)
    }

    @objc func dealNextHand(_ sender: Any?) {
        flow.dealNextHand()
    }

    @objc func topUp(_ sender: Any?) {
        flow.topUp()
    }

    @objc func toggleFastOpponents(_ sender: Any?) {
        preferences.speed = preferences.speed == .fast ? .normal : .fast
        preferences.save()
        flow.speed = preferences.speed
    }

    @objc func toggleHandStrength(_ sender: Any?) {
        preferences.showsHandStrength.toggle()
        preferences.save()
        tableView.showsHandStrength = preferences.showsHandStrength
    }

    @objc func showStatistics(_ sender: Any?) {
        let wasActive = isActive
        isActive = false
        syncScheduler()
        PokerStatisticsWindow.show(stats) { [weak self] in
            self?.stats = PokerStats()
            PokerStorage.save(PokerStats())
        }
        isActive = wasActive
        syncScheduler()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let cardUp = optionsCard?.isPresented == true
        switch item.action {
        case #selector(dealNextHand(_:)):
            return !cardUp && flow.stage == .betweenHands
        case #selector(topUp(_:)):
            return !cardUp && flow.canTopUp
        case #selector(toggleFastOpponents(_:)):
            item.state = preferences.speed == .fast ? .on : .off
            return true
        case #selector(toggleHandStrength(_:)):
            item.state = preferences.showsHandStrength ? .on : .off
            return true
        case #selector(newGameSameSettings(_:)):
            return !cardUp
        default:
            return true
        }
    }

    // MARK: Harness

    static var screenshotScenarios: [String] {
        PokerScenarios.names + PokerGame.extraScenarios
    }

    func prepareForScreenshot(scenario: String?) {
        _ = view
        optionsCard?.dismiss(animated: false)
        optionsCard = nil
        panel.isSuppressed = false
        Banner.dismissAll(in: tableView)
        tableView.isQuiet = false
        let name = scenario ?? Self.screenshotScenarios[0]
        let table = PokerGame.scenarioTable(name) ?? PokerScenarios.table(nil) ?? flow.table
        flow.start(table, dealNow: false, frozen: true)
        switch name {
        case "tournament-end":
            showTournamentResult(place: table.humanPlace ?? 1)
        case "new-game":
            presentOptions(allowCancel: true, animated: false)
        default:
            break
        }
        tableView.layoutSubtreeIfNeeded()
    }

    static func runSelfTests(_ t: TestReporter) {
        PokerTests.run(t)
    }

    // MARK: Library tile

    /// Pocket aces at the rail of an oval table, the board and the pot beyond. See `PokerArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        PokerArtwork.draw(in: ctx, rect: rect)
    }

    // MARK: For the tests

    var flowForTesting: PokerFlow { _ = view; return flow }
    var tableViewForTesting: PokerTableView { _ = view; return tableView }
    var panelForTesting: PokerActionPanel { _ = view; return panel }
    var optionsCardForTesting: OptionsCard? { optionsCard }
}
