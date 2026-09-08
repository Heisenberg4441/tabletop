//
//  main.swift
//  Entry point. A SwiftPM executable has no nib, so the application object,
//  its activation policy and the whole menu bar are set up here by hand — miss
//  any of the three and the app launches without a menu or a Dock icon.
//

import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if let i = arguments.firstIndex(of: "--preview") {
    let path = i + 1 < arguments.count ? arguments[i + 1] : "deck.png"
    exit(Preview.renderDeck(to: path))
}
if let i = arguments.firstIndex(of: "--icon") {
    let path = i + 1 < arguments.count ? arguments[i + 1] : "icon.png"
    exit(IconRenderer.render(to: path))
}
if let i = arguments.firstIndex(of: "--shot") {
    var options = Screenshot.Options()
    options.path = i + 1 < arguments.count ? arguments[i + 1] : "board.png"
    func value(_ flag: String) -> Int? {
        guard let j = arguments.firstIndex(of: flag), j + 1 < arguments.count else { return nil }
        return Int(arguments[j + 1])
    }
    if let deal = value("--deal") { options.deal = deal }
    if let moves = value("--moves") { options.moves = moves }
    if let width = value("--width") { options.width = CGFloat(width) }
    if let height = value("--height") { options.height = CGFloat(height) }
    if let draw = value("--draw") { options.drawCount = draw }
    exit(Screenshot.render(options))
}
if let i = arguments.firstIndex(of: "--playtest") {
    let games = i + 1 < arguments.count ? (Int(arguments[i + 1]) ?? 60) : 60
    exit(PlayTest.run(games: games))
}
if let i = arguments.firstIndex(of: "--sounds") {
    let directory = i + 1 < arguments.count ? arguments[i + 1] : "."
    exit(Sound.exportAll(to: directory))
}
if arguments.contains("--controls") {
    exit(PlayTest.checkControls())
}
if arguments.contains("--golden") {
    SelfTest.printGoldenVectors()
    exit(0)
}
if arguments.contains("--benchmark") {
    exit(Benchmark.run())
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Solitaire"
application.mainMenu = MainMenu.build(appName: appName)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
