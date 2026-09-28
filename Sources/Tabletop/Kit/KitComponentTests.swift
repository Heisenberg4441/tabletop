//
//  KitComponentTests.swift
//  Checks for the design system and the card-table kit — the parts four games
//  are built on at once, by people who cannot change them. A regression here
//  is a regression in every game, so the checks go for the promises the kit
//  makes in its comments: that a breakdown adds up and is minimal, that a fan
//  is symmetric and stays where it is put, that a click lands on the card
//  that is really on top even when it is turned, that a cancelled step never
//  runs, that an id can be reused.
//

import AppKit

@MainActor
extension KitTests {

    static func runComponents(_ t: TestReporter) {
        design(t)
        chips(t)
        layout(t)
        scheduler(t)
        sprites(t)
        hitTesting(t)
        controls(t)
        seats(t)
        tolerantPreferences(t)
        runRegressions(t)
    }

    // MARK: Design

    private static func design(_ t: TestReporter) {
        t.section("Design tokens")
        let rect = CGRect(x: 10, y: 20, width: 200, height: 120)
        let box = ContinuousShape.roundedRect(rect, radius: 24).boundingBoxOfPath
        t.check("a continuous rounded rect fills exactly its rect",
                abs(box.minX - rect.minX) < 0.5 && abs(box.maxX - rect.maxX) < 0.5
                    && abs(box.minY - rect.minY) < 0.5 && abs(box.maxY - rect.maxY) < 0.5)
        let capsule = ContinuousShape.roundedRect(CGRect(x: 0, y: 0, width: 100, height: 30), radius: 40)
        t.check("an oversized radius makes a capsule, not a tangle",
                capsule.contains(CGPoint(x: 50, y: 15)) && !capsule.contains(CGPoint(x: 1, y: 1)))
        let springs = [Motion.Spring.snappy, .smooth, .gentle]
        t.check("every spring is critically damped — it settles without wobbling",
                springs.allSatisfy { abs($0.damping - 2 * $0.stiffness.squareRoot()) < 0.001 })
        let animation = Motion.spring("opacity", from: 0, to: 1, spring: .smooth)
        t.check("and lasts exactly as long as it takes to settle",
                animation.duration > 0.1 && abs(animation.duration - animation.settlingDuration) < 0.001)
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        t.check("motion can be switched off for a test", !Motion.isEnabled)
        TabletopEnvironment.animationsOverride = saved
        t.check("numbers that change use tabular digits",
                Typography.number(14).fontDescriptor.fontAttributes[.featureSettings] != nil)
        t.check("a label is given room for its whole text",
                Typography.fittingWidth(Typography.label("Blinds 10/20")) > Typography.label("Blinds 10/20").intrinsicContentSize.width)
    }

    // MARK: Chips

