//
//  PoolPlayerPlate.swift
//  A player at the top of the table: the kit's seat — avatar, name, one
//  line of detail, the ring that says whose turn it is and the gold sweep
//  while the computer thinks — and beside it, on its own strip of glass, the
//  balls that player still needs, drawn as tiny balls.
//
//  The kit's status pills carry words and an SF Symbol only, and a pool
//  player's group is best said with the balls themselves, so the plate sits
//  under the window's strip rather than in it.
//

import AppKit

final class PoolPlayerPlate: NSView {

    enum Side { case leading, trailing }

    let seat: SeatView
    private let strip = GlassPanel(capsule: true)
    private let balls = PoolBallStrip()
    private let note = Typography.label("", font: Typography.caption, color: Palette.textSecondary)
    let side: Side

    static let height: CGFloat = 58
    private static let stripHeight: CGFloat = 30

    init(name: String, avatar: SeatView.Avatar, side: Side) {
        self.side = side
        seat = SeatView(name: name, detail: "", avatar: avatar, layout: .inline)
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height))
        wantsLayer = true
        strip.castsShadow = true
        addSubview(seat)
        addSubview(strip)
        strip.contentView.addSubview(balls)
        strip.contentView.addSubview(note)
        strip.isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // information, never a control

    /// Shows `numbers` as balls on the strip, or `text` when there are no
    /// balls to show; neither hides the strip.
    func setBalls(_ numbers: [Int], text: String? = nil) {
        balls.numbers = numbers
        note.stringValue = text ?? ""
        note.isHidden = text == nil || !numbers.isEmpty
        strip.isHidden = numbers.isEmpty && text == nil
        let accessibility = numbers.isEmpty ? (text ?? "")
            : numbers.map(String.init).joined(separator: ", ")
        strip.setAccessibilityLabel(accessibility)
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        SeatView.inlineSize.width + (strip.isHidden ? 0 : Spacing.s + stripWidth)
    }

    private var stripWidth: CGFloat {
        if !balls.numbers.isEmpty { return balls.preferredWidth + 18 }
        return Typography.fittingWidth(note) + 24
    }

    override func layout() {
        super.layout()
        let seatSize = SeatView.inlineSize
        let stripFrame: CGRect
        switch side {
        case .leading:
            seat.frame = CGRect(x: 0, y: 0, width: seatSize.width, height: seatSize.height)
            stripFrame = CGRect(x: seatSize.width + Spacing.s, y: ((Self.height - Self.stripHeight) / 2).rounded(),
                                width: stripWidth, height: Self.stripHeight)
        case .trailing:
            seat.frame = CGRect(x: bounds.width - seatSize.width, y: 0, width: seatSize.width, height: seatSize.height)
            stripFrame = CGRect(x: bounds.width - seatSize.width - Spacing.s - stripWidth,
                                y: ((Self.height - Self.stripHeight) / 2).rounded(), width: stripWidth, height: Self.stripHeight)
        }
        strip.frame = stripFrame
        balls.frame = CGRect(x: 9, y: (Self.stripHeight - PoolBallStrip.ball) / 2, width: balls.preferredWidth,
                             height: PoolBallStrip.ball)
        let h = note.intrinsicContentSize.height
        note.frame = CGRect(x: 12, y: ((Self.stripHeight - h) / 2).rounded(), width: stripFrame.width - 20, height: h)
    }
}

/// A row of tiny pool balls, drawn the way the library's cover draws them.
final class PoolBallStrip: NSView {
    static let ball: CGFloat = 19
    static let gap: CGFloat = 3

    var numbers: [Int] = [] { didSet { if numbers != oldValue { needsDisplay = true } } }

    var preferredWidth: CGFloat {
        numbers.isEmpty ? 0 : CGFloat(numbers.count) * Self.ball + CGFloat(numbers.count - 1) * Self.gap
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = Self.ball / 2
        for (i, n) in numbers.enumerated() {
            let c = CGPoint(x: r + CGFloat(i) * (Self.ball + Self.gap), y: r)
            TableArt.poolBallShadow(center: c, radius: r * 0.92, away: CGVector(dx: 0.2, dy: 0.1), squash: 0.5, context: ctx)
            TableArt.poolBall(n, center: c, radius: r * 0.92, turn: 0, context: ctx)
        }
    }
}
