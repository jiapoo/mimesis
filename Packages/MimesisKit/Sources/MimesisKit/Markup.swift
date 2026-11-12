import SwiftUI

/// The drawing tools' settings: the tool in hand, each tool's own colour and width (kept while you
/// switch between them), and the drawing chosen with the select tool. One for the whole comparison,
/// so drawing on both clips at once uses the same tools.
@MainActor @Observable
final class Pen {
    enum Tool: String, CaseIterable, Identifiable {
        case select
        case pen, marker, pencil, eraser
        case line, arrow, rectangle, circle, angle
        var id: Self { self }

        static let brushes: [Tool] = [.pen, .marker, .pencil, .eraser]
        static let shapes: [Tool] = [.line, .arrow, .rectangle, .circle, .angle]

        var isShape: Bool { Self.shapes.contains(self) }
        /// Draws something (so it has a colour and a width).
        var draws: Bool { self != .select && self != .eraser }

        var kind: Drawing.Kind {
            switch self {
            case .select, .pen, .marker, .pencil, .eraser: .freehand
            case .line: .line
            case .arrow: .arrow
            case .rectangle: .rectangle
            case .circle: .circle
            case .angle: .angle
            }
        }

        var brush: Drawing.Brush {
            switch self {
            case .marker: .marker
            case .pencil: .pencil
            default: .pen
            }
        }

        var title: String {
            switch self {
            case .select: "Select and move (V)"
            case .pen: "Pen (P)"
            case .marker: "Marker: wide and see-through (M)"
            case .pencil: "Pencil: fine, with a grain (N)"
            case .eraser: "Eraser: drag over a drawing (E)"
            case .line: "Line (L)"
            case .arrow: "Arrow (A)"
            case .rectangle: "Rectangle (R)"
            case .circle: "Circle (O)"
            case .angle: "Angle, in degrees: drag the first arm from the joint, then drag again for the second arm"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .pen: "pencil.tip"
            case .marker: "highlighter"
            case .pencil: "pencil"
            case .eraser: "eraser"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .rectangle: "rectangle"
            case .circle: "circle"
            case .angle: "angle"
            }
        }

        /// The widths the thickness slider offers, in points.
        var widthRange: ClosedRange<Double> {
            switch self {
            case .marker: 6...48
            case .pencil: 0.5...8
            default: 0.5...20
            }
        }

        var defaultWidth: Double {
            switch self {
            case .marker: 20
            case .pencil: 1.5
            default: 2
            }
        }

        var defaultColor: Drawing.RGBA {
            switch self {
            case .marker: Palette.yellow
            case .pencil: Palette.white
            default: Palette.crimson
            }
        }
    }

    var tool: Tool = .pen {
        didSet { if tool != .select { selected = nil } }
    }
    var always = false
    /// Space is held (Mac): drags move the video instead of drawing.
    var panning = false
    /// The button is down while Space is held: the hand closes.
    var grabbing = false
    /// What the pointer is over, for its shape (Mac): nothing, a drawing, one of the chosen drawing's
    /// points, or a corner of its box (0 top left, clockwise).
    enum Over: Equatable { case nothing, drawing, point, corner(Int) }
    var over: Over = .nothing
    /// How far the options bar has been dragged from its place at the top.
    var barOffset: CGSize = .zero
    /// The drawing chosen with the select tool: its box and handles show, and the options bar changes it.
    var selected: UUID?
    private var colors: [Tool: Drawing.RGBA] = [:]
    private var widths: [Tool: Double] = [:]

    var color: Drawing.RGBA {
        get { colors[tool] ?? tool.defaultColor }
        set { colors[tool] = newValue }
    }

    var width: Double {
        get { widths[tool] ?? tool.defaultWidth }
        set { widths[tool] = newValue }
    }

    /// Chooses a drawing; the options bar then shows its colour and width.
    func select(_ drawing: Drawing) {
        selected = drawing.id
        colors[.select] = drawing.resolvedColor
        widths[.select] = drawing.resolvedWidth
    }
}

/// The colours a tap away; any other from the colour picker.
enum Palette {
    static let crimson = Drawing.RGBA(0.925, 0.227, 0.333)
    static let yellow = Drawing.RGBA(1, 0.84, 0.2)
    static let white = Drawing.RGBA(1, 1, 1)
    static let cyan = Drawing.RGBA(0.3, 0.85, 1)
    static let green = Drawing.RGBA(0.33, 0.86, 0.45)
    static let black = Drawing.RGBA(0.08, 0.08, 0.09)
    static let all = [crimson, yellow, white, cyan, green, black]

    static func name(of color: Drawing.RGBA) -> String {
        switch color.solid {
        case crimson: "Crimson"
        case yellow: "Yellow"
        case white: "White"
        case cyan: "Cyan"
        case green: "Green"
        case black: "Black"
        default: "Colour"
        }
    }
}