    private static func chips(_ t: TestReporter) {
        t.section("Chips")
        var wrong: [Int] = []
        for amount in 0...6_000 where Chips.total(Chips.breakdown(amount)) != amount { wrong.append(amount) }
        var rng = DeterministicRNG(seed: 5)
        for _ in 0..<500 {
            let amount = rng.next(upperBound: 2_000_000)
            if Chips.total(Chips.breakdown(amount)) != amount { wrong.append(amount) }
        }
        t.check("every breakdown adds up to the amount exactly \(wrong.prefix(3))", wrong.isEmpty)

        // The fewest chips, against an exhaustive search.
        let limit = 3_000
        var fewest = [Int](repeating: Int.max, count: limit + 1)
        fewest[0] = 0
        for amount in 1...limit {
            for d in Chips.denominations where d <= amount && fewest[amount - d] != Int.max {
                fewest[amount] = min(fewest[amount], fewest[amount - d] + 1)
            }
        }
        let greedyWorse = (1...limit).filter { amount in
            Chips.breakdown(amount).reduce(0) { $0 + $1.count } != fewest[amount]
        }
        t.check("and uses the fewest chips possible \(greedyWorse.prefix(3))", greedyWorse.isEmpty)
        let sample = Chips.breakdown(12_340)
        t.check("biggest chips first, each denomination once",
                sample.map(\.denomination) == sample.map(\.denomination).sorted(by: >)
                    && Set(sample.map(\.denomination)).count == sample.count)
        t.check("nothing, or less, is no chips", Chips.breakdown(0).isEmpty && Chips.breakdown(-40).isEmpty)
        t.check("a signed change uses a true minus", Chips.formatChange(-75).hasPrefix("\u{2212}")
                    && Chips.formatChange(240).hasPrefix("+"))
        t.check("thousands are grouped", Chips.format(1_250) != "1250")
        t.check("big chips read as thousands", Chips.faceLabel(5_000).contains("5") && Chips.faceLabel(25) == "25")

        let stacks = ChipStackLayer.stacks(for: 12_340, maximumPerStack: 3, maximumStacks: 10)
        t.check("a stack never goes higher than asked", stacks.allSatisfy { $0.count <= 3 && !$0.isEmpty })
        t.check("and within the limits every chip is stacked",
                stacks.flatMap { $0 }.reduce(0, +) == 12_340)
        t.check("a crowded amount is capped at the stack limit",
                ChipStackLayer.stacks(for: 99_999, maximumPerStack: 2, maximumStacks: 4).count == 4)

        let layer = ChipStackLayer()
        layer.contentsScale = 2
        layer.setAmount(1_485, animated: false)
        t.check("a stack layer draws itself and sizes itself round the chips",
                layer.contents != nil && layer.bounds.width > layer.chipDiameter && layer.bounds.height > layer.chipDiameter)
        let spot = CGPoint(x: 300, y: 200)
        layer.position = spot
        layer.setAmount(40, animated: false)
        t.check("and stays standing on its spot when the amount changes", layer.position == spot)
        let image = ChipRenderer.chipImage(25, diameter: 40, scale: 2)
        t.check("a single chip renders at the size asked for", image?.width == Int((40 * 1.3 * 2).rounded(.up)))
        var landed = false
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        ChipFlight.fly(amount: 300, from: .zero, to: spot, in: CALayer()) { landed = true }
        TabletopEnvironment.animationsOverride = saved
        t.check("with motion off, chips arrive at once", landed)
    }

    // MARK: Layout

