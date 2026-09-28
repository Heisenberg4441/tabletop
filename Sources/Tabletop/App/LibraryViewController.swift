//
//  LibraryViewController.swift
//  The first thing the player sees: every game in the collection, as a shelf
//  of covers.
//
//  One tile per game in `GameCatalog`, each with the game's own cover art
//  (drawn by the game, rasterised once per size and cached), its name, one
//  line about it and who it is for. Click a tile — or pick one with the arrow
//  keys and press Return — and the window controller swaps the game in.
//
//  Nothing here animates on its own. The only motion is a tile rising a
//  little under the pointer, and under Reduce Motion even that is a change of
//  shadow rather than a movement.
//

import AppKit
import QuartzCore

final class LibraryViewController: NSViewController {

    /// Called with the game the player chose. Set by the window controller.
    var onOpen: ((GameID) -> Void)?

    private var grid: LibraryGridView!
    private var scrollView: NSScrollView!
    private var preferencesObserver: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    override func loadView() {
        let backdrop = LibraryBackdropView()

        grid = LibraryGridView(games: GameCatalog.all.map { $0.info })
        grid.onOpen = { [weak self] id in self?.onOpen?(id) }

        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = grid
        scrollView.contentView.postsBoundsChangedNotifications = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        view = backdrop

        // The covers show real cards, so a new card back in the View menu
        // should reach them too — which means painting them again.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: TablePreferences.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                LibraryArtwork.removeAll()
                self?.grid.refreshArtwork()
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        grid.topInset = TabletopChrome.topInset(for: view)
        grid.fit(width: scrollView.contentView.bounds.width,
                 minimumHeight: scrollView.contentView.bounds.height)
    }

    /// The grid takes the keyboard, so arrows and Return work at once.
    var preferredFirstResponder: NSView? { grid }

    /// For `--shot library`: the first tile chosen, the way a player arriving
    /// by keyboard would see it, and nothing hovered.
    func prepareForScreenshot() {
        grid.select(index: 0, showRing: false)
    }
}

// MARK: - Backdrop

/// The room the shelf stands in: near-black, lit from above and to the left
/// like every table in the collection, with a trace of grain so the dark reads
/// as a surface rather than as an absence.
final class LibraryBackdropView: NSView {

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(TabletopRootView.roomColor.cgColor)
        ctx.fill(bounds)
        let lamp = CGPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY - bounds.height * 0.10)
        if let g = AppleStyle.gradient([
            (NSColor(srgbRed: 0.170, green: 0.168, blue: 0.176, alpha: 1), 0),
            (NSColor(srgbRed: 0.090, green: 0.089, blue: 0.095, alpha: 1), 0.55),
            (TabletopRootView.roomColor, 1),
        ]) {
            ctx.drawRadialGradient(g, startCenter: lamp, startRadius: 0, endCenter: lamp,
                                   endRadius: hypot(bounds.width, bounds.height) * 0.85,
                                   options: [.drawsAfterEndLocation])
        }
        AppleStyle.grain(in: bounds, context: ctx, alpha: 0.05, spread: 20)
    }
}

// MARK: - Grid

/// The shelf: a header, the featured game as a wide hero, and the rest in a
/// grid that reflows with the window — four across when there is room, two
/// when there is not.
final class LibraryGridView: NSView {

    var onOpen: ((GameID) -> Void)?

    /// The titlebar strip, which the header keeps clear of.
    var topInset: CGFloat = TabletopChrome.minimumTopInset {
        didSet { if topInset != oldValue { needsLayout = true } }
    }

    private let titleLabel = Typography.label(NSLocalizedString("Tabletop", comment: "app name, library heading"),
                                              font: Typography.largeTitle)
    private let subtitleLabel = Typography.label(NSLocalizedString("Classic games for the table", comment: "library subheading"),
                                                 font: .systemFont(ofSize: 15, weight: .regular),
                                                 color: Palette.textSecondary)
    private let allGamesLabel = Typography.label("", font: Typography.eyebrow, color: Palette.textTertiary)
    private var tiles: [LibraryTileView] = []
    private var selectedIndex = 0
    private var ringVisible = false

