//
//  PoolGame.swift
//  Pool, as one game in the collection: a nine-foot table in SceneKit, you
//  against the computer at eight-ball or nine-ball, or on your own.
//
//  This file is the game's face to the shell — identity, lifecycle, the
//  Pool menu, the New Game card, saving, screenshots — and holds every
//  piece of state. The rest lives in extensions beside it:
//
//    PoolGame+Play          the turn: aiming, striking, the shot rolling
//                           out, the rules' verdict, the computer's turn
//    PoolGame+Presentation  the camera, the cue and the guides, the HUD
//    PoolGame+Input         the mouse and the keyboard
//
//  The engine (Engine/) is authoritative about everything on the cloth; the
//  game only asks it what happens and shows it.
//

import AppKit
import SceneKit
import simd

final class PoolGame: NSViewController, TabletopGame, NSMenuItemValidation {

    // MARK: Identity

    static var info: GameInfo {
        GameInfo(
            id: .pool,
            title: NSLocalizedString("Pool", comment: "game title"),
            subtitle: NSLocalizedString("Eight-ball and nine-ball on a full-size table", comment: "pool subtitle"),
            detail: NSLocalizedString("1 player · vs computer", comment: "pool players"),
            symbolName: "8.circle.fill",
            accent: NSColor(srgbRed: 0.090, green: 0.420, blue: 0.470, alpha: 1),
            keyEquivalent: "1"
        )
    }

    static var howToPlay: String {
        NSLocalizedString("""
        You play the computer at eight-ball or nine-ball, or practise on your own.

        • Eight-ball: after the break, the first ball you pot decides your group — solids or stripes. Pot all of your group, then the eight, to win. Pot the eight early, or on a foul, and you lose.
        • Nine-ball: always hit the lowest ball first. Pot the nine on a legal shot — even in a combination — to win.
        • A foul — the cue ball in a pocket, the wrong ball first, nothing hit, or nothing reaching a cushion — gives your opponent ball in hand: they may place the cue ball anywhere.

        Aim by dragging across the table: sideways turns the cue, up and down raises or lowers your view. Hold Shift for fine aim, or nudge with ← and →. Scroll or pinch to move closer.

        Shoot by pressing the power meter on the left and pulling down, then letting go — or hold Space and release. Escape calls a shot off. Return shoots at the strength shown.

        The cue ball on the right sets spin: above centre for follow, below for draw, either side for english. T switches to the view from above, where a click aims at that spot. With ball in hand, drag the cue ball where you want it.
        """, comment: "pool help text")
    }

    // MARK: State

    /// Where the turn is.
    enum Phase: Equatable {
        /// The player is lining up (with ball in hand, if the rules gave it).
        case aiming
        /// The player is drawing the cue back.
        case charging
        /// The cue is going through; the shot is being worked out.
        case striking
        /// The shot is playing out on the cloth.
        case rolling
        /// The computer is making up its mind.
        case thinking
        /// The computer is lining up and playing its shot.
        case computerLining
        /// The game is over; the result is up.
        case over
    }

    enum ViewMode { case aim, top }

    enum Drag {
        case none
        /// Turning the aim and tilting the view.
        case orbit
        /// Top view: the aim follows the pointer.
        case aimAtPointer
        /// Ball in hand: carrying the cue ball.
        case placing
    }

    enum ChargeSource { case meter, keyboard }

    /// A shot that has been struck and is playing out, with the rules'
    /// verdict already known.
    struct Playback {
        var result: PoolShotResult
        var outcome: PoolTurnOutcome
        var time: Double
        var duration: Double
    }

    var match: PoolMatch
    var statistics: PoolStatistics
    /// The choices the New Game card opens with: the last ones started.
    var options: PoolOptions

