//
//  MainMenu.swift
//  The menu bar, built in code because a SwiftPM app has no nib to load one
//  from. Every shortcut here is checked against the ones macOS reserves:
//  ⌘H hides the app and ⌘M minimises it, so games work around them.
//
//  The bar is the same everywhere except for one slot. Between Games and Edit
//  sits the menu of whichever game is in front — Solitaire's, Poker's — and in
//  the library there is nothing there at all. `TabletopWindowController` swaps
//  it through `installGameMenu(_:title:in:)`.
//

import AppKit

@MainActor
enum MainMenu {

    /// Marks the item carrying the active game's menu, so it can be found
    /// again to be swapped out.
    static let gameMenuTag = 0x7AB1E

    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenu(appName: appName))
        main.addItem(gamesMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    /// Puts `menu` in the game slot, replacing whatever game menu was there,
    /// or empties the slot when `menu` is nil.
    static func installGameMenu(_ menu: NSMenu?, title: String, in main: NSMenu) {
        if let existing = main.items.firstIndex(where: { $0.tag == gameMenuTag }) {
            // The same menu going back in is a no-op, so flipping between the
            // library and a game does not make the menu bar flicker.
            if let menu, main.items[existing].submenu === menu { return }
            main.items[existing].submenu = nil
            main.removeItem(at: existing)
        }
        guard let menu else { return }
        menu.title = title
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.tag = gameMenuTag
        item.submenu = menu
        // After the application menu and Games, before Edit.
        let gamesIndex = main.items.firstIndex { $0.submenu?.identifier == gamesMenuIdentifier } ?? 1
        main.insertItem(item, at: min(gamesIndex + 1, main.items.count))
    }

    private static let gamesMenuIdentifier = NSUserInterfaceItemIdentifier("TabletopGamesMenu")

    // MARK: Building blocks

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "", modifiers: NSEvent.ModifierFlags = .command,
                            tag: Int = 0, represented: Any? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.representedObject = represented
        item.target = target      // nil means "walk the responder chain"
        menu.addItem(item)
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: Menus

    private static func applicationMenu(appName: String) -> NSMenuItem {
        let (item, menu) = submenu(appName)
        add(menu, String(format: NSLocalizedString("About %@", comment: ""), appName),
            #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())

        let services = NSMenu()
        let servicesItem = NSMenuItem(
            title: NSLocalizedString("Services", comment: ""), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        add(menu, String(format: NSLocalizedString("Hide %@", comment: ""), appName),
            #selector(NSApplication.hide(_:)), "h")
        add(menu, NSLocalizedString("Hide Others", comment: ""),
            #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option])
        add(menu, NSLocalizedString("Show All", comment: ""),
            #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, String(format: NSLocalizedString("Quit %@", comment: ""), appName),
            #selector(NSApplication.terminate(_:)), "q")
        return item
    }

    /// The library and every game, numbered in library order. The window
    /// controller answers all of them and ticks the one in front.
    private static func gamesMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Games", comment: "menu title"))
        menu.identifier = gamesMenuIdentifier
        let library = add(menu, NSLocalizedString("Library", comment: "the game library"),
                          #selector(TabletopWindowController.showLibrary(_:)), "0")
        library.image = symbol("square.grid.2x2")
        menu.addItem(.separator())
        for type in GameCatalog.all {
            let info = type.info
            let entry = add(menu, info.title, #selector(TabletopWindowController.openGame(_:)),
                            info.keyEquivalent, represented: info.id.rawValue)
            entry.image = symbol(info.symbolName)
        }
        return item
    }

    /// Undo and Redo only. They travel down the responder chain to the game
    /// in front, and grey out on their own wherever nothing answers them — in
    /// the library, or in a game that has no undo.
    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Edit", comment: ""))
        add(menu, NSLocalizedString("Undo", comment: ""),
            #selector(TabletopUndoable.undoMove(_:)), "z")
        add(menu, NSLocalizedString("Redo", comment: ""),
            #selector(TabletopUndoable.redoMove(_:)), "z", modifiers: [.command, .shift])
        return item
    }

    /// The table, which is the same table in every game: its cloth, the backs
    /// of the cards, the four-colour deck and the sound. Answered by the app
    /// delegate, which owns `TablePreferences`.
    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("View", comment: ""))

        let (tableItem, table) = submenu(NSLocalizedString("Table Colour", comment: ""))
        for color in TableColor.allCases {
            add(table, color.localizedName,
                #selector(AppDelegate.setTableColor(_:)), represented: color.rawValue)
        }
        menu.addItem(tableItem)

        let (backItem, back) = submenu(NSLocalizedString("Card Back", comment: ""))
        for style in CardBackStyle.allCases {
            add(back, style.localizedName,
                #selector(AppDelegate.setCardBackStyle(_:)), represented: style.rawValue)
        }
        back.addItem(.separator())
        for color in CardBackColor.allCases {
            add(back, color.localizedName,
                #selector(AppDelegate.setCardBackColor(_:)), represented: color.rawValue)
        }
        menu.addItem(backItem)

        add(menu, NSLocalizedString("Four-Colour Deck", comment: ""),
            #selector(AppDelegate.toggleFourColorDeck(_:)))
        add(menu, NSLocalizedString("Sound", comment: ""),
            #selector(AppDelegate.toggleSound(_:)))
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Enter Full Screen", comment: ""),
            #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Window", comment: ""))
        add(menu, NSLocalizedString("Minimise", comment: ""),
            #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, NSLocalizedString("Zoom", comment: ""), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Bring All to Front", comment: ""),
            #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    /// One item, retitled by the window controller for whatever is in front:
    /// "How to Play Durak" in a game, the collection's own help in the library.
    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Help", comment: ""))
        add(menu, NSLocalizedString("How to Play", comment: "help menu item"),
            #selector(TabletopWindowController.showHowToPlay(_:)), "?")
        NSApp.helpMenu = menu
        return item
    }
}
