//
//  SeatView.swift
//  A player at the table: their face, their name, and how they are doing.
//
//      ╭──╮
//      │AK│  ← avatar: initials on a deterministic colour, or a symbol
//      ╰──╯     ring: white while it is their turn, sweeping gold while a
//   ┌────────┐        bot is thinking, gold and glowing for the winner
//   │  Anna  │  ← nameplate: glass, name over one line of detail
//   │ 1,240  │     (their stack, their card count, "Folded")
//   └────────┘
//
//  States: waiting (nothing to say), active (their turn), folded and out
//  (dimmed), winner (a soft gold halo). The dealer button rides on the
//  avatar's shoulder.
//
//  The one thing that animates is the thinking sweep, and it runs only while
//  the seat is active *and* thinking *and* its window is key and on screen —
//  it watches the window itself, so a game cannot leave it spinning behind
//  the library or a minimised window.
//

import AppKit
import QuartzCore

final class SeatView: NSView {

    enum State: Equatable {
        /// Seated and waiting.
        case waiting
        /// Their turn.
        case active
        /// Out of this hand.
        case folded
        /// Out of the game.
        case out
        /// Won the hand.
        case winner
    }

    enum Avatar: Equatable {
        /// Up to two initials from the name on a colour picked from the name.
        case initials
        /// An SF Symbol on the same colour — `person.fill` for the player.
        case symbol(String)
    }

    enum Layout {
        /// Avatar above, nameplate below. For seats round a table.
        case stacked
        /// Avatar to the left of the nameplate, for a seat along an edge.
        case inline
    }

    var name: String {
        didSet { if name != oldValue { nameLabel.stringValue = name; avatarChanged(); updateAccessibility() } }
    }

    /// The line under the name: a stack, a card count, a status.
    var detail: String {
        didSet { if detail != oldValue { detailLabel.stringValue = detail; needsLayout = true; updateAccessibility() } }
    }

    var state: State = .waiting {
        didSet { if state != oldValue { applyState(animated: true) } }
    }

    /// A bot is making up its mind. Shows the sweep, but only while `state`
    /// is `.active`.
    var isThinking = false {
        didSet { if isThinking != oldValue { applyState(animated: true) } }
    }

    /// The dealer button on the avatar's shoulder.
    var isDealer = false {
        didSet { if isDealer != oldValue { dealerBadge.isHidden = !isDealer } }
    }

    var avatar: Avatar {
        didSet { if avatar != oldValue { avatarChanged() } }
    }

    let layoutStyle: Layout

    /// The avatar's diameter.
    static let avatarSize: CGFloat = 52

    private let avatarLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let sweepLayer = CAShapeLayer()
    private let dealerBadge = CALayer()
    private let plate = GlassPanel(capsule: false)
    private let nameLabel = Typography.label("", font: Typography.headline)
    private let detailLabel = Typography.label("", font: Typography.monospacedDigits(.systemFont(ofSize: 11.5, weight: .medium)),
                                               color: Palette.textSecondary)
    private var windowObservers: [NSObjectProtocol] = []

