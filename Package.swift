// swift-tools-version:5.9
import PackageDescription

// Built with SwiftPM only (no Xcode required). Tools-version 5.9 keeps the
// target in Swift 5 language mode, which is what we want: AppKit is not
// fully Sendable-audited and strict concurrency would drown the app in
// false positives for no runtime benefit. Everything UI-facing is @MainActor
// by construction; the solver is the only background work and is explicitly
// isolated.
let package = Package(
    name: "Solitaire",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Solitaire", targets: ["Solitaire"])
    ],
    targets: [
        .executableTarget(name: "Solitaire", path: "Sources/Solitaire")
    ]
)