    var phase: Phase = .aiming
    var viewMode: ViewMode = .aim
    var aim = 0.0
    var tipSide = 0.0
    var tipVertical = 0.0
    /// The strength Shoot and Return use, and the meter shows at rest.
    var armedPower = 0.62
    var chargePower = 0.0
    var chargeSource: ChargeSource?
    /// The aim view's tilt and distance, which the player adjusts.
    var aimPitch = 0.30
    var aimDistance = 1.05
    var drag: Drag = .none
    var rig = PoolCameraRig(PoolCameraPose(focus: [0, 0, 0], yaw: 0, pitch: .pi / 2, distance: 3.4, fieldOfView: 36))
    /// How far the cue is drawn back from the ball right now.
    var cuePull = 0.0
    var cueVisible = true
    var tweens: [PoolTween] = []
    var playback: Playback?
    /// A struck shot waiting for its simulation, or for the stroke to land.
    var pendingResult: PoolShotResult?
    var strokeLanded = false
    /// Bumped by every new game, so nothing from an old one (a decision, a
    /// simulation, a scheduled step) lands in the new one.
    var generation = 0
    var decision: PoolAIDecision?
    var thinkingTimeUp = false
    /// Everything runs to completion at once: while a snapshot is taken, and
    /// in the self-tests. No background work, no frames, no waiting.
    var runsSynchronously = TabletopEnvironment.isRenderingSnapshot
    var isActive = false
    var ballInHandBadge: TableBadge?
    /// Frames still to draw after a change made at rest.
    var redrawFrames = 0
    /// Where the last drag event was, in the scene view.
    var dragLast: CGPoint = .zero
    /// The last place a dragged cue ball was allowed to be.
    var dragValidSpot: SIMD2<Double>?

    // Views.
    var root: PoolRootView!
    var sceneView: PoolSceneView!
    var table: PoolTableScene!
    let actionBar = ActionBar()
    var youPlate: PoolPlayerPlate!
    var computerPlate: PoolPlayerPlate!
    let powerMeter = PoolPowerMeter()
    let spinControl = PoolSpinControl()
    let vignette = PoolVignetteView()
    let scheduler = TableScheduler()
    var clock: PoolFrameClock!
    var optionsCard: OptionsCard?
    private var preferencesObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    static let savedGameName = Storage.fileName("game.json", for: .pool)
    static let optionsName = Storage.fileName("options.json", for: .pool)

