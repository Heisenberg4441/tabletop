//
//  KitRegressionTests.swift
//  Checks for the traps the foundation's review found in the kit — each one
//  something a game would have walked into by following the docs: an options
//  card shown a second time coming up invisible, a result banner stranded by
//  a trip to the library, a table resizing every card when a bet slider
//  comes and goes, an old button answering a key while it fades out, a click
//  that could not be backed out of, blackjack's lettering under the player's
//  cards. Every check here pins one of those shut.
//

import AppKit

@MainActor
extension KitTests {

    static func runRegressions(_ t: TestReporter) {
        presentingAgain(t)
        banners(t)
        actionBarReserve(t)
        clicks(t)
        halfMoonPrinting(t)
        tableLayers(t)
        newControls(t)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A table in a window that is never shown.
    private static func hostTable(_ shape: TableShape = .rectangular,
                                  size: CGSize = CGSize(width: 1000, height: 700)) -> (CardTableView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let table = CardTableView(shape: shape)
        table.frame = CGRect(origin: .zero, size: size)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    // MARK: Present, dismiss, present again

    private static func presentingAgain(_ t: TestReporter) {
        t.section("Presenting a card again")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = saved }
        let (table, window) = hostTable()
        defer { withExtendedLifetime(window) {} }

        let card = OptionsCard(title: "New Game", rows: [OptionsCard.Row(id: "n", title: "Opponents", options: ["1", "2"])])
        card.onCancel = {}
        card.present(in: table, animated: true)
        pump(0.1)
        card.dismiss(animated: true)
        pump(0.7)
        let lingering = (card.layer?.animationKeys() ?? []).filter { $0.hasPrefix("motion.dismiss") }
        t.check("a dismissed card leaves no fade behind on its layer \(lingering)", lingering.isEmpty)
        card.present(in: table, animated: true)
        pump(1.0)
        let keys = (card.layer?.animationKeys() ?? []).filter { $0.hasPrefix("motion.dismiss") }
        let opacity = card.layer?.presentation()?.opacity ?? card.layer?.opacity ?? 0
        t.check("presented again, it is visible (opacity \(opacity)) with no old fade on it \(keys)",
                keys.isEmpty && opacity > 0.95 && card.alphaValue == 1 && card.isPresented)
        t.check("and it has the keyboard", window.firstResponder === card)
        card.present(in: table, animated: true)
        t.check("presenting a card that is up does nothing more",
                table.subviews.filter { $0 is OptionsScrim }.count == 1)

        // Presented again while still fading out: back at once, and the old
        // exit's tidy-up never takes it away.
        card.dismiss(animated: true)
        pump(0.03)
        card.present(in: table, animated: true)
        pump(0.8)
        t.check("a card presented mid-dismissal stays up and visible",
                card.superview != nil && card.isPresented && (card.layer?.presentation()?.opacity ?? 1) > 0.95)
        t.check("and keeps the keyboard", window.firstResponder === card)
        card.dismiss(animated: false)
        t.check("dismissed, it hands the keyboard back to the table", window.firstResponder === table)

        // A card presented before its table is in a window takes the keyboard
        // when it arrives.
        let loose = CardTableView(shape: .rectangular)
        loose.frame = table.frame
        let early = OptionsCard(title: "New Game", rows: [])
        early.present(in: loose, animated: false)
        window.contentView = loose
        pump(0.05)
        t.check("a card presented before its table reached a window takes the keyboard there",
                window.firstResponder === early)
        early.dismiss(animated: false)
    }

    // MARK: Banners

    private static func banners(_ t: TestReporter) {
        t.section("Banners that wait")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = saved }
        let (table, window) = hostTable()
        defer { withExtendedLifetime(window) {} }

        // On the table's scheduler: it keeps the table's hours.
        let scheduler = TableScheduler(immediate: false)
        var said: [String] = []
        let timed = Banner.show(in: table, title: "You win 40", autoDismissAfter: 5, scheduler: scheduler)
        timed.onDismiss = { said.append("next hand") }
        t.check("a banner's auto-dismiss can wait on the table's scheduler", scheduler.pendingCount == 1)
        scheduler.suspend()
        scheduler.runPendingImmediately()
        t.check("and goes when the scheduler says, running its follow-up once",
                timed.superview == nil && said == ["next hand"])

        // On its own timer: the table goes to the library and comes back.
        said.removeAll()
        let own = Banner.show(in: table, title: "Dealer busts", autoDismissAfter: 0.25)
        own.onDismiss = { said.append("own") }
        let parking = NSView(frame: table.frame)
        window.contentView = parking
        pump(0.45)
        t.check("a banner out of the window is not dismissed while away",
                own.superview === table && said.isEmpty)
        window.contentView = table
        pump(0.9)
        t.check("and back in the window it goes by itself after all", own.superview == nil && said == ["own"])

        // Quietly, for a new game.
        said.removeAll()
        let quiet = Banner.show(in: table, title: "Push")
        quiet.onDismiss = { said.append("quiet") }
        let another = Banner.show(in: table, title: "Split")
        t.check("every banner on a table can be found", Banner.banners(in: table).count == 2)
        Banner.dismissAll(in: table)
        t.check("and cleared for a new game without running the old hand's follow-up",
                quiet.superview == nil && another.superview == nil && said.isEmpty)
    }

