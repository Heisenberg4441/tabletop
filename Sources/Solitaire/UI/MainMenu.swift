//
//  MainMenu.swift
//  The menu bar, built in code because a SwiftPM app has no nib to load one
//  from. Every shortcut here is checked against the ones macOS reserves:
//  ⌘H hides the app and ⌘M minimises it, so Hint and the rest work around them.
//

import AppKit

enum MainMenu {

    static func build(appName: String) -> NSMenu {
        let main = NSMenu()

        main.addItem(applicationMenu(appName: appName))
        main.addItem(gameMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu(appName: appName))
        return main
    }

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

    private static func gameMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Game", comment: ""))
        add(menu, NSLocalizedString("New Game", comment: ""),
            #selector(GameWindowController.newGame(_:)), "n")
        add(menu, NSLocalizedString("Select Deal…", comment: ""),
            #selector(GameWindowController.selectDeal(_:)), "n", modifiers: [.command, .shift])
        add(menu, NSLocalizedString("Restart This Deal", comment: ""),
            #selector(GameWindowController.restartDeal(_:)), "r")
        menu.addItem(.separator())
        // Space is handled by the board's `keyDown`, not here: a menu key
        // equivalent would intercept it before any text field could see it.
        add(menu, NSLocalizedString("Turn Over a Card", comment: ""),
            #selector(GameWindowController.drawFromStock(_:)))
        // ⌘H is reserved for Hide, so the hint lives on ⌘/ — and the board also
        // takes a bare H, which is what players reach for.
        add(menu, NSLocalizedString("Hint", comment: ""),
            #selector(GameWindowController.hint(_:)), "/")
        add(menu, NSLocalizedString("Auto-Finish", comment: ""),
            #selector(GameWindowController.autoFinish(_:)), "e")
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Statistics…", comment: ""),
            #selector(GameWindowController.showStatistics(_:)), "s", modifiers: [.command, .option])
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Edit", comment: ""))
        add(menu, NSLocalizedString("Undo", comment: ""),
            #selector(GameWindowController.undoMove(_:)), "z")
        add(menu, NSLocalizedString("Redo", comment: ""),
            #selector(GameWindowController.redoMove(_:)), "z", modifiers: [.command, .shift])
        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("View", comment: ""))

        add(menu, NSLocalizedString("Draw One Card", comment: ""),
            #selector(GameWindowController.setDrawCount(_:)), "1", tag: 1)
        add(menu, NSLocalizedString("Draw Three Cards", comment: ""),
            #selector(GameWindowController.setDrawCount(_:)), "3", tag: 3)
        menu.addItem(.separator())

        let (scoringItem, scoring) = submenu(NSLocalizedString("Scoring", comment: ""))
        for mode in ScoringMode.allCases {
            add(scoring, mode.localizedName,
                #selector(GameWindowController.setScoring(_:)), represented: mode.rawValue)
        }
        menu.addItem(scoringItem)
        add(menu, NSLocalizedString("Timed Game", comment: ""),
            #selector(GameWindowController.toggleTimed(_:)))
        add(menu, NSLocalizedString("Winnable Deals Only", comment: ""),
            #selector(GameWindowController.toggleWinnableDeals(_:)))
        add(menu, NSLocalizedString("Click Sends Cards to Foundations", comment: ""),
            #selector(GameWindowController.toggleClickPrefersFoundation(_:)))
        add(menu, NSLocalizedString("Play Aces and Twos Automatically", comment: ""),
            #selector(GameWindowController.toggleAutoPlaySafeCards(_:)))
        menu.addItem(.separator())

        let (tableItem, table) = submenu(NSLocalizedString("Table Colour", comment: ""))
        for color in TableColor.allCases {
            add(table, color.localizedName,
                #selector(GameWindowController.setTableColor(_:)), represented: color.rawValue)
        }
        menu.addItem(tableItem)

        let (backItem, back) = submenu(NSLocalizedString("Card Back", comment: ""))
        for style in CardBackStyle.allCases {
            add(back, style.localizedName,
                #selector(GameWindowController.setCardBackStyle(_:)), represented: style.rawValue)
        }
        back.addItem(.separator())
        for color in CardBackColor.allCases {
            add(back, color.localizedName,
                #selector(GameWindowController.setCardBackColor(_:)), represented: color.rawValue)
        }
        menu.addItem(backItem)

        add(menu, NSLocalizedString("Four-Colour Deck", comment: ""),
            #selector(GameWindowController.toggleFourColorDeck(_:)))
        menu.addItem(.separator())
        // ⌘B is free — the reserved ones are ⌘H (hide) and ⌘M (minimise).
        add(menu, NSLocalizedString("Brainrot Mode", comment: "the silly one"),
            #selector(GameWindowController.toggleBrainrot(_:)), "b")
        add(menu, NSLocalizedString("Brainrot Dubstep", comment: "the loud one"),
            #selector(GameWindowController.toggleBrainrotMusic(_:)), "b",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, NSLocalizedString("Sound", comment: ""),
            #selector(GameWindowController.toggleSound(_:)))
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

    private static func helpMenu(appName: String) -> NSMenuItem {
        let (item, menu) = submenu(NSLocalizedString("Help", comment: ""))
        add(menu, String(format: NSLocalizedString("%@ Help", comment: ""), appName),
            #selector(AppDelegate.showHelp(_:)), "?")
        NSApp.helpMenu = menu
        return item
    }
}
