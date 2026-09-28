//
//  Screenshot.swift
//  `Tabletop --shot <library|kit|game id> <out.png>` photographs a screen
//  off-screen. `kit` is the gallery of every shared component (KitGallery).
//
//  Checking a change by launching the app and taking a screen grab is slow,
//  interrupts whatever else is on the screen, and cannot be scripted. This
//  builds the real window — the same controller, the same views, the same
//  renderer — never puts it on screen, and draws it into a bitmap at 2×: the
//  game's own `snapshotImage`, with the window's chrome (the Library button)
//  laid over it where it would really sit. The traffic lights are the one
//  thing missing; they belong to the window server.
//
//      --scenario NAME   one of the game's `screenshotScenarios` (default: its first)
//      --width W         content size in points, default 1200
//      --height H        default 800
//      --table COLOUR    green, blue, burgundy or slate
//
//  Solitaire keeps the flags it has always had: --deal N, --moves N, --draw 1|3.
//

import AppKit

@MainActor
enum Screenshot {

    static func run(target rawTarget: String?, path rawPath: String?) -> Int32 {
        // The solitaire-only app took `--shot <path>`; that still means the
        // solitaire board.
        var targetName = rawTarget
        var path = rawPath
        if let name = targetName, name.hasSuffix(".png"), path == nil {
            targetName = GameID.solitaire.rawValue
            path = name
        }
        guard let targetName, let path else {
            return fail("usage: --shot <library|kit|\(GameID.allCases.map(\.rawValue).joined(separator: "|"))> <out.png>")
        }
        let game = GameID(rawValue: targetName)
        guard game != nil || targetName == "library" || targetName == "kit" else {
            return fail("shot: no such screen '\(targetName)'")
        }
        let isKit = targetName == "kit"

        let width = TabletopEnvironment.value(of: "--width").flatMap(Double.init)
            ?? (isKit ? Double(KitGallery.defaultSize.width) : 1200)
        let height = TabletopEnvironment.value(of: "--height").flatMap(Double.init)
            ?? (isKit ? Double(KitGallery.defaultSize.height) : 800)
        let size = CGSize(width: max(320, width), height: max(240, height))
        if let raw = TabletopEnvironment.value(of: "--table") {
            guard let colour = TableColor(rawValue: raw) else { return fail("shot: no such table colour '\(raw)'") }
            TablePreferences.current.table = colour
        }
        let scenario = TabletopEnvironment.value(of: "--scenario")
        if isKit, let scenario, !KitGallery.scenarios.contains(scenario) {
            return fail("shot: the kit has no scenario '\(scenario)' — try \(KitGallery.scenarios.joined(separator: ", "))")
        }
        if let game, let scenario {
            let known = GameCatalog.type(for: game).screenshotScenarios
            guard known.contains(scenario) else {
                return fail("shot: \(game.rawValue) has no scenario '\(scenario)'"
                            + (known.isEmpty ? "" : " — try \(known.joined(separator: ", "))"))
            }
        }

        TabletopEnvironment.isRenderingSnapshot = true
        if isKit { return shootKit(size: scenario == nil || scenario == "gallery" ? size : CGSize(
            width: TabletopEnvironment.value(of: "--width").flatMap(Double.init) ?? 1200,
            height: TabletopEnvironment.value(of: "--height").flatMap(Double.init) ?? 800), scenario: scenario, path: path) }
        let controller = TabletopWindowController()
        guard let window = controller.window else { return fail("shot: no window") }
        window.setContentSize(size)

        let image: CGImage?
        if let game {
            controller.show(.game(game), animated: false)
            let screen = controller.game(for: game)
            settle(window)
            screen.prepareForScreenshot(scenario: scenario ?? GameCatalog.type(for: game).screenshotScenarios.first)
            settle(window)
            image = screen.snapshotImage(size: size)
        } else {
            controller.library.prepareForScreenshot()
            settle(window)
            image = LayerSnapshot.image(of: controller.library.view, size: size, scale: 2)
        }
        guard let image else { return fail("shot: the screen produced no image") }

        // The chrome goes over the top, at the same 2×.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return fail("shot: no bitmap") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
        controller.renderChrome(into: ctx, size: size)

        guard let composed = ctx.makeImage(), LayerSnapshot.writePNG(composed, to: path) else { return 1 }
        print("wrote \(path) — \(targetName)\(scenario.map { ", \($0)" } ?? ""), \(Int(size.width))×\(Int(size.height)) @2x")
        return 0
    }

    /// The kit gallery: every shared component on one table, in a borderless
    /// window of its own that is never shown.
    private static func shootKit(size: CGSize, scenario: String?, path: String) -> Int32 {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let gallery = KitGallery.makeView(size: size, scenario: scenario)
        window.contentView = gallery
        gallery.frame = CGRect(origin: .zero, size: size)
        settle(window)
        guard let image = LayerSnapshot.image(of: gallery, size: size, scale: 2) else {
            return fail("shot: the kit gallery produced no image")
        }
        guard LayerSnapshot.writePNG(image, to: path) else { return 1 }
        print("wrote \(path) — kit \(scenario ?? "gallery"), \(Int(size.width))×\(Int(size.height)) @2x")
        return 0
    }

    /// Lets the window lay out and the layer tree fill in. A few turns of the
    /// run loop, because some of what a screen shows arrives on the main queue
    /// a moment after the state change that asked for it.
    private static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 1
    }
}
