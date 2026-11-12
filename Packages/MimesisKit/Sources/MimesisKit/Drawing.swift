import CoreGraphics
import SwiftUI

/// A mark drawn on a clip: a pen, marker or pencil stroke, or a line, arrow, rectangle, circle or angle.
/// Points are in the video picture itself, 0–1 across and down (as filmed, before mirroring),
/// so a drawing stays on the player through zoom, pan, resizing and mirroring.
public struct Drawing: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case line, arrow, circle, angle, rectangle
        /// Drawn by hand with a pen, marker or pencil.
        case freehand
        public var id: Self { self }
    }

    /// What a freehand stroke was drawn with (shapes are drawn with the pen).
    public enum Brush: String, Codable, CaseIterable, Identifiable, Sendable {
        case pen, marker, pencil
        public var id: Self { self }
    }

    /// A colour, saved as numbers (sRGB, 0–1).
    public struct RGBA: Codable, Hashable, Sendable {
        public var r, g, b, a: Double

        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
        /// The same colour, solid (for swatches).
        var solid: RGBA { with(alpha: 1) }
    }

    public var id = UUID()
    public var kind: Kind
    /// Shapes: line, arrow: start and end; circle: centre and a point on the edge; rectangle: two corners;
    /// angle: arm end, vertex, arm end. Freehand: the stroke.
    public var points: [CGPoint]
    /// The clip time it was drawn on.
    public var time: Double
    /// Shown on every frame, not just its own.
    public var always: Bool
    /// The first drawings' four colours; `color` overrides it.
    public var ink: Ink
    /// The first drawings' three sizes; `width` overrides it.
    public var size: Size?
    public var color: RGBA?
    /// Line width in points on screen.
    public var width: Double?
    public var brush: Brush?
    /// Made in the overlay, over both pictures as they were placed then: shown only there, and removed
    /// when the top clip is moved (the drawing would no longer be where it was put).
    public var overlay: Bool?

    public enum Ink: String, Codable, CaseIterable, Sendable {
        case crimson, yellow, white, cyan
        var rgba: RGBA {
            switch self {
            case .crimson: RGBA(0.925, 0.227, 0.333)
            case .yellow: RGBA(1, 0.84, 0.2)
            case .white: RGBA(1, 1, 1)
            case .cyan: RGBA(0.3, 0.85, 1)
            }
        }
    }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case thin, medium, thick
        var scale: CGFloat {
            switch self {
            case .thin: 0.6
            case .medium: 1
            case .thick: 1.8
            }
        }
    }

    init(kind: Kind, points: [CGPoint], time: Double, always: Bool, color: RGBA, width: Double, brush: Brush) {
        self.kind = kind
        self.points = points
        self.time = time
        self.always = always
        self.ink = .crimson
        self.color = color
        self.width = width
        self.brush = brush
    }

    var resolvedColor: RGBA { color ?? ink.rgba }
    var resolvedWidth: Double { width ?? 3 * Double((size ?? .medium).scale) }
    var resolvedBrush: Brush { brush ?? .pen }
    var isShape: Bool { kind != .freehand }
}

// MARK: - Shape, shared by the screen and the export

extension Drawing {
    /// What to stroke for a drawing whose points are already placed (on screen, or in an export frame).
    struct Geometry {
        var path = CGMutablePath()
        /// The angle's arc, drawn thinner.
        var arc: CGMutablePath?
        /// The angle's reading and where it goes.
        var label: (text: String, at: CGPoint)?
        /// An arrow's head, filled.
        var head: CGMutablePath?
    }

