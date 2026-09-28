//
//  TableBadge.swift
//  A small glass label pinned to a point on the table: "Bust" over a
//  blackjack hand, "Raise 80" by a poker seat, "Takes" beside a durak player,
//  a hand's total, a showdown's hand name.
//
//  The kit's other two ways of saying something are for the whole table: a
//  `Banner` is the one result in the middle, a `Toast` the one passing remark
//  along an edge. A badge belongs to a place instead, so there can be as many
//  as there are places — one per split hand, one per seat — and each stays
//  where it was put until the game moves it, changes it or takes it away.
//
//  It is chrome, like the others: a glass capsule in SF Pro, the words in the
//  tone's colour, never taking a click (the card or seat under it still gets
//  it) and read out by VoiceOver when it appears or changes. Nothing about it
//  moves on its own. Place badges from `layoutTable()` with `move(to:)`, so
//  they follow the table through a resize.
//

import AppKit

final class TableBadge: NSView {

    /// Which side of the point the badge sits on.
    enum Anchor {
        /// Centred above it, its bottom edge a few points clear — over a hand.
        case above
        /// Centred below it — under a seat.
        case below
        /// To its left, centred vertically — beside a hand's left edge.
        case leading
        /// To its right, centred vertically — a total beside a hand, a word
        /// beside a seat's plate.
        case trailing
        /// Centred on it.
        case center
    }

    private let panel = GlassPanel(capsule: true)
    private let symbolView = NSImageView()
    private let label = Typography.label("", font: TableBadge.font)
    private(set) var text: String
    private(set) var symbolName: String?
    private(set) var tone: Banner.Tone
    private var point: CGPoint = .zero
    private var anchor: Anchor = .above

    static let height: CGFloat = 26
    private static let font = Typography.monospacedDigits(.systemFont(ofSize: 12.5, weight: .semibold))
    /// Gap between the badge and its point, for `.above` and `.below`.
    private static let clearance: CGFloat = 6

    private struct WeakBadge { weak var badge: TableBadge? }
    private static var showing: [WeakBadge] = []

    private init(text: String, symbolName: String?, tone: Banner.Tone) {
        self.text = text
        self.symbolName = symbolName
        self.tone = tone
        super.init(frame: .zero)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        panel.contentView.addSubview(symbolView)
        panel.contentView.addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // the table under it keeps its clicks

    // MARK: Showing

    /// Pins a badge saying `text` to `point` (in `host`'s coordinates) and
    /// returns it. Any number may be up in one host at once.
    @discardableResult
    static func show(_ text: String, symbolName: String? = nil, tone: Banner.Tone = .neutral, in host: NSView,
                     at point: CGPoint, anchor: Anchor = .above, animated: Bool = true) -> TableBadge {
        let badge = TableBadge(text: text, symbolName: symbolName, tone: tone)
        host.addSubview(badge)
        badge.move(to: point, anchor: anchor)
        showing.removeAll { $0.badge == nil }
        showing.append(WeakBadge(badge: badge))
        if animated { Motion.present(badge, spring: .smooth, from: 0.9, rise: 4) }
        badge.announce()
        return badge
    }

    /// Changes what the badge says, in place — the total going from 12 to
    /// 19, "Call 40" becoming "Raise 120". It stays pinned to its point.
    func update(text: String, symbolName: String? = nil, tone: Banner.Tone = .neutral) {
        guard text != self.text || symbolName != self.symbolName || tone != self.tone else { return }
        let changedWords = text != self.text
        self.text = text
        self.symbolName = symbolName
        self.tone = tone
        apply()
        move(to: point, anchor: anchor)
        if changedWords { announce() }
    }

    /// Re-pins the badge — call it from the table's `layoutTable()`.
    func move(to point: CGPoint, anchor: Anchor? = nil) {
        self.point = point
        if let anchor { self.anchor = anchor }
        guard let host = superview else { return }
        let size = intrinsicContentSize
        var x = point.x - size.width / 2
        var y = point.y - size.height / 2
        switch self.anchor {
        case .above: y = host.isFlipped ? point.y - Self.clearance - size.height : point.y + Self.clearance
        case .below: y = host.isFlipped ? point.y + Self.clearance : point.y - Self.clearance - size.height
        case .leading: x = point.x - Self.clearance - size.width
        case .trailing: x = point.x + Self.clearance
        case .center: break
        }
        frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Takes the badge away.
    func hide(animated: Bool = true) {
        Self.showing.removeAll { $0.badge == nil || $0.badge === self }
        guard superview != nil else { return }
        if animated {
            Motion.dismiss(self) { [weak self] in self?.removeFromSuperview() }
        } else {
            removeFromSuperview()
        }
    }

    /// Every badge inside `host`.
    static func badges(in host: NSView) -> [TableBadge] {
        showing.compactMap(\.badge).filter { $0.isDescendant(of: host) }
    }

    /// Takes every badge inside `host` away — a new hand.
    static func hideAll(in host: NSView, animated: Bool = false) {
        for badge in badges(in: host) { badge.hide(animated: animated) }
    }

    // MARK: Drawing

    private var color: NSColor {
        switch tone {
        case .neutral: return Palette.textPrimary
        case .win: return Palette.positive
        case .loss: return Palette.negative
        }
    }

    private func apply() {
        label.stringValue = text
        label.textColor = color
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color.withAlphaComponent(0.85)])))
            symbolView.isHidden = false
        } else {
            symbolView.image = nil
            symbolView.isHidden = true
        }
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func announce() {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    override var intrinsicContentSize: NSSize {
        let words = Typography.fittingWidth(label)
        let symbol = symbolView.image.map { $0.size.width + 5 } ?? 0
        return NSSize(width: ceil(max(Self.height, words + symbol + 22)), height: Self.height)
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let words = Typography.fittingWidth(label)
        let symbol = symbolView.image?.size ?? .zero
        let total = words + (symbol.width > 0 ? symbol.width + 5 : 0)
        var x = ((bounds.width - total) / 2).rounded()
        if symbol.width > 0 {
            symbolView.frame = CGRect(x: x, y: ((bounds.height - symbol.height) / 2).rounded(),
                                      width: symbol.width, height: symbol.height)
            x += symbol.width + 5
        }
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: words, height: height)
    }
}
