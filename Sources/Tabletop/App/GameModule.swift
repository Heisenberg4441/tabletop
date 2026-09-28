//
//  GameModule.swift
//  The contract between the Tabletop shell and the games that live in it.
//
//  READ THIS FIRST if you are adding or building a game. Everything the shell
//  knows about a game is on this page; everything a game may rely on from the
//  shell is on this page too. Neither side reaches past it.
//
//  THE SHAPE OF A GAME
//
//  A game is one `NSViewController` subclass conforming to `TabletopGame`,
//  plus whatever it needs, all inside `Sources/Tabletop/Games/<Name>/`. The
//  shell creates the controller the first time the player opens the game,
//  keeps it alive for the rest of the session — going back to the library and
//  returning resumes exactly where the player was — and swaps its view in and
//  out of the one window. Register it in `GameCatalog.type(for:)`.
//
//  The shared pieces a game may use, all in `Kit/`. `Tabletop --shot kit
//  out.png` renders every one of them on one table, and `--shot kit --scenario
//  poker|blackjack|durak` a sample table composed from nothing but the kit —
//  look at those before building anything of your own.
//
//    Cards       `Card`, `Suit`, `Rank` (the deck, no rules), `DeterministicRNG`,
//                `CardRenderer` and `CardLayer` (printed cards, rasterised once,
//                moved by the compositor; a resting turn and scale that compose
//                with the flip and the pick-up).
//    Surfaces    `AppleStyle` (felt, wood, slots, varnish), `TableArt` (cards,
//                chips, pool balls and cloth for a still life — cover art),
//                `Theme` and `TablePreferences` (the View menu's choices).
//    Design      `Design.swift`: `Typography`, `Palette`, `Spacing`, `Radius`,
//                `ControlHeight`, `Elevation`, `ContinuousShape`, `Motion` (durations,
//                critically damped springs, the one animations switch),
//                `Haptics`.
//    Chrome      `GlassPanel`, `CapsuleButton` + `ChromeAction`, `ActionBar`,
//                `BetControl`, `OptionsCard` + `SegmentedChoice`, `Banner`,
//                `Toast`, `TableBadge` (a label pinned to a point on the
//                table, as many as you like), and `TopBarStatus` for pills
//                in the window's strip.
//    Table       `CardTableView` (the base class for a card table: painted
//                table, sprites by id, hit testing, drags, hover, scheduler),
//                `TableShape` / `TableGeometry` / `TableSurface` (rectangle,
//                poker oval, blackjack half-moon), `TableLayout` + `CardPose`
//                (fans, rows, decks, the trump, discard piles, durak pairs),
//                `CardSizePolicy`, `TableScheduler`.
//    Chips       `Chips` (breakdown, formatting), `ChipStyle`, `ChipRenderer`,
//                `ChipStackLayer`, `ChipFlight`, `ChipRackView` (click chips
//                to build a bet).
//    Seats       `SeatView`, `AvatarRenderer`, `BotRoster`.
//    Plumbing    `Sound` (the existing card sounds, off by default), `Storage`
//                (JSON files in Application Support), `TestReporter`,
//                `LayerSnapshot`, `Plural` (counted words), `Array[safe:]`.
//
//  RULES OF THE HOUSE
//
//  * One module. Every game compiles into the same target, so every
//    top-level name is shared. Prefix yours with the game — `PokerHand`,
//    `DurakMove`, `PoolPhysics` — or nest them inside your controller.
//    Solitaire predates the collection and already holds several bare names:
//    `Game`, `GameState`, `GameOptions`, `GameEvent`, `Move`, `MoveRecord`,
//    `SavedGame`, `PileID`, `PileKind`, `ClickTarget`, `CardPlacement`,
//    `PilePlacement`, `TableauColumn`, `BoardView`, `BoardViewDelegate`,
//    `BoardLayout`, `Scoring`, `ScoringMode`, `DealGenerator`,
//    `KlondikeSolver`, `MessageOverlay`, `WinCascade`, `ScoreFloatPool`,
//    `PileAccessibilityElement`, `SolitaireStatus`. Treat them as taken, along
//    with every name in Kit, App and Support (`DealNumber` is Kit's; so are
//    `Palette`, `Motion`, `Chips`, `TableLayout` and the rest listed above).
//    Two games declaring the same name is a build failure for everyone, not
//    just for the second.
//  * Stay in your folder. Kit and App are shared; if you need something from
//    them that is not there, say so rather than changing it underneath the
//    other games.
//  * No image or audio files. Everything is drawn or synthesised in code.
//  * No new sounds. `Sound.play(.deal / .place / .flip / .slide / .shuffle)`
//    where a card physically moves, and nothing else — some players find
//    sharp interface sounds painful, and the switch is off by default.
//  * Nothing runs while idle. No timer, display link or render loop may run
//    unless the game is the active screen *and* the window is key and
//    visible — which is exactly the span between `gameDidBecomeActive()` and
//    `gameWillResignActive()`. A table nobody is looking at should cost
//    nothing. On a `CardTableView`, that means `scheduler.suspend()` in
//    `gameWillResignActive()` and `scheduler.resume()` in
//    `gameDidBecomeActive()`; `SeatView`'s thinking sweep watches the window
//    by itself.
//  * Every string the player can see goes through `NSLocalizedString`, in
//    English; the Russian localisation is added later from those keys. A
//    string with a count in it goes through `Plural.format(n, one:, other:)`
//    — never `String(format: "%d moves")`, which reads "1 moves" in English
//    and cannot be put into Russian at all.
//  * AppKit on the main thread, and no force-unwraps on a path the player can
//    reach.
//  * The look is two layers, and every screen honours both. The surfaces —
//    felt, wood, printed cards, one light from above-left, texture felt rather
//    than seen — come from `AppleStyle`. The chrome floating over them is
//    modern macOS, and comes from the kit's Design and Chrome pieces: glass
//    (`GlassPanel` — Liquid Glass on macOS 26, vibrancy before, drawn in
//    snapshots), SF Pro and SF Pro Rounded, SF Symbols, capsule buttons, calm
//    springs that settle without wobbling, and no decorative motion under
//    Reduce Motion (`Motion.isEnabled`; see the next rule). One accent —
//    `Palette.accent`, gold, "look here" — and a porcelain primary button.
//    No emoji, no confetti, no screen shake. Build chrome from the kit rather
//    than from raw AppKit controls, so five games read as one app.
//  * Reduce Motion removes decoration, not the game. Springs, fades, card
//    flights, a camera flying in, a flourish on a win: all become cuts when
//    `Motion.isEnabled` is false. Motion that *is* the game — pool balls
//    rolling after a shot — still plays, since there is nothing to show
//    without it; keep it plain (no camera shake, no slow-motion replays) and
//    let it come to rest. While a snapshot is being taken
//    (`TabletopEnvironment.isRenderingSnapshot`) such a simulation is run to
//    rest synchronously instead, so `--shot` always shows the settled table.
//
//  THE WINDOW
//
//  The game's view fills the whole window, including the strip under the
//  transparent titlebar. That strip — `TabletopChrome.topInset(for:)` points
//  tall, 38 on this system (a compact toolbar sets it) — belongs to the
//  window: the traffic lights, the Library button, the game's title and its
//  status pills (`TopBarStatus`) sit in it, and a drag there moves the window,
//  so nothing the player needs to click may live in it. It is the same quiet
//  surface on every screen — the dark room (`Palette.room`) — so the chrome
//  never sits half on wood and half on cloth: the table itself, rail and
//  all, starts below it. A `CardTableView` does this for you whatever its
//  shape; a view that paints its own table calls
//  `TableSurface.paintTopBand(in:height:context:)` and starts the table at
//  `topInset`; a SceneKit view sits below the strip on a room-coloured
//  backdrop. The window is at least 960 × 640 and opens at 1200 × 800.
//
//  Escape is the game's to use; the shell never takes it. The shell does own
//  ⌘0–⌘5 (the Games menu), ⌘? (How to Play), ⌃⌘F, ⌘H, ⌘M and ⌘Q.
//
//  LIFECYCLE, IN ORDER
//
//    init()                        the player opens the game for the first time
//    loadView() / viewDidLoad()    straight after, when the view is first needed
//    makeGameMenu()                once, the first time the game is shown
//    preferredFirstResponder       every time the game is shown
//    gameDidBecomeActive()   ┐     on screen with the window key and visible;
//    gameWillResignActive()  ┘     always balanced, never twice in a row
//    prepareToQuit()               at quit or window close, after resigning
//
//  The command-line harness (see Support/) drives the rest: `runSelfTests`
//  for `--selftest`, `prepareForScreenshot` and `snapshotImage` for `--shot`.
//