    /// - Parameter unit: how big one screen point is where it's drawn (1 on screen).
    func geometry(_ points: [CGPoint], unit: CGFloat) -> Geometry {
        var g = Geometry()
        let width = CGFloat(resolvedWidth) * unit
        switch kind {
        case .freehand:
            g.path = Self.smooth(points)
        case .line:
            g.path.addLines(between: points)
        case .arrow:
            guard points.count == 2 else { break }
            let length = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
            guard length > 4 else {
                g.path.addLines(between: points)
                break
            }
            // A solid, pointed head, sized to the line; the line stops at its base.
            let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
            let head = min(length * 0.6, max(9 * unit, width * 3.6))
            let half = head * 0.42
            let base = CGPoint(x: points[1].x - head * cos(angle), y: points[1].y - head * sin(angle))
            g.path.move(to: points[0])
            g.path.addLine(to: CGPoint(x: base.x + head * 0.2 * cos(angle), y: base.y + head * 0.2 * sin(angle)))
            let tip = CGMutablePath()
            tip.move(to: points[1])
            tip.addLine(to: CGPoint(x: base.x - half * sin(angle), y: base.y + half * cos(angle)))
            tip.addLine(to: CGPoint(x: base.x + half * sin(angle), y: base.y - half * cos(angle)))
            tip.closeSubpath()
            g.head = tip
        case .circle:
            guard points.count == 2 else { break }
            let r = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
            g.path.addEllipse(in: CGRect(x: points[0].x - r, y: points[0].y - r, width: r * 2, height: r * 2))
        case .rectangle:
            guard points.count == 2 else { break }
            g.path.addRect(CGRect(
                x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y)))
        case .angle:
            guard points.count == 3 else { break }
            g.path.addLines(between: points)
            let (a, v, c) = (points[0], points[1], points[2])
            let start = atan2(a.y - v.y, a.x - v.x), end = atan2(c.y - v.y, c.x - v.x)
            var sweep = end - start
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            let radius = min(34 * unit, hypot(a.x - v.x, a.y - v.y) * 0.5, hypot(c.x - v.x, c.y - v.y) * 0.5)
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: v.x + radius * cos(start), y: v.y + radius * sin(start)))
            arc.addArc(center: v, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: sweep < 0)
            g.arc = arc
            let middle = start + sweep / 2
            g.label = ("\(Int((abs(sweep) * 180 / .pi).rounded()))°",
                       CGPoint(x: v.x + (radius + 26 * unit) * cos(middle), y: v.y + (radius + 26 * unit) * sin(middle)))
        }
        return g
    }

    /// A hand-drawn stroke, smoothed: curves through the midpoints between the points it went through.
    static func smooth(_ points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.count == 2 ? points[1] : first)
            return path
        }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// How a drawing lays down its colour.
    struct Look {
        /// On top of the colour's own opacity.
        let alpha: Double
        /// A dark edge under it, so it reads on any background.
        let shadow: Bool
        /// Square ends (a marker's chisel).
        let square: Bool
        /// A pencil's grain.
        let grain: Bool
    }

    var look: Look {
        switch (kind, resolvedBrush) {
        case (.freehand, .marker): Look(alpha: 0.5, shadow: false, square: true, grain: false)
        case (.freehand, .pencil): Look(alpha: 0.85, shadow: false, square: false, grain: true)
        default: Look(alpha: 1, shadow: true, square: false, grain: false)
        }
    }

    /// Draws it into a SwiftUI canvas, its points already in view coordinates.
    /// - Parameter labels: write an angle's degrees. Off where they're written apart, over the zoomed
    ///   picture at their own size (`DrawingLabels`).
    func render(_ points: [CGPoint], in context: inout GraphicsContext, labels: Bool = true) {
        let g = geometry(points, unit: 1)
        let path = Path(g.path)
        let width = CGFloat(resolvedWidth)
        let look = self.look
        let color = resolvedColor.with(alpha: resolvedColor.a * look.alpha).color
        let cap: CGLineCap = look.square ? .square : .round
        // A thin dark edge, in proportion to the line, so a fine line stays fine.
        let edge = Self.edge(for: width)
        if look.shadow {
            context.stroke(path, with: .color(.black.opacity(0.35)),
                           style: StrokeStyle(lineWidth: width + edge, lineCap: cap, lineJoin: .round))
            if let head = g.head {
                context.stroke(Path(head), with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: edge, lineJoin: .round))
            }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: cap, lineJoin: .round))
        if let head = g.head { context.fill(Path(head), with: .color(color)) }
        if look.grain {
            context.stroke(path, with: .color(.black.opacity(0.18)),
                           style: StrokeStyle(lineWidth: max(0.6, width * 0.45), lineCap: .butt, dash: [0.8, 1.6]))
        }
        if let arc = g.arc {
            context.stroke(Path(arc), with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: max(1.5, width * 0.66)))
        }
        if labels, let label = g.label {
            context.draw(
                Text(label.text).font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(.white),
                at: label.at)
        }
    }

    /// How much wider the dark edge under a line is than the line.
    static func edge(for width: CGFloat) -> CGFloat { min(2.5, max(0.8, width * 0.45)) }

    /// The box around the drawing, its points in view coordinates.
    func bounds(_ points: [CGPoint]) -> CGRect {
        let g = geometry(points, unit: 1)
        var box = g.path.boundingBoxOfPath
        if let head = g.head { box = box.union(head.boundingBoxOfPath) }
        return box.insetBy(dx: -CGFloat(resolvedWidth) / 2 - 4, dy: -CGFloat(resolvedWidth) / 2 - 4)
    }

    /// Whether `point` touches the drawing (both in view coordinates).
    func touches(_ point: CGPoint, points: [CGPoint], tolerance: CGFloat) -> Bool {
        let g = geometry(points, unit: 1)
        let wide = g.path.copy(strokingWithWidth: CGFloat(resolvedWidth) + tolerance * 2,
                               lineCap: .round, lineJoin: .round, miterLimit: 4)
        return wide.contains(point)
    }
}

