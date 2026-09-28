//
//  WindowChrome.swift
//  The window's own furniture: the dark room behind every screen, the strip
//  under the transparent titlebar, and the glass capsule that leads back to
//  the library.
//
//  The window has no visible titlebar. Every screen runs right up to the top
//  edge, leaving the strip there to the dark room; the traffic lights sit in
//  it, and the one control the window itself adds — Library — sits beside
//  them. That strip still has to behave like a titlebar: a drag there moves
//  the window and a double-click zooms it, whatever the screen has put
//  underneath.
//

import AppKit

/// The window's content view: the dark room the screens sit in, and the one
/// view that hears about every resize.
final class TabletopRootView: NSView {

    /// Called after every layout pass, so the chrome can follow the traffic
    /// lights through resizes and in and out of full screen.
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = TabletopRootView.roomColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    /// Nearly black and a touch warm — the colour of the room a lamp-lit table
    /// sits in. Shows only for the instant a screen is crossfading in.
    static let roomColor = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.060, alpha: 1)

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The strip along the top of the window that belongs to the window.
///
/// Transparent, and laid over whichever screen is showing. It answers the
/// mouse itself — a drag moves the window, a double-click does whatever the
/// player chose for titlebars in System Settings — because the screens under
/// it are mostly opaque views, and an opaque view under a transparent titlebar
/// swallows the click that should have moved the window. Scrolling passes
/// straight through to the screen underneath.
final class WindowChromeView: NSView {

    /// Where scroll events go: the screen host under the strip.
    weak var passThrough: NSView?

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        // A control in the strip takes its own clicks; anywhere else is ours.
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performTitlebarDoubleClick(on: window)
            return
        }
        window.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let passThrough, let root = passThrough.superview else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        (passThrough.hitTest(point) ?? passThrough).scrollWheel(with: event)
    }

    /// What double-clicking a titlebar does is the player's choice, made in
    /// System Settings ▸ Desktop & Dock: zoom, minimise, or nothing.
    static func performTitlebarDoubleClick(on window: NSWindow) {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// The soft darkening along the top edge of the window, under the chrome.
///
/// Every screen leaves the strip to the room (see `TabletopChrome`), so the
/// Library capsule, the title and the pills always sit on the same quiet,
/// near-black surface. This deepens it a touch towards the very top and lets
/// a few points of shade spill onto whatever starts below — the table's
/// frame — the way a ledge darkens what is just under it; over the dark
/// library it is barely there. It takes no clicks.
final class WindowEdgeShadeView: NSView {

    /// How far below the strip the shade fades out.
    static let overhang: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            NSColor(white: 0, alpha: 0.46).cgColor,
            NSColor(white: 0, alpha: 0.22).cgColor,
            NSColor(white: 0, alpha: 0).cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
        // The root view is not flipped: the top of this view is its maxY.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    /// The view's own layer is the gradient, so it is always exactly the
    /// view's size with nothing to keep in step.
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The game's name, centred in the strip. Says where you are without a
/// titlebar; takes no clicks, so a drag on it still moves the window.
final class ChromeTitleView: NSView {

    let label = Typography.label("", font: .systemFont(ofSize: 13, weight: .semibold),
                                 color: NSColor(white: 1, alpha: 0.86))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.alignment = .center
        addSubview(label)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.5)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        label.shadow = shadow
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue; needsLayout = true }
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 0, y: ((bounds.height - size.height) / 2).rounded(), width: bounds.width,
                             height: size.height)
    }
}

/// The row of status pills at the right-hand end of the strip: whatever the
/// game in front last posted to `TopBarStatus`. Updates pills in place by id,
/// so a ticking number changes without the row rebuilding.
final class StatusPillRow: NSView {

    private var pills: [StatusPillView] = []
    static let spacing: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setItems(_ items: [StatusPillItem], animated: Bool) {
        var kept: [StatusPillView] = []
        for item in items {
            if let existing = pills.first(where: { $0.item.id == item.id }) {
                if existing.item != item { existing.apply(item) }
                kept.append(existing)
            } else {
                let pill = StatusPillView(item: item)
                addSubview(pill)
                kept.append(pill)
                if animated { needsFadeIn.append(pill) }
            }
        }
        for gone in pills where !kept.contains(where: { $0 === gone }) {
            if animated {
                Motion.dismiss(gone) { gone.removeFromSuperview() }
            } else {
                gone.removeFromSuperview()
            }
        }
        pills = kept
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private var needsFadeIn: [StatusPillView] = []

    override var intrinsicContentSize: NSSize {
        let widths = pills.map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + CGFloat(max(0, pills.count - 1)) * Self.spacing
        return NSSize(width: ceil(total), height: StatusPillView.height)
    }

    override func layout() {
        super.layout()
        var x = bounds.maxX
        for pill in pills.reversed() {
            let size = pill.intrinsicContentSize
            x -= size.width
            pill.frame = CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width,
                                height: size.height)
            x -= Self.spacing
        }
        for pill in needsFadeIn { Motion.present(pill, spring: .smooth, from: 0.94, rise: 0) }
        needsFadeIn.removeAll()
    }
}
