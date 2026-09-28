//
//  PoolSceneView.swift
//  The window onto the table: a Metal SceneKit view that draws only when
//  something has changed, hands the mouse and keyboard to the game, and can
//  photograph itself without a screen.
//
//  ENERGY. `rendersContinuously` is off and the scene is not "playing" at
//  rest, so a still table costs nothing: SceneKit draws once after a change
//  and stops. While something moves — a shot rolling, the camera gliding,
//  the cue being drawn back — `PoolFrameClock` runs a display link on the
//  main run loop, the game advances its state by the real time elapsed,
//  and the view plays for exactly that long. The clock is only ever allowed
//  to run while the game is the active screen of a key, visible window.
//

import AppKit
import SceneKit
import QuartzCore

@MainActor
protocol PoolSceneViewInput: AnyObject {
    func poolMouseDown(_ event: NSEvent, at point: CGPoint)
    func poolMouseDragged(_ event: NSEvent, at point: CGPoint)
    func poolMouseUp(_ event: NSEvent, at point: CGPoint)
    func poolScroll(_ event: NSEvent)
    func poolMagnify(_ event: NSEvent)
    func poolKeyDown(_ event: NSEvent) -> Bool
    func poolKeyUp(_ event: NSEvent) -> Bool
}

final class PoolSceneView: SCNView {

    weak var input: PoolSceneViewInput?

    init(scene: SCNScene) {
        super.init(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        self.scene = scene
        rendersContinuously = false
        isPlaying = false
        antialiasingMode = .multisampling4X
        allowsCameraControl = false
        showsStatistics = false
        backgroundColor = Palette.room
        isJitteringEnabled = false
        preferredFramesPerSecond = 60
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(NSLocalizedString("Pool table", comment: "accessibility: the 3D pool table"))
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A point in the view's own coordinates (bottom-left origin, which is
    /// also what `projectPoint` and `unprojectPoint` use).
    private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        input?.poolMouseDown(event, at: location(event))
    }
    override func mouseDragged(with event: NSEvent) { input?.poolMouseDragged(event, at: location(event)) }
    override func mouseUp(with event: NSEvent) { input?.poolMouseUp(event, at: location(event)) }
    override func scrollWheel(with event: NSEvent) { input?.poolScroll(event) }
    override func magnify(with event: NSEvent) { input?.poolMagnify(event) }
    override func rightMouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if input?.poolKeyDown(event) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if input?.poolKeyUp(event) != true { super.keyUp(with: event) }
    }

    // MARK: Where the pointer is on the cloth

    /// Where the ray under `point` meets the horizontal plane at `height`,
    /// in table coordinates, or nil if it misses it (above the horizon).
    func tablePoint(under point: CGPoint, height: Double) -> SIMD2<Double>? {
        let near = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = unprojectPoint(SCNVector3(point.x, point.y, 1))
        let a = SIMD3<Double>(Double(near.x), Double(near.y), Double(near.z))
        let b = SIMD3<Double>(Double(far.x), Double(far.y), Double(far.z))
        let dy = b.y - a.y
        guard abs(dy) > 1e-9 else { return nil }
        let t = (height - a.y) / dy
        guard t > 0 else { return nil }
        let hit = a + (b - a) * t
        return SIMD2(hit.x, -hit.z)
    }

    /// A scene point on screen, in this view's coordinates, and whether it
    /// is in front of the camera.
    func screenPoint(of p: SIMD3<Float>) -> CGPoint? {
        let v = projectPoint(SCNVector3(p))
        guard v.z > 0, v.z < 1 else { return nil }
        return CGPoint(x: v.x, y: v.y)
    }

    // MARK: A picture without a screen

    /// The scene through its camera, `scale` pixels per point, rendered off
    /// screen with the same antialiasing — what `--shot` puts under the HUD.
    func renderImage(scale: CGFloat = 2) -> CGImage? {
        guard let scene, let device = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.isJitteringEnabled = false
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// The display link that runs while something on the table moves, and only
/// then. The game asks for frames with `request()`; every tick hands it the
/// real time since the last one (capped, so a hitch never teleports a
/// ball); when the game says nothing more is moving the link goes away.
@MainActor
final class PoolFrameClock: NSObject {

    /// Called every frame with the elapsed seconds; returns whether another
    /// frame is wanted.
    var onFrame: ((Double) -> Bool)?
    /// Called when the clock starts or stops, so the view can play or rest.
    var onRunningChanged: ((Bool) -> Void)?

    /// Whether frames may run at all: the game is in front, in a key and
    /// visible window. Turning it off stops the clock at once; nothing is
    /// lost, the next request carries on from where things were.
    var isAllowed = false {
        didSet {
            guard isAllowed != oldValue else { return }
            if !isAllowed { stop() } else if wantsFrames { start() }
        }
    }

    private weak var view: NSView?
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    /// A request made while not allowed, honoured when allowed again.
    private var wantsFrames = false

    init(view: NSView) {
        self.view = view
    }

    var isRunning: Bool { link != nil }

    func request() {
        wantsFrames = true
        guard isAllowed, link == nil else { return }
        start()
    }

    private func start() {
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        last = nil
        onRunningChanged?(true)
    }

    private func stop() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        last = nil
        onRunningChanged?(false)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last.map { min(1.0 / 20, max(0, now - $0)) } ?? (1.0 / 60)
        last = now
        let more = onFrame?(dt) ?? false
        if !more {
            wantsFrames = false
            stop()
        }
    }
}
