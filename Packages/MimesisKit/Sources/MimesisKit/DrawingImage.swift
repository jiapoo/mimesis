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
        // About 4–5 px in a 1920-wide export, whichever way round the clip was filmed.
        let line = max(3, max(size.width, size.height) / 240)

        for drawing in drawings {
            let points = drawing.points.map { p in
                CGPoint(x: (mirrored ? 1 - p.x : p.x) * size.width, y: p.y * size.height)
            }
            let path = CGMutablePath()
            var label: (text: String, at: CGPoint)?
            switch drawing.kind {
            case .line:
                path.addLines(between: points)
            case .arrow:
                path.addLines(between: points)
                if points.count == 2, hypot(points[1].x - points[0].x, points[1].y - points[0].y) > 4 {
                    let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
                    for side in [-1.0, 1.0] {
                        let wing = angle + .pi + side * .pi / 7
                        path.move(to: points[1])
                        path.addLine(to: CGPoint(x: points[1].x + line * 5 * cos(wing), y: points[1].y + line * 5 * sin(wing)))
                    }
                }
            case .circle:
                guard points.count == 2 else { continue }
                let r = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
                path.addEllipse(in: CGRect(x: points[0].x - r, y: points[0].y - r, width: r * 2, height: r * 2))
            case .angle:
                guard points.count == 3 else { continue }
                path.addLines(between: points)
                let (a, v, c) = (points[0], points[1], points[2])
                let start = atan2(a.y - v.y, a.x - v.x), end = atan2(c.y - v.y, c.x - v.x)
                var sweep = end - start
                while sweep > .pi { sweep -= 2 * .pi }
                while sweep < -.pi { sweep += 2 * .pi }
                let radius = min(line * 11, hypot(a.x - v.x, a.y - v.y) * 0.5, hypot(c.x - v.x, c.y - v.y) * 0.5)
                path.move(to: CGPoint(x: v.x + radius * cos(start), y: v.y + radius * sin(start)))
                path.addArc(center: v, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: sweep < 0)
                let middle = start + sweep / 2
                label = ("\(Int((abs(sweep) * 180 / .pi).rounded()))°",
                         CGPoint(x: v.x + (radius + line * 9) * cos(middle), y: v.y + (radius + line * 9) * sin(middle)))
            }
            // A dark edge under the colour, as on screen, so marks read on any background.
            context.addPath(path)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.45))
            context.setLineWidth(line * 1.8)
            context.strokePath()
            context.addPath(path)
            context.setStrokeColor(drawing.ink.cgColor)
            context.setLineWidth(line)
            context.strokePath()
            if let label { draw(label.text, at: label.at, size: line * 5, in: context) }
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

extension Drawing.Ink {
    var cgColor: CGColor {
        switch self {
        case .crimson: CGColor(red: 0.925, green: 0.227, blue: 0.333, alpha: 1)
        case .yellow: CGColor(red: 1, green: 0.84, blue: 0.2, alpha: 1)
        case .white: CGColor(gray: 1, alpha: 1)
        case .cyan: CGColor(red: 0.3, green: 0.85, blue: 1, alpha: 1)
        }
    }
}
