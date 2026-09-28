//
//  PoolTableScene.swift
//  The room: a nine-foot table under its lamp, in the dark.
//
//  Built entirely from `PoolTableGeometry` — the cushions are the engine's
//  own segments extruded, the pockets are cut where the engine's pockets
//  are, the balls are the engine's radius — and lit the way a pool hall is:
//  one long lamp low over the cloth, two lights inside it casting soft
//  shadows straight down, a dark room round about, and the lamp's diffuser
//  reflected in every ball. Nothing here moves by itself; the controller
//  places the balls, the cue and the camera, and asks the view to draw.
//

import AppKit
import SceneKit
import simd

@MainActor
final class PoolTableScene {

    let scene = SCNScene()
    let dimensions: PoolTableDimensions
    var geometry: PoolTableGeometry { dimensions.geometry }

    let cameraNode = SCNNode()
    let camera = SCNCamera()
    private(set) var balls: [Int: PoolBallNode] = [:]
    let cue = PoolCueNode()
    let guides: PoolGuideNodes
    /// The lamp's hood and diffuser — faded out when the camera rises above it.
    let lamp = SCNNode()
    /// The area behind the head string, lit up while the cue ball may be
    /// placed only there.
    let kitchen = SCNNode()
    /// The cue ball's translucent stand-in while it is dragged somewhere it
    /// may not go.
    let placementGhost: SCNNode

    private var bedMaterial: SCNMaterial
    private var cushionMaterial: SCNMaterial
    private var clothColor: TableColor

    static let lampHeight = 0.98
    static let lampLength = 1.86
    static let lampWidth = 0.40

    init(geometry: PoolTableGeometry = .standard, cloth: TableColor = TablePreferences.current.table) {
        dimensions = PoolTableDimensions(geometry)
        clothColor = cloth
        bedMaterial = PoolMaterials.bedCloth(cloth)
        cushionMaterial = PoolMaterials.cushionCloth(cloth)
        guides = PoolGuideNodes(radius: geometry.ballRadius)

        let ghostSphere = SCNSphere(radius: CGFloat(geometry.ballRadius))
        ghostSphere.segmentCount = 48
        ghostSphere.materials = [PoolMaterials.guide(Palette.negative, alpha: 0.45)]
        placementGhost = SCNNode(geometry: ghostSphere)
        placementGhost.isHidden = true
        placementGhost.castsShadow = false

        scene.background.contents = Palette.room
        buildRoom()
        buildTable()
        buildLamp()
        buildLights()
        buildCamera()
        buildBalls()
        scene.rootNode.addChildNode(cue.node)
        scene.rootNode.addChildNode(guides.node)
        scene.rootNode.addChildNode(placementGhost)
        applyEnvironment()
    }

    // MARK: The cloth colour

    /// The View menu's table colour, re-dyed in place.
    func setCloth(_ color: TableColor) {
        guard color != clothColor else { return }
        clothColor = color
        let bed = PoolMaterials.bedCloth(color)
        bedMaterial.diffuse.contents = bed.diffuse.contents
        cushionMaterial.diffuse.contents = PoolMaterials.cushionCloth(color).diffuse.contents
        applyEnvironment()
    }

    private func applyEnvironment() {
        let color = clothColor
        let image = PoolMaterials.image("environment-\(color.rawValue)") {
            PoolTextures.environmentImage(cloth: PoolMaterials.clothColor(color), lampHeight: Self.lampHeight,
                                          lampLength: Self.lampLength, lampWidth: Self.lampWidth, width: 1024)
        }
        scene.lightingEnvironment.contents = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        // The same room behind the table, dimmer and out of focus — the
        // walls the balls reflect, so the dark around the table has depth.
        scene.background.contents = scene.lightingEnvironment.contents
        scene.background.intensity = 0.45
        scene.lightingEnvironment.intensity = 1.4
    }

    // MARK: The room

    private func buildRoom() {
        let floor = SCNFloor()
        floor.reflectivity = 0
        floor.materials = [PoolMaterials.floor()]
        let node = SCNNode(geometry: floor)
        node.position.y = -0.79
        scene.rootNode.addChildNode(node)
    }

    // MARK: The table

