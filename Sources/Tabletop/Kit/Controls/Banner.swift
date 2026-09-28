//
//  Banner.swift
//  The result of a hand, said once, in the middle of the table — and the
//  small pill that says everything smaller.
//
//  `Banner` is for outcomes: "You win 240", "Dealer busts", "You are the
//  durak". A glass card with a symbol, a title in large type, a line under it
//  and, if the player has a choice to make, a button or two. It arrives on a
//  gentle spring and leaves by itself after a while if asked to; nothing about
//  it flashes, shakes or celebrates. A result is information, not a party.
//
//  `Toast` is for everything smaller and passing: "Your turn", "Trumps: ♥",
//  "Blinds up". A capsule that appears, stays long enough to read, and goes.
//  One at a time per view — a new toast replaces the one showing.
//

import AppKit

final class Banner: NSView {

    /// The mood of a result, which only changes the symbol's colour. The
    /// words carry the meaning.
    enum Tone {
        case neutral, win, loss
    }

    private let panel = GlassPanel(cornerRadius: Radius.panel)
    private let symbolView = NSImageView()
    private let titleLabel = Typography.label("", font: Typography.title)
    private let subtitleLabel = Typography.label("", font: Typography.body, color: Palette.textSecondary)
    private var buttons: [CapsuleButton] = []
    private let tone: Tone

    // The auto-dismiss timer. On a table's `TableScheduler` when the game
    // passed one — then it pauses with the table and `cancelAll()` drops it —
    // and otherwise a one-shot dispatch that stops when the banner leaves the
    // window and starts again, with the time it had left, when it returns.
    private weak var scheduler: TableScheduler?
    private var schedulerToken: TableScheduler.Token?
    private var dismissWork: DispatchWorkItem?
    private var dismissDue: CFTimeInterval = 0
    private var dismissRemaining: TimeInterval?

    /// Called once the banner has gone — dismissed by a button, by the timer,
    /// or by the game calling `dismiss()` — unless the game dismissed it with
    /// `notify: false`. This is where "then deal the next hand" goes.
    var onDismiss: (() -> Void)?

    /// Every banner on screen, so a game starting over can clear them all.
    private struct WeakBanner { weak var banner: Banner? }
    private static var showing: [WeakBanner] = []

    private static let padding: CGFloat = 26

