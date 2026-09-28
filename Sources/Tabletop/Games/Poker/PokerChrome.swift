//
//  PokerChrome.swift
//  Two small things the poker table needs that the kit does not have: the
//  hand's result said in the pot's place, and the words printed under the
//  pot's chips.
//
//  WHY NOT A BANNER. The kit's `Banner` is the result of a hand in the middle
//  of the table — and the middle of a poker table is the board, whose five
//  winning cards are lifted and lit at exactly that moment. A banner there
//  would hide the very thing it announces. So the hand's result is a
//  one-line glass capsule of the same material and type, in the place the
//  pot has just left, over the board rather than on it. (The tournament's
//  end, which has nothing on the board to show, is a real `Banner`.)
//

import AppKit
import QuartzCore

/// "Anna wins 1,240 — Flush, Ace high": one line in a glass capsule, over
/// the board. One line, because the room between the board and the seat
/// across the table is one line high at the smallest window; when the whole
/// line would reach a shown hand, the hand is named by its kind alone
/// ("Flush"), and failing that the winner alone is said.
final class PokerResultPill: NSView {

    private let panel = GlassPanel(capsule: true)
    private let label = Typography.label("", font: PokerResultPill.titleFont)
    private(set) var text: PokerResultText?
    /// The line on show, as chosen for the room there is.
    private(set) var shownLine = ""
    private var anchor: CGPoint = .zero
    private var maxWidth: CGFloat = .greatestFiniteMagnitude

    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let handFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    private static let padding: CGFloat = 20

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        label.alignment = .center
        panel.contentView.addSubview(label)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // the table keeps its clicks

    /// Shows `text` centred on `point`, no wider than `maxWidth`, or hides
    /// the pill for nil.
    func show(_ text: PokerResultText?, at point: CGPoint, maxWidth: CGFloat, animated: Bool) {
        anchor = point
        self.maxWidth = maxWidth
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
    func move(to point: CGPoint, maxWidth: CGFloat) {
        anchor = point
        self.maxWidth = maxWidth
        if text != nil { place() }
    }

    /// The winner in the title's weight (gold when it is the player), the
    /// hand after a dash in the lighter one.
    private func line(_ text: PokerResultText, hand: String) -> NSAttributedString {
        let titleColor = text.humanWon ? Palette.accentSoft : Palette.textPrimary
        let line = NSMutableAttributedString(string: text.title,
                                             attributes: Typography.attributes(Self.titleFont, titleColor, alignment: .center))
        if !hand.isEmpty {
            line.append(NSAttributedString(string: " — " + hand,
                                           attributes: Typography.attributes(Self.handFont, Palette.textSecondary,
                                                                             alignment: .center)))
        }
        return line
    }

    private func place() {
        guard let text else { return }
        // The longest that fits: the whole hand, its kind, or nothing.
        var hands = [text.subtitle]
        if !text.shortSubtitle.isEmpty && text.shortSubtitle != text.subtitle { hands.append(text.shortSubtitle) }
        if !text.subtitle.isEmpty { hands.append("") }
        var chosen = line(text, hand: "")
        var chosenWidth: CGFloat = 0
        for hand in hands {
            let candidate = line(text, hand: hand)
            label.attributedStringValue = candidate
            let width = Typography.fittingWidth(label) + Self.padding * 2
            chosen = candidate
            chosenWidth = width
            if width <= maxWidth { break }
        }
        label.attributedStringValue = chosen
        shownLine = chosen.string
        let width = ceil(max(160, min(chosenWidth, max(160, maxWidth))))
        let height = PokerLayout.resultHeight
        frame = CGRect(x: (anchor.x - width / 2).rounded(), y: (anchor.y - height / 2).rounded(),
                       width: width, height: height)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: Self.padding - 4, y: ((bounds.height - height) / 2).rounded(),
                             width: bounds.width - (Self.padding - 4) * 2, height: height)
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

    /// How wide the capsule saying `text` at `fontSize` is — for laying out
    /// a row before it is drawn.
    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        let font = Typography.number(fontSize, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width + fontSize * 1.6)
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