    // MARK: Action bar

    private static func actionBarReserve(_ t: TestReporter) {
        t.section("An action bar that keeps its height")
        let (table, window) = hostTable()
        defer { withExtendedLifetime(window) {} }
        let bar = ActionBar()
        bar.install(in: table)
        bar.setActions([ChromeAction(id: "fold", title: "Fold") {}], animated: false)
        let bare = bar.reservedHeight
        let bet = BetControl(minimum: 20, maximum: 400, step: 10, value: 20)
        bar.leadingAccessory = bet
        t.check("an accessory taller than the buttons grows an ordinary bar", bar.reservedHeight > bare)
        bar.minimumContentHeight = BetControl.height
        let withBet = bar.reservedHeight
        bar.leadingAccessory = nil
        t.check("with minimumContentHeight set, the reserve is the same with the accessory and without",
                abs(bar.reservedHeight - withBet) < 0.5)
        t.check("and matches the reserve worked out up front",
                abs(ActionBar.reservedHeight(contentHeight: BetControl.height, bottomMargin: bar.bottomMargin)
                    - withBet) < 0.5)

        // The slider has the keyboard when its bet control leaves the bar.
        bar.leadingAccessory = bet
        table.layoutSubtreeIfNeeded()
        let slider = bet.subviews.first { $0 is BetSlider }
        if let slider { window.makeFirstResponder(slider) }
        bar.leadingAccessory = nil
        t.check("taking out a focused accessory hands the keyboard to the table, not the window",
                window.firstResponder === table)

        // Old buttons during the crossfade.
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = saved }
        var raised = 0
        bar.setActions([ChromeAction(id: "raise", title: "Raise", keyEquivalent: "r") { raised += 1 }], animated: false)
        let old = bar.button(for: "raise")
        bar.setActions([ChromeAction(id: "call", title: "Call") {}], animated: true)
        old?.activate(nil)
        old?.performPress()
        let point = old.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
        t.check("a button fading out of the bar answers no key and no click",
                raised == 0 && old?.isRetired == true && old?.keyEquivalent == "" && old?.hitTest(point) == nil)
    }

    // MARK: Clicks

    private final class ClickTable: CardTableView {
        var clicked: [Int] = []
        var cloth = 0
        override func spriteClicked(_ id: Int, with event: NSEvent) { clicked.append(id) }
        override func tableClicked(at point: CGPoint, with event: NSEvent) { cloth += 1 }
    }

    private static func clicks(_ t: TestReporter) {
        t.section("Clicks on the table")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = saved }
        let size = CGSize(width: 1000, height: 700)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let table = ClickTable(shape: .rectangular)
        table.frame = CGRect(origin: .zero, size: size)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        let center = CGPoint(x: 500, y: 350)
        table.sprite(id: 3, card: Card(.hearts, .seven))
        table.place(3, at: center, z: 1, duration: 0)

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: table.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: 1)
        }
        func click(from a: CGPoint, to b: CGPoint) {
            if let down = event(.leftMouseDown, at: a) { table.mouseDown(with: down) }
            if let up = event(.leftMouseUp, at: b) { table.mouseUp(with: up) }
        }
        click(from: center, to: CGPoint(x: center.x + 2, y: center.y + 1))
        t.check("pressed and released on a card is a click on it", table.clicked == [3])
        click(from: center, to: CGPoint(x: 80, y: 600))
        t.check("pressed on a card and let go off it is nothing at all", table.clicked == [3] && table.cloth == 0)
        click(from: CGPoint(x: 80, y: 600), to: CGPoint(x: 82, y: 601))
        t.check("the cloth is clicked where it is pressed and released", table.cloth == 1)
        withExtendedLifetime(window) {}
    }

    // MARK: Blackjack's printing

    private static func halfMoonPrinting(_ t: TestReporter) {
        t.section("The half-moon's printing and the player's cards")
        var problems: [String] = []
        var droppedRule = false, keptRule = false
        for size in [CGSize(width: 960, height: 640), CGSize(width: 1200, height: 800),
                     CGSize(width: 1600, height: 1000), CGSize(width: 2200, height: 1300)] {
            let bounds = CGRect(origin: .zero, size: size)
            let reserve = ActionBar.reservedHeight(contentHeight: ChipRackView.height)
            let card = CardSizePolicy.blackjack.cardSize(for: CGSize(width: size.width,
                                                                     height: size.height - 40 - reserve))
            for spots in [1, 3] {
                let g = TableSurface.geometry(for: .halfMoon(HalfMoonPrint(betSpots: spots)), in: bounds,
                                              topInset: 40, bottomReserve: reserve, cardWidth: card.width)
                let name = "\(Int(size.width))×\(Int(size.height))/\(spots)"
                guard let m = g.markings else { problems.append("\(name): no markings"); continue }
                if m.ruleRadius == nil { droppedRule = true } else { keptRule = true }
                let spotTop = g.betSpots.map { hypot($0.x - g.arcCenter.x, $0.y - g.arcCenter.y) }.min() ?? 0
                if m.handBand.upperBound > spotTop - g.betSpotRadius + 0.5 { problems.append("\(name): band over circles") }
                if m.handBand.upperBound - m.handBand.lowerBound < card.height { problems.append("\(name): band too thin") }
                if let band = m.insuranceBand, band.upperBound > m.handBand.lowerBound {
                    problems.append("\(name): insurance in the card band")
                }
                if let rule = m.ruleRadius, rule > (m.insuranceBand?.lowerBound ?? m.handBand.lowerBound) {
                    problems.append("\(name): rule in the band")
                }
                if m.headlineRadius > (m.ruleRadius ?? m.insuranceBand?.lowerBound ?? m.handBand.lowerBound) {
                    problems.append("\(name): headline out of order")
                }
                // The headline's letters keep clear of the dealer's hand.
                let lettersTop = m.headlineRadius - m.size * 0.95
                let clearX = card.width * 1.6
                let top = g.arcCenter.y + (max(0, lettersTop * lettersTop - clearX * clearX)).squareRoot()
                if top < g.dealerArea.y + card.height / 2 { problems.append("\(name): headline under the dealer's cards") }
                for i in g.betSpots.indices {
                    let anchor = g.playerCardAnchor(forBetSpot: i)
                    if !g.contains(anchor, inset: g.railWidth) { problems.append("\(name): hand \(i) off the cloth") }
                    let area = g.handArea(forBetSpot: i)
                    if area.width < card.width * 1.2 || area.height < card.height { problems.append("\(name): area \(i) small") }
                    if let insurance = g.insuranceSpot(forBetSpot: i), !g.contains(insurance, inset: g.railWidth) {
                        problems.append("\(name): insurance \(i) off the cloth")
                    }
                }
            }
        }
        t.check("at every window size the player's cards have a band clear of every printed word \(problems.prefix(4))",
                problems.isEmpty)
        t.check("the rule line goes first when a window is short, and stays when there is room",
                droppedRule && keptRule)
    }

    // MARK: Layers on the cloth

    private static func tableLayers(_ t: TestReporter) {
        t.section("Layers on the cloth")
        let (table, window) = hostTable()
        defer { withExtendedLifetime(window) {} }
        t.check("a chip stack is drawn for a Retina screen from the start", ChipStackLayer().contentsScale >= 2
                    || (NSScreen.main?.backingScaleFactor ?? 2) < 2)
        let under = ChipStackLayer()
        under.setAmount(100, animated: false)
        let over = CALayer()
        table.addTableLayer(over, z: -5)
        table.addTableLayer(under, z: -10)
        table.sprite(id: 1, card: Card(.spades, .ace))
        table.place(1, at: CGPoint(x: 300, y: 300), z: 0, duration: 0)
        table.layoutSubtreeIfNeeded()
        let order = table.tableLayer.sublayers ?? []
        let indices = [under, over, table.existingSprite(1) as CALayer?].map { layer in
            order.firstIndex { $0 === layer } ?? -1
        }
        t.check("layers on the cloth go under the cards, in z order, in the layer array a snapshot walks \(indices)",
                indices[0] >= 0 && indices[0] < indices[1] && indices[1] < indices[2])
        t.check("and take the window's backing scale", under.contentsScale == (window.backingScaleFactor))
    }

    // MARK: New controls

    private static func newControls(_ t: TestReporter) {
        t.section("Badges, the chip rack and counted words")
        let (table, window) = hostTable()
        defer { withExtendedLifetime(window) {} }
        let point = CGPoint(x: 400, y: 300)
        let first = TableBadge.show("Bust", tone: .loss, in: table, at: point, anchor: .above, animated: false)
        let second = TableBadge.show("Soft 18", in: table, at: CGPoint(x: 600, y: 300), animated: false)
        t.check("any number of badges can be up on one table", TableBadge.badges(in: table).count == 2)
        t.check("a badge above a point stands clear of it, centred on it",
                first.frame.maxY <= point.y - 4 && abs(first.frame.midX - point.x) <= 1)
        t.check("and never takes the click meant for the card under it",
                first.hitTest(CGPoint(x: first.frame.midX, y: first.frame.midY)) == nil)
        let width = second.frame.width
        second.update(text: "Soft 18 / 8")
        t.check("updated, it grows round its new words and stays on its point",
                second.frame.width > width && abs(second.frame.midX - 600) <= 1)
        TableBadge.hideAll(in: table)
        t.check("and a new hand clears them all", TableBadge.badges(in: table).isEmpty && first.superview == nil)

        let rack = ChipRackView(denominations: [100, 5, 25])
        var picked: [Int] = []
        rack.onPick = { picked.append($0) }
        rack.available = 30
        rack.pick(100)
        rack.pick(25)
        t.check("a chip rack offers its chips smallest first", rack.denominations == [5, 25, 100])
        t.check("and a chip worth more than the player has does nothing", picked == [25] && !rack.isChipEnabled(100))
        rack.isEnabled = false
        rack.pick(5)
        t.check("a rack switched off between hands takes no bets", picked == [25])
        t.check("it is as tall as the bar is told to keep", rack.intrinsicContentSize.height == ChipRackView.height)

        for width in stride(from: 300, through: 460, by: 40) {
            _ = LibraryArtwork.image(for: .solitaire, size: CGSize(width: width, height: width * 5 / 8), scale: 1)
        }
        t.check("the library keeps one cover per game, not one per window size it passed through",
                LibraryArtwork.cachedCount <= GameID.allCases.count)

        let program = "/Applications/Tabletop.app/Contents/MacOS/Tabletop"
        let refused = [["--selftests"], ["--shots", "x.png"], ["--help2"], ["selftest"], ["--demo", "--kit"]]
        let allowed = [[], ["--demo"], ["-psn_0_12345"], ["-NSDocumentRevisionsDebugMode", "YES"],
                       ["--shot", "poker", "x.png", "--seed", "4"], ["--selftest", "kit"]]
        t.check("a mistyped harness flag is refused before the app can launch",
                refused.allSatisfy { tabletopStrayArgument(in: [program] + $0) != nil })
        t.check("while the app's own launch arguments and every harness mode's options pass",
                allowed.allSatisfy { tabletopStrayArgument(in: [program] + $0) == nil })

        t.check("one move, twenty-four moves",
                Plural.format(1, one: "%d move", other: "%d moves") == "1 move"
                    && Plural.format(24, one: "%d move", other: "%d moves") == "24 moves"
                    && Plural.format(0, one: "%d move", other: "%d moves") == "0 moves")
    }
}
