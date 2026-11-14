//
//  PoolTests.swift
//  Pool's checks, for `Tabletop --selftest pool`.
//
//  The engine's own tests come first (`PoolEngineTests`, in Engine/). Then
//  the presentation's: that the table drawn is the table the engine plays
//  on, that the textures read the right way round, that the camera settles,
//  that a game saves and comes back, and that the controller plays whole
//  games against itself — every shot shown exactly as the rules scored it —
//  plays the computer's turn in real time only while it is in front, stops
//  everything that ticks when it leaves the screen, and photographs itself.
//

import AppKit
import SceneKit
import simd

@MainActor
enum PoolTests {

    static func run(_ t: TestReporter) {
        let started = Date()
        defer { t.info(String(format: "pool presentation tests took %.1f s", Date().timeIntervalSince(started))) }
        PoolEngineTests.run(t)
        t.section("Pool: the table as drawn")
        tableGeometry(t)
        space(t)
        t.section("Pool: textures and camera")
        textures(t)
        camera(t)
        t.section("Pool: games and saves")
        matches(t)
        persistence(t)
        t.section("Pool: the controller")
        controller(t)
    }

    // MARK: Geometry

    private static func tableGeometry(_ t: TestReporter) {
        let g = PoolTableGeometry.standard
        let d = PoolTableDimensions(g)
        let runs = PoolShapes.cushionRuns(d)
        let edges = runs.map { $0.chain.count - 1 }.reduce(0, +)
        t.check("every one of the engine's \(g.cushions.count) cushion segments is drawn, in \(runs.count) cushions",
                edges == g.cushions.count && !runs.isEmpty)
        let inside = runs.allSatisfy { run in
            run.polygon.allSatisfy { abs($0.x) <= d.backX + 1e-6 && abs($0.y) <= d.backY + 1e-6 }
        }
        t.check("every cushion stays inside the rail", inside)
        let noses = g.cushions.allSatisfy { segment in
            runs.contains { run in
                zip(run.chain, run.chain.dropFirst()).contains { simd_distance($0, segment.a) < 1e-9 && simd_distance($1, segment.b) < 1e-9 }
            }
        }
        t.check("each cushion's nose is exactly the engine's segment", noses)
        let meshes = runs.allSatisfy { run in
            PoolCushionMesh.geometry(chain: run.chain, interior: run.interior, onBackLine: run.isOnBackLine,
                                     back: run.back, nose: g.cushionNoseHeight, top: d.cushionTop,
                                     material: SCNMaterial()) != nil
        }
        t.check("every cushion's rubber profile can be swept", meshes)
        let profile = PoolCushionMesh.profile(nose: g.cushionNoseHeight, top: d.cushionTop)
        t.check("the profile's nose is the engine's nose height, with the undercut below it",
                profile.contains { $0.x == 0 && $0.y == g.cushionNoseHeight } && (profile.first?.x ?? 0) > 0)

        var holesClear = true
        for pocket in g.pockets {
            let hole = PoolShapes.holePolygon(pocket, d)
            let (m0, m1) = pocket.mouth
            var n = simd_normalize(SIMD2(-(m1 - m0).y, (m1 - m0).x))
            if simd_dot(pocket.center - m0, n) < 0 { n = -n }
            if hole.count < 3 || hole.contains(where: { simd_dot($0 - m0, n) < 0 }) { holesClear = false }
        }
        t.check("no pocket's hole reaches in front of its mouth, onto the playing surface", holesClear)

        let boundary = PoolShapes.railInnerBoundary(d)
        let outsideBack = boundary.allSatisfy { abs($0.x) >= d.backX - 1e-6 || abs($0.y) >= d.backY - 1e-6 }
        t.check("the rail's inner edge never crosses onto the cushions (\(boundary.count) points)", outsideBack)
        let bites = g.pockets.allSatisfy { contains(boundary, $0.center) }
        t.check("the rail is cut away over every pocket", bites)
        t.check("the playing surface is entirely inside the rail", contains(boundary, [d.halfLength - 0.01, d.halfWidth - 0.01])
                    && contains(boundary, [-d.halfLength + 0.01, -d.halfWidth + 0.01]))
    }