    private func buildTable() {
        let d = dimensions
        let root = scene.rootNode
        let table = SCNNode()
        table.name = "table"
        root.addChildNode(table)

        // The bed: slate under cloth, running under the cushions and the
        // rail, with a hole where each pocket drops.
        let bedOutline = PoolShapes.rectangle(d.outerX - 0.02, d.outerY - 0.02)
        let holes = geometry.pockets.map { PoolShapes.holePolygon($0, d) }
        // The holes' sides are the pocket's leather, not cloth.
        let bed = PoolShapes.extrusion([bedOutline] + holes, bottom: -0.045, top: 0,
                                       materials: [bedMaterial, bedMaterial, PoolMaterials.pocketDepth()])
        bed.name = "bed"
        table.addChildNode(bed)

        // The cushions, from the engine's segments: the rubber profile swept
        // along each run, or — should a run ever defeat that — its outline
        // extruded.
        for run in PoolShapes.cushionRuns(d) {
            if let mesh = PoolCushionMesh.geometry(chain: run.chain, interior: run.interior,
                                                   onBackLine: run.isOnBackLine, back: run.back,
                                                   nose: geometry.cushionNoseHeight, top: d.cushionTop,
                                                   material: cushionMaterial) {
                let node = SCNNode(geometry: mesh)
                node.name = "cushion"
                table.addChildNode(node)
            } else {
                let cushion = PoolShapes.extrusion([run.polygon], bottom: -0.001, top: d.cushionTop, chamfer: 0.0055,
                                                   materials: [cushionMaterial])
                cushion.name = "cushion"
                table.addChildNode(cushion)
            }
        }

        // The rail: walnut, with a bite for every pocket, rounded over on
        // its outside edge and running down into the apron.
        let railOuter = PoolShapes.roundedRectangle(d.outerX, d.outerY, radius: 0.045)
        let railInner = PoolShapes.railInnerBoundary(d)
        let top = PoolMaterials.railTop(d), side = PoolMaterials.railSide()
        let rail = PoolShapes.extrusion([railOuter, railInner], bottom: -0.17, top: d.railTop, chamfer: 0.014,
                                        materials: [top, side, side, side, side])
        rail.name = "rail"
        table.addChildNode(rail)

        // The cabinet under the rail, and its legs, standing on the floor.
        let cabinetBox = SCNBox(width: CGFloat(d.outerX * 2 - 0.16), height: 0.36, length: CGFloat(d.outerY * 2 - 0.16),
                                chamferRadius: 0.02)
        cabinetBox.materials = [side]
        let cabinet = SCNNode(geometry: cabinetBox)
        cabinet.position.y = -0.17 - 0.18
        table.addChildNode(cabinet)
        for sx in [-1.0, 0, 1] {
            for sy in [-1.0, 1] {
                let leg = SCNBox(width: 0.16, height: 0.26, length: 0.16, chamferRadius: 0.015)
                leg.materials = [side]
                let node = SCNNode(geometry: leg)
                node.position = SCNVector3(CGFloat(sx * (d.outerX - 0.2)), -0.53 - 0.13, CGFloat(-sy * (d.outerY - 0.2)))
                table.addChildNode(node)
            }
        }

        // Pockets: leather lining the bite in the rail and lapping over its
        // top, and a dark well under the hole for the balls to drop into.
        let leather = PoolMaterials.leather()
        let depth = PoolMaterials.pocketDepth()
        for pocket in geometry.pockets {
            let liner = PoolShapes.linerPolygon(pocket, d, inset: 0.004, outset: 0.001)
            if liner.count > 4 {
                let wall = PoolShapes.extrusion([liner], bottom: -0.044, top: d.railTop + 0.0015, chamfer: 0.002,
                                                materials: [leather])
                table.addChildNode(wall)
            }
            let lip = PoolShapes.linerPolygon(pocket, d, inset: 0.004, outset: 0.016)
            if lip.count > 4 {
                let cap = PoolShapes.extrusion([lip], bottom: d.railTop - 0.004, top: d.railTop + 0.003, chamfer: 0.003,
                                               materials: [leather])
                table.addChildNode(cap)
            }
            let r = d.cut(pocket)
            // Below the bed only, so it never meets the leather above.
            let well = SCNTube(innerRadius: CGFloat(r - 0.004), outerRadius: CGFloat(r), height: 0.09)
            well.radialSegmentCount = 64
            well.materials = [depth]
            let wellNode = SCNNode(geometry: well)
            wellNode.simdPosition = PoolSpace.sceneSIMD(pocket.center, height: -0.047 - 0.045)
            table.addChildNode(wellNode)
            let bottom = SCNCylinder(radius: CGFloat(r), height: 0.004)
            bottom.materials = [depth]
            let bottomNode = SCNNode(geometry: bottom)
            bottomNode.simdPosition = PoolSpace.sceneSIMD(pocket.center, height: -0.13)
            table.addChildNode(bottomNode)
        }

        // Mother-of-pearl sights, let into the rail between the pockets.
        let pearl = PoolMaterials.pearl()
        let middleY = (d.backY + d.outerY) / 2, middleX = (d.backX + d.outerX) / 2
        var sights: [(SIMD2<Double>, Bool)] = []
        for k in [-3.0, -2, -1, 1, 2, 3] {
            sights.append(([k * geometry.length / 8, middleY], true))
            sights.append(([k * geometry.length / 8, -middleY], true))
        }
        for k in [-1.0, 0, 1] {
            sights.append(([middleX, k * geometry.width / 4], false))
            sights.append(([-middleX, k * geometry.width / 4], false))
        }
        for (centre, alongX) in sights {
            let a = 0.0125, b = 0.0055
            let diamond: [SIMD2<Double>] = alongX
                ? [centre + [a, 0], centre + [0, b], centre - [a, 0], centre - [0, b]]
                : [centre + [0, a], centre - [b, 0], centre - [0, a], centre + [b, 0]]
            let sight = PoolShapes.extrusion([diamond], bottom: d.railTop - 0.001, top: d.railTop + 0.0004,
                                             materials: [pearl])
            table.addChildNode(sight)
        }

        // The foot spot, a small white disc on the cloth.
        let spot = SCNCylinder(radius: 0.0055, height: 0.0003)
        let spotMaterial = PoolMaterials.pbr()
        spotMaterial.diffuse.contents = NSColor(white: 0.86, alpha: 1)
        spotMaterial.roughness.contents = 0.6
        spot.materials = [spotMaterial]
        let spotNode = SCNNode(geometry: spot)
        spotNode.simdPosition = PoolSpace.sceneSIMD(geometry.footSpot, height: 0.00015)
        table.addChildNode(spotNode)

        // The kitchen, for placing the cue ball behind the head string.
        let kitchenLength = geometry.headStringX + d.halfLength
        let plane = SCNPlane(width: CGFloat(kitchenLength), height: CGFloat(geometry.width))
        plane.materials = [PoolMaterials.guide(.white, alpha: 0.035)]
        let area = SCNNode(geometry: plane)
        area.eulerAngles.x = -.pi / 2
        area.simdPosition = PoolSpace.sceneSIMD([-d.halfLength + kitchenLength / 2, 0], height: 0.0006)
        kitchen.addChildNode(area)
        let string = SCNBox(width: 0.0022, height: 0.0002, length: CGFloat(geometry.width), chamferRadius: 0)
        string.materials = [PoolMaterials.guide(.white, alpha: 0.32)]
        let stringNode = SCNNode(geometry: string)
        stringNode.simdPosition = PoolSpace.sceneSIMD([geometry.headStringX, 0], height: 0.0008)
        kitchen.addChildNode(stringNode)
        kitchen.isHidden = true
        kitchen.castsShadow = false
        root.addChildNode(kitchen)
    }