extension Clip {
    /// The drawings to show at the playhead: those on this frame (within half a frame), and those on every frame.
    var visibleDrawings: [Drawing] { visibleDrawings(overlay: false) }

    /// - Parameter overlay: those made in the overlay, or those made on the clip by itself.
    func visibleDrawings(overlay: Bool) -> [Drawing] {
        let now = engine.currentTime
        return drawings.filter {
            ($0.overlay == true) == overlay && ($0.always || abs($0.time - now) <= frameLength * 0.6)
        }
    }
}

/// A clip's drawings over its video, and, while editing, drawing with the pen: freehand strokes,
/// shapes, the eraser, and dragging a shape's white dots to adjust it.
struct DrawingLayer: View {
    let clip: Clip
    let editing: Bool
    let pen: Pen
    /// In the overlay: its own drawings, apart from the clip's.
    var overlay = false

    private var shown: [Drawing] { clip.visibleDrawings(overlay: overlay) }

    @State private var draft: Drawing?
    /// What a drag with the select tool is doing: moving one point of the chosen drawing, or all of it.
    @State private var moving: Move?
    /// The stroke being drawn, in view points.
    @State private var stroke: [CGPoint] = []

    private struct Move {
        let id: UUID
        /// The point being dragged; nil moves the whole drawing (or resizes it, with `corner`).
        let point: Int?
        let from: [CGPoint]
        /// Resizing by a corner of the box: which corner (0 top left, clockwise), the box, and the
        /// drawing's points, all as they were on screen at the start.
        var corner: Int?
        var box: CGRect = .zero
        var fromView: [CGPoint] = []
    }

    /// An angle whose first arm is drawn: the next drag places its second arm.
    @State private var pendingAngle: UUID?

