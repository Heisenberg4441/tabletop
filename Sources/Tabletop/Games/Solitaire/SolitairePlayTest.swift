//
//  SolitairePlayTest.swift
//  `Tabletop --playtest [games]` plays solitaire through the real view,
//  off-screen.
//
//  The engine is fuzzed thoroughly by `--selftest`, but the engine is not where
//  the interesting bugs live. Hit testing, the click-to-move path, the layout
//  diff and the layer bookkeeping are only exercised by a pointer, and a
//  pointer is exactly what a test cannot easily hold. So this drives the real
//  `BoardView` — same layout, same hit testing, same `perform` — by working out
//  where a card is on screen and clicking it there.
//

import AppKit

enum SolitairePlayTest {

    static func run(games: Int) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Sound.isEnabled = false
        let t = TestReporter()
        func check(_ name: String, _ ok: Bool) { t.check(name, ok) }

        // A range of window shapes, including the advertised minimum, because
        // fan compression only misbehaves when it is under pressure.
        let sizes = [
            CGSize(width: 720, height: 526),
            CGSize(width: 1000, height: 714),
            CGSize(width: 1600, height: 1000),
            CGSize(width: 2400, height: 1400),
        ]

        var hitMismatches = 0
        var inconsistencies = 0
        var clicksPerformed = 0
        var gamesWon = 0
        var offBoard = 0
        var movesWithoutAnimation = 0
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
        let apple = appleChecks(size: sizes[1])
        let inset = insetChecks()

        t.section("Playing \(games) games through the real board view")
        check("a click always lands on the card under it (\(hitMismatches) misses)", hitMismatches == 0)
        check("no card is pushed off the bottom of the table (\(offBoard))", offBoard == 0)
        check("the board never lost a card (\(inconsistencies))", inconsistencies == 0)
        check("clicks actually played (\(clicksPerformed))", clicksPerformed > games * 15)
        check("every move animates the cards it moved (\(movesWithoutAnimation) did not)",
              movesWithoutAnimation == 0)
        check("drags actually ran (\(drags.attempted))", drags.attempted >= 6)
        check("a drag applies its move (\(drags.notApplied) did not)", drags.notApplied == 0)
        check("held cards are lifted off the pile (\(drags.notLifted) were not)", drags.notLifted == 0)
        check("the drop target lights up (\(drags.noGlow) did not)", drags.noGlow == 0)
        check("dropped cards are set back down (\(drags.notSettled) were not)", drags.notSettled == 0)
        check("the Apple table differs from the flat one it replaced", apple.tableDiffers)
        check("the Apple cards differ from the flat ones (\(apple.sameArtwork) came out identical)",
              apple.sameArtwork == 0)
        check("the look reaches every card already on the table (\(apple.staleLayers) stale)",
              apple.staleLayers == 0)
        check("cards turn over in perspective (\(apple.flatFlips) squeezed instead)",
              apple.flips > 0 && apple.flatFlips == 0)
        check("a held card leans in the hand (\(apple.heldFlat) did not)",
              apple.held > 0 && apple.heldFlat == 0)
        check("the Apple table never corrupts the board (\(apple.inconsistent))", apple.inconsistent == 0)
        check("no card is laid out under the window's titlebar strip (\(inset.underChrome))",
              inset.checked > 0 && inset.underChrome == 0)
        check("and a click there never lands on a card (\(inset.hitsUnderChrome))",
              inset.hitsUnderChrome == 0)
        check("no card is laid out under the floating action bar (\(inset.underBar))",
              inset.checked > 0 && inset.underBar == 0)
        t.info("won \(gamesWon)/\(games) clicking more or less at random")
        return t.finish(passed: "Play-test passed.", failed: { "\($0) play-test check(s) FAILED." })
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

// MARK: - The Apple table

extension SolitairePlayTest {

    struct AppleResults {
        var tableDiffers = false
        var sameArtwork = 0
        var staleLayers = 0
        var flips = 0
        var flatFlips = 0
        var held = 0
        var heldFlat = 0
        var inconsistent = 0
    }

    /// The Apple table, which is all surface and therefore easy to get wrong
    /// in ways nothing else here would notice.
    ///
    /// It is the only look the app has now, but the flat rendering it replaced
    /// is still behind `Theme.apple = false`, and it is the yardstick. Three
    /// things are worth asserting and none of them are visible to the other
    /// checks. First, that the look actually changes what is drawn — a theme
    /// flag that silently fails to reach the renderer would leave the board
    /// flat, and the only complaint would come from the player. Second, that a
    /// theme change mid-game (the View menu does this all the time) reaches
    /// the fifty-two layers already on the table, which is a cache-invalidation
    /// question and so the kind that goes wrong quietly. Third, that the two
    /// pieces of real three-dimensional behaviour — the turn and the lean — are
    /// producing matrices that are genuinely not flat, because a perspective
    /// animation that has lost its `m34` still animates, still looks like
    /// something, and is simply the old squeeze wearing a new name.
    static func appleChecks(size: CGSize) -> AppleResults {
        let previousAnimations = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = previousAnimations }
        var results = AppleResults()
        var flat = Theme()
        flat.apple = false
        var apple = Theme()
        apple.apple = true

        // The artwork, compared bitmap for bitmap at one size.
        let cardSize = CGSize(width: 100, height: 143)
        let flatCards = CardRenderer(theme: flat, size: cardSize, scale: 2)
        let appleCards = CardRenderer(theme: apple, size: cardSize, scale: 2)
        for card in Card.full {
            if bitmap(flatCards.faceImage(for: card)) == bitmap(appleCards.faceImage(for: card)) {
                results.sameArtwork += 1
            }
        }
        if bitmap(flatCards.backImage()) == bitmap(appleCards.backImage()) { results.sameArtwork += 1 }

        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        let game = Game(dealNumber: 9, options: GameOptions())
        let board = BoardView(game: game, theme: flat)
        board.frame = frame
        window.contentView = board
        board.layoutSubtreeIfNeeded()
        board.displayIfNeeded()

