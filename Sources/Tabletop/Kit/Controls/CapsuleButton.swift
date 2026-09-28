//
//  CapsuleButton.swift
//  The button. Every button a game shows is one of these.
//
//  A capsule with an optional SF Symbol and a word, in one of five styles:
//
//    primary      porcelain fill, near-black type — the one thing to do next
//    secondary    glass on its own; a quiet fill when it sits inside a panel
//    destructive  like secondary, with the words in a soft red — leaving,
//                 resigning, discarding progress, said without shouting
//    destructiveProminent
//                 a filled deep red, for the final step of a confirmation
//                 only ("Leave the table?" · Leave); never in an action bar
//    plain        just the type, with a fill appearing under the pointer
//
//  It answers a closure rather than a selector, so a game can build its
//  buttons where it decides what they do. It still carries a target and an
//  action — itself, and `activate(_:)` — so `--controls` can see that every
//  button on screen reaches something.
//
//  Keys: `keyEquivalent` fires the button while its window is key and the
//  button is visible and enabled. Give buttons bare keys ("f" for Fold, "\r"
//  for the default) and leave ⌘-shortcuts to the game's menu: the window asks
//  its views about a ⌘-key before the menu bar does, so a button holding ⌘N
//  would quietly steal New Game from the menu.
//
//  No sound, ever: this app makes no interface noises.
//

import AppKit

final class CapsuleButton: NSControl {