    private func corners(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    /// How close to a handle a drag must start to move it.
    private let grab: CGFloat = 16

    var body: some View {
        GeometryReader { space in
            let frame = pictureFrame(in: space.size)
            ZStack {
                Canvas { context, _ in
                    // (An angle's degrees are written by `DrawingLabels`, over the zoomed picture.)
                    for drawing in shown {
                        drawing.render(drawing.points.map { toView($0, frame) }, in: &context, labels: false)
                    }
                    if let draft {
                        let points = draft.kind == .freehand ? stroke : draft.points.map { toView($0, frame) }
                        draft.render(points, in: &context)
                    }
                }
                // Only the chosen drawing shows its box and handles (as in Photoshop): the rest stay clean.
                if editing, let chosen = shown.first(where: { $0.id == pen.selected }) {
                    let points = chosen.points.map { toView($0, frame) }
                    let box = chosen.bounds(points)
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: max(8, box.width), height: max(8, box.height))
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                    // A shape's own points reshape it; a hand-drawn stroke resizes by the corners of its box.
                    let handles = chosen.isShape ? points : corners(box)
                    ForEach(handles.indices, id: \.self) { index in
                        Group {
                            if chosen.isShape { Circle().fill(Color.white).overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5)) }
                            else { Rectangle().fill(Color.white).overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5)) }
                        }
                        .frame(width: 9, height: 9)
                        .position(handles[index])
                        .allowsHitTesting(false)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in changed(drag, frame) }
                    .onEnded { drag in ended(drag, frame) },
                isEnabled: editing)
            #if os(macOS)
            // What the pointer is over, for its shape.
            .onContinuousHover { phase in
                guard editing else { return }
                switch phase {
                case .active(let at): pen.over = over(at, frame)
                case .ended: pen.over = .nothing
                }
            }
            #endif
        }
        .allowsHitTesting(editing)
    }

    /// What's under the pointer: a point or box corner of the chosen drawing, a drawing, or nothing.
    private func over(_ at: CGPoint, _ frame: CGRect) -> Pen.Over {
        if moving != nil || draft != nil { return pen.over }
        if let chosen = shown.first(where: { $0.id == pen.selected }) {
            let points = chosen.points.map { toView($0, frame) }
            if chosen.isShape {
                if points.contains(where: { distance($0, at) < grab }) { return .point }
            } else if let corner = corners(chosen.bounds(points)).firstIndex(where: { distance($0, at) < grab }) {
                return .corner(corner)
            }
        }
        let hit = shown.contains { $0.touches(at, points: $0.points.map { toView($0, frame) }, tolerance: 8) }
        return hit ? .drawing : .nothing
    }

    // MARK: - Making, choosing, moving and erasing

    private func changed(_ drag: DragGesture.Value, _ frame: CGRect) {
        switch pen.tool {
        case .eraser:
            erase(at: drag.location, frame)
        case .select:
            select(drag, frame)
        default:
            draw(drag, frame)
        }
    }

    /// The select tool: press a drawing to choose it, drag to move it, drag one of its handles to
    /// reshape it; press anywhere else and nothing is chosen.
    private func select(_ drag: DragGesture.Value, _ frame: CGRect) {
        if moving == nil, drag.translation == .zero || distance(drag.startLocation, drag.location) < 1 {
            // The press: a handle of the chosen drawing, else the drawing under the pointer, else nothing.
            if let chosen = shown.first(where: { $0.id == pen.selected }) {
                let points = chosen.points.map { toView($0, frame) }
                if chosen.isShape, let index = points.firstIndex(where: { distance($0, drag.startLocation) < grab }) {
                    moving = Move(id: chosen.id, point: index, from: chosen.points)
                    return
                }
                let box = chosen.bounds(points)
                if !chosen.isShape, let corner = corners(box).firstIndex(where: { distance($0, drag.startLocation) < grab }) {
                    moving = Move(id: chosen.id, point: nil, from: chosen.points, corner: corner, box: box, fromView: points)
                    return
                }
            }
            if let hit = shown.reversed().first(where: {
                $0.touches(drag.startLocation, points: $0.points.map { toView($0, frame) }, tolerance: 8)
            }) {
                pen.select(hit)
                moving = Move(id: hit.id, point: nil, from: hit.points)
            } else {
                pen.selected = nil
            }
            return
        }
        guard let moving, let at = clip.drawings.firstIndex(where: { $0.id == moving.id }) else { return }
        if let point = moving.point {
            clip.drawings[at].points[point] = toVideo(drag.location, frame)
        } else if let corner = moving.corner {
            // Resize about the opposite corner, wider and taller as the corner is dragged.
            let from = corners(moving.box)
            let anchor = from[(corner + 2) % 4], grabbed = from[corner]
            let sx = abs(grabbed.x - anchor.x) > 1 ? (drag.location.x - anchor.x) / (grabbed.x - anchor.x) : 1
            let sy = abs(grabbed.y - anchor.y) > 1 ? (drag.location.y - anchor.y) / (grabbed.y - anchor.y) : 1
            clip.drawings[at].points = moving.fromView.map { p in
                toVideo(CGPoint(x: anchor.x + (p.x - anchor.x) * max(0.05, sx), y: anchor.y + (p.y - anchor.y) * max(0.05, sy)), frame)
            }
        } else {
            let start = toVideo(drag.startLocation, frame), here = toVideo(drag.location, frame)
            let dx = here.x - start.x, dy = here.y - start.y
            clip.drawings[at].points = moving.from.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
    }

    private func draw(_ drag: DragGesture.Value, _ frame: CGRect) {
        let here = toVideo(drag.location, frame)
        // An angle's second drag: its other arm follows the pointer, to any angle.
        if draft == nil, pen.tool == .angle, let pending = pendingAngle,
           let at = clip.drawings.firstIndex(where: { $0.id == pending }), clip.drawings[at].points.count == 3 {
            clip.drawings[at].points[2] = here
            return
        }
        // A press that hasn't moved yet draws nothing: it may be a click on a drawing, to choose it.
        if draft == nil, distance(drag.startLocation, drag.location) < 3 { return }
        if draft == nil {
            pen.selected = nil
            let start = toVideo(drag.startLocation, frame)
            draft = Drawing(
                kind: pen.tool.kind, points: [start, start], time: clip.engine.currentTime, always: pen.always,
                color: pen.color, width: pen.width, brush: pen.tool.brush)
            if overlay { draft?.overlay = true }
            stroke = [drag.startLocation]
        }
        guard var drawing = draft else { return }
        let start = toVideo(drag.startLocation, frame)
        switch drawing.kind {
        case .freehand:
            if let last = stroke.last, distance(last, drag.location) >= 1.5 { stroke.append(drag.location) }
            return
        case .line, .arrow, .circle, .rectangle:
            drawing.points = [start, here]
        case .angle:
            // Drag from the vertex along the first arm; the second arm opens 40° from it, to adjust after.
            let second = rotate(drag.location, around: drag.startLocation, by: -40)
            drawing.points = [here, start, toVideo(second, frame)]
        }
        draft = drawing
    }

    private func ended(_ drag: DragGesture.Value, _ frame: CGRect) {
        defer {
            draft = nil
            moving = nil
            stroke = []
        }
        if pen.tool.draws, draft == nil {
            // The angle's second arm is placed.
            if pendingAngle != nil {
                pendingAngle = nil
                return
            }
            // A click, not a drag: on a drawing, it's chosen (as with the select tool), to move or change.
            if let hit = shown.reversed().first(where: {
                $0.touches(drag.startLocation, points: $0.points.map { toView($0, frame) }, tolerance: 8)
            }) {
                pen.tool = .select
                pen.select(hit)
                return
            }
            // On nothing: a pen leaves a dot.
            if pen.tool.kind == .freehand {
                var dot = Drawing(kind: .freehand, points: [], time: clip.engine.currentTime, always: pen.always,
                                  color: pen.color, width: pen.width, brush: pen.tool.brush)
                if overlay { dot.overlay = true }
                let p = drag.startLocation
                dot.points = [toVideo(p, frame), toVideo(CGPoint(x: p.x + 0.5, y: p.y), frame)]
                clip.drawings.append(dot)
            }
            return
        }
        guard var drawing = draft else { return }
        if drawing.kind == .freehand {
            // A tap leaves a dot, as a pen does.
            if stroke.count == 1 { stroke.append(CGPoint(x: stroke[0].x + 0.5, y: stroke[0].y)) }
            drawing.points = stroke.map { toVideo($0, frame) }
        } else {
            // A tap, not a drag: no shape.
            guard distance(drag.startLocation, drag.location) > 8 else { return }
        }
        clip.drawings.append(drawing)
        // An angle: its first arm is drawn; the next drag places the second.
        pendingAngle = drawing.kind == .angle ? drawing.id : nil
    }

    /// The eraser takes away whole drawings it passes over, as Photos' object eraser does.
    private func erase(at point: CGPoint, _ frame: CGRect) {
        let shown = Set(shown.map(\.id))
        let gone = Set(clip.drawings.filter {
            shown.contains($0.id) && $0.touches(point, points: $0.points.map { toView($0, frame) }, tolerance: 10)
        }.map(\.id))
        guard !gone.isEmpty else { return }
        clip.drawings.removeAll { gone.contains($0.id) }
    }

    private func rotate(_ point: CGPoint, around center: CGPoint, by degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians))
    }

    // MARK: - Where the picture is

    /// The video picture inside the layer, as AVPlayer shows it (fit, centred).
    private func pictureFrame(in size: CGSize) -> CGRect {
        let video = clip.engine.videoSize
        guard video.width > 0, video.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    private var mirrored: Bool { clip.engine.mirroredHorizontally }

    private func toView(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        let x = mirrored ? 1 - point.x : point.x
        return CGPoint(x: frame.minX + x * frame.width, y: frame.minY + point.y * frame.height)
    }

    private func toVideo(_ point: CGPoint, _ frame: CGRect) -> CGPoint {
        let x = (point.x - frame.minX) / max(1, frame.width)
        return CGPoint(x: mirrored ? 1 - x : x, y: (point.y - frame.minY) / max(1, frame.height))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The degrees of the angles drawn on a clip, written over the zoomed video rather than zoomed with
/// it (like the skeleton's): they follow the picture, keep their size, and stay sharp.
struct DrawingLabels: View {
    let clip: Clip
    var overlay = false
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var body: some View {
        GeometryReader { space in
            let frame = pictureFrame(in: space.size)
            let centre = CGPoint(x: space.size.width / 2, y: space.size.height / 2)
            let mirrored = clip.engine.mirroredHorizontally
            let angles = clip.visibleDrawings(overlay: overlay).filter { $0.kind == .angle }
            Canvas { context, _ in
                for drawing in angles {
                    let points = drawing.points.map { p in
                        CGPoint(x: frame.minX + (mirrored ? 1 - p.x : p.x) * frame.width, y: frame.minY + p.y * frame.height)
                    }
                    guard let label = drawing.geometry(points, unit: 1).label else { continue }
                    let at = CGPoint(x: centre.x + (label.at.x - centre.x) * zoom + pan.width,
                                     y: centre.y + (label.at.y - centre.y) * zoom + pan.height)
                    let text = context.resolve(
                        Text(label.text).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(.white))
                    let size = text.measure(in: CGSize(width: 90, height: 30))
                    let box = CGRect(x: at.x - size.width / 2 - 4, y: at.y - size.height / 2 - 2,
                                     width: size.width + 8, height: size.height + 4)
                    context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(.black.opacity(0.6)))
                    context.draw(text, at: at)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pictureFrame(in size: CGSize) -> CGRect {
        let video = clip.engine.videoSize
        guard video.width > 0, video.height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