/// The drawing tools, laid out as in Photoshop: `strip`, the tools down the left edge (select, the
/// brushes, the shapes), and `options`, a bar across the top for the tool in hand: colour, a
/// thickness slider, opacity, this frame or every frame, undo and redo, Done.
struct MarkupTools: View {
    enum Part { case strip, options }

    let part: Part
    /// The clips being drawn on (both, when drawing on both at once).
    let clips: [Clip]
    let pen: Pen
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onDone: () -> Void
    /// Little room (an iPhone on its side): the strip in two columns, a shorter options bar.
    var compact = false

    @Environment(\.self) private var environment
    @State private var gripFrom: CGSize?

    var body: some View {
        switch part {
        case .strip: strip
        case .options: options
        }
    }

    // MARK: - The tool strip

    private var strip: some View {
        let groups: [[Pen.Tool]] = [[.select], Pen.Tool.brushes, Pen.Tool.shapes]
        return Group {
            if compact {
                // Two columns: select and the brushes, then the shapes.
                HStack(alignment: .top, spacing: 4) {
                    VStack(spacing: 4) { ForEach([Pen.Tool.select] + Pen.Tool.brushes) { toolButton($0) } }
                    VStack(spacing: 4) { ForEach(Pen.Tool.shapes) { toolButton($0) } }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, tools in
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 22, height: 1).padding(.vertical, 2)
                        }
                        ForEach(tools) { toolButton($0) }
                    }
                }
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .fixedSize()
        .plainPointer()
    }

    private func toolButton(_ tool: Pen.Tool) -> some View {
        let on = pen.tool == tool
        return Button { pen.tool = tool } label: {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Theme.onAccent : Color.white)
                .frame(width: compact ? 30 : 34, height: compact ? 28 : 32)
                .background(on ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.title)
    }

    // MARK: - The options bar

    private var chosen: Drawing? {
        guard let id = pen.selected else { return nil }
        for clip in clips { if let drawing = clip.drawings.first(where: { $0.id == id }) { return drawing } }
        return nil
    }

    /// Changes the chosen drawing too (with the select tool, the bar edits what's chosen).
    private func change(_ edit: (inout Drawing) -> Void) {
        guard let id = pen.selected else { return }
        for clip in clips {
            if let at = clip.drawings.firstIndex(where: { $0.id == id }) { edit(&clip.drawings[at]) }
        }
    }

    private var hasLook: Bool { pen.tool.draws || chosen != nil }

    private var options: some View {
        HStack(spacing: 10) {
            grip
            // (Undo and redo are in the top bar; on an iPhone, in the bar under the clips.)
            if hasLook {
                colours
                divider
                thickness
                if !compact {
                    divider
                    opacity
                }
                if pen.tool == .angle {
                    divider
                    Text("Drag one arm from the joint, then drag again for the other")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            } else {
                Text(pen.tool == .eraser ? "Drag over a drawing to erase it" : "Click a drawing to choose it; drag to move or resize it")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            divider
            if pen.tool == .eraser {
                Button("Erase this frame") {
                    for clip in clips {
                        let shown = Set((clip.visibleDrawings(overlay: false) + clip.visibleDrawings(overlay: true)).map(\.id))
                        clip.drawings.removeAll { shown.contains($0.id) }
                    }
                }
                .buttonStyle(ChipStyle())
                .help("Erase everything drawn on this frame")
            } else if chosen != nil {
                RoundButton(symbol: "plus.square.on.square", size: 28) { duplicate() }
                    .help("Duplicate the chosen drawing")
                RoundButton(symbol: "trash", size: 28) {
                    let id = pen.selected
                    for clip in clips { clip.drawings.removeAll { $0.id == id } }
                    pen.selected = nil
                }
                .help("Delete the chosen drawing (Delete)")
            }
            Button {
                pen.always.toggle()
                change { $0.always = pen.always }
            } label: {
                Label(compact ? "" : (pen.always ? "Every frame" : "This frame"),
                      systemImage: pen.always ? "square.stack.3d.up.fill" : "square")
            }
            .buttonStyle(ChipStyle(active: pen.always))
            .help(pen.always ? "Drawings show on every frame. Tap for this frame only." : "Drawings show on this frame only. Tap for every frame.")
            Button("Done", action: onDone)
                .buttonStyle(ChipStyle(active: true))
                .help("Stop drawing (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .fixedSize()
        .plainPointer()
    }

    /// The bar's handle: drag it to move the bar off what you're drawing; double-click puts it back.
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.secondary)
            .frame(width: 22, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = gripFrom ?? pen.barOffset
                        gripFrom = start
                        pen.barOffset = CGSize(width: start.width + drag.translation.width,
                                               height: start.height + drag.translation.height)
                    }
                    .onEnded { _ in gripFrom = nil })
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { pen.barOffset = .zero } }
            .help("Drag to move this bar; double-click to put it back")
    }

    /// A copy of the chosen drawing, a little down and to the right, chosen in its place.
    private func duplicate() {
        guard let id = pen.selected else { return }
        for clip in clips {
            guard let original = clip.drawings.first(where: { $0.id == id }) else { continue }
            var copy = original
            copy.id = UUID()
            copy.points = original.points.map { CGPoint(x: $0.x + 0.02, y: $0.y + 0.02) }
            clip.drawings.append(copy)
            pen.select(copy)
        }
    }

    private var colours: some View {
        HStack(spacing: 4) {
            ForEach(Palette.all, id: \.self) { color in
                let on = pen.color.solid == color.solid
                Button {
                    pen.color = color.with(alpha: pen.color.a)
                    change { $0.color = pen.color }
                } label: {
                    Circle().fill(color.color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0).padding(-3))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Palette.name(of: color))
            }
            colorWheel
        }
    }

    /// Thickness: a slider, a dot as thick as the line it draws, and the width in points.
    private var thickness: some View {
        let range = pen.tool == .select ? 0.5...48 : pen.tool.widthRange
        return HStack(spacing: 6) {
            Image(systemName: "lineweight").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            // Finer steps at the thin end, where they matter most.
            SlimSlider(value: Binding(
                get: { sqrt((pen.width - range.lowerBound) / (range.upperBound - range.lowerBound)) },
                set: { share in
                    let width = range.lowerBound + share * share * (range.upperBound - range.lowerBound)
                    pen.width = (width * 2).rounded() / 2
                    change { $0.width = pen.width }
                }), range: 0...1)
                .frame(width: compact ? 80 : 120)
            ZStack {
                Circle().fill(pen.color.solid.color)
                    .frame(width: min(22, max(1.5, pen.width)), height: min(22, max(1.5, pen.width)))
            }
            .frame(width: 22, height: 22)
            Text(pen.width.formatted(.number.precision(.fractionLength(0...1))))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 28, alignment: .leading)
        }
        .help("Thickness, in points")
    }

    private var opacity: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            SlimSlider(value: Binding(
                get: { pen.color.a },
                set: {
                    pen.color = pen.color.with(alpha: max(0.1, $0))
                    change { $0.color = pen.color }
                }), range: 0.1...1)
                .frame(width: 70)
            // (Wide enough for "100%" on one line.)
            Text("\(Int((pen.color.a * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .frame(width: 38, alignment: .leading)
        }
        .help("Opacity")
    }

    /// Any colour: the system colour picker (on iPhone and iPad the same as Photos'), behind a colour wheel.
    private var colorWheel: some View {
        ColorPicker("", selection: Binding(
            get: { pen.color.color },
            set: { color in
                let r = color.resolve(in: environment)
                pen.color = Drawing.RGBA(Double(r.red), Double(r.green), Double(r.blue), Double(r.opacity))
                change { $0.color = pen.color }
            }), supportsOpacity: true)
            .labelsHidden()
            #if os(macOS)
            // The Mac's picker is a wide well: keep it to a circle, under the wheel.
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center), lineWidth: 4)
                    .background(Circle().fill(pen.color.solid.color).padding(5))
                    .allowsHitTesting(false)
            }
            #endif
            .frame(width: 26, height: 28)
            .help("Any colour")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 22)
    }
}