        // The felt, drawn both ways into the same size of bitmap.
        let before = tableBitmap(of: board)
        board.theme = apple
        board.displayIfNeeded()
        let after = tableBitmap(of: board)
        results.tableDiffers = before != nil && after != nil && before != after

        // Switching the look has to reach the cards already on the table: both
        // the picture on them and the depth they sit at.
        let shallow = cardLayers(in: board).filter { $0.shadowRadius <= board.boardLayout.cardSize.width * 0.03 }
        results.staleLayers = shallow.count

        // Turning over: the flip has to be a sampled rotation, not a squeeze
        // along x. Played until some move uncovers a face-down card.
        var rng = DeterministicRNG(seed: 0xA99_1E)
        for _ in 0..<200 {
            let moves = game.state.allMoves()
            guard !moves.isEmpty else { break }
            guard board.perform(moves[rng.next(upperBound: moves.count)]) else { continue }
            if !game.state.isConsistent { results.inconsistent += 1; break }
            for layer in cardLayers(in: board) {
                guard let turn = layer.animation(forKey: "flip") else { continue }
                results.flips += 1
                guard let keyframe = turn as? CAKeyframeAnimation,
                      keyframe.keyPath == "transform",
                      let middle = (keyframe.values?[(keyframe.values?.count ?? 1) / 2]) as? NSValue,
                      !CATransform3DIsAffine(middle.caTransform3DValue)
                else {
                    results.flatFlips += 1
                    continue
                }
            }
            if results.flips > 0 { break }
        }

        // And the lean: a card in the hand is standing in three dimensions,
        // which an affine matrix cannot express.
        let placements = board.boardLayout.placements(for: game.state)
        if let top = placements.last(where: { $0.pile.kind == .tableau && $0.faceUp }) {
            let start = CGPoint(x: top.frame.midX, y: top.frame.midY)
            board.mouseDown(with: event(at: start, in: board, window: window, type: .leftMouseDown))
            for step in 1...4 {
                let p = CGPoint(x: start.x + CGFloat(step) * 14, y: start.y + CGFloat(step) * 9)
                board.mouseDragged(with: event(at: p, in: board, window: window, type: .leftMouseDragged))
            }
            for layer in cardLayers(in: board) where layer.isHeld {
                results.held += 1
                let t = layer.transform
                if CATransform3DIsAffine(t) || (abs(t.m13) < 0.001 && abs(t.m31) < 0.001) {
                    results.heldFlat += 1
                }
            }
            board.mouseUp(with: event(at: CGPoint(x: start.x + 56, y: start.y + 36),
                                      in: board, window: window, type: .leftMouseUp))
        }
        if !game.state.isConsistent { results.inconsistent += 1 }
        return results
    }

    private static func bitmap(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The felt only: the board rendered with every card layer hidden, so that
    /// the comparison is about the table rather than about the deck.
    private static func tableBitmap(of board: BoardView) -> Data? {
        guard let layer = board.layer else { return nil }
        let cards = cardLayers(in: board)
        let hidden = cards.map(\.isHidden)
        cards.forEach { $0.isHidden = true }
        defer { for (card, was) in zip(cards, hidden) { card.isHidden = was } }

        guard let ctx = CGContext(
            data: nil, width: Int(board.bounds.width), height: Int(board.bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        layer.render(in: ctx)
        return bitmap(ctx.makeImage())
    }

    struct InsetResults {
        var checked = 0
        var underChrome = 0
        var hitsUnderChrome = 0
        var underBar = 0
    }

    /// The strip under the transparent titlebar belongs to the window — the
    /// traffic lights, the Library button, the drag area — so the felt runs
    /// under it but no card may. Checked at the smallest window the app allows
    /// and at a large one, over a few dozen moves each, because it is the
    /// smallest window that squeezes the layout hardest.
    static func insetChecks() -> InsetResults {
        var results = InsetResults()
        let strip = TabletopChrome.minimumTopInset
        // The action bar floats over the bottom of the felt, as tall as the
        // real one with its margin.
        let bar = ActionBar().reservedHeight
        for (deal, size) in [(21, CGSize(width: 960, height: 640)), (22, CGSize(width: 1600, height: 1000))] {
            let frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            let game = Game(dealNumber: deal, options: GameOptions())
            let board = BoardView(game: game, theme: Theme())
            board.frame = frame
            window.contentView = board
            board.topInset = strip
            board.bottomInset = bar
            board.layoutSubtreeIfNeeded()

            var rng = DeterministicRNG(seed: UInt64(deal))
            for _ in 0..<40 {
                let placements = board.boardLayout.placements(for: game.state)
                results.checked += 1
                if placements.contains(where: { $0.frame.minY < strip - 0.5 }) { results.underChrome += 1 }
                if placements.contains(where: { $0.frame.maxY > size.height - bar + 0.5 }) { results.underBar += 1 }
                for x in stride(from: CGFloat(4), to: size.width, by: 37) {
                    let target = board.boardLayout.target(at: CGPoint(x: x, y: strip / 2),
                                                          state: game.state, placements: placements)
                    if target != .nothing { results.hitsUnderChrome += 1 }
                }
                let moves = game.state.allMoves()
                guard !moves.isEmpty else { break }
                _ = board.perform(moves[rng.next(upperBound: moves.count)])
            }
        }
        return results
    }
}
