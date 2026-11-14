//
//  OptionsCard.swift
//  The "New Game" card: a few choices, then Start.
//
//  Every game opens its new-game setup the same way — a glass card in the
//  middle of the table, the table dimmed behind it, a title, a line saying
//  what is about to happen, and one row per choice:
//
//      Opponents     [ 1 | 2 | 3 | 4 | 5 ]
//      Difficulty    [ Relaxed | Standard | Sharp ]
//
//      [ Cancel ]                 [ Start ]
//
//  The rows are generic — a title and some strings — and the card hands back
//  the chosen index of each by row id. It is modal while it is up: the scrim
//  swallows clicks on the table, Return starts, Escape cancels, ↑ and ↓ move
//  between rows and ← and → change the choice in the focused row.
//

import AppKit

final class OptionsCard: NSView {

    struct Row {
        /// Stable key for reading the choice back: "opponents", "difficulty".
        var id: String
        var title: String
        var options: [String]
        var selectedIndex: Int

        init(id: String, title: String, options: [String], selectedIndex: Int = 0) {
            self.id = id
            self.title = title
            self.options = options
            self.selectedIndex = max(0, min(selectedIndex, options.count - 1))
        }
    }

    /// Called with every row's chosen index, keyed by row id, when the player
    /// presses Start. The card has already begun dismissing itself.
    var onStart: (([String: Int]) -> Void)?
    /// Called when the player cancels. Nil hides the Cancel button, for a
    /// first launch where there is no game to go back to.
    var onCancel: (() -> Void)? {
        didSet { cancelButton.isHidden = onCancel == nil; needsLayout = true }
    }

    /// Every card presented right now, so buttons behind one know to stay
    /// quiet about their keys.
    static var presentedCards: [OptionsCard] {
        presented.compactMap { $0.card }
    }
    private struct WeakCard { weak var card: OptionsCard? }
    private static var presented: [WeakCard] = []

    private let panel = GlassPanel(cornerRadius: Radius.panel)
    private let titleLabel = Typography.label("", font: Typography.title)
    private let subtitleLabel = Typography.label("", font: Typography.callout, color: Palette.textSecondary)
    private var rowLabels: [NSTextField] = []
    private var choices: [SegmentedChoice] = []
    private(set) var rows: [Row]
    private let startButton: CapsuleButton
    private let cancelButton: CapsuleButton
    private var scrim: OptionsScrim?
    private var focusedRow = 0
    private weak var previousResponder: NSResponder?

    private static let width: CGFloat = 440
    private static let padding: CGFloat = 28

