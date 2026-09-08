//
//  Screenshot.swift
//  `Solitaire --shot <path>` renders the board off-screen to a PNG.
//
//  Checking a change by launching the game and taking a screen grab is slow,
//  interrupts whatever else is on screen, and cannot be scripted. This draws
//  the real view — the same layers, the same renderer — into a bitmap instead.
//

import AppKit

enum Screenshot {

    struct Options {
        var path = "board.png"
        var deal = 1
        var moves = 0
        var width: CGFloat = 1100
        var height: CGFloat = 760
        var drawCount = 1
        var theme = Theme()
    }

    static func render(_ options: Options) -> Int32 {
        // A window is needed for the view to lay out and for the layers to get
        // a backing scale, but it never has to appear.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var gameOptions = GameOptions()
        gameOptions.drawCount = options.drawCount
        let game = Game(dealNumber: options.deal, options: gameOptions)

        // Play a few sensible moves so the board looks like a game in progress
        // rather than an untouched deal.
        for _ in 0..<options.moves {
            guard let move = game.hint() else { break }
            guard game.perform(move) != nil else { break }
        }

        let frame = NSRect(x: 0, y: 0, width: options.width, height: options.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let board = BoardView(game: game, theme: options.theme)
        board.frame = frame
        window.contentView = board
        window.contentView?.layoutSubtreeIfNeeded()
        board.displayIfNeeded()

        // Let the run loop settle so the layer tree has its contents.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        board.displayIfNeeded()

        guard let layer = board.layer else { return 1 }
        let scale: CGFloat = 2
        guard let ctx = CGContext(
            data: nil,
            width: Int(options.width * scale), height: Int(options.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return 1 }
        ctx.scaleBy(x: scale, y: scale)
        // The board draws top-down; CALayer.render works bottom-up.
        ctx.translateBy(x: 0, y: options.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)

        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return 1 }
        do {
            try data.write(to: URL(fileURLWithPath: options.path))
            print("wrote \(options.path) — deal \(options.deal), \(options.moves) moves played")
            return 0
        } catch {
            FileHandle.standardError.write(Data("shot: \(error)\n".utf8))
            return 1
        }
    }
}