    init(name: String, detail: String = "", avatar: Avatar = .initials, layout: Layout = .stacked) {
        self.name = name
        self.detail = detail
        self.avatar = avatar
        self.layoutStyle = layout
        super.init(frame: CGRect(origin: .zero, size: layout == .stacked ? Self.stackedSize : Self.inlineSize))
        wantsLayer = true

        plate.cornerRadius = 14
        plate.castsShadow = true
        addSubview(plate)
        nameLabel.stringValue = name
        nameLabel.alignment = layout == .stacked ? .center : .left
        detailLabel.stringValue = detail
        detailLabel.alignment = layout == .stacked ? .center : .left
        plate.contentView.addSubview(nameLabel)
        plate.contentView.addSubview(detailLabel)

        // The avatar and its rings sit in their own layers above the plate.
        let host = SeatAvatarHost()
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        for layer in [ringLayer, avatarLayer, sweepLayer, dealerBadge] { host.layer?.addSublayer(layer) }

        avatarLayer.contentsGravity = .resizeAspect
        avatarLayer.shadowColor = NSColor.black.cgColor
        avatarLayer.shadowOpacity = 0.45
        avatarLayer.shadowRadius = 5
        avatarLayer.shadowOffset = CGSize(width: 0, height: 2.5)
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 2.5
        sweepLayer.fillColor = nil
        sweepLayer.lineWidth = 3
        sweepLayer.lineCap = .round
        sweepLayer.strokeColor = Palette.accent.cgColor
        sweepLayer.strokeStart = 0
        sweepLayer.strokeEnd = 0.28
        sweepLayer.isHidden = true
        dealerBadge.isHidden = true
        dealerBadge.contentsGravity = .resizeAspect

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        avatarChanged()
        applyState(animated: false)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var isFlipped: Bool { true }

    static let stackedSize = CGSize(width: 128, height: 104)
    static let inlineSize = CGSize(width: 176, height: 58)

    override var intrinsicContentSize: NSSize {
        layoutStyle == .stacked ? Self.stackedSize : Self.inlineSize
    }

    /// Where the avatar's centre is, in the seat's coordinates — for placing
    /// the seat so the avatar lands on a point of the rail.
    var avatarCenter: CGPoint {
        let d = Self.avatarSize
        switch layoutStyle {
        case .stacked: return CGPoint(x: bounds.midX, y: 4 + d / 2)
        case .inline: return CGPoint(x: 4 + d / 2, y: bounds.midY)
        }
    }

    /// Puts the seat so its avatar's centre is at `point` in the superview.
    func centerAvatar(at point: CGPoint) {
        let c = avatarCenter
        let flipped = superview?.isFlipped ?? true
        let y = flipped ? point.y - c.y : point.y - (bounds.height - c.y)
        setFrameOrigin(CGPoint(x: (point.x - c.x).rounded(), y: y.rounded()))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let d = Self.avatarSize
        let center = avatarCenter
        let avatarFrame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatarLayer.frame = avatarFrame
        avatarLayer.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: avatarFrame.size), transform: nil)
        let ringRect = avatarFrame.insetBy(dx: -4.5, dy: -4.5)
        ringLayer.frame = ringRect
        ringLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: ringRect.size).insetBy(dx: 1.25, dy: 1.25), transform: nil)
        sweepLayer.bounds = CGRect(origin: .zero, size: ringRect.size)
        sweepLayer.position = CGPoint(x: ringRect.midX, y: ringRect.midY)
        sweepLayer.path = ringLayer.path
        // The dealer button sits on the ring at the avatar's lower right, on
        // a disc of the room's colour a couple of points wider than itself:
        // the ring and the thinking sweep pass *behind* it with a clean gap,
        // rather than being cut by a white disc laid on top of the gold.
        let badge: CGFloat = 22
        let ringRadius = ringRect.width / 2 - 1.25
        let badgeCenter = CGPoint(x: center.x + ringRadius * 0.7071, y: center.y + ringRadius * 0.7071)
        dealerBadge.frame = CGRect(x: badgeCenter.x - badge / 2, y: badgeCenter.y - badge / 2,
                                   width: badge, height: badge)
        dealerBadge.cornerRadius = badge / 2
        dealerBadge.backgroundColor = Palette.room.cgColor
        CATransaction.commit()

        switch layoutStyle {
        case .stacked:
            let plateTop = avatarFrame.maxY - 8
            plate.frame = CGRect(x: 0, y: plateTop, width: bounds.width, height: bounds.height - plateTop)
            let inner = plate.bounds.insetBy(dx: 8, dy: 0)
            let nameHeight = nameLabel.intrinsicContentSize.height
            let detailHeight = detailLabel.intrinsicContentSize.height
            let top = 10 + (plate.bounds.height - 10 - nameHeight - detailHeight) / 2
            nameLabel.frame = CGRect(x: inner.minX, y: top.rounded(), width: inner.width, height: nameHeight)
            detailLabel.frame = CGRect(x: inner.minX, y: (top + nameHeight).rounded(), width: inner.width, height: detailHeight)
        case .inline:
            let plateLeft = avatarFrame.maxX - 10
            plate.frame = CGRect(x: plateLeft, y: (bounds.midY - 22).rounded(), width: bounds.width - plateLeft, height: 44)
            let inner = CGRect(x: 18, y: 0, width: plate.bounds.width - 26, height: plate.bounds.height)
            let nameHeight = nameLabel.intrinsicContentSize.height
            let detailHeight = detailLabel.intrinsicContentSize.height
            let top = (inner.height - nameHeight - detailHeight) / 2
            nameLabel.frame = CGRect(x: inner.minX, y: top.rounded(), width: inner.width, height: nameHeight)
            detailLabel.frame = CGRect(x: inner.minX, y: (top + nameHeight).rounded(), width: inner.width, height: detailHeight)
        }
        refreshImages()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshImages()
    }

    private var renderedKey = ""

    private func refreshImages() {
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(name)|\(avatar)|\(scale)"
        guard key != renderedKey else { return }
        renderedKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        avatarLayer.contents = AvatarRenderer.image(name: name, avatar: avatar, diameter: Self.avatarSize, scale: scale)
        avatarLayer.contentsScale = scale
        dealerBadge.contents = AvatarRenderer.dealerButton(diameter: 20, scale: scale)
        dealerBadge.contentsScale = scale
        CATransaction.commit()
    }

    private func avatarChanged() {
        renderedKey = ""
        needsLayout = true
    }

    // MARK: State

    private func applyState(animated: Bool) {
        let motion = animated && Motion.isEnabled
        let dimmed = state == .folded || state == .out
        if motion {
            Motion.animate(duration: Motion.standard) { self.animator().alphaValue = dimmed ? 0.45 : 1 }
        } else {
            alphaValue = dimmed ? 0.45 : 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!motion)
        CATransaction.setAnimationDuration(Motion.standard)
        switch state {
        case .active:
            // Thinking, the ring steps back and the gold sweep does the
            // talking; otherwise a clean porcelain ring says "your turn".
            ringLayer.strokeColor = (isThinking ? NSColor(white: 1, alpha: 0.28) : Palette.primaryFill).cgColor
            ringLayer.opacity = 1
            ringLayer.shadowOpacity = 0
        case .winner:
            ringLayer.strokeColor = Palette.accent.cgColor
            ringLayer.opacity = 1
            ringLayer.shadowColor = Palette.accent.cgColor
            ringLayer.shadowOpacity = 0.9
            ringLayer.shadowRadius = 9
            ringLayer.shadowOffset = .zero
        default:
            ringLayer.opacity = 0
            ringLayer.shadowOpacity = 0
        }
        // A winner's avatar glows gold; everyone else's casts an ordinary
        // shadow.
        avatarLayer.shadowColor = (state == .winner ? Palette.accent : NSColor.black).cgColor
        avatarLayer.shadowOpacity = state == .winner ? 0.85 : 0.45
        avatarLayer.shadowRadius = state == .winner ? 12 : 5
        avatarLayer.shadowOffset = state == .winner ? .zero : CGSize(width: 0, height: 2.5)
        CATransaction.commit()
        nameLabel.textColor = state == .winner ? Palette.accentSoft : Palette.textPrimary
        updateSweep()
        updateAccessibility()
    }

    // MARK: The thinking sweep

    /// Whether the sweep should be turning right now.
    private var sweepShouldRun: Bool {
        guard state == .active, isThinking, let window else { return false }
        return window.isVisible && window.isKeyWindow && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    private func updateSweep() {
        let visible = state == .active && isThinking
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweepLayer.isHidden = !visible
        CATransaction.commit()
        let running = sweepLayer.animation(forKey: "sweep") != nil
        if sweepShouldRun && Motion.isEnabled {
            guard !running else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * CGFloat.pi
            spin.duration = 1.4
            spin.repeatCount = .infinity
            sweepLayer.add(spin, forKey: "sweep")
        } else if running {
            sweepLayer.removeAnimation(forKey: "sweep")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        if let window {
            let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didChangeOcclusionStateNotification,
                                              NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
            for name in names {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateSweep() }
                    })
            }
        }
        updateSweep()
        refreshImages()
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        var parts = [name]
        if !detail.isEmpty { parts.append(detail) }
        switch state {
        case .active: parts.append(NSLocalizedString("their turn", comment: "accessibility: seat state"))
        case .folded: parts.append(NSLocalizedString("folded", comment: "accessibility: seat state"))
        case .out: parts.append(NSLocalizedString("out", comment: "accessibility: seat state"))
        case .winner: parts.append(NSLocalizedString("winner", comment: "accessibility: seat state"))
        case .waiting: break
        }
        if isDealer { parts.append(NSLocalizedString("dealer", comment: "accessibility: seat has the dealer button")) }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }
}

