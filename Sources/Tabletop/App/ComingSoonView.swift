//
//  ComingSoonView.swift
//  The table a game shows before the game itself has been built.
//
//  Scaffolding. Pool, Poker, Blackjack and Durak are each being written in
//  their own folder, and until one lands its controller shows this: the real
//  cloth, dressed the way the player chose in the View menu, with a quiet glass
//  card (the kit's `GlassPanel`) in the middle saying what is coming. When the last of the four has
//  replaced its stub, nothing uses this file and it can go.
//

import AppKit

final class ComingSoonView: NSView {

    private let info: GameInfo
    /// The glass card in the middle. Visible to the harness, which checks it
    /// actually comes out with a size on every system.
    let panel = GlassPanel(cornerRadius: Radius.panel)
    private let stack = NSStackView()
    private var preferencesObserver: NSObjectProtocol?
    private var lastTopInset: CGFloat = 0

    init(info: GameInfo) {
        self.info = info
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let symbol = NSImageView()
        // A numbered-circle symbol (Pool's 8-ball) has two layers, the number
        // and the disc; with one palette colour the number is cut out of the
        // disc and shows the glass behind it, which is to say not at all.
        let colors: [NSColor] = info.symbolName.hasSuffix(".circle.fill")
            ? [NSColor(white: 0.08, alpha: 1), Palette.textPrimary] : [Palette.textPrimary]
        symbol.image = NSImage(systemSymbolName: info.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: colors)))

        let title = Typography.label(info.title, font: Typography.title)
        let subtitle = Typography.label(info.subtitle, font: Typography.body, color: Palette.textSecondary)
        let soon = Typography.label(NSLocalizedString("Coming soon", comment: "placeholder for an unfinished game"),
                                    font: Typography.caption, color: Palette.textTertiary)

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 44, bottom: 26, right: 44)
        for view in [symbol, title, subtitle, soon] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(12, after: symbol)
        stack.setCustomSpacing(14, after: subtitle)
        panel.contentView.addSubview(stack)
        addSubview(panel)

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: TablePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The window's strip is the room, like every other screen's; the
        // table starts under it.
        let band = min(TabletopChrome.topInset(for: self), bounds.height)
        TableSurface.paintTopBand(in: bounds, height: band, context: ctx)
        AppleStyle.drawTable(TablePreferences.current.table,
                             in: CGRect(x: bounds.minX, y: bounds.minY + band, width: bounds.width,
                                        height: max(1, bounds.height - band)),
                             context: ctx, cardWidth: 110)
    }

    override func layout() {
        super.layout()
        // Sized by hand from what is in it: the stack's own fitting size,
        // never narrower than 300 points, centred in the table.
        let fitting = stack.fittingSize
        let size = CGSize(width: max(300, ceil(fitting.width)), height: ceil(fitting.height))
        let top = TabletopChrome.topInset(for: self)
        panel.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                             y: (top + (bounds.height - top - size.height) / 2).rounded(),
                             width: size.width, height: size.height)
        // The band's height changes with full screen; repaint to follow it.
        if top != lastTopInset {
            lastTopInset = top
            needsDisplay = true
        }
        stack.frame = CGRect(origin: .zero, size: size)
    }

    /// The whole of a stub game's menu: New Game, where the real game will
    /// put it, greyed out — there is no game yet, and a menu item that looks
    /// live and does nothing is worse than one that is plainly not ready.
    /// (An item with no action is disabled by the menu's auto-enabling.)
    static func menu(for info: GameInfo) -> NSMenu {
        let menu = NSMenu(title: info.title)
        let item = NSMenuItem(title: NSLocalizedString("New Game", comment: ""), action: nil, keyEquivalent: "n")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
        return menu
    }
}
