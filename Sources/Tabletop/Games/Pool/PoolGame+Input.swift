//
//  PoolGame+Input.swift
//  The mouse and the keyboard at the table.
//
//  Drag across the cloth to aim — sideways turns the cue, up and down tilts
//  the view — with Shift for a finer hand. In the view from above the cue
//  simply points at the pointer. With ball in hand, a press on the cue ball
//  picks it up. Space draws the cue back while it is held and shoots on
//  release; Escape calls it off.
//

import AppKit
import simd

extension PoolGame: PoolSceneViewInput {

    func poolMouseDown(_ event: NSEvent, at point: CGPoint) {
        guard isPlayersTurn, phase == .aiming else { drag = .none; return }
        dragLast = point
        dragStart = point
        dragMoved = false
        if playerHasBallInHand, isOverCueBall(point) {
            drag = .placing
            dragValidSpot = match.table.cueBall?.position
            if let spot = dragValidSpot {
                table.placementRing.isHidden = false
                table.placementRing.simdPosition = PoolSpace.sceneSIMD(spot, height: 0.0008)
            }
            hideBallInHandBadge()
            refreshAim()
            requestFrames()
            return
        }
        if viewMode == .top {
            drag = .aimAtPointer
            aimAtPointer(point)
        } else {
            drag = .orbit
        }
        requestFrames()
    }

    func poolMouseDragged(_ event: NSEvent, at point: CGPoint) {
        defer { dragLast = point }
        if hypot(point.x - dragStart.x, point.y - dragStart.y) > 3 { dragMoved = true }
        switch drag {
        case .none:
            return
        case .orbit:
            let fine = event.modifierFlags.contains(.shift)
            let dx = Double(point.x - dragLast.x), dy = Double(point.y - dragLast.y)
            // Right turns the cue right (clockwise from above); pulling the
            // table down lifts the camera.
            aim -= dx * (fine ? 0.00045 : 0.0042)
            aimPitch = max(0.07, min(Self.highestAimPitch, aimPitch - dy * (fine ? 0.0006 : 0.0042)))
            if dragMoved { learned(aimed: true) }
            setCamera(aimPose(), animated: false, following: true)
            refreshAim()
        case .aimAtPointer:
            if dragMoved { learned(aimed: true) }
            aimAtPointer(point)
        case .placing:
            carryCueBall(to: point)
        }
    }

    func poolMouseUp(_ event: NSEvent, at point: CGPoint) {
        let was = drag
        endDrag()
        // A click on a ball, from behind the cue ball, aims straight at it
        // (from above, any click aims at its point already).
        if was == .orbit, !dragMoved, isPlayersTurn, phase == .aiming, let target = ball(under: point),
           let cue = match.table.cueBall {
            let d = target - cue.position
            aim = atan2(d.y, d.x)
            setCamera(aimPose(), animated: true)
            refreshAim()
        }
        redraw()
    }

    /// Ends whatever the mouse was doing. A cue ball being carried is put
    /// down on the last spot it was allowed — also when the drag is cut
    /// short by the window going, a new game or a stroke.
    func endDrag() {
        let was = drag
        drag = .none
        guard was == .placing else { return }
        table.placementGhost.isHidden = true
        table.placementDeny.isHidden = true
        table.placementRing.isHidden = true
        updateDenyBadge()
        if let spot = dragValidSpot { moveCueBall(to: spot) }
        dragValidSpot = nil
        if viewMode == .aim && isPlayersTurn { setCamera(aimPose(), animated: true) }
        refreshAim()
        refreshHUD()
    }

    func poolScroll(_ event: NSEvent) {
        guard viewMode == .aim, phase != .over else { return }
        let k = event.hasPreciseScrollingDeltas ? 0.006 : 0.08
        zoom(by: exp(-Double(event.scrollingDeltaY) * k))
    }

    func poolMagnify(_ event: NSEvent) {
        guard viewMode == .aim, phase != .over else { return }
        zoom(by: 1 - Double(event.magnification))
    }

    private func zoom(by factor: Double) {
        aimDistance = max(0.42, min(Self.farthestAim, aimDistance * factor))
        if phase == .aiming || phase == .charging { setCamera(aimPose(), animated: false, following: true) }
        redraw()
    }

