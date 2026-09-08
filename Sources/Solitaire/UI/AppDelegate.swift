//
//  AppDelegate.swift
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: GameWindowController?
    private var demoTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences.load()
        let controller = GameWindowController(preferences: preferences)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--demo") { startDemo() }
    }

    /// `Solitaire --demo` plays itself, roughly at the pace of a person.
    ///
    /// It exists to be measured: energy figures taken while an app sits doing
    /// nothing prove nothing about what it costs to actually play, and there is
    /// no other way to hold a mouse for sixty seconds.
    private func startDemo() {
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let controller = self?.controller else { return }
            controller.playOneDemoMove()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        demoTimer = timer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareToQuit()
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("How to play", comment: "")
        alert.informativeText = NSLocalizedString("""
        Build the four foundations up from ace to king, one for each suit.

        • Click a card and it moves itself to the best place it can go — a \
        foundation if it fits, otherwise onto another column.
        • Click part-way down a run to move that whole run.
        • Drag instead, if you would rather choose the destination yourself.
        • Click the face-down pile to turn a card over; click it again when it \
        is empty to turn the pile back over.
        • Right-click a card to send it straight to a foundation.

        Keyboard: N for a new game, ⌘Z to undo, Space to turn a card over, \
        H for a hint, and E to finish a game that is already decided.
        """, comment: "help text")
        alert.addButton(withTitle: NSLocalizedString("Done", comment: ""))
        alert.runModal()
    }
}
