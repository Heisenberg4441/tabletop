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
        if playerHasBallInHand, isOverCueBall(point) {
            drag = .placing
            dragValidSpot = match.table.cueBall?.position
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
        switch drag {
        case .none:
            return
        case .orbit:
            let fine = event.modifierFlags.contains(.shift)
            let dx = Double(point.x - dragLast.x), dy = Double(point.y - dragLast.y)
            // Right turns the cue right (clockwise from above); pulling the
            // table down lifts the camera.
            aim -= dx * (fine ? 0.00045 : 0.0042)
            aimPitch = max(0.07, min(1.35, aimPitch - dy * (fine ? 0.0006 : 0.0042)))
            setCamera(aimPose(), animated: false)
            refreshAim()
        case .aimAtPointer:
            aimAtPointer(point)
        case .placing:
            carryCueBall(to: point)
        }
    }

    func poolMouseUp(_ event: NSEvent, at point: CGPoint) {
        let was = drag
        drag = .none
        if was == .placing {
            table.placementGhost.isHidden = true
            if let spot = dragValidSpot { moveCueBall(to: spot) }
            dragValidSpot = nil
            if viewMode == .aim { setCamera(aimPose(), animated: true) }
            refreshAim()
            refreshHUD()
        }
        redraw()
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
        aimDistance = max(0.42, min(2.6, aimDistance * factor))
        if phase == .aiming || phase == .charging { setCamera(aimPose(), animated: false) }
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
            if viewMode == .aim { setCamera(aimPose(), animated: false) }
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

    func poolFlagsChanged(_ event: NSEvent) {}

    // MARK: Helpers

    private func isOverCueBall(_ point: CGPoint) -> Bool {
        guard let cue = match.table.cueBall, cue.pocket == nil else { return false }
        let R = geometry.ballRadius
        guard let centre = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position, height: R)),
              let edge = sceneView.screenPoint(of: PoolSpace.sceneSIMD(cue.position + [0, R], height: R)) else { return false }
        let radius = max(10, hypot(edge.x - centre.x, edge.y - centre.y) * 1.6)
        return hypot(point.x - centre.x, point.y - centre.y) <= radius
    }

    private func aimAtPointer(_ point: CGPoint) {
        guard let cue = match.table.cueBall,
              let p = sceneView.tablePoint(under: point, height: geometry.ballRadius) else { return }
        let d = p - cue.position
        guard simd_length(d) > geometry.ballRadius * 0.5 else { return }
        aim = atan2(d.y, d.x)
        refreshAim()
    }

    /// The cue ball follows the pointer wherever the rules allow it; where
    /// they do not, it waits at the last allowed spot and a red ghost shows
    /// where the pointer is.
    private func carryCueBall(to point: CGPoint) {
        let R = geometry.ballRadius
        guard let p = sceneView.tablePoint(under: point, height: R) else { return }
        let clamped = SIMD2(max(-geometry.length / 2 + R, min(geometry.length / 2 - R, p.x)),
                            max(-geometry.width / 2 + R, min(geometry.width / 2 - R, p.y)))
        var others = match.table
        others.balls.removeAll { $0.number == 0 }
        if PoolRules.isValidPlacement(clamped, match.rules, table: others, geometry: geometry) {
            dragValidSpot = clamped
            table.placementGhost.isHidden = true
            moveCueBall(to: clamped)
        } else {
            table.placementGhost.isHidden = false
            table.placementGhost.simdPosition = PoolSpace.sceneSIMD(clamped, height: R)
        }
        redraw()
    }
}
