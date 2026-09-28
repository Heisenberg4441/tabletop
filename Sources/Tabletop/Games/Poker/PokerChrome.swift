//
//  PokerChrome.swift
//  Two small things the poker table needs that the kit does not have: the
//  hand's result said in the pot's place, and the words printed under the
//  pot's chips.
//
//  WHY NOT A BANNER. The kit's `Banner` is the result of a hand in the middle
//  of the table — and the middle of a poker table is the board, whose five
//  winning cards are lifted and lit at exactly that moment. A banner there
//  would hide the very thing it announces. So the hand's result is a smaller
//  glass card of the same material and type, in the place the pot has just
//  left, over the board rather than on it. (The tournament's end, which has
//  nothing on the board to show, is a real `Banner`.)
//

import AppKit
import QuartzCore

/// "Anna wins 1,240" over "Flush, Ace high", in glass, over the board.
final class PokerResultPill: NSView {

    private let panel = GlassPanel(cornerRadius: 16)
    private let titleLabel = Typography.label("", font: Typography.title2)
    private let subtitleLabel = Typography.label("", font: Typography.callout, color: Palette.textSecondary)
    private(set) var text: PokerResultText?
    private var anchor: CGPoint = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        titleLabel.alignment = .center
        subtitleLabel.alignment = .center
        panel.contentView.addSubview(titleLabel)
        panel.contentView.addSubview(subtitleLabel)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // the table keeps its clicks

    /// Shows `text` centred on `point`, or hides the pill for nil.
    func show(_ text: PokerResultText?, at point: CGPoint, animated: Bool) {
        anchor = point
        guard let text else {
            guard self.text != nil else { return }
            self.text = nil
            if animated && Motion.isEnabled && !isHidden {
                Motion.dismiss(self) { [weak self] in
                    guard self?.text == nil else { return }
                    self?.isHidden = true
                }
            } else {
                isHidden = true
            }
            return
        }
        let changed = text != self.text
        self.text = text
        titleLabel.stringValue = text.title
        titleLabel.textColor = text.humanWon ? Palette.accentSoft : Palette.textPrimary
        subtitleLabel.stringValue = text.subtitle
        subtitleLabel.isHidden = text.subtitle.isEmpty
        setAccessibilityLabel([text.title, text.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        place()
        if changed || isHidden {
            isHidden = false
            if animated { Motion.present(self, spring: .gentle, from: 0.94, rise: 6) } else { alphaValue = 1 }
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: accessibilityLabel() ?? text.title,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Re-centres the pill — from the table's `layoutTable()`.
    func move(to point: CGPoint) {
        anchor = point
        place()
    }

    private func place() {
        let titleSize = titleLabel.intrinsicContentSize
        let subtitleSize = subtitleLabel.isHidden ? .zero : subtitleLabel.intrinsicContentSize
        let width = ceil(max(200, max(titleSize.width, subtitleSize.width) + 44))
        let height = ceil(titleSize.height + (subtitleLabel.isHidden ? 0 : subtitleSize.height + 1) + 20)
        frame = CGRect(x: (anchor.x - width / 2).rounded(), y: (anchor.y - height / 2).rounded(),
                       width: width, height: height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let titleHeight = titleLabel.intrinsicContentSize.height
        let subtitleHeight = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.height
        let top = ((bounds.height - titleHeight - (subtitleLabel.isHidden ? 0 : subtitleHeight + 1)) / 2).rounded()
        titleLabel.frame = CGRect(x: 12, y: top, width: bounds.width - 24, height: titleHeight)
        subtitleLabel.frame = CGRect(x: 12, y: top + titleHeight + 1, width: bounds.width - 24, height: subtitleHeight)
    }
}

/// Words printed in a small dark capsule on the cloth — "Main pot 1,240" —
/// in the same style as the amount under a `ChipStackLayer`, so the pot's
/// label and a bet's label read as one family.
final class PokerCapsuleLabelLayer: CALayer {

    private(set) var text = ""
    private var fontSize: CGFloat = 12

    override init() {
        super.init()
        contentsGravity = .center
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        if let other = layer as? PokerCapsuleLabelLayer {
            text = other.text
            fontSize = other.fontSize
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func action(forKey event: String) -> CAAction? { nil }

    /// Sets the words and the letter size; the layer sizes itself round them.
    func set(_ text: String, fontSize: CGFloat) {
        guard text != self.text || fontSize != self.fontSize || contents == nil else { return }
        self.text = text
        self.fontSize = fontSize
        redraw()
    }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue, !text.isEmpty { redraw() } }
    }

    private func redraw() {
        let font = Typography.number(fontSize, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let box = CGSize(width: ceil(size.width + fontSize * 1.6), height: ceil(size.height + fontSize * 0.42))
        let image = ChipRenderer.render(size: box, scale: max(1, contentsScale)) { ctx in
            let rect = CGRect(origin: .zero, size: box).insetBy(dx: 0.5, dy: 0.5)
            let path = ContinuousShape.capsule(rect)
            ctx.addPath(path)
            ctx.setFillColor(NSColor(white: 0.04, alpha: 0.62).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            (text as NSString).draw(in: CGRect(x: 0, y: (box.height - size.height) / 2, width: box.width, height: size.height),
                                    withAttributes: Typography.attributes(font, Palette.textPrimary, alignment: .center))
            NSGraphicsContext.restoreGraphicsState()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let keep = position
        bounds = CGRect(origin: .zero, size: box)
        position = keep
        contents = image
        CATransaction.commit()
    }
}