    private static func contains(_ polygon: [SIMD2<Double>], _ p: SIMD2<Double>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func space(_ t: TestReporter) {
        let p = SIMD2<Double>(0.73, -0.41)
        t.check("a point on the cloth survives the trip into the scene and back",
                simd_distance(PoolSpace.table(PoolSpace.scene(p, height: 0.2)), p) < 1e-6)
        // Turning a vector in the engine and carrying it across must be the
        // same as carrying it across and turning it in the scene.
        let q = simd_normalize(simd_quatd(angle: 0.9, axis: simd_normalize(SIMD3(0.3, -0.5, 0.8))))
        let v = SIMD3<Double>(0.2, 0.7, -0.4)
        let turned = q.act(v)
        let viaEngine = SIMD3<Float>(Float(turned.x), Float(turned.z), Float(-turned.y))
        let viaScene = PoolSpace.sceneOrientation(q).act(SIMD3<Float>(Float(v.x), Float(v.z), Float(-v.y)))
        t.check("a rolling ball's orientation turns the same way on screen", simd_distance(viaEngine, viaScene) < 1e-5)
        let aim = 0.6
        let yaw = PoolCameraPose.yaw(forAim: aim)
        let pose = PoolCameraPose(focus: .zero, yaw: yaw, pitch: 0, distance: 1, fieldOfView: 40)
        let flat = PoolSpace.direction(aim)
        t.check("the aim view looks along the shot",
                simd_distance(SIMD3<Float>(Float(pose.forward.x), Float(pose.forward.y), Float(pose.forward.z)), flat) < 1e-5)
    }

    // MARK: Textures and camera

    private static func textures(_ t: TestReporter) {
        // The first table of a session makes every texture; later ones share them.
        let started = Date()
        let first = PoolTableScene(cloth: .green)
        let made = Date().timeIntervalSince(started)
        let again = Date()
        _ = PoolTableScene(cloth: .green)
        t.info(String(format: "building the table: %.0f ms the first time, %.0f ms after", made * 1000,
                      Date().timeIntervalSince(again) * 1000))
        t.check("the table has sixteen balls, a cue and a camera",
                first.balls.count == 16 && first.cameraNode.camera != nil && first.cue.length > 1.4)
        guard let image = PoolMaterials.ballImage(11) else { t.check("ball textures are made", false); return }
        t.check("a ball's skin is 2:1 for a sphere (\(image.width)×\(image.height))", image.width == 2 * image.height)
        let pole = pixel(image, image.width / 8, 4)
        let band = pixel(image, image.width / 8, image.height / 2)
        t.check("a stripe is ivory at the poles and coloured round the middle",
                pole.x > 0.85 && pole.y > 0.85 && pole.z > 0.8 && band.x > 0.6 && band.y < 0.3)
        let solid = PoolMaterials.ballImage(4).map { pixel($0, $0.width / 8, 4) } ?? .zero
        t.check("a solid is coloured all over", solid.x < 0.5 && solid.z > 0.35)
        // A seven has its bar at the top: more ink in the top half of its
        // coverage than the bottom, if it is the right way up.
        if let seven = PoolTextures.glyphCoverage(7, size: 64) {
            let top = seven.values.prefix(32 * 64).reduce(0.0, +)
            let bottom = seven.values.suffix(32 * 64).reduce(0.0, +)
            t.check("the numbers are printed the right way up", top > bottom * 1.3)
        } else {
            t.check("the numbers are printed the right way up", false)
        }
        let all = (0...15).allSatisfy { PoolMaterials.ballImage($0) != nil }
        t.check("all sixteen balls have skins", all)
        t.check("the room the balls reflect is made",
                PoolTextures.environmentImage(cloth: [0.1, 0.3, 0.2], lampHeight: 1, lampLength: 1.8, lampWidth: 0.4, width: 64) != nil)
    }

    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> SIMD3<Double> {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .zero }
        let i = y * image.bytesPerRow + x * 4
        return SIMD3(Double(bytes[i]), Double(bytes[i + 1]), Double(bytes[i + 2])) / 255
    }

    private static func camera(_ t: TestReporter) {
        var rig = PoolCameraRig(PoolCameraPose(focus: [0, 0, 0], yaw: 0, pitch: 0.3, distance: 1, fieldOfView: 40))
        rig.set(PoolCameraPose(focus: [1, 0, 0], yaw: 0, pitch: 0.3, distance: 3, fieldOfView: 40), immediately: false)
        var last = rig.current.distance
        var monotonic = true
        var frames = 0
        while rig.step(1.0 / 60) && frames < 600 {
            if rig.current.distance < last - 1e-9 || rig.current.distance > 3 + 1e-6 { monotonic = false }
            last = rig.current.distance
            frames += 1
        }
        t.check("the camera glides to its goal without overshooting", monotonic && rig.isSettled)
        t.check("and settles in about a second (\(frames) frames)", frames > 20 && frames < 110)
        var turn = PoolCameraRig(PoolCameraPose(focus: .zero, yaw: 3.0, pitch: 0.3, distance: 1, fieldOfView: 40))
        turn.set(PoolCameraPose(focus: .zero, yaw: -3.0, pitch: 0.3, distance: 1, fieldOfView: 40), immediately: false)
        t.check("it turns the short way round", abs(turn.goal.yaw - 3.0) < 0.3)
    }

    // MARK: Matches and saves

    private static func matches(_ t: TestReporter) {
        for (mode, count) in [(PoolMode.eightBall, 16), (.nineBall, 10), (.practice, 16)] {
            var options = PoolOptions()
            options.mode = mode
            let match = PoolMatch.start(options, seed: 5, breaker: PoolSeat.you, opponentName: "Anna")
            t.check("\(PoolEngineText.mode(mode)) racks \(count) balls, the player to break",
                    match.table.balls.count == count && match.rules.shooter == PoolSeat.you && !match.isOver)
        }
        let match = PoolMatch.start(PoolOptions(), seed: 5, breaker: PoolSeat.you, opponentName: "Anna")
        t.check("nobody has a group before the break", match.ballsNeeded(by: 0) == nil && match.ballsNeeded(by: 1) == nil)
        var later = match
        later.rules.shotCount += 1
        t.check("the computer's decisions are seeded by the game and the shot",
                match.decisionSeed == PoolMatch.start(PoolOptions(), seed: 5, breaker: 0, opponentName: "B").decisionSeed
                    && later.decisionSeed != match.decisionSeed)
        var withGroups = match
        withGroups.table = PoolScenarios.midGame()
        withGroups.rules.groups = [.solids, .stripes]
        t.check("the balls still needed are the group's balls left on the cloth",
                withGroups.ballsNeeded(by: 0) == [2, 3, 6] && withGroups.ballsNeeded(by: 1) == [9, 10, 12, 14, 15])
    }

