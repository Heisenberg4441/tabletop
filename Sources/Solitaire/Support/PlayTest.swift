//
//  PlayTest.swift
//  `Solitaire --playtest [games]` plays through the real view, off-screen.
//
//  The engine is fuzzed thoroughly by `--selftest`, but the engine is not where
//  the interesting bugs live. Hit testing, the click-to-move path, the layout
//  diff and the layer bookkeeping are only exercised by a pointer, and a
//  pointer is exactly what a test cannot easily hold. So this drives the real
//  `BoardView` — same layout, same hit testing, same `perform` — by working out
//  where a card is on screen and clicking it there.
//

import AppKit

enum PlayTest {

    static func run(games: Int) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Sound.isEnabled = false

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok   \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }

        // A range of window shapes, including the advertised minimum, because
        // fan compression only misbehaves when it is under pressure.
        let sizes = [
            CGSize(width: 720, height: 526),
            CGSize(width: 1000, height: 714),
            CGSize(width: 1600, height: 1000),
            CGSize(width: 2400, height: 1400),
        ]

        // First, while the main queue is still empty: this is the only check
        // here that cares what time it is.
        let burst = burstChecks(size: sizes[1])

        var hitMismatches = 0
        var inconsistencies = 0
        var clicksPerformed = 0
        var gamesWon = 0
        var offBoard = 0
        var movesWithoutAnimation = 0
        var movesWithoutBurst = 0
        var mostSparkLayers = 0
        var rng = DeterministicRNG(seed: 0xB0A2D)

        for index in 0..<games {
            let size = sizes[index % sizes.count]
            var options = GameOptions()
            options.drawCount = (index % 2 == 0) ? 1 : 3
            let game = Game(dealNumber: index + 1, options: options)

            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            let board = BoardView(game: game, theme: Theme())
            board.frame = frame
            window.contentView = board
            board.layoutSubtreeIfNeeded()

            for _ in 0..<400 {
                guard !game.isWon else { break }
                let layout = board.boardLayout
                let placements = layout.placements(for: game.state)

                // Everything on the table has to stay on the table. A card
                // pushed off the bottom by a long column is unreachable, which
                // is the failure mode fan compression exists to prevent.
                for placement in placements where placement.frame.maxY > board.bounds.maxY + 1 {
                    offBoard += 1
                    break
                }

                // The top card of every column must be the one a click in its
                // middle lands on, not the card behind it.
                for placement in placements where placement.pile.kind == .tableau {
                    let column = game.state.tableau[placement.pile.index]
                    guard placement.indexInPile == column.count - 1,
                          placement.indexInPile >= column.down.count else { continue }
                    let point = CGPoint(x: placement.frame.midX, y: placement.frame.midY)
                    if layout.target(at: point, state: game.state, placements: placements)
                        != .tableauCard(column: placement.pile.index, depthFromTop: 0) {
                        hitMismatches += 1
                    }
                }

                // Click something. Prefer a card that has somewhere to go, so
                // the test actually plays rather than hammering the stock.
                var targets: [ClickTarget] = [.stock]
                if game.state.waste.last != nil { targets.append(.waste) }
                for column in 0..<7 {
                    for depth in 0..<game.state.tableau[column].up.count {
                        targets.append(.tableauCard(column: column, depthFromTop: depth))
                    }
                }
                let playable = targets.filter { game.autoMove(for: $0) != nil }
                let pool = playable.isEmpty ? targets : playable
                let intended = pool[rng.next(upperBound: pool.count)]

                // Go in through a point and the hit test rather than calling
                // `autoMove` directly, so the coordinate maths is on trial too.
                guard let point = pointFor(intended, layout: layout, placements: placements) else { continue }
                let resolved = layout.target(at: point, state: game.state, placements: placements)
                if resolved != intended { hitMismatches += 1 }
                if let move = game.autoMove(for: resolved) {
                    _ = board.perform(move)
                    clicksPerformed += 1
                    // Every move puts at least one card somewhere else, so at
                    // least one layer has to come out of it with a position
                    // animation attached. This is worth a check of its own
                    // because the failure is invisible from the source: the
                    // board still ends up in exactly the right state, the cards
                    // just teleport into it.
                    if board.animationsEnabled, !glidingCards(in: board) {
                        movesWithoutAnimation += 1
                    }
                    // And every move throws a burst of sparks off the card as
                    // it lands. Same reasoning as above — the board is correct
                    // either way — plus one thing this file is the only place
                    // able to check: the bursts are pooled, and there is no run
                    // loop here to deliver the cleanup they schedule. If the
                    // sweep on the way in ever stops working, hundreds of moves
                    // in a row is where it shows.
                    let sparks = sparkLayers(in: board).count
                    if board.animationsEnabled, sparks < SparkBurstPool.Scale.puff.sparkCount + 1 {
                        movesWithoutBurst += 1
                    }
                    mostSparkLayers = max(mostSparkLayers, sparks)
                }
                if !game.state.isConsistent { inconsistencies += 1; break }

                if rng.next(upperBound: 22) == 0 { board.undo() }
                if rng.next(upperBound: 40) == 0 {
                    // Resize mid-game: the layout, the card bitmaps and every
                    // layer frame all have to survive it.
                    board.frame = NSRect(origin: .zero, size: sizes[rng.next(upperBound: sizes.count)])
                    board.layoutSubtreeIfNeeded()
                }
            }
            if game.isWon { gamesWon += 1 }
            if !game.state.isConsistent { inconsistencies += 1 }
        }

        let drags = dragChecks(sizes: sizes)
        let rot = brainrotChecks(size: sizes[1])

        print("Playing \(games) games through the real board view")
        check("a click always lands on the card under it (\(hitMismatches) misses)", hitMismatches == 0)
        check("no card is pushed off the bottom of the table (\(offBoard))", offBoard == 0)
        check("the board never lost a card (\(inconsistencies))", inconsistencies == 0)
        check("clicks actually played (\(clicksPerformed))", clicksPerformed > games * 15)
        check("every move animates the cards it moved (\(movesWithoutAnimation) did not)",
              movesWithoutAnimation == 0)
        check("every move bursts where the card lands (\(movesWithoutBurst) did not)",
              movesWithoutBurst == 0)
        check("a burst is built at once and held back (\(burst.held)/\(burst.layers) layers)",
              burst.layers == SparkBurstPool.Scale.puff.sparkCount + 1 && burst.held == burst.layers)
        check("and its sparks fly when the card lands (\(burst.visible) lit, \(burst.travelled) moving)",
              burst.visible >= SparkBurstPool.Scale.puff.sparkCount
                  && burst.travelled >= SparkBurstPool.Scale.puff.sparkCount)
        let burstCeiling = SparkBurstPool.maximum * (SparkBurstPool.Scale.burst.sparkCount + 1)
        check("spark layers stay pooled (\(mostSparkLayers) at once, ceiling \(burstCeiling))",
              mostSparkLayers <= burstCeiling)
        check("brainrot mode played (\(rot.moves) moves)", rot.moves > 200)
        check("every brainrot move builds its effects (\(rot.quiet) built nothing)", rot.quiet == 0)
        check("every brainrot move kicks the table (\(rot.noShake) did not)", rot.noShake == 0)
        check("brainrot layers stay pooled (\(rot.mostLayers) at once, ceiling \(BrainrotShow.layerCeiling))",
              rot.mostLayers <= BrainrotShow.layerCeiling)
        check("brainrot never corrupts the board (\(rot.inconsistent))", rot.inconsistent == 0)
        check("drags actually ran (\(drags.attempted))", drags.attempted >= 6)
        check("a drag applies its move (\(drags.notApplied) did not)", drags.notApplied == 0)
        check("held cards are lifted off the pile (\(drags.notLifted) were not)", drags.notLifted == 0)
        check("the drop target lights up (\(drags.noGlow) did not)", drags.noGlow == 0)
        check("dropped cards are set back down (\(drags.notSettled) were not)", drags.notSettled == 0)
        print("  info won \(gamesWon)/\(games) clicking more or less at random")

        print("")
        print(failures == 0 ? "Play-test passed." : "\(failures) play-test check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }

    struct DragResults {
        var attempted = 0
        var notApplied = 0
        var notLifted = 0
        var noGlow = 0
        var notSettled = 0
    }

    /// Drags a card from one column to another with synthetic events.
    ///
    /// The loop above only ever clicks, so nothing there touches `beginDrag`,
    /// the drop-target search, or the two pieces of feedback that only exist
    /// while the mouse is down — the card growing into the player's hand and
    /// the outline over the pile it would land on. Both are invisible to every
    /// other check in this file: the board reaches exactly the right state
    /// whether or not they happen.
    static func dragChecks(sizes: [CGSize]) -> DragResults {
        var results = DragResults()

        for deal in 1...12 {
            let size = sizes[deal % sizes.count]
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            let game = Game(dealNumber: deal, options: GameOptions())
            let board = BoardView(game: game, theme: Theme())
            board.frame = frame
            window.contentView = board
            board.layoutSubtreeIfNeeded()

            // Turn cards up until there is a tableau-to-tableau move to drag.
            var plan: (from: Int, to: Int, count: Int)?
            for _ in 0..<60 {
                plan = firstTableauDrag(in: game.state)
                if plan != nil { break }
                let move: Move = game.state.stock.isEmpty ? .recycle : .draw(count: 1)
                guard game.state.isLegal(move) else { break }
                _ = board.perform(move)
            }
            guard let plan else { continue }

            let placements = board.boardLayout.placements(for: game.state)
            let source = placements.filter { $0.pile == .tableau(plan.from) }
            guard let top = source.dropLast(plan.count - 1).last else { continue }
            let destination = board.boardLayout.frame(of: .tableau(plan.to))
            let landing = placements.last { $0.pile == .tableau(plan.to) }?.frame ?? destination

            let start = CGPoint(x: top.frame.midX, y: top.frame.midY)
            let end = CGPoint(x: landing.midX, y: landing.midY + top.frame.height * 0.4)
            let before = game.state

            results.attempted += 1
            board.mouseDown(with: event(at: start, in: board, window: window, type: .leftMouseDown))
            // Two steps: the first crosses the threshold that starts the drag,
            // the second lands it on the target.
            board.mouseDragged(with: event(at: CGPoint(x: start.x + 12, y: start.y + 12),
                                           in: board, window: window, type: .leftMouseDragged))
            board.mouseDragged(with: event(at: end, in: board, window: window, type: .leftMouseDragged))

            let lifted = liftedCards(in: board)
            if lifted.isEmpty { results.notLifted += 1 }
            if !dropGlowIsVisible(in: board) { results.noGlow += 1 }

            board.mouseUp(with: event(at: end, in: board, window: window, type: .leftMouseUp))

            if game.state == before { results.notApplied += 1 }
            // Only the cards that were actually in hand. Checking every layer
            // instead would trip over the card the drag uncovered: it is part
            // way through `flip`, which parks the layer edge-on until a
            // transaction completion puts it back — and there is no run loop
            // here to deliver one.
            if !liftedCards(in: board).isDisjoint(with: lifted) { results.notSettled += 1 }
        }
        return results
    }

    struct BrainrotResults {
        var moves = 0
        var quiet = 0
        var mostLayers = 0
        var noShake = 0
        var inconsistent = 0
    }

    /// Brainrot mode, played fast and hard.
    ///
    /// The mode itself is decoration and cannot make the board wrong — but it
    /// can bury it. Every move builds up to a hundred layers whose cleanup is
    /// scheduled on the main queue, and a queue that never runs is exactly the
    /// situation here, so this is where a broken sweep shows up as an unbounded
    /// pile of layers. The rest is a sanity check that the fireworks actually
    /// got built and that the table was kicked.
    static func brainrotChecks(size: CGSize) -> BrainrotResults {
        var results = BrainrotResults()
        var rng = DeterministicRNG(seed: 0xB2A1_4207)

        for deal in 1...4 {
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            let game = Game(dealNumber: deal, options: GameOptions())
            let board = BoardView(game: game, theme: Theme())
            board.brainrot = true
            board.frame = frame
            window.contentView = board
            board.layoutSubtreeIfNeeded()
            guard board.animationsEnabled else { return results }

            for _ in 0..<160 {
                let moves = game.state.allMoves()
                guard !moves.isEmpty else { break }
                guard board.perform(moves[rng.next(upperBound: moves.count)]) else { continue }
                results.moves += 1
                if board.brainrotLayerCount == 0 { results.quiet += 1 }
                if board.layer?.animation(forKey: "brainrotShake") == nil { results.noShake += 1 }
                results.mostLayers = max(results.mostLayers, board.brainrotLayerCount)
                if !game.state.isConsistent { results.inconsistent += 1; break }
            }
            // Turning the mode off has to take the whole circus with it.
            board.brainrot = false
            if board.brainrotLayerCount != 0 { results.quiet -= 1000 }
        }
        return results
    }

    struct BurstResults {
        var layers = 0
        var held = 0
        var visible = 0
        var travelled = 0
    }

    /// The one check in this file that needs the clock to run.
    ///
    /// A landing burst is built the instant the move is played, but every one
    /// of its animations is held back with `beginTime` so the sparks go off as
    /// the card arrives rather than as it sets off. Nothing else here can tell
    /// "held back" from "never runs": the layers are on the board either way
    /// with a model opacity of zero, and not even a screenshot would show the
    /// difference, because `render(in:)` draws model values. So this plays one
    /// move, lets the clock past the delay, and asks the compositor what it is
    /// actually drawing.
    static func burstChecks(size: CGSize) -> BurstResults {
        var results = BurstResults()
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let game = Game(dealNumber: 1, options: GameOptions())
        let board = BoardView(game: game, theme: Theme())
        board.frame = frame
        window.contentView = board
        board.layoutSubtreeIfNeeded()
        guard board.animationsEnabled else { return results }

        _ = board.perform(.draw(count: 1))
        let layers = sparkLayers(in: board)
        results.layers = layers.count

        let now = CACurrentMediaTime()
        for layer in layers {
            let animations = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
            if !animations.isEmpty, animations.allSatisfy({ $0.beginTime > now }) { results.held += 1 }
        }

        // Sampled over and over across the burst's whole life rather than once
        // in the middle of it, and judged on the brightest and furthest each
        // spark ever got. A single sample has to be taken at the right moment,
        // and the moment is not ours to choose: `run(until:)` also has to drain
        // whatever the main queue is holding, so a busy queue lands the sample
        // late — with the sparks nearly faded, which looks exactly like a burst
        // that never ran.
        var peakOpacity = [Float](repeating: 0, count: layers.count)
        var peakTravel = [CGFloat](repeating: 0, count: layers.count)
        for _ in 0..<24 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            for (i, layer) in layers.enumerated() {
                guard let shown = layer.presentation() else { continue }
                peakOpacity[i] = max(peakOpacity[i], shown.opacity)
                peakTravel[i] = max(peakTravel[i], hypot(shown.position.x - layer.position.x,
                                                         shown.position.y - layer.position.y))
            }
        }
        results.visible = peakOpacity.filter { $0 > 0.1 }.count
        // The sparks fly outward; the ring stays put and opens instead, which
        // is why one layer of every burst is expected never to move.
        results.travelled = peakTravel.filter { $0 > 0.5 }.count
        return results
    }

    /// A run the rules will let us move between two tableau columns.
    private static func firstTableauDrag(in state: GameState) -> (from: Int, to: Int, count: Int)? {
        for from in 0..<7 {
            for to in 0..<7 where to != from {
                for count in 1...max(1, state.tableau[from].up.count) {
                    let move = Move.tableauToTableau(from: from, to: to, count: count)
                    // Moving a whole column onto an empty one is legal and
                    // changes nothing worth dragging for.
                    if state.isLegal(move), !state.tableau[to].isEmpty {
                        return (from, to, count)
                    }
                }
            }
        }
        return nil
    }

    private static func event(at viewPoint: CGPoint, in board: BoardView,
                              window: NSWindow, type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: board.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    private static func cardLayers(in board: BoardView) -> [CardLayer] {
        (board.layer?.sublayers ?? []).compactMap { $0 as? CardLayer }
    }

    private static func scaleX(of layer: CALayer) -> CGFloat {
        CGFloat((layer.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 1)
    }

    /// The cards currently drawn larger than life, which is to say the ones in
    /// the player's hand.
    private static func liftedCards(in board: BoardView) -> Set<UInt8> {
        Set(cardLayers(in: board).filter { scaleX(of: $0) > 1.001 }.map(\.card.code))
    }

    private static func dropGlowIsVisible(in board: BoardView) -> Bool {
        (board.layer?.sublayers ?? []).contains {
            ($0 as? CAShapeLayer)?.path != nil && $0.opacity > 0.5
        }
    }

    /// The spark layers a landing burst leaves on the board. The burst's own
    /// `zPosition` is the marker: nothing else on the table sits at that
    /// height, and unlike the drop-target outline the sparks are plain layers
    /// with no path to recognise them by.
    private static func sparkLayers(in board: BoardView) -> [CALayer] {
        (board.layer?.sublayers ?? []).filter { $0.zPosition == SparkBurstPool.zPosition }
    }

    /// Whether any card on the board is currently in the middle of a move.
    private static func glidingCards(in board: BoardView) -> Bool {
        (board.layer?.sublayers ?? []).contains { ($0 as? CardLayer)?.isGliding == true }
    }

    /// Where on screen a player would click to hit `target`.
    private static func pointFor(_ target: ClickTarget, layout: BoardLayout,
                                 placements: [CardPlacement]) -> CGPoint? {
        func centre(_ pile: PileID) -> CGPoint {
            let frame = layout.frame(of: pile)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        switch target {
        case .stock:
            return centre(.stock)
        case .waste:
            guard let placement = placements.last(where: { $0.pile.kind == .waste }) else {
                return centre(.waste)
            }
            return CGPoint(x: placement.frame.midX, y: placement.frame.midY)
        case .foundation(let i):
            return centre(.foundation(i))
        case .emptyTableau(let i):
            return centre(.tableau(i))
        case .tableauCard(let column, let depth):
            let inColumn = placements.filter { $0.pile == .tableau(column) }
            guard depth < inColumn.count else { return nil }
            let placement = inColumn[inColumn.count - 1 - depth]
            // Aim just below the top edge: on a fanned card that sliver is the
            // only part the player can actually see.
            let y = depth == 0 ? placement.frame.midY : placement.frame.minY + 3
            return CGPoint(x: placement.frame.midX, y: y)
        case .nothing:
            return nil
        }
    }
}

// MARK: - Controls

extension PlayTest {

    /// `Solitaire --controls` checks that the buttons in the status bar are
    /// wired to something that will actually answer them.
    ///
    /// A button with a nil target relies on the responder chain to find its
    /// action, which means it can look perfectly correct in the source and do
    /// nothing at all at runtime. There is no way to see that by reading; the
    /// chain has to be walked.
    static func checkControls() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Sound.isEnabled = false

        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok   \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }

        let controller = GameWindowController(preferences: Preferences())
        guard let window = controller.window, let content = window.contentView else {
            print("  FAIL no window")
            return 1
        }
        window.layoutIfNeeded()

        var buttons: [NSButton] = []
        func collect(_ view: NSView) {
            if let button = view as? NSButton { buttons.append(button) }
            view.subviews.forEach(collect)
        }
        collect(content)
        check("the status bar has its buttons (\(buttons.count))", buttons.count >= 3)

        // Every button must have an action, and something in the chain that
        // window would send it to must implement it.
        for button in buttons {
            guard let action = button.action else {
                check("a button has no action at all", false)
                continue
            }
            let name = NSStringFromSelector(action)
            if let target = button.target {
                check("\(name) has a target that answers it", target.responds(to: action))
                continue
            }
            // Nil target: walk the chain the way AppKit would.
            var responder: NSResponder? = window.firstResponder ?? content
            var found: NSResponder?
            var hops = 0
            while let current = responder, hops < 24 {
                if current.responds(to: action) { found = current; break }
                responder = current.nextResponder
                hops += 1
            }
            if found == nil, let delegate = window.delegate as? NSResponder,
               delegate.responds(to: action) {
                found = delegate
            }
            check("\(name) reaches a responder that answers it"
                  + (found == nil ? "" : " (\(type(of: found!)))"), found != nil)
        }

        // The same trap applies to every menu item. Any action this controller
        // implements must actually arrive here, and not be intercepted on the
        // way by NSWindow, NSApplication or a view in between.
        NSApp.mainMenu = MainMenu.build(appName: "Solitaire")
        var checkedItems = 0
        var hijacked: [String] = []
        var orphaned: [String] = []

        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard let action = item.action else { continue }
                checkedItems += 1
                let name = NSStringFromSelector(action)
                // Only our own actions are interesting; the standard AppKit
                // ones are supposed to be handled elsewhere.
                guard GameWindowController.instancesRespond(to: action) else { continue }
                var responder: NSResponder? = window.firstResponder ?? content
                var found: NSResponder?
                var hops = 0
                while let current = responder, hops < 24 {
                    if current.responds(to: action) { found = current; break }
                    responder = current.nextResponder
                    hops += 1
                }
                switch found {
                case nil: orphaned.append(name)
                case is GameWindowController: break
                case let other?: hijacked.append("\(name) -> \(type(of: other))")
                }
            }
        }
        walk(NSApp.mainMenu!)

        check("every menu item has an action (\(checkedItems) checked)", checkedItems > 20)
        check("no menu action is intercepted before the controller \(hijacked)", hijacked.isEmpty)
        check("no menu action falls off the end of the chain \(orphaned)", orphaned.isEmpty)

        print("")
        print(failures == 0 ? "Controls passed." : "\(failures) control check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
