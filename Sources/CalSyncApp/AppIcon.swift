import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The CalSync mark, drawn rather than shipped as image assets.
///
/// Two rounded squares — the two calendars — overlap, and their intersection is filled
/// solid. That intersection is literally what the app produces: the shared busy region
/// between two separate accounts.
///
/// One routine drives both the app icon and the menu bar icon so they cannot drift apart.
enum CalSyncMark {

    // MARK: - Geometry

    /// Draws the two-squares mark centred in a `size × size` canvas.
    /// Proportional throughout, so it is resolution-independent.
    private static func drawMark(
        in ctx: CGContext,
        size s: CGFloat,
        color: CGColor,
        side sideRatio: CGFloat,
        lineWidth lineRatio: CGFloat,
        corner cornerRatio: CGFloat,
        spread: CGFloat
    ) {
        let side = s * sideRatio
        let radius = s * cornerRatio
        let offset = s * spread

        // Offset on the diagonal: equal weight to both calendars, neither one "first".
        let a = CGRect(x: s / 2 - offset - side / 2, y: s / 2 + offset - side / 2,
                       width: side, height: side)
        let b = CGRect(x: s / 2 + offset - side / 2, y: s / 2 - offset - side / 2,
                       width: side, height: side)
        let pathA = CGPath(roundedRect: a, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let pathB = CGPath(roundedRect: b, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.setLineWidth(s * lineRatio)
        ctx.setStrokeColor(color)
        ctx.setLineJoin(.round)
        ctx.addPath(pathA)
        ctx.addPath(pathB)
        ctx.strokePath()

        // The overlap: clip to one square, fill the other. What remains is the intersection.
        ctx.saveGState()
        ctx.addPath(pathA)
        ctx.clip()
        ctx.setFillColor(color)
        ctx.addPath(pathB)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // MARK: - App icon

    private static func drawAppIcon(in ctx: CGContext, size s: CGFloat) {
        // macOS icons sit inside a transparent margin rather than filling the canvas.
        let inset = s * 0.055
        let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = rect.width * 0.2237  // approximates the system squircle

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(colorSpace: space, components: [0.35, 0.36, 0.90, 1.0])!,
            CGColor(colorSpace: space, components: [0.16, 0.66, 0.75, 1.0])!,
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: s),
                                   end: CGPoint(x: s, y: 0),
                                   options: [])
        }
        ctx.restoreGState()

        // Two sets of proportions, the way Apple ships different artwork per size.
        //
        // Large renders get generous margin around the glyph, which is the house style:
        // the mark spans a little over half the tile and lets the squircle breathe.
        //
        // Small renders keep the tighter, heavier geometry. Shrinking the glyph at 16pt
        // would push the stroke back under one pixel and smear the two squares into a
        // single blob, which is exactly the mush this sizing already fixed once.
        let white = CGColor(gray: 1, alpha: 1)
        if s <= 32 {
            drawMark(in: ctx, size: s, color: white,
                     side: 0.42, lineWidth: 0.105, corner: 0.09, spread: 0.12)
        } else {
            drawMark(in: ctx, size: s, color: white,
                     side: 0.33, lineWidth: 0.046, corner: 0.072, spread: 0.095)
        }
    }

    /// The full-colour mark, for use inside the app's own UI.
    static func appIconImage(points: CGFloat) -> NSImage? {
        let scale: CGFloat = 2
        guard let ctx = bitmapContext(pixels: Int(points * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        drawAppIcon(in: ctx, size: points)
        guard let cgImage = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: points, height: points))
    }

    // MARK: - Menu bar icon

    /// A template image: drawn in black with alpha, letting macOS tint it for light,
    /// dark, and highlighted menu bars automatically.
    static func statusItemImage(alert: Bool) -> NSImage? {
        let s: CGFloat = 18
        let scale: CGFloat = 2          // draw at 2× so the mark stays crisp on Retina
        guard let ctx = bitmapContext(pixels: Int(s * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let black = CGColor(gray: 0, alpha: 1)
        // Heavier strokes than the app icon for the same sub-pixel reason: at 18pt a
        // hairline outline disappears against the menu bar.
        drawMark(in: ctx, size: s, color: black,
                 side: 0.44, lineWidth: 0.095, corner: 0.10, spread: 0.125)

        if alert {
            // Punch a transparent gap first so the dot reads as separate from the mark.
            let centre = CGPoint(x: s * 0.84, y: s * 0.84)
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: centre.x - s * 0.20, y: centre.y - s * 0.20,
                                       width: s * 0.40, height: s * 0.40))
            ctx.setBlendMode(.normal)
            ctx.setFillColor(black)
            ctx.fillEllipse(in: CGRect(x: centre.x - s * 0.13, y: centre.y - s * 0.13,
                                       width: s * 0.26, height: s * 0.26))
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: s, height: s))
        image.isTemplate = true
        return image
    }

    // MARK: - Icon set export (used by build.sh)

    private static func bitmapContext(pixels: Int) -> CGContext? {
        let ctx = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setAllowsAntialiasing(true)
        ctx?.interpolationQuality = .high
        return ctx
    }

    /// Writes the PNGs `iconutil` expects. Called by `build.sh`, so the icon is rebuilt
    /// from source on every build and never committed as a binary.
    static func exportIconSet(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // (base point size, scale) — iconutil requires exactly these names.
        let variants: [(Int, Int)] = [
            (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
        ]

        for (points, scale) in variants {
            let pixels = points * scale
            guard let ctx = bitmapContext(pixels: pixels) else {
                throw IconError.contextFailed(pixels)
            }
            ctx.scaleBy(x: CGFloat(pixels) / CGFloat(points), y: CGFloat(pixels) / CGFloat(points))
            drawAppIcon(in: ctx, size: CGFloat(points))

            guard let image = ctx.makeImage() else { throw IconError.renderFailed(pixels) }
            let name = scale == 1
                ? "icon_\(points)x\(points).png"
                : "icon_\(points)x\(points)@2x.png"
            let url = directory.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw IconError.writeFailed(name)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw IconError.writeFailed(name)
            }
        }
    }

    enum IconError: LocalizedError {
        case contextFailed(Int)
        case renderFailed(Int)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .contextFailed(let px): return "Could not create a \(px)px drawing context."
            case .renderFailed(let px): return "Could not render the \(px)px icon."
            case .writeFailed(let name): return "Could not write \(name)."
            }
        }
    }
}
