import CoreGraphics
import CoreText
import Foundation

/// Draws a clip's marks into a transparent image the size of its frame, for exported videos:
/// the same lines, arrows, circles and angles (with their degrees) as on screen.
enum DrawingImage {
    /// The drawings shown on a frame at `time`: those drawn on it (within about half a frame) and those on every frame.
    static func visible(_ drawings: [Drawing], at time: Double, frameLength: Double) -> [Drawing] {
        drawings.filter { $0.always || abs($0.time - time) <= frameLength * 0.6 }
    }

    /// - Parameter mirrored: the frame is shown mirrored, so the marks (stored as filmed) are flipped too.
    static func image(_ drawings: [Drawing], size: CGSize, mirrored: Bool) -> CGImage? {
        guard !drawings.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw with y counting down from the top, as the marks do.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        // One screen point: about 1.5 px in a 1920-wide export, whichever way round the clip was filmed.
        let unit = max(1, max(size.width, size.height) / 720)

        for drawing in drawings {
            let points = drawing.points.map { p in
                CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width, y: p.y * size.height)
            }
            let g = drawing.geometry(points, unit: unit)
            let width = CGFloat(drawing.resolvedWidth) * unit
            let look = drawing.look
            let color = drawing.resolvedColor.with(alpha: drawing.resolvedColor.a * look.alpha)
            context.setLineCap(look.square ? .square : .round)
            context.setLineDash(phase: 0, lengths: [])
            // A dark edge under the colour, as on screen, so marks read on any background.
            if look.shadow {
                context.addPath(g.path)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
                context.setLineWidth(width + Drawing.edge(for: CGFloat(drawing.resolvedWidth)) * unit)
                context.strokePath()
            }
            context.addPath(g.path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokePath()
            if let head = g.head {
                context.addPath(head)
                context.setFillColor(color.cgColor)
                context.fillPath()
            }
            if look.grain {
                context.addPath(g.path)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
                context.setLineWidth(max(0.6, width * 0.45))
                context.setLineCap(.butt)
                context.setLineDash(phase: 0, lengths: [0.8 * unit, 1.6 * unit])
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
            }
            if let arc = g.arc {
                context.addPath(arc)
                context.setStrokeColor(color.with(alpha: color.a * 0.9).cgColor)
                context.setLineWidth(max(1.5 * unit, width * 0.66))
                context.strokePath()
            }
            if let label = g.label { draw(label.text, at: label.at, size: 15 * unit, in: context) }
        }
        return context.makeImage()
    }

    /// White bold text centred on `point` (in the flipped, top-down context).
    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(ctLine, context)
        context.saveGState()
        // Text draws upright only in a y-up space: undo the flip around the label.
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}

