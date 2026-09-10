//
//  SelfTest.swift
//  Engine invariants, runnable from the command line with `Solitaire --selftest`.
//
//  A solitaire bug that loses or duplicates a card is invisible until it
//  ruins a game twenty minutes in, so the engine gets fuzzed rather than
//  spot-checked: play thousands of random games, undo every move back to the
//  deal, and assert the state is byte-identical each time.
//

import Foundation

enum SelfTest {

    static func run() -> Int32 {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("  ok   \(name)")
            } else {
                print("  FAIL \(name)")
                failures += 1
            }
        }

        print("Card encoding")
        check("52 distinct codes", Set(Card.full.map(\.code)).count == 52)
        check("round trip", Card.full.allSatisfy { Card($0.suit, $0.rank) == $0 })
        check("A♠ on empty foundation", Card(.spades, .ace).canStack(onFoundation: nil))
        check("2♠ needs A♠", Card(.spades, .two).canStack(onFoundation: Card(.spades, .ace)))
        check("2♠ refuses A♥", !Card(.spades, .two).canStack(onFoundation: Card(.hearts, .ace)))
        check("red 5 on black 6", Card(.hearts, .five).canStack(onTableau: Card(.spades, .six)))
        check("red 5 refuses red 6", !Card(.hearts, .five).canStack(onTableau: Card(.diamonds, .six)))

        print("Deterministic shuffle")
        let a = GameState.deal(number: 12345)
        let b = GameState.deal(number: 12345)
        let c = GameState.deal(number: 12346)
        check("same number, same deal", a == b)
        check("different number, different deal", a != c)
        check("deal is consistent", a.isConsistent)
        check("24 cards in stock", a.stock.count == 24)
        check("tableau triangle", (0..<7).allSatisfy { a.tableau[$0].count == $0 + 1 })
        check("one face-up per column", a.tableau.allSatisfy { $0.up.count == 1 })

        print("Deal-number distribution")
        var distinct = Set<GameState>()
        for n in 1...500 { distinct.insert(GameState.deal(number: n)) }
        check("500 numbers give 500 deals", distinct.count == 500)

        print("Apply/undo fuzz (4000 games)")
        var rng = DeterministicRNG(seed: 0xC0FFEE)
        var totalMoves = 0
        var wins = 0
        var undoMismatch = 0
        var inconsistent = 0
        var illegalApplied = 0

        for game in 0..<4000 {
            let drawCount = (game % 2 == 0) ? 1 : 3
            var state = GameState.deal(number: game + 1, drawCount: drawCount)
            let dealt = state
            var history: [MoveRecord] = []
            var snapshots: [GameState] = []

            for _ in 0..<220 {
                let moves = state.allMoves()
                guard !moves.isEmpty else { break }
                let move = moves[rng.next(upperBound: moves.count)]
                snapshots.append(state)
                guard let record = state.apply(move) else { illegalApplied += 1; break }
                history.append(record)
                totalMoves += 1
                if !state.isConsistent { inconsistent += 1; break }
                if state.isWon { wins += 1; break }
            }

            // Unwind and compare against the snapshot taken before each move.
            while let record = history.popLast() {
                state.undo(record)
                let expected = snapshots.removeLast()
                if state != expected { undoMismatch += 1; break }
            }
            if history.isEmpty && snapshots.isEmpty && state != dealt { undoMismatch += 1 }
        }

        check("no inconsistent states (\(inconsistent))", inconsistent == 0)
        check("no illegal moves applied (\(illegalApplied))", illegalApplied == 0)
        check("undo is exact (\(undoMismatch) mismatches)", undoMismatch == 0)
        check("fuzz actually played (\(totalMoves) moves)", totalMoves > 100_000)
        print("  info random play won \(wins)/4000 games")

        print("Click-to-move")
        var t = GameState()
        t.tableau[0].up = [Card(.clubs, .ace)]
        t.tableau[1].up = [Card(.spades, .king)]
        t.tableau[2].down = [Card(.hearts, .two)]
        t.tableau[2].up = [Card(.hearts, .queen)]
        check("ace flies to foundation",
              t.autoMove(for: .tableauCard(column: 0, depthFromTop: 0)) == .tableauToFoundation(column: 0))
        check("queen lands on king",
              t.autoMove(for: .tableauCard(column: 2, depthFromTop: 0)) == .tableauToTableau(from: 2, to: 1, count: 1))
        check("lone king moves to an empty column",
              t.autoMove(for: .tableauCard(column: 1, depthFromTop: 0))
                  == .tableauToTableau(from: 1, to: 3, count: 1))
        check("lone king may be dragged to an empty column",
              t.isLegal(.tableauToTableau(from: 1, to: 3, count: 1)))
        check("clicking a foundation does nothing", t.autoMove(for: .foundation(0)) == nil)

        var w = GameState()
        w.waste = [Card(.diamonds, .ace)]
        w.wasteFan = 1
        check("waste ace flies up", w.autoMove(for: .waste) == .wasteToFoundation)

        // Two black sixes want the same red five: prefer the column that is
        // already dug out, so the buried one stays reachable.
        var pick = GameState()
        pick.tableau[0].up = [Card(.hearts, .five)]
        pick.tableau[1].down = [Card(.clubs, .three), Card(.clubs, .four)]
        pick.tableau[1].up = [Card(.spades, .six)]
        pick.tableau[2].up = [Card(.clubs, .six)]
        check("prefers the uncovered column",
              pick.autoMove(for: .tableauCard(column: 0, depthFromTop: 0))
                  == .tableauToTableau(from: 0, to: 2, count: 1))

        print("Runs")
        var run = GameState()
        run.tableau[0].up = [Card(.spades, .seven), Card(.hearts, .six), Card(.clubs, .five)]
        run.tableau[1].up = [Card(.diamonds, .eight)]
        check("clicking mid-run moves the run",
              run.autoMove(for: .tableauCard(column: 0, depthFromTop: 2))
                  == .tableauToTableau(from: 0, to: 1, count: 3))
        check("run move is legal", run.isLegal(.tableauToTableau(from: 0, to: 1, count: 3)))
        check("broken run is not offered", !run.isLegal(.tableauToTableau(from: 0, to: 1, count: 2)))

        // A column headed by a king with nothing underneath may be picked up
        // whole and dropped on bare table — legal, but never suggested, or the
        // hint engine would offer a move that changes nothing and no game would
        // ever look dead.
        var kingRun = GameState()
        kingRun.tableau[0].up = [Card(.spades, .king), Card(.hearts, .queen)]
        check("a whole king column moves to an empty column",
              kingRun.isLegal(.tableauToTableau(from: 0, to: 1, count: 2)))
        check("without its king it does not",
              !kingRun.isLegal(.tableauToTableau(from: 0, to: 1, count: 1)))
        check("the move is not offered as a hint",
              !kingRun.allMoves().contains(.tableauToTableau(from: 0, to: 1, count: 2)))
        check("nor does it keep a dead game alive", kingRun.isStuck)

        print("Stock cycling")
        var s = GameState.deal(number: 7, drawCount: 3)
        var draws = 0
        while !s.stock.isEmpty { s.apply(.draw(count: 3)); draws += 1 }
        check("24 cards need 8 draws of three", draws == 8)
        check("all 24 on the waste", s.waste.count == 24)
        check("recycle available", s.canRecycle)
        let beforeRecycle = s.waste
        s.apply(.recycle)
        check("recycle empties the waste", s.waste.isEmpty && s.stock.count == 24)
        while !s.stock.isEmpty { s.apply(.draw(count: 3)) }
        check("a full cycle deals the identical sequence", s.waste == beforeRecycle)
        check("still consistent", s.isConsistent)

        print("Partial draw at the end of the stock")
        var p = GameState.deal(number: 9, drawCount: 3)
        for _ in 0..<7 { p.apply(.draw(count: 3)) }
        check("3 cards left", p.stock.count == 3)
        p.apply(.draw(count: 3))
        check("stock empty", p.stock.isEmpty)
        var q = GameState.deal(number: 9, drawCount: 3)
        q.stock.removeLast(22)
        check("draw of 3 with 2 left is legal", q.isLegal(.draw(count: 3)))
        let rec = q.apply(.draw(count: 3))
        check("only 2 moved", q.waste.count == 2 && q.wasteFan == 2)
        check("record says 2", rec?.move == .draw(count: 2))
        if let rec { q.undo(rec) }
        check("undo restores partial draw", q.waste.isEmpty && q.stock.count == 2)

        print("Auto-finish terminates")
        // Four columns, each holding one suit face up in descending order, so
        // the ace of every suit is the accessible card. This is the shape any
        // fully-exposed Klondike board has: a face-up run always descends, so
        // the lowest card of a column is always on top.
        var solved = GameState()
        for suit in Suit.allCases {
            let column = Int(suit.rawValue)
            solved.tableau[column].up = (1...13).reversed().map { Card(suit, Rank(rawValue: UInt8($0))!) }
        }
        check("auto-finish fixture is consistent", solved.isConsistent)
        var steps = 0
        while let move = solved.autoFinishMove(), steps < 200 {
            guard solved.apply(move) != nil else { break }
            steps += 1
        }
        check("auto-finish drains the board", solved.isWon)
        check("auto-finish is efficient (\(steps) steps)", steps == 52)

        print("Safe autoplay rule")
        var safe = GameState()
        safe.foundations = [1, 1, 1, 1]        // all aces up
        safe.tableau[0].up = [Card(.spades, .two)]
        check("two is always safe", safe.isSafeToAutoPlay(Card(.spades, .two)))
        safe.foundations = [2, 1, 1, 2]
        check("black three unsafe while red aces are low",
              !safe.isSafeToAutoPlay(Card(.spades, .three)))
        safe.foundations = [2, 2, 2, 2]
        check("black three safe once both reds reached two",
              safe.isSafeToAutoPlay(Card(.spades, .three)))

        print("Stuck detection")
        var dead = GameState()
        dead.tableau[0].up = [Card(.spades, .five)]   // lone five, nothing else anywhere
        check("dead position is stuck", dead.isStuck)
        check("fresh deal is not stuck", !GameState.deal(number: 3).isStuck)

        // A five with a six to sit on is alive.
        var alive = dead
        alive.tableau[1].up = [Card(.hearts, .six)]
        check("a legal tableau move revives it", !alive.isStuck)

        // So is one whose card is still to come out of the stock. Note the
        // direction: a card in the waste can only be played *onto* the
        // tableau, never receive cards, so the stock must hold the five that
        // sits on the six, not the six the five would want.
        var pending = GameState()
        pending.tableau[0].up = [Card(.hearts, .six)]
        pending.stock = [Card(.spades, .five)]
        check("a playable card in the stock counts", !pending.isStuck)

        // Six cards drawn three at a time only ever expose the 4th and the
        // 1st, so a five parked at index 1 never reaches the top of the waste.
        var buried = GameState()
        buried.tableau[0].up = [Card(.hearts, .six)]
        buried.stock = [
            Card(.clubs, .ten), Card(.spades, .five), Card(.diamonds, .nine),
            Card(.clubs, .queen), Card(.diamonds, .jack), Card(.hearts, .nine),
        ]
        buried.drawCount = 3
        buried.redealLimit = 0
        check("draw-3 on a final pass can bury the only playable card", buried.isStuck)
        buried.redealLimit = nil
        check("redeals alone do not un-bury it — the cycle repeats exactly",
              buried.isStuck)

        // But a card already sitting on the waste shifts the batching by one,
        // so the next pass exposes a different set.
        var shifted = buried
        shifted.waste = [Card(.spades, .king)]
        shifted.wasteFan = 1
        check("a card on the waste shifts the next pass and frees it", !shifted.isStuck)

        // But not one where the stock holds nothing useful.
        var junk = GameState()
        junk.tableau[0].up = [Card(.spades, .five)]
        junk.stock = [Card(.hearts, .nine), Card(.clubs, .ten)]
        check("an unhelpful stock is still stuck", junk.isStuck)

        // Foundation retreats do not count as being un-stuck.
        var retreat = GameState()
        retreat.foundations = [1, 0, 0, 0]
        check("pulling a card off a foundation is not progress", retreat.isStuck)

        print("Frozen deal numbers")
        // If one of these fails, someone changed the shuffle, the deal order or
        // the seed derivation, and every deal number in the world just moved.
        let golden: [(Int, UInt64)] = [
            (1, 0x9C9C6FDF5C17EEB2),
            (2, 0xB1580B23ED08C576),
            (3, 0xAEFAFB9E95CAA2B0),
            (7, 0x3EF17F399F88174E),
            (42, 0xD4159A8E901AC5CC),
            (100, 0x92AD52C83DFAD0E8),
            (999, 0x4E82F9431D2B8972),
            (1234, 0x11E98A34B0916F84),
            (40312, 0x7EE2DB6C29F27670),
            (999_999, 0x3E9C1052D6D7A9FC),
        ]
        var drifted: [Int] = []
        for (number, expected) in golden
        where layoutFingerprint(GameState.deal(number: number)) != expected {
            drifted.append(number)
        }
        check("10 deal numbers still mean the same cards \(drifted)", drifted.isEmpty)

        print("Score and undo")
        var scored = Game(dealNumber: 1, options: {
            var o = GameOptions(); o.scoring = .standard; o.drawCount = 1; return o
        }())
        // Drive the score down to where the clamp bites, then undo. Undo must
        // give back what the score actually lost, not the nominal penalty —
        // otherwise every recycle-then-undo mints a hundred points.
        while !scored.state.stock.isEmpty { scored.perform(.draw(count: 1)) }
        let scoreBeforePenalty = scored.score
        scored.perform(.recycle)
        let scoreAfterPenalty = scored.score
        check("standard score never goes negative", scoreAfterPenalty >= 0)
        scored.undo()
        check("undoing a clamped penalty restores the exact score (\(scoreBeforePenalty) -> \(scoreAfterPenalty) -> \(scored.score))",
              scored.score == scoreBeforePenalty)

        var minted = Game(dealNumber: 1, options: {
            var o = GameOptions(); o.scoring = .standard; return o
        }())
        while !minted.state.stock.isEmpty { minted.perform(.draw(count: 1)) }
        let start = minted.score
        for _ in 0..<6 {
            minted.perform(.recycle)
            minted.undo()
        }
        check("recycle/undo cannot mint points (\(start) -> \(minted.score))", minted.score == start)

        // The single-case check above only exercises the clamp when the score
        // happens to be low, so fuzz it: play real games, undo everything, and
        // demand the score comes back to exactly where it started every time.
        var scoreDrift = 0
        var clampsSeen = 0
        var frng = DeterministicRNG(seed: 0x5C0DE)
        for n in 0..<400 {
            var options = GameOptions()
            options.scoring = .standard
            options.drawCount = (n % 2 == 0) ? 1 : 3
            let game = Game(dealNumber: n + 1, options: options)
            var scores: [Int] = []
            for _ in 0..<70 {
                let moves = game.state.allMoves()
                guard !moves.isEmpty, !game.isWon else { break }
                scores.append(game.score)
                let before = game.score
                let move = moves[frng.next(upperBound: moves.count)]
                guard game.perform(move) != nil else { scores.removeLast(); break }
                if case .recycle = move, before < 100, game.score == 0 { clampsSeen += 1 }
            }
            while let expected = scores.popLast() {
                game.undo()
                if game.score != expected { scoreDrift += 1; break }
            }
        }
        check("score survives 400 games of undo (\(scoreDrift) drifts)", scoreDrift == 0)
        check("the clamp was actually exercised (\(clampsSeen) times)", clampsSeen > 0)

        print("Win bonus")
        var bonusGame = Game(dealNumber: 5, options: {
            var o = GameOptions(); o.scoring = .standard; o.timed = true; return o
        }())
        // Force a position one move from a win, then win it.
        var nearlyWon = GameState()
        for suit in Suit.allCases { nearlyWon.foundations[Int(suit.rawValue)] = 13 }
        nearlyWon.foundations[3] = 12
        nearlyWon.tableau[0].up = [Card(.spades, .king)]
        bonusGame.forceState(nearlyWon)
        bonusGame.perform(.tableauToFoundation(column: 0))
        check("winning is detected", bonusGame.isWon)
        let wonScore = bonusGame.displayScore
        bonusGame.undo()
        check("undoing the winning move retracts the bonus", bonusGame.timeBonus == 0)
        bonusGame.redo()
        check("redo does not pay the bonus twice", bonusGame.displayScore == wonScore)

        print("Auto-finish preconditions")
        var draw3 = GameState()
        draw3.drawCount = 3
        draw3.redealLimit = nil
        draw3.stock = [Card(.clubs, .five), Card(.hearts, .nine)]
        check("draw-three with cards left cannot auto-finish", !draw3.canAutoFinish)
        draw3.drawCount = 1
        check("draw-one with unlimited passes can", draw3.canAutoFinish)
        draw3.stock = []
        draw3.drawCount = 3
        check("an empty stock always can", draw3.canAutoFinish)

        print("Draw legality")
        var drawState = GameState.deal(number: 2)
        check("draw of one is legal", drawState.isLegal(.draw(count: 1)))
        check("draw of three is legal", drawState.isLegal(.draw(count: 3)))
        check("draw of seven is not", !drawState.isLegal(.draw(count: 7)))
        check("draw of zero is not", !drawState.isLegal(.draw(count: 0)))
        drawState.stock = []
        check("draw from an empty stock is not", !drawState.isLegal(.draw(count: 1)))

        print("Move destinations")
        var dest = GameState()
        dest.tableau[0].up = [Card(.hearts, .ace)]
        dest.waste = [Card(.spades, .ace)]
        dest.wasteFan = 1
        check("a tableau ace goes to its own foundation",
              Move.tableauToFoundation(column: 0).destination(in: dest) == .foundation(2))
        check("a waste ace goes to its own foundation",
              Move.wasteToFoundation.destination(in: dest) == .foundation(3))

        print("Undo grouping")
        var grouped = Game(dealNumber: 11, options: GameOptions())
        grouped.beginUndoGroup()
        grouped.perform(.draw(count: 1))
        grouped.perform(.draw(count: 1))
        grouped.perform(.draw(count: 1))
        grouped.endUndoGroup()
        check("three grouped moves are one undo step", grouped.moveCount == 3)
        grouped.undo()
        check("one undo takes back all three", grouped.state.waste.isEmpty)
        check("and nothing is left to undo", !grouped.canUndo)

        print("Preferences")
        // A file saved before a setting existed has to keep loading, with the
        // new setting defaulted and every choice the player made intact. The
        // synthesised decoder throws on the first missing key and `load()`
        // answers a throw with a factory-fresh file — which is the difference
        // between adding a setting and quietly resetting everybody's.
        let older = #"{"drawCount":3,"scoring":"vegas","table":"slate","windowFrame":"{{0, 74}, {1800, 1056}}"}"#
        let restored = try? JSONDecoder().decode(Preferences.self, from: Data(older.utf8))
        check("a preferences file from an older build still loads", restored != nil)
        check("the choices in it survive",
              restored?.drawCount == 3 && restored?.scoring == .vegas
                  && restored?.table == .slate
                  && restored?.windowFrame == "{{0, 74}, {1800, 1056}}")
        check("settings it never heard of come back as defaults",
              restored?.brainrot == false && restored?.clickPrefersFoundation == true
                  && restored?.backColor == .navy)
        var written = Preferences()
        written.brainrot = true
        written.table = .burgundy
        let roundTrip = (try? JSONEncoder().encode(written))
            .flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        check("and a round trip through disk is lossless", roundTrip == written)

        print("Solver")
        // The verdict that matters is "winnable", because that is the one the
        // game acts on: with "winnable deals only" turned on, a false positive
        // hands the player a deal that cannot be won. So every accepted deal is
        // replayed move by move through the real rules — not the solver's own
        // packed model — and has to actually finish.
        var accepted = 0
        var undecided = 0
        var lineRejected = 0
        var lineDidNotWin = 0
        for n in 1...120 {
            let drawCount = (n % 2 == 0) ? 1 : 3
            let deal = GameState.deal(number: n, drawCount: drawCount)
            let solver = KlondikeSolver(state: deal)
            guard solver.isWinnable() else {
                if solver.hitLimit { undecided += 1 }
                continue
            }
            accepted += 1
            // The solver plays with unlimited redeals, so replay under the same
            // rule it decided under.
            var replay = deal
            replay.redealLimit = nil
            var ok = true
            for move in solver.solution where ok {
                if replay.apply(move) == nil { ok = false }
            }
            if !ok { lineRejected += 1 }
            else if !replay.isWon { lineDidNotWin += 1 }
        }
        check("the solver decided most deals (\(accepted) winnable, \(undecided) undecided of 120)",
              accepted + undecided == 120 ? accepted >= 80 : accepted >= 80)
        check("every winning line is legal move for move (\(lineRejected) rejected)", lineRejected == 0)
        check("every winning line actually wins (\(lineDidNotWin) did not)", lineDidNotWin == 0)

        // A position one move from a win must be recognised instantly.
        var oneAway = GameState()
        for suit in Suit.allCases { oneAway.foundations[Int(suit.rawValue)] = 13 }
        oneAway.foundations[3] = 12
        oneAway.tableau[0].up = [Card(.spades, .king)]
        check("a position one move from a win is winnable", KlondikeSolver(state: oneAway).isWinnable())

        // And a hopeless one must not be.
        var hopeless = GameState()
        hopeless.tableau[0].up = [Card(.spades, .five)]
        check("a position with no moves at all is not winnable",
              !KlondikeSolver(state: hopeless).isWinnable())

        print("")
        if failures == 0 {
            print("All self-tests passed.")
        } else {
            print("\(failures) self-test(s) FAILED.")
        }
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Regression tests

extension SelfTest {

    /// A stable fingerprint of a dealt layout. Frozen on purpose: if any of
    /// these change, every deal number a player has ever written down now means
    /// different cards.
    static func layoutFingerprint(_ state: GameState) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        for column in state.tableau {
            for card in column.down { mix(card.code) }
            mix(0xFD)
            for card in column.up { mix(card.code) }
            mix(0xFE)
        }
        for card in state.stock { mix(card.code) }
        return hash
    }

    static func printGoldenVectors() {
        for n in [1, 2, 3, 7, 42, 100, 999, 1234, 40312, 999_999] {
            let h = layoutFingerprint(GameState.deal(number: n))
            print("        (\(n), 0x\(String(h, radix: 16, uppercase: true))),")
        }
    }
}
