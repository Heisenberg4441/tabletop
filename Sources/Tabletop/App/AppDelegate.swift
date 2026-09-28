//
//  AppDelegate.swift
//  Launch, quit, and the View menu's table settings.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private(set) var controller: TabletopWindowController?
    private var demoTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read once up front: this is also what puts the sound switch where
        // the player left it (off, unless they turned it on).
        _ = TablePreferences.current

        let controller = TabletopWindowController()
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--demo") { startDemo() }
    }

    /// `Tabletop --demo` opens Solitaire and plays it, roughly at the pace of
    /// a person.
    ///
    /// It exists to be measured: energy figures taken while an app sits doing
    /// nothing prove nothing about what it costs to actually play, and there is
    /// no other way to hold a mouse for sixty seconds.
    private func startDemo() {
        controller?.show(.game(.solitaire), animated: false)
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                (self?.controller?.existingGame(.solitaire) as? SolitaireGame)?.playOneDemoMove()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        demoTimer?.invalidate()
        controller?.prepareToQuit()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: View ▸ the table

    // Every one of these changes the table in every game at once: they write
    // `TablePreferences.current`, which saves and tells the games, and each
    // game re-dresses its own table in place.

    @objc func setTableColor(_ sender: NSMenuItem) {
        guard let color = TableColor(rawValue: sender.representedObject as? String ?? "") else { return }
        TablePreferences.current.table = color
    }

    @objc func setCardBackStyle(_ sender: NSMenuItem) {
        guard let style = CardBackStyle(rawValue: sender.representedObject as? String ?? "") else { return }
        TablePreferences.current.backStyle = style
    }

    @objc func setCardBackColor(_ sender: NSMenuItem) {
        guard let color = CardBackColor(rawValue: sender.representedObject as? String ?? "") else { return }
        TablePreferences.current.backColor = color
    }

    @objc func toggleFourColorDeck(_ sender: NSMenuItem) {
        TablePreferences.current.fourColorDeck.toggle()
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        TablePreferences.current.soundEnabled.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let preferences = TablePreferences.current
        let represented = item.representedObject as? String
        switch item.action {
        case #selector(setTableColor(_:)):
            item.state = preferences.table.rawValue == represented ? .on : .off
        case #selector(setCardBackStyle(_:)):
            item.state = preferences.backStyle.rawValue == represented ? .on : .off
        case #selector(setCardBackColor(_:)):
            item.state = preferences.backColor.rawValue == represented ? .on : .off
        case #selector(toggleFourColorDeck(_:)):
            item.state = preferences.fourColorDeck ? .on : .off
        case #selector(toggleSound(_:)):
            item.state = preferences.soundEnabled ? .on : .off
        default:
            break
        }
        return true
    }
}
