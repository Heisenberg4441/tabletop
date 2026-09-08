//
//  IconRenderer.swift
//  `Solitaire --icon <path>` draws the app icon.
//
//  Drawn rather than shipped so the icon always matches the cards in the game,
//  and so the repository holds no binary assets at all.
//

import AppKit

enum IconRenderer {

    static func render(to path: String, size: Int = 1024) -> Int32 {
        let s = CGFloat(size)
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return 1 }

        ctx.translateBy(x: 0, y: s)
        ctx.scaleBy(x: 1, y: -1)

        // macOS icons sit in a rounded square with a generous margin; going
        // edge to edge makes an app look like it was ported from somewhere else.
        let margin = s * 0.086
        let plate = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
        let radius = plate.width * 0.2237       // the macOS "squircle" proportion
        let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.030,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(platePath)
        ctx.setFillColor(NSColor(srgbRed: 0.098, green: 0.318, blue: 0.216, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(platePath)
        ctx.clip()
        let theme = Theme()
        let (center, edge) = theme.table.gradient
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [center.cgColor, edge.cgColor] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: plate.midX, y: plate.midY * 0.86), startRadius: 0,
                endCenter: CGPoint(x: plate.midX, y: plate.midY), endRadius: plate.width * 0.78,
                options: [.drawsAfterEndLocation])
        }

        // Three cards fanned out of the corner: a back, then the two aces that
        // read best at small sizes.
        let cardWidth = plate.width * 0.42
        let cardSize = CGSize(width: cardWidth, height: (cardWidth / 0.70).rounded())
        let renderer = CardRenderer(theme: theme, size: cardSize, scale: 1)

        let cards: [(image: CGImage?, angle: CGFloat, dx: CGFloat, dy: CGFloat)] = [
            (renderer.backImage(), -0.30, -0.20, 0.05),
            (renderer.faceImage(for: Card(.hearts, .ace)), -0.09, 0.02, -0.01),
            (renderer.faceImage(for: Card(.spades, .ace)), 0.16, 0.24, 0.04),
        ]

        for card in cards {
            guard let image = card.image else { continue }
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: s * 0.010), blur: s * 0.026,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.translateBy(x: plate.midX + plate.width * card.dx,
                            y: plate.midY + plate.height * card.dy)
            ctx.rotate(by: card.angle)
            let rect = CGRect(x: -cardSize.width / 2, y: -cardSize.height / 2,
                              width: cardSize.width, height: cardSize.height)
            ctx.translateBy(x: 0, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // A hairline highlight along the top edge, the way system icons catch light.
        ctx.addPath(platePath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(s * 0.004)
        ctx.strokePath()

        guard let image = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return 1 }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return 0
        } catch {
            FileHandle.standardError.write(Data("icon: \(error)\n".utf8))
            return 1
        }
    }
}