    enum Style: Equatable {
        case primary, secondary, destructive, destructiveProminent, plain
    }

    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: return ControlHeight.small
            case .regular: return ControlHeight.regular
            case .large: return ControlHeight.large
            }
        }

        var font: NSFont {
            switch self {
            case .small: return .systemFont(ofSize: 12, weight: .semibold)
            case .regular: return .systemFont(ofSize: 13, weight: .semibold)
            case .large: return .systemFont(ofSize: 15, weight: .semibold)
            }
        }

        var symbolPointSize: CGFloat {
            switch self {
            case .small: return 11
            case .regular: return 12.5
            case .large: return 14.5
            }
        }

        var padding: CGFloat {
            switch self {
            case .small: return 12
            case .regular: return 16
            case .large: return 22
            }
        }
    }

    /// What the pointer is doing to the button — or, for the kit gallery, what
    /// it is pretending the pointer is doing.
    enum Interaction { case idle, hovered, pressed }

    var style: Style {
        didSet { if style != oldValue { rebuildBackground(); needsDisplay = true; face.needsDisplay = true } }
    }
    let size: Size

    var title: String {
        didSet {
            guard title != oldValue else { return }
            invalidateIntrinsicContentSize()
            face.needsDisplay = true
            setAccessibilityLabel(accessibilityTitle)
        }
    }

    var symbolName: String? {
        didSet {
            guard symbolName != oldValue else { return }
            invalidateIntrinsicContentSize()
            face.needsDisplay = true
        }
    }

    /// Runs when the button is clicked, pressed through accessibility, or its
    /// key equivalent is typed.
    var handler: (() -> Void)?

    /// A bare key ("f", "\r", "\u{1b}") or, with `keyEquivalentModifierMask`,
    /// a combination. See the top of the file before reaching for ⌘.
    var keyEquivalent = ""
    var keyEquivalentModifierMask: NSEvent.ModifierFlags = []

    /// The narrowest the capsule may be, so a row of short words ("Hit",
    /// "Stand") comes out as a row of equal buttons rather than a ragged one.
    var minimumWidth: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// For a symbol-only button, what VoiceOver and the tooltip say.
    var accessibilityTitle: String {
        get { explicitAccessibilityTitle ?? title }
        set {
            explicitAccessibilityTitle = newValue
            setAccessibilityLabel(newValue)
            toolTip = title.isEmpty ? newValue : nil
        }
    }
    private var explicitAccessibilityTitle: String?

    /// Pins the look to one interaction state — only the kit gallery, which
    /// has to show a hovered and a pressed button without a pointer, sets it.
    var interactionOverride: Interaction? {
        didSet { needsDisplay = true; face.needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { isPressed = false }
            needsDisplay = true
            face.needsDisplay = true
            glass?.alphaValue = isEnabled ? 1 : 0.55
        }
    }

    private let face = CapsuleButtonFace()
    private var glass: GlassPanel?
    private var isHovered = false { didSet { if isHovered != oldValue { stateChanged() } } }
    private var isPressed = false { didSet { if isPressed != oldValue { stateChanged() } } }

    init(title: String, symbolName: String? = nil, style: Style = .secondary, size: Size = .regular,
         handler: (() -> Void)? = nil) {
        self.title = title
        self.symbolName = symbolName
        self.style = style
        self.size = size
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: 80, height: size.height))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        target = self
        action = #selector(activate(_:))

        face.button = self
        face.autoresizingMask = [.width, .height]
        addSubview(face)
        rebuildBackground()

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    /// A button made from a `ChromeAction`, which is how the bar, the banner
    /// and the options card build theirs.
    convenience init(_ action: ChromeAction, size: Size = .regular) {
        self.init(title: action.title, symbolName: action.symbolName, style: action.style, size: size,
                  handler: action.handler)
        keyEquivalent = action.keyEquivalent
        keyEquivalentModifierMask = action.modifiers
        isEnabled = action.isEnabled
        identifier = NSUserInterfaceItemIdentifier(action.id)
        if let label = action.accessibilityLabel { accessibilityTitle = label }
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Size

    override var intrinsicContentSize: NSSize {
        let text = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: [.font: size.font]).width)
        let symbol = symbolImage(color: .white)?.size.width ?? 0
        let gap: CGFloat = (text > 0 && symbol > 0) ? 6 : 0
        var width = text + symbol + gap + size.padding * 2
        if text == 0 { width = size.height }                 // a symbol alone is a circle
        return NSSize(width: max(minimumWidth, ceil(width)), height: size.height)
    }

    // MARK: Glass

    /// Glass for a secondary (or quiet destructive) button standing on its
    /// own; a plain fill, drawn in `draw(_:)`, for everything else —
    /// including either inside a panel, since glass does not go on glass.
    private var wantsGlass: Bool { (style == .secondary || style == .destructive) && !isInsideGlassPanel }

    /// The two styles drawn as a solid capsule with a lamp on its top half.
    private var isFilled: Bool { style == .primary || style == .destructiveProminent }

    private func rebuildBackground() {
        if wantsGlass {
            guard glass == nil else { return }
            let panel = GlassPanel(capsule: true)
            panel.castsShadow = true
            panel.autoresizingMask = [.width, .height]
            panel.frame = bounds
            addSubview(panel, positioned: .below, relativeTo: face)
            glass = panel
        } else {
            glass?.removeFromSuperview()
            glass = nil
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuildBackground()
    }

    override func layout() {
        super.layout()
        face.frame = bounds
        glass?.frame = bounds
        guard let layer else { return }
        // A filled capsule standing on the felt casts a small shadow; one on
        // glass does not — the glass already did.
        if isFilled && !isInsideGlassPanel {
            Elevation.raised.apply(toFlipped: layer, path: ContinuousShape.capsule(bounds))
        } else {
            layer.shadowOpacity = 0
        }
    }

    // MARK: Drawing

    var currentInteraction: Interaction {
        if let interactionOverride { return interactionOverride }
        if isPressed { return .pressed }
        return isHovered ? .hovered : .idle
    }

    /// True while the button stands on glass of its own.
    var hasGlass: Bool { glass != nil }

    /// The capsule's fill for this style and state, or nil for none. On a
    /// glass button this is a wash laid over the glass by the face.
    var fillColor: NSColor? {
        let state = currentInteraction
        switch style {
        case .primary:
            return state == .pressed ? Palette.primaryFillPressed
                : state == .hovered ? Palette.primaryFillHover : Palette.primaryFill
        case .destructiveProminent:
            return state == .pressed ? Palette.destructiveFill.blended(withFraction: 0.2, of: .black)
                : state == .hovered ? Palette.destructiveFillHover : Palette.destructiveFill
        case .secondary, .destructive:
            if glass != nil {
                // The glass is the fill; the pointer only brightens it.
                return state == .pressed ? NSColor(white: 0, alpha: 0.12)
                    : state == .hovered ? NSColor(white: 1, alpha: 0.08) : nil
            }
            return state == .pressed ? Palette.fillQuietPressed
                : state == .hovered ? Palette.fillQuietHover : Palette.fillQuiet
        case .plain:
            return state == .pressed ? Palette.fillQuietPressed
                : state == .hovered ? Palette.fillQuiet : nil
        }
    }

    /// The colour of the words and the symbol.
    var labelColor: NSColor {
        switch style {
        case .primary: return Palette.primaryLabel
        case .destructiveProminent: return .white
        case .destructive: return Palette.destructiveText
        case .secondary: return Palette.textPrimary
        case .plain: return currentInteraction == .idle ? Palette.textSecondary : Palette.textPrimary
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // A glass button's wash is drawn by the face, above the glass.
        guard glass == nil, let ctx = NSGraphicsContext.current?.cgContext, let fill = fillColor else { return }
        let path = ContinuousShape.capsule(bounds)
        ctx.saveGState()
        ctx.setAlpha(isEnabled ? 1 : 0.38)
        ctx.addPath(path)
        ctx.setFillColor(fill.cgColor)
        ctx.fillPath()
        if isFilled {
            // A little of the lamp on the top half of a solid capsule, so it
            // reads as a pressed tile rather than a flat sticker.
            ctx.addPath(path)
            ctx.clip()
            AppleStyle.fillVertical(bounds, context: ctx, [
                (NSColor(white: 1, alpha: style == .primary ? 0.35 : 0.14), 0),
                (NSColor(white: 1, alpha: 0), 0.55),
                (NSColor(white: 0, alpha: 0.05), 1),
            ])
        }
        ctx.restoreGState()
    }

    func symbolImage(color: NSColor) -> NSImage? {
        guard let symbolName,
              let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: size.symbolPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration)
    }

    private func stateChanged() {
        needsDisplay = true
        face.needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            isPressed = false
        }
        // An ancestor may have been put into a panel since this button last
        // looked (a bet control's presets, dropped into an action bar); by
        // the time the button reaches a window its ancestry is settled.
        rebuildBackground()
        needsLayout = true
    }

    /// The whole capsule is the button, words and symbol included — until it
    /// has been retired, when clicks go through it to whatever replaced it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !isRetired, frame.contains(point) else { return nil }
        return self
    }

    /// True once `retire()` has been called.
    private(set) var isRetired = false

    /// Takes the button out of play for good while it is still on screen —
    /// an action bar's old buttons, fading out as new ones fade in. It keeps
    /// its look for the fade, but answers no click, no key and no
    /// accessibility press, and forgets its handler.
    func retire() {
        isRetired = true
        handler = nil
        keyEquivalent = ""
        isPressed = false
        isHovered = false
        setAccessibilityElement(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let wasPressed = isPressed
        isPressed = false
        guard inside, wasPressed, isEnabled else { return }
        sendAction(action, to: target)
    }

    /// What every route to the button ends in: click, key, accessibility.
    @objc func activate(_ sender: Any?) {
        guard isEnabled, !isRetired else { return }
        handler?()
    }

    /// Clicks the button as if with the pointer: shows it pressed for a beat
    /// and fires. For key equivalents, and for tests.
    func performPress() {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return }
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            MainActor.assumeIsolated { self?.isPressed = false }
        }
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        sendAction(action, to: target)
        return true
    }

    // MARK: Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard matchesKeyEquivalent(event), isEnabled, !isHiddenOrHasHiddenAncestor, window != nil,
              !event.isARepeat, !isBlockedByModalCard else {
            return super.performKeyEquivalent(with: event)
        }
        performPress()
        return true
    }

    /// Whether `event` is this button's key equivalent, modifiers and all.
    func matchesKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !keyEquivalent.isEmpty, event.type == .keyDown else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let typed = event.modifierFlags.intersection(relevant)
        let wanted = keyEquivalentModifierMask.intersection(relevant)
        // Shift is part of the character for a bare letter ("F" is "f" with
        // shift), so it only has to match when the equivalent asks for it.
        if wanted.contains(.shift) {
            guard typed == wanted else { return false }
        } else {
            guard typed.subtracting(.shift) == wanted else { return false }
        }
        return event.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased()
    }

    /// A button behind a presented options card must not answer its key: the
    /// card is modal, and Return belongs to its Start button.
    private var isBlockedByModalCard: Bool {
        guard let window else { return false }
        for card in OptionsCard.presentedCards where card.window === window {
            if !isDescendant(of: card) { return true }
        }
        return false
    }
}

