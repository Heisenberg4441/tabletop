//
//  TabletopWindowController.swift
//  The one window: which screen is in it, how it gets there, and who is told.
//
//  The app has a single window. It opens on the library; picking a game swaps
//  that game's view in, and the Library button (or ⌘0) swaps the library back.
//  Each game's controller is made the first time it is opened and then kept
//  for the whole session, so walking away to the library and coming back finds
//  the cards exactly where they were.
//
//  The other half of the job is telling the game in front what is happening to
//  the window, because the energy rules depend on it: a game may only run a
//  clock or a render loop while it is the active screen of a key, visible
//  window. Key changes, occlusion, minimising and screen changes all funnel
//  into `syncActivation()`, which is the only place `gameDidBecomeActive` and
//  `gameWillResignActive` are called, and which keeps them strictly balanced.
//

import AppKit
import QuartzCore

final class TabletopWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    enum Screen: Equatable {
        case library
        case game(GameID)
    }

    private(set) var screen: Screen = .library
    let library = LibraryViewController()

    /// Every game opened this session, kept alive so going back resumes it.
    private var games: [GameID: any TabletopGame] = [:]
    /// Each game's own menu, made once and reinstalled whenever it is in front.
    private var gameMenus: [GameID: NSMenu] = [:]
    /// True between `gameDidBecomeActive` and `gameWillResignActive` of the
    /// game in front. The balance of those two calls hangs on this flag.
    private var activeGameIsRunning = false
    private var hasPreparedToQuit = false
    /// Bumped by every screen change, so the tidy-up of a crossfade that has
    /// been overtaken by a newer one knows to leave the views alone.
    private var transitionGeneration = 0

    private let rootView = TabletopRootView()
    private let screenHost = NSView()
    private let edgeShade = WindowEdgeShadeView()
    private let chrome = WindowChromeView()
    private let titleView = ChromeTitleView()
    private let pillRow = StatusPillRow()
    private let libraryButton = CapsuleButton(
        title: NSLocalizedString("Library", comment: "button returning to the game library"),
        symbolName: "chevron.left", style: .secondary, size: .small)
    private var statusObserver: NSObjectProtocol?

    /// The Library button's identifier, for the harness to find it by.
    static let libraryButtonIdentifier = NSUserInterfaceItemIdentifier("tabletop.library")

    static let defaultContentSize = NSSize(width: 1200, height: 800)
    static let minimumContentSize = NSSize(width: 960, height: 640)
    private static let windowStateFile = "window.json"

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = NSLocalizedString("Tabletop", comment: "window title in the library")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // An empty toolbar in the compact unified style, for its height alone:
        // it makes the titlebar strip 38 points and centres the traffic
        // lights in it, which leaves the Library capsule and the status pills
        // (28 points) a proper margin above and below — without it the strip
        // is 28–32 points and the capsules touch the top edge. It holds no
        // items and draws nothing; the strip's contents are the window's own
        // views (see `layoutChrome`), which AppKit passes clicks through to.
        let toolbar = NSToolbar(identifier: "tabletop.window")
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        // Tables are dark, lamp-lit things, and the chrome floating over them
        // is dark glass whatever the system appearance is — light-mode glass
        // over green baize looks like a sticker.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = TabletopRootView.roomColor
        window.contentMinSize = Self.minimumContentSize
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // A card dragged across the felt must never drag the window with it.
        window.isMovableByWindowBackground = false

        super.init(window: window)
        window.delegate = self

        rootView.frame = NSRect(origin: .zero, size: Self.defaultContentSize)
        screenHost.frame = rootView.bounds
        screenHost.autoresizingMask = [.width, .height]
        rootView.addSubview(screenHost)

        edgeShade.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(edgeShade)
        chrome.passThrough = screenHost
        chrome.autoresizingMask = [.width, .minYMargin]
        rootView.addSubview(chrome)
        titleView.isHidden = true
        chrome.addSubview(titleView)
        chrome.addSubview(pillRow)
        libraryButton.handler = { [weak self] in self?.showLibrary(nil) }
        libraryButton.identifier = Self.libraryButtonIdentifier
        libraryButton.toolTip = NSLocalizedString("Back to the library (⌘0)", comment: "Library button tooltip")
        libraryButton.isHidden = true
        libraryButton.translatesAutoresizingMaskIntoConstraints = true
        chrome.addSubview(libraryButton)

        rootView.onLayout = { [weak self] in self?.layoutChrome() }
        window.contentView = rootView

        library.onOpen = { [weak self] id in self?.show(.game(id), animated: true) }
        statusObserver = NotificationCenter.default.addObserver(
            forName: TopBarStatus.didChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, case .game(let id) = self.screen, (note.object as? GameID) == id else { return }
                self.pillRow.setItems(TopBarStatus.items(for: id), animated: true)
                self.layoutChrome()
            }
        }
        install(library, animated: false)
        restoreWindowFrame(window)
        layoutChrome()
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    // MARK: Screens

    /// The game controller for `id`, made now if this is the first time.
    func game(for id: GameID) -> any TabletopGame {
        if let existing = games[id] { return existing }
        let made = GameCatalog.type(for: id).init()
        games[id] = made
        return made
    }

    /// The game controller for `id` if the player has opened it this session.
    func existingGame(_ id: GameID) -> (any TabletopGame)? { games[id] }

    /// Every game made this session, for the harness.
    var openedGames: [any TabletopGame] { GameID.allCases.compactMap { games[$0] } }

    private var currentController: NSViewController {
        switch screen {
        case .library: return library
        case .game(let id): return game(for: id)
        }
    }

    /// Brings `target` to the front: the game in front stops, the new screen
    /// crossfades in, the menu bar and the chrome follow, and the keyboard
    /// goes to the new screen at once.
    func show(_ target: Screen, animated: Bool) {
        guard target != screen else {
            focusCurrentScreen()
            return
        }
        // Everything that ticks stops before anything moves.
        deactivateActiveGame()
        screen = target
        let incoming = currentController
        install(incoming, animated: animated)

        switch target {
        case .library:
            window?.title = NSLocalizedString("Tabletop", comment: "window title in the library")
            libraryButton.isHidden = true
            titleView.isHidden = true
            pillRow.setItems([], animated: false)
        case .game(let id):
            window?.title = GameCatalog.info(for: id).title
            libraryButton.isHidden = false
            titleView.title = GameCatalog.info(for: id).title
            titleView.isHidden = false
            pillRow.setItems(TopBarStatus.items(for: id), animated: false)
        }
        updateGameMenu()
        layoutChrome()
        focusCurrentScreen()
        syncActivation()
    }

    /// Swaps the view in, over the top of whatever is there, and fades the
    /// old one out from under it.
    ///
    /// A short crossfade with the new screen settling from a hair smaller,
    /// on the same critically damped feel as the rest of the chrome. The
    /// animations touch only the presentation — the views' model geometry
    /// is AppKit's, and is never fought over. Under Reduce Motion the swap is
    /// instant.
    private func install(_ controller: NSViewController, animated: Bool) {
        let incoming = controller.view
        let outgoing = screenHost.subviews.filter { $0 !== incoming }
        transitionGeneration &+= 1
        let generation = transitionGeneration

        incoming.translatesAutoresizingMaskIntoConstraints = true
        incoming.autoresizingMask = [.width, .height]
        incoming.frame = screenHost.bounds
        incoming.wantsLayer = true
        incoming.layer?.removeAnimation(forKey: Self.fadeKey)
        incoming.layer?.removeAnimation(forKey: Self.scaleKey)
        screenHost.addSubview(incoming)       // on top, even if it was already there
        incoming.layoutSubtreeIfNeeded()

        let tidy = { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            for view in outgoing where view !== incoming {
                view.layer?.removeAnimation(forKey: Self.fadeKey)
                view.layer?.removeAnimation(forKey: Self.scaleKey)
                view.removeFromSuperview()
            }
        }
        guard animated, TabletopEnvironment.animationsEnabled, !outgoing.isEmpty,
              let incomingLayer = incoming.layer else {
            tidy()
            return
        }

        let duration: CFTimeInterval = 0.30
        let curve = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.26, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock(tidy)

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = duration
        fadeIn.timingFunction = curve
        incomingLayer.add(fadeIn, forKey: Self.fadeKey)

        let settle = CABasicAnimation(keyPath: "transform")
        settle.fromValue = NSValue(caTransform3D: Self.scale(0.985, about: incoming.bounds))
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        settle.duration = duration
        settle.timingFunction = curve
        incomingLayer.add(settle, forKey: Self.scaleKey)

        for view in outgoing {
            guard let layer = view.layer else { continue }
            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = layer.presentation()?.opacity ?? 1
            fadeOut.toValue = 0
            fadeOut.duration = duration * 0.8
            fadeOut.timingFunction = curve
            fadeOut.fillMode = .forwards
            fadeOut.isRemovedOnCompletion = false
            layer.add(fadeOut, forKey: Self.fadeKey)
        }
        CATransaction.commit()
    }

    private static let fadeKey = "tabletop.screenFade"
    private static let scaleKey = "tabletop.screenScale"

    /// A scale about the middle of `bounds`, for a view's layer — which
    /// AppKit anchors at its corner, not its centre.
    private static func scale(_ s: CGFloat, about bounds: CGRect) -> CATransform3D {
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    /// Gives the keyboard to the screen in front: to an options card the game
    /// left up when the player went away, if there is one — it is modal, and
    /// its arrows and Return are what the player needs — and otherwise to the
    /// game's `preferredFirstResponder`.
    private func focusCurrentScreen() {
        guard let window else { return }
        let screenView = currentController.view
        if let card = OptionsCard.presentedCards.first(where: { $0.isDescendant(of: screenView) }),
           window.makeFirstResponder(card) {
            return
        }
        let preferred: NSView?
        switch screen {
        case .library: preferred = library.preferredFirstResponder
        case .game(let id): preferred = game(for: id).preferredFirstResponder
        }
        if let preferred, window.makeFirstResponder(preferred) { return }
        window.makeFirstResponder(screenView)
    }

    // MARK: Menus

    private func updateGameMenu() {
        guard let main = NSApp.mainMenu else { return }
        switch screen {
        case .library:
            MainMenu.installGameMenu(nil, title: "", in: main)
        case .game(let id):
            let menu: NSMenu
            if let made = gameMenus[id] {
                menu = made
            } else {
                menu = game(for: id).makeGameMenu()
                gameMenus[id] = menu
            }
            MainMenu.installGameMenu(menu, title: GameCatalog.info(for: id).title, in: main)
        }
    }

    /// The menu a game made, once it has been shown. For the harness.
    func gameMenu(for id: GameID) -> NSMenu? { gameMenus[id] }

    @objc func showLibrary(_ sender: Any?) {
        show(.library, animated: true)
    }

    @objc func openGame(_ sender: Any?) {
        let raw = (sender as? NSMenuItem)?.representedObject as? String ?? ""
        guard let id = GameID(rawValue: raw) else { return }
        show(.game(id), animated: true)
    }

    /// Help ▸ How to Play: the rules of the game in front, or of the library
    /// itself. A sheet, so the table stays in view behind it.
    @objc func showHowToPlay(_ sender: Any?) {
        let alert = NSAlert()
        switch screen {
        case .library:
            alert.messageText = NSLocalizedString("Welcome to Tabletop", comment: "library help title")
            alert.informativeText = NSLocalizedString("""
            A collection of classic table games: pool, poker, blackjack, durak \
            and solitaire.

            • Click a game to sit down at it, or choose it with the arrow keys \
            and press Return.
            • ⌘1 to ⌘5 open a game from anywhere, and ⌘0 or the Library button \
            brings you back here. Every game waits exactly where you left it.
            • The View menu dresses every table at once: the colour of the \
            cloth, the backs of the cards, a four-colour deck. Sound is off \
            until you turn it on there.
            """, comment: "library help text")
        case .game(let id):
            let type = GameCatalog.type(for: id)
            alert.messageText = String(format: NSLocalizedString("How to Play %@", comment: "help title"),
                                       type.info.title)
            alert.informativeText = type.howToPlay
        }
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showLibrary(_:)):
            item.state = screen == .library ? .on : .off
        case #selector(openGame(_:)):
            let raw = item.representedObject as? String ?? ""
            item.state = screen == GameID(rawValue: raw).map(Screen.game) ? .on : .off
        case #selector(showHowToPlay(_:)):
            switch screen {
            case .library:
                item.title = NSLocalizedString("Tabletop Help", comment: "help menu item in the library")
            case .game(let id):
                item.title = String(format: NSLocalizedString("How to Play %@", comment: "help menu item"),
                                    GameCatalog.info(for: id).title)
            }
            return window?.attachedSheet == nil
        default:
            break
        }
        return true
    }

    // MARK: Chrome

    /// Puts the strip along the top and the Library button beside the traffic
    /// lights — measured from the lights themselves rather than assumed, since
    /// their size and spacing change between macOS versions. In full screen
    /// the lights are gone and the button moves into the corner.
    private func layoutChrome() {
        guard let window else { return }
        let bounds = rootView.bounds
        let band = TabletopChrome.topInset(for: rootView)
        chrome.frame = CGRect(x: 0, y: bounds.height - band, width: bounds.width, height: band)
        let shade = band + WindowEdgeShadeView.overhang
        edgeShade.frame = CGRect(x: 0, y: bounds.height - shade, width: bounds.width, height: shade)

        let size = libraryButton.intrinsicContentSize
        var x: CGFloat = 12
        var midY = band / 2
        if !window.styleMask.contains(.fullScreen),
           let zoom = window.standardWindowButton(.zoomButton), zoom.window === window, !zoom.isHidden {
            let lights = chrome.convert(zoom.convert(zoom.bounds, to: nil), from: nil)
            x = lights.maxX + 14
            midY = lights.midY
        }
        libraryButton.frame = CGRect(x: x.rounded(), y: (midY - size.height / 2).rounded(),
                                     width: size.width, height: size.height)

        // The pills stand 16 points in from the right edge; the title sits in
        // the middle of the window, or — if the pills reach that far — in the
        // middle of what is left between the button and them.
        let pills = pillRow.intrinsicContentSize
        pillRow.frame = CGRect(x: (bounds.width - 16 - pills.width).rounded(),
                               y: (midY - pills.height / 2).rounded(), width: pills.width, height: pills.height)
        let titleWidth = min(360, titleView.label.intrinsicContentSize.width + 24)
        var titleX = (bounds.width - titleWidth) / 2
        let leftLimit = libraryButton.frame.maxX + 12
        let rightLimit = pills.width > 0 ? pillRow.frame.minX - 12 : bounds.width - 12
        if titleX < leftLimit || titleX + titleWidth > rightLimit {
            titleX = leftLimit + max(0, (rightLimit - leftLimit - titleWidth) / 2)
        }
        titleView.frame = CGRect(x: titleX.rounded(), y: (midY - 10).rounded(),
                                 width: max(0, min(titleWidth, rightLimit - titleX)), height: 20)
    }

    /// For `--shot`: the chrome as it would sit over `screen`, drawn over a
    /// snapshot of it, so a screenshot shows where the Library button lands.
    /// The edge shade goes down first, then the strip's contents.
    func renderChrome(into ctx: CGContext, size: CGSize) {
        layoutChrome()
        for view in [edgeShade as NSView, chrome] {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        CATransaction.flush()
        for view in [edgeShade as NSView, chrome] {
            guard let layer = view.layer ?? { view.wantsLayer = true; return view.layer }() else { continue }
            ctx.saveGState()
            // Both sit at the top of an unflipped root view; the bitmap's
            // origin is at the bottom, so they go up by the rest of the window.
            ctx.translateBy(x: view.frame.minX, y: view.frame.minY)
            layer.render(in: ctx)
            ctx.restoreGState()
        }
    }

    // MARK: Activation

    /// For the harness: stands in for "the window is key and visible", which
    /// a window that is never put on screen can never be. Nil in the app.
    var assumeWindowIsKeyForTesting: Bool? {
        didSet { syncActivation() }
    }

    /// Every start ("+pool") and stop ("-pool") of a game, in order, while the
    /// harness runs — so `--controls` can check they pair up.
    private(set) var activationLog: [String] = []

    /// Whether the game in front should be running right now.
    private var gameShouldBeActive: Bool {
        guard case .game = screen, !hasPreparedToQuit, let window else { return false }
        if let assumed = assumeWindowIsKeyForTesting { return assumed }
        return window.isVisible && window.isKeyWindow && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    private func log(_ started: Bool, _ id: GameID) {
        guard TabletopEnvironment.isHarness else { return }
        activationLog.append((started ? "+" : "-") + id.rawValue)
    }

    /// The one place a game is started or stopped. Idempotent: calling it
    /// twice changes nothing the second time, so every window notification
    /// can simply call it.
    private func syncActivation() {
        guard case .game(let id) = screen, let game = games[id] else { return }
        let wanted = gameShouldBeActive
        if wanted && !activeGameIsRunning {
            activeGameIsRunning = true
            log(true, id)
            game.gameDidBecomeActive()
        } else if !wanted && activeGameIsRunning {
            activeGameIsRunning = false
            log(false, id)
            game.gameWillResignActive()
        }
    }

    private func deactivateActiveGame() {
        guard activeGameIsRunning, case .game(let id) = screen, let game = games[id] else { return }
        activeGameIsRunning = false
        log(false, id)
        game.gameWillResignActive()
    }

    // MARK: Unhandled keys

    /// A key nobody wanted ends here, at the end of the window's responder
    /// chain, and AppKit's answer to it is the system alert sound. That is a
    /// sharp transient straight into the ear — exactly the kind of sound this
    /// app never makes — so a stray letter on any screen is simply ignored.
    /// Only key events are silenced; everything else keeps AppKit's behaviour.
    override func noResponder(for eventSelector: Selector) {
        if eventSelector == #selector(NSResponder.keyDown(with:)) { return }
        super.noResponder(for: eventSelector)
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) { syncActivation() }
    func windowDidResignKey(_ notification: Notification) { syncActivation() }
    func windowDidChangeOcclusionState(_ notification: Notification) { syncActivation() }
    func windowDidMiniaturize(_ notification: Notification) { syncActivation() }
    func windowDidDeminiaturize(_ notification: Notification) { syncActivation() }
    func windowDidEnterFullScreen(_ notification: Notification) { layoutChrome() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutChrome() }

    func windowWillClose(_ notification: Notification) {
        prepareToQuit()
    }

    /// Saves everything, once: every game that was opened this session, and
    /// where the window was. Called on window close and again on quit, which
    /// in this app follow each other, so the second call does nothing.
    func prepareToQuit() {
        guard !hasPreparedToQuit else { return }
        deactivateActiveGame()
        hasPreparedToQuit = true
        for game in openedGames { game.prepareToQuit() }
        if let window {
            Storage.save(WindowState(frame: NSStringFromRect(window.frame)), to: Self.windowStateFile)
        }
    }

    // MARK: Window frame

    private struct WindowState: Codable {
        var frame: String?
    }

    /// The solitaire-only app kept its window frame in its preferences file.
    private struct LegacyWindowState: Decodable {
        var windowFrame: String?
    }

    private func savedFrame() -> String? {
        if let state = Storage.load(WindowState.self, from: Self.windowStateFile) {
            return state.frame
        }
        return Storage.load(LegacyWindowState.self, from: TablePreferences.legacyFileName)?.windowFrame
    }

    /// Puts the window back where the player left it — but only if that place
    /// still exists. Displays get unplugged, resolutions change, and a frame
    /// restored blindly can land the window entirely off-screen where the only
    /// way to reach it is to delete a preferences file.
    private func restoreWindowFrame(_ window: NSWindow) {
        guard let saved = savedFrame() else {
            window.center()
            return
        }
        var frame = NSRectFromString(saved)
        guard frame.width > 200, frame.height > 200 else {
            window.center()
            return
        }
        // Never smaller than the table needs, whatever an older build allowed.
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumContentSize))
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        // Shrink to fit if the screen it lands on is smaller than it used to be.
        let screens = NSScreen.screens
        let landing = screens.max(by: {
            $0.visibleFrame.intersection(frame).coveredArea < $1.visibleFrame.intersection(frame).coveredArea
        })
        guard let landing, landing.visibleFrame.intersection(frame).coveredArea > frame.coveredArea * 0.35 else {
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
}

private extension CGRect {
    /// Zero for the null rect `intersection` returns when there is no overlap.
    var coveredArea: CGFloat { isNull || isEmpty ? 0 : width * height }
}
