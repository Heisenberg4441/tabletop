//
//  MessageOverlay.swift
//  A quiet panel that floats over the table.
//
//  Used for the one thing a solitaire player genuinely needs telling — that
//  there are no moves left. A modal alert for that would be heavy-handed: the
//  game is not over until the player says so, and they may well want to look at
//  the board for a while before undoing.
//

import AppKit

final class MessageOverlay: NSView {

    private let panel = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 3

        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.distribution = .fillEqually

        let stack = NSStackView(views: [titleLabel, bodyLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
        ])

        isHidden = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError() }

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

    private var handlers: [Int: () -> Void] = [:]

    func show(title: String, body: String, actions: [Action], animated: Bool = true) {
        titleLabel.stringValue = title
        bodyLabel.stringValue = body
        bodyLabel.isHidden = body.isEmpty

        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        handlers.removeAll()
        for (i, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(tap(_:)))
            button.bezelStyle = .rounded
            button.tag = i
            if action.isDefault { button.keyEquivalent = "\r" }
            handlers[i] = action.handler
            buttons.addArrangedSubview(button)
        }

        isHidden = false
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }

    func dismiss(animated: Bool = true) {
        guard !isHidden else { return }
        guard animated else {
            alphaValue = 0
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }

    @objc private func tap(_ sender: NSButton) {
        let handler = handlers[sender.tag]
        dismiss()
        handler?()
    }
}