    private enum Metric {
        static let headerTop: CGFloat = 16
        static let headerGap: CGFloat = 22
        static let sectionGap: CGFloat = 30
        static let eyebrowGap: CGFloat = 12
        static let columnGap: CGFloat = 24
        static let rowGap: CGFloat = 30
        static let minimumFourUpTileWidth: CGFloat = 186
        static let maximumContentWidth: CGFloat = 1320
        static let bottomMargin: CGFloat = 36
        static let minimumHeroHeight: CGFloat = 210
    }

    /// The height of the scroll view's visible area, which the hero shrinks
    /// to fit so the whole shelf is in view at once whenever it can be.
    private var viewportHeight: CGFloat = 800

    init(games: [GameInfo]) {
        super.init(frame: .zero)
        wantsLayer = true

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        allGamesLabel.attributedStringValue = NSAttributedString(
            string: NSLocalizedString("All Games", comment: "library section heading").uppercased(),
            attributes: Typography.attributes(Typography.eyebrow, Palette.textTertiary, kern: Typography.eyebrowKern))
        addSubview(allGamesLabel)

        for (index, info) in games.enumerated() {
            let tile = LibraryTileView(info: info, style: index == 0 ? .hero : .standard)
            tile.onOpen = { [weak self] in
                self?.select(index: index, showRing: false)
                self?.onOpen?(info.id)
            }
            tile.onHover = { [weak self] in self?.pointerArrived(at: index) }
            tiles.append(tile)
            addSubview(tile)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Games", comment: "accessibility: the library grid"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Sizes the grid for a viewport `width` wide, at least `minimumHeight`
    /// tall so the backdrop's clicks and scrolls land on it everywhere.
    func fit(width: CGFloat, minimumHeight: CGFloat) {
        viewportHeight = minimumHeight
        let height = max(minimumHeight, contentHeight(forWidth: width))
        if frame.size != CGSize(width: width, height: height) {
            setFrameSize(CGSize(width: width, height: height))
        }
        needsLayout = true
    }

    // MARK: Geometry

    private func sideMargin(forWidth width: CGFloat) -> CGFloat {
        min(64, max(36, width * 0.045)).rounded()
    }

    /// The column the whole shelf sits in: centred, never wider than a
    /// comfortable reading width, whatever the screen.
    private func content(forWidth width: CGFloat) -> (left: CGFloat, width: CGFloat) {
        let margin = sideMargin(forWidth: width)
        let available = max(1, width - margin * 2)
        let used = min(available, Metric.maximumContentWidth)
        return (((width - used) / 2).rounded(), used)
    }

    private func grid(forWidth width: CGFloat) -> (columns: Int, tileWidth: CGFloat) {
        let available = content(forWidth: width).width
        let fourUp = (available - 3 * Metric.columnGap) / 4
        let columns = fourUp >= Metric.minimumFourUpTileWidth ? 4 : 2
        let tileWidth = ((available - CGFloat(columns - 1) * Metric.columnGap) / CGFloat(columns)).rounded(.down)
        return (columns, tileWidth)
    }

    /// Wide and cinematic when there is room, never so tall that it pushes
    /// the rest of the shelf out of a small window: the hero takes whatever
    /// height the header and the grid leave, up to 38% of its width — so a
    /// big window is filled by the picture rather than by empty room under
    /// the shelf.
    private func heroHeight(forWidth width: CGFloat) -> CGFloat {
        let available = content(forWidth: width).width
        let ideal = min(560, available * 0.38)
        let rest = contentHeight(forWidth: width, hero: 0)
        let fits = viewportHeight - rest
        return max(Metric.minimumHeroHeight, min(ideal, fits)).rounded()
    }

    private var headerHeight: CGFloat {
        topInset + Metric.headerTop + titleLabel.intrinsicContentSize.height + 2
            + subtitleLabel.intrinsicContentSize.height + Metric.headerGap
    }

    private func contentHeight(forWidth width: CGFloat, hero: CGFloat? = nil) -> CGFloat {
        let (columns, tileWidth) = grid(forWidth: width)
        let others = max(0, tiles.count - 1)
        let rows = (others + columns - 1) / columns
        let tileHeight = LibraryTileView.height(forWidth: tileWidth)
        return headerHeight + (hero ?? heroHeight(forWidth: width)) + Metric.sectionGap
            + allGamesLabel.intrinsicContentSize.height + Metric.eyebrowGap
            + CGFloat(rows) * tileHeight + CGFloat(max(0, rows - 1)) * Metric.rowGap + Metric.bottomMargin
    }

    override func layout() {
        super.layout()
        let (left, width) = content(forWidth: bounds.width)
        var y = topInset + Metric.headerTop
        let title = titleLabel.intrinsicContentSize
        titleLabel.frame = CGRect(x: left, y: y, width: width, height: title.height)
        y += title.height + 2
        let subtitle = subtitleLabel.intrinsicContentSize
        subtitleLabel.frame = CGRect(x: left + 1, y: y, width: width, height: subtitle.height)
        y = headerHeight

        guard let hero = tiles.first else { return }
        let heroHeight = heroHeight(forWidth: bounds.width)
        hero.frame = CGRect(x: left, y: y, width: width, height: heroHeight)
        y += heroHeight + Metric.sectionGap

        let eyebrow = allGamesLabel.intrinsicContentSize
        allGamesLabel.frame = CGRect(x: left + 1, y: y, width: width, height: eyebrow.height)
        y += eyebrow.height + Metric.eyebrowGap

        let (columns, tileWidth) = grid(forWidth: bounds.width)
        let tileHeight = LibraryTileView.height(forWidth: tileWidth)
        for (i, tile) in tiles.dropFirst().enumerated() {
            let row = i / columns
            let column = i % columns
            tile.frame = CGRect(x: (left + CGFloat(column) * (tileWidth + Metric.columnGap)).rounded(),
                                y: y + CGFloat(row) * (tileHeight + Metric.rowGap),
                                width: tileWidth, height: tileHeight)
        }
    }

    func refreshArtwork() {
        tiles.forEach { $0.refreshArtwork() }
    }

    // MARK: Keyboard

    func select(index: Int, showRing: Bool) {
        guard !tiles.isEmpty else { return }
        selectedIndex = min(max(0, index), tiles.count - 1)
        ringVisible = showRing
        for (i, tile) in tiles.enumerated() {
            tile.isSelected = ringVisible && i == selectedIndex
        }
        if showRing { tiles[selectedIndex].scrollToVisible(tiles[selectedIndex].bounds.insetBy(dx: 0, dy: -28)) }
    }

    /// The tile the arrow key points at from the selected one: the nearest
    /// whose centre lies in that direction, favouring ones straight ahead —
    /// which is what makes "down" from the wide hero land on the tile under
    /// the middle of it rather than on the first in the row.
    private func neighbour(of index: Int, dx: CGFloat, dy: CGFloat) -> Int? {
        let from = tiles[index].frame
        let origin = CGPoint(x: from.midX, y: from.midY)
        var best: (index: Int, score: CGFloat)?
        for (i, tile) in tiles.enumerated() where i != index {
            let c = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            let along = (c.x - origin.x) * dx + (c.y - origin.y) * dy
            guard along > 1 else { continue }
            let across = abs((c.x - origin.x) * dy) + abs((c.y - origin.y) * dx)
            let score = along + across * 2.5
            if best == nil || score < best!.score { best = (i, score) }
        }
        return best?.index
    }

    override func keyDown(with event: NSEvent) {
        guard !tiles.isEmpty else { return super.keyDown(with: event) }
        // The first press only shows where the selection is, the way focus
        // works everywhere on the Mac; the next one moves it.
        let step: (CGFloat, CGFloat) -> Void = { dx, dy in
            if !self.ringVisible {
                self.select(index: self.selectedIndex, showRing: true)
            } else if let next = self.neighbour(of: self.selectedIndex, dx: dx, dy: dy) {
                self.select(index: next, showRing: true)
            }
        }
        switch Int(event.keyCode) {
        case 123: step(-1, 0)                    // left
        case 124: step(1, 0)                     // right
        case 125: step(0, 1)                     // down
        case 126: step(0, -1)                    // up
        case 48:                                 // tab, shift-tab
            let forward = !event.modifierFlags.contains(.shift)
            select(index: ringVisible ? (selectedIndex + (forward ? 1 : tiles.count - 1)) % tiles.count : selectedIndex,
                   showRing: true)
        case 36, 76, 49:                         // return, enter, space
            onOpen?(tiles[selectedIndex].info.id)
        default:
            super.keyDown(with: event)
        }
    }

    /// The pointer takes over from the keyboard: the ring goes.
    private func pointerArrived(at index: Int) {
        guard ringVisible else { return }
        select(index: index, showRing: false)
    }
}

// MARK: - Tile

/// One game on the shelf.
///
/// Two shapes. The hero is the featured game: its cover fills the whole
/// tile, and its name, one line about it and a Play button sit over the
/// bottom of the picture on a soft scrim. A standard tile has the cover on
/// top, untouched — nothing is laid over the picture — and the words
/// underneath, with a small Play capsule at the end of the name's line, the
/// way the App Store sets a Get button beside an app.
final class LibraryTileView: NSView {

    enum Style { case hero, standard }

    let info: GameInfo
    let style: Style
    var onOpen: (() -> Void)?
    var onHover: (() -> Void)?

    var isSelected = false {
        didSet { if isSelected != oldValue { updateLift(animated: true) } }
    }

    private let cover = CALayer()          // shadow and lift
    private let art = CALayer()            // the picture, clipped to the rounded rect
    private let scrim = CAGradientLayer()  // under the hero's words
    private let ring = CAShapeLayer()      // keyboard selection
    private let eyebrowLabel = Typography.label("", font: Typography.eyebrow, color: Palette.textSecondary)
    private let titleLabel = Typography.label("")
    private let subtitleLabel = Typography.label("")
    private let detailLabel = Typography.label("")
    private let playButton: CapsuleButton
    private var isHovered = false { didSet { if isHovered != oldValue { updateLift(animated: true) } } }
    private var isPressed = false { didSet { if isPressed != oldValue { updateLift(animated: true) } } }
    private var artworkKey = ""

    static let artAspect: CGFloat = 10.0 / 16.0
    static let cornerRadius: CGFloat = Radius.large

    /// Everything under a standard tile's picture: the name's line (as tall
    /// as the Play capsule at its end), a subtitle of up to two lines
    /// (translations run long), and the players line.
    private static let textBlock: CGFloat = 10 + ControlHeight.small + 2 + 16 * 2 + 16

    static func height(forWidth width: CGFloat) -> CGFloat {
        (width * artAspect).rounded() + textBlock
    }

    init(info: GameInfo, style: Style) {
        self.info = info
        self.style = style
        playButton = CapsuleButton(title: NSLocalizedString("Play", comment: "library: open this game"),
                                   symbolName: "play.fill",
                                   style: style == .hero ? .primary : .secondary,
                                   size: style == .hero ? .regular : .small)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        cover.shadowColor = NSColor.black.cgColor
        cover.shadowOpacity = 0.45
        cover.shadowRadius = 10
        cover.shadowOffset = CGSize(width: 0, height: 6)
        art.cornerRadius = Self.cornerRadius
        art.cornerCurve = .continuous
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        // A hairline of light around the edge, as glass and metal catch it.
        art.borderWidth = 0.5
        art.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        cover.addSublayer(art)

        if style == .hero {
            // Dark at the bottom-left where the words are, clear by the top
            // right, so the picture is untouched where it matters.
            scrim.colors = [NSColor(white: 0, alpha: 0.78).cgColor, NSColor(white: 0, alpha: 0.30).cgColor,
                            NSColor(white: 0, alpha: 0).cgColor]
            scrim.locations = [0, 0.45, 1]
            scrim.startPoint = CGPoint(x: 0.25, y: 1)      // the tile is flipped: y = 1 is the bottom
            scrim.endPoint = CGPoint(x: 0.55, y: 0.35)
            art.addSublayer(scrim)
        }

        ring.fillColor = nil
        ring.strokeColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(1).cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        cover.addSublayer(ring)
        layer?.addSublayer(cover)

        titleLabel.stringValue = info.title
        subtitleLabel.stringValue = info.subtitle
        detailLabel.stringValue = info.detail
        switch style {
        case .hero:
            eyebrowLabel.attributedStringValue = NSAttributedString(
                string: NSLocalizedString("Featured", comment: "library: the hero tile's label").uppercased(),
                attributes: Typography.attributes(Typography.eyebrow, Palette.accentSoft, kern: Typography.eyebrowKern))
            // A step under the page's own 34-point heading, so there is one
            // top-level title on the screen, not two a hundred points apart.
            titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
            subtitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
            subtitleLabel.textColor = NSColor(white: 1, alpha: 0.86)
            detailLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            detailLabel.textColor = Palette.textSecondary
            for label in [eyebrowLabel, titleLabel, subtitleLabel, detailLabel] {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
                shadow.shadowBlurRadius = 6
                shadow.shadowOffset = CGSize(width: 0, height: -1)
                label.shadow = shadow
                addSubview(label)
            }
        case .standard:
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            subtitleLabel.font = .systemFont(ofSize: 12.5)
            subtitleLabel.textColor = Palette.textSecondary
            subtitleLabel.maximumNumberOfLines = 2
            subtitleLabel.lineBreakMode = .byWordWrapping
            subtitleLabel.cell?.wraps = true
            subtitleLabel.cell?.truncatesLastVisibleLine = true
            detailLabel.font = .systemFont(ofSize: 11.5)
            detailLabel.textColor = Palette.textTertiary
            for label in [titleLabel, subtitleLabel, detailLabel] { addSubview(label) }
        }

        playButton.handler = { [weak self] in self?.onOpen?() }
        // The tile is the button VoiceOver reads; the capsule is the same
        // action again and would only be read twice.
        playButton.setAccessibilityElement(false)
        addSubview(playButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(info.title)
        setAccessibilityHelp(info.subtitle)
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var artFrame: CGRect {
        switch style {
        case .hero: return bounds
        case .standard: return CGRect(x: 0, y: 0, width: bounds.width, height: (bounds.width * Self.artAspect).rounded())
        }
    }

    override func layout() {
        super.layout()
        let frame = artFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.frame = frame
        art.frame = cover.bounds
        scrim.frame = art.bounds
        cover.shadowPath = CGPath(roundedRect: cover.bounds, cornerWidth: Self.cornerRadius,
                                  cornerHeight: Self.cornerRadius, transform: nil)
        ring.path = CGPath(roundedRect: cover.bounds.insetBy(dx: -4, dy: -4),
                           cornerWidth: Self.cornerRadius + 4, cornerHeight: Self.cornerRadius + 4,
                           transform: nil)
        CATransaction.commit()

        let play = playButton.intrinsicContentSize
        switch style {
        case .hero:
            let inset: CGFloat = bounds.width > 700 ? 34 : 26
            let textWidth = min(bounds.width * 0.62, bounds.width - inset * 2 - play.width - 16)
            var y = bounds.height - inset
            let detail = detailLabel.intrinsicContentSize
            y -= detail.height
            detailLabel.frame = CGRect(x: inset, y: y, width: textWidth, height: detail.height)
            let subtitle = subtitleLabel.intrinsicContentSize
            y -= subtitle.height + 2
            subtitleLabel.frame = CGRect(x: inset, y: y, width: textWidth, height: subtitle.height)
            let title = titleLabel.intrinsicContentSize
            y -= title.height
            titleLabel.frame = CGRect(x: inset - 1, y: y, width: textWidth, height: title.height)
            let eyebrow = eyebrowLabel.intrinsicContentSize
            y -= eyebrow.height + 2
            eyebrowLabel.frame = CGRect(x: inset, y: y, width: textWidth, height: eyebrow.height)
            playButton.frame = CGRect(x: bounds.width - inset - max(play.width, 104), y: bounds.height - inset - play.height,
                                      width: max(play.width, 104), height: play.height)
        case .standard:
            // Play ends the name's line, right-aligned under the picture's
            // edge; the name takes what is left of the line, the subtitle and
            // the players line the full width below.
            var y = frame.maxY + 10
            let line = ControlHeight.small
            playButton.frame = CGRect(x: bounds.width - play.width, y: y, width: play.width, height: play.height)
            let textWidth = bounds.width - 4
            let titleHeight = titleLabel.intrinsicContentSize.height
            titleLabel.frame = CGRect(x: 2, y: y + ((line - titleHeight) / 2).rounded(),
                                      width: max(0, playButton.frame.minX - 8 - 2), height: titleHeight)
            y += line + 2
            let subtitleHeight = min(32, ceil((info.subtitle as NSString).boundingRect(
                with: CGSize(width: textWidth - 4, height: 100), options: [.usesLineFragmentOrigin],
                attributes: [.font: subtitleLabel.font ?? NSFont.systemFont(ofSize: 12.5)]).height) + 1)
            subtitleLabel.frame = CGRect(x: 2, y: y, width: textWidth, height: subtitleHeight)
            y += subtitleHeight
            detailLabel.frame = CGRect(x: 2, y: y, width: textWidth, height: 16)
        }
        refreshArtwork()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshArtwork()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        refreshArtwork()
    }

    /// Leaving the window — the player opened a game — means the pointer left
    /// too, whether or not AppKit gets round to saying so; a tile must not be
    /// found still raised when the library comes back.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            isPressed = false
        }
    }

    /// Puts the cover in, from the cache if this size has been painted before.
    func refreshArtwork() {
        // A window being dragged wider keeps the cover it has — the layer
        // scales it — and paints the right one once the drag is over.
        if inLiveResize, art.contents != nil { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = artFrame.size
        guard size.width > 1, size.height > 1 else { return }
        let key = LibraryArtwork.key(for: info.id, size: size, scale: scale)
        guard key != artworkKey || art.contents == nil else { return }
        artworkKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.contents = LibraryArtwork.image(for: info.id, size: size, scale: scale)
        art.contentsScale = scale
        CATransaction.commit()
    }

    // MARK: Lift

    /// Under the pointer, or chosen from the keyboard, the cover rises a
    /// little towards the light: a longer, softer shadow and a small swell,
    /// on a critically damped spring so it settles without wobbling. The
    /// hero, whose words sit on its picture, swells less. Under Reduce Motion
    /// the shadow changes and nothing moves.
    private func updateLift(animated: Bool) {
        let lifted = (isHovered || isSelected) && !isPressed
        let motion = animated && TabletopEnvironment.animationsEnabled
        let swell: CGFloat = style == .hero ? 1.006 : 1.02
        let scale: CGFloat = motion ? (isPressed ? 0.99 : (lifted ? swell : 1)) : 1
        // The cover is a plain layer anchored at its centre, so this swells
        // it about the middle rather than from a corner.
        let transform = CATransform3DMakeScale(scale, scale, 1)

        let targets: [(String, Any)] = [
            ("shadowRadius", lifted ? 20 : 10),
            ("shadowOffset", NSValue(size: CGSize(width: 0, height: lifted ? 14 : 6))),
            ("shadowOpacity", lifted ? 0.58 : 0.45),
            ("transform", NSValue(caTransform3D: transform)),
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (keyPath, value) in targets {
            let from = cover.presentation()?.value(forKeyPath: keyPath) ?? cover.value(forKeyPath: keyPath)
            cover.setValue(value, forKeyPath: keyPath)
            guard motion else { continue }
            cover.add(Motion.spring(keyPath, from: from, to: value, spring: .snappy), forKey: keyPath)
        }
        ring.opacity = isSelected ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; onHover?() }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }
}

// MARK: - Artwork cache

/// The covers, painted once per game, size and scale.
///
/// A cover is drawn by the game itself and may be expensive — real cards
/// through `CardRenderer`, cloth with weave and grain — so it is never drawn
/// twice for the same size. Sizes are bucketed to 16 points so that dragging
/// the window wider repaints a cover every so often rather than on every frame
/// of the drag; the layer fills the tile from the nearest bucket, which on a
/// picture like this is not something an eye can find. The hero's picture is
/// much wider than a standard tile's, and each game draws for whatever shape
/// it is given.
///
/// Only the latest size of each game's cover is kept. Every size a window
/// passes through on its way to where the player leaves it would otherwise
/// stay in memory for the session — seven megabytes a time for the hero —
/// while the one that matters is the one on screen.
@MainActor
enum LibraryArtwork {

    private static var cache: [GameID: (key: String, image: CGImage)] = [:]

    static func bucket(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width / 16).rounded(.up) * 16, height: (size.height / 16).rounded(.up) * 16)
    }

    static func key(for id: GameID, size: CGSize, scale: CGFloat) -> String {
        let b = bucket(size)
        return "\(id.rawValue)|\(Int(b.width))x\(Int(b.height))|\(scale)"
    }

    static func image(for id: GameID, size: CGSize, scale: CGFloat) -> CGImage? {
        let key = key(for: id, size: size, scale: scale)
        if let cached = cache[id], cached.key == key { return cached.image }
        let b = bucket(size)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: max(1, Int(b.width * scale)), height: max(1, Int(b.height * scale)),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Top-left origin, as the contract promises.
        ctx.translateBy(x: 0, y: b.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        GameCatalog.type(for: id).drawArtwork(in: ctx, rect: CGRect(origin: .zero, size: b))
        let image = ctx.makeImage()
        if let image { cache[id] = (key, image) }
        return image
    }

    /// How many covers are held, for the harness's memory check.
    static var cachedCount: Int { cache.count }

    static func removeAll() {
        cache.removeAll()
    }
}