import AppKit

// MARK: - Identity

/// Every game in the collection, in the order the library shows them and the
/// Games menu numbers them (⌘1 is `pool`).
///
/// The raw value is permanent: it names the game's files on disk (see
/// `Storage.fileName(_:for:)`), its `--shot` and `--selftest` arguments, and
/// the menu's represented objects.
enum GameID: String, CaseIterable, Codable {
    case pool, poker, blackjack, durak, solitaire
}

/// How a game introduces itself to the library, the menu bar and Help.
///
/// Built on demand rather than stored, so every string in it can be localised
/// at the moment it is read.
struct GameInfo {
    let id: GameID
    /// The game's name: the library tile, the menu title, the window title.
    /// "Pool", "Durak".
    let title: String
    /// One short line under the title: what kind of game it is. "Eight-ball
    /// on a full-size table".
    let subtitle: String
    /// Who plays: "1–2 players · vs computer". Shown small, with a figure.
    let detail: String
    /// An SF Symbol for the Games menu and the library, e.g. "suit.spade.fill".
    let symbolName: String
    /// The one colour the game is allowed to call its own: the library tile's
    /// highlight, the menu glyph. Keep it deep and quiet — it sits next to
    /// four others.
    let accent: NSColor
    /// The digit for the Games menu's ⌘ shortcut, "1" to "5", matching the
    /// game's position in `GameID.allCases`.
    let keyEquivalent: String
}