    func poolKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 49:                                                   // space
            if !event.isARepeat && phase == .aiming { beginCharge(.keyboard) }
            return true
        case 53:                                                   // escape
            if phase == .charging {
                powerMeter.cancel()
                cancelCharge()
                return true
            }
            if viewMode == .top { setViewMode(.aim); return true }
            return false
        case 123, 124:                                             // ← →
            guard isPlayersTurn, phase == .aiming else { return true }
            let step = (event.modifierFlags.contains(.shift) ? 0.05 : 0.3) * Double.pi / 180
            aim += event.keyCode == 123 ? step : -step
            learned(aimed: true)
            if viewMode == .aim { setCamera(aimPose(), animated: false, following: true) }
            refreshAim()
            return true
        case 125, 126:                                             // ↓ ↑
            guard isPlayersTurn, phase == .aiming else { return true }
            armedPower = max(0.02, min(1, armedPower + (event.keyCode == 126 ? 0.05 : -0.05)))
            powerMeter.armedPower = armedPower
            return true
        default:
            return false
        }
    }

    func poolKeyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        if phase == .charging, chargeSource == .keyboard { endCharge(shoot: true) }
        return true
    }

    // MARK: Helpers

    private func isOverCueBall(_ point: CGPoint) -> Bool {
        guard let cue = match.table.cueBall, cue.pocket == nil else { return false }
        let R = geometry.ballRadius
        guard let centre = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: R)),
              let edge = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position + [0, R], height: R)) else { return false }
        let radius = max(10, hypot(edge.x - centre.x, edge.y - centre.y) * 1.6)
        return hypot(point.x - centre.x, point.y - centre.y) <= radius
    }

    /// Says, over the red stand-in, why the cue ball may not go there.
    func updateDenyBadge() {
        guard drag == .placing, !table.placementGhost.isHidden,
              let c = sceneView.screenPoint(of: table.placementGhost.simdPosition + [0, Float(geometry.ballRadius), 0])
        else {
            denyBadge?.hide(animated: false)
            denyBadge = nil
            return
        }
        let at = sceneView.convert(c, to: root)
        let past = PoolSpace.table(table.placementGhost.simdPosition).x > geometry.headStringX
        let text = match.rules.ballInHand == .kitchen && past
            ? NSLocalizedString("Behind the line only", comment: "pool badge: the break's cue ball must stay in the kitchen")
            : NSLocalizedString("Not on another ball", comment: "pool badge: the cue ball may not be put on a ball")
        if let badge = denyBadge, badge.superview != nil {
            badge.update(text: text, symbolName: "xmark", tone: .loss)
            badge.move(to: at, anchor: .above)
        } else {
            denyBadge = TableBadge.show(text, symbolName: "xmark", tone: .loss, in: root, at: at, anchor: .above,
                                        animated: false)
        }
    }

    /// The object ball under `point` on screen, if any: where the ray under
    /// it meets the plane through the balls' centres, within a ball's width.
    private func ball(under point: CGPoint) -> SIMD2<Double>? {
        let R = geometry.ballRadius
        guard let p = sceneView.tablePoint(under: point, height: R) else { return nil }
        return match.table.balls
            .filter { $0.number != 0 && $0.pocket == nil && simd_distance($0.position, p) < R * 1.3 }
            .min { simd_distance($0.position, p) < simd_distance($1.position, p) }?.position
    }

    private func aimAtPointer(_ point: CGPoint) {
        guard let cue = match.table.cueBall,
              let p = sceneView.tablePoint(under: point, height: geometry.ballRadius) else { return }
        let d = p - cue.position
        guard simd_length(d) > geometry.ballRadius * 0.5 else { return }
        aim = atan2(d.y, d.x)
        refreshAim()
    }

    /// The cue ball follows the pointer wherever the rules allow it, sliding
    /// along the head string, the cushions and other balls; where nothing
    /// near is allowed, it waits at the last allowed spot and a red ghost
    /// shows where the pointer is. Every spot it stops on is one
    /// `PoolRules.isValidPlacement` accepts.
    private func carryCueBall(to point: CGPoint) {
        guard let p = sceneView.tablePoint(under: point, height: geometry.ballRadius) else { return }
        carryCueBall(toward: p)
    }

    /// The same, for a point on the cloth.
    func carryCueBall(toward p: SIMD2<Double>) {
        let R = geometry.ballRadius
        if let spot = slidePlacement(toward: p), simd_distance(spot, p) < 4 * R {
            dragValidSpot = spot
            table.placementGhost.isHidden = true
            table.placementDeny.isHidden = true
            moveCueBall(to: spot)
            table.placementRing.isHidden = false
            table.placementRing.simdPosition = PoolSpace.sceneSIMD(spot, height: 0.0008)
        } else {
            let shown = SIMD2(max(-geometry.length / 2 + R, min(geometry.length / 2 - R, p.x)),
                              max(-geometry.width / 2 + R, min(geometry.width / 2 - R, p.y)))
            table.placementGhost.isHidden = false
            table.placementGhost.simdPosition = PoolSpace.sceneSIMD(shown, height: R)
            table.placementDeny.isHidden = false
            table.placementDeny.simdPosition = PoolSpace.sceneSIMD(shown, height: 0.0008)
            table.placementRing.isHidden = true
        }
        updateDenyBadge()
        redraw()
    }
}
