//
//  MessageOverlay.swift
//  A quiet panel that floats over the table.
//
//  Used for the one thing a solitaire player genuinely needs telling — that
//  there are no moves left. A modal alert for that would be heavy-handed: the
//  game is not over until the player says so, and they may well want to look at
//  the board for a while before undoing. So it is a glass card from the kit,
//  and the board underneath stays playable.
//

import AppKit

final class MessageOverlay: NSView {

    private let panel = GlassPanel(cornerRadius: Radius.panel)
    private let titleLabel = Typography.label("", font: Typography.title2)
    private let bodyLabel = Typography.label("", font: Typography.body, color: Palette.textSecondary)
    private var buttons: [CapsuleButton] = []

    private static let padding: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(panel)
        titleLabel.alignment = .center
        bodyLabel.alignment = .center
        panel.contentView.addSubview(titleLabel)
        panel.contentView.addSubview(bodyLabel)
        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Only the panel takes clicks; the board underneath stays playable, which
    /// matters because the panel's whole point is to let the player keep
    /// looking at the position.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return panel.frame.contains(local) ? super.hitTest(point) : nil
    }

    struct Action {
        var title: String
        var isDefault = false
        var handler: () -> Void
    }

    func show(title: String, body: String, actions: [Action], animated: Bool = true) {
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.isHidden = body.isEmpty

        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = CapsuleButton(title: action.title, style: action.isDefault ? .primary : .secondary) { [weak self] in
                self?.dismiss()
                action.handler()
            }
            if action.isDefault { button.keyEquivalent = "\r" }
            button.minimumWidth = 110
            panel.contentView.addSubview(button)
            return button
        }
        needsLayout = true
        layoutSubtreeIfNeeded()

        isHidden = false
        alphaValue = 1
        // A panel that was faded out last time is left transparent by
        // `Motion.dismiss`; `present` restores it, and so must a plain show.
        panel.alphaValue = 1
        if animated { Motion.present(panel) }
    }

    func dismiss(animated: Bool = true) {
        guard !isHidden else { return }
        guard animated, Motion.isEnabled else {
            alphaValue = 0
            isHidden = true
            return
        }
        Motion.dismiss(panel) { [weak self] in
            self?.isHidden = true
            self?.alphaValue = 0
        }
    }

    override func layout() {
        super.layout()
        let titleSize = titleLabel.intrinsicContentSize
        let bodySize = bodyLabel.isHidden ? .zero : bodyLabel.intrinsicContentSize
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let buttonsWidth = widths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * Spacing.m
        let width = ceil(max(320, titleSize.width, bodySize.width, buttonsWidth) + Self.padding * 2)
        var height = Self.padding + titleSize.height
        if !bodyLabel.isHidden { height += 4 + bodySize.height }
        if !buttons.isEmpty { height += Spacing.l + ControlHeight.regular }
        height += Self.padding
        panel.frame = CGRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(),
                             width: width, height: ceil(height))

        let inner = CGRect(x: Self.padding, y: 0, width: width - Self.padding * 2, height: height)
        var y = Self.padding
        titleLabel.frame = CGRect(x: inner.minX, y: y, width: inner.width, height: titleSize.height)
        y += titleSize.height
        if !bodyLabel.isHidden {
            bodyLabel.frame = CGRect(x: inner.minX, y: y + 4, width: inner.width, height: bodySize.height)
            y += 4 + bodySize.height
        }
        y += Spacing.l
        var x = ((width - buttonsWidth) / 2).rounded()
        for (button, w) in zip(buttons, widths) {
            button.frame = CGRect(x: x, y: y, width: w, height: ControlHeight.regular)
            x += w + Spacing.m
        }
    }
}