// MARK: - The contract

/// One game in the collection. See the top of this file for the rules every
/// conformer lives by.
///
/// Conform with a `final class` — the shell creates the game through
/// `init()` on the metatype, which a non-final class would have to mark
/// `required`. Because there is no nib, override `loadView()` and assign
/// `view` yourself; `NSViewController`'s own `loadView` goes looking for a nib
/// named after the class and fails.
///
/// Default implementations exist for everything a game may not need (the
/// hooks, the screenshot scenarios, the snapshot, the tests). A game that
/// provides its own must match the signature exactly — a near miss compiles
/// fine and silently leaves the default in charge.
@MainActor
protocol TabletopGame: NSViewController {

    /// Title, subtitle, players, symbol, accent and shortcut.
    static var info: GameInfo { get }

    /// Cheap. The shell calls this the moment the player picks the game, and
    /// the view has to be on screen a heartbeat later: deal cards, build
    /// scenes and start solvers in `viewDidLoad()` or on first activation.
    init()

    /// The library tile's picture — the game's cover art.
    ///
    /// `ctx` is set up with a TOP-LEFT origin and y growing downward (the same
    /// convention as `CardRenderer` and `AppleStyle`), in points, already
    /// scaled for the backing store; draw to fill `rect` exactly (it is not
    /// necessarily at the origin). The tile clips it to a rounded rectangle, so
    /// paint right to the corners. It is rasterised once per size and cached,
    /// so it may be as expensive as it needs to be — but it runs on the main
    /// thread while the library appears, so a few milliseconds, not a second.
    /// No text: the tile prints the title underneath.
    static func drawArtwork(in ctx: CGContext, rect: CGRect)

