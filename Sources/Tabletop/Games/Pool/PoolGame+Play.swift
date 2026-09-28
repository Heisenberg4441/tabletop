//
//  PoolGame+Play.swift
//  The turn, from lining up to the rules' verdict — the player's and the
//  computer's.
//
//  A shot goes: the cue is drawn back (charging), goes through (striking,
//  while the engine works the whole shot out on a background queue), the
//  balls roll it out exactly as the engine recorded it (rolling), and at
//  rest the rules decide what it meant. The verdict is known the moment the
//  simulation is, so a game left mid-shot is saved as the shot will end.
//
//  The computer's turn goes: it thinks (the engine's `PoolAI` on a
//  background queue, and never less than a moment, so it reads as thought),
//  then plays like a person — carries the cue ball over if it has ball in
//  hand, swings its cue round onto the line, draws back, pauses, strikes.
//

import AppKit
import simd

extension PoolGame {

    var isPlayersTurn: Bool { !match.isOver && !match.shooterIsComputer && (phase == .aiming || phase == .charging) }

    /// The player may pick the cue ball up and put it somewhere else.
    var playerHasBallInHand: Bool { isPlayersTurn && match.rules.ballInHand != nil }

    var geometry: PoolTableGeometry { table.geometry }

    // MARK: Turns

    /// Picks the game up where a save left it.
    func resumeTurn() {
        if match.isOver {
            phase = .over
        }
        ensureCueBallOnTable()
        beginTurn(announce: false)
    }

    func beginTurn(announce: Bool) {
        drag = .none
        armPowerForTurn()
        if match.isOver {
            phase = .over
            cueVisible = false
            refreshAim()
            setCamera(topPose(), animated: true)
            refreshHUD()
            return
        }
        ensureCueBallOnTable()
        if match.shooterIsComputer {
            beginComputerTurn()
        } else {
            beginPlayerTurn(announce: announce)
        }
    }

    private func beginPlayerTurn(announce: Bool) {
        phase = .aiming
        cueVisible = true
        cuePull = 0
        if let spin = playerSpin {
            playerSpin = nil
            tipSide = spin.side
            tipVertical = spin.vertical
            spinControl.set(side: spin.side, vertical: spin.vertical)
        }
        if announce {
            let text: String
            if match.rules.isBreakShot {
                text = NSLocalizedString("Your break", comment: "pool toast")
            } else if match.rules.ballInHand != nil {
                text = NSLocalizedString("Ball in hand", comment: "pool toast: you may place the cue ball")
            } else {
                text = NSLocalizedString("Your turn", comment: "pool toast")
            }
            toast(text, symbol: "arrowtriangle.right.fill")
        }
        if viewMode == .aim { setCamera(aimPose(), animated: true) } else { setCamera(topPose(), animated: true) }
        refreshAim()
        refreshHUD()
    }

