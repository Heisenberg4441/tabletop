//
//  GameWindowController.swift
//  Owns the window, the board and the game, and answers every menu command.
//

import AppKit

final class GameWindowController: NSWindowController, NSWindowDelegate, BoardViewDelegate, NSMenuItemValidation {

    private(set) var preferences: Preferences
    private var statistics: Statistics
    private var boardView: BoardView!
    private var statusBar: StatusBar!
    private var overlay: MessageOverlay!
    private var clockTimer: Timer?
    private var statsCountedThisGame = false
    private var dealGenerator = DealGenerator()

    private static let savedGameName = "current-game.json"

    init(preferences: Preferences) {
        self.preferences = preferences
        self.statistics = Statistics.load()
        Sound.isEnabled = preferences.soundEnabled

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("Solitaire", comment: "window title")
        // Sized from the worst case rather than by eye: the tallest column a
        // legal game can produce is 6 face-down plus a full 13-card run, and at
        // this width the fan still has room to show every rank.
        window.minSize = NSSize(width: 720, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        let game = restoreGame() ?? newGameInstance()
        boardView = BoardView(game: game, theme: preferences.theme)
        boardView.brainrot = preferences.brainrot
        boardView.delegate = self
        BrainrotAudio.isEnabled = preferences.brainrot && preferences.brainrotMusic
        boardView.translatesAutoresizingMaskIntoConstraints = false

        statusBar = StatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        overlay = MessageOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(boardView)
        content.addSubview(overlay)
        content.addSubview(statusBar)
        window.contentView = content

        NSLayoutConstraint.activate([
            boardView.topAnchor.constraint(equalTo: content.topAnchor),
            boardView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            boardView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            boardView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            overlay.topAnchor.constraint(equalTo: boardView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: boardView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: boardView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: boardView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: StatusBar.height),
        ])

        restoreWindowFrame(window)

        refreshStatus()
        syncClockTimer()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var game: Game { boardView.game }

    /// Puts the window back where the player left it — but only if that place
    /// still exists. Displays get unplugged, resolutions change, and a frame
    /// restored blindly can land the window entirely off-screen where the only
    /// way to reach it is to delete a preferences file.
    private func restoreWindowFrame(_ window: NSWindow) {
        guard let saved = preferences.windowFrame else {
            window.center()
            return
        }
        var frame = NSRectFromString(saved)
        guard frame.width > 200, frame.height > 200 else {
            window.center()
            return
        }
        // Shrink to fit if the screen it lands on is smaller than it used to be.
        let screens = NSScreen.screens
        let landing = screens.max(by: {
            $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area
        })
        guard let landing, landing.visibleFrame.intersection(frame).area > frame.area * 0.35 else {
            window.center()
            return
        }
        let visible = landing.visibleFrame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
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
        countAbandonedGame()
        let game = newGameInstance(dealNumber: dealNumber)
        statsCountedThisGame = false
        boardView.replaceGame(game, dealAnimation: true)
        refreshStatus()
    }

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

    // MARK: Menu actions

    @objc func newGame(_ sender: Any?) { overlay.dismiss(animated: false); startNewGame() }

    @objc func toggleAutoPlaySafeCards(_ sender: NSMenuItem) {
        preferences.autoPlaySafeCards.toggle()
        preferences.save()
        applyOptionsToCurrentGame()
    }

    @objc func restartDeal(_ sender: Any?) {
        overlay.dismiss(animated: false)
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
    // own NSUndoManager. The window sits in the responder chain between the
    // board and this controller, so an action called `undo:` is swallowed there
    // and silently does nothing — which is exactly what the Undo button did.
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

    @objc func toggleSound(_ sender: NSMenuItem) {
        preferences.soundEnabled.toggle()
        Sound.isEnabled = preferences.soundEnabled
        preferences.save()
    }

    /// Purely a display setting, so it takes effect at once and does not go
    /// through `changeRules`: the deal, the score and the rules are untouched
    /// by it, and being asked to start a new game to turn fireworks on would
    /// be a strange thing to be asked.
    @objc func toggleBrainrot(_ sender: NSMenuItem) {
        preferences.brainrot.toggle()
        preferences.save()
        boardView.brainrot = preferences.brainrot
        applyBrainrotMusic()
    }

    /// The soundtrack. Only ever plays with the mode on: the music is part of
    /// the joke, not a media player, and leaving it running over a quiet board
    /// would be the worst of both.
    @objc func toggleBrainrotMusic(_ sender: NSMenuItem) {
        preferences.brainrotMusic.toggle()
        preferences.save()
        applyBrainrotMusic()
    }

    private func applyBrainrotMusic() {
        let wanted = preferences.brainrot && preferences.brainrotMusic
        BrainrotAudio.isEnabled = wanted
        if wanted {
            BrainrotAudio.start()
        } else {
            BrainrotAudio.stop()
        }
    }

    /// Apple mode. Display-only, like the card back and the felt, so it takes
    /// effect on the board in front of the player rather than asking for a new
    /// deal first.
    @objc func toggleAppleMode(_ sender: NSMenuItem) {
        preferences.apple.toggle()
        applyTheme()
    }

    @objc func toggleFourColorDeck(_ sender: NSMenuItem) {
        preferences.fourColorDeck.toggle()
        applyTheme()
    }

    @objc func setTableColor(_ sender: NSMenuItem) {
        guard let color = TableColor(rawValue: sender.representedObject as? String ?? "") else { return }
        preferences.table = color
        applyTheme()
    }

    @objc func setCardBackStyle(_ sender: NSMenuItem) {
        guard let style = CardBackStyle(rawValue: sender.representedObject as? String ?? "") else { return }
        preferences.backStyle = style
        applyTheme()
    }

    @objc func setCardBackColor(_ sender: NSMenuItem) {
        guard let color = CardBackColor(rawValue: sender.representedObject as? String ?? "") else { return }
        preferences.backColor = color
        applyTheme()
    }

    @objc func showStatistics(_ sender: Any?) {
        StatisticsWindow.show(statistics: statistics) { [weak self] in
            guard let self else { return }
            self.statistics = Statistics()
            self.statistics.save()
        }
    }

    /// Rule changes mean a different game, so the player is asked before an
    /// in-progress deal is thrown away.
    private func changeRules(_ mutate: (inout Preferences) -> Void) {
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

    private func applyTheme() {
        preferences.save()
        boardView.theme = preferences.theme
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
        case #selector(toggleSound(_:)):
            item.state = preferences.soundEnabled ? .on : .off
        case #selector(toggleFourColorDeck(_:)):
            item.state = preferences.fourColorDeck ? .on : .off
        case #selector(toggleAppleMode(_:)):
            item.state = preferences.apple ? .on : .off
        case #selector(toggleBrainrot(_:)):
            item.state = preferences.brainrot ? .on : .off
        case #selector(toggleBrainrotMusic(_:)):
            item.state = preferences.brainrotMusic ? .on : .off
            // Meaningless on its own, so it greys out until the mode is on.
            return preferences.brainrot
        case #selector(setTableColor(_:)):
            item.state = preferences.table.rawValue == item.representedObject as? String ? .on : .off
        case #selector(setCardBackStyle(_:)):
            item.state = preferences.backStyle.rawValue == item.representedObject as? String ? .on : .off
        case #selector(setCardBackColor(_:)):
            item.state = preferences.backColor.rawValue == item.representedObject as? String ? .on : .off
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
            actions: actions
        )
    }

    func boardView(_ view: BoardView, didFinishWinAnimation: Bool) {
        statistics.recordWin(drawCount: game.options.drawCount, time: game.elapsed,
                             moves: game.moveCount, score: game.displayScore)   // moves in the winning line, not clicks
        statistics.save()
        Storage.remove(Self.savedGameName)
        presentWin()
    }

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
    /// there is a running clock and a visible window to draw into, and it is
    /// torn down the moment either goes away. A repeating timer that ticks
    /// forever costs almost no CPU but it does wake the processor, and wake-ups
    /// are what actually drain a battery — a game left open on a lecture desk
    /// should be indistinguishable from a closed one.
    ///
    /// The generous tolerance matters as much as the interval: it lets macOS
    /// slide this tick onto the back of some other timer that was going to fire
    /// anyway, so most seconds cost no extra wake-up at all.
    private func syncClockTimer() {
        let shouldRun = game.isClockRunning
            && (window?.occlusionState.contains(.visible) ?? false)
        if shouldRun {
            guard clockTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.statusBar.update(game: self.game, scoringMode: self.preferences.scoring)
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
        statusBar.update(game: game, scoringMode: preferences.scoring)
        syncClockTimer()
    }

    // MARK: Saving

    private func saveGame() {
        guard !game.isWon else { return }
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

    // MARK: Window delegate

    func windowDidResignKey(_ notification: Notification) {
        game.pauseClock()
        syncClockTimer()
        // Dubstep out of a window the player has clicked away from is the
        // behaviour of malware, not of a card game.
        BrainrotAudio.stop()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if game.hasStarted && !game.isWon { game.startClock() }
        syncClockTimer()
        applyBrainrotMusic()
    }

    /// Covered by another window, or minimised: stop drawing a clock nobody can
    /// see. The game clock itself keeps running — the player has not stopped
    /// playing just because something is in front of the window.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        syncClockTimer()
    }

    func windowWillClose(_ notification: Notification) {
        prepareToQuit()
    }

    func prepareToQuit() {
        game.pauseClock()
        BrainrotAudio.stop()
        saveGame()
        if let window {
            preferences.windowFrame = NSStringFromRect(window.frame)
        }
        preferences.save()
        statistics.save()
    }
}