    init(title: String, subtitle: String = "", symbolName: String? = nil, tone: Tone = .neutral,
         actions: [ChromeAction] = []) {
        self.tone = tone
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(panel)
        panel.autoresizingMask = [.width, .height]

        let content = panel.contentView
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let color: NSColor
            switch tone {
            case .win: color = Palette.accent
            case .loss: color = Palette.negative
            case .neutral: color = Palette.textPrimary
            }
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color])))
            content.addSubview(symbolView)
        }
        titleLabel.stringValue = title
        titleLabel.alignment = .center
        subtitleLabel.stringValue = subtitle
        subtitleLabel.alignment = .center
        subtitleLabel.isHidden = subtitle.isEmpty
        content.addSubview(titleLabel)
        content.addSubview(subtitleLabel)

        for action in actions {
            var wrapped = action
            let original = action.handler
            wrapped.handler = { [weak self] in
                self?.dismiss()
                original()
            }
            let button = CapsuleButton(wrapped, size: .large)
            button.minimumWidth = 120
            buttons.append(button)
            content.addSubview(button)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, subtitle].filter { !$0.isEmpty }.joined(separator: ". "))
        frame.size = fittingBannerSize
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    // MARK: Showing

    /// Shows a banner in the middle of `host` — `verticalPosition` of the way
    /// down, 0.42 by default so it sits a little above the centre where the
    /// eye rests — and returns it. With `autoDismissAfter`, it goes by itself
    /// after that many seconds; a banner with buttons usually should not.
    ///
    /// Pass the table's `scheduler` for the auto-dismiss and the timer keeps
    /// the table's hours: it waits while the game is suspended, and runs at
    /// once under `runPendingImmediately()` in a test. Without one the banner
    /// keeps its own timer, which waits while the table is out of the window.
    /// Either way nothing dismisses a banner while a snapshot is being taken,
    /// so `--shot` can photograph a result.
    @discardableResult
    static func show(in host: NSView, title: String, subtitle: String = "", symbolName: String? = nil,
                     tone: Tone = .neutral, actions: [ChromeAction] = [], autoDismissAfter: TimeInterval? = nil,
                     scheduler: TableScheduler? = nil, verticalPosition: CGFloat = 0.42) -> Banner {
        let banner = Banner(title: title, subtitle: subtitle, symbolName: symbolName, tone: tone, actions: actions)
        banner.present(in: host, verticalPosition: verticalPosition, autoDismissAfter: autoDismissAfter,
                       scheduler: scheduler)
        return banner
    }

    func present(in host: NSView, verticalPosition: CGFloat = 0.42, autoDismissAfter: TimeInterval? = nil,
                 scheduler: TableScheduler? = nil) {
        cancelTimer()
        frame.size = fittingBannerSize
        let y = host.isFlipped ? host.bounds.height * verticalPosition - frame.height / 2
            : host.bounds.height * (1 - verticalPosition) - frame.height / 2
        frame.origin = CGPoint(x: ((host.bounds.width - frame.width) / 2).rounded(), y: y.rounded())
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        host.addSubview(self)
        layoutSubtreeIfNeeded()
        Self.showing.removeAll { $0.banner == nil || $0.banner === self }
        Self.showing.append(WeakBanner(banner: self))
        Motion.present(self, spring: .gentle, from: 0.94, rise: 10)
        guard let autoDismissAfter, !TabletopEnvironment.isRenderingSnapshot else { return }
        if let scheduler {
            self.scheduler = scheduler
            schedulerToken = scheduler.after(autoDismissAfter) { [weak self] in
                self?.schedulerToken = nil
                self?.dismiss()
            }
        } else {
            startTimer(autoDismissAfter)
        }
    }

    /// Takes the banner away. Safe to call twice.
    ///
    /// `notify: false` takes it away without running `onDismiss` — what a
    /// game wants when it clears the table for a new game, since the old
    /// hand's "deal the next one" must not run inside the new one.
    func dismiss(animated: Bool = true, notify: Bool = true) {
        cancelTimer()
        Self.showing.removeAll { $0.banner == nil || $0.banner === self }
        if !notify { onDismiss = nil }
        guard superview != nil else { return }
        let done = { [weak self] in
            guard let self else { return }
            self.removeFromSuperview()
            let handler = self.onDismiss
            self.onDismiss = nil
            handler?()
        }
        if animated { Motion.dismiss(self, completion: done) } else { done() }
    }

    /// Every banner showing inside `host` (at any depth), newest last.
    static func banners(in host: NSView) -> [Banner] {
        showing.compactMap(\.banner).filter { $0.isDescendant(of: host) }
    }

    /// Takes every banner inside `host` away — the first thing a new game
    /// does. Quietly by default: see `dismiss(animated:notify:)`.
    static func dismissAll(in host: NSView, animated: Bool = false, notify: Bool = false) {
        for banner in banners(in: host) { banner.dismiss(animated: animated, notify: notify) }
    }

    // MARK: Timer

    private func startTimer(_ delay: TimeInterval) {
        dismissWork?.cancel()
        dismissRemaining = nil
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.dismissWork = nil
                self?.dismiss()
            }
        }
        dismissWork = work
        dismissDue = CACurrentMediaTime() + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimer() {
        dismissWork?.cancel()
        dismissWork = nil
        dismissRemaining = nil
        if let schedulerToken { scheduler?.cancel(schedulerToken) }
        schedulerToken = nil
    }

    /// A banner is about the table in front of the player. When the table
    /// leaves the window — the player went to the library — its own timer
    /// stops with the time it had left, and starts again when the table
    /// comes back, so the banner is neither stranded nor gone unread.
    /// (A banner on a scheduler follows the table's suspend and resume.)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, let work = dismissWork {
            work.cancel()
            dismissWork = nil
            dismissRemaining = max(0.6, dismissDue - CACurrentMediaTime())
        } else if window != nil, superview != nil, let left = dismissRemaining {
            startTimer(left)
        }
    }

    // MARK: Layout

    private var fittingBannerSize: CGSize {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let subtitleWidth = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.width
        let buttonsWidth = buttons.map { $0.intrinsicContentSize.width }.reduce(0, +)
            + CGFloat(max(0, buttons.count - 1)) * Spacing.m
        let width = min(560, max(320, max(titleWidth, subtitleWidth, buttonsWidth) + Self.padding * 2))
        var height = Self.padding
        if symbolView.image != nil { height += 36 + Spacing.m }
        height += titleLabel.intrinsicContentSize.height
        if !subtitleLabel.isHidden { height += 4 + subtitleLabel.intrinsicContentSize.height }
        if !buttons.isEmpty { height += Spacing.xl + ControlHeight.large }
        height += Self.padding
        return CGSize(width: ceil(width), height: ceil(height))
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        let inner = bounds.insetBy(dx: Self.padding, dy: 0)
        var y = Self.padding
        if let image = symbolView.image {
            let size = image.size
            symbolView.frame = CGRect(x: (bounds.width - size.width) / 2, y: y + (36 - size.height) / 2,
                                      width: size.width, height: size.height)
            y += 36 + Spacing.m
        }
        let titleHeight = titleLabel.intrinsicContentSize.height
        titleLabel.frame = CGRect(x: inner.minX, y: y, width: inner.width, height: titleHeight)
        y += titleHeight
        if !subtitleLabel.isHidden {
            let h = subtitleLabel.intrinsicContentSize.height
            subtitleLabel.frame = CGRect(x: inner.minX, y: y + 4, width: inner.width, height: h)
            y += 4 + h
        }
        guard !buttons.isEmpty else { return }
        y += Spacing.xl
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let total = widths.reduce(0, +) + CGFloat(buttons.count - 1) * Spacing.m
        var x = ((bounds.width - total) / 2).rounded()
        for (button, width) in zip(buttons, widths) {
            button.frame = CGRect(x: x, y: y, width: width, height: ControlHeight.large)
            x += width + Spacing.m
        }
    }
}