// MARK: - The pointer's shape (Mac)

extension View {
    /// While drawing, the pointer says what a press will do, as in Photoshop: a crosshair to draw, a
    /// hand to move (Space held, or over a drawing with the select tool), a pointing hand over a
    /// drawing a click would choose, resize arrows on a corner of the chosen drawing's box, an eraser.
    @ViewBuilder func drawingPointer(_ pen: Pen, on: Bool) -> some View {
        #if os(macOS)
        pointerStyle(on ? pen.pointer : nil)
        #else
        self
        #endif
    }

    /// The ordinary arrow, over the drawing tools themselves.
    @ViewBuilder func plainPointer() -> some View {
        #if os(macOS)
        pointerStyle(.default)
        #else
        self
        #endif
    }
}

#if os(macOS)
extension Pen {
    var pointer: PointerStyle {
        if panning { return grabbing ? .grabActive : .grabIdle }
        switch over {
        case .point:
            return .rectSelection
        case .corner(let corner):
            let positions: [FrameResizePosition] = [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading]
            return .frameResize(position: positions[corner % 4])
        case .drawing:
            if tool == .eraser { return .image(Self.eraserPointer, hotSpot: .bottomLeading) }
            return tool == .select ? .grabIdle : .link
        case .nothing:
            switch tool {
            case .select: return .default
            case .eraser: return .image(Self.eraserPointer, hotSpot: .bottomLeading)
            default: return .rectSelection
            }
        }
    }

    /// A white eraser with a dark edge, to show on any video.
    private static let eraserPointer: Image = {
        let renderer = ImageRenderer(content:
            Image(systemName: "eraser.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 1)
                .shadow(color: .black, radius: 1)
                .padding(3))
        renderer.scale = 2
        if let image = renderer.nsImage { return Image(nsImage: image) }
        return Image(systemName: "eraser.fill")
    }()
}
#endif