    private static func layout(_ t: TestReporter) {
        t.section("Table layout")
        let size = CGSize(width: 80, height: 114)
        let anchor = CGPoint(x: 600, y: 650)
        var symmetric = true
        for count in 1...14 {
            let fan = TableLayout.fan(count: count, anchor: anchor, cardSize: size)
            for i in 0..<count {
                let a = fan[i], b = fan[count - 1 - i]
                if abs((a.position.x - anchor.x) + (b.position.x - anchor.x)) > 0.01
                    || abs(a.position.y - b.position.y) > 0.01 || abs(a.rotation + b.rotation) > 0.0001 {
                    symmetric = false
                }
            }
        }
        t.check("a fan is symmetric about its anchor, one card to fourteen", symmetric)
        let seven = TableLayout.fan(count: 7, anchor: anchor, cardSize: size, baseZ: 10)
        t.check("its middle card sits on the anchor, upright", seven[3].position == anchor && seven[3].rotation == 0)
        t.check("left to right, lowest to highest", seven.map(\.z) == Array(10...16))
        t.check("and its ends droop, the way a hand is held",
                seven[0].position.y > anchor.y && seven[0].rotation < 0 && seven[6].rotation > 0)

        let view = CGRect(x: 0, y: 0, width: 960, height: 640)
        var escaped: [Int] = []
        for count in 1...24 {
            let fan = TableLayout.fan(count: count, anchor: CGPoint(x: view.midX, y: view.maxY - size.height * 0.95),
                                      cardSize: size, maxWidth: view.width * 0.8)
            let union = TableLayout.bounds(of: fan, cardSize: size)
            if !view.contains(union) || union.width > view.width * 0.8 + size.width * 0.35 { escaped.append(count) }
        }
        t.check("a squeezed hand of up to 24 stays on a 960-point table \(escaped)", escaped.isEmpty)

        let top = TableLayout.fan(count: 5, anchor: CGPoint(x: 400, y: 100), cardSize: size, side: .top, style: .compact)
        t.check("an opponent across the table holds the hand turned round", abs(top[2].rotation - .pi) < 0.0001)
        let left = TableLayout.fan(count: 5, anchor: CGPoint(x: 100, y: 300), cardSize: size, side: .left, style: .compact)
        t.check("a hand at the left points into the table",
                abs(left[2].rotation - .pi / 2) < 0.0001 && left.map(\.position.x).allSatisfy { abs($0 - left[2].position.x) < size.height })
        let small = TableLayout.fan(count: 3, anchor: anchor, cardSize: size, scale: 0.6)
        t.check("a scaled hand carries its scale to every card", small.allSatisfy { $0.scale == 0.6 })

        let row = TableLayout.row(count: 5, center: CGPoint(x: 500, y: 300), cardSize: size)
        t.check("a row is centred and evenly spaced",
                abs((row[0].position.x + row[4].position.x) / 2 - 500) < 1
                    && abs((row[1].position.x - row[0].position.x) - (row[4].position.x - row[3].position.x)) < 1)
        let deck = TableLayout.deck(count: 36, center: CGPoint(x: 100, y: 100), cardSize: size, visibleThickness: 8)
        t.check("a deck's top card is on its centre and only its top few show",
                deck.last?.position == CGPoint(x: 100, y: 100) && deck.filter { !$0.isHidden }.count == 9)
        let trump = TableLayout.trump(underDeckAt: CGPoint(x: 100, y: 100), cardSize: size)
        t.check("the trump lies across under the deck and sticks out",
                abs(trump.rotation - .pi / 2) < 0.0001 && trump.position.x > 100 + size.width * 0.2 && trump.z < deck[0].z)
        let pileA = TableLayout.discardPile(count: 9, center: .zero, cardSize: size, seed: 4)
        let pileB = TableLayout.discardPile(count: 9, center: .zero, cardSize: size, seed: 4)
        let pileC = TableLayout.discardPile(count: 9, center: .zero, cardSize: size, seed: 5)
        t.check("a discard pile is the same pile every time it is laid out", pileA == pileB && pileA != pileC)
        t.check("and every card in it is thrown only a little askew", pileA.allSatisfy { abs($0.rotation) <= 0.3 })
        let pairs = TableLayout.battlePairs(count: 6, center: CGPoint(x: 480, y: 320), cardSize: size, perRow: 3)
        t.check("a beating card lies over the card it beats", pairs.allSatisfy { $0.defence.z > $0.attack.z })
        t.check("six fights make two rows of three", Set(pairs.map { Int($0.attack.position.y) }).count == 2)

        let policy = CardSizePolicy.poker
        let card = policy.cardSize(for: CGSize(width: 1200, height: 800))
        t.check("a card size keeps the deck's proportions",
                abs(card.width / card.height - CardSizePolicy.aspect) < 0.01)
        t.check("and stays within its limits",
                policy.cardSize(for: CGSize(width: 200, height: 100)).width == policy.minimumWidth
                    && policy.cardSize(for: CGSize(width: 9000, height: 9000)).width == policy.maximumWidth)

        let oval = TableSurface.geometry(for: .oval, in: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                         topInset: 32, bottomReserve: 90)
        t.check("the oval stays clear of the strip and the bar",
                oval.tableRect.minY >= 32 && oval.tableRect.maxY <= 800 - 90)
        let seat = oval.railPoint(angle: .pi / 2, inset: 0)
        t.check("a seat at the bottom of the rail is on the rail",
                abs(seat.x - oval.center.x) < 1 && abs(seat.y - oval.tableRect.maxY) < 1.5)
        let moon = TableSurface.geometry(for: .halfMoon(HalfMoonPrint(betSpots: 3)),
                                         in: CGRect(x: 0, y: 0, width: 1200, height: 800), topInset: 32, bottomReserve: 90)
        t.check("the half-moon's betting circles are on the cloth, left to right",
                moon.betSpots.count == 3 && moon.betSpots.allSatisfy { moon.contains($0, inset: moon.betSpotRadius) }
                    && moon.betSpots[0].x < moon.betSpots[1].x)
        t.check("seats go round from the bottom", abs(TableGeometry.seatAngles(count: 6)[0] - .pi / 2) < 0.0001)
    }

    // MARK: Scheduler

