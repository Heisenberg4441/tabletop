//
//  PoolScenarios.swift
//  The tables `--shot pool` photographs, set up by hand so each picture is
//  the same every time and says one thing clearly — whatever the engine's
//  physics happen to do on a given break.
//
//    break       the rack, from behind the cue ball, lined up on the apex
//    aim         mid-game, a cut into the corner with the guides and some spin
//    top         the same table from above
//    ballInHand  after the computer's foul: the cue ball ready to be placed
//    result      the eight just dropped, and the result banner
//    rolling     the break a moment after the cue ball arrives, balls in
//                flight, from the camera that follows a shot
//    thinking    the computer's turn: its seat sweeping gold while it
//                decides, the camera watching over its shoulder
//
//  `--pool-at SECONDS` stops the two shots — the break in "rolling", the
//  winning eight in "result" — at that moment of their recorded playback,
//  to look at a ball in flight or dropping into its pocket.
//  `--pool-mode nineBall|practice` racks that game instead of eight-ball
//  for "break" and "rolling".
//
//  Only the engine's public API is used: a rack's balls moved about, a rule
//  state from `newGame` with its fields set, and for the result a real shot
//  played through the real physics and rules.
//

import AppKit
import simd

@MainActor
enum PoolScenarios {

    static func prepare(_ game: PoolGame, scenario: String) {
        var options = PoolOptions()
        options.mode = .eightBall
        if ["break", "rolling"].contains(scenario),
           let mode = TabletopEnvironment.value(of: "--pool-mode").flatMap(PoolMode.init(rawValue:)) {
            options.mode = mode
        }
        options.difficulty = .medium
        options.guides = .long
        game.startNewGame(options, breaker: PoolSeat.you)
        game.aimPitch = 0.30
        game.aimDistance = 1.05
        if scenario != "break" { Toast.hide(in: game.root, animated: false) }

        switch scenario {
        case "aim", "top":
            setUp(game, table: midGame(), shooter: PoolSeat.you, ballInHand: nil)
            aim(game, at: 3, into: 3)
            game.setSpin(side: 0.28, vertical: -0.42)
            game.armedPower = 0.46
            game.powerMeter.armedPower = 0.46
            game.setViewMode(scenario == "top" ? .top : .aim, animated: false)
        case "ballInHand":
            var table = midGame()
            move(&table, 0, to: [-0.35, -0.02])
            setUp(game, table: table, shooter: PoolSeat.you, ballInHand: true)
            aim(game, at: 3, into: 3)
            game.aimPitch = 0.62
            game.aimDistance = 1.55
            game.setViewMode(.aim, animated: false)
        case "result":
            playWinningEight(game, stoppingAt: playbackTime)
        case "thinking":
            var table = midGame()
            move(&table, 0, to: [0.62, 0.30])
            game.match.table = table
            game.match.rules.isBreakShot = false
            game.match.rules.groups = [.solids, .stripes]
            game.match.rules.shooter = PoolSeat.computer
            game.match.rules.ballInHand = nil
            game.table.apply(table: table)
            game.showThinking()
        case "rolling":
            guard let cue = game.match.table.cueBall else { break }
            let apex = apexBall(game)
            let aim = atan2(apex.y - cue.position.y, apex.x - cue.position.x)
            game.aim = aim
            game.previewShot(PoolShot(aim: aim, power: PoolGame.breakPower, tipSide: 0, tipVertical: -0.15),
                             at: playbackTime ?? 0.62)
        default:
            // The break: lined up on the head ball, the break stroke armed.
            if let cue = game.match.table.cueBall {
                let apex = apexBall(game)
                game.aim = atan2(apex.y - cue.position.y, apex.x - cue.position.x)
            }
            game.setViewMode(.aim, animated: false)
        }
        game.refreshAim()
        game.refreshHUD()
        game.applyCamera()
    }

    /// The rack's head ball — the one on the foot spot — where a break aims.
    static func apexBall(_ game: PoolGame) -> SIMD2<Double> {
        let foot = game.geometry.footSpot
        return game.match.table.balls.filter { $0.number != 0 && $0.pocket == nil }
            .min { simd_distance($0.position, foot) < simd_distance($1.position, foot) }?.position ?? foot
    }

    /// `--pool-at`: a moment of a shot's playback to stop at, in seconds.
    static var playbackTime: Double? {
        TabletopEnvironment.value(of: "--pool-at").flatMap(Double.init).map { max(0, $0) }
    }

    // MARK: Tables

