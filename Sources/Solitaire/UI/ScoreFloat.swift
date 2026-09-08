//
//  ScoreFloat.swift
//  The "+10" that lifts off a card and fades.
//
//  The score already sits in the status bar, but a number that silently ticks
//  from 60 to 70 tells the player nothing about *which* of the things they just
//  did earned it. Putting the change where the move happened is what turns the
//  score from a running total into feedback — and it is the only way a player
//  ever discovers the −100 for recycling the stock in a draw-one game.
//

import AppKit
import QuartzCore

/// Short-lived text layers that rise off the table and fade out.
///
/// The pool owns them rather than letting each one delete itself on a timer,
/// because a timer needs a run loop and the off-screen play-test has none: it
/// plays thousands of moves in a tight loop, and per-move layers that only ever
/// get cleaned up by a callback would simply pile up. Sweeping on the way in
/// costs nothing and cannot be skipped.
final class ScoreFloatPool {

    private struct Live {
        let layer: CALayer
        let expires: CFTimeInterval
    }

    /// Long enough to read a three-digit number, short enough that a quick run
    /// of moves does not leave a column of them standing.
    private let lifetime: CFTimeInterval = 0.85
    /// A hard ceiling, so a burst of fast moves thins itself out instead of
    /// stacking into an unreadable pile.
    private let maximum = 5

    private var live: [Live] = []

    func show(_ delta: Int, currency: Bool, at point: CGPoint, size: CGFloat,
              in root: CALayer, theme: Theme, scale: CGFloat) {
        guard delta != 0 else { return }
        sweep(force: live.count >= maximum)

        let string = Self.format(delta, currency: currency)
        // The rounded face is the one macOS uses for scores and badges, and it
        // holds up at this size against a busy background better than the
        // default system face does.
        let plain = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = NSFont(descriptor: plain.fontDescriptor.withDesign(.rounded) ?? plain.fontDescriptor,
                          size: size) ?? plain

        let text = CATextLayer()
        text.string = string
        text.font = font
        text.fontSize = size
        text.alignmentMode = .center
        text.foregroundColor = (delta > 0 ? theme.scoreGainColor : theme.scoreLossColor).cgColor
        text.contentsScale = scale
        text.isWrapped = false

        // A dark badge behind the number rather than bare text.
        //
        // Half of these land on the felt, where pale text reads perfectly well,
        // and half land over the card that was just covered — and pale green on
        // a white card face is close to invisible. The plate is what makes the
        // two cases look the same, and it is sized to the string so it stays a
        // badge rather than becoming a banner.
        // The height is the font's own line box, untouched. A CATextLayer draws
        // its text from the top edge down and offers no way to centre it
        // vertically, so any padding added here would show up entirely under
        // the number and leave it sitting high in the pill. The line box
        // already carries the ascent and descent, which is the breathing room
        // the badge needs.
        let measured = (string as NSString).size(withAttributes: [.font: font])
        text.bounds = CGRect(x: 0, y: 0,
                             width: (measured.width + size * 0.62).rounded(),
                             height: measured.height.rounded())
        text.backgroundColor = NSColor(white: 0.04, alpha: 0.62).cgColor
        text.cornerRadius = text.bounds.height / 2
        text.cornerCurve = .continuous
        text.shadowColor = NSColor.black.cgColor
        text.shadowOpacity = 0.35
        text.shadowRadius = 3
        text.shadowOffset = CGSize(width: 0, height: 1)
        text.position = point
        // Above every card, including one in flight, but below the cards the
        // player is holding: a number is a comment on the move, not an object
        // on the table.
        text.zPosition = 1200
        text.isGeometryFlipped = true

        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = point.y
        rise.toValue = point.y - size * 2.6
        rise.duration = lifetime
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.6, 0.3, 1)

        // Held back so the number is fully opaque while it is closest to the
        // card it belongs to, and only thins out once it has cleared it.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.55, 1]
        fade.duration = lifetime

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.12, 1.0]
        pop.keyTimes = [0, 0.3, 1]
        pop.duration = lifetime * 0.45
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(text)
        text.opacity = 0
        text.position = CGPoint(x: point.x, y: point.y - size * 2.6)
        text.add(rise, forKey: "rise")
        text.add(fade, forKey: "fade")
        text.add(pop, forKey: "pop")
        CATransaction.commit()

        live.append(Live(layer: text, expires: CACurrentMediaTime() + lifetime))
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 0.05) { [weak self] in
            self?.sweep(force: false)
        }
    }

    /// Drops every number whose time is up. `force` also drops the oldest one
    /// still running, which is how the ceiling is kept.
    private func sweep(force: Bool) {
        let now = CACurrentMediaTime()
        var survivors: [Live] = []
        for entry in live {
            if entry.expires <= now {
                entry.layer.removeFromSuperlayer()
            } else {
                survivors.append(entry)
            }
        }
        if force, let oldest = survivors.first {
            oldest.layer.removeFromSuperlayer()
            survivors.removeFirst()
        }
        live = survivors
    }

    func removeAll() {
        live.forEach { $0.layer.removeFromSuperlayer() }
        live.removeAll()
    }

    /// A real minus sign rather than a hyphen: at this weight and size the
    /// hyphen sits too high and too short to read as a sign.
    static func format(_ delta: Int, currency: Bool) -> String {
        let sign = delta > 0 ? "+" : "\u{2212}"
        let magnitude = abs(delta)
        return currency ? "\(sign)$\(magnitude)" : "\(sign)\(magnitude)"
    }
}