    // MARK: The lamp

    private func buildLamp() {
        let hoodBox = SCNBox(width: CGFloat(Self.lampLength + 0.10), height: 0.13, length: CGFloat(Self.lampWidth + 0.08),
                             chamferRadius: 0.025)
        hoodBox.materials = [PoolMaterials.hood()]
        let hood = SCNNode(geometry: hoodBox)
        hood.position.y = CGFloat(Self.lampHeight + 0.065)
        hood.castsShadow = false
        lamp.addChildNode(hood)

        let panel = SCNPlane(width: CGFloat(Self.lampLength), height: CGFloat(Self.lampWidth))
        panel.materials = [PoolMaterials.diffuser()]
        let diffuser = SCNNode(geometry: panel)
        diffuser.eulerAngles.x = .pi / 2           // facing down
        diffuser.position.y = CGFloat(Self.lampHeight - 0.001)
        diffuser.castsShadow = false
        lamp.addChildNode(diffuser)

        let trimBox = SCNBox(width: CGFloat(Self.lampLength + 0.11), height: 0.012, length: CGFloat(Self.lampWidth + 0.09),
                             chamferRadius: 0.006)
        trimBox.materials = [PoolMaterials.brass()]
        let trim = SCNNode(geometry: trimBox)
        trim.position.y = CGFloat(Self.lampHeight + 0.004)
        trim.castsShadow = false
        lamp.addChildNode(trim)

        for x in [-Self.lampLength * 0.36, Self.lampLength * 0.36] {
            let rod = SCNCylinder(radius: 0.005, height: 2.4)
            rod.materials = [PoolMaterials.brass()]
            let node = SCNNode(geometry: rod)
            node.position = SCNVector3(CGFloat(x), CGFloat(Self.lampHeight + 0.13 + 1.2), 0)
            node.castsShadow = false
            lamp.addChildNode(node)
        }
        lamp.name = "lamp"
        scene.rootNode.addChildNode(lamp)
    }

