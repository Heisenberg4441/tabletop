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
    /// is played from. Never below the cue: when it has to be raised over a
    /// rail or a ball behind the cue ball, the camera rises with it and
    /// looks down past it, so the cue never stands up the middle of the
    /// picture in front of the shot.
    func aimPose() -> PoolCameraPose {
        let R = geometry.ballRadius
        let cue = match.table.cueBall?.position ?? geometry.headSpot
        let tipHeight = R + tipVertical * 0.5 * R
        let raised = cueElevation(from: cue, tipHeight: tipHeight, pull: 0)
        var pitch = max(aimPitch, min(Self.highestAimPitch, raised + 6 * .pi / 180))
        var distance = aimDistance
        let forced = pitch > aimPitch + 0.01
        // Looking down that steeply, the camera stands back far enough to
        // keep the shot in the picture below the players' plates: the ghost
        // ball, or wherever the aim meets a cushion.
        let reach = forced
            ? min(2.2, simd_distance(PoolAimGuide.predict(aim: aim, from: match.table, geometry: geometry).ghostBallCenter,
                                     cue) + 2 * R)
            : 0
        let limit = 0.5 * tan(20 * Double.pi / 180)
        var lead = Self.aimLead
        for _ in 0..<60 {
            // Looking steeply down, the view leads the cue ball by less, so
            // the ball stays well clear of the action bar.
            lead = min(Self.aimLead, 0.55 * tan(20 * Double.pi / 180) / (sin(pitch) + 0.2 * cos(pitch)))
            if forced {
                let k = sin(pitch) - limit * cos(pitch)
                if k > 0 { distance = max(aimDistance, min(Self.farthestAim, reach * k / (limit + lead * k))) }
            }
            // And high enough over the cue's line where the camera stands,
            // with room for the thickness of the butt.
            let behind = distance * cos(pitch) - lead * distance
            let height = R + distance * sin(pitch)
            if pitch >= Self.highestAimPitch || height >= tipHeight + max(0, behind) * tan(raised) + 0.045 { break }
            pitch += 0.02
        }
        let ahead = cue + PoolSpace.tableDirection(aim) * (lead * distance)
        return PoolCameraPose(focus: [ahead.x, R, -ahead.y], yaw: PoolCameraPose.yaw(forAim: aim),
                              pitch: min(pitch, Self.highestAimPitch), distance: distance, fieldOfView: 40)
    }

    /// How far ahead of the cue ball the aim view looks, per metre of its
    /// distance: the object ball matters more than the cue ball.
    static let aimLead = 0.26
    static let highestAimPitch = 1.35
    static let farthestAim = 2.6

    /// Straight down on the whole table, the long way across the screen,
    /// framed inside the HUD.
    func topPose() -> PoolCameraPose {
        let size = viewportSize
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

    /// Over the computer's shoulder while it thinks: from the end of the
    /// table its cue ball is at, turned a little across from its side, the
    /// whole table framed between the HUD's edges — with the lamp hanging
    /// over the far end.
    func watchPose() -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        let cue = match.table.cueBall?.position ?? geometry.headSpot
        let toward = cue.x <= 0 ? 1.0 : -1.0
        let side = cue.y >= 0 ? 1.0 : -1.0
        let look = atan2(-side * 0.35, toward)
        let d = table.dimensions
        var corners: [SIMD3<Double>] = []
        for sx in [-1.0, 1] {
            for sy in [-1.0, 1] {
                corners.append(SIMD3(sx * d.outerX, d.railTop, -sy * d.outerY))
            }
        }
        return PoolFraming.fit(corners, yaw: PoolCameraPose.yaw(forAim: look), pitch: 0.40, fieldOfView: 40,
                               viewport: viewportSize, insets: hudInsets, distance: 1.5...8) ?? topPose()
    }

    /// For a shot about to roll: up and back, far enough to keep every ball
    /// it will move in view from start to finish — worked out from the whole
    /// recorded shot, so the camera makes one calm move instead of chasing.
    /// Steeper for a shot that spans the table; from above when nothing
    /// else will do.
    func shotPose(for trajectory: PoolTrajectory) -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        let R = geometry.ballRadius
        var points: [SIMD3<Double>] = []
        for track in trajectory.tracks {
            guard let first = track.keys.first else { continue }
            let moves = track.pocket != nil || track.keys.contains { simd_distance($0.position, first.position) > 0.004 }
            guard moves else { continue }
            for key in track.keys { points.append(PoolSpace.sceneDouble(key.position, height: R)) }
            if let id = track.pocket, let pocket = geometry.pockets.first(where: { $0.id == id }) {
                points.append(PoolSpace.sceneDouble(pocket.center, height: R))
            }
        }
        guard !points.isEmpty else { return rig.goal }
        // The balls are round: keep their whole width clear of the HUD.
        var insets = hudInsets
        insets.top += 12; insets.bottom += 12; insets.left += 12; insets.right += 12
        let yaw = rig.current.yaw
        for pitch in [0.95, 1.08, 1.22, 1.36] {
            if let pose = PoolFraming.fit(points, yaw: yaw, pitch: pitch, fieldOfView: 40, viewport: viewportSize,
                                          insets: insets, distance: 1.35...5.2) {
                return pose
            }
        }
        return topPose()
    }

    /// Where the camera belongs right now, in the chosen view.
    func naturalPose() -> PoolCameraPose {
        if viewMode == .top { return topPose() }
        switch phase {
        case .thinking: return watchPose()
        case .over: return topPose()
        case .rolling, .striking:
            if let playback, let trajectory = playback.result.trajectory {
                return shotPose(for: trajectory)
            }
            return rig.goal
        default: return aimPose()
        }
    }

    /// The scene view's size, or the window's usual one before it has any.
    var viewportSize: CGSize {
        sceneView.bounds.size.width > 10 ? sceneView.bounds.size : CGSize(width: 1200, height: 762)
    }

    /// What the HUD covers at each edge of the scene view: the players'
    /// plates at the top, the action bar at the bottom, the power meter and
    /// the spin control at the sides.
    var hudInsets: PoolFraming.Insets {
        PoolFraming.Insets(top: Double(Self.plateTop + PoolPlayerPlate.height + 12),
                           left: Double(Self.hudSide + PoolPowerMeter.size.width + 12),
                           bottom: Double(actionBar.reservedHeight + 8),
                           right: Double(Self.hudSide + PoolSpinControl.size.width + 12))
    }

    /// `following` is for a drag: the camera keeps up exactly, but for a
    /// pitch the cue forces, which glides.
    func setCamera(_ pose: PoolCameraPose, animated: Bool, following: Bool = false) {
        let cut = !animated || !Motion.isEnabled || runsSynchronously || view.window == nil
        if following && !runsSynchronously && Motion.isEnabled {
            rig.follow(pose)
        } else {
            rig.set(pose, immediately: cut)
        }
        applyCamera()
        if !rig.isSettled { requestFrames() }
    }

    func applyCamera() {
        guard isViewLoaded else { return }
        table.apply(camera: rig.current)
        table.cue.fade(near: SIMD3<Float>(rig.current.position))
        updateBallInHandBadge()
        updateHints()
        if denyBadge != nil { updateDenyBadge() }
    }

    func setViewMode(_ mode: ViewMode, animated: Bool = true) {
        viewMode = mode
        setCamera(naturalPose(), animated: animated)
        refreshAim()
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
            table.cue.fade(near: SIMD3<Float>(rig.current.position))
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
        updateHints()
        redraw()
    }

    func guides(hidden: Bool) {
        if hidden { table.guides.hide() } else { refreshAim() }
    }

    /// How steeply the cue is held to clear what lies behind the cue ball,
    /// the way a player raises the butt; never flatter than a few degrees.
    ///
    /// A cushion or the rail behind the ball: the cue rests on it, as it
    /// would on a rail bridge, and is raised no further — a butt tipped up
    /// higher only stands in front of the shot. A ball close behind is
    /// different: the cue must clear it, however steep that is, and the
    /// camera rises with it (`aimPose`). `pull` is how far the cue is drawn
    /// back (the current draw when nil).
    func cueElevation(from centre: SIMD2<Double>, tipHeight: Double, pull: Double? = nil) -> Double {
        let R = geometry.ballRadius
        let d = table.dimensions
        let back = -PoolSpace.tableDirection(aim)
        let drawn = pull ?? cuePull
        var overRail = 0.0, overBalls = 0.0
        var s = 0.02
        while s < 1.4 {
            let p = centre + back * (R + drawn + s)
            let r = table.cue.radius(at: s) + 0.003
            if d.isOverRail(p) {
                overRail = max(overRail, atan2(d.railTop + r - tipHeight, s))
            } else if d.isOverCushion(p) {
                overRail = max(overRail, atan2(d.cushionTop + r - tipHeight, s))
            }
            for ball in match.table.balls where ball.number != 0 && ball.pocket == nil
                && simd_distance(ball.position, p) < R + r {
                overBalls = max(overBalls, atan2(2 * R + r - tipHeight, s))
            }
            s += 0.02
        }
        let flattest = 4.5 * Double.pi / 180
        return min(max(flattest, min(overRail, Self.railBridgeElevation), overBalls), 1.15)
    }

    /// The most a rail behind the cue ball raises the cue: about a rail
    /// bridge's angle.
    static let railBridgeElevation = 30 * Double.pi / 180

    // MARK: Spin

    func setSpin(side: Double, vertical: Double) {
        tipSide = side
        tipVertical = vertical
        spinControl.set(side: side, vertical: vertical)
        refreshAim()
        refreshHUD()
        // The tip height changes how high the cue has to be held.
        if phase == .aiming && viewMode == .aim && !match.shooterIsComputer {
            setCamera(aimPose(), animated: true, following: true)
        }
    }

    // MARK: The HUD

    static let plateTop: CGFloat = 10
    static let hudSide: CGFloat = 26

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
        // The meter and the spin control stand in the bottom corners, level
        // with the action bar: in the view from behind the cue ball that is
        // the near cloth behind it, where balls seldom are, and from above
        // it is beside the table, not over it.
        let bottom = b.height - actionBar.bottomMargin
        let meter = PoolPowerMeter.size
        powerMeter.frame = CGRect(x: Self.hudSide, y: bottom - meter.height, width: meter.width, height: meter.height)
        let spin = PoolSpinControl.size
        spinControl.frame = CGRect(x: b.width - Self.hudSide - spin.width, y: bottom - spin.height,
                                   width: spin.width, height: spin.height)
        for (caption, control) in [(powerCaption, powerMeter), (spinCaption, spinControl)] as [(NSTextField, NSView)] {
            let width = Typography.fittingWidth(caption), height = ceil(caption.intrinsicContentSize.height)
            caption.frame = CGRect(x: (control.frame.midX - width / 2).rounded(), y: control.frame.minY - height - 3,
                                   width: width, height: height)
        }
        if resized {
            // Every framing depends on the view's shape.
            if viewMode == .top || phase == .over || phase == .thinking || phase == .rolling {
                setCamera(naturalPose(), animated: false)
            }
        }
        updateBallInHandBadge()
        updateHints()
    }

    private func layoutPlates() {
        let inset = TabletopChrome.topInset(for: root)
        let y = inset + Self.plateTop
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
        var actions: [ChromeAction]
        if over {
            // The game is decided: the only choices left are what to play
            // next — offered by the result banner while it is up, and here
            // once it has gone.
            actions = resultShowing ? [] : [
                ChromeAction(id: "new", title: NSLocalizedString("New Game…", comment: "pool button"),
                             symbolName: "plus") { [weak self] in self?.presentOptions() },
                ChromeAction(id: "rematch", title: NSLocalizedString("Rematch", comment: "pool button"),
                             style: .primary) { [weak self] in self?.rematch(nil) },
            ]
        } else {
            actions = [
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
                                            symbolName: "triangle", isEnabled: !isShotInFlight) { [weak self] in
                    self?.rematch(nil)
                })
            }
            actions.append(ChromeAction(id: "shoot", title: NSLocalizedString("Shoot", comment: "pool button"),
                                        style: .primary, keyEquivalent: "\r",
                                        isEnabled: isPlayersTurn && phase == .aiming) { [weak self] in
                self?.shootAtArmedPower()
            })
        }
        actionBar.setActions(actions, animated: view.window != nil)
        // An empty bar would still show its glass.
        actionBar.isHidden = actions.isEmpty
        powerMeter.isEnabled = isPlayersTurn
        spinControl.isEnabled = isPlayersTurn
        // Over a finished game the stroke controls have nothing to say.
        for control in [powerMeter, spinControl, powerCaption, spinCaption] as [NSView] { control.isHidden = over }
        updateHints()
    }

    /// A struck shot that has not yet been taken into the game: the cue
    /// going through, or the balls rolling.
    var isShotInFlight: Bool { phase == .rolling || (phase == .striking && (playback != nil || strokeInFlight != nil)) }

    /// The line under a player's name.
    private func detail(for player: Int) -> String {
        if let winner = match.rules.winner {
            return winner == player ? NSLocalizedString("Winner", comment: "pool: the winner's plate")
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
                if match.rules.shooter == player { return NSLocalizedString("To break", comment: "pool: this player breaks") }
                // The other player, before the break: who they are.
                return player == PoolSeat.computer
                    ? PoolEngineText.difficulty(match.options.difficulty)
                    : NSLocalizedString("Waiting to play", comment: "pool: the player's plate while the computer breaks")
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

    // MARK: Badges beside the cue ball

    /// The cue ball on screen, in the root view: its centre, its radius, and
    /// which way the shot runs from it (a unit vector, y down).
    private func cueBallOnScreen() -> (centre: CGPoint, radius: CGFloat, ahead: CGVector)? {
        guard let cue = match.table.cueBall, cue.pocket == nil else { return nil }
        let R = geometry.ballRadius
        guard let c = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: R)),
              let top = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: R * 2)),
              let front = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position + PoolSpace.tableDirection(aim) * 0.1,
                                                                        height: R))
        else { return nil }
        let centre = sceneView.convert(c, to: root)
        let ahead = sceneView.convert(front, to: root)
        let dx = ahead.x - centre.x, dy = ahead.y - centre.y
        let length = max(hypot(dx, dy), 0.001)
        return (centre, max(abs(top.y - c.y), 4), CGVector(dx: dx / length, dy: dy / length))
    }

    /// Beside the cue ball, square to the line of the shot — so neither the
    /// aiming line ahead of it nor the cue behind it is covered — on the
    /// right-hand side of the line, or its left when `left`. Nil when the
    /// point would be off the table's part of the screen.
    private func besideCueBall(left: Bool) -> (point: CGPoint, anchor: TableBadge.Anchor)? {
        guard let ball = cueBallOnScreen() else { return nil }
        // The two sides square to the shot; "right" is the one further
        // right on screen.
        var side = CGVector(dx: -ball.ahead.dy, dy: ball.ahead.dx)
        if side.dx < 0 || (side.dx == 0 && side.dy > 0) { side = CGVector(dx: -side.dx, dy: -side.dy) }
        if left { side = CGVector(dx: -side.dx, dy: -side.dy) }
        let reach = ball.radius * 1.3 + 4
        let at = CGPoint(x: ball.centre.x + side.dx * reach, y: ball.centre.y + side.dy * reach)
        guard root.bounds.insetBy(dx: 40, dy: 40).contains(at) else { return nil }
        let anchor: TableBadge.Anchor = abs(side.dx) >= abs(side.dy)
            ? (side.dx >= 0 ? .trailing : .leading)
            : (side.dy >= 0 ? .below : .above)
        return (at, anchor)
    }

    func updateBallInHandBadge() {
        guard isViewLoaded else { return }
        guard playerHasBallInHand, drag != .placing, let spot = besideCueBall(left: false) else {
            hideBallInHandBadge()
            return
        }
        if let badge = ballInHandBadge, badge.superview != nil {
            badge.move(to: spot.point, anchor: spot.anchor)
        } else {
            ballInHandBadge = TableBadge.show(NSLocalizedString("Drag to place", comment: "pool badge: ball in hand"),
                                              symbolName: "arrow.up.and.down.and.arrow.left.and.right",
                                              in: root, at: spot.point, anchor: spot.anchor, animated: view.window != nil)
        }
    }

    func hideBallInHandBadge() {
        ballInHandBadge?.hide(animated: false)
        ballInHandBadge = nil
    }

    // MARK: First-time hints

    /// Until the player has aimed by dragging and taken a shot, a quiet
    /// badge says how — one thing at a time: first, beside the cue ball,
    /// how to aim; once they have, beside the meter, how to shoot.
    func updateHints() {
        guard isViewLoaded else { return }
        let ready = isPlayersTurn && phase == .aiming && drag == .none && optionsCard?.isPresented != true
        if ready, !options.hasAimed, viewMode == .aim, let spot = besideCueBall(left: true) {
            if let badge = aimHint, badge.superview != nil {
                badge.move(to: spot.point, anchor: spot.anchor)
            } else {
                aimHint = TableBadge.show(NSLocalizedString("Drag across the table to aim", comment: "pool hint"),
                                          symbolName: "arrow.left.and.right", in: root, at: spot.point,
                                          anchor: spot.anchor, animated: view.window != nil)
            }
        } else {
            aimHint?.hide(animated: false)
            aimHint = nil
        }
        if ready, options.hasAimed, !options.hasShot, !powerMeter.isHidden {
            let at = CGPoint(x: powerMeter.frame.maxX, y: powerMeter.frame.minY + 44)
            if let badge = shootHint, badge.superview != nil {
                badge.move(to: at, anchor: .trailing)
            } else {
                shootHint = TableBadge.show(NSLocalizedString("Pull down to shoot", comment: "pool hint: the power meter"),
                                            symbolName: "arrow.down", in: root, at: at, anchor: .trailing,
                                            animated: view.window != nil)
            }
        } else {
            shootHint?.hide(animated: false)
            shootHint = nil
        }
    }

    /// The player has shown they know how: `aimed` by dragging, `shot`.
    func learned(aimed: Bool = false, shot: Bool = false) {
        var changed = false
        if aimed && !options.hasAimed { options.hasAimed = true; changed = true }
        if shot && !options.hasShot { options.hasShot = true; changed = true }
        guard changed else { return }
        Storage.save(options, to: Self.optionsName)
        updateHints()
    }
}
