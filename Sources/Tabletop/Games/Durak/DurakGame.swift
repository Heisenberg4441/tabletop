//
//  DurakGame.swift
//  Durak, the Russian game of attack and defence, against one to three
//  computer players.
//
//  The controller ties four things together and owns none of their insides:
//
//    DurakState      the rules (Engine/), one value per position
//    DurakMatch      whose decision it is, bots thinking at a human pace
//    DurakTableView  the cards on the cloth, the seats, clicks and drags
//    DurakSession    the opponents, tonight's tally, the game on disk
//
//  and answers the Durak menu, the New Game card, the end-of-game banner and
//  the shell's lifecycle: bots think only while the game is the active
//  screen, and everything is saved after every move, so quitting mid-bout
//  and coming back carries on from the same card.
//
//  FOR THE LOCALISER — the Russian words these English strings stand for
//  (see also Engine/DurakTypes.swift):
//
//      Durak               «Дурак»         the game, and the loser
//      Podkidnoy           «Подкидной»     the variant with throw-ins
//      Perevodnoy          «Переводной»    the variant with transfers
//      Take                «Беру»          the defender's button
//      Takes               «Берёт»         a seat's status while taking
//      Bito                «Бито»          all beaten, cards to the discard
//      Pass                «Пас»           nothing to throw in
//      Done                «Хватит»        nothing more to pile on
//      Transfer            «Перевести»     perevodnoy's move
//      Trump               «Козырь»
//      Deck                «Колода»
//      Attacking           «Ходит»
//      Defending           «Отбивается»
//      Out                 «Вышел»         no cards left, safe
//      Draw                «Ничья»
//      You are the Durak   «Вы — дурак»
//

import AppKit

final class DurakGame: NSViewController, TabletopGame, NSMenuItemValidation, NSMenuDelegate {

    // MARK: Identity