    private static func persistence(_ t: TestReporter) {
        var match = PoolMatch.start(PoolOptions(), seed: 77, breaker: PoolSeat.computer, opponentName: "Grace")
        match.table = PoolScenarios.midGame()
        match.rules.groups = [.stripes, .solids]
        match.rules.isBreakShot = false
        match.currentRun = 3
        let saved = PoolSavedGame(match, aim: 1.25)
        guard let data = try? JSONEncoder().encode(saved),
              let back = try? JSONDecoder().decode(PoolSavedGame.self, from: data) else {
            t.check("a game in progress saves and loads", false)
            return
        }
        let same = zip(back.table.balls, match.table.balls).allSatisfy {
            $0.number == $1.number && $0.pocket == $1.pocket && simd_distance($0.position, $1.position) < 1e-12
        }
        t.check("a game in progress saves and loads, ball for ball", same && back.aim == 1.25
                    && back.opponentName == "Grace" && back.currentRun == 3 && back.rules.groups == [.stripes, .solids])
        t.check("and is recognised as worth resuming", back.isPlausible)
        // A detail that cannot be read falls back; a table that cannot be
        // read means there is no game to resume.
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["options"] = "garbage"
            object["currentRun"] = "three"
            let damaged = try? JSONSerialization.data(withJSONObject: object)
            let loaded = damaged.flatMap { try? JSONDecoder().decode(PoolSavedGame.self, from: $0) }
            t.check("a save with an unreadable detail still loads, with defaults",
                    loaded?.options == PoolOptions() && loaded?.currentRun == 0)
            object["table"] = ["balls": "none"]
            let broken = try? JSONSerialization.data(withJSONObject: object)
            // The engine reads what it can of a damaged table, so the save
            // may load — but a table without its balls is never resumed.
            let resumable = broken.flatMap { try? JSONDecoder().decode(PoolSavedGame.self, from: $0) }?.isPlausible ?? false
            t.check("a save without a readable table is not resumed", !resumable)
        }
        let partial = Data(#"{"played": {"easy": 4}, "bestRun": "lots"}"#.utf8)
        let stats = try? JSONDecoder().decode(PoolStatistics.self, from: partial)
        t.check("statistics decode key by key", stats?.games(.easy) == 4 && stats?.wins(.easy) == 0 && stats?.bestRun == 0)
        var options = PoolOptions()
        options.mode = .nineBall
        options.guides = .short
        let optionsBack = (try? JSONEncoder().encode(options)).flatMap { try? JSONDecoder().decode(PoolOptions.self, from: $0) }
        t.check("the New Game choices are remembered", optionsBack == options)
    }

    // MARK: The controller

    private static func makeGame() -> (PoolGame, NSWindow) {
        Storage.remove(PoolGame.savedGameName)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let game = PoolGame()
        game.runsSynchronously = true
        window.contentView = game.view
        game.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        game.view.layoutSubtreeIfNeeded()
        return (game, window)
    }

    private static func controller(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        t.check("a first game is eight-ball, the player to break, lined up and waiting",
                game.match.options.mode == .eightBall && game.phase == .aiming && game.isPlayersTurn
                    && game.match.rules.isBreakShot)
        t.check("the cue is on the cue ball and the guides are on the cloth",
                !game.table.cue.node.isHidden && !game.table.guides.node.isHidden)
        t.check("GameInfo says one player against the computer", PoolGame.info.detail == "1 player · vs computer")

        computerGames(t, game: game)

        // New game from the card.
        game.presentOptions()
        t.check("New Game brings up the options card", game.optionsCard?.isPresented == true)
        game.optionsCard?.dismiss(animated: false)
        var nine = PoolOptions()
        nine.mode = .nineBall
        game.startNewGame(nine, breaker: PoolSeat.you)
        t.check("a nine-ball rack has the nine and eight others", game.match.table.balls.count == 10)
        t.check("the player's plate shows the ball on", game.match.lowestBall == 1)

        // Ball in hand: the cue ball can only be put where the rules allow.
        var options = PoolOptions()
        options.mode = .eightBall
        game.startNewGame(options, breaker: PoolSeat.you)
        let spot = game.placementSpot(near: game.geometry.headSpot)
        var others = game.match.table
        others.balls.removeAll { $0.number == 0 }
        t.check("a place for the cue ball for the break is one the rules allow",
                PoolRules.isValidPlacement(spot, game.match.rules, table: others))

        // The cue is raised to clear the rail when the ball is against it.
        game.moveCueBall(to: [0.2, game.geometry.width / 2 - game.geometry.ballRadius - 0.002])
        game.aim = -.pi / 2
        let steep = game.cueElevation(from: game.match.table.cueBall?.position ?? .zero,
                                      tipHeight: game.geometry.ballRadius)
        game.moveCueBall(to: [0.2, 0])
        let flat = game.cueElevation(from: [0.2, 0], tipHeight: game.geometry.ballRadius)
        t.check("the cue is lifted over the rail when the cue ball is frozen to it (\(Int(steep * 180 / .pi))° against \(Int(flat * 180 / .pi))°)",
                steep > flat + 0.08)

        // Saving.
        game.save()
        let saved = Storage.load(PoolSavedGame.self, from: PoolGame.savedGameName)
        t.check("the game in progress is saved as pool-game.json",
                PoolGame.savedGameName == "pool-game.json" && saved?.table.balls.count == game.match.table.balls.count)

        // The computer's turn shows its own spin on the control, and hands
        // the player's back with the turn — whenever the turn comes back
        // (from a few positions, as the computer sometimes runs out).
        var handedBack = 0, spinRestored = true
        var easy = PoolOptions()
        easy.difficulty = .easy
        for k in 0..<4 where handedBack == 0 {
            game.startNewGame(easy, breaker: PoolSeat.you)
            game.setSpin(side: 0.3, vertical: -0.2)
            game.match.seed = UInt64(31 + k)
            game.match.table = PoolScenarios.midGame()
            game.match.rules.isBreakShot = false
            game.match.rules.ballInHand = nil
            game.match.rules.groups = [.solids, .stripes]
            game.match.rules.shooter = PoolSeat.computer
            game.table.apply(table: game.match.table)
            game.beginTurn(announce: false)
            guard !game.match.isOver else { continue }
            handedBack += 1
            if !(game.isPlayersTurn && game.tipSide == 0.3 && game.tipVertical == -0.2) { spinRestored = false }
        }
        t.check("after the computer's turn the player's own spin is back", handedBack > 0 && spinRestored)

        energy(t)
        computerInRealTime(t)
        leavingMidShot(t)
        hudAndHints(t)
        framing(t)
        snapshot(t)
    }

    // MARK: Whole games

    /// One game for `computerGames`: the rules, who breaks, and how well each
    /// seat plays.
    private struct GamePlan {
        let mode: PoolMode
        let breaker: Int
        let you: PoolDifficulty
        let computer: PoolDifficulty
        /// The player's seat's strokes to play; nil plays the game out.
        var turns: Int? = nil
        /// The player's seat simply strikes the nearest ball it may hit
        /// (instead of deciding like the computer does).
        var scripted = false
    }