    private static func scheduler(_ t: TestReporter) {
        t.section("Table scheduler")
        var log: [String] = []
        let immediate = TableScheduler(immediate: true)
        immediate.after(0.2) { log.append("a") }
        immediate.after(0.1) { log.append("b") }
        t.check("in immediate mode a block runs the moment it is scheduled", log == ["a", "b"])

        log.removeAll()
        let virtual = TableScheduler(immediate: false)
        virtual.after(0.30) { log.append("late") }
        virtual.after(0.10) {
            log.append("early")
            virtual.after(0.05) { log.append("nested") }
        }
        let cancelled = virtual.after(0.12) { log.append("cancelled") }
        virtual.cancel(cancelled)
        virtual.runPendingImmediately()
        t.check("drained, blocks run in the order they were due, nested ones included \(log)",
                log == ["early", "nested", "late"])
        t.check("a cancelled block never runs, and nothing is left", !log.contains("cancelled") && virtual.pendingCount == 0)

        log.removeAll()
        let live = TableScheduler(immediate: false)
        live.after(0.02) { log.append("ran") }
        live.after(0.02) { log.append("also") }
        live.cancelAll()
        spin(0.08)
        t.check("cancelAll throws every pending step away", log.isEmpty && live.pendingCount == 0)
        live.after(0.02) { log.append("ran") }
        live.suspend()
        spin(0.08)
        t.check("a suspended scheduler holds its steps", log.isEmpty && live.pendingCount == 1 && live.isSuspended)
        live.resume()
        spin(0.10)
        t.check("and resuming runs them", log == ["ran"] && live.pendingCount == 0)
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Sprites

    /// A table in a window that is never shown, laid out at a fixed size.
    private static func makeTable(_ shape: TableShape = .rectangular) -> (CardTableView, NSWindow) {
        let size = CGSize(width: 1000, height: 700)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let table = CardTableView(shape: shape)
        table.frame = CGRect(origin: .zero, size: size)
        window.contentView = table
        table.layoutSubtreeIfNeeded()
        return (table, window)
    }

    private static func sprites(_ t: TestReporter) {
        t.section("Card table sprites")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = saved }
        let (table, window) = makeTable()
        defer { withExtendedLifetime(window) {} }

        let first = table.sprite(id: 5, card: Card(.spades, .ace))
        let same = table.sprite(id: 5, card: Card(.hearts, .king))
        t.check("asking again for an id gives the same sprite, now showing the new card",
                first === same && same.card == Card(.hearts, .king))
        table.remove(5)
        t.check("a removed id is gone at once", table.existingSprite(5) == nil && !table.spriteIDs.contains(5))
        let reused = table.sprite(id: 5, card: Card(.diamonds, .queen))
        t.check("and can be used again for a new card", reused !== first && reused.card == Card(.diamonds, .queen))

        var landed = false
        let pose = CardPose(position: CGPoint(x: 300, y: 250), rotation: 0.4, z: 7)
        table.place(5, pose: pose, faceUp: true, duration: 0.3) { landed = true }
        t.check("with motion off a move lands at once and says so", landed)
        t.check("and the card is where it was sent, turned and face up",
                reused.position == pose.position && abs(reused.restingRotation - 0.4) < 0.0001 && reused.isFaceUp
                    && reused.zPosition == 7 && !reused.isHidden)
        t.check("a card at rest has an affine transform, so a snapshot can draw it",
                CATransform3DIsAffine(reused.transform))
        reused.setPickedUp(true, duration: 0)
        reused.setPickedUp(false, duration: 0)
        let back = reused.value(forKeyPath: "transform.rotation.z") as? NSNumber
        t.check("picking a turned card up and putting it down keeps its turn",
                abs(CGFloat(back?.doubleValue ?? 0) - 0.4) < 0.001)
        var missing = false
        table.place(999, at: .zero) { missing = true }
        t.check("placing a sprite that does not exist still calls back", missing)
        table.flip(5, faceUp: false, duration: 0)
        t.check("a flip turns it over where it lies", !reused.isFaceUp && reused.position == pose.position)
        table.place(5, pose: CardPose(position: CGPoint(x: 10, y: 10), isHidden: true), duration: 0)
        t.check("a buried card is hidden once it lands", reused.isHidden)
        table.removeAllSprites()
        t.check("and everything can be cleared", table.spriteIDs.isEmpty)
    }

    // MARK: Hit testing

