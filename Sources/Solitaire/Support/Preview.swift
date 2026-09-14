//
//  Preview.swift
//  `Solitaire --preview <path>` renders a contact sheet of the whole deck.
//  Iterating on card art by launching the game and squinting at it is slow;
//  this puts every card side by side at a readable size.
//

import AppKit

enum Preview {

    static func renderDeck(to path: String, apple: Bool = false,
                           cardWidth: CGFloat = 120, scale: CGFloat = 2) -> Int32 {
        var theme = Theme()
        theme.apple = apple
        let height = (cardWidth / 0.70).rounded()
        let renderer = CardRenderer(theme: theme, size: CGSize(width: cardWidth, height: height), scale: scale)

        let columns = 13
        let rows = 5   // four suits plus a row of backs and empty slots
        let gap = cardWidth * 0.12
        let margin = cardWidth * 0.35
        let sheet = CGSize(
            width: margin * 2 + CGFloat(columns) * cardWidth + CGFloat(columns - 1) * gap,
            height: margin * 2 + CGFloat(rows) * height + CGFloat(rows - 1) * gap
        )

        guard let ctx = CGContext(
            data: nil,
            width: Int(sheet.width * scale), height: Int(sheet.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return 1 }

        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: sheet.height)
        ctx.scaleBy(x: 1, y: -1)

        // The felt, so the cards are judged against the background they live on.
        let (center, edge) = apple ? theme.table.appleGradient : theme.table.gradient
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [center.cgColor, edge.cgColor] as CFArray,
                                     locations: [0, 1]) {
            ctx.saveGState()
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: sheet.width / 2, y: sheet.height / 2), startRadius: 0,
                endCenter: CGPoint(x: sheet.width / 2, y: sheet.height / 2),
                endRadius: max(sheet.width, sheet.height) * 0.75,
                options: [.drawsAfterEndLocation]
            )
            ctx.restoreGState()
        }

        func place(_ image: CGImage?, row: Int, column: Int) {
            guard let image else { return }
            let x = margin + CGFloat(column) * (cardWidth + gap)
            let y = margin + CGFloat(row) * (height + gap)
            let rect = CGRect(x: x, y: y, width: cardWidth, height: height)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -cardWidth * 0.022),
                          blur: cardWidth * 0.055,
                          color: NSColor.black.withAlphaComponent(0.42).cgColor)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
            ctx.restoreGState()
        }

        for suit in Suit.allCases {
            for rank in Rank.allCases {
                place(renderer.faceImage(for: Card(suit, rank)),
                      row: Int(suit.rawValue), column: Int(rank.rawValue) - 1)
            }
        }

        // Last row: every card back, then the four-colour deck's aces.
        var column = 0
        for style in CardBackStyle.allCases {
            var t = theme
            t.backStyle = style
            let r = CardRenderer(theme: t, size: CGSize(width: cardWidth, height: height), scale: scale)
            place(r.backImage(), row: 4, column: column)
            column += 1
        }
        for color in CardBackColor.allCases where column < columns {
            var t = theme
            t.backColor = color
            let r = CardRenderer(theme: t, size: CGSize(width: cardWidth, height: height), scale: scale)
            place(r.backImage(), row: 4, column: column)
            column += 1
        }
        var fourColor = theme
        fourColor.fourColorDeck = true
        let fourRenderer = CardRenderer(theme: fourColor, size: CGSize(width: cardWidth, height: height), scale: scale)
        for suit in Suit.allCases where column < columns {
            place(fourRenderer.faceImage(for: Card(suit, .ace)), row: 4, column: column)
            column += 1
        }

        guard let image = ctx.makeImage() else { return 1 }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(Int(sheet.width))x\(Int(sheet.height)) @\(Int(scale))x)")
            return 0
        } catch {
            print("failed: \(error)")
            return 1
        }
    }
}