// MARK: - Toast

final class Toast: NSView {

    enum Placement {
        /// Just under the window's titlebar strip.
        case top
        /// The middle of the view.
        case center
        /// `offset` points above the bottom edge — above an action bar, say.
        case bottom(offset: CGFloat)
    }

    private let panel = GlassPanel(capsule: true)
    private let symbolView = NSImageView()
    private let label = Typography.label("", font: Typography.headline)
    private var hideWork: DispatchWorkItem?

    private static var showing: [ObjectIdentifier: Toast] = [:]

    private init(text: String, symbolName: String?, symbolTint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        label.stringValue = text
        panel.contentView.addSubview(label)
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            symbolView.image = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12.5, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [symbolTint])))
            panel.contentView.addSubview(symbolView)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // never in the way of a click

    override var intrinsicContentSize: NSSize {
        let text = Typography.fittingWidth(label)
        let symbol = symbolView.image.map { $0.size.width + 7 } ?? 0
        return NSSize(width: ceil(text + symbol + 34), height: 34)
    }

    override func layout() {
        super.layout()
        panel.frame = bounds
        var x: CGFloat = 18
        if let image = symbolView.image {
            symbolView.frame = CGRect(x: x, y: ((bounds.height - image.size.height) / 2).rounded(),
                                      width: image.size.width, height: image.size.height)
            x += image.size.width + 7
        }
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: x, y: ((bounds.height - size.height) / 2).rounded(),
                             width: max(0, bounds.width - x - 14), height: size.height)
    }

    /// Shows `text` in a pill over `host` for `duration` seconds, replacing
    /// any toast already showing there. VoiceOver announces it.
    ///
    /// The symbol is drawn in the secondary text colour by default — a quiet
    /// glyph beside the words, not an ornament. Keep gold (`Palette.accent`)
    /// for the rare toast that really is "look here", and pick a glyph that
    /// does not read as an emoji at this size: `arrowtriangle.right.fill`
    /// for "your turn", `suit.heart.fill` for a trump, never a pointing hand.
    @discardableResult
    static func show(_ text: String, symbolName: String? = nil, symbolTint: NSColor = Palette.textSecondary,
                     in host: NSView, placement: Placement = .top, duration: TimeInterval = 1.8) -> Toast {
        let key = ObjectIdentifier(host)
        showing[key]?.hide(animated: false)
        let toast = Toast(text: text, symbolName: symbolName, symbolTint: symbolTint)
        toast.frame.size = toast.intrinsicContentSize
        let x = ((host.bounds.width - toast.frame.width) / 2).rounded()
        let height = toast.frame.height
        var y: CGFloat
        switch placement {
        case .top: y = TabletopChrome.topInset(for: host) + Spacing.m
        case .center: y = (host.bounds.height - height) / 2
        case .bottom(let offset): y = host.bounds.height - offset - height
        }
        if !host.isFlipped { y = host.bounds.height - y - height }
        toast.frame.origin = CGPoint(x: x, y: y.rounded())
        // Pinned to the edge it was placed against, so a resize keeps it there.
        var mask: NSView.AutoresizingMask = [.minXMargin, .maxXMargin]
        switch placement {
        case .top: mask.insert(host.isFlipped ? .maxYMargin : .minYMargin)
        case .bottom: mask.insert(host.isFlipped ? .minYMargin : .maxYMargin)
        case .center: mask.formUnion([.minYMargin, .maxYMargin])
        }
        toast.autoresizingMask = mask
        host.addSubview(toast)
        toast.layoutSubtreeIfNeeded()
        showing[key] = toast
        Motion.present(toast, spring: .smooth, from: 0.96, rise: -6)
        NSAccessibility.post(element: toast, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])

        let work = DispatchWorkItem { [weak toast] in
            MainActor.assumeIsolated { toast?.hide(animated: true) }
        }
        toast.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        return toast
    }

    /// Hides the toast showing over `host`, if there is one.
    static func hide(in host: NSView, animated: Bool = true) {
        showing[ObjectIdentifier(host)]?.hide(animated: animated)
    }

    func hide(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        if let host = superview, Toast.showing[ObjectIdentifier(host)] === self {
            Toast.showing[ObjectIdentifier(host)] = nil
        }
        guard superview != nil else { return }
        if animated {
            Motion.dismiss(self) { [weak self] in self?.removeFromSuperview() }
        } else {
            removeFromSuperview()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window — the player went back to the library — ends
        // the toast there and then, timer and all.
        if window == nil, hideWork != nil { hide(animated: false) }
    }
}
