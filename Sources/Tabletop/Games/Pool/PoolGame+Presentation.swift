//
//  PoolGame+Presentation.swift
//  What the player sees: where the camera stands, the cue lined up on the
//  cue ball and lifted clear of the rail, the guides on the cloth, and the
//  glass HUD round the edges.
//

import AppKit
import SceneKit
import simd

extension PoolGame {

    // MARK: Camera poses

    /// Behind the cue ball, low, looking along the shot — the view the game
    /// is played from.
    func aimPose() -> PoolCameraPose {
        let R = geometry.ballRadius
        let cue = match.table.cueBall?.position ?? geometry.headSpot
        let ahead = cue + PoolSpace.tableDirection(aim) * (0.26 * aimDistance)
        return PoolCameraPose(focus: [ahead.x, R, -ahead.y], yaw: PoolCameraPose.yaw(forAim: aim),
                              pitch: aimPitch, distance: aimDistance, fieldOfView: 40)
    }

    /// Straight down on the whole table, the long way across the screen,
    /// framed inside the HUD.
    func topPose() -> PoolCameraPose {
        let size = sceneView.bounds.size.width > 10 ? sceneView.bounds.size : CGSize(width: 1200, height: 762)
        let fov = 30.0
        let t = tan(fov / 2 * .pi / 180)
        let aspect = Double(size.width / size.height)
        // Keep clear of the power meter and the spin control at the sides,
        // the players at the top and the action bar at the bottom.
        let side = 158.0, band = 74.0
        let fw = max(0.45, (Double(size.width) - 2 * side) / Double(size.width))
        let fh = max(0.45, (Double(size.height) - 2 * band) / Double(size.height))
        let d = table.dimensions
        let distance = max(d.outerX / (t * aspect * fw), d.outerY / (t * fh))
        return PoolCameraPose(focus: [0, 0, 0], yaw: 0, pitch: .pi / 2, distance: distance, fieldOfView: fov)
    }