/// The words and the symbol, drawn above the glass.
final class CapsuleButtonFace: NSView {

    weak var button: CapsuleButton?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func draw(_ dirtyRect: NSRect) {
        guard let button else { return }
        if button.hasGlass, let wash = button.fillColor, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.addPath(ContinuousShape.capsule(bounds))
            ctx.setFillColor(wash.cgColor)
            ctx.fillPath()
        }
        let color = button.labelColor.withAlphaComponent(
            button.labelColor.alphaComponent * (button.isEnabled ? 1 : 0.42))
        let font = button.size.font
        let text = button.title as NSString
        let attributes = Typography.attributes(font, color)
        let textSize = button.title.isEmpty ? .zero : text.size(withAttributes: attributes)
        let symbol = button.symbolImage(color: color)
        let symbolSize = symbol?.size ?? .zero
        let gap: CGFloat = (textSize.width > 0 && symbolSize.width > 0) ? 6 : 0
        let total = min(bounds.width - 8, symbolSize.width + gap + ceil(textSize.width))
        var x = ((bounds.width - total) / 2).rounded()

        if let symbol {
            let rect = CGRect(x: x, y: ((bounds.height - symbolSize.height) / 2).rounded(),
                              width: symbolSize.width, height: symbolSize.height)
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            x += symbolSize.width + gap
        }
        if textSize.width > 0 {
            let width = max(0, bounds.maxX - x - 4)
            // Centred on the cap height rather than the line box, which sits
            // a point too low in a capsule this short.
            let y = ((bounds.height - textSize.height) / 2).rounded() - 0.5
            text.draw(with: CGRect(x: x, y: y, width: width, height: textSize.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
    }
}

/// One thing the player can do, described once and turned into a button by
/// whichever piece of chrome shows it: the action bar, a banner, an options
/// card.
struct ChromeAction {
    /// Stable within a set, so a bar can find the button again to enable or
    /// retitle it: "fold", "raise", "hit".
    var id: String
    var title: String
    var symbolName: String?
    var style: CapsuleButton.Style = .secondary
    /// Bare keys only — see `CapsuleButton`.
    var keyEquivalent: String = ""
    var modifiers: NSEvent.ModifierFlags = []
    var isEnabled = true
    /// For a symbol-only action: what VoiceOver says.
    var accessibilityLabel: String?
    var handler: () -> Void

    init(id: String, title: String, symbolName: String? = nil, style: CapsuleButton.Style = .secondary,
         keyEquivalent: String = "", modifiers: NSEvent.ModifierFlags = [], isEnabled: Bool = true,
         accessibilityLabel: String? = nil, handler: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.style = style
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.handler = handler
    }
}