    /// Whole games, computer against computer, through the controller the
    /// way they are played. The player's seat is the engine's computer player
    /// striking through the same `strike` the Shoot button uses (putting the
    /// cue ball down first with ball in hand, as a drag does, and only where
    /// the rules allow); the other seat is the controller's own computer
    /// turn; every animation lands at once. After every shot — either
    /// seat's — the playback must end exactly on the table the rules judged,
    /// and the table and the rules must make sense; every game must end with
    /// a winner.
    private static func computerGames(_ t: TestReporter, game: PoolGame) {
        var plans: [GamePlan] = []
        if PoolEngineTests.isRelease {
            // Every pairing of levels at both games, each seat breaking in
            // turn, and a practice rack cleared on its own.
            for (k, (you, computer)) in [(PoolDifficulty.hard, PoolDifficulty.medium), (.medium, .hard), (.easy, .easy),
                                         (.easy, .medium), (.medium, .medium), (.hard, .easy)].enumerated() {
                for mode in [PoolMode.eightBall, .nineBall] {
                    let breaker = (k + (mode == .nineBall ? 1 : 0)) % 2
                    plans.append(GamePlan(mode: mode, breaker: breaker, you: you, computer: computer))
                }
            }
            plans.append(GamePlan(mode: .practice, breaker: PoolSeat.you, you: .medium, computer: .medium))
        } else {
            // A debug build runs the engine some seventy times slower: the
            // opening shots of a practice rack and of a nine-ball game —
            // the break, and the computer's replies — checked the same way.
            plans = [
                GamePlan(mode: .practice, breaker: PoolSeat.you, you: .easy, computer: .easy, turns: 3, scripted: true),
                GamePlan(mode: .eightBall, breaker: PoolSeat.computer, you: .easy, computer: .easy, turns: 1,
                         scripted: true),
            ]
        }
        let started = Date()
        let playedBefore = PoolStatistics.load().played.values.reduce(0, +)
        var finished = 0, shots = 0
        var problems: [String] = []
        var wins = [0, 0]
        var trueToPlayback = true, rightPockets = true, legalPlacements = true
        // How each level played: shots, shots that potted a ball of its own
        // (or kept the turn), and fouls.
        var levelShots: [PoolDifficulty: (shots: Int, pots: Int, fouls: Int)] = [:]
        var levels = [PoolDifficulty.medium, .medium]
        game.shotObserver = { result, outcome, shooter in
            if !game.match.isPractice, let level = levels[safe: shooter] {
                var tally = levelShots[level] ?? (0, 0, 0)
                tally.shots += 1
                if outcome.foul == nil && (!outcome.credited.isEmpty || outcome.gameOver?.winner == shooter) { tally.pots += 1 }
                if outcome.foul != nil { tally.fouls += 1 }
                levelShots[level] = tally
            }
            guard let trajectory = result.trajectory else { trueToPlayback = false; return }
            // What was shown is what was scored: the playback's last moment
            // is the final table, ball for ball, and every ball it showed
            // dropping went down the pocket the rules were told about.
            let end = trajectory.poses(at: trajectory.duration)
            for ball in result.final.balls {
                guard let pose = end[ball.number] else { trueToPlayback = false; continue }
                if pose.pocket != ball.pocket { trueToPlayback = false }
                if ball.pocket == nil && (simd_distance(pose.position, ball.position) > 1e-9
                                          || simd_distance(pose.orientation.vector, ball.orientation.vector) > 1e-9) {
                    trueToPlayback = false
                }
            }
            for (ball, pocket) in result.pocketed {
                guard let track = trajectory.tracks.first(where: { $0.number == ball }) else { rightPockets = false; continue }
                let dropping = PoolTrajectory.pose(of: track, at: track.pocketTime + 0.05)
                if dropping?.pocket != pocket || track.pocket != pocket { rightPockets = false }
            }
        }
        defer { game.shotObserver = nil }

        for (index, plan) in plans.enumerated() {
            var options = PoolOptions()
            options.mode = plan.mode
            options.difficulty = plan.computer
            levels = [plan.you, plan.computer]
            game.startNewGame(options, breaker: plan.breaker)
            let numbers = Set(game.match.table.balls.map(\.number))
            var turns = 0
            var problem = self.problem(in: game, numbers: numbers, before: nil)
            // Practice has no winner: it is over when the rack is cleared.
            func done() -> Bool { game.match.isOver || (game.match.isPractice && game.match.ballsOnTable.isEmpty) }
            while problem == nil && !done() && turns < (plan.turns ?? 150) {
                let before = game.match.table
                let decision = plan.scripted
                    ? PoolAIDecision(placement: nil, shot: PoolShot(aim: game.defaultAim(), power: 0.55))
                    : PoolAI.decide(table: game.match.table, rules: game.match.rules, difficulty: plan.you,
                                    seed: game.match.decisionSeed ^ UInt64(index + 1) << 40, geometry: game.geometry)
                if let spot = decision.placement, game.playerHasBallInHand {
                    if !game.isAllowedPlacement(spot) { legalPlacements = false }
                    game.moveCueBall(to: spot)
                }
                game.aim = decision.shot.aim
                game.setSpin(side: decision.shot.tipSide, vertical: decision.shot.tipVertical)
                game.strike(decision.shot)
                turns += 1
                problem = self.problem(in: game, numbers: numbers, before: before)
            }
            shots += game.match.rules.shotCount
            if let problem {
                problems.append("\(PoolEngineText.mode(plan.mode)) game \(index + 1): \(problem)")
            } else if plan.turns != nil {
                finished += 1
            } else if let winner = game.match.rules.winner {
                finished += 1
                wins[winner] += 1
            } else if game.match.isPractice && game.match.ballsOnTable.isEmpty {
                finished += 1
            } else {
                problems.append("\(PoolEngineText.mode(plan.mode)) game \(index + 1) never ended")
            }
        }
        let whole = plans.allSatisfy { $0.turns == nil }
        t.check(whole
                    ? "\(finished) of \(plans.count) whole games, computer against computer, end with a winner (or, in practice, a cleared table)"
                    : "\(finished) of \(plans.count) games, computer against computer, play their opening shots (whole games in release)",
                finished == plans.count)
        t.check("the table and the rules make sense after every one of \(shots) shots"
                    + (problems.isEmpty ? "" : " (\(problems.joined(separator: "; ")))"), problems.isEmpty)
        t.check("each shot's playback ends exactly on the table the rules judged", trueToPlayback)
        t.check("every ball seen dropping goes down the pocket the rules counted", rightPockets)
        t.check("the player's seat only ever puts the cue ball where the rules allow", legalPlacements)
        let contested = plans.filter { $0.mode != .practice && $0.turns == nil }.count
        if whole {
            t.check("finished games are counted",
                    PoolStatistics.load().played.values.reduce(0, +) == playedBefore + wins[0] + wins[1]
                        && wins[0] + wins[1] == contested)
        }
        t.info(String(format: "%d games (player's seat %d, computer's %d), %d shots, through the controller: %.1f s",
                      plans.count, wins[0], wins[1], shots, Date().timeIntervalSince(started)))
        var rates: [PoolDifficulty: (pots: Double, fouls: Double)] = [:]
        for level in PoolDifficulty.allCases {
            guard let tally = levelShots[level], tally.shots > 0 else { continue }
            rates[level] = (Double(tally.pots) / Double(tally.shots), Double(tally.fouls) / Double(tally.shots))
            t.info(String(format: "%@: %d shots, %.0f%% potted, %.0f%% fouls", PoolEngineText.difficulty(level), tally.shots,
                          100 * Double(tally.pots) / Double(tally.shots), 100 * Double(tally.fouls) / Double(tally.shots)))
        }
        if let easy = rates[.easy], let medium = rates[.medium], let hard = rates[.hard] {
            t.check("each level pots more and fouls less than the one below it, and Hard seldom fouls",
                    easy.pots < medium.pots && medium.pots < hard.pots && hard.fouls <= medium.fouls
                        && medium.fouls <= easy.fouls && hard.fouls < 0.1)
        }
    }

