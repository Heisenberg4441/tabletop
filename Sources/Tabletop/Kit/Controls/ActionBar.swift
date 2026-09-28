//
//  ActionBar.swift
//  The capsule of glass at the bottom of the table that holds what the player
//  can do right now.
//
//  Every card game in the collection has one: Fold · Check · Raise in poker,
//  Hit · Stand · Double in blackjack, Take · Done in durak. It sits centred at
//  the bottom of the window, floats over the cloth, and swaps its buttons as
//  the hand moves on — a quick crossfade while the capsule springs to its new
//  width, so the player sees the choice change without the bar jumping.
//
//  A leading and a trailing accessory can ride along beside the buttons: a
//  `BetControl`, a hand total, a count of cards left. The bar measures them by
//  their `fittingSize`, so give an accessory an intrinsic size or constraints
//  that determine one.
//
//  Placement is the game's: `install(in:)` pins the bar to the bottom centre
//  of a view, and `reservedHeight` says how much of the table to keep clear
//  under it.
//
//  RESERVE FOR THE TALLEST BAR YOU WILL EVER SHOW. A table's `bottomReserve`
//  is part of its layout: change it and every card is resized and
//  re-rasterised, the oval or half-moon moves, and cards in flight snap to
//  where they were going. So a bar whose accessory comes and goes — poker's
//  `BetControl`, shown on the player's turn only — must not let its reserve
//  follow it. Set `minimumContentHeight = BetControl.height` once, and the
//  bar (and `reservedHeight`) keeps that height whether the control is in it
//  or not; or feed the table `ActionBar.reservedHeight(contentHeight:)` for
//  the tallest configuration up front.
//

import AppKit

final class ActionBar: NSView {

    /// Space between the bar and the bottom of the window.
    var bottomMargin: CGFloat = Spacing.xl {
        didSet { bottomConstraint?.constant = -bottomMargin }
    }

    /// Something to the left of the buttons — a bet control, a readout.
    var leadingAccessory: NSView? {
        didSet { replaceAccessory(oldValue, with: leadingAccessory) }
    }

    /// Something to the right of the buttons.
    var trailingAccessory: NSView? {
        didSet { replaceAccessory(oldValue, with: trailingAccessory) }
    }

