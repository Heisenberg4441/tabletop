//
//  GlassPanel.swift
//  The one material the chrome is made of.
//
//  Every panel, bar, pill and standalone button that floats over a table sits
//  on one of these. On macOS 26 and later it is real Liquid Glass
//  (`NSGlassEffectView`); on 14 and 15 it is the HUD vibrancy material, the
//  nearest thing those systems have; and while `--shot` is photographing a
//  screen it is drawn by hand, because both of the real materials are painted
//  by the window server and `CALayer.render(in:)` captures them as a flat white
//  slab. The drawn version is not a placeholder — it is tuned to read the way
//  dark glass reads over dark cloth, so a screenshot is a fair picture of the
//  app and a reviewer can judge the chrome from it.
//
//  Two rules come with it, both Apple's:
//
//  * Glass does not go on glass. A control inside a panel is drawn as a quiet
//    fill, never as a second pane; `CapsuleButton` notices by itself.
//  * A panel is a surface, not a hole. Clicks on its empty parts stop here
//    instead of falling through to the table underneath.
//

import AppKit

final class GlassPanel: NSView {

    /// How the material is produced. Decided once, when the panel is made.
    enum Rendering {
        /// `NSGlassEffectView`, macOS 26 and later.
        case liquidGlass
        /// `NSVisualEffectView` with the HUD material, before macOS 26.
        case vibrancy
        /// Painted with Core Graphics: for off-screen snapshots, which cannot
        /// capture either of the real materials.
        case drawn
    }

    /// What a panel made now should use: drawn while a snapshot is being
    /// taken, otherwise the best material the system has.
    static var preferredRendering: Rendering {
        if TabletopEnvironment.isRenderingSnapshot { return .drawn }
        if #available(macOS 26.0, *) { return .liquidGlass }
        return .vibrancy
    }

    let rendering: Rendering

    /// Put the panel's contents in here, not in the panel itself: on Liquid
    /// Glass this view is embedded in the glass so its contents are lit and
    /// tinted with it. It always fills the panel.
    let contentView = GlassContentView()

    /// Corner radius, with continuous corners. Ignored when `isCapsule`.
    var cornerRadius: CGFloat = Radius.panel {
        didSet { if cornerRadius != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// Ends that are always semicircles, whatever the height.
    var isCapsule = false {
        didSet { if isCapsule != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// A colour washed through the glass: a seat's team colour, a destructive
    /// panel's red. Keep it deep and let the material do the rest.
    var tint: NSColor? {
        didSet { applyTint(); needsDisplay = true }
    }

    /// The soft shadow a floating panel casts on the table. Liquid Glass
    /// brings its own and ignores this.
    var castsShadow = true {
        didSet { needsLayout = true }
    }

    private var material: NSView?

    init(cornerRadius: CGFloat = Radius.panel, capsule: Bool = false, tint: NSColor? = nil,
         rendering: Rendering = GlassPanel.preferredRendering) {
        self.rendering = rendering
        self.cornerRadius = cornerRadius
        self.isCapsule = capsule
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        contentView.autoresizingMask = [.width, .height]

        switch rendering {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.style = .regular
                glass.autoresizingMask = [.width, .height]
                glass.contentView = contentView
                addSubview(glass)
                material = glass
            } else {
                addSubview(contentView)
            }
        case .vibrancy:
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 0.5
            effect.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(contentView)
            addSubview(effect)
            material = effect
        case .drawn:
            addSubview(contentView)
        }
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The radius actually in force, capsule or not.
    var effectiveCornerRadius: CGFloat {
        isCapsule ? bounds.height / 2 : min(cornerRadius, min(bounds.width, bounds.height) / 2)
    }

    /// The panel's outline in its own coordinates.
    var outline: CGPath {
        isCapsule ? ContinuousShape.capsule(bounds)
            : ContinuousShape.roundedRect(bounds, radius: effectiveCornerRadius)
    }

    override func layout() {
        super.layout()
        material?.frame = bounds
        contentView.frame = bounds
        let radius = effectiveCornerRadius
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else if let effect = material {
            effect.layer?.cornerRadius = radius
        }
        guard let layer else { return }
        // Liquid Glass casts its own shadow; a second one under it doubles
        // the depth and muddies the edge.
        if castsShadow && rendering != .liquidGlass {
            Elevation.floating.apply(toFlipped: layer, path: outline)
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
    }

    private func applyTint() {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            glass.tintColor = tint?.withAlphaComponent(0.45)
        } else if let effect = material {
            effect.layer?.backgroundColor = tint?.withAlphaComponent(0.22).cgColor
        }
    }

    // MARK: The drawn material

    /// Dark glass, painted: a smoked body that lets the cloth show through, a
    /// sheen falling off the top edge where the light is, and a rim that
    /// catches the light along the top and loses it along the bottom.
    override func draw(_ dirtyRect: NSRect) {
        guard rendering == .drawn, let ctx = NSGraphicsContext.current?.cgContext else { return }
        GlassPanel.paintDrawnGlass(outline, in: bounds, tint: tint, context: ctx)
    }

    /// The drawn glass on its own, for anything that paints glass into a
    /// picture rather than being a view: a status pill in the window chrome,
    /// the kit gallery. `ctx` is top-left origin, like everything else here.
    static func paintDrawnGlass(_ path: CGPath, in rect: CGRect, tint: NSColor? = nil, context ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // The body: smoke, so the table underneath tints it the way it tints
        // real glass.
        ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.105, blue: 0.115, alpha: 0.58).cgColor)
        ctx.fill(rect)
        if let tint {
            ctx.setFillColor(tint.withAlphaComponent(0.30).cgColor)
            ctx.fill(rect)
        }
        // The sheen: brightest at the top, gone by the middle, a faint bounce
        // off the table at the very bottom.
        AppleStyle.fillVertical(rect, context: ctx, [
            (NSColor(white: 1, alpha: 0.13), 0),
            (NSColor(white: 1, alpha: 0.05), 0.45),
            (NSColor(white: 1, alpha: 0.02), 0.85),
            (NSColor(white: 1, alpha: 0.05), 1),
        ])
        ctx.restoreGState()

        // The rim, as a gradient: clip to a stroke of the outline and let a
        // vertical gradient decide how much light each part of it catches.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.addPath(path)
        ctx.setLineWidth(2)            // half lands outside and is clipped away
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        AppleStyle.fillVertical(rect, context: ctx, [
            (NSColor(white: 1, alpha: 0.42), 0),
            (NSColor(white: 1, alpha: 0.14), 0.35),
            (NSColor(white: 1, alpha: 0.08), 0.7),
            (NSColor(white: 1, alpha: 0.20), 1),
        ])
        ctx.restoreGState()
    }

    // MARK: Events

    // A panel is a surface: a click on its empty glass must not fall through
    // to the table — through the responder chain, a plain view hands an
    // unhandled mouse-down to its superview, which is the table.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// The view inside a `GlassPanel` that holds its contents. Flipped, like
/// every view in the kit, so frames are laid out from the top.
final class GlassContentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

extension NSView {
    /// True when this view sits inside a `GlassPanel` — where a control has
    /// to draw as a fill rather than as glass of its own.
    var isInsideGlassPanel: Bool {
        var view = superview
        while let current = view {
            if current is GlassPanel { return true }
            view = current.superview
        }
        return false
    }
}