    // MARK: Light

    /// Two lights inside the lamp, a little to the left of centre so shadows
    /// fall away from the one light every table in the collection shares,
    /// soft-edged and straight down; a whisper of ambient so nothing under
    /// the rail is ever pure black; and the room itself, through the
    /// lighting environment, for every reflection.
    private func buildLights() {
        for x in [-0.52, 0.52] {
            let light = SCNLight()
            light.type = .spot
            light.color = NSColor(srgbRed: 1.0, green: 0.94, blue: 0.84, alpha: 1)
            light.intensity = 17
            light.spotInnerAngle = 20
            light.spotOuterAngle = 96
            light.attenuationStartDistance = 0.4
            light.attenuationEndDistance = 4.5
            light.attenuationFalloffExponent = 2
            light.castsShadow = true
            light.shadowMapSize = CGSize(width: 4096, height: 4096)
            light.shadowSampleCount = 24
            light.shadowRadius = 5
            light.shadowColor = NSColor(white: 0, alpha: 0.78)
            light.shadowMode = .forward
            light.shadowBias = 0.8
            light.zNear = 0.4
            light.zFar = 2.6
            let node = SCNNode()
            node.light = light
            node.position = SCNVector3(CGFloat(x - 0.06), CGFloat(Self.lampHeight - 0.02), 0.05)
            node.eulerAngles.x = -.pi / 2
            scene.rootNode.addChildNode(node)
        }
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 12
        ambient.color = NSColor(srgbRed: 0.9, green: 0.88, blue: 0.85, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    // MARK: The camera

    private func buildCamera() {
        camera.zNear = 0.01
        camera.zFar = 30
        camera.fieldOfView = 40
        // No HDR post-processing: an off-screen snapshot does not apply it,
        // and the picture on screen and in `--shot` must be the same one.
        camera.wantsHDR = false
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.bloomIntensity = 0.12
        camera.bloomThreshold = 1.2
        camera.bloomBlurRadius = 6
        camera.vignettingIntensity = 0.35
        camera.vignettingPower = 0.9
        camera.minimumExposure = -2
        camera.maximumExposure = 2
        cameraNode.camera = camera
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)
    }

    func apply(camera pose: PoolCameraPose) {
        cameraNode.simdPosition = SIMD3<Float>(pose.position)
        cameraNode.simdOrientation = pose.orientation
        camera.fieldOfView = CGFloat(pose.fieldOfView)
        // The lamp is over the table; a camera that climbs up past it would
        // look at the back of its hood.
        let height = pose.position.y
        let fade = 1 - PoolTextures.smoothstep(Self.lampHeight + 0.35, Self.lampHeight + 0.75, height)
        lamp.opacity = CGFloat(fade)
        lamp.isHidden = fade <= 0.01
    }

    // MARK: Balls

    private func buildBalls() {
        for n in 0...15 {
            let ball = PoolBallNode(number: n, radius: geometry.ballRadius)
            balls[n] = ball
            scene.rootNode.addChildNode(ball.node)
            scene.rootNode.addChildNode(ball.contact)
            ball.hide()
        }
    }

    /// Every ball where the table says, the pocketed ones out of sight.
    func apply(table: PoolTableState) {
        var present = Set<Int>()
        for ball in table.balls {
            present.insert(ball.number)
            guard let node = balls[ball.number] else { continue }
            if ball.pocket != nil { node.hide() } else { node.place(position: ball.position, orientation: ball.orientation) }
        }
        for (n, node) in balls where !present.contains(n) { node.hide() }
    }

    /// Every ball at a moment of a shot.
    func apply(poses: [Int: PoolBallPose]) {
        for (n, pose) in poses {
            guard let node = balls[n] else { continue }
            if let id = pose.pocket, let pocket = geometry.pockets.first(where: { $0.id == id }) {
                node.drop(from: pose.position, orientation: pose.orientation, into: pocket, progress: pose.dropProgress)
            } else {
                node.place(position: pose.position, orientation: pose.orientation)
            }
        }
    }
}
