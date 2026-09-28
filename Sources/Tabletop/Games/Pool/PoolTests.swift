//
//  PoolTests.swift
//  Pool's checks, for `Tabletop --selftest pool`.
//
//  The engine's own tests come first (`PoolEngineTests`, in Engine/). Then
//  the presentation's: that the table drawn is the table the engine plays
//  on, that the textures read the right way round, that the camera settles,
//  that a game saves and comes back, and that the controller plays whole
//  games against itself, stops everything that ticks when it leaves the
//  screen, and photographs itself.
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
            let top = (0..<32).flatMap { y in (0..<64).map { seven.values[y * 64 + $0] } }.reduce(0, +)
            let bottom = (32..<64).flatMap { y in (0..<64).map { seven.values[y * 64 + $0] } }.reduce(0, +)
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
            t.check("a save without a readable table is not resumed",
                    broken.flatMap { try? JSONDecoder().decode(PoolSavedGame.self, from: $0) } == nil)
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

        // Whole games, the player's shots chosen by the engine's own
        // computer player: the turn must always come back to someone, the
        // balls must all be accounted for, and the game must end.
        let gamesStarted = Date()
        var endedGames = 0
        var conserved = true
        var stuck = false
        // Nine-ball to the end; eight-ball for its first dozen shots — enough
        // to cross the break, the open table and the first groups, inside
        // the few seconds a debug self-test may take.
        for (index, (mode, limit)) in [(PoolMode.nineBall, 120), (.eightBall, 12)].enumerated() {
            var options = PoolOptions()
            options.mode = mode
            options.difficulty = .hard
            game.startNewGame(options, breaker: PoolSeat.you)
            let count = game.match.table.balls.count
            var shots = 0
            while !game.match.isOver && shots < limit {
                guard game.phase == .aiming, game.isPlayersTurn else { stuck = true; break }
                let decision = PoolAI.decide(table: game.match.table, rules: game.match.rules, difficulty: .hard,
                                             seed: UInt64(shots + index * 1000))
                if let spot = decision.placement, game.playerHasBallInHand { game.moveCueBall(to: spot) }
                game.aim = decision.shot.aim
                game.setSpin(side: decision.shot.tipSide, vertical: decision.shot.tipVertical)
                game.strike(decision.shot)
                shots += 1
                if game.match.table.balls.count != count { conserved = false }
                let onCloth = game.match.table.balls.filter { $0.pocket == nil }
                if onCloth.contains(where: { abs($0.position.x) > 1.3 || abs($0.position.y) > 0.66 }) { conserved = false }
            }
            if mode == .nineBall && game.match.isOver { endedGames += 1 }
        }
        t.check("the turn always comes back to the player or the game ends", !stuck)
        t.check("every ball is on the cloth or in a pocket, all game long", conserved)
        t.check("a game against the computer comes to an end", endedGames == 1)
        t.info(String(format: "a game and a dozen shots through the controller: %.1f s", Date().timeIntervalSince(gamesStarted)))
        t.check("finished games are counted", PoolStatistics.load().played.values.reduce(0, +) >= endedGames)

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

        energy(t)
        snapshot(t)
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
        // Drive the frames by hand: the stroke lands, the balls roll, the
        // shot finishes.
        var frames = 0
        while (game.phase == .striking || game.phase == .rolling) && frames < 4000 {
            _ = game.frame(1.0 / 60)
            frames += 1
            if game.phase == .striking, game.pendingResult == nil, game.playback == nil, game.tweens.isEmpty { break }
        }
        t.check("frame by frame the shot plays out and comes to rest (\(frames) frames)", game.playback == nil
                    && game.phase != .rolling)
        game.gameDidBecomeActive()
        game.gameWillResignActive()
        t.check("balanced start and stop leave nothing running", !game.clock.isRunning)
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
        t.check("the screenshot scenarios are the ones promised",
                PoolGame.screenshotScenarios == ["break", "aim", "top", "ballInHand", "result", "rolling"])
    }
}
