//
//  BlackjackPrompt.swift
//  A question with two answers, in one strip of glass on the table:
//  "Insurance? 50 pays 2 to 1 · No Thanks · Take Insurance".
//
//  The kit's `Banner` asks its questions in a card in the middle of the
//  table, which on a blackjack table is exactly where the dealer's ace and
//  the player's hand are — the two things the insurance question is about.
//  This is the same glass, type and buttons laid out in one row, a third of
//  the height, and pinned over the printed insurance band, between the two
//  hands, so both stay in view while the player decides.
//
//  Its buttons answer their keys like any on the table; answering dismisses
//  it. It arrives on the kit's gentle spring and leaves as a Banner does,
//  both cuts under Reduce Motion.
//

import AppKit

final class BlackjackPrompt: NSView {

    /// Smoked a little deeper than the kit's glass: it sits on the printed
    /// lettering, which must not read through the question.
    private let panel = GlassPanel(cornerRadius: Radius.large, tint: NSColor(white: 0.02, alpha: 1))
    private let titleLabel = Typography.label("", font: Typography.title2)
    private let detailLabel = Typography.label("", font: Typography.callout, color: Palette.textSecondary)
    private var buttons: [CapsuleButton] = []
    private var center = CGPoint.zero

    private static let padding: CGFloat = 14
    static let height: CGFloat = 62

    init(title: String, detail: String, actions: [ChromeAction]) {
        super.init(frame: .zero)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        panel.contentView.addSubview(titleLabel)
        panel.contentView.addSubview(detailLabel)
        for action in actions {
            var wrapped = action
            let original = action.handler
            wrapped.handler = { [weak self] in
                self?.dismiss()
                original()
            }
            let button = CapsuleButton(wrapped, size: .regular)
            button.minimumWidth = 104
            buttons.append(button)
            panel.contentView.addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, detail].filter { !$0.isEmpty }.joined(separator: ". "))
        frame.size = intrinsicContentSize
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    /// Whether it is still on the table.
    var isShowing: Bool { superview != nil }

    /// Puts the prompt over `host`, centred on `point`, and says it aloud.
    func present(in host: NSView, at point: CGPoint) {
        center = point
        host.addSubview(self)
        place()
        layoutSubtreeIfNeeded()
        Motion.present(self, spring: .gentle, from: 0.96, rise: 6)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: accessibilityLabel() ?? "",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Re-pins it — the table was resized.
    func move(to point: CGPoint) {
        center = point
        place()
    }

    private func place() {
        let size = intrinsicContentSize
        frame = CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                       width: size.width, height: size.height)
    }

    /// Takes it away. Safe to call twice.
    func dismiss(animated: Bool = true) {
        guard superview != nil else { return }
        for button in buttons { button.retire() }
        if animated {
            Motion.dismiss(self) { [weak self] in self?.removeFromSuperview() }
        } else {
            removeFromSuperview()
        }
    }

    // MARK: Layout

    private var textWidth: CGFloat {
        ceil(max(Typography.fittingWidth(titleLabel), Typography.fittingWidth(detailLabel)))
    }

    override var intrinsicContentSize: NSSize {
        let buttonsWidth = buttons.map { $0.intrinsicContentSize.width }.reduce(0, +)
            + CGFloat(max(0, buttons.count - 1)) * Spacing.s
        return NSSize(width: ceil(Self.padding + 6 + textWidth + Spacing.xl + buttonsWidth + Self.padding),
                      height: Self.height)
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let titleHeight = titleLabel.intrinsicContentSize.height
        let detailHeight = detailLabel.intrinsicContentSize.height
        let top = ((bounds.height - titleHeight - detailHeight) / 2).rounded()
        let x = Self.padding + 6
        titleLabel.frame = CGRect(x: x, y: top, width: textWidth, height: titleHeight)
        detailLabel.frame = CGRect(x: x, y: top + titleHeight, width: textWidth, height: detailHeight)
        var right = bounds.width - Self.padding
        for button in buttons.reversed() {
            let size = button.intrinsicContentSize
            right -= size.width
            button.frame = CGRect(x: right, y: ((bounds.height - size.height) / 2).rounded(),
                                  width: size.width, height: size.height)
            right -= Spacing.s
        }
    }
}