    private static func hitTesting(_ t: TestReporter) {
        t.section("Card table hit testing")
        let saved = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = false
        defer { TabletopEnvironment.animationsOverride = saved }
        let (table, window) = makeTable()
        defer { withExtendedLifetime(window) {} }
        let size = table.cardSize
        let center = CGPoint(x: 500, y: 350)

        table.sprite(id: 1, card: Card(.clubs, .two))
        table.place(1, at: center, rotation: .pi / 2, z: 1, duration: 0)
        // Turned a quarter, the card is wide rather than tall.
        let alongWide = CGPoint(x: center.x + size.height * 0.45, y: center.y)
        let alongTall = CGPoint(x: center.x, y: center.y + size.height * 0.45)
        t.check("a click on the turned card's long side finds it", table.sprite(at: alongWide) == 1)
        t.check("and a click where it would have been upright does not", table.sprite(at: alongTall) == nil)

        table.sprite(id: 2, card: Card(.clubs, .three))
        table.place(2, at: CGPoint(x: center.x + 10, y: center.y), z: 5, duration: 0)
        t.check("where two cards overlap, the higher one is hit", table.sprite(at: center) == 2)
        table.place(1, at: center, rotation: .pi / 2, z: 9, duration: 0)
        t.check("restack them and the other one is", table.sprite(at: center) == 1)
        table.place(1, pose: CardPose(position: center, z: 9, isHidden: true), duration: 0)
        t.check("a hidden card is never hit", table.sprite(at: center) == 2)
        table.place(2, pose: CardPose(position: center, z: 5, scale: 0.5), duration: 0)
        let nearEdge = CGPoint(x: center.x + size.width * 0.4, y: center.y)
        t.check("a card drawn small is hit only where it is drawn", table.sprite(at: nearEdge) == nil
                    && table.sprite(at: center) == 2)
        t.check("bare cloth is nothing", table.sprite(at: CGPoint(x: 5, y: 5)) == nil)
    }

    // MARK: Controls

