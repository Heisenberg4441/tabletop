// swift-tools-version:5.9
import PackageDescription

// Built with SwiftPM only (no Xcode required). Tools-version 5.9 keeps the
// target in Swift 5 language mode, which is what we want: AppKit is not
// fully Sendable-audited and strict concurrency would drown the app in
// false positives for no runtime benefit. Everything UI-facing is @MainActor
// by construction; the solitaire solver is the only background work and is
// explicitly isolated.
//
// One target, laid out by folder rather than by module:
//
//   App/            the shell — window, library, menu bar, the game contract
//   Kit/            everything more than one game uses — cards, the table
//                   surfaces, sound, storage, preferences, the test reporter
//   Games/<Name>/   one folder per game, and nothing outside it knows the
//                   game's insides beyond its `TabletopGame` conformance
//   Support/        the command-line harness — self-tests, screenshots, icon
//
// Separate SwiftPM modules would enforce those borders, but they would also
// force `public` onto every declaration the games share and cost a rebuild of
// the whole graph for a one-line change in the kit. The borders are a
// convention, written down in App/GameModule.swift.
let package = Package(
    name: "Tabletop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabletop", targets: ["Tabletop"])
    ],
    targets: [
        .executableTarget(name: "Tabletop", path: "Sources/Tabletop")
    ]
)
