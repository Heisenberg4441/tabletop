#if os(macOS)
//
//  main.swift
//  Entry point. A SwiftPM executable has no nib, so the application object,
//  its activation policy and the whole menu bar are set up here by hand — miss
//  any of the three and the app launches without a menu or a Dock icon.
//
//  The same binary is also the whole test and tooling harness. Every
//  `--` mode below runs off-screen, never shows a window, and points storage
//  at a throwaway folder first, so none of them can touch a player's saves:
//
//    --selftest [kit|<game>]      invariants for the kit and every game
//    --playtest [N]               N solitaire games through the real board
//    --controls                   every menu item and button reaches a handler
//    --shot <library|kit|<game>> <out.png> [--scenario NAME] [--width W] [--height H]
//                                 [--table green|blue|burgundy|slate]
//                                 (solitaire also takes --deal N --moves N --draw 1|3;
//                                 kit takes --scenario gallery|poker|blackjack|durak)
//    --benchmark                  solitaire solver and table rendering timings
//    --preview [out.png] [--flat] every card face and back on one sheet
//    --icon <out.png>             the app icon at 1024 px
//    --sounds <directory>         the card sounds as WAV files
//    --golden                     solitaire's frozen deal fingerprints
//    --help                       this list
//
//  Anything else that looks like one of these — a typo, `--selftests`, a
//  flag from another tool — is refused with the list and exit status 2
//  before a single window or file is touched. Without that check a mistyped
//  harness command would fall through to launching the real app: a window
//  on the player's screen, and the real Application Support folder written.
//  Only `--demo` (the app itself, playing solitaire on its own) and the
//  single-dash arguments macOS and AppKit pass (`-psn_…`, `-NSFoo YES`)
//  reach the GUI.
//

import AppKit

let arguments = CommandLine.arguments

/// The flags that pick a harness mode. Once one of these is present, any
/// other `--flag` is an option of that mode (a game may read its own through
/// `TabletopEnvironment.value(of:)`), so nothing more is checked.
let tabletopHarnessModes: Set<String> = [
    "--selftest", "--playtest", "--controls", "--shot", "--benchmark", "--preview", "--icon", "--sounds", "--golden",
]

let tabletopUsage = """
usage: Tabletop [mode]
  (no mode)                    the app; --demo also plays solitaire by itself
  --selftest [kit|<game>]      invariants for the kit and every game
  --playtest [N]               N solitaire games through the real board
  --controls                   every menu item and button reaches a handler
  --shot <library|kit|<game>> <out.png> [--scenario NAME] [--width W] [--height H]
                               [--table green|blue|burgundy|slate]
  --benchmark                  solitaire solver and table rendering timings
  --preview [out.png] [--flat] every card face and back on one sheet
  --icon <out.png>             the app icon at 1024 px
  --sounds <directory>         the card sounds as WAV files
  --golden                     solitaire's frozen deal fingerprints
games: \(GameID.allCases.map(\.rawValue).joined(separator: ", "))

"""

/// The first argument in `arguments` (the program's own path first, as in
/// `CommandLine.arguments`) that would send an unrecognised request to the
/// GUI app, or nil when the command line is safe to launch with. The kit's
/// self-tests run it over typical typos.
func tabletopStrayArgument(in arguments: [String]) -> String? {
    guard !arguments.contains(where: tabletopHarnessModes.contains) else { return nil }
    for i in arguments.indices.dropFirst() {
        let argument = arguments[i]
        if argument.hasPrefix("--") {
            if argument != "--demo" { return argument }
        } else if !argument.hasPrefix("-") {
            // A bare word is fine only as the value of a single-dash AppKit
            // or LaunchServices argument before it (`-NSFoo YES`).
            let previous = arguments[i - 1]
            let isValue = previous.hasPrefix("-") && !previous.hasPrefix("--") && i - 1 > 0
            if !isValue { return argument }
        }
    }
    return nil
}

/// What every harness mode does before anything else.
@MainActor
func enterHarness() {
    TabletopEnvironment.isHarness = true
    Storage.useTemporaryDirectory()
    Sound.isEnabled = false
    NSApplication.shared.setActivationPolicy(.prohibited)
}

/// The argument after `flag`, unless it is another flag.
func operand(after flag: String, offset: Int = 1) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + offset < arguments.count else { return nil }
    let value = arguments[i + offset]
    return value.hasPrefix("--") ? nil : value
}

@MainActor
func launch() {
    if arguments.contains("--help") || arguments.contains("-h") {
        print(tabletopUsage, terminator: "")
        exit(0)
    }
    if let stray = tabletopStrayArgument(in: arguments) {
        FileHandle.standardError.write(Data("Tabletop: unknown argument '\(stray)'\n\n\(tabletopUsage)".utf8))
        exit(2)
    }
    if arguments.contains("--selftest") {
        enterHarness()
        exit(SelfTestRunner.run(only: operand(after: "--selftest")))
    }
    if arguments.contains("--playtest") {
        enterHarness()
        exit(SolitairePlayTest.run(games: operand(after: "--playtest").flatMap(Int.init) ?? 60))
    }
    if arguments.contains("--controls") {
        enterHarness()
        exit(ControlsCheck.run())
    }
    if arguments.contains("--shot") {
        enterHarness()
        exit(Screenshot.run(target: operand(after: "--shot"), path: operand(after: "--shot", offset: 2)))
    }
    if arguments.contains("--benchmark") {
        enterHarness()
        exit(SolitaireBenchmark.run())
    }
    if arguments.contains("--preview") {
        enterHarness()
        exit(Preview.renderDeck(to: operand(after: "--preview") ?? "deck.png",
                                apple: !arguments.contains("--flat")))
    }
    if arguments.contains("--icon") {
        enterHarness()
        exit(IconRenderer.render(to: operand(after: "--icon") ?? "icon.png"))
    }
    if arguments.contains("--sounds") {
        enterHarness()
        exit(Sound.exportAll(to: operand(after: "--sounds") ?? "."))
    }
    if arguments.contains("--golden") {
        enterHarness()
        SolitaireTests.printGoldenVectors()
        exit(0)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.regular)

    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Tabletop"
    application.mainMenu = MainMenu.build(appName: appName)

    // NSApplication holds its delegate weakly.
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
        application.run()
    }
}

// Last, after every top-level declaration above has been initialised: in
// main.swift those run in order, like a script. Top-level code is not isolated
// to the main actor in Swift 5 mode, but it does run on the main thread —
// which is all the main actor is — so the launch is claimed for it here, once,
// rather than call by call.
MainActor.assumeIsolated {
    launch()
}
#else
import Foundation

let server = EngineServer()
while let line = readLine() {
    let response: [String: Any]
    do {
        guard let data = line.data(using: .utf8),
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.invalidRequest("Expected a JSON object")
        }
        response = try server.handle(request)
    } catch {
        response = ["ok": false, "error": String(describing: error)]
    }
    if let data = try? JSONSerialization.data(withJSONObject: response),
       let output = String(data: data, encoding: .utf8) {
        print(output)
        fflush(stdout)
    }
}
#endif