    private static func controls(_ t: TestReporter) {
        t.section("Chrome controls")
        let bet = BetControl(minimum: 20, maximum: 1_237, step: 25, value: 20)
        t.check("a bet snaps to whole chips", bet.snap(61) == 50 && bet.snap(63) == 75)
        t.check("and to its limits, the odd maximum included",
                bet.snap(5) == 20 && bet.snap(5_000) == 1_237 && bet.snap(1_236) == 1_225 && bet.snap(1_237) == 1_237)
        var reported: [Int] = []
        bet.onChange = { reported.append($0) }
        bet.step(by: 1)
        t.check("a step up from an odd amount lands on the next whole chip", bet.value == 25)
        bet.step(by: 10)
        bet.value = 1_237
        bet.step(by: -1)
        t.check("a step down from the odd maximum lands on the whole chip below it", bet.value == 1_225)
        t.check("the player's changes are reported, a set value is not", reported == [25, 275, 1_225])

        let choice = SegmentedChoice(options: ["1", "2", "3"], selectedIndex: 7)
        t.check("a choice clamps an out-of-range selection", choice.selectedIndex == 2)
        choice.select(offset: 5)
        t.check("and never runs off the end", choice.selectedIndex == 2)

        let button = CapsuleButton(title: "Fold")
        button.keyEquivalent = "f"
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: 3)
        }
        t.check("a button answers its bare key, shifted or not",
                key("f", []).map(button.matchesKeyEquivalent) == true && key("F", .shift).map(button.matchesKeyEquivalent) == true)
        t.check("but not the same key with ⌘, which is the menu's", key("f", .command).map(button.matchesKeyEquivalent) == false)
        var pressed = 0
        button.handler = { pressed += 1 }
        button.activate(nil)
        button.isEnabled = false
        button.activate(nil)
        t.check("a disabled button does nothing", pressed == 1)
        t.check("and every button reaches itself through the responder chain",
                button.target === button && button.action == #selector(CapsuleButton.activate(_:)))

        let bar = ActionBar()
        var fired = ""
        bar.setActions([ChromeAction(id: "hit", title: "Hit") { fired = "old" }], animated: false)
        let hit = bar.button(for: "hit")
        bar.setActions([ChromeAction(id: "hit", title: "Hit") { fired = "new" }], animated: false)
        hit?.activate(nil)
        t.check("setting the same actions again keeps the buttons and takes the new handlers",
                bar.button(for: "hit") === hit && fired == "new")
        bar.setActions([ChromeAction(id: "hit", title: "Hit Me", isEnabled: false) {}], animated: false)
        t.check("the same ids update in place: new title, new state, same button",
                bar.button(for: "hit") === hit && hit?.title == "Hit Me" && hit?.isEnabled == false)
        bar.setEnabled(true, for: "hit")
        t.check("a bar's button can be switched on and off by id", bar.button(for: "hit")?.isEnabled == true)
        bar.setActions([ChromeAction(id: "stand", title: "Stand") {}], animated: false)
        t.check("new actions replace the old", bar.button(for: "hit") == nil && bar.button(for: "stand") != nil)

        let card = OptionsCard(title: "New Game", rows: [OptionsCard.Row(id: "n", title: "Opponents", options: ["1", "2"], selectedIndex: 1)])
        t.check("an options card hands its choices back by row", card.selections == ["n": 1] && card.selection(for: "x") == nil)

        var posts = 0
        let observer = NotificationCenter.default.addObserver(forName: TopBarStatus.didChange, object: nil, queue: nil) { _ in
            posts += 1
        }
        let items = [StatusPillItem(id: "t", text: "Trumps ♥", isEmphasized: true)]
        TopBarStatus.set(items, for: .durak)
        TopBarStatus.set(items, for: .durak)
        NotificationCenter.default.removeObserver(observer)
        t.check("posting the same pills twice tells the window once", posts == 1 && TopBarStatus.items(for: .durak) == items)
        TopBarStatus.set([], for: .durak)

        // The drawn glass has to be something a screenshot can show.
        let panel = GlassPanel(cornerRadius: 20, rendering: .drawn)
        panel.frame = CGRect(x: 0, y: 0, width: 80, height: 40)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        let image = LayerSnapshot.image(of: panel, size: panel.frame.size, scale: 1)
        let middle = image.flatMap { pixel(in: $0, x: 40, y: 20) }
        t.check("drawn glass is visible in a snapshot, and not a white slab",
                middle.map { $0.red < 200 && $0.red + $0.green + $0.blue > 0 } ?? false)
    }

    // MARK: Seats

    private static func seats(_ t: TestReporter) {
        t.section("Seats")
        // Frozen: a bot called Anna is the same colour on every Mac for ever.
        t.check("a name's colour is the same on every launch", AvatarRenderer.stableHash("Anna") == 0x1469_cb8a_cbe9_449b)
        t.check("and the hash is FNV-1a, frozen", AvatarRenderer.stableHash("") == 0xcbf2_9ce4_8422_2325)
        t.check("initials come from up to two words",
                AvatarRenderer.initials("Anna") == "A" && AvatarRenderer.initials("anna karenina") == "AK"
                    && AvatarRenderer.initials("Jean-Luc Picard") == "JL")
        let names = BotRoster.pick(5, seed: 9)
        t.check("bots are seated deterministically, never twice",
                names == BotRoster.pick(5, seed: 9) && Set(names).count == 5)
        t.check("no two bots share an initial", Set(BotRoster.names.map { $0.prefix(1) }).count == BotRoster.names.count)
        let seat = SeatView(name: "Anna", detail: "1,240")
        seat.state = .folded
        t.check("a folded seat is dimmed", seat.alphaValue < 0.6)
        seat.state = .active
        seat.isThinking = true
        t.check("a thinking seat out of any window does not spin", seat.window == nil)
        seat.state = .winner
        t.check("a winner is at full strength", seat.alphaValue == 1)
    }

    // MARK: Table preferences, tolerated

    private static func tolerantPreferences(_ t: TestReporter) {
        t.section("Table preferences from other builds")
        let future = #"{"table":"purple","backColor":"plum","backStyle":7,"fourColorDeck":"yes","soundEnabled":false}"#
        let decoded = try? JSONDecoder().decode(TablePreferences.self, from: Data(future.utf8))
        t.check("a file from a later build still reads", decoded != nil)
        t.check("an unknown cloth falls back on its own, keeping the rest",
                decoded?.table == .green && decoded?.backColor == .plum)
        t.check("so does a value of the wrong type", decoded?.backStyle == .lattice && decoded?.fourColorDeck == false)
        t.check("an empty file is the defaults", (try? JSONDecoder().decode(TablePreferences.self, from: Data("{}".utf8))) == TablePreferences())
    }
}