    /// Solids against stripes, a dozen shots in: the player (solids) has the
    /// 2, 3 and 6 left, the computer five stripes, the eight near the foot.
    static func midGame() -> PoolTableState {
        var table = PoolRack.eightBall(seed: 11)
        let spots: [Int: SIMD2<Double>] = [
            0: [-0.62, -0.12], 3: [0.30, 0.20], 2: [0.95, -0.38], 6: [-1.02, 0.44], 8: [0.72, -0.05],
            9: [0.05, -0.36], 10: [-0.25, 0.42], 12: [1.08, 0.16], 14: [0.45, -0.50], 15: [-0.22, -0.50],
        ]
        for i in table.balls.indices {
            let n = table.balls[i].number
            table.balls[i].velocity = .zero
            if let p = spots[n] {
                table.balls[i].position = p
                table.balls[i].pocket = nil
            } else {
                pocket(&table.balls[i])
            }
        }
        return table
    }

    /// Down a pocket, where the engine keeps a pocketed ball: at the
    /// pocket's centre, still.
    static func pocket(_ ball: inout PoolBall, _ id: Int = 0) {
        let pockets = PoolTableGeometry.standard.pockets
        let pocket = pockets.first { $0.id == id } ?? pockets[0]
        ball.pocket = pocket.id
        ball.position = pocket.center
        ball.velocity = .zero
        ball.spin = .zero
    }

    static func move(_ table: inout PoolTableState, _ number: Int, to p: SIMD2<Double>) {
        guard let i = table.balls.firstIndex(where: { $0.number == number }) else { return }
        table.balls[i].position = p
        table.balls[i].pocket = nil
    }

    static func setUp(_ game: PoolGame, table: PoolTableState, shooter: Int, ballInHand: Bool?) {
        var rules = PoolRules.newGame(.eightBall, breaker: PoolSeat.you)
        rules.isBreakShot = false
        rules.groups = [.solids, .stripes]
        rules.shooter = shooter
        rules.shotCount = 14
        rules.ballInHand = nil
        if ballInHand == true {
            // What a foul by the computer leaves the player.
            rules.ballInHand = .anywhere
            rules.lastFoul = .wrongBallFirst
            rules.fouls = [0, 1]
        }
        game.match.table = table
        game.match.rules = rules
        game.match.pocketedBy = [[1, 4, 5, 7], [11, 13]]
        game.table.apply(table: table)
        game.beginTurn(announce: false)
    }

    /// Aims the player's cue so ball `number` goes to the pocket with `id`.
    static func aim(_ game: PoolGame, at number: Int, into id: Int) {
        guard let cue = game.match.table.cueBall, let ball = game.match.table.ball(number),
              let pocket = game.geometry.pockets.first(where: { $0.id == id }) else { return }
        let out = simd_normalize(pocket.center - ball.position)
        let ghost = ball.position - out * 2 * game.geometry.ballRadius
        game.aim = atan2(ghost.y - cue.position.y, ghost.x - cue.position.x)
    }

    // MARK: The result

    /// Clears the table down to three stripes and the eight, and has the
    /// player sink the eight — through the engine, so the banner says what
    /// the rules really decided. With a time, the shot is shown at that
    /// moment of its playback instead, before the rules have spoken.
    static func playWinningEight(_ game: PoolGame, stoppingAt time: Double? = nil) {
        var table = PoolRack.eightBall(seed: 11)
        let spots: [Int: SIMD2<Double>] = [
            0: [0.58, 0.18], 8: [0.98, 0.43], 9: [-0.42, -0.30], 12: [-0.95, 0.35], 15: [0.20, -0.44],
        ]
        for i in table.balls.indices {
            let n = table.balls[i].number
            if let p = spots[n] { table.balls[i].position = p; table.balls[i].pocket = nil } else { pocket(&table.balls[i]) }
        }
        setUp(game, table: table, shooter: PoolSeat.you, ballInHand: nil)
        game.match.pocketedBy = [[1, 2, 3, 4, 5, 6, 7], [10, 11, 13, 14]]
        let pocket = game.geometry.pockets.max { $0.center.x + $0.center.y < $1.center.x + $1.center.y }
        let target = pocket?.center ?? [1.3, 0.66]
        guard let eight = game.match.table.ball(8), let cue = game.match.table.cueBall else { return }
        let out = simd_normalize(target - eight.position)
        let ghost = eight.position - out * 2 * game.geometry.ballRadius
        game.aim = atan2(ghost.y - cue.position.y, ghost.x - cue.position.x)
        let shot = PoolShot(aim: game.aim, power: 0.32, tipSide: 0, tipVertical: -0.2)
        if let time {
            game.previewShot(shot, at: time)
        } else {
            game.strike(shot)
        }
    }
}