/// Holds a seat's avatar layers above its nameplate, and lets clicks through.
final class SeatAvatarHost: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Avatars

/// Faces for players: a colour from the name, the initials in SF Pro Rounded,
/// lit like everything else. Deterministic — the same name is the same face
/// on every Mac and every launch — which is why the colour comes from a hash
/// written out here rather than from `hashValue`, which Swift reseeds every
/// time the app starts.
enum AvatarRenderer {

    /// Deep, quiet pairs — top and bottom of a gradient — that sit together
    /// round a table and read against every cloth.
    static let palette: [(NSColor, NSColor)] = [
        (NSColor(srgbRed: 0.36, green: 0.52, blue: 0.80, alpha: 1), NSColor(srgbRed: 0.18, green: 0.29, blue: 0.55, alpha: 1)),
        (NSColor(srgbRed: 0.84, green: 0.48, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.58, green: 0.24, blue: 0.21, alpha: 1)),
        (NSColor(srgbRed: 0.38, green: 0.68, blue: 0.60, alpha: 1), NSColor(srgbRed: 0.16, green: 0.42, blue: 0.38, alpha: 1)),
        (NSColor(srgbRed: 0.66, green: 0.50, blue: 0.82, alpha: 1), NSColor(srgbRed: 0.40, green: 0.26, blue: 0.58, alpha: 1)),
        (NSColor(srgbRed: 0.86, green: 0.68, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.60, green: 0.40, blue: 0.16, alpha: 1)),
        (NSColor(srgbRed: 0.58, green: 0.62, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.32, green: 0.35, blue: 0.43, alpha: 1)),
        (NSColor(srgbRed: 0.80, green: 0.46, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.52, green: 0.22, blue: 0.38, alpha: 1)),
        (NSColor(srgbRed: 0.54, green: 0.70, blue: 0.40, alpha: 1), NSColor(srgbRed: 0.30, green: 0.45, blue: 0.20, alpha: 1)),
    ]