    /// The rules and the controls, in a few short paragraphs of plain English,
    /// localised. Shown by Help ▸ How to Play while the game is in front.
    static var howToPlay: String { get }

    /// The game is now on screen, in front, in a key and visible window.
    /// Start the clocks, the render loop, the bots' thinking.
    func gameDidBecomeActive()

    /// The game is going out of view: back to the library, the window lost
    /// key, was covered, or was minimised. Stop everything that ticks, and
    /// save — the next thing that happens may be the process being killed.
    func gameWillResignActive()

    /// The app is quitting or the window is closing. Save. Called on every
    /// game that was ever opened this session, after `gameWillResignActive()`
    /// if it was active.
    func prepareToQuit()

    /// The game's own menu, titled with the game's name. It sits between Games
    /// and Edit while the game is in front and is removed in the library.
    /// Called once; the shell keeps the menu. Leave item targets nil and the
    /// responder chain delivers to this controller (it sits after its view);
    /// validate with `NSMenuItemValidation`. ⌘N should be New Game.
    ///
    /// Undo and Redo are not in here: they are the Edit menu's, and reach the
    /// game by implementing `TabletopUndoable`.
    func makeGameMenu() -> NSMenu

    /// The view that should take the keyboard when the game is shown, so keys
    /// work without a click first. Defaults to `view`, which must then accept
    /// first responder.
    var preferredFirstResponder: NSView? { get }

    /// Names `--shot <game> --scenario NAME` accepts, first one the default.
    /// Short, lowercase, hyphenated: "opening", "showdown", "break".
    static var screenshotScenarios: [String] { get }

    /// Puts the game into a deterministic, representative, fully settled state
    /// for an off-screen screenshot: seeded dealing, no animation in flight,
    /// nothing waiting on a timer. `scenario` is one of `screenshotScenarios`,
    /// or nil for the default. Called with the view already in its off-screen
    /// window at the final size, with `TabletopEnvironment.isRenderingSnapshot`
    /// set, and without `gameDidBecomeActive()`.
    func prepareForScreenshot(scenario: String?)

    /// The game's view as a picture, `size` points at 2×. The default renders
    /// `view.layer` through Core Animation, which covers anything built from
    /// views and layers. Content Core Animation cannot draw into a bitmap —
    /// a SceneKit or Metal view — comes out as a transparent hole, so such a
    /// game overrides this and passes the scene's own picture as the
    /// underlay, with its kit HUD (glass panels, the action bar, banners)
    /// rendered on top:
    ///
    ///     let scene = scnView.snapshot().cgImage(forProposedRect: nil, context: nil, hints: nil)
    ///     return LayerSnapshot.image(of: view, size: size, scale: 2, underlay: scene)
    ///
    /// `SCNView.snapshot()` works in the harness's window that is never
    /// shown. Keep the root view and the SCNView's ancestors free of opaque
    /// backgrounds of their own, or they paint over the scene. (If the
    /// SCNView does not fill the root view, draw its snapshot into a bitmap
    /// the root's size at the SCNView's frame first.)
    func snapshotImage(size: CGSize) -> CGImage?

    /// The game's checks, for `--selftest` (everything) and
    /// `--selftest <game id>` (just this game). Engine invariants first: a
    /// rules bug is invisible until it ruins a game twenty minutes in.
    /// Runs on the main actor with `Storage` pointed at a throwaway folder;
    /// mark a test enum `@MainActor` if it touches the controller or AppKit.
    /// Keep the whole suite to a few seconds in a debug build.
    static func runSelfTests(_ t: TestReporter)
}

extension TabletopGame {
    func gameDidBecomeActive() {}
    func gameWillResignActive() {}
    func prepareToQuit() {}
    var preferredFirstResponder: NSView? { view }
    static var screenshotScenarios: [String] { [] }
    func prepareForScreenshot(scenario: String?) {}
    static func runSelfTests(_ t: TestReporter) {}

