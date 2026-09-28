//
//  SolitaireGame.swift
//  Klondike, as one game in the collection: owns the board, the rules the
//  player chose, the clock and the record, and answers the Solitaire menu.
//
//  This was the whole app once, as a window controller. Everything that was
//  about the window — its frame, its titlebar, which screen it is showing —
//  now belongs to the shell; everything that was about the game is here,
//  unchanged in behaviour.
//

import AppKit

final class SolitaireGame: NSViewController, TabletopGame, TabletopUndoable,
                           BoardViewDelegate, NSMenuItemValidation {

    // MARK: Identity

    static var info: GameInfo {
        GameInfo(
            id: .solitaire,
            title: NSLocalizedString("Solitaire", comment: "game title"),
            subtitle: NSLocalizedString("Klondike, draw one or three", comment: "solitaire subtitle"),
            detail: NSLocalizedString("1 player", comment: "solitaire players"),
            symbolName: "suit.heart.fill",
            accent: NSColor(srgbRed: 0.157, green: 0.443, blue: 0.290, alpha: 1),
            keyEquivalent: "5"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Build the four foundations up from ace to king, one for each suit.

        • Click a card and it moves itself to the best place it can go — a \
        foundation if it fits, otherwise onto another column.
        • Click part-way down a run to move that whole run.
        • Drag instead, if you would rather choose the destination yourself.
        • Click the face-down pile to turn a card over; click it again when it \
        is empty to turn the pile back over.
        • Right-click a card to send it straight to a foundation.

        Keyboard: ⌘N for a new game, ⌘Z to undo, Space to turn a card over, \
        H for a hint, and ⌘E to finish a game that is already decided.
        """, comment: "solitaire help text")
    }

    // MARK: State

    private(set) var preferences: SolitairePreferences
    private var statistics: SolitaireStatistics
    private var boardView: BoardView!
    private let actionBar = ActionBar()
    private var overlay: MessageOverlay!
    private var clockTimer: Timer?
    private var statsCountedThisGame = false
    private var dealGenerator = DealGenerator()
    private var preferencesObserver: NSObjectProtocol?

    /// On screen, in front, in a key and visible window — the span between
    /// `gameDidBecomeActive` and `gameWillResignActive`. The clock's readout
    /// only ticks inside it.
    private var isActive = false

    private static let savedGameName = Storage.fileName("current-game.json", for: .solitaire)

    init() {
        self.preferences = SolitairePreferences.load()
        self.statistics = SolitaireStatistics.load()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("SolitaireGame is built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    private var game: Game { boardView.game }

    override func loadView() {
        let restored = restoreGame()
        let game = restored ?? newGameInstance()
        // A deal restored from disk with moves on it was counted as played in
        // the session that started it; counting it again on the first move
        // after every relaunch would inflate "played" once per session.
        statsCountedThisGame = restored?.hasStarted ?? false
        boardView = BoardView(game: game, theme: TablePreferences.current.theme)
        boardView.allowsLiveAnimation = isActive
        boardView.delegate = self
        boardView.translatesAutoresizingMaskIntoConstraints = false

        overlay = MessageOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(boardView)
        content.addSubview(overlay)

        NSLayoutConstraint.activate([
            boardView.topAnchor.constraint(equalTo: content.topAnchor),
            boardView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            boardView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            boardView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            overlay.topAnchor.constraint(equalTo: boardView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: boardView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: boardView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: boardView.bottomAnchor),
        ])
        // The buttons float over the bottom of the felt; the cards stop short
        // of them.
        actionBar.bottomMargin = Spacing.l
        actionBar.install(in: content)
        view = content

        // The table follows the View menu live: a new cloth or card back is
        // display-only, so it goes straight onto the board in front of the
        // player rather than waiting for the next deal.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: TablePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }

        refreshStatus()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        boardView.topInset = TabletopChrome.topInset(for: view)
        boardView.bottomInset = actionBar.reservedHeight
    }

    var preferredFirstResponder: NSView? { boardView }

    // MARK: Lifecycle

    func gameDidBecomeActive() {
        isActive = true
        guard isViewLoaded else { return }
        boardView.allowsLiveAnimation = true
        if game.hasStarted && !game.isWon { game.startClock() }
        refreshStatus()
        // A win that finished while the player was away is congratulated now
        // they are back, rather than by a dialog popping up over whatever
        // they went to look at.
        if winAwaitingPresentation {
            winAwaitingPresentation = false
            DispatchQueue.main.async { [weak self] in self?.presentWin() }
        }
    }

    /// Covered, minimised, clicked away from or left for the library: the
    /// player is not playing, so the game clock stops with the readout — the
    /// time on a won deal is time spent at the table, not time the window was
    /// open.
    func gameWillResignActive() {
        isActive = false
        guard isViewLoaded else { return }
        // Nothing may keep running for a table nobody is watching. An
        // auto-finish still stepping through its moves is played out at once
        // — and, the board no longer being allowed a live animation, the win
        // it ends in is reported without a cascade. A cascade already flying
        // (it runs on a display link) lands at once. Either way the win is
        // counted and nothing ticks.
        boardView.allowsLiveAnimation = false
        boardView.finishAutoFinishNow()
        boardView.finishWinAnimationNow()
        game.pauseClock()
        syncClockTimer()
        saveGame()
    }

    func prepareToQuit() {
        if isViewLoaded {
            game.pauseClock()
            syncClockTimer()
            saveGame()
        }
        preferences.save()
        statistics.save()
    }

    // MARK: New games

    private func newGameInstance(dealNumber: Int? = nil) -> Game {
        let options = preferences.gameOptions
        let number: Int
        if let dealNumber {
            number = dealNumber
        } else if preferences.winnableDealsOnly {
            number = dealGenerator.winnableDealNumber(options: options)
        } else {
            number = DealNumber.random()
        }
        return Game(dealNumber: number, options: options)
    }

    private func startNewGame(dealNumber: Int? = nil) {
        settlePendingWin()
        countAbandonedGame()
        let game = newGameInstance(dealNumber: dealNumber)
        statsCountedThisGame = false
        boardView.replaceGame(game, dealAnimation: true)
        refreshStatus()
    }

    /// A win whose cascade is still flying when the player asks for a new
    /// deal (⌘N, Restart) is a win: it is landed and recorded first, quietly —
    /// the player has already moved on, so no "You win!" dialog — rather than
    /// being thrown away with the board, which used to lose the win while
    /// "played" had already counted the deal and leave the streak unbroken
    /// but unextended.
    private func settlePendingWin() {
        guard isViewLoaded else { return }
        isSettlingWin = true
        boardView.finishAutoFinishNow()
        boardView.finishWinAnimationNow()
        isSettlingWin = false
    }

    /// True while `settlePendingWin` lands a cascade.
    private var isSettlingWin = false

    /// A game the player walked away from mid-move still counts as a loss —
    /// otherwise the win rate is whatever the player wants it to be.
    private func countAbandonedGame() {
        guard let current = boardView?.game, current.hasStarted, !current.isWon else { return }
        statistics.recordLoss(drawCount: current.options.drawCount, time: current.elapsed)
        statistics.save()
    }

    /// One move, chosen the way a competent player would, or a fresh deal when
    /// the game is over. Used by `--demo` to generate a realistic load.
    func playOneDemoMove() {
        guard isViewLoaded else { return }
        if game.isWon || game.isStuck {
            startNewGame()
            return
        }
        if let move = game.hint() {
            boardView.perform(move)
        } else if !game.state.stock.isEmpty {
            boardView.perform(.draw(count: game.options.drawCount))
        } else if game.state.canRecycle {
            boardView.perform(.recycle)
        } else {
            startNewGame()
        }
    }

    // MARK: The Solitaire menu

    func makeGameMenu() -> NSMenu {
        let menu = NSMenu(title: Self.info.title)

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0,
                 represented: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.tag = tag
            item.representedObject = represented
            item.target = nil      // the responder chain brings it here
            menu.addItem(item)
            return item
        }

        add(menu, NSLocalizedString("New Game", comment: ""), #selector(newGame(_:)), "n")
        add(menu, NSLocalizedString("Select Deal…", comment: ""), #selector(selectDeal(_:)), "n",
            modifiers: [.command, .shift])
        add(menu, NSLocalizedString("Restart This Deal", comment: ""), #selector(restartDeal(_:)), "r")
        menu.addItem(.separator())
        // Space is handled by the board's `keyDown`, not here: a menu key
        // equivalent would intercept it before any text field could see it.
        add(menu, NSLocalizedString("Turn Over a Card", comment: ""), #selector(drawFromStock(_:)))
        // ⌘H is reserved for Hide, so the hint lives on ⌘/ — and the board also
        // takes a bare H, which is what players reach for.
        add(menu, NSLocalizedString("Hint", comment: ""), #selector(hint(_:)), "/")
        add(menu, NSLocalizedString("Auto-Finish", comment: ""), #selector(autoFinish(_:)), "e")
        menu.addItem(.separator())

        // ⌘1 to ⌘5 open the games, so the two draw modes move over to ⌥⌘.
        add(menu, NSLocalizedString("Draw One Card", comment: ""), #selector(setDrawCount(_:)), "1",
            modifiers: [.command, .option], tag: 1)
        add(menu, NSLocalizedString("Draw Three Cards", comment: ""), #selector(setDrawCount(_:)), "3",
            modifiers: [.command, .option], tag: 3)
        let scoringItem = NSMenuItem(title: NSLocalizedString("Scoring", comment: ""), action: nil,
                                     keyEquivalent: "")
        let scoring = NSMenu(title: scoringItem.title)
        for mode in ScoringMode.allCases {
            add(scoring, mode.localizedName, #selector(setScoring(_:)), represented: mode.rawValue)
        }
        scoringItem.submenu = scoring
        menu.addItem(scoringItem)
        add(menu, NSLocalizedString("Timed Game", comment: ""), #selector(toggleTimed(_:)))
        add(menu, NSLocalizedString("Winnable Deals Only", comment: ""), #selector(toggleWinnableDeals(_:)))
        add(menu, NSLocalizedString("Click Sends Cards to Foundations", comment: ""),
            #selector(toggleClickPrefersFoundation(_:)))
        add(menu, NSLocalizedString("Play Aces and Twos Automatically", comment: ""),
            #selector(toggleAutoPlaySafeCards(_:)))
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Statistics…", comment: ""), #selector(showStatistics(_:)), "s",
            modifiers: [.command, .option])
        return menu
    }

    @objc func newGame(_ sender: Any?) { overlay.dismiss(animated: false); startNewGame() }

    @objc func toggleAutoPlaySafeCards(_ sender: NSMenuItem) {
        preferences.autoPlaySafeCards.toggle()
        preferences.save()
        applyOptionsToCurrentGame()
    }

    @objc func restartDeal(_ sender: Any?) {
        overlay.dismiss(animated: false)
        settlePendingWin()
        boardView.stopWinAnimation()
        game.restart()
        statsCountedThisGame = false
        boardView.replaceGame(game, dealAnimation: true)
        refreshStatus()
    }

    @objc func selectDeal(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Select a Deal", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString("Enter a deal number between %d and %d.", comment: ""),
            DealNumber.range.lowerBound, DealNumber.range.upperBound)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(game.dealNumber)
        field.alignment = .center
        alert.accessoryView = field
        alert.addButton(withTitle: NSLocalizedString("Deal", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              DealNumber.range.contains(number) else {
            NSSound.beep()
            return
        }
        startNewGame(dealNumber: number)
    }

    // Named `undoMove:` and `redoMove:` rather than the obvious `undo:` and
    // `redo:` because NSWindow already implements both, forwarding them to its
    // own NSUndoManager. The window sits in the responder chain after the
    // board, so an action called `undo:` is swallowed there before it can
    // reach anything behind it and silently does nothing — which is exactly
    // what the Undo button once did. See `TabletopUndoable`.
    @objc func undoMove(_ sender: Any?) { overlay.dismiss(); boardView.undo(); refreshStatus() }
    @objc func redoMove(_ sender: Any?) { boardView.redo(); refreshStatus() }
    @objc func hint(_ sender: Any?) { boardView.showHint() }
    @objc func autoFinish(_ sender: Any?) { boardView.autoFinish() }

    @objc func drawFromStock(_ sender: Any?) {
        if !game.state.stock.isEmpty {
            boardView.perform(.draw(count: game.options.drawCount))
        } else if game.state.canRecycle {
            boardView.perform(.recycle)
        }
    }

    @objc func setDrawCount(_ sender: NSMenuItem) {
        changeRules { $0.drawCount = sender.tag }
    }

    @objc func setScoring(_ sender: NSMenuItem) {
        guard let mode = ScoringMode(rawValue: sender.representedObject as? String ?? "") else { return }
        changeRules { $0.scoring = mode }
    }

    @objc func toggleTimed(_ sender: NSMenuItem) {
        changeRules { $0.timed.toggle() }
    }

    @objc func toggleWinnableDeals(_ sender: NSMenuItem) {
        preferences.winnableDealsOnly.toggle()
        preferences.save()
    }

    @objc func toggleClickPrefersFoundation(_ sender: NSMenuItem) {
        preferences.clickPrefersFoundation.toggle()
        preferences.save()
        applyOptionsToCurrentGame()
    }

    @objc func showStatistics(_ sender: Any?) {
        SolitaireStatisticsWindow.show(statistics: statistics) { [weak self] in
            guard let self else { return }
            self.statistics = SolitaireStatistics()
            self.statistics.save()
        }
    }

    /// Rule changes mean a different game, so the player is asked before an
    /// in-progress deal is thrown away.
    private func changeRules(_ mutate: (inout SolitairePreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        guard updated != preferences else { return }

        if game.hasStarted && !game.isWon {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Start a new game?", comment: "")
            alert.informativeText = NSLocalizedString(
                "Changing this setting deals a new game. The current game will be counted as a loss.",
                comment: "")
            alert.addButton(withTitle: NSLocalizedString("New Game", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        preferences = updated
        preferences.save()
        startNewGame()
    }

    /// The cloth, the card backs and the four-colour deck, from the View menu.
    private func applyTheme() {
        guard isViewLoaded else { return }
        boardView.theme = TablePreferences.current.theme
        boardView.needsDisplay = true
    }

    /// Pushes the settings that do not change the cards into the running game.
    /// Anything that would alter the deal goes through `changeRules` instead,
    /// which asks the player first.
    private func applyOptionsToCurrentGame() {
        game.updateLiveOptions(
            clickPrefersFoundation: preferences.clickPrefersFoundation,
            autoPlaySafeCards: preferences.autoPlaySafeCards
        )
        boardView.needsDisplay = true
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard isViewLoaded else { return false }
        switch item.action {
        case #selector(undoMove(_:)): return game.canUndo
        case #selector(redoMove(_:)): return game.canRedo
        case #selector(autoFinish(_:)): return game.canAutoFinish
        case #selector(hint(_:)): return !game.isWon
        case #selector(setDrawCount(_:)):
            item.state = preferences.drawCount == item.tag ? .on : .off
        case #selector(setScoring(_:)):
            item.state = preferences.scoring.rawValue == item.representedObject as? String ? .on : .off
        case #selector(toggleTimed(_:)):
            item.state = preferences.timed ? .on : .off
        case #selector(toggleWinnableDeals(_:)):
            item.state = preferences.winnableDealsOnly ? .on : .off
        case #selector(toggleClickPrefersFoundation(_:)):
            item.state = preferences.clickPrefersFoundation ? .on : .off
        case #selector(toggleAutoPlaySafeCards(_:)):
            item.state = preferences.autoPlaySafeCards ? .on : .off
        default: break
        }
        return true
    }

    // MARK: Board delegate

    func boardViewDidChangeGame(_ view: BoardView) {
        if game.hasStarted && !statsCountedThisGame {
            statsCountedThisGame = true
            statistics.recordStart(drawCount: game.options.drawCount)
            statistics.save()
        }
        if preferences.autoPlaySafeCards, !game.isWon,
           !view.isPerformingSequence, !view.isInteracting,
           let move = game.state.safeAutoPlayMove() {
            DispatchQueue.main.async { [weak view] in
                guard let view, !view.isInteracting, !view.isPerformingSequence else { return }
                view.perform(move)
            }
        }
        refreshStatus()
        saveGame()
        checkForDeadEnd(view)
    }

    /// Tells the player when there is genuinely nothing left to try.
    ///
    /// Worth being careful about: nothing is more irritating than being told
    /// the game is over while a move is still available, so this leans on
    /// `GameState.isStuck`, which walks the whole stock cycle rather than
    /// guessing. It is also deliberately not a modal alert — the player may
    /// want to sit and stare at the position before undoing.
    private func checkForDeadEnd(_ view: BoardView) {
        guard !view.isPerformingSequence, !game.isWon, game.hasStarted else {
            overlay.dismiss()
            return
        }
        guard game.isStuck else {
            overlay.dismiss()
            return
        }
        var actions: [MessageOverlay.Action] = []
        if game.canUndo {
            actions.append(.init(title: NSLocalizedString("Undo", comment: "")) { [weak self] in
                self?.undoMove(nil)
            })
        }
        actions.append(.init(title: NSLocalizedString("New Game", comment: ""), isDefault: true) { [weak self] in
            self?.startNewGame()
        })
        overlay.show(
            title: NSLocalizedString("No moves left", comment: ""),
            body: NSLocalizedString("There is nothing left to play on this deal.", comment: ""),
            actions: actions,
            animated: TabletopEnvironment.animationsEnabled
        )
    }

    func boardView(_ view: BoardView, didFinishWinAnimation: Bool) {
        statistics.recordWin(drawCount: game.options.drawCount, time: game.elapsed,
                             moves: game.moveCount, score: game.displayScore)   // moves in the winning line, not clicks
        statistics.save()
        Storage.remove(Self.savedGameName)
        // A snapshot or a test that wins a deal must not stop to ask the
        // question below: there is nobody there to answer it. Nor must a new
        // deal the player already asked for.
        guard !TabletopEnvironment.isHarness, !isSettlingWin else { return }
        guard isActive else {
            winAwaitingPresentation = true
            return
        }
        presentWin()
    }

    /// Set when a win finished while the game was not in front.
    private var winAwaitingPresentation = false

    private func presentWin() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("You win!", comment: "")
        let seconds = Int(game.elapsed)
        var details = String(
            format: NSLocalizedString("Deal %d finished in %d:%02d with %d moves.", comment: ""),
            game.dealNumber, seconds / 60, seconds % 60, game.moveCount)
        if preferences.scoring != .none {
            details += "\n" + String(format: NSLocalizedString("Final score: %d", comment: ""),
                                     game.displayScore)
        }
        alert.informativeText = details
        alert.addButton(withTitle: NSLocalizedString("New Game", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Close", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            startNewGame()
        }
    }

    // MARK: Status and clock

    /// Runs the elapsed-time readout, and only that.
    ///
    /// The timer exists solely to redraw a label, so it is created only while
    /// there is a running clock and the game is the active screen of a key,
    /// visible window, and it is torn down the moment either goes away. A
    /// repeating timer that ticks forever costs almost no CPU but it does wake
    /// the processor, and wake-ups are what actually drain a battery — a game
    /// left open on a lecture desk should be indistinguishable from a closed
    /// one.
    ///
    /// The generous tolerance matters as much as the interval: it lets macOS
    /// slide this tick onto the back of some other timer that was going to fire
    /// anyway, so most seconds cost no extra wake-up at all.
    private func syncClockTimer() {
        let shouldRun = isActive && isViewLoaded && game.isClockRunning
        if shouldRun {
            guard clockTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    TopBarStatus.set(SolitaireStatus.pills(for: self.game, scoring: self.preferences.scoring),
                                     for: .solitaire)
                }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            clockTimer = timer
        } else {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    private func refreshStatus() {
        guard isViewLoaded else { return }
        TopBarStatus.set(SolitaireStatus.pills(for: game, scoring: preferences.scoring), for: .solitaire)
        actionBar.setActions(SolitaireStatus.actions(
            for: game,
            undo: { [weak self] in self?.undoMove(nil) },
            hint: { [weak self] in self?.hint(nil) },
            finish: { [weak self] in self?.autoFinish(nil) }),
            animated: view.window != nil)
        syncClockTimer()
    }

    // MARK: Saving

    private func saveGame() {
        guard isViewLoaded, !game.isWon else { return }
        Storage.save(game.saved, to: Self.savedGameName)
    }

    private func restoreGame() -> Game? {
        guard let saved = Storage.load(SavedGame.self, from: Self.savedGameName) else { return nil }
        guard saved.state.isConsistent else {
            Storage.remove(Self.savedGameName)
            return nil
        }
        return Game(restoring: saved)
    }

    // MARK: Screenshots

    /// `midgame` is deal 1 with two dozen sensible moves played, the table a
    /// player actually looks at; `opening` is the untouched deal; `late` is a
    /// deal the solver can win, played seven-tenths of the way along its
    /// winning line — deep cascades, most cards turned, foundations well up.
    /// Each can be adjusted with solitaire's own flags, which `--shot
    /// solitaire` has always taken: `--deal N`, `--moves N`, `--draw 1|3`.
    static var screenshotScenarios: [String] { ["midgame", "opening", "late"] }

    func prepareForScreenshot(scenario: String?) {
        loadViewIfNeeded()
        var options = preferences.gameOptions
        if let draw = TabletopEnvironment.value(of: "--draw").flatMap(Int.init), draw == 1 || draw == 3 {
            options.drawCount = draw
        }
        let requestedDeal = TabletopEnvironment.value(of: "--deal").flatMap(Int.init)
        let requestedMoves = TabletopEnvironment.value(of: "--moves").flatMap(Int.init)
        var game: Game
        if scenario == "late" {
            game = Self.lateGame(options: options, deal: requestedDeal, fraction: 0.7)
        } else {
            let deal = requestedDeal ?? 1
            game = Game(dealNumber: deal, options: options)
            // Sensible moves rather than random ones, so the board looks like
            // a game in progress rather than an untouched deal or a scramble.
            // Once the hints only go round in a circle — turning the stock
            // through, moving a card and back — the board comes back to a
            // position it has been in; the game is replayed up to the first
            // time it was there, so "80 moves" on the pill is never 24 moves
            // and a long walk in a circle.
            let moves = requestedMoves ?? (scenario == "opening" ? 0 : 24)
            var positions: [GameState] = [game.state]
            var played: [Move] = []
            for _ in 0..<max(0, moves) {
                guard let move = game.hint(), game.perform(move) != nil else { break }
                if let first = positions.firstIndex(of: game.state) {
                    game = Game(dealNumber: deal, options: options)
                    for earlier in played.prefix(first) { _ = game.perform(earlier) }
                    break
                }
                positions.append(game.state)
                played.append(move)
            }
        }
        game.pauseClock()
        overlay.dismiss(animated: false)
        boardView.replaceGame(game, dealAnimation: false)
        refreshStatus()
    }

    /// The first deal from `deal` (or 1) on that the solver can win, played
    /// `fraction` of the way along its winning line.
    private static func lateGame(options: GameOptions, deal: Int?, fraction: Double) -> Game {
        let first = deal ?? 1
        for number in first..<(first + 40) {
            let state = GameState.deal(number: number, drawCount: options.drawCount, redealLimit: nil)
            let solver = KlondikeSolver(state: state)
            guard solver.isWinnable(), !solver.solution.isEmpty else { continue }
            var unlimited = options
            unlimited.redealLimit = nil       // the solver plays with unlimited passes
            let game = Game(dealNumber: number, options: unlimited)
            for move in solver.solution.prefix(Int(Double(solver.solution.count) * fraction)) {
                guard game.perform(move) != nil else { break }
            }
            return game
        }
        return Game(dealNumber: first, options: options)
    }

    // MARK: Harness

    /// The board, for the self-tests.
    var boardForTesting: BoardView? { isViewLoaded ? boardView : nil }

    // MARK: Library tile

    /// A game under way: the stock, the aces going up, the columns cascading.
    /// See `SolitaireArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        SolitaireArtwork.draw(in: ctx, rect: rect)
    }

    // MARK: Self-tests

    static func runSelfTests(_ t: TestReporter) {
        SolitaireTests.run(t)
        SolitaireLifecycleTests.run(t)
    }
}