    /// The bar's inside height never drops below this, whatever it holds —
    /// so `reservedHeight` stays put while accessories come and go. Set it
    /// to the tallest accessory the bar will ever carry
    /// (`BetControl.height`). Defaults to a row of regular buttons.
    var minimumContentHeight: CGFloat = ControlHeight.regular {
        didSet {
            guard minimumContentHeight != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// The actions on show, in order.
    private(set) var actions: [ChromeAction] = []

    private let panel = GlassPanel(capsule: true)

    /// A bar tall enough to hold a two-row accessory stops being a capsule —
    /// a capsule that tall reads as a lozenge — and takes the panel radius.
    private static let capsuleLimit: CGFloat = 60
    private var buttons: [CapsuleButton] = []
    private var outgoing: [CapsuleButton] = []
    private let leadingDivider = ActionBar.divider()
    private let trailingDivider = ActionBar.divider()
    private var bottomConstraint: NSLayoutConstraint?

    /// Inside padding and the gap between neighbours.
    private static let inset: CGFloat = 8
    private static let gap: CGFloat = 8
    /// Buttons in the bar are at least this wide, so short words make an even
    /// row.
    static let minimumButtonWidth: CGFloat = 92

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        panel.contentView.addSubview(leadingDivider)
        panel.contentView.addSubview(trailingDivider)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(NSLocalizedString("Actions", comment: "accessibility: the bar of game actions"))
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    // MARK: Placement

    /// Adds the bar to `host`, centred at the bottom, `bottomMargin` above
    /// the edge. Call once.
    func install(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let bottom = bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -bottomMargin)
        NSLayoutConstraint.activate([centerXAnchor.constraint(equalTo: host.centerXAnchor), bottom])
        bottomConstraint = bottom
    }

    /// How much of the bottom of the table the bar covers, margin included,
    /// plus a little air: what a table's layout should keep clear. Feed it to
    /// `CardTableView.bottomReserve` — and see the top of the file: it is
    /// only constant if `minimumContentHeight` covers every accessory.
    var reservedHeight: CGFloat { intrinsicContentSize.height + bottomMargin + Spacing.m }

    /// The reserve a bar whose contents are `contentHeight` tall would need,
    /// for a table that wants to size itself before its bar is built — e.g.
    /// `ActionBar.reservedHeight(contentHeight: BetControl.height)`.
    static func reservedHeight(contentHeight: CGFloat, bottomMargin: CGFloat = Spacing.xl) -> CGFloat {
        ceil(max(ControlHeight.regular, contentHeight) + inset * 2) + bottomMargin + Spacing.m
    }

    // MARK: Actions

    /// Shows `actions`, replacing whatever was there.
    ///
    /// When the ids are the same as before, in the same order, the buttons
    /// stay and are updated where they stand — a title ("Call 40" to "Call
    /// 80"), an enabled state, a handler — and only the capsule's width
    /// moves. When the set itself changes, the old buttons fade out as the
    /// new ones fade in and the capsule springs to its new width. Either way,
    /// a game can simply call this after every change of state. Unanimated
    /// (or under Reduce Motion), everything simply changes.
    func setActions(_ newActions: [ChromeAction], animated: Bool = true) {
        if newActions.map(\.id) == actions.map(\.id), buttons.count == newActions.count {
            let resized = zip(buttons, newActions).contains { $0.title != $1.title || $0.symbolName != $1.symbolName }
            actions = newActions
            for (button, action) in zip(buttons, newActions) {
                button.title = action.title
                button.symbolName = action.symbolName
                button.style = action.style
                button.keyEquivalent = action.keyEquivalent
                button.keyEquivalentModifierMask = action.modifiers
                button.isEnabled = action.isEnabled
                button.handler = action.handler
                if let label = action.accessibilityLabel { button.accessibilityTitle = label }
            }
            if resized {
                invalidateIntrinsicContentSize()
                needsLayout = true
                if animated && Motion.isEnabled && window != nil, let host = superview {
                    Motion.animate(duration: Motion.standard) { host.layoutSubtreeIfNeeded() }
                }
            }
            return
        }
        actions = newActions
        let old = buttons
        buttons = newActions.map { action in
            let button = CapsuleButton(action, size: .regular)
            button.minimumWidth = Self.minimumButtonWidth
            return button
        }
        for button in buttons { panel.contentView.addSubview(button) }

        let motion = animated && Motion.isEnabled && window != nil
        // The old buttons are done the moment they are replaced, even while
        // they fade: no key, no click, no handler — a quick second "r" must
        // not raise twice.
        for button in old { button.retire() }
        if motion {
            outgoing.append(contentsOf: old)
            for button in old { fade(button, to: 0, removeWhenDone: true) }
            for button in buttons {
                button.alphaValue = 1
                button.layer?.opacity = 1
                fade(button, from: 0, to: 1)
            }
        } else {
            old.forEach { $0.removeFromSuperview() }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        if motion, let host = superview {
            Motion.animate(duration: Motion.standard) { host.layoutSubtreeIfNeeded() }
        }
    }

    /// The button for the action with `id`, to enable or retitle it in place.
    func button(for id: String) -> CapsuleButton? {
        buttons.first { $0.identifier?.rawValue == id }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        button(for: id)?.isEnabled = enabled
        if let index = actions.firstIndex(where: { $0.id == id }) { actions[index].isEnabled = enabled }
    }

    func setTitle(_ title: String, for id: String) {
        guard let button = button(for: id) else { return }
        button.title = title
        if let index = actions.firstIndex(where: { $0.id == id }) { actions[index].title = title }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func fade(_ view: NSView, from: Float? = nil, to: Float, removeWhenDone: Bool = false) {
        guard let layer = view.layer else {
            if removeWhenDone { view.removeFromSuperview() }
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            guard removeWhenDone, let view else { return }
            view.removeFromSuperview()
            self?.outgoing.removeAll { $0 === view }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from ?? layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = to
        animation.duration = removeWhenDone ? Motion.quick : Motion.standard
        animation.timingFunction = Motion.easeOut
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = !removeWhenDone
        layer.opacity = to
        layer.add(animation, forKey: "actionBar.fade")
        CATransaction.commit()
    }

    private func replaceAccessory(_ old: NSView?, with new: NSView?) {
        // A bet slider the player clicked holds the keyboard; taking it out
        // of the window would leave the window itself as first responder and
        // the table deaf to its keys until the next click. Hand the keyboard
        // to the view the bar stands on instead.
        if let old, let window = old.window, let first = window.firstResponder as? NSView,
           first === old || first.isDescendant(of: old) {
            window.makeFirstResponder(superview)
        }
        old?.removeFromSuperview()
        if let new { panel.contentView.addSubview(new) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.separator.cgColor
        return view
    }

    // MARK: Layout

    private func accessorySize(_ view: NSView?) -> CGSize {
        guard let view, !view.isHidden else { return .zero }
        let intrinsic = view.intrinsicContentSize
        if intrinsic.width != NSView.noIntrinsicMetric, intrinsic.height != NSView.noIntrinsicMetric {
            return intrinsic
        }
        return view.fittingSize
    }

    private var contentHeight: CGFloat {
        max(ControlHeight.regular, minimumContentHeight,
            accessorySize(leadingAccessory).height, accessorySize(trailingAccessory).height)
    }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = 0
        var items = 0
        func add(_ w: CGFloat) {
            width += w
            items += 1
        }
        let leading = accessorySize(leadingAccessory)
        let trailing = accessorySize(trailingAccessory)
        if leading.width > 0 { add(leading.width); add(1) }
        for button in buttons { add(button.intrinsicContentSize.width) }
        if trailing.width > 0 { add(1); add(trailing.width) }
        let gaps = CGFloat(max(0, items - 1)) * Self.gap
        // A bar with nothing in it keeps a capsule's worth of width, so it
        // shrinks to a pill rather than to a line.
        let inner = max(width + gaps, ControlHeight.regular)
        return NSSize(width: ceil(inner + Self.inset * 2 + (leading.width > 0 ? 6 : 0) + (trailing.width > 0 ? 6 : 0)),
                      height: ceil(contentHeight + Self.inset * 2))
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        panel.isCapsule = bounds.height <= Self.capsuleLimit
        panel.cornerRadius = Radius.panel
        let height = contentHeight
        let midY = bounds.height / 2
        var x = Self.inset + (leadingAccessory.map { $0.isHidden ? 0 : 6 } ?? 0)

        let leading = accessorySize(leadingAccessory)
        if let accessory = leadingAccessory, leading.width > 0 {
            accessory.frame = CGRect(x: x, y: (midY - leading.height / 2).rounded(),
                                     width: leading.width, height: leading.height)
            x += leading.width + Self.gap
            leadingDivider.isHidden = false
            leadingDivider.frame = CGRect(x: x, y: (midY - height * 0.32).rounded(), width: 1, height: (height * 0.64).rounded())
            x += 1 + Self.gap
        } else {
            leadingDivider.isHidden = true
        }

        for button in buttons {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
            x += size.width + Self.gap
        }

        let trailing = accessorySize(trailingAccessory)
        if let accessory = trailingAccessory, trailing.width > 0 {
            trailingDivider.isHidden = false
            trailingDivider.frame = CGRect(x: x, y: (midY - height * 0.32).rounded(), width: 1, height: (height * 0.64).rounded())
            x += 1 + Self.gap
            accessory.frame = CGRect(x: x, y: (midY - trailing.height / 2).rounded(),
                                     width: trailing.width, height: trailing.height)
        } else {
            trailingDivider.isHidden = true
        }
        // Buttons still fading out keep their old places.
    }
}