    func snapshotImage(size: CGSize) -> CGImage? {
        LayerSnapshot.image(of: view, size: size, scale: 2)
    }
}

/// Undo and Redo, for a game that has them.
///
/// Edit ▸ Undo (⌘Z) and Redo (⇧⌘Z) send `undoMove:` and `redoMove:` down the
/// responder chain; implement them on the game controller (conforming to this
/// protocol documents that you did) and validate them in
/// `validateMenuItem(_:)`. A game without them simply sees both items greyed.
///
/// Named `undoMove:` and `redoMove:` rather than the obvious `undo:` and
/// `redo:` because NSWindow already implements both, forwarding them to its
/// own NSUndoManager. Anything that answers after the window in the responder
/// chain — the window controller, the app delegate — would never hear an
/// action called `undo:`; the window swallows it and silently does nothing,
/// which is exactly what solitaire's Undo button once did.
@objc protocol TabletopUndoable {
    func undoMove(_ sender: Any?)
    func redoMove(_ sender: Any?)
}

// MARK: - Environment

/// What the app is doing right now, for kit and game code that has to behave
/// differently when it is being tested or photographed.
enum TabletopEnvironment {

    /// True for the whole of a `--shot` run. Animations are off, and anything
    /// time-dependent — a clock face, a shimmer — should draw its resting
    /// state, so the same command always produces the same picture.
    static var isRenderingSnapshot = false

    /// True when the process is the command-line harness (`--selftest`,
    /// `--playtest`, `--controls`, `--shot`, …) rather than the app a player
    /// launched. `Storage` is pointed at a throwaway folder in that case, so
    /// saving is harmless; a game might still skip a slow background search.
    static var isHarness = false

    /// Whether to animate at all: off under Reduce Motion (which a game must
    /// honour for every decorative motion, springs included — see the house
    /// rules for the one exception, a simulation that is the game) and while
    /// rendering a snapshot. Reduce Motion can change while the app runs;
    /// observe
    /// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on
    /// `NSWorkspace.shared.notificationCenter` to follow it live.
    ///
    /// `Motion.isEnabled` is the same switch under the design system's name;
    /// kit code reads that one.
    static var animationsEnabled: Bool {
        if let animationsOverride { return animationsOverride }
        return !isRenderingSnapshot && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Forces `animationsEnabled` one way or the other, for a self-test that
    /// has to see a sequence land synchronously (false) or check that an
    /// animation was actually attached (true). Nil — the default — means
    /// "follow Reduce Motion and the snapshot flag". Put it back when done.
    static var animationsOverride: Bool?

    /// The value after `flag` on the command line, e.g. `value(of: "--deal")`.
    /// For a game's own extra `--shot` options.
    static func value(of flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

/// The window's own furniture, as far as a game needs to know about it.
enum TabletopChrome {

    /// Height of the strip along the top of the window that belongs to the
    /// window rather than the game: the titlebar's height, and never less than
    /// the room the Library button needs (it stays there in full screen, where
    /// the titlebar is hidden). Paint under it; keep controls out of it.
    /// Read it in `layout()` — it changes on entering and leaving full screen.
    static func topInset(for view: NSView) -> CGFloat {
        guard let window = view.window else { return minimumTopInset }
        let titlebar = window.frame.height - window.contentLayoutRect.height
        return max(minimumTopInset, titlebar.rounded())
    }

    /// The strip's height when the window cannot say — in full screen, or
    /// for a view not yet in a window — and never less than that otherwise:
    /// the window's compact toolbar makes its titlebar exactly this tall.
    static let minimumTopInset: CGFloat = 38
}

extension Storage {

    /// A game's file name: `"\(game)-\(name)"`, e.g. `poker-bankroll.json`.
    /// Every file a game writes goes through this, so the folder can be read —
    /// and a game reset — at a glance.
    static func fileName(_ name: String, for game: GameID) -> String {
        "\(game.rawValue)-\(name)"
    }
}
