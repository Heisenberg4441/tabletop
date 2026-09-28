//
//  StatusPill.swift
//  The right-hand end of the window's top strip, where the game in front can
//  say what state the table is in: "Blinds 10/20", "Shoe 62%", "Trumps ♥".
//
//  The strip belongs to the window (see `TabletopChrome`), so a game does not
//  put views there itself. It describes what it wants shown — a few short
//  items — and the window lays them out as glass pills beside the edge,
//  opposite the Library button, for as long as that game is in front. Going
//  back to the library hides them; coming back shows them again as the game
//  last left them.
//
//      TopBarStatus.set([
//          StatusPillItem(id: "blinds", text: "Blinds 10/20", symbolName: "circle.grid.2x1"),
//          StatusPillItem(id: "hand", text: "Hand 14"),
//      ], for: .poker)
//
//  Pills are information, never controls: nothing in them is clickable, and
//  the strip stays draggable underneath them. Keep them few (three at most)
//  and short — a label and a number.
//

import AppKit

/// One pill in the top strip.
struct StatusPillItem: Equatable {
    /// Stable across updates — "blinds", "shoe" — so a changing number
    /// updates its pill in place rather than rebuilding the row.
    var id: String
    var text: String
    var symbolName: String?
    /// Gold rather than white: for the one fact the player should notice
    /// now ("Trumps ♥" on the first deal, "Last hand").
    var isEmphasized = false

    init(id: String, text: String, symbolName: String? = nil, isEmphasized: Bool = false) {
        self.id = id
        self.text = text
        self.symbolName = symbolName
        self.isEmphasized = isEmphasized
    }
}

/// Where games post their pills, and where the window reads them.
@MainActor
enum TopBarStatus {

    /// Posted on the main thread after any game's items change. The object is
    /// the `GameID`.
    static let didChange = Notification.Name("TopBarStatusDidChange")

    private static var items: [GameID: [StatusPillItem]] = [:]

    /// Replaces `game`'s pills. Cheap when nothing changed: the same items
    /// again post nothing, so a game may call this on every state change —
    /// a clock may call it every second.
    static func set(_ newItems: [StatusPillItem], for game: GameID) {
        guard items[game] ?? [] != newItems else { return }
        items[game] = newItems
        NotificationCenter.default.post(name: didChange, object: game)
    }

    /// `game`'s pills, as it last set them.
    static func items(for game: GameID) -> [StatusPillItem] {
        items[game] ?? []
    }

    /// Clears every game's pills — for the harness between runs.
    static func removeAll() {
        items.removeAll()
    }
}

/// A single pill: glass, a symbol, a few words. Sized by its contents.
final class StatusPillView: NSView {

    private(set) var item: StatusPillItem
    private let panel = GlassPanel(capsule: true)
    private let symbolView = NSImageView()
    private let label = Typography.label("", font: Typography.monospacedDigits(.systemFont(ofSize: 12, weight: .semibold)))

    static let height: CGFloat = 26

    init(item: StatusPillItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        panel.castsShadow = false
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        panel.contentView.addSubview(symbolView)
        panel.contentView.addSubview(label)
        apply(item)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // the strip under it stays draggable

    func apply(_ item: StatusPillItem) {
        self.item = item
        let color = item.isEmphasized ? Palette.accentSoft : Palette.textPrimary
        label.stringValue = item.text
        label.textColor = color
        if let name = item.symbolName, let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [item.isEmphasized ? Palette.accent : Palette.textSecondary])))
            symbolView.isHidden = false
        } else {
            symbolView.image = nil
            symbolView.isHidden = true
        }
        setAccessibilityLabel(item.text)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let text = Typography.fittingWidth(label)
        let symbol = symbolView.image.map { $0.size.width + 5 } ?? 0
        return NSSize(width: ceil(text + symbol + 22), height: Self.height)
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        var x: CGFloat = 12
        if let image = symbolView.image {
            symbolView.frame = CGRect(x: x, y: ((bounds.height - image.size.height) / 2).rounded(),
                                      width: image.size.width, height: image.size.height)
            x += image.size.width + 5
        }
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                             width: max(0, bounds.width - x - 8), height: size.height)
    }
}
