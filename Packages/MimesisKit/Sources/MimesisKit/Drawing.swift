import SwiftUI

/// A mark drawn on a clip: a line, an arrow, a circle or an angle.
/// Points are in the video picture itself, 0–1 across and down (as filmed, before mirroring),
/// so a drawing stays on the player through zoom, pan, resizing and mirroring.
public struct Drawing: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Identifiable {
        case line, arrow, circle, angle
        public var id: Self { self }

        var symbol: String {
            switch self {
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .circle: "circle"
            case .angle: "angle"
            }
        }

        var title: String {
            switch self {
            case .line: "Line"
            case .arrow: "Arrow"
            case .circle: "Circle"
            case .angle: "Angle"
            }
        }
    }

    public enum Ink: String, Codable, CaseIterable, Identifiable {
        case crimson, yellow, white, cyan
        public var id: Self { self }

        var color: Color {
            switch self {
            case .crimson: Theme.accent
            case .yellow: Color(red: 1, green: 0.84, blue: 0.2)
            case .white: .white
            case .cyan: Color(red: 0.3, green: 0.85, blue: 1)
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    /// Line, arrow: start and end. Circle: centre and a point on the edge. Angle: arm end, vertex, arm end.
    public var points: [CGPoint]
    /// The clip time it was drawn on.
    public var time: Double
    /// Shown on every frame, not just its own.
    public var always: Bool
    public var ink: Ink
    /// The pen's size; nil in drawings made before there were sizes (medium).
    public var size: Size?

    public enum Size: String, Codable, CaseIterable, Identifiable {
        case thin, medium, thick
        public var id: Self { self }
        /// Against the medium pen.
        var scale: CGFloat {
            switch self {
            case .thin: 0.6
            case .medium: 1
            case .thick: 1.8
            }
        }
        var title: String { rawValue.capitalized }
    }

    var penSize: Size { size ?? .medium }
}

extension Clip {
    /// The drawings to show at the playhead: those on this frame (within half a frame), and those on every frame.
    var visibleDrawings: [Drawing] {
        let now = engine.currentTime
        return drawings.filter { $0.always || abs($0.time - now) <= frameLength * 0.6 }
    }
}

/// Draws a clip's marks over its video and, while editing, makes new ones and moves their points.
struct DrawingLayer: View {
    let clip: Clip
    let editing: Bool
    let pen: Pen

    @State private var draft: Drawing?
    @State private var moving: (id: UUID, index: Int)?

    /// How close a finger must come to a point to move it.
    private let grab: CGFloat = 22

    var body: some View {
        GeometryReader { space in
            let frame = pictureFrame(in: space.size)
            let shown = clip.visibleDrawings + (draft.map { [$0] } ?? [])
            ZStack {
                Canvas { context, _ in
                    for drawing in shown {
                        draw(drawing, points: drawing.points.map { toView($0, frame) }, in: &context)
                    }
                }
                if editing {
                    ForEach(clip.visibleDrawings) { drawing in
                        ForEach(drawing.points.indices, id: \.self) { index in
                            Circle()
                                .fill(Color.white)
                                .overlay(Circle().strokeBorder(drawing.ink.color, lineWidth: 2))
                                .frame(width: 12, height: 12)
                                .position(toView(drawing.points[index], frame))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in changed(drag, frame) }
                    .onEnded { drag in ended(drag, frame) },
                isEnabled: editing)
        }
        .allowsHitTesting(editing)
    }

    // MARK: - Making and moving

    private func changed(_ drag: DragGesture.Value, _ frame: CGRect) {
        let here = toVideo(drag.location, frame)
        if let moving, let at = clip.drawings.firstIndex(where: { $0.id == moving.id }) {
            clip.drawings[at].points[moving.index] = here
            return
        }
        if draft == nil {
            // Starting on a point of a shown drawing moves that point.
            for drawing in clip.visibleDrawings.reversed() {
                if let index = drawing.points.firstIndex(where: { distance(toView($0, frame), drag.startLocation) < grab }) {
                    moving = (drawing.id, index)
                    return
                }
            }
            let start = toVideo(drag.startLocation, frame)
            draft = Drawing(kind: pen.tool, points: [start, start], time: clip.engine.currentTime, always: pen.always, ink: pen.ink,
                            size: pen.size)
        }
        guard var drawing = draft else { return }
        let start = toVideo(drag.startLocation, frame)
        switch pen.tool {
        case .line, .arrow, .circle:
            drawing.points = [start, here]
        case .angle:
            // Drag from the vertex along the first arm; the second arm opens 40° from it, to adjust after.
            let first = CGPoint(x: drag.location.x, y: drag.location.y)
            let vertex = drag.startLocation
            let second = rotate(first, around: vertex, by: -40, frame: frame)
            drawing.points = [toVideo(first, frame), start, toVideo(second, frame)]
        }
        draft = drawing
    }

    private func ended(_ drag: DragGesture.Value, _ frame: CGRect) {
        defer {
            draft = nil
            moving = nil
        }
        guard moving == nil, let drawing = draft else { return }
        // A tap, not a drag: nothing to keep.
        guard distance(drag.startLocation, drag.location) > 8 else { return }
        clip.drawings.append(drawing)
    }

    private func rotate(_ point: CGPoint, around center: CGPoint, by degrees: Double, frame: CGRect) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians))
    }

    // MARK: - Drawing

    private func draw(_ drawing: Drawing, points: [CGPoint], in context: inout GraphicsContext) {
        let color = drawing.ink.color
        let scale = drawing.penSize.scale
        let style = StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round)
        let shadow = StrokeStyle(lineWidth: 5.5 * scale, lineCap: .round, lineJoin: .round)
        var path = Path()
        switch drawing.kind {
        case .line:
            path.addLines(points)
        case .arrow:
            path.addLines(points)
            if points.count == 2, distance(points[0], points[1]) > 4 {
                let angle = atan2(points[1].y - points[0].y, points[1].x - points[0].x)
                for side in [-1.0, 1.0] {
                    let wing = angle + .pi + side * .pi / 7
                    path.move(to: points[1])
                    path.addLine(to: CGPoint(x: points[1].x + 16 * cos(wing), y: points[1].y + 16 * sin(wing)))
                }
            }
        case .circle:
            let radius = distance(points[0], points[1])
            path.addEllipse(in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
        case .angle:
            guard points.count == 3 else { return }
            path.addLines(points)
            let (a, v, c) = (points[0], points[1], points[2])
            let start = atan2(a.y - v.y, a.x - v.x), end = atan2(c.y - v.y, c.x - v.x)
            var sweep = end - start
            while sweep > .pi { sweep -= 2 * .pi }
            while sweep < -.pi { sweep += 2 * .pi }
            let radius = min(34, distance(v, a) * 0.5, distance(v, c) * 0.5)
            var arc = Path()
            arc.addArc(center: v, radius: radius, startAngle: .radians(start), endAngle: .radians(start + sweep), clockwise: sweep < 0)
            context.stroke(arc, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 2))
            // The reading, outside the arc on the bisector.
            let middle = start + sweep / 2
            let label = CGPoint(x: v.x + (radius + 26) * cos(middle), y: v.y + (radius + 26) * sin(middle))
            let degrees = Int((abs(sweep) * 180 / .pi).rounded())
            context.draw(
                Text("\(degrees)°").font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(.white),
                at: label)
        }
        context.stroke(path, with: .color(.black.opacity(0.45)), style: shadow)
        context.stroke(path, with: .color(color), style: style)
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

/// The tools while drawing: shape, colour, pen size, this frame or every frame, undo, clear, done.
struct DrawingTools: View {
    /// The clips being drawn on (both, when drawing on both at once).
    let clips: [Clip]
    let pen: Pen
    let onUndo: () -> Void
    let canUndo: Bool
    let onDone: () -> Void

    var body: some View {
        @Bindable var pen = pen
        HStack(spacing: 6) {
            ForEach(Drawing.Kind.allCases) { kind in
                RoundButton(symbol: kind.symbol, active: pen.tool == kind) { pen.tool = kind }
                    .help(kind.title)
            }
            divider
            ForEach(Drawing.Ink.allCases) { option in
                Button { pen.ink = option } label: {
                    Circle().fill(option.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: pen.ink == option ? 2 : 0).padding(-3))
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            divider
            // The pen's size: a dot as thick as the line it draws.
            ForEach(Drawing.Size.allCases) { size in
                Button { pen.size = size } label: {
                    Circle().fill(Color.white)
                        .frame(width: 5 * size.scale + 2, height: 5 * size.scale + 2)
                        .frame(width: 26, height: 26)
                        .background(pen.size == size ? Color.white.opacity(0.22) : .clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("\(size.title) pen")
            }
            divider
            Button { pen.always.toggle() } label: {
                Text(pen.always ? "Every frame" : "This frame")
            }
            .buttonStyle(ChipStyle(active: pen.always))
            .help("Show new drawings on this frame only, or on every frame")
            divider
            RoundButton(symbol: "arrow.uturn.backward", action: onUndo)
                .help("Undo (⌘Z)")
                .disabled(!canUndo)
            RoundButton(symbol: "trash") { for clip in clips { clip.drawings.removeAll() } }
                .help(clips.count > 1 ? "Clear every drawing on both clips" : "Clear every drawing on this clip")
                .disabled(clips.allSatisfy(\.drawings.isEmpty))
            Button("Done", action: onDone)
                .buttonStyle(ChipStyle(active: true))
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 2)
    }
}