    /// What is wrong with the game at rest between turns, if anything.
    private static func problem(in game: PoolGame, numbers: Set<Int>, before: PoolTableState?) -> String? {
        let g = game.geometry, R = g.ballRadius
        let table = game.match.table, rules = game.match.rules
        guard Set(table.balls.map(\.number)) == numbers, table.balls.count == numbers.count else {
            return "balls lost or doubled"
        }
        guard table.isAtRest else { return "the balls are still moving" }
        let onCloth = table.balls.filter { $0.pocket == nil }
        for ball in onCloth {
            // A ball may stop in a pocket's jaws, a little past the rail's line.
            guard ball.position.x.isFinite, ball.position.y.isFinite,
                  abs(ball.position.x) < g.length / 2 + 0.06, abs(ball.position.y) < g.width / 2 + 0.06 else {
                return "ball \(ball.number) is off the table"
            }
        }
        for (i, a) in onCloth.enumerated() {
            for b in onCloth[(i + 1)...] where simd_distance(a.position, b.position) < 2 * R - 1e-6 {
                return "balls \(a.number) and \(b.number) overlap"
            }
        }
        if let before {
            // A ball once down stays down, but for the eight or the nine
            // spotted again.
            let down = Set(before.balls.filter { $0.number != 0 && $0.pocket != nil }.map(\.number))
            let back = down.filter { table.ball($0)?.pocket == nil }
            if !back.isSubset(of: [8, 9]) { return "ball \(back.sorted()) came back out of a pocket" }
        }
        guard (0...1).contains(rules.shooter) else { return "nobody is to shoot" }
        if game.match.options.mode == .eightBall {
            let groups = rules.groups
            guard groups.count == 2, (groups[0] == nil) == (groups[1] == nil), groups[0] == nil || groups[0] != groups[1] else {
                return "the groups do not add up"
            }
        }
        if rules.ballInHand != nil && rules.lastFoul == nil && !rules.isBreakShot && !game.match.isPractice {
            return "ball in hand without a foul"
        }
        if game.match.isOver {
            guard game.phase == .over else { return "the game ended but play goes on" }
            let deciding = game.match.options.mode == .nineBall ? 9 : 8
            guard table.ball(deciding)?.pocket != nil else { return "the game ended with the \(deciding) on the cloth" }
        } else {
            guard game.phase == .aiming, game.isPlayersTurn else { return "the turn stopped at \(game.phase)" }
            guard table.cueBall?.pocket == nil else { return "there is no cue ball to play" }
        }
        return nil
    }

