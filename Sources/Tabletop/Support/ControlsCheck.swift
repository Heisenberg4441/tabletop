//
//  ControlsCheck.swift
//  `Tabletop --controls`: every menu item and every button, on every screen,
//  reaches something that answers it.
//
//  A menu item or button with a nil target relies on the responder chain to
//  find its action, which means it can look perfectly correct in the source
//  and do nothing at all at runtime — and in an app where each game brings its
//  own menu and its own buttons into one shared window, the chain is different
//  on every screen. There is no way to see that by reading; the chain has to be
//  walked, screen by screen, the way AppKit walks it.
//
//  Also checked here, because they are properties of the same wiring: that
//  the screen in front has the keyboard, that no two menu items share a
//  shortcut, that each game's menu follows the house conventions, and that the
//  Library button can actually be clicked where it sits in the titlebar.
//

import AppKit

@MainActor
enum ControlsCheck {

    /// Actions that are allowed to find no one: Undo and Redo, which grey
    /// themselves out wherever the screen in front has no undo.
    private static let optional: Set<Selector> = [
        #selector(TabletopUndoable.undoMove(_:)),
        #selector(TabletopUndoable.redoMove(_:)),
    ]

    static func run() -> Int32 {
        let t = TestReporter()
        let delegate = AppDelegate()
        NSApp.delegate = delegate
        NSApp.mainMenu = MainMenu.build(appName: "Tabletop")
        let controller = TabletopWindowController()
        guard let window = controller.window, let main = NSApp.mainMenu else {
            print("  FAIL no window")
            return 1
        }
        window.layoutIfNeeded()

        let screens: [TabletopWindowController.Screen] = [.library] + GameID.allCases.map { .game($0) }
        for screen in screens {
            controller.show(screen, animated: false)
            window.layoutIfNeeded()
            let name: String
            let screenView: NSView
            let owner: NSResponder
            switch screen {
            case .library:
                name = NSLocalizedString("Library", comment: "")
                screenView = controller.library.view
                owner = controller.library
            case .game(let id):
                name = GameCatalog.info(for: id).title
                let game = controller.game(for: id)
                screenView = game.view
                owner = game
            }
            t.section("Controls: \(name)")

            // The keyboard is the screen's the moment it appears.
            let first = window.firstResponder as? NSView
            t.check("the screen has the keyboard (\(first.map { String(describing: type(of: $0)) } ?? "nothing"))",
                    first.map { $0.isDescendant(of: screenView) } ?? false)

            // Menu items.
            var dead: [String] = []
            var hijacked: [String] = []
            var checked = 0
            var shortcuts: [String: String] = [:]
            var clashes: [String] = []
            func walk(_ menu: NSMenu) {
                for item in menu.items {
                    if let submenu = item.submenu {
                        // An item that opens a submenu carries AppKit's own
                        // `submenuAction:`; it is the items inside that count.
                        walk(submenu)
                        continue
                    }
                    if !item.keyEquivalent.isEmpty {
                        let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                        if let other = shortcuts[key] { clashes.append("\(other) / \(item.title)") }
                        shortcuts[key] = item.title
                    }
                    guard let action = item.action, !(menu.autoenablesItems == false && !item.isEnabled) else { continue }
                    checked += 1
                    let label = "\(item.title) (\(NSStringFromSelector(action)))"
                    let answer = resolve(action, target: item.target, window: window)
                    if answer == nil {
                        if !optional.contains(action) { dead.append(label) }
                        continue
                    }
                    // An action the screen's own controller implements has to
                    // arrive there, and not be caught on the way by the window
                    // or the application — which is how an Undo menu item
                    // once silently did nothing.
                    if item.target == nil, owner.responds(to: action), let answer,
                       answer !== owner, !((answer as? NSView)?.isDescendant(of: screenView) ?? false) {
                        hijacked.append("\(label) -> \(type(of: answer))")
                    }
                }
            }
            walk(main)
            t.check("every menu item reaches a handler (\(checked) checked) \(dead)", checked > 20 && dead.isEmpty)
            t.check("none is intercepted before the screen's controller \(hijacked)", hijacked.isEmpty)
            t.check("no two menu items share a shortcut \(clashes)", clashes.isEmpty)

            // The game's own menu follows the house conventions.
            if case .game(let id) = screen {
                let menu = controller.gameMenu(for: id)
                t.check("the \(name) menu is in the menu bar, under the game's name",
                        menu != nil && main.items.contains { $0.submenu === menu && $0.title == name })
                t.check("and New Game is ⌘N",
                        menu?.items.contains { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command } ?? false)
            } else {
                t.check("the library has no game menu", !main.items.contains { $0.tag == MainMenu.gameMenuTag })
            }

            // Buttons and every other control on the screen, and the chrome.
            var controls: [NSControl] = []
            func collect(_ view: NSView) {
                if let control = view as? NSControl, control.action != nil, !control.isHiddenOrHasHiddenAncestor {
                    controls.append(control)
                }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            var deadControls: [String] = []
            for control in controls {
                guard let action = control.action else { continue }
                if resolve(action, target: control.target, window: window) == nil {
                    deadControls.append("\(type(of: control)) \(NSStringFromSelector(action))")
                }
            }
            t.check("every button reaches a handler (\(controls.count) checked) \(deadControls)", deadControls.isEmpty)

            // A capsule button's key equivalent is answered before the menu
            // bar's, so one that repeats a menu shortcut silently steals it.
            var stolen: [String] = []
            for case let button as CapsuleButton in controls where !button.keyEquivalent.isEmpty {
                let key = "\(button.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]).rawValue)-\(button.keyEquivalent.lowercased())"
                if let title = shortcuts[key] { stolen.append("\(button.title) / \(title)") }
            }
            t.check("no button's key takes a menu item's shortcut \(stolen)", stolen.isEmpty)

            // A stub's glass card has to come out with a size, on the glass
            // path the real app takes — this run is not a snapshot.
            if let stub = screenView as? ComingSoonView {
                stub.layoutSubtreeIfNeeded()
                t.check("the placeholder's card has a size (\(Int(stub.panel.frame.width))×\(Int(stub.panel.frame.height)))",
                        stub.panel.frame.width >= 300 && stub.panel.frame.height >= 100)
            }
        }

        // The Library button sits in the titlebar strip, where the window's
        // own frame view gets first say over every click. It has to win there.
        controller.show(.game(.solitaire), animated: false)
        window.layoutIfNeeded()
        t.section("Window chrome")
        if let frameView = window.contentView?.superview,
           let button = findButton(in: window.contentView) {
            let centre = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            let hit = frameView.hitTest(frameView.convert(centre, from: nil))
            t.check("a click on the Library button lands on it (\(hit.map { String(describing: type(of: $0)) } ?? "nothing"))",
                    hit === button)
            let zoom = window.standardWindowButton(.zoomButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
            let frame = button.convert(button.bounds, to: nil)
            t.check("it sits clear of the traffic lights", frame.minX >= zoom.maxX + 6)
            t.check("and inside the titlebar strip",
                    frame.minY >= window.contentLayoutRect.maxY - 2 && frame.maxY <= window.frame.height)
            let strip = window.frame.height - window.contentLayoutRect.height
            t.check("with room above and below it, not touching the window's edge (\(Int(strip)) pt strip)",
                    window.frame.height - frame.maxY >= 4 && frame.minY - window.contentLayoutRect.maxY >= 4)
            let lights = window.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
            t.check("and centred on the traffic lights", abs(frame.midY - lights.midY) <= 1.5)
            let middle = CGPoint(x: window.frame.width / 2, y: window.frame.height - 8)
            let stripHit = frameView.hitTest(frameView.convert(middle, from: nil))
            t.check("a drag in the rest of the strip moves the window",
                    stripHit.map { $0.mouseDownCanMoveWindow || $0 is WindowChromeView } ?? true)
        } else {
            t.check("the Library button exists", false)
        }
        controller.show(.library, animated: false)
        t.check("the Library button is hidden in the library", findButton(in: window.contentView) == nil)

        // The start and stop calls every game's energy discipline hangs on:
        // one of each, in order, whatever the player does to the window.
        t.section("Starting and stopping games")
        controller.assumeWindowIsKeyForTesting = true
        controller.show(.game(.durak), animated: false)
        controller.show(.game(.durak), animated: false)
        controller.show(.game(.poker), animated: false)
        controller.assumeWindowIsKeyForTesting = false       // the window loses key
        controller.assumeWindowIsKeyForTesting = false
        controller.assumeWindowIsKeyForTesting = true        // and gets it back
        controller.show(.library, animated: false)
        controller.assumeWindowIsKeyForTesting = false
        controller.assumeWindowIsKeyForTesting = true        // nothing to start in the library
        controller.show(.game(.solitaire), animated: false)
        controller.prepareToQuit()
        controller.assumeWindowIsKeyForTesting = true        // nothing starts after quitting
        let log = controller.activationLog
        let expected = ["+durak", "-durak", "+poker", "-poker", "+poker", "-poker", "+solitaire", "-solitaire"]
        t.check("a game starts when it comes to the front of a key window, and stops when it leaves \(log)",
                log == expected)
        var running: String?
        var unbalanced = false
        for entry in log {
            let id = String(entry.dropFirst())
            if entry.hasPrefix("+") { if running != nil { unbalanced = true }; running = id }
            else { if running != id { unbalanced = true }; running = nil }
        }
        t.check("never started twice, never stopped without starting", !unbalanced && running == nil)

        return t.finish(passed: "Controls passed.", failed: { "\($0) control check(s) FAILED." })
    }

    /// Who would answer `action` sent from the menu bar right now: the explicit
    /// target if there is one, otherwise the first responder and everything
    /// after it, then the application and its delegate — the order AppKit uses.
    private static func resolve(_ action: Selector, target: AnyObject?, window: NSWindow) -> AnyObject? {
        if let target { return target.responds(to: action) ? target : nil }
        var responder: NSResponder? = window.firstResponder ?? window.contentView
        var hops = 0
        while let current = responder, hops < 64 {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
            hops += 1
        }
        if let delegate = window.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        if NSApp.responds(to: action) { return NSApp }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    private static func findButton(in view: NSView?) -> CapsuleButton? {
        guard let view else { return nil }
        if let button = view as? CapsuleButton, button.identifier == TabletopWindowController.libraryButtonIdentifier,
           !button.isHiddenOrHasHiddenAncestor { return button }
        for sub in view.subviews { if let found = findButton(in: sub) { return found } }
        return nil
    }
}