    init(title: String, subtitle: String = "", rows: [Row],
         startTitle: String = NSLocalizedString("Start", comment: "options card: begin the new game"),
         cancelTitle: String = NSLocalizedString("Cancel", comment: "")) {
        self.rows = rows
        startButton = CapsuleButton(title: startTitle, style: .primary, size: .large)
        cancelButton = CapsuleButton(title: cancelTitle, style: .secondary, size: .large)
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.cell?.wraps = true
        titleLabel.alignment = .center
        subtitleLabel.alignment = .center

        addSubview(panel)
        panel.autoresizingMask = [.width, .height]
        let content = panel.contentView
        content.addSubview(titleLabel)
        content.addSubview(subtitleLabel)
        for (i, row) in rows.enumerated() {
            let label = Typography.label(row.title, font: Typography.headline, color: Palette.textSecondary)
            let choice = SegmentedChoice(options: row.options, selectedIndex: row.selectedIndex)
            choice.onChange = { [weak self] index in
                self?.rows[i].selectedIndex = index
                self?.focus(row: i)
            }
            choice.setAccessibilityLabel(row.title)
            rowLabels.append(label)
            choices.append(choice)
            content.addSubview(label)
            content.addSubview(choice)
        }
        startButton.minimumWidth = 140
        cancelButton.minimumWidth = 120
        startButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.handler = { [weak self] in self?.start() }
        cancelButton.handler = { [weak self] in self?.cancel() }
        cancelButton.isHidden = true
        content.addSubview(startButton)
        content.addSubview(cancelButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
        frame.size = fittingCardSize
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The chosen index of the row with `id`, or nil for no such row.
    func selection(for id: String) -> Int? {
        rows.first { $0.id == id }?.selectedIndex
    }

    var selections: [String: Int] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.selectedIndex) })
    }

    // MARK: Presenting

    /// Whether the card is up.
    var isPresented: Bool { scrim != nil }

    /// Dims `host` and brings the card up in its middle. The card takes the
    /// keyboard; dismissing gives it back.
    ///
    /// Keep one card and present it again for every new game if you like:
    /// presenting a card that is already up does nothing, and presenting one
    /// still fading out takes it straight back. A card presented before the
    /// table is in a window (from `viewDidLoad`, say) takes the keyboard as
    /// soon as it gets there, and takes it back whenever the game returns
    /// from the library while it is still up.
    func present(in host: NSView, animated: Bool = true) {
        guard scrim == nil else { return }
        let scrim = OptionsScrim(frame: host.bounds)
        scrim.autoresizingMask = [.width, .height]
        host.addSubview(scrim)
        self.scrim = scrim

        frame.size = fittingCardSize
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        frame.origin = CGPoint(x: ((host.bounds.width - frame.width) / 2).rounded(),
                               y: ((host.bounds.height - frame.height) / 2).rounded())
        scrim.addSubview(self)
        layoutSubtreeIfNeeded()
        Self.presented.removeAll { $0.card == nil || $0.card === self }
        Self.presented.append(WeakCard(card: self))

        if let responder = host.window?.firstResponder, !(responder is OptionsCard) {
            previousResponder = responder
        } else {
            previousResponder = host
        }
        host.window?.makeFirstResponder(self)
        focus(row: 0)

        if animated && Motion.isEnabled {
            scrim.alphaValue = 0
            Motion.animate(duration: Motion.standard) { scrim.animator().alphaValue = 1 }
            Motion.present(self)
        }
    }

    /// Takes the card and the scrim away and gives the keyboard back.
    func dismiss(animated: Bool = true) {
        Self.presented.removeAll { $0.card == nil || $0.card === self }
        guard let scrim else { return }
        self.scrim = nil
        let window = self.window
        let restore = previousResponder
        let finish = { [weak self] in
            scrim.removeFromSuperview()
            // Presented again while this one was fading: the keyboard is the
            // new showing's, not the old one's to hand back.
            guard self?.isPresented != true else { return }
            let first = window?.firstResponder
            if let restore, first === self || first == nil || first === window {
                window?.makeFirstResponder(restore)
            }
        }
        if animated && Motion.isEnabled {
            Motion.dismiss(self)
            Motion.animate(duration: Motion.quick * 1.3, timing: Motion.easeIn, {
                scrim.animator().alphaValue = 0
            }, completion: finish)
        } else {
            finish()
        }
    }

    /// A card presented before its table reached a window, or one that is
    /// still up when the table comes back from the library, takes the
    /// keyboard the moment it arrives.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isPresented, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.isPresented, self.window === window else { return }
                if window.firstResponder !== self { window.makeFirstResponder(self) }
            }
        }
    }

    private func start() {
        let chosen = selections
        dismiss()
        onStart?(chosen)
    }

    private func cancel() {
        guard onCancel != nil else { return }
        dismiss()
        onCancel?()
    }

    // MARK: Keyboard

    private func focus(row: Int) {
        guard !choices.isEmpty else { return }
        focusedRow = max(0, min(row, choices.count - 1))
        for (i, choice) in choices.enumerated() { choice.showsFocus = i == focusedRow }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 126: focus(row: focusedRow - 1)                         // up
        case 125: focus(row: focusedRow + 1)                         // down
        case 123: choices[safe: focusedRow]?.select(offset: -1)      // left
        case 124: choices[safe: focusedRow]?.select(offset: 1)       // right
        case 36, 76: startButton.performPress()                      // return, enter
        case 53: if onCancel != nil { cancelButton.performPress() }  // escape
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel != nil { cancelButton.performPress() }
    }

    // MARK: Layout

    private var labelColumn: CGFloat {
        ceil(rowLabels.map { $0.intrinsicContentSize.width }.max() ?? 0)
    }

    private var fittingCardSize: CGSize {
        let choiceWidth = choices.map { $0.intrinsicContentSize.width }.max() ?? 0
        let width = max(Self.width, Self.padding * 2 + labelColumn + Spacing.l + choiceWidth)
        var height = Self.padding + titleLabel.intrinsicContentSize.height
        if !subtitleLabel.isHidden { height += 6 + subtitleHeight(for: width) }
        height += CGFloat(rows.count) * (SegmentedChoice.height + Spacing.m) + (rows.isEmpty ? 0 : Spacing.l)
        height += Spacing.m + ControlHeight.large + Self.padding
        return CGSize(width: ceil(width), height: ceil(height))
    }

    private func subtitleHeight(for width: CGFloat) -> CGFloat {
        let bounds = (subtitleLabel.stringValue as NSString).boundingRect(
            with: CGSize(width: width - Self.padding * 2, height: 200),
            options: [.usesLineFragmentOrigin], attributes: [.font: Typography.callout])
        return ceil(min(bounds.height, 36))
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let inner = bounds.insetBy(dx: Self.padding, dy: 0)
        var y = Self.padding
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: inner.minX, y: y, width: inner.width, height: titleHeight)
        y += titleHeight
        if !subtitleLabel.isHidden {
            let h = subtitleHeight(for: bounds.width)
            subtitleLabel.frame = CGRect(x: inner.minX, y: y + 6, width: inner.width, height: h)
            y += 6 + h
        }
        if !rows.isEmpty { y += Spacing.l + 4 }
        let column = labelColumn
        for (label, choice) in zip(rowLabels, choices) {
            let size = label.intrinsicContentSize
            let choiceSize = choice.intrinsicContentSize
            let choiceX = inner.maxX - choiceSize.width
            label.frame = CGRect(x: inner.minX, y: y + (SegmentedChoice.height - size.height) / 2,
                                 width: max(column, choiceX - inner.minX - Spacing.s), height: size.height)
            choice.frame = CGRect(x: choiceX, y: y, width: choiceSize.width, height: SegmentedChoice.height)
            y += SegmentedChoice.height + Spacing.m
        }
        y = bounds.height - Self.padding - ControlHeight.large
        let start = startButton.intrinsicContentSize
        if cancelButton.isHidden {
            // Alone, Start takes the full width: there is only one way on.
            startButton.frame = CGRect(x: inner.minX, y: y, width: inner.width, height: start.height)
        } else {
            let half = ((inner.width - Spacing.m) / 2).rounded(.down)
            cancelButton.frame = CGRect(x: inner.minX, y: y, width: half, height: start.height)
            startButton.frame = CGRect(x: inner.maxX - half, y: y, width: half, height: start.height)
        }
    }
}