    /// Nothing ticks unless the game is in front; a shot struck while it is
    /// away waits, and plays out from the same instant when it comes back.
    private static func energy(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        game.runsSynchronously = false
        let before = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = before }
        t.check("at rest, nothing runs", !game.clock.isRunning)
        game.shootAtArmedPower()
        // The engine works the shot out on a background queue.
        let deadline = Date().addingTimeInterval(5)
        while game.pendingResult == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        t.check("the shot is worked out off the main thread and handed back", game.pendingResult != nil)
        t.check("while the game is not in front, no frames run", !game.clock.isRunning)
        game.gameDidBecomeActive()
        t.check("in front, the frame clock runs while the shot is under way", game.clock.isAllowed && game.needsFrames)
        game.gameWillResignActive()
        t.check("and stops the moment the game leaves", !game.clock.isRunning && !game.clock.isAllowed
                    && game.scheduler.isSuspended)
        // Drive the frames by hand — each the longest step the clock ever
        // takes: the stroke lands, the balls roll, the shot finishes.
        var frames = 0
        while (game.phase == .striking || game.phase == .rolling) && frames < 2000 {
            _ = game.frame(1.0 / 20)
            frames += 1
            if game.phase == .striking, game.pendingResult == nil, game.playback == nil, game.tweens.isEmpty { break }
        }
        t.check("frame by frame the shot plays out and comes to rest (\(frames) frames)", game.playback == nil
                    && game.phase != .rolling)
        game.gameDidBecomeActive()
        game.gameWillResignActive()
        t.check("balanced start and stop leave nothing running", !game.clock.isRunning)
    }

    /// The computer's turn as it really runs: deciding on a background
    /// queue, waiting while the game is away, then carrying the cue ball
    /// over with ball in hand, lining up, striking and playing out frame by
    /// frame — the very stroke it decided, from the very spot it chose.
    private static func computerInRealTime(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        game.runsSynchronously = false
        let before = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = before }
        var options = PoolOptions()
        options.difficulty = .easy
        game.startNewGame(options, breaker: PoolSeat.you)
        // The player has just scratched; the turn begins while the game is
        // away (as after a launch): the decision may come back, but nothing
        // is played.
        game.match.table = PoolScenarios.midGame()
        game.match.rules.isBreakShot = false
        game.match.rules.groups = [.solids, .stripes]
        game.match.rules.shooter = PoolSeat.computer
        game.match.rules.ballInHand = .anywhere
        game.match.rules.lastFoul = .scratch
        game.table.apply(table: game.match.table)
        let table = game.match.table
        game.gameDidBecomeActive()
        game.gameWillResignActive()
        game.beginTurn(announce: false)
        let deadline = Date().addingTimeInterval(20)
        while game.decision == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let decision = game.decision, decision.placement != nil else {
            t.check("the computer decides off the main thread, with ball in hand", false)
            return
        }
        t.check("the computer decides off the main thread, and while the game is away it waits",
                game.phase == .thinking && !game.clock.isRunning && game.scheduler.isSuspended)
        // What it decided, worked out here independently.
        var start = table
        if let spot = decision.placement, var cue = start.cueBall {
            cue.position = spot
            start.cueBall = cue
        }
        let expected = PoolPhysics.simulate(decision.shot, from: start, geometry: game.geometry, record: false)
        var played: PoolShotResult?
        game.shotObserver = { result, _, _ in if played == nil { played = result } }
        defer { game.shotObserver = nil }

        // Back in front. The frames are driven by hand, so the display link
        // is kept out of it; each is the longest step the clock ever takes.
        game.gameDidBecomeActive()
        game.clock.isAllowed = false
        var frames = 0
        while !(game.match.isOver || (game.isPlayersTurn && game.phase == .aiming)) && frames < 3000 {
            game.scheduler.runPendingImmediately()
            _ = game.frame(1.0 / 20)
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            frames += 1
        }
        t.check("back in front, it lines up, strikes, and the turn comes round (\(frames) frames)",
                game.match.isOver || (game.isPlayersTurn && game.phase == .aiming))
        t.check("the stroke played is the one decided, from the spot chosen",
                played.map { $0.final == expected.final && $0.firstContact == expected.firstContact } ?? false)
        game.gameWillResignActive()
    }

    // MARK: Leaving mid-shot, new games, the mouse held

    /// Waits (the engine works on a background queue) and then steps frames
    /// until `done`, at most `limit` of them.
    private static func drive(_ game: PoolGame, frames limit: Int = 600, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        var frames = 0
        while !done() && frames < limit && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            game.scheduler.runPendingImmediately()
            _ = game.frame(1.0 / 60)
            frames += 1
        }
    }

    /// SceneKit projects points only once its view has drawn: draws it
    /// once, off screen, and puts the badges where they belong.
    private static func drawOnce(_ game: PoolGame) {
        _ = game.sceneView.snapshot()
        game.applyCamera()
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in game: PoolGame) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: game.view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)
    }

    /// A win the rules have decided is never thrown away by a new game —
    /// while the balls roll, or even before they start — and a new game
    /// begins clean: no Rematch while a shot is out, the cue whole again,
    /// a carried cue ball put down when the window goes, no frames for a
    /// mouse held still, VoiceOver's power the power shot.
    private static func leavingMidShot(_ t: TestReporter) {
        let before = TabletopEnvironment.animationsOverride
        TabletopEnvironment.animationsOverride = true
        defer { TabletopEnvironment.animationsOverride = before }
        let rematch = NSMenuItem(title: "", action: #selector(PoolGame.rematch(_:)), keyEquivalent: "r")

        for (label, waitForRolling) in [("rolling", true), ("the cue still going through", false)] {
            let (game, window) = makeGame()
            _ = window
            game.runsSynchronously = false
            game.clock.isAllowed = false
            let stats = PoolStatistics.load()
            func total(_ s: PoolStatistics) -> (games: Int, wins: Int) {
                (PoolDifficulty.allCases.map(s.games).reduce(0, +), PoolDifficulty.allCases.map(s.wins).reduce(0, +))
            }
            PoolScenarios.playWinningEight(game)
            if waitForRolling {
                drive(game) { game.phase == .rolling && (game.playback?.time ?? 0) > 0.5 }
            }
            let decided = game.phase == .rolling || game.phase == .striking
            t.check("Rematch is off while a shot is out on the cloth (\(label))",
                    decided && !game.validateMenuItem(rematch))
            game.startNewGame(game.match.options, breaker: PoolSeat.computer)
            let after = PoolStatistics.load()
            t.check("a new game started with the winning eight \(label) records the win, not a loss",
                    total(after).wins == total(stats).wins + 1 && total(after).games == total(stats).games + 1)
            t.check("…and the new game's cue is whole (opacity \(game.table.cue.node.opacity))",
                    game.table.cue.node.opacity == 1 && !game.resultShowing && !game.isShotInFlight)
        }

        // Carrying the cue ball when the window goes: it is put down where
        // it last could be, and the red stand-in goes.
        let (game, window) = makeGame()
        _ = window
        var options = PoolOptions()
        options.hasAimed = true
        options.hasShot = true
        game.startNewGame(options, breaker: PoolSeat.you)
        game.view.layoutSubtreeIfNeeded()
        drawOnce(game)
        if let cue = game.match.table.cueBall,
           let at = game.sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: game.geometry.ballRadius)),
           let down = mouse(.leftMouseDown, at: at, in: game) {
            game.poolMouseDown(down, at: at)
            let placing = game.drag == .placing
            // Past the head string, where a break's ball in hand may not go.
            let far = game.sceneView.screenPoint(of: PoolSpace.sceneSIMD([0.4, 0], height: game.geometry.ballRadius)) ?? at
            if let move = mouse(.leftMouseDragged, at: far, in: game) { game.poolMouseDragged(move, at: far) }
            let denied = !game.table.placementGhost.isHidden && !game.table.placementDeny.isHidden
            game.gameDidBecomeActive()
            game.gameWillResignActive()
            let tidy = game.drag == .none && game.table.placementGhost.isHidden && game.table.placementDeny.isHidden
                && game.table.placementRing.isHidden && !game.table.cue.node.isHidden
                && game.match.table.cueBall.map { game.geometry.kitchenContains($0.position) } == true
            t.check("leaving mid-drag puts the carried cue ball down in the kitchen and clears the red stand-in",
                    placing && denied && tidy)
        } else {
            t.check("leaving mid-drag puts the carried cue ball down", false)
        }

        // The mouse held still asks for no frames.
        game.runsSynchronously = false
        game.redrawFrames = 0
        game.rig.set(game.rig.goal, immediately: true)
        let centre = CGPoint(x: game.sceneView.bounds.midX, y: game.sceneView.bounds.maxY * 0.7)
        if let down = mouse(.leftMouseDown, at: centre, in: game) { game.poolMouseDown(down, at: centre) }
        var wanted = 0
        for _ in 0..<120 where game.frame(1.0 / 60) { wanted += 1 }
        t.check("a mouse held still on the table asks for no frames (\(wanted) of 120)", game.drag == .orbit && wanted <= 3)
        if let up = mouse(.leftMouseUp, at: centre, in: game) { game.poolMouseUp(up, at: centre) }

        // VoiceOver: the meter's steps are the shot's strength.
        let armed = game.armedPower
        let stepped = game.powerMeter.accessibilityPerformIncrement()
        t.check("VoiceOver's increment on Power changes the strength Shoot uses (\(armed) → \(game.armedPower))",
                stepped && abs(game.armedPower - min(1, armed + 0.05)) < 1e-9 && game.powerMeter.armedPower == game.armedPower)
        game.match.rules.shooter = PoolSeat.computer
        game.phase = .thinking
        game.refreshHUD()
        t.check("…and does nothing on the computer's turn", !game.powerMeter.accessibilityPerformIncrement())
        game.runsSynchronously = true
    }

    // MARK: The HUD

    /// The first-time hints come and go; a finished game offers what next
    /// once, not twice; the plates always have a second line.
    private static func hudAndHints(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        // Practice: the shot leaves the turn with the player.
        var practice = PoolOptions()
        practice.mode = .practice
        game.startNewGame(practice, breaker: PoolSeat.you)
        game.options.hasAimed = false
        game.options.hasShot = false
        game.setViewMode(.aim, animated: false)
        drawOnce(game)
        t.check("a new player is shown how to aim first", game.aimHint != nil && game.shootHint == nil)
        game.learned(aimed: true)
        t.check("having aimed, that hint goes and stays gone, and how to shoot is shown",
                game.aimHint == nil && game.shootHint != nil
                    && Storage.load(PoolOptions.self, from: PoolGame.optionsName)?.hasAimed == true)
        game.shootAtArmedPower()
        t.check("having shot, so does the other",
                game.shootHint == nil && Storage.load(PoolOptions.self, from: PoolGame.optionsName)?.hasShot == true)
        game.startNewGame(game.match.options, breaker: PoolSeat.you)
        t.check("a rematch keeps what the hints taught", game.options.hasAimed && game.options.hasShot)

        game.startNewGame(PoolOptions(), breaker: PoolSeat.you)
        t.check("before the break both plates have a second line",
                !game.youPlate.seat.detail.isEmpty && !game.computerPlate.seat.detail.isEmpty)

        PoolScenarios.playWinningEight(game)
        t.check("a won game: the banner offers what next, the action bar stays empty, the stroke controls go",
                game.match.isOver && game.resultShowing && game.actionBar.isHidden && game.powerMeter.isHidden
                    && game.spinControl.isHidden && game.youPlate.seat.detail == NSLocalizedString("Winner", comment: ""))
        Banner.banners(in: game.root).forEach { $0.dismiss(animated: false) }
        t.check("…and once the banner has gone, the bar offers it instead",
                !game.resultShowing && !game.actionBar.isHidden)
    }

    // MARK: Framing

    /// What each camera shows, projected exactly: the aim view's object
    /// ball is never behind the cue, however steeply it is raised; a shot's
    /// balls stay inside the HUD from first moment to last; the thinking
    /// view frames the whole table; the lamp never stands in front of the
    /// cloth.
    private static func framing(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        var options = PoolOptions()
        options.hasAimed = true
        options.hasShot = true
        game.startNewGame(options, breaker: PoolSeat.you)
        let viewport = game.viewportSize
        let insets = game.hudInsets
        let R = game.geometry.ballRadius
        func inside(_ p: CGPoint?, margin: Double = 0) -> Bool {
            guard let p else { return false }
            return Double(p.x) >= insets.left - margin && Double(p.x) <= Double(viewport.width) - insets.right + margin
                && Double(p.y) >= insets.top - margin && Double(p.y) <= Double(viewport.height) - insets.bottom + margin
        }

        // The cue ball against a cushion, in a corner, with a ball right
        // behind it, and in the open.
        let layouts: [(String, SIMD2<Double>?, Bool)] = [
            ("in the open", nil, false), ("frozen to the head cushion", [-1.2410, 0.1], false),
            ("in a corner", [-1.20, -0.57], false), ("with a ball right behind it", nil, true),
        ]
        var covered: [String] = []
        for (name, spot, behind) in layouts {
            var table = PoolScenarios.midGame()
            if let spot { PoolScenarios.move(&table, 0, to: spot) }
            PoolScenarios.setUp(game, table: table, shooter: PoolSeat.you, ballInHand: nil)
            PoolScenarios.aim(game, at: 3, into: 3)
            if behind, let cue = game.match.table.cueBall {
                PoolScenarios.move(&game.match.table, 12, to: cue.position - PoolSpace.tableDirection(game.aim) * (2 * R + 0.004))
                game.table.apply(table: game.match.table)
            }
            game.setViewMode(.aim, animated: false)
            let pose = game.aimPose()
            guard let object = game.match.table.ball(3),
                  let ball = PoolFraming.project(PoolSpace.sceneDouble(object.position, height: R), from: pose, viewport: viewport),
                  let edge = PoolFraming.project(PoolSpace.sceneDouble(object.position, height: 2 * R), from: pose,
                                                 viewport: viewport) else {
                covered.append("\(name): the object ball is behind the camera")
                continue
            }
            let radius = abs(Double(edge.y - ball.y))
            // Along the cue as drawn, tip to butt.
            let tip = SIMD3<Double>(game.table.cue.node.simdWorldPosition)
            let along = -SIMD3<Double>(game.table.cue.node.simdWorldFront)
            var nearest = Double.infinity
            for k in 0...60 {
                let p = tip + along * (game.table.cue.length * Double(k) / 60)
                guard let q = PoolFraming.project(p, from: pose, viewport: viewport) else { continue }
                nearest = min(nearest, hypot(Double(q.x - ball.x), Double(q.y - ball.y)))
            }
            if nearest < radius + 8 { covered.append("\(name): the cue passes \(Int(nearest)) pt from the object ball") }
            if !inside(ball, margin: 20) { covered.append("\(name): the object ball is outside the picture's free area") }
        }
        t.check("from behind the cue ball the object ball is in view and clear of the cue, even with the cue raised"
                    + (covered.isEmpty ? "" : " (\(covered.joined(separator: "; ")))"), covered.isEmpty)

        // A break, start to finish, from the camera that follows it.
        game.startNewGame(options, breaker: PoolSeat.you)
        if let cue = game.match.table.cueBall {
            let apex = PoolScenarios.apexBall(game)
            game.aim = atan2(apex.y - cue.position.y, apex.x - cue.position.x)
            game.setViewMode(.aim, animated: false)
            let shot = PoolShot(aim: game.aim, power: PoolGame.breakPower, tipVertical: -0.15, isBreak: true)
            let result = PoolPhysics.simulate(shot, from: game.match.table, geometry: game.geometry, record: true)
            if let trajectory = result.trajectory {
                let pose = game.shotPose(for: trajectory)
                var outside = 0, points = 0
                for track in trajectory.tracks where track.keys.count > 1 {
                    for key in track.keys {
                        points += 1
                        let p = PoolFraming.project(PoolSpace.sceneDouble(key.position, height: R), from: pose, viewport: viewport)
                        if !inside(p, margin: 1) { outside += 1 }
                    }
                }
                t.check("a break stays inside the HUD from its first moment to its last (\(points - outside) of \(points) positions)",
                        outside == 0 && points > 100)
            }
        }

        // The computer thinking: the whole table in frame.
        game.match.rules.isBreakShot = false
        game.match.rules.shooter = PoolSeat.computer
        game.showThinking()
        let watch = game.watchPose()
        let d = game.table.dimensions
        let corners = [SIMD2(d.outerX, d.outerY), SIMD2(-d.outerX, d.outerY), SIMD2(d.outerX, -d.outerY), SIMD2(-d.outerX, -d.outerY)]
        t.check("the view while the computer thinks frames the whole table inside the HUD",
                corners.allSatisfy { inside(PoolFraming.project(PoolSpace.sceneDouble($0, height: d.railTop), from: watch,
                                                                viewport: viewport), margin: 1) })
        // The lamp: out of the way from above, hanging in view from low down
        // beyond the table.
        t.check("the lamp steps aside wherever it would stand in front of the cloth, and hangs in view where it would not",
                game.table.lampVisibility(from: game.topPose().position) == 0
                    && game.table.lampVisibility(from: [-4.0, 0.55, 0]) > 0.99
                    && game.table.lampVisibility(from: [0, 0.9, 0.1]) == 0)
    }

    private static func snapshot(_ t: TestReporter) {
        let (game, window) = makeGame()
        _ = window
        TabletopEnvironment.isRenderingSnapshot = true
        defer { TabletopEnvironment.isRenderingSnapshot = false }
        game.prepareForScreenshot(scenario: "top")
        let size = CGSize(width: 600, height: 400)
        game.view.frame = CGRect(origin: .zero, size: size)
        game.view.layoutSubtreeIfNeeded()
        let image = game.snapshotImage(size: size)
        t.check("the table photographs itself off screen at 2× (\(image?.width ?? 0)×\(image?.height ?? 0))",
                image?.width == 1200 && image?.height == 800)
        if let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            // The middle of the top view is cloth, lit: green over red.
            let i = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
            let b = Double(bytes[i]), g = Double(bytes[i + 1]), r = Double(bytes[i + 2])
            t.check("and the cloth is there in the picture (r \(Int(r)) g \(Int(g)) b \(Int(b)))", g > r + 30 && g > 60)
        }
        t.check("the screenshot scenarios are the ones promised, named the kit's way",
                PoolGame.screenshotScenarios == ["break", "aim", "top", "ball-in-hand", "placing", "result", "rolling",
                                                 "thinking", "rail", "corner", "ball-behind"]
                    && PoolGame.screenshotScenarios.allSatisfy { $0 == $0.lowercased() && !$0.contains(" ") })
    }
}
