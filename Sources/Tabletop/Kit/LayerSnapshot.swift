//
//  LayerSnapshot.swift
//  A view, drawn into a bitmap through Core Animation.
//
//  How `--shot` photographs a game without putting a window on anybody's
//  screen. `NSView.cacheDisplay(in:to:)` would be the obvious tool, but it
//  replays `draw(_:)` and nothing else — and the interesting parts of a card
//  table are layers added by hand, which it never sees. `CALayer.render(in:)`
//  walks the real layer tree, the same one the compositor shows.
//
//  Two things it cannot capture, and every caller should know: content that
//  is not drawn by Core Animation at all (SceneKit, Metal — those views take
//  their own snapshot), and the live blur behind a glass or vibrancy panel,
//  which the window server paints. Those come out as whatever is underneath.
//
//  For the first there is `underlay`: a SceneKit game passes
//  `scnView.snapshot()` (which works in a window that is never shown) and the
//  rest of its view — the glass HUD, the action bar, a banner — is rendered
//  over it. For that to come out right, the root view and every ancestor of
//  the SCNView must have no opaque background of its own, or it paints over
//  the scene; the SCNView's own layer renders as a transparent hole.
//

import AppKit
import QuartzCore

enum LayerSnapshot {

    /// `view` at `size` points and `scale` pixels per point, or nil if the view
    /// has no layer or the bitmap could not be made. Lays the view out and
    /// displays it first, so it can be called straight after a state change.
    static func image(of view: NSView, size: CGSize, scale: CGFloat) -> CGImage? {
        image(of: view, size: size, scale: scale, underlay: nil)
    }

    /// The same, with `underlay` drawn first, stretched over the whole
    /// bitmap: the picture of whatever Core Animation cannot draw — a
    /// SceneKit view's `snapshot()` — for the view's layers to go on top of.
    /// `underlay` is taken as covering exactly `view`'s bounds.
    static func image(of view: NSView, size: CGSize, scale: CGFloat, underlay: CGImage?) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // AppKit attaches a new subview's layer to the tree lazily, at the end
        // of the current Core Animation transaction. Without this, a view
        // built a moment ago renders as its background and nothing on it.
        CATransaction.flush()
        guard let layer = view.layer,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: max(1, Int((size.width * scale).rounded())),
                height: max(1, Int((size.height * scale).rounded())),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        if let underlay {
            ctx.interpolationQuality = .high
            ctx.draw(underlay, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
        ctx.scaleBy(x: scale, y: scale)
        // `render(in:)` draws in the layer's own geometry. A flipped view's
        // layer is geometry-flipped, so its sublayers are laid out top-down and
        // the context has to be turned over to match; an ordinary view's layer
        // is bottom-up already, like the context.
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Writes an image as a PNG. Returns false, having said why on standard
    /// error, if it could not.
    @discardableResult
    static func writePNG(_ image: CGImage, to path: String) -> Bool {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode \(path)\n".utf8))
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("\(path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