    init() {
        let options = Storage.load(PoolOptions.self, from: Self.optionsName) ?? PoolOptions()
        self.options = options
        statistics = PoolStatistics.load()
        if let saved = Storage.load(PoolSavedGame.self, from: Self.savedGameName), saved.isPlausible {
            match = saved.match
            aim = saved.aim
        } else {
            let seed = Self.freshSeed()
            match = PoolMatch.start(options, seed: seed, breaker: PoolSeat.you, opponentName: Self.opponentName(seed: seed))
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }

    static func freshSeed() -> UInt64 {
        TabletopEnvironment.isHarness ? 0x9001 : UInt64.random(in: 1...UInt64.max)
    }

    static func opponentName(seed: UInt64) -> String {
        BotRoster.pick(1, seed: seed).first ?? BotRosterFallback.name
    }

    // MARK: Views

    override func loadView() {
        root = PoolRootView()
        table = PoolTableScene(cloth: TablePreferences.current.table)
        sceneView = PoolSceneView(scene: table.scene)
        sceneView.pointOfView = table.cameraNode
        sceneView.input = self
        // Upload the textures and geometry in the background now, so the
        // first frame the player sees does not wait for them.
        if !TabletopEnvironment.isHarness { sceneView.prepare([table.scene], completionHandler: nil) }
        root.addSubview(sceneView)
        root.addSubview(vignette)

        youPlate = PoolPlayerPlate(name: NSLocalizedString("You", comment: "pool: the player"),
                                   avatar: .symbol("person.fill"), side: .leading)
        computerPlate = PoolPlayerPlate(name: match.opponentName, avatar: .initials, side: .trailing)
        root.addSubview(youPlate)
        root.addSubview(computerPlate)

        powerMeter.onBegin = { [weak self] in self?.beginCharge(.meter) }
        powerMeter.onChange = { [weak self] power in self?.updateCharge(power) }
        powerMeter.onEnd = { [weak self] shoot in self?.endCharge(shoot: shoot) }
        root.addSubview(powerMeter)
        spinControl.onChange = { [weak self] side, vertical in self?.setSpin(side: side, vertical: vertical) }
        root.addSubview(spinControl)

        actionBar.bottomMargin = Spacing.l
        actionBar.install(in: root)
        root.onLayout = { [weak self] in self?.layoutHUD() }
        view = root

        clock = PoolFrameClock(view: sceneView)
        clock.onFrame = { [weak self] dt in self?.frame(dt) ?? false }
        clock.onRunningChanged = { [weak self] running in self?.sceneView.isPlaying = running }

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: TablePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.table.setCloth(TablePreferences.current.table)
                self.redraw()
            }
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if !Motion.isEnabled { self?.settleDecorations() } }
        }

        table.apply(table: match.table)
        powerMeter.armedPower = armedPower
        // Nothing scheduled may run before the game is actually in front:
        // the scheduler starts held, and `gameDidBecomeActive` lets it go.
        if !runsSynchronously { scheduler.suspend() }
        resumeTurn()
    }

    var preferredFirstResponder: NSView? { sceneView }

    // MARK: Lifecycle

    func gameDidBecomeActive() {
        isActive = true
        guard isViewLoaded else { return }
        scheduler.resume()
        clock.isAllowed = !runsSynchronously
        // Anything that was moving when the player left carries on.
        if needsFrames { clock.request() }
        // A decision that came back while the game was away is played now.
        if phase == .thinking { resumeComputerTurn() }
        refreshHUD()
    }

    func gameWillResignActive() {
        isActive = false
        guard isViewLoaded else { return }
        // Everything that ticks stops here: the frame clock (the shot, the
        // camera, the cue), the scheduler (the computer's pause for thought,
        // the beat between turns), and a pull on the cue is called off.
        clock.isAllowed = false
        scheduler.suspend()
        if phase == .charging { cancelCharge() }
        drag = .none
        save()
    }

    func prepareToQuit() {
        guard isViewLoaded else { save(); return }
        // A shot still rolling is played out, so its result — a win, a
        // record run — is kept.
        finishPlaybackNow()
        save()
    }

    // MARK: The Pool menu

    func makeGameMenu() -> NSMenu {
        let menu = NSMenu(title: Self.info.title)
        func add(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                 tag: Int = 0, to target: NSMenu? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
            item.tag = tag
            item.target = nil            // the responder chain brings it here
            (target ?? menu).addItem(item)
        }
        add(NSLocalizedString("New Game…", comment: "pool menu"), #selector(newGame(_:)), "n")
        add(NSLocalizedString("Rematch", comment: "pool menu: same game again"), #selector(rematch(_:)), "r")
        menu.addItem(.separator())
        add(NSLocalizedString("Top View", comment: "pool menu"), #selector(toggleTopView(_:)), "t")
        add(NSLocalizedString("Reset Spin", comment: "pool menu"), #selector(resetSpin(_:)))
        let guidesItem = NSMenuItem(title: NSLocalizedString("Aiming Guides", comment: "pool menu"), action: nil,
                                    keyEquivalent: "")
        let guides = NSMenu(title: guidesItem.title)
        for (i, length) in PoolGuideLength.allCases.enumerated() {
            add(length.title, #selector(setGuides(_:)), tag: i, to: guides)
        }
        guidesItem.submenu = guides
        menu.addItem(guidesItem)
        menu.addItem(.separator())
        add(NSLocalizedString("Statistics…", comment: "pool menu"), #selector(showStatistics(_:)))
        return menu
    }

    @objc func newGame(_ sender: Any?) { presentOptions() }

    @objc func rematch(_ sender: Any?) {
        startNewGame(match.options, breaker: match.isPractice ? PoolSeat.you : 1 - match.breaker)
    }

    @objc func toggleTopView(_ sender: Any?) { setViewMode(viewMode == .top ? .aim : .top) }

    @objc func resetSpin(_ sender: Any?) { setSpin(side: 0, vertical: 0) }

    @objc func setGuides(_ sender: NSMenuItem) {
        guard let length = PoolGuideLength.allCases[safe: sender.tag] else { return }
        match.options.guides = length
        options.guides = length
        Storage.save(options, to: Self.optionsName)
        refreshAim()
    }

    @objc func showStatistics(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Pool Statistics", comment: "pool statistics title")
        var lines: [String] = []
        for difficulty in PoolDifficulty.allCases {
            let games = statistics.games(difficulty), wins = statistics.wins(difficulty)
            let played = Plural.format(games, one: NSLocalizedString("%d game", comment: "pool statistics, one game"),
                                       other: NSLocalizedString("%d games", comment: "pool statistics, games"))
            let won = Plural.format(wins, one: NSLocalizedString("%d win", comment: "pool statistics, one win"),
                                    other: NSLocalizedString("%d wins", comment: "pool statistics, wins"))
            lines.append(String(format: NSLocalizedString("%1$@: %2$@, %3$@", comment: "pool statistics: difficulty: games, wins"),
                                PoolEngineText.difficulty(difficulty), played, won))
        }
        let run = Plural.format(statistics.bestRun, one: NSLocalizedString("%d ball", comment: "pool: one ball"),
                                other: NSLocalizedString("%d balls", comment: "pool: balls"))
        lines.append(String(format: NSLocalizedString("Best eight-ball run: %@", comment: "pool statistics"), run))
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.runModal()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard isViewLoaded else { return false }
        switch item.action {
        case #selector(rematch(_:)):
            item.title = match.isPractice ? NSLocalizedString("Re-rack", comment: "pool menu: practice rack again")
                : NSLocalizedString("Rematch", comment: "pool menu: same game again")
            return optionsCard?.isPresented != true
        case #selector(toggleTopView(_:)):
            item.state = viewMode == .top ? .on : .off
            return true
        case #selector(resetSpin(_:)):
            return isPlayersTurn && (tipSide != 0 || tipVertical != 0)
        case #selector(setGuides(_:)):
            item.state = PoolGuideLength.allCases[safe: item.tag] == match.options.guides ? .on : .off
        default: break
        }
        return true
    }

    // MARK: New games

    func presentOptions() {
        guard isViewLoaded else { return }
        if let card = optionsCard, card.isPresented { return }
        let modes: [PoolMode] = [.eightBall, .nineBall, .practice]
        let card = OptionsCard(
            title: NSLocalizedString("New Game", comment: "options card title"),
            subtitle: NSLocalizedString("You play the computer — or practise on your own.", comment: "pool options subtitle"),
            rows: [
                OptionsCard.Row(id: "mode", title: NSLocalizedString("Game", comment: "pool options row"),
                                options: modes.map(PoolEngineText.mode),
                                selectedIndex: modes.firstIndex(of: options.mode) ?? 0),
                OptionsCard.Row(id: "difficulty", title: NSLocalizedString("Difficulty", comment: "pool options row"),
                                options: PoolDifficulty.allCases.map(PoolEngineText.difficulty),
                                selectedIndex: PoolDifficulty.allCases.firstIndex(of: options.difficulty) ?? 1),
                OptionsCard.Row(id: "guides", title: NSLocalizedString("Aiming guides", comment: "pool options row"),
                                options: PoolGuideLength.allCases.map(\.title),
                                selectedIndex: PoolGuideLength.allCases.firstIndex(of: options.guides) ?? 0),
            ])
        card.onStart = { [weak self] chosen in
            guard let self else { return }
            var picked = self.options
            picked.mode = modes[safe: chosen["mode"] ?? 0] ?? .eightBall
            picked.difficulty = PoolDifficulty.allCases[safe: chosen["difficulty"] ?? 1] ?? .medium
            picked.guides = PoolGuideLength.allCases[safe: chosen["guides"] ?? 0] ?? .long
            self.startNewGame(picked, breaker: PoolSeat.you)
        }
        card.onCancel = { [weak self] in self?.view.window?.makeFirstResponder(self?.sceneView) }
        optionsCard = card
        if phase == .charging { cancelCharge() }
        card.present(in: root, animated: view.window != nil)
    }

    /// Racks a new game with `options`, `breaker` to break. A game against
    /// the computer that was under way counts as lost.
    func startNewGame(_ options: PoolOptions, breaker: Int) {
        countAbandonedGame()
        self.options = options
        Storage.save(options, to: Self.optionsName)
        generation += 1
        scheduler.cancelAll()
        Banner.dismissAll(in: root)
        Toast.hide(in: root, animated: false)
        TableBadge.hideAll(in: root)
        ballInHandBadge = nil
        tweens.removeAll()
        playback = nil
        pendingResult = nil
        decision = nil
        powerMeter.cancel()
        chargeSource = nil
        drag = .none
        let seed = Self.freshSeed() &+ UInt64(generation)
        match = PoolMatch.start(options, seed: seed, breaker: breaker, opponentName: Self.opponentName(seed: seed))
        computerPlate.seat.name = match.opponentName
        tipSide = 0
        tipVertical = 0
        spinControl.set(side: 0, vertical: 0)
        table.apply(table: match.table)
        aim = defaultAim()
        save()
        beginTurn(announce: true)
    }

    private func countAbandonedGame() {
        guard !match.isPractice, !match.isOver, match.rules.shotCount > 0 else { return }
        statistics.record(win: false, difficulty: match.options.difficulty)
        statistics.save()
    }

    // MARK: Saving

    func save() {
        var saved = match
        // A shot still playing out is saved as it will end.
        if let playback { _ = saved.apply(playback.outcome, result: playback.result) }
        if saved.isOver {
            Storage.remove(Self.savedGameName)
        } else {
            Storage.save(PoolSavedGame(saved, aim: aim), to: Self.savedGameName)
        }
    }

    // MARK: Screenshots

    static var screenshotScenarios: [String] { ["break", "aim", "top", "ballInHand", "result", "rolling"] }

    func prepareForScreenshot(scenario: String?) {
        loadViewIfNeeded()
        runsSynchronously = true
        clock.isAllowed = false
        view.layoutSubtreeIfNeeded()
        PoolScenarios.prepare(self, scenario: scenario ?? Self.screenshotScenarios[0])
        view.layoutSubtreeIfNeeded()
    }

    func snapshotImage(size: CGSize) -> CGImage? {
        guard isViewLoaded else { return nil }
        view.layoutSubtreeIfNeeded()
        applyCamera()
        let scale: CGFloat = 2
        guard let scene = sceneView.renderImage(scale: scale),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return LayerSnapshot.image(of: view, size: size, scale: scale) }
        // The room behind everything, and the scene where its view sits
        // (below the window's strip; the context is bottom-up).
        ctx.setFillColor(Palette.room.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let f = sceneView.frame
        ctx.draw(scene, in: CGRect(x: f.minX * scale, y: (size.height - f.maxY) * scale,
                                   width: f.width * scale, height: f.height * scale))
        guard let underlay = ctx.makeImage() else { return nil }
        return LayerSnapshot.image(of: view, size: size, scale: scale, underlay: underlay)
    }

    // MARK: Library tile

    static func drawArtwork(in ctx: CGContext, rect: CGRect) {
        PoolArtwork.draw(in: ctx, rect: rect)
    }

    // MARK: Self-tests

    static func runSelfTests(_ t: TestReporter) {
        PoolTests.run(t)
    }
}

/// The room's darkness closing in at the edges of the picture — drawn as
/// a view over the scene rather than by the camera, so the screen and a
/// snapshot show the same thing. Takes no clicks.
final class PoolVignetteView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let gradient = AppleStyle.gradient([(NSColor(white: 0, alpha: 0), 0.55), (NSColor(white: 0, alpha: 0.16), 0.8),
                                                  (NSColor(white: 0, alpha: 0.42), 1)]) else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY * 0.96)
        let r = hypot(bounds.width, bounds.height) / 2
        ctx.saveGState()
        // An ellipse the shape of the view, not a circle.
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: 1, y: bounds.height / max(1, bounds.width) * 1.25)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

/// The game's root: flipped, no background of its own (the scene paints the
/// room, and a snapshot's underlay must show through), laid out by the game.
final class PoolRootView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}