    static var info: GameInfo {
        GameInfo(
            id: .durak,
            title: NSLocalizedString("Durak", comment: "game title («Дурак»)"),
            subtitle: NSLocalizedString("The classic Russian card game", comment: "durak subtitle"),
            detail: NSLocalizedString("1 player · vs computer", comment: "durak players"),
            symbolName: "suit.club.fill",
            accent: NSColor(srgbRed: 0.278, green: 0.306, blue: 0.451, alpha: 1),
            keyEquivalent: "4"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        Played with thirty-six cards, six through ace. The card turned up at \
        the deal lies under the deck, and its suit is trumps for the whole game. \
        Whoever holds the lowest trump attacks first; after that, the last \
        game's durak defends first.

        • The attacker leads any card. The defender beats it with a higher card \
        of the same suit, or with any trump.
        • The others may throw in cards of any rank already on the table, up to \
        six in a bout (five in the first) and never more than the defender holds.
        • A defender who cannot or will not beat everything says Take and picks \
        the table up. When everything is beaten, the cards go to the bito pile \
        and the defender attacks next.
        • Everyone draws back up to six, attacker first. Once the deck is gone, \
        a player with no cards is out. The last one holding cards is the durak.
        • Perevodnoy: before beating anything, the defender may pass the attack \
        on by adding a card of the same rank.

        Click a card to play it; if it could beat more than one card, click the \
        one to beat. You can also drag cards onto the table, onto a card, or \
        onto the Transfer place. T takes; Return or Space says Bito, Pass or \
        Done. ⌘N starts a new game.
        """, comment: "durak help text")
    }

    // MARK: State

    private var settings: DurakSettings
    private var statistics: DurakStatistics
    private var session: DurakSession?
    private(set) var table: DurakTableView!
    private(set) var match: DurakMatch!
    private var optionsCard: OptionsCard?
    private var endBanner: Banner?
    private var scoreboardView: DurakScoreboardView?
    private var isActive = false
    /// Bumped for every new or restored game, so the prompt and the saved
    /// file notice a new game even at the same move number.
    private var gameSerial = 0
    private var promptKey: [Int]?
    private var savedKey: [Int] = []

    /// Where new deals' seeds come from; the self-tests make it predictable.
    var nextSeed: () -> UInt64 = { UInt64.random(in: 1...UInt64.max) }

    init() {
        settings = DurakSettings.load()
        statistics = DurakStatistics.load()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func loadView() {
        let restored = DurakSession.load()
        let playerCount = restored?.state?.playerCount ?? restored?.playerCount ?? settings.playerCount
        let table = DurakTableView(playerCount: playerCount)
        table.handOrder = settings.handOrder
        self.table = table
        view = table

        match = DurakMatch(scheduler: table.scheduler, difficulty: settings.difficulty)
        match.present = { [weak self] events, state, done in
            self?.table.present(events, final: state, completion: done)
        }
        match.onChange = { [weak self] in self?.matchChanged() }
        table.onAction = { [weak self] action in self?.match.play(action) ?? false }
        table.onLayout = { [weak self] in self?.placeEnd() }
        // Nothing ticks until the game is on screen.
        if !isActive { table.scheduler.suspend() }

        if let restored {
            session = restored
            table.configure(names: [Self.youName] + restored.names)
            table.pileSeed = restored.pileSeed
            if let state = restored.state {
                gameSerial += 1
                table.show(DurakTableSnapshot(state: state))
                match.resume(state)
            }
        }
        if session?.state == nil {
            // The first time: the deck on the cloth and the New Game card.
            presentOptions(cancellable: false, animated: false)
        }
        refreshPills()
    }

    static var youName: String { NSLocalizedString("You", comment: "durak: the player's seat") }

    /// The end of the responder chain for the table's keys. Whatever bare
    /// key the table and its buttons did not want — Space while a bot
    /// thinks, Return with nothing to say, a letter that means nothing here —
    /// stops here rather than walking on to the window, where AppKit answers
    /// an unhandled key with the system alert sound. That sound is exactly
    /// what this app never makes. ⌘, ⌃ and ⌥ keys go on as usual, and so
    /// does Tab, which the window uses to move the keyboard focus.
    override func keyDown(with event: NSEvent) {
        let bare = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if bare && event.keyCode != 48 { return }
        super.keyDown(with: event)
    }

    var preferredFirstResponder: NSView? {
        optionsCard?.isPresented == true ? optionsCard : table
    }

    // MARK: Lifecycle

    func gameDidBecomeActive() {
        isActive = true
        guard isViewLoaded else { return }
        table.scheduler.resume()
        match.release(.inactive)
        // The window puts the pills back as they were posted; the suit's
        // colour goes back on with them.
        DurakTrumpPill.paint(match.state?.trump, in: view.window)
    }

    func gameWillResignActive() {
        isActive = false
        guard isViewLoaded else { return }
        table.scheduler.suspend()
        match.hold(.inactive)
        saveSession(force: true)
    }

    func prepareToQuit() {
        if isViewLoaded { saveSession(force: true) }
        settings.save()
        statistics.save()
    }

    // MARK: New games

    /// Deals the next game at this table, with `newSettings` if given.
    func startNewGame(with newSettings: DurakSettings? = nil) {
        if let newSettings {
            settings = newSettings
            settings.save()
            table.handOrder = settings.handOrder
        }
        // A game that ended while its last moves were still being shown has
        // not been counted yet — the table was about to. It counts now, as
        // it ended: New Game in that second is no way out of being the durak.
        if let state = session?.state, state.isOver { recordResult(state) }
        recordAbandonedGame()
        dismissEnd(animated: false)
        Toast.hide(in: table, animated: false)
        table.scheduler.cancelAll()
        table.cancelPresentation()

        let seed = nextSeed()
        var session = self.session ?? DurakSession(names: DurakSession.pickNames(settings.opponents, seed: seed))
        if session.playerCount != settings.playerCount {
            // A different table: new faces, a fresh tally, and the lowest
            // trump opens again.
            session = DurakSession(names: DurakSession.pickNames(settings.opponents, seed: seed))
        }
        let opening = DurakOpening.following(session.lastResult, playerCount: session.playerCount)
        let game = DurakState.newGame(rules: DurakRules(playerCount: session.playerCount, variant: settings.variant),
                                      seed: seed, opening: opening)
        session.state = game.state
        session.resultRecorded = false
        session.pileSeed = seed
        self.session = session
        gameSerial += 1

        match.difficulty = settings.difficulty
        table.configure(names: [Self.youName] + session.names)
        table.pileSeed = seed
        match.begin(game.state, events: game.events)
        if optionsCard?.isPresented == true { optionsCard?.dismiss(animated: false) }
        match.release(.modal)
        saveSession(force: true)
    }

    /// A game left before its end counts: as a loss while the player still
    /// held cards (otherwise the record is whatever the player wants it to
    /// be), and as an escape if they were already out.
    private func recordAbandonedGame() {
        guard var session, let state = session.state, !state.isOver, !session.resultRecorded,
              state.actionCount > 0 else { return }
        let outcome: DurakOutcome = state.isOut(DurakMatch.human)
            ? .escaped(first: state.outOrder.first == DurakMatch.human) : .durak
        statistics[state.rules.variant].record(outcome)
        statistics.save()
        session.resultRecorded = true
        self.session = session
    }

    private var gameInProgressCounts: Bool {
        guard let state = session?.state else { return false }
        return !state.isOver && state.actionCount > 0 && !state.isOut(DurakMatch.human)
    }

    // MARK: The New Game card

    private func presentOptions(cancellable: Bool, animated: Bool = true) {
        guard optionsCard?.isPresented != true else { return }
        let subtitle = gameInProgressCounts
            ? NSLocalizedString("The game in progress will count as a loss.", comment: "durak new game card")
            : NSLocalizedString("Thirty-six cards. The last player holding cards is the durak.", comment: "durak new game card")
        let card = OptionsCard(
            title: NSLocalizedString("New Game", comment: "durak new game card title"),
            subtitle: subtitle,
            rows: [
                OptionsCard.Row(id: "opponents", title: NSLocalizedString("Opponents", comment: "durak new game card"),
                                options: (1...3).map { String.localizedStringWithFormat("%d", $0) },
                                selectedIndex: settings.opponents - 1),
                OptionsCard.Row(id: "variant", title: NSLocalizedString("Variant", comment: "durak new game card"),
                                options: DurakVariant.allCases.map(\.localizedName),
                                selectedIndex: DurakVariant.allCases.firstIndex(of: settings.variant) ?? 0),
                OptionsCard.Row(id: "difficulty", title: NSLocalizedString("Difficulty", comment: "durak new game card"),
                                options: DurakDifficulty.allCases.map(\.localizedName),
                                selectedIndex: DurakDifficulty.allCases.firstIndex(of: settings.difficulty) ?? 1),
            ],
            startTitle: NSLocalizedString("Deal", comment: "durak new game card: start"))
        card.onStart = { [weak self] choice in
            guard let self else { return }
            var chosen = self.settings
            chosen.opponents = (choice["opponents"] ?? 1) + 1
            chosen.variant = DurakVariant.allCases[safe: choice["variant"] ?? 0] ?? .podkidnoy
            chosen.difficulty = DurakDifficulty.allCases[safe: choice["difficulty"] ?? 1] ?? .normal
            self.startNewGame(with: chosen)
        }
        if cancellable {
            card.onCancel = { [weak self] in self?.match.release(.modal) }
        }
        optionsCard = card
        match.hold(.modal)
        card.present(in: table, animated: animated && table.window != nil)
    }

    // MARK: Following the match

    private func matchChanged() {
        guard isViewLoaded, let match else { return }
        let state = match.state
        // The ring moves on when the table has caught up, not while the last
        // move is still being shown.
        table.activeSeat = match.isPresenting ? nil : state.flatMap { $0.isOver ? nil : $0.actor }
        table.thinkingSeat = match.thinkingSeat
        let awaiting = match.isAwaitingHuman
        let key = awaiting ? state.map { [gameSerial, $0.actionCount] } : nil
        if key != promptKey {
            promptKey = key
            table.prompt = awaiting ? state.map { DurakPrompt(state: $0) } : nil
        }
        refreshActions()
        refreshPills()
        saveSession(force: false)
        if let state, state.isOver, !match.isPresenting {
            gameEnded(state)
        }
    }

    private func refreshActions() {
        let bar = table.actionBar
        var actions: [ChromeAction] = []
        if let state = match.state, !state.isOver, !state.isOut(DurakMatch.human) {
            let awaiting = match.isAwaitingHuman
            if state.defender == DurakMatch.human {
                actions.append(ChromeAction(
                    id: "take", title: NSLocalizedString("Take", comment: "durak button: pick the cards up («Беру»)"),
                    symbolName: "tray.and.arrow.down", keyEquivalent: "t",
                    isEnabled: awaiting && state.phase == .defend) { [weak self] in
                        _ = self?.match.play(.take)
                    })
                if awaiting, let prompt = table.prompt, prompt.canTransfer {
                    actions.append(ChromeAction(
                        id: "transfer", title: NSLocalizedString("Transfer", comment: "durak button («Перевести»)"),
                        symbolName: "arrow.turn.up.right") { [weak self] in self?.transferWithBestCard() })
                }
            } else if awaiting, let kind = state.passKind(for: DurakMatch.human) {
                let title: String
                switch kind {
                case .bito: title = NSLocalizedString("Bito", comment: "durak button: everything is beaten («Бито»)")
                case .pass: title = NSLocalizedString("Pass", comment: "durak button: nothing to throw in («Пас»)")
                case .done: title = NSLocalizedString("Done", comment: "durak button: nothing more to pile on («Хватит»)")
                }
                actions.append(ChromeAction(id: "pass", title: title, style: .primary, keyEquivalent: "\r") { [weak self] in
                    _ = self?.match.play(.pass)
                })
            }
        }
        let animated = table.window != nil && Motion.isEnabled
        if actions.isEmpty {
            barWanted = false
            guard !bar.isHidden else { return }
            // No keys or clicks while it fades.
            for action in bar.actions { bar.setEnabled(false, for: action.id) }
            let hide = { [weak self] in
                guard self?.barWanted == false else { return }
                bar.isHidden = true
                bar.setActions([], animated: false)
            }
            if animated {
                Motion.animate(duration: Motion.quick, { bar.animator().alphaValue = 0 }, completion: hide)
            } else {
                hide()
            }
        } else {
            barWanted = true
            let wasHidden = bar.isHidden || bar.alphaValue < 1
            bar.setActions(actions, animated: animated && !wasHidden)
            if wasHidden {
                bar.isHidden = false
                if animated {
                    Motion.animate(duration: Motion.standard) { bar.animator().alphaValue = 1 }
                } else {
                    bar.alphaValue = 1
                }
            }
        }
    }

    /// Whether the action bar should be showing; a fade-out that finishes
    /// after the bar was wanted again leaves it alone.
    private var barWanted = false

    private func transferWithBestCard() {
        guard let action = table.prompt?.bestTransfer else { return }
        match.play(action)
    }

    private func refreshPills() {
        var items: [StatusPillItem] = []
        if let state = match?.state {
            items.append(DurakTrumpPill.item(for: state.trump, emphasized: state.bout == 0 && !state.isOver))
            if state.stockCount > 0 {
                // "Deck 12" is a label and its number, not a counted noun.
                items.append(StatusPillItem(
                    id: "deck", text: String.localizedStringWithFormat(
                        NSLocalizedString("Deck %d", comment: "durak pill: cards left in the deck («Колода»)"), state.stockCount),
                    symbolName: "rectangle.stack.fill"))
            }
            items.append(StatusPillItem(id: "variant", text: state.rules.variant.localizedName,
                                        symbolName: state.rules.variant == .perevodnoy ? "arrow.turn.up.right" : "plus.rectangle.on.rectangle"))
        }
        TopBarStatus.set(items, for: .durak)
        DurakTrumpPill.paint(match?.state?.trump, in: view.window)
    }

    // MARK: The end of a game

    private func gameEnded(_ state: DurakState) {
        recordResult(state)
        showEnd(state, animated: table.window != nil)
    }

    /// Counts a finished game — the statistics, tonight's tally, who defends
    /// first next time — exactly once, however it is reached.
    private func recordResult(_ state: DurakState) {
        guard var session, let result = state.result, !session.resultRecorded else { return }
        statistics[state.rules.variant].record(result.outcome(for: DurakMatch.human, outOrder: state.outOrder))
        statistics.save()
        session.scoreboard.record(result)
        session.lastResult = result
        session.resultRecorded = true
        self.session = session
        saveSession(force: true)
    }

    private func showEnd(_ state: DurakState, animated: Bool) {
        guard endBanner == nil, let session, let result = state.result else { return }
        let names = [Self.youName] + session.names
        let title: String
        var subtitle = ""
        let symbol: String
        let tone: Banner.Tone
        switch result {
        case .durak(let loser) where loser == DurakMatch.human:
            title = NSLocalizedString("You are the Durak", comment: "durak end banner («Вы — дурак»)")
            if let first = state.outOrder.first, names.indices.contains(first) {
                subtitle = String(format: NSLocalizedString("%@ went out first.", comment: "durak end banner"), names[first])
            }
            symbol = "xmark.seal"
            tone = .loss
        case .durak(let loser):
            let loserName = names.indices.contains(loser) ? names[loser] : ""
            title = String(format: NSLocalizedString("%@ is the Durak", comment: "durak end banner: the loser's name"), loserName)
            subtitle = state.outOrder.first == DurakMatch.human
                ? NSLocalizedString("You're out — and you went out first.", comment: "durak end banner")
                : NSLocalizedString("You're out — you got rid of all your cards.", comment: "durak end banner")
            symbol = "checkmark.seal"
            tone = .win
        case .draw:
            title = NSLocalizedString("Draw", comment: "durak end banner («Ничья»)")
            subtitle = NSLocalizedString("The last cards went together — nobody is the Durak.", comment: "durak end banner")
            symbol = "equal.circle"
            tone = .neutral
        }
        let again = ChromeAction(id: "again", title: NSLocalizedString("New Game", comment: "durak end banner button"),
                                 style: .primary, keyEquivalent: "\r") { [weak self] in self?.startNewGame() }
        let banner = Banner.show(in: table, title: title, subtitle: subtitle, symbolName: symbol, tone: tone,
                                 actions: [again], scheduler: table.scheduler, verticalPosition: 0.34)
        endBanner = banner
        banner.onDismiss = { [weak self] in self?.dismissEnd(animated: true) }

        let loser: Int? = { if case .durak(let s) = result { return s } else { return nil } }()
        let board = DurakScoreboardView(names: names, scoreboard: session.scoreboard, loser: loser)
        // Placed with the banner by `placeEnd`, on every layout: nothing
        // about the two may be left to their own autoresizing, which moves
        // each by its own margins until they drift apart.
        board.autoresizingMask = []
        table.addSubview(board)
        scoreboardView = board
        placeEnd()
        if animated && !board.isHidden { Motion.present(board, spring: .gentle, from: 0.96, rise: 10) }
    }

    /// The end banner and the scoreboard, as one group on clear cloth: off
    /// the durak's turned-up hand, your own, the pile and the seats. Runs
    /// whenever the table is laid out — a resize, full screen, a finished
    /// game restored into a window of another size.
    private func placeEnd() {
        guard let banner = endBanner, banner.superview === table else { return }
        let layout = table.layoutModel
        let area = layout.play.insetBy(dx: 10, dy: 4)
        let boardSize = scoreboardView?.frame.size ?? .zero
        let placement = DurakEndPlacement.place(banner: banner.frame.size, board: boardSize, in: area,
                                                avoiding: table.endObstacles, middle: layout.battleCenter.y)
        banner.frame.origin = placement.banner.origin
        if let board = scoreboardView {
            if let frame = placement.board {
                board.frame.origin = frame.origin
                board.isHidden = false
            } else {
                board.isHidden = true
            }
        }
    }

    /// The end panels' frames, for the self-tests.
    var endFramesForTesting: (banner: CGRect?, board: CGRect?) {
        (endBanner?.frame, scoreboardView.flatMap { $0.isHidden ? nil : $0.frame })
    }

    private func dismissEnd(animated: Bool) {
        if let endBanner {
            self.endBanner = nil
            endBanner.dismiss(animated: animated, notify: false)
        }
        if let board = scoreboardView {
            scoreboardView = nil
            if animated && Motion.isEnabled {
                Motion.dismiss(board) { board.removeFromSuperview() }
            } else {
                board.removeFromSuperview()
            }
        }
    }

    // MARK: Saving

    private func saveSession(force: Bool) {
        guard var session else { return }
        session.state = match?.state ?? session.state
        self.session = session
        let key = [gameSerial, session.state?.actionCount ?? -1, session.resultRecorded ? 1 : 0]
        guard force || key != savedKey else { return }
        savedKey = key
        session.save()
    }

    // MARK: The Durak menu

    func makeGameMenu() -> NSMenu {
        let menu = NSMenu(title: Self.info.title)

        @discardableResult
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.tag = tag
            item.target = nil      // the responder chain brings it here
            menu.addItem(item)
            return item
        }

        add(menu, NSLocalizedString("New Game…", comment: "durak menu"), #selector(newGame(_:)), "n")
        menu.addItem(.separator())
        // The table's own keys (T, Return, Space) are not repeated here: a
        // bare-key menu item would take them from the table's buttons.
        add(menu, NSLocalizedString("Take", comment: "durak menu («Беру»)"), #selector(takeCards(_:)))
        add(menu, NSLocalizedString("Bito", comment: "durak menu («Бито»)"), #selector(passTurn(_:)))
        add(menu, NSLocalizedString("Transfer", comment: "durak menu («Перевести»)"), #selector(transferAttack(_:)))
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Sort by Suit", comment: "durak menu"), #selector(sortHand(_:)), tag: 0)
        add(menu, NSLocalizedString("Sort by Rank", comment: "durak menu"), #selector(sortHand(_:)), tag: 1)
        menu.addItem(.separator())
        let scoreboardItem = NSMenuItem(title: NSLocalizedString("Scoreboard", comment: "durak menu: this session's tally"),
                                        action: nil, keyEquivalent: "")
        let scoreboard = NSMenu(title: scoreboardItem.title)
        scoreboard.delegate = self
        scoreboardItem.submenu = scoreboard
        menu.addItem(scoreboardItem)
        add(menu, NSLocalizedString("Statistics…", comment: "durak menu"), #selector(showStatistics(_:)), "s",
            modifiers: [.command, .option])
        return menu
    }

    @objc func newGame(_ sender: Any?) {
        presentOptions(cancellable: session?.state != nil)
    }

    @objc func takeCards(_ sender: Any?) { match.play(.take) }
    @objc func passTurn(_ sender: Any?) { match.play(.pass) }
    @objc func transferAttack(_ sender: Any?) { transferWithBestCard() }

    @objc func sortHand(_ sender: NSMenuItem) {
        settings.handOrder = sender.tag == 1 ? .byRank : .bySuit
        settings.save()
        table.handOrder = settings.handOrder
    }

    @objc func showStatistics(_ sender: Any?) {
        DurakStatisticsWindow.show(statistics: statistics) { [weak self] in
            self?.statistics = DurakStatistics()
            self?.statistics.save()
        }
    }

    /// The Scoreboard submenu: tonight's tally, as plain lines.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let session else {
            menu.addItem(NSMenuItem(title: NSLocalizedString("No games yet", comment: "durak scoreboard menu"),
                                    action: nil, keyEquivalent: ""))
            return
        }
        let names = [Self.youName] + session.names
        for (seat, name) in names.enumerated() {
            let times = session.scoreboard.durakCounts[safe: seat] ?? 0
            let line = Plural.format(times, one: String(format: NSLocalizedString("%@ — durak %%d time", comment: "durak scoreboard menu line"), name),
                                     other: String(format: NSLocalizedString("%@ — durak %%d times", comment: "durak scoreboard menu line"), name))
            menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let games = Plural.format(session.scoreboard.games, one: NSLocalizedString("%d game", comment: "durak scoreboard"),
                                  other: NSLocalizedString("%d games", comment: "durak scoreboard"))
        let draws = Plural.format(session.scoreboard.draws, one: NSLocalizedString("%d draw", comment: "durak scoreboard"),
                                  other: NSLocalizedString("%d draws", comment: "durak scoreboard"))
        menu.addItem(NSMenuItem(title: String(format: NSLocalizedString("%@ · %@", comment: "durak scoreboard: games · draws"),
                                              games, draws), action: nil, keyEquivalent: ""))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard isViewLoaded, let match else { return false }
        let state = match.state
        let awaiting = match.isAwaitingHuman
        switch item.action {
        case #selector(takeCards(_:)):
            return awaiting && state?.phase == .defend
        case #selector(passTurn(_:)):
            switch state.flatMap({ awaiting ? $0.passKind(for: DurakMatch.human) : nil }) {
            case .pass?: item.title = NSLocalizedString("Pass", comment: "durak menu («Пас»)")
            case .done?: item.title = NSLocalizedString("Done", comment: "durak menu («Хватит»)")
            default: item.title = NSLocalizedString("Bito", comment: "durak menu («Бито»)")
            }
            return awaiting && state?.passKind(for: DurakMatch.human) != nil
        case #selector(transferAttack(_:)):
            item.isHidden = (state?.rules.variant ?? settings.variant) != .perevodnoy
            return awaiting && table.prompt?.canTransfer == true
        case #selector(sortHand(_:)):
            item.state = (item.tag == 1) == (settings.handOrder == .byRank) ? .on : .off
            return true
        case #selector(newGame(_:)):
            return optionsCard?.isPresented != true
        default:
            return true
        }
    }

    // MARK: Screenshots

    static var screenshotScenarios: [String] { DurakScenario.names }

    func prepareForScreenshot(scenario: String?) {
        loadViewIfNeeded()
        if scenario == "options" {
            // The first launch: the deck on the cloth, the New Game card.
            optionsCard?.dismiss(animated: false)
            match.clear()
            session = nil
            table.configure(names: DurakTableView.placeholderNames(settings.playerCount))
            table.show(DurakTableSnapshot(emptyTable: settings.playerCount))
            refreshPills()
            presentOptions(cancellable: false, animated: false)
            view.layoutSubtreeIfNeeded()
            return
        }
        guard let scenario = DurakScenario.make(scenario ?? "attack") else { return }
        var session = DurakSession(names: Array(scenario.names.dropFirst()))
        session.scoreboard = scenario.scoreboard
        session.resultRecorded = true
        session.pileSeed = scenario.state.seed
        install(scenario.state, session: session)
        if let reveal = scenario.reveal { table.holdReveal(reveal.seat, reveal.card) }
        if let card = scenario.select { table.click(card.durakIndex) }
        if let toast = scenario.toast {
            table.toast(toast.text, symbol: toast.symbol,
                        tint: scenario.reveal.map { $0.card.suit.durakTint } ?? Palette.textSecondary)
        }
        view.layoutSubtreeIfNeeded()
    }

    /// Puts `state` on the table as the game in progress, laid out at once —
    /// for the screenshots and the self-tests. Nothing is recorded.
    func install(_ state: DurakState, session newSession: DurakSession) {
        loadViewIfNeeded()
        optionsCard?.dismiss(animated: false)
        match.release(.modal)
        dismissEnd(animated: false)
        table.scheduler.cancelAll()
        var session = newSession
        session.state = state
        self.session = session
        gameSerial += 1
        table.configure(names: [Self.youName] + session.names)
        table.pileSeed = session.pileSeed
        table.show(DurakTableSnapshot(state: state))
        match.resume(state)
    }

    // MARK: Library tile

    /// The deck with the trump across it, a beaten attack, the hand below. See `DurakArtwork`.
    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        DurakArtwork.draw(in: ctx, rect: rect)
    }

    // MARK: Self-tests

    static func runSelfTests(_ t: TestReporter) {
        DurakTests.run(t)
    }

    // MARK: Harness

    /// The saved session, for the self-tests.
    var sessionForTesting: DurakSession? { session }
    var statisticsForTesting: DurakStatistics { statistics }
    var isOptionsCardUp: Bool { optionsCard?.isPresented == true }
    var endBannerForTesting: Banner? { endBanner }
}