    private func beginComputerTurn() {
        phase = .thinking
        cueVisible = false
        decision = nil
        thinkingTimeUp = false
        guides(hidden: true)
        setCamera(watchPose(), animated: true)
        refreshAim()
        refreshHUD()

        let gen = generation
        let table = match.table, rules = match.rules, difficulty = match.options.difficulty, seed = match.decisionSeed
        let geometry = self.geometry
        if runsSynchronously {
            decision = PoolAI.decide(table: table, rules: rules, difficulty: difficulty, seed: seed, geometry: geometry)
            thinkingTimeUp = true
            proceedWithComputerTurn()
            return
        }
        // The decision is pure and Sendable; the answer comes back to the
        // main thread and waits there, if the game has been left meanwhile,
        // until the scheduler is running again. It cannot be interrupted, so
        // an answer for a game that has since been replaced is dropped.
        DispatchQueue.global(qos: .userInitiated).async {
            let choice = PoolAI.decide(table: table, rules: rules, difficulty: difficulty, seed: seed, geometry: geometry)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation, self.phase == .thinking else { return }
                    self.decision = choice
                    self.proceedWithComputerTurn()
                }
            }
        }
        scheduler.after(Motion.isEnabled ? 1.1 : 0.6) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.thinkingTimeUp = true
            self.proceedWithComputerTurn()
        }
    }

    func resumeComputerTurn() { proceedWithComputerTurn() }

    /// The computer's turn as it looks while it thinks, without asking it
    /// anything — for a screenshot.
    func showThinking() {
        armPowerForTurn()
        phase = .thinking
        cueVisible = false
        guides(hidden: true)
        setCamera(watchPose(), animated: false)
        refreshAim()
        refreshHUD()
    }

    private func proceedWithComputerTurn() {
        guard phase == .thinking, thinkingTimeUp, let decision, !scheduler.isSuspended || runsSynchronously else { return }
        playComputerShot(decision)
    }

    /// The computer plays `decision` the way a person would.
    private func playComputerShot(_ decision: PoolAIDecision) {
        phase = .computerLining
        refreshHUD()
        let gen = generation
        let shot = decision.shot
        let startAim = aim

        func lineUp() {
            guard gen == generation else { return }
            cueVisible = true
            cuePull = 0.05
            if playerSpin == nil { playerSpin = (tipSide, tipVertical) }
            tipSide = shot.tipSide
            tipVertical = shot.tipVertical
            spinControl.set(side: shot.tipSide, vertical: shot.tipVertical)
            // Swing onto the line from a little off it, the camera following.
            let delta = atan2(sin(shot.aim - startAim), cos(shot.aim - startAim))
            let from = abs(delta) > 0.5 ? shot.aim - 0.35 * (delta > 0 ? 1 : -1) : startAim
            aim = from
            setCamera(naturalPose(), animated: true)
            refreshAim()
            addTween(PoolTween(duration: 1.0, update: { [weak self] t in
                guard let self else { return }
                let d = atan2(sin(shot.aim - from), cos(shot.aim - from))
                self.aim = from + d * t
                // The camera follows the swing — unless the player is
                // watching from above.
                self.rig.set(self.naturalPose(), immediately: false)
                self.refreshAim()
            }, completion: { drawBack() }), decorative: true)
        }
        func drawBack() {
            guard gen == generation else { return }
            aim = shot.aim
            let target = 0.03 + shot.power * 0.20
            let start = cuePull
            addTween(PoolTween(duration: 0.75, update: { [weak self] t in
                self?.cuePull = start + (target - start) * t
                self?.refreshAim()
            }, completion: { [weak self] in
                guard let self, gen == self.generation else { return }
                if self.runsSynchronously || !Motion.isEnabled {
                    self.strike(shot)
                } else {
                    self.scheduler.after(0.28) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.strike(shot)
                    }
                }
            }), decorative: true)
        }

        if let spot = computerPlacement(decision) {
            // Carry the cue ball to where the computer wants it — lifted
            // over whatever lies between, as a hand would — and set it down
            // exactly there: the stroke was chosen for that spot.
            let from = match.table.cueBall?.position ?? geometry.headSpot
            let height = min(0.08, 0.02 + simd_distance(from, spot) * 0.05)
            addTween(PoolTween(duration: 0.7, update: { [weak self] t in
                guard let self else { return }
                self.moveCueBall(to: from + (spot - from) * t)
                self.table.balls[0]?.lift(height * sin(.pi * t))
            }, completion: { [weak self] in
                self?.moveCueBall(to: spot)
                lineUp()
            }), decorative: true)
        } else {
            lineUp()
        }
    }

    /// Where the computer's cue ball goes before its stroke: its own choice
    /// when the rules give it ball in hand and allow that spot, the nearest
    /// allowed spot otherwise, and nowhere without ball in hand.
    func computerPlacement(_ decision: PoolAIDecision) -> SIMD2<Double>? {
        guard match.rules.ballInHand != nil, let spot = decision.placement else { return nil }
        return isAllowedPlacement(spot) ? spot : placementSpot(near: spot)
    }

    /// Whether the rules let the cue ball be put down at `point` now.
    func isAllowedPlacement(_ point: SIMD2<Double>) -> Bool {
        PoolRules.isValidPlacement(point, match.rules, table: match.table, geometry: geometry)
    }

    /// A break wants a full stroke — the meter's usual middle is barely a
    /// quarter of a break's pace — so one is armed for the player's break,
    /// and their own strength comes back as soon as the break is over.
    func armPowerForTurn() {
        if match.rules.isBreakShot && !match.shooterIsComputer && !match.isOver {
            if powerBeforeBreak == nil { powerBeforeBreak = armedPower }
            armedPower = Self.breakPower
        } else if let before = powerBeforeBreak {
            powerBeforeBreak = nil
            armedPower = before
        }
        powerMeter.armedPower = armedPower
    }

    static let breakPower = 0.92

    // MARK: Charging and shooting

    func beginCharge(_ source: ChargeSource) {
        guard isPlayersTurn, phase == .aiming else { return }
        drag = .none
        phase = .charging
        chargeSource = source
        chargePower = 0
        powerMeter.chargingPower = 0
        cueVisible = true
        refreshAim()
        refreshHUD()
        if source == .keyboard { requestFrames() }
    }

    func updateCharge(_ power: Double) {
        guard phase == .charging else { return }
        chargePower = max(0, min(1, power))
        powerMeter.chargingPower = chargePower
        cuePull = 0.012 + chargePower * 0.22
        refreshAim()
    }

    /// The pull is over: shoot at the strength reached, or call it off.
    func endCharge(shoot: Bool) {
        guard phase == .charging else { return }
        let power = chargePower
        chargeSource = nil
        powerMeter.chargingPower = nil
        if shoot && power > 0.02 {
            armedPower = power
            powerMeter.armedPower = power
            strike(PoolShot(aim: aim, power: power, tipSide: tipSide, tipVertical: tipVertical))
        } else {
            cancelCharge()
        }
    }

    func cancelCharge() {
        guard phase == .charging else { return }
        phase = .aiming
        chargeSource = nil
        powerMeter.cancel()
        powerMeter.chargingPower = nil
        cuePull = 0
        refreshAim()
        refreshHUD()
    }

    /// Shoot at the armed strength — the Shoot button and Return.
    func shootAtArmedPower() {
        guard isPlayersTurn, phase == .aiming else { return }
        cuePull = 0.012 + armedPower * 0.22
        strike(PoolShot(aim: aim, power: armedPower, tipSide: tipSide, tipVertical: tipVertical))
    }

    /// The cue goes through `shot`. The engine works it out meanwhile; the
    /// balls start moving when both are done.
    func strike(_ shot: PoolShot) {
        guard match.table.cueBall.map({ $0.pocket == nil }) ?? false else { return }
        phase = .striking
        drag = .none
        guides(hidden: true)
        table.kitchen.isHidden = true
        table.placementGhost.isHidden = true
        table.placementRing.isHidden = true
        hideBallInHandBadge()
        refreshHUD()
        pendingResult = nil
        strokeLanded = false
        let gen = generation
        let before = match.table

        if runsSynchronously {
            pendingResult = PoolPhysics.simulate(shot, from: before, geometry: geometry, record: true)
        } else {
            let geometry = self.geometry
            DispatchQueue.global(qos: .userInitiated).async {
                let result = PoolPhysics.simulate(shot, from: before, geometry: geometry, record: true)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard gen == self.generation, self.phase == .striking else { return }
                        self.pendingResult = result
                        self.startPlaybackIfReady()
                    }
                }
            }
        }
        // The stroke: quick for a hard shot, gentler for a touch.
        let from = max(cuePull, 0.03)
        let duration = 0.10 + 0.16 * (1 - shot.power)
        addTween(PoolTween(duration: duration, curve: PoolTween.easeIn, update: { [weak self] t in
            self?.cuePull = from * (1 - t)
            self?.refreshAim()
        }, completion: { [weak self] in
            guard let self, gen == self.generation else { return }
            self.strokeLanded = true
            self.startPlaybackIfReady()
        }), decorative: true)
    }

    private func startPlaybackIfReady() {
        guard phase == .striking, strokeLanded, let result = pendingResult else { return }
        pendingResult = nil
        let outcome = PoolRules.evaluate(result, before: match.table, state: match.rules, geometry: geometry)
        let duration = result.trajectory?.duration ?? 0
        playback = Playback(result: result, outcome: outcome, time: 0, duration: duration)
        phase = .rolling
        // The cue follows through and fades away.
        let pull = cuePull
        addTween(PoolTween(duration: 0.35, curve: PoolTween.easeOut, update: { [weak self] t in
            guard let self else { return }
            self.cuePull = pull - 0.035 * t
            self.table.cue.node.opacity = CGFloat(1 - t)
            self.refreshAim()
        }, completion: { [weak self] in
            guard let self else { return }
            self.cueVisible = false
            self.table.cue.node.opacity = 1
            self.refreshAim()
        }), decorative: true)
        if let trajectory = result.trajectory {
            setCamera(shotPose(for: trajectory, from: Self.firstContactTime(result)), animated: true)
        }
        refreshHUD()
        if runsSynchronously || duration <= 0 {
            finishShot()
        } else {
            requestFrames()
        }
    }

    /// Shows `shot` `time` seconds in, from the camera that follows it, and
    /// changes nothing else — for a screenshot of balls in flight.
    func previewShot(_ shot: PoolShot, at time: Double) {
        let result = PoolPhysics.simulate(shot, from: match.table, geometry: geometry, record: true)
        guard let trajectory = result.trajectory else { return }
        phase = .rolling
        cueVisible = false
        guides(hidden: true)
        hideBallInHandBadge()
        table.apply(poses: trajectory.poses(at: min(time, trajectory.duration)))
        setCamera(shotPose(for: trajectory, from: Self.firstContactTime(result)), animated: false)
        refreshAim()
        refreshHUD()
    }

    /// When the cue ball first meets a ball — or, if it meets none, when
    /// anything first happens to it.
    static func firstContactTime(_ result: PoolShotResult) -> Double {
        result.firstContactTime ?? result.events.first?.time ?? 0
    }

    // MARK: The frame

    /// Everything that moves, advanced by `dt` seconds of real time.
    /// Returns whether anything is still moving.
    func frame(_ dt: Double) -> Bool {
        if !tweens.isEmpty {
            let running = tweens
            tweens.removeAll()
            var carryOn: [PoolTween] = []
            for tween in running where !tween.advance(dt) { carryOn.append(tween) }
            // Completions may have added tweens of their own.
            tweens = carryOn + tweens
        }
        if phase == .charging, chargeSource == .keyboard {
            updateCharge(min(1, chargePower + dt * 0.6))
        }
        if var playback {
            playback.time = min(playback.duration, playback.time + dt)
            self.playback = playback
            if let poses = playback.result.trajectory?.poses(at: playback.time) { table.apply(poses: poses) }
            if playback.time >= playback.duration { finishShot() }
        }
        rig.step(dt)
        applyCamera()
        if redrawFrames > 0 { redrawFrames -= 1 }
        return needsFrames
    }

    var needsFrames: Bool {
        !tweens.isEmpty || playback != nil || (phase == .charging && chargeSource == .keyboard) || !rig.isSettled
            || redrawFrames > 0 || drag != .none
    }

    func requestFrames() {
        guard !runsSynchronously else { return }
        clock.request()
    }

    /// Adds a tween. A decorative one (the cue's stroke, a camera-led swing)
    /// lands at once under Reduce Motion; everything lands at once when the
    /// game runs synchronously.
    func addTween(_ tween: PoolTween, decorative: Bool) {
        if runsSynchronously || (decorative && !Motion.isEnabled) {
            tween.finish()
            return
        }
        tweens.append(tween)
        requestFrames()
    }

    /// Reduce Motion came on: whatever decoration is in flight lands now.
    func settleDecorations() {
        let running = tweens
        tweens.removeAll()
        running.forEach { $0.finish() }
        rig.set(rig.goal, immediately: true)
        applyCamera()
    }

    // MARK: The end of a shot

    /// Plays a rolling shot out at once — the game is quitting.
    func finishPlaybackNow() {
        guard playback != nil else { return }
        finishShot()
    }

    private func finishShot() {
        guard let playback else { return }
        self.playback = nil
        let summary = match.apply(playback.outcome, result: playback.result)
        table.apply(table: match.table)
        shotObserver?(playback.result, playback.outcome, summary.shooter)
        if let run = summary.finishedRun, run > statistics.bestRun {
            statistics.bestRun = run
            statistics.save()
        }
        if let over = summary.gameOver, !match.isPractice {
            statistics.record(win: over.winner == PoolSeat.you, difficulty: match.options.difficulty)
            statistics.save()
        }
        save()
        if match.isOver {
            phase = .over
            refreshHUD()
            showResult(summary)
            beginTurn(announce: false)
            return
        }
        let spoke = announce(summary)
        ensureCueBallOnTable()
        let gen = generation
        let next = { [weak self] in
            guard let self, gen == self.generation else { return }
            if !self.match.shooterIsComputer { self.aim = self.defaultAim() }
            // "Your turn" only when the turn really passed to the player and
            // nothing else has just been said.
            let handedOver = summary.shooter != self.match.rules.shooter && !self.match.shooterIsComputer
            self.beginTurn(announce: handedOver && !spoke)
        }
        // A beat at rest before the next turn begins; nothing can be played
        // during it.
        if runsSynchronously {
            next()
        } else {
            phase = .striking
            refreshHUD()
            scheduler.after(Motion.isEnabled ? 0.45 : 0.2, next)
        }
    }

    /// What the player should hear about a shot, said once: the foul, the
    /// groups, a good pot, a re-spot.
    @discardableResult
    private func announce(_ summary: PoolMatch.Summary) -> Bool {
        let you = summary.shooter == PoolSeat.you
        let name = match.opponentName
        if let foul = summary.foul, !match.isPractice {
            let text = you
                ? String(format: NSLocalizedString("%1$@ — %2$@ has ball in hand", comment: "pool toast: your foul"),
                         PoolEngineText.foul(foul), name)
                : String(format: NSLocalizedString("%@ — ball in hand", comment: "pool toast: the computer's foul"),
                         PoolEngineText.foul(foul))
            toast(text, symbol: "exclamationmark.circle", tint: you ? Palette.negative : Palette.textSecondary)
            return true
        } else if let group = summary.groupAssigned {
            let mine = you ? group : group.opposite
            let text = String(format: NSLocalizedString("You are on %@", comment: "pool toast: your group"),
                              PoolEngineText.group(mine).lowercased(with: .current))
            toast(text, symbol: "circle.lefthalf.filled")
            return true
        } else if let remark = summary.remarks.first {
            toast(remark, symbol: "info.circle")
            return true
        } else if you && summary.pocketed.count >= 2 {
            toast(NSLocalizedString("Nice shot", comment: "pool toast"), symbol: "checkmark.circle")
            return true
        }
        return false
    }

    private func showResult(_ summary: PoolMatch.Summary) {
        guard let over = summary.gameOver else { return }
        let win = over.winner == PoolSeat.you
        let reason = PoolEngineText.gameOver(over.reason, winnerIsYou: win, opponent: match.opponentName)
        Banner.show(
            in: root,
            title: win ? NSLocalizedString("You win", comment: "pool result")
                : String(format: NSLocalizedString("%@ wins", comment: "pool result: the computer won"), match.opponentName),
            subtitle: reason,
            symbolName: win ? "trophy.fill" : "flag.fill",
            tone: win ? .win : .loss,
            actions: [
                ChromeAction(id: "new", title: NSLocalizedString("New Game…", comment: "pool result button")) { [weak self] in
                    self?.presentOptions()
                },
                ChromeAction(id: "rematch", title: NSLocalizedString("Rematch", comment: "pool result button"),
                             style: .primary, keyEquivalent: "\r") { [weak self] in
                    self?.rematch(nil)
                },
            ],
            scheduler: scheduler, verticalPosition: 0.40)
    }

    // MARK: The cue ball

    /// Puts a pocketed or missing cue ball back on the cloth. The rules
    /// already bring it back after a scratch; this only mends a save that
    /// somehow kept it in a pocket, the way the rules would have.
    func ensureCueBallOnTable() {
        guard match.table.cueBall?.pocket != nil || match.table.cueBall == nil else { return }
        let kitchen = match.rules.ballInHand == .kitchen
        PoolRules.placeCueBall(on: &match.table, preferring: kitchen ? PoolRack.breakCueSpot(geometry) : geometry.headSpot,
                               kitchen: kitchen, geometry: geometry)
        table.apply(table: match.table)
    }

    /// The allowed spot nearest `point` that the cue ball can slide to: kept
    /// on the cloth (and behind the head string when the rules say so), and
    /// eased out of any ball it would overlap — so a dragged ball runs along
    /// an obstacle instead of sticking. Nil when nothing near is allowed.
    func slidePlacement(toward point: SIMD2<Double>) -> SIMD2<Double>? {
        let R = geometry.ballRadius
        func clamp(_ p: SIMD2<Double>) -> SIMD2<Double> {
            var q = SIMD2(max(-geometry.length / 2 + R, min(geometry.length / 2 - R, p.x)),
                          max(-geometry.width / 2 + R, min(geometry.width / 2 - R, p.y)))
            if match.rules.ballInHand == .kitchen { q.x = min(q.x, geometry.headStringX - 1e-5) }
            return q
        }
        var p = clamp(point)
        let others = match.table.balls.filter { $0.number != 0 && $0.pocket == nil }
        for _ in 0..<4 {
            if isAllowedPlacement(p) { return p }
            // Out of every ball it overlaps, along the line from its centre.
            for ball in others {
                let d = p - ball.position
                let distance = simd_length(d)
                if distance < 2 * R + 1e-5 {
                    let away = distance > 1e-9 ? d / distance : SIMD2(0, 1)
                    p = ball.position + away * (2 * R + 2e-5)
                }
            }
            p = clamp(p)
        }
        return isAllowedPlacement(p) ? p : nil
    }

    /// The nearest place to `point` the rules allow the cue ball, looking
    /// outwards in rings.
    func placementSpot(near point: SIMD2<Double>) -> SIMD2<Double> {
        if isAllowedPlacement(point) { return point }
        for ring in 1...40 {
            let r = Double(ring) * geometry.ballRadius * 0.6
            for k in 0..<24 {
                let a = Double(k) / 24 * 2 * .pi
                let p = point + SIMD2(cos(a), sin(a)) * r
                if isAllowedPlacement(p) { return p }
            }
        }
        return point
    }

    func moveCueBall(to point: SIMD2<Double>) {
        guard let index = match.table.balls.firstIndex(where: { $0.number == 0 }) else { return }
        match.table.balls[index].position = point
        match.table.balls[index].pocket = nil
        if let node = table.balls[0] { node.place(position: point, orientation: match.table.balls[index].orientation) }
        refreshAim()
    }

    /// Where the player's cue points when a turn starts: at the nearest ball
    /// they may hit first.
    func defaultAim() -> Double {
        guard let cue = match.table.cueBall else { return 0 }
        let legal = PoolRules.legalFirstContacts(match.rules, table: match.table)
        let nearest = match.table.balls
            .filter { legal.contains($0.number) && $0.pocket == nil }
            .min { simd_distance($0.position, cue.position) < simd_distance($1.position, cue.position) }
        guard let target = nearest else { return aim }
        return atan2(target.position.y - cue.position.y, target.position.x - cue.position.x)
    }
}