    /// FNV-1a over the name's UTF-8: small, stable, and good enough to spread
    /// a handful of names over eight colours.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    static func colors(for name: String) -> (NSColor, NSColor) {
        palette[Int(stableHash(name) % UInt64(palette.count))]
    }

    /// "Anna" → "A", "Anna Karenina" → "AK".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        return words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    private static var cache: [String: CGImage] = [:]

    static func image(name: String, avatar: SeatView.Avatar, diameter d: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(name)|\(avatar)|\(Int(d))|\(scale)"
        if let cached = cache[key] { return cached }
        let image = ChipRenderer.render(size: CGSize(width: d, height: d), scale: scale) { ctx in
            draw(name: name, avatar: avatar, in: CGRect(x: 0, y: 0, width: d, height: d), context: ctx)
        }
        if let image {
            if cache.count > 64 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }

    /// Draws the avatar filling `rect`, in a top-left-origin context.
    static func draw(name: String, avatar: SeatView.Avatar, in rect: CGRect, context ctx: CGContext) {
        // A symbol avatar — the player's own seat — is graphite, the way a
        // contact without a picture is; colour is for the other players.
        let (top, bottom): (NSColor, NSColor)
        if case .symbol = avatar {
            (top, bottom) = (NSColor(srgbRed: 0.60, green: 0.62, blue: 0.66, alpha: 1),
                             NSColor(srgbRed: 0.36, green: 0.38, blue: 0.42, alpha: 1))
        } else {
            (top, bottom) = colors(for: name)
        }
        let disc = CGPath(ellipseIn: rect, transform: nil)
        ctx.saveGState()
        ctx.addPath(disc)
        ctx.clip()
        AppleStyle.fillVertical(rect, context: ctx, [(top, 0), (bottom, 1)])
        AppleStyle.grain(in: rect, context: ctx, alpha: 0.05, spread: 20, tile: rect.width)
        if let g = AppleStyle.gradient([(NSColor(white: 1, alpha: 0.22), 0), (NSColor(white: 1, alpha: 0), 0.6)]) {
            let light = CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.18)
            ctx.drawRadialGradient(g, startCenter: light, startRadius: 0, endCenter: light,
                                   endRadius: rect.width * 0.75, options: [])
        }
        ctx.restoreGState()

        let glyphColor = NSColor(white: 1, alpha: 0.96)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        switch avatar {
        case .initials:
            let text = initials(name)
            let font = Typography.rounded(rect.width * (text.count > 1 ? 0.36 : 0.42), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: glyphColor]
            let size = (text as NSString).size(withAttributes: attributes)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
            shadow.shadowOffset = CGSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1
            var shadowed = attributes
            shadowed[.shadow] = shadow
            (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                    withAttributes: shadowed)
        case .symbol(let symbolName):
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))) {
                let size = image.size
                image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                      width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // A fine rim: light over the top, dark round the bottom.
        AppleStyle.bevel(disc, in: rect, context: ctx, width: max(0.75, rect.width * 0.025),
                         top: NSColor(white: 1, alpha: 0.40), bottom: NSColor(white: 0, alpha: 0.30))
    }

    /// The dealer button: a white acrylic puck with a D on it.
    static func dealerButton(diameter d: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "dealer|\(Int(d))|\(scale)"
        if let cached = cache[key] { return cached }
        let pad: CGFloat = 3
        let image = ChipRenderer.render(size: CGSize(width: d + pad * 2, height: d + pad * 2), scale: scale) { ctx in
            let rect = CGRect(x: pad, y: pad, width: d, height: d)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.2), blur: 2.5, color: NSColor(white: 0, alpha: 0.55).cgColor)
            ctx.setFillColor(NSColor(srgbRed: 0.97, green: 0.965, blue: 0.95, alpha: 1).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            AppleStyle.fillVertical(rect, context: ctx, [(NSColor(white: 1, alpha: 0.5), 0), (NSColor(white: 0, alpha: 0.12), 1)])
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor(white: 0, alpha: 0.18).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokeEllipse(in: rect.insetBy(dx: d * 0.12, dy: d * 0.12))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let text = NSLocalizedString("D", comment: "the dealer button's letter") as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Typography.rounded(d * 0.52, weight: .heavy),
                .foregroundColor: NSColor(white: 0.10, alpha: 1),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let image { cache[key] = image }
        return image
    }
}

// MARK: - Bots

/// AppKit-specific avatar colours; names and seating live in the portable kit.
extension BotRoster {
    /// The colours a name's avatar is drawn in, top and bottom.
    static func avatarColors(for name: String) -> (NSColor, NSColor) {
        AvatarRenderer.colors(for: name)
    }
}