    /// High over the computer's shoulder while it thinks.
    func watchPose() -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        let cue = match.table.cueBall?.position ?? geometry.headSpot
        var toCentre = -cue
        if simd_length(toCentre) < 0.2 { toCentre = [1, 0] }
        let a = atan2(toCentre.y, toCentre.x)
        let focus = cue * 0.45
        return PoolCameraPose(focus: [focus.x, 0, -focus.y], yaw: PoolCameraPose.yaw(forAim: a),
                              pitch: 0.74, distance: 2.3, fieldOfView: 40)
    }

    /// For a shot about to roll: up and back, far enough to keep every ball
    /// it will move in view — worked out from the whole recorded shot, so the
    /// camera makes one calm move instead of chasing.
    func shotPose(for trajectory: PoolTrajectory, from firstContact: Double = 0) -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        let start = trajectory.poses(at: 0)
        var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
        // From the first contact on: where the cue ball set off from is
        // behind the camera's interest by then.
        let from = min(max(0, firstContact), trajectory.duration)
        let steps = 60
        for i in 0...steps {
            let t = from + (trajectory.duration - from) * Double(i) / Double(steps)
            for (n, pose) in trajectory.poses(at: t) {
                let moved = start[n].map { simd_distance($0.position, pose.position) > 0.004 } ?? true
                guard moved || n == 0 else { continue }
                lo = simd_min(lo, pose.position)
                hi = simd_max(hi, pose.position)
            }
        }
        guard lo.x.isFinite else { return rig.goal }
        let centre = (lo + hi) / 2
        let span = max(hi.x - lo.x, (hi.y - lo.y) * 1.4)
        let distance = max(1.35, min(3.3, 0.9 + span * 1.05))
        return PoolCameraPose(focus: [centre.x, 0, -centre.y], yaw: rig.current.yaw, pitch: 0.95,
                              distance: distance, fieldOfView: 40)
    }

    /// Where the camera belongs right now, in the chosen view.
    func naturalPose() -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        switch phase {
        case .thinking: return watchPose()
        case .over: return topPose()
        case .rolling, .striking: return rig.goal
        default: return aimPose()
        }
    }

    func setCamera(_ pose: PoolCameraPose, animated: Bool) {
        let cut = !animated || !Motion.isEnabled || runsSynchronously || view.window == nil
        rig.set(pose, immediately: cut)
        applyCamera()
        if !rig.isSettled { requestFrames() }
    }

    func applyCamera() {
        guard isViewLoaded else { return }
        table.apply(camera: rig.current)
        updateBallInHandBadge()
    }

    func setViewMode(_ mode: ViewMode, animated: Bool = true) {
        viewMode = mode
        setCamera(naturalPose(), animated: animated)
        refreshHUD()
        redraw()
    }

    /// Asks the view to draw a couple of frames — after a change made while
    /// nothing was otherwise moving.
    func redraw() {
        guard isViewLoaded, !runsSynchronously else { return }
        redrawFrames = max(redrawFrames, 2)
        requestFrames()
    }

    // MARK: The cue and the guides

    func refreshAim() {
        guard isViewLoaded else { return }
        let R = geometry.ballRadius
        guard let cue = match.table.cueBall, cue.pocket == nil else {
            table.cue.node.isHidden = true
            table.guides.hide()
            return
        }
        let showCue = cueVisible && phase != .over && phase != .thinking && drag != .placing
        table.cue.node.isHidden = !showCue
        if showCue {
            let tipHeight = R + tipVertical * 0.5 * R
            table.cue.place(ballCentre: PoolSpace.sceneSIMD(cue.position, height: R), aim: aim, tipSide: tipSide,
                            tipVertical: tipVertical, radius: R, pullBack: cuePull,
                            elevation: cueElevation(from: cue.position, tipHeight: tipHeight))
        }
        let guidesWanted = (phase == .aiming || phase == .charging) && !match.shooterIsComputer
            && match.options.guides != .off && drag != .placing && !match.isOver
        if guidesWanted {
            let prediction = PoolAimGuide.predict(aim: aim, from: match.table, geometry: geometry)
            let objectBall = prediction.targetBall.flatMap { match.table.ball($0)?.position }
            table.guides.show(cue: cue.position, prediction: prediction, objectBall: objectBall,
                              objectReach: match.options.guides.objectLine, cueReach: match.options.guides.cueLine,
                              dimensions: table.dimensions)
        } else {
            table.guides.hide()
        }
        // The kitchen is marked while the cue ball is being carried, or seen
        // from above — from behind the ball the head string would only be a
        // line through it.
        table.kitchen.isHidden = !(playerHasBallInHand && match.rules.ballInHand == .kitchen
                                   && (drag == .placing || viewMode == .top))
        updateBallInHandBadge()
        redraw()
    }

    func guides(hidden: Bool) {
        if hidden { table.guides.hide() } else { refreshAim() }
    }

    /// How steeply the cue has to be held to clear what lies behind the cue
    /// ball — the cushion and rail when it is near one, and any ball in the
    /// way — the way a player raises the butt. Never flatter than a few
    /// degrees.
    func cueElevation(from centre: SIMD2<Double>, tipHeight: Double) -> Double {
        let R = geometry.ballRadius
        let d = table.dimensions
        let back = -PoolSpace.tableDirection(aim)
        var elevation = 4.5 * Double.pi / 180
        var s = 0.02
        while s < 1.4 {
            let p = centre + back * (R + cuePull + s)
            let r = table.cue.radius(at: s) + 0.003
            var needed: Double?
            if d.isOverRail(p) {
                needed = d.railTop + r
            } else if d.isOverCushion(p) {
                needed = d.cushionTop + r
            }
            for ball in match.table.balls where ball.number != 0 && ball.pocket == nil {
                if simd_distance(ball.position, p) < R + r {
                    needed = max(needed ?? 0, 2 * R + r)
                }
            }
            if let needed { elevation = max(elevation, atan2(needed - tipHeight, s)) }
            s += 0.02
        }
        return min(elevation, 1.15)
    }

    // MARK: Spin

    func setSpin(side: Double, vertical: Double) {
        tipSide = side
        tipVertical = vertical
        spinControl.set(side: side, vertical: vertical)
        refreshAim()
        refreshHUD()
    }

    // MARK: The HUD

    func layoutHUD() {
        guard isViewLoaded else { return }
        let inset = TabletopChrome.topInset(for: root)
        let b = root.bounds
        let sceneFrame = CGRect(x: 0, y: inset, width: b.width, height: max(1, b.height - inset))
        let resized = sceneView.frame.size != sceneFrame.size
        sceneView.frame = sceneFrame
        if vignette.frame != sceneFrame {
            vignette.frame = sceneFrame
            vignette.needsDisplay = true
        }
        layoutPlates()
        let middle = inset + (b.height - inset) / 2 - 12
        let meter = PoolPowerMeter.size
        powerMeter.frame = CGRect(x: 26, y: (middle - meter.height / 2).rounded(), width: meter.width, height: meter.height)
        let spin = PoolSpinControl.size
        spinControl.frame = CGRect(x: b.width - 26 - spin.width, y: (middle - spin.height / 2).rounded(),
                                   width: spin.width, height: spin.height)
        if resized && viewMode == .top { setCamera(topPose(), animated: false) }
        updateBallInHandBadge()
    }

    private func layoutPlates() {
        let inset = TabletopChrome.topInset(for: root)
        let y = inset + 10
        let w = root.bounds.width
        let youWidth = youPlate.preferredWidth, computerWidth = computerPlate.preferredWidth
        youPlate.frame = CGRect(x: 18, y: y, width: youWidth, height: PoolPlayerPlate.height)
        computerPlate.frame = CGRect(x: w - 18 - computerWidth, y: y, width: computerWidth, height: PoolPlayerPlate.height)
    }

    func refreshHUD() {
        guard isViewLoaded else { return }
        let over = match.isOver
        let winner = match.rules.winner
        youPlate.seat.state = winner == PoolSeat.you ? .winner : (!over && !match.shooterIsComputer ? .active : .waiting)
        youPlate.seat.detail = detail(for: PoolSeat.you)
        computerPlate.isHidden = match.isPractice
        computerPlate.seat.name = match.opponentName
        computerPlate.seat.state = winner == PoolSeat.computer ? .winner : (!over && match.shooterIsComputer ? .active : .waiting)
        computerPlate.seat.isThinking = phase == .thinking
        computerPlate.seat.detail = phase == .thinking
            ? NSLocalizedString("Thinking…", comment: "pool: the computer is deciding") : detail(for: PoolSeat.computer)
        for (plate, player) in [(youPlate, PoolSeat.you), (computerPlate, PoolSeat.computer)] {
            guard let plate else { continue }
            if over { plate.setBalls([]); continue }
            switch match.options.mode {
            case .eightBall:
                plate.setBalls(match.ballsNeeded(by: player) ?? [])
            case .nineBall:
                let on = !over && match.rules.shooter == player ? match.lowestBall.map { [$0] } ?? [] : []
                plate.setBalls(on)
            case .practice:
                plate.setBalls([])
            }
        }
        layoutPlates()

        var pills = [StatusPillItem(id: "mode", text: PoolEngineText.mode(match.options.mode),
                                    symbolName: PoolEngineText.modeSymbol(match.options.mode))]
        if !match.isPractice {
            pills.append(StatusPillItem(id: "difficulty", text: PoolEngineText.difficulty(match.options.difficulty),
                                        symbolName: "speedometer"))
        }
        if playerHasBallInHand {
            pills.append(StatusPillItem(id: "hand", text: NSLocalizedString("Ball in hand", comment: "pool pill"),
                                        symbolName: "arrow.up.and.down.and.arrow.left.and.right", isEmphasized: true))
        }
        TopBarStatus.set(pills, for: .pool)

        let top = viewMode == .top
        var actions = [
            ChromeAction(id: "view", title: top ? NSLocalizedString("Aim View", comment: "pool button")
                            : NSLocalizedString("Top View", comment: "pool button"),
                         symbolName: top ? "scope" : "rectangle", keyEquivalent: "t") { [weak self] in
                self?.toggleTopView(nil)
            },
            ChromeAction(id: "spin", title: NSLocalizedString("Reset Spin", comment: "pool button"),
                         symbolName: "arrow.counterclockwise",
                         isEnabled: isPlayersTurn && (tipSide != 0 || tipVertical != 0)) { [weak self] in
                self?.resetSpin(nil)
            },
        ]
        if match.isPractice {
            actions.append(ChromeAction(id: "rerack", title: NSLocalizedString("Re-rack", comment: "pool button"),
                                        symbolName: "triangle", isEnabled: phase != .rolling && phase != .striking) { [weak self] in
                self?.rematch(nil)
            })
        }
        if over {
            actions.append(ChromeAction(id: "rematch", title: NSLocalizedString("Rematch", comment: "pool button"),
                                        style: .primary) { [weak self] in self?.rematch(nil) })
        } else {
            actions.append(ChromeAction(id: "shoot", title: NSLocalizedString("Shoot", comment: "pool button"),
                                        style: .primary, keyEquivalent: "\r",
                                        isEnabled: isPlayersTurn && phase == .aiming) { [weak self] in
                self?.shootAtArmedPower()
            })
        }
        actionBar.setActions(actions, animated: view.window != nil)
        powerMeter.isEnabled = isPlayersTurn
        spinControl.isEnabled = isPlayersTurn
    }

    /// The line under a player's name.
    private func detail(for player: Int) -> String {
        if let winner = match.rules.winner {
            return winner == player ? NSLocalizedString("Wins the game", comment: "pool: the winner's plate")
                : NSLocalizedString("Game over", comment: "pool: the loser's plate")
        }
        switch match.options.mode {
        case .eightBall:
            if let group = match.rules.groups[safe: player] ?? nil {
                return match.ballsNeeded(by: player) == [8]
                    ? NSLocalizedString("On the eight", comment: "pool: only the eight left to pot")
                    : PoolEngineText.group(group)
            }
            if match.rules.isBreakShot {
                return match.rules.shooter == player ? NSLocalizedString("To break", comment: "pool: this player breaks") : ""
            }
            return NSLocalizedString("Open table", comment: "pool: groups not yet decided")
        case .nineBall:
            let count = match.pocketedBy[safe: player]?.count ?? 0
            return Plural.format(count, one: NSLocalizedString("%d ball potted", comment: "pool: one ball potted"),
                                 other: NSLocalizedString("%d balls potted", comment: "pool: balls potted"))
        case .practice:
            return Plural.format(match.rules.shotCount, one: NSLocalizedString("%d shot", comment: "pool practice: one shot"),
                                 other: NSLocalizedString("%d shots", comment: "pool practice: shots"))
        }
    }

    func toast(_ text: String, symbol: String, tint: NSColor = Palette.textSecondary) {
        guard isViewLoaded else { return }
        Toast.show(text, symbolName: symbol, symbolTint: tint, in: root,
                   placement: .bottom(offset: actionBar.reservedHeight + Spacing.s))
    }

    // MARK: Ball in hand

    func updateBallInHandBadge() {
        guard isViewLoaded else { return }
        guard playerHasBallInHand, drag != .placing, let cue = match.table.cueBall, cue.pocket == nil,
              let centre = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: geometry.ballRadius)),
              let top = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: geometry.ballRadius * 2))
        else {
            hideBallInHandBadge()
            return
        }
        // A little right of the ball's own edge on screen.
        let radius = abs(top.y - centre.y)
        let at = sceneView.convert(CGPoint(x: centre.x + radius * 1.3 + 4, y: centre.y), to: root)
        guard root.bounds.insetBy(dx: 40, dy: 40).contains(at) else { hideBallInHandBadge(); return }
        // Beside the ball, clear of the aiming line that runs up from it.
        if let badge = ballInHandBadge, badge.superview != nil {
            badge.move(to: at, anchor: .trailing)
        } else {
            ballInHandBadge = TableBadge.show(NSLocalizedString("Drag to place", comment: "pool badge: ball in hand"),
                                              symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                              in: root, at: at, anchor: .trailing, animated: view.window != nil)
        }
    }

    func hideBallInHandBadge() {
        ballInHandBadge?.hide(animated: false)
        ballInHandBadge = nil
    }
}