/// The dimming behind a presented card. Takes every click, so the table
/// underneath cannot be played while the card is up.
final class OptionsScrim: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.scrim.cgColor
    }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// A row of mutually exclusive choices: a quiet capsule track with a
/// porcelain thumb that slides to the chosen word.
///
/// Three layers, bottom to top: the track (drawn), the thumb (a layer, so it
/// can spring across), and the words (a face view above both, so the chosen
/// word sits on the thumb rather than under it).
final class SegmentedChoice: NSControl {

    static let height: CGFloat = 32

    private(set) var options: [String]
    private(set) var selectedIndex: Int
    var onChange: ((Int) -> Void)?

    /// Drawn with a focus ring: the options card's keyboard row.
    var showsFocus = false { didSet { needsDisplay = true } }

    private let thumb = CALayer()
    private let face = SegmentedChoiceFace()
    fileprivate let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    init(options: [String], selectedIndex: Int = 0) {
        self.options = options
        self.selectedIndex = max(0, min(selectedIndex, max(0, options.count - 1)))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        thumb.backgroundColor = Palette.primaryFill.cgColor
        thumb.cornerCurve = .continuous
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.28
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(thumb)
        face.choice = self
        face.autoresizingMask = [.width, .height]
        addSubview(face)
        target = self
        action = #selector(noop(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityValue(options[safe: self.selectedIndex] ?? "")
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func noop(_ sender: Any?) {}

    private var segmentWidth: CGFloat {
        let widest = options.map { ceil(($0 as NSString).size(withAttributes: [.font: labelFont]).width) }.max() ?? 0
        return max(54, widest + 26)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidth * CGFloat(max(1, options.count)) + 4, height: Self.height)
    }

    fileprivate func segmentRect(_ i: Int) -> CGRect {
        let w = (bounds.width - 4) / CGFloat(max(1, options.count))
        return CGRect(x: 2 + CGFloat(i) * w, y: 2, width: w, height: bounds.height - 4)
    }

    override func layout() {
        super.layout()
        face.frame = bounds
        placeThumb(animated: false)
    }

    private func placeThumb(animated: Bool) {
        let rect = segmentRect(selectedIndex)
        let from = thumb.presentation()?.position ?? thumb.position
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.cornerRadius = rect.height / 2
        thumb.bounds = CGRect(origin: .zero, size: rect.size)
        thumb.shadowPath = CGPath(roundedRect: thumb.bounds, cornerWidth: rect.height / 2,
                                  cornerHeight: rect.height / 2, transform: nil)
        thumb.position = CGPoint(x: rect.midX, y: rect.midY)
        if animated && Motion.isEnabled {
            thumb.add(Motion.spring("position", from: NSValue(point: from), to: NSValue(point: thumb.position),
                                    spring: .snappy), forKey: "slide")
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(ContinuousShape.capsule(bounds))
        ctx.setFillColor(Palette.fillQuiet.cgColor)
        ctx.fillPath()
        if showsFocus && window?.isKeyWindow != false {
            ctx.addPath(ContinuousShape.capsule(bounds.insetBy(dx: 0.75, dy: 0.75)))
            ctx.setStrokeColor(Palette.accent.withAlphaComponent(0.65).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
    }

    func select(_ index: Int, notify: Bool = true) {
        let clamped = max(0, min(index, options.count - 1))
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        placeThumb(animated: true)
        face.needsDisplay = true
        setAccessibilityValue(options[safe: clamped] ?? "")
        Haptics.levelChange()
        if notify { onChange?(clamped) }
    }

    func select(offset: Int) { select(selectedIndex + offset) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for i in options.indices where segmentRect(i).contains(point) {
            select(i)
            return
        }
    }
}

/// The words of a `SegmentedChoice`, above its thumb.
final class SegmentedChoiceFace: NSView {
    weak var choice: SegmentedChoice?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("built in code") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let choice else { return }
        for (i, option) in choice.options.enumerated() {
            let rect = choice.segmentRect(i)
            let selected = i == choice.selectedIndex
            let attributes = Typography.attributes(choice.labelFont, selected ? Palette.primaryLabel : Palette.textSecondary,
                                                   alignment: .center)
            let size = (option as NSString).size(withAttributes: attributes)
            (option as NSString).draw(in: CGRect(x: rect.minX + 4, y: rect.midY - size.height / 2 - 0.5,
                                                 width: rect.width - 8, height: size.height),
                                      withAttributes: attributes)
        }
    }
}
