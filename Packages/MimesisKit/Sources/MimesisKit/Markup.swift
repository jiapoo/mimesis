import SwiftUI

/// The drawing tools' settings, as in Photos' Markup: the tool in hand, and each tool's own colour and
/// width, kept while you switch between them. One for the whole comparison, so drawing on both clips
/// at once uses the same pen.
@MainActor @Observable
final class Pen {
    enum Tool: String, CaseIterable, Identifiable {
        case pen, marker, pencil, eraser
        case line, arrow, rectangle, circle, angle
        var id: Self { self }

        static let pens: [Tool] = [.pen, .marker, .pencil, .eraser]
        static let shapes: [Tool] = [.line, .arrow, .rectangle, .circle, .angle]

        var isShape: Bool { Self.shapes.contains(self) }

        var kind: Drawing.Kind {
            switch self {
            case .pen, .marker, .pencil, .eraser: .freehand
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
            case .pen: "Pen"
            case .marker: "Marker"
            case .pencil: "Pencil"
            case .eraser: "Eraser"
            case .line: "Line"
            case .arrow: "Arrow"
            case .rectangle: "Rectangle"
            case .circle: "Circle"
            case .angle: "Angle"
            }
        }

        var symbol: String {
            switch self {
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

        /// The widths offered, thinnest first.
        var widths: [Double] {
            switch self {
            case .marker: [8, 14, 20, 28, 36]
            case .pencil: [1, 2, 3, 5, 8]
            default: [1.5, 3, 5, 8, 12]
            }
        }

        var defaultWidth: Double {
            switch self {
            case .marker: 20
            case .pencil: 2
            default: 3
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

    var tool: Tool = .pen
    /// The shape "+" draws, last chosen.
    var shape: Tool = .arrow
    var always = false
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

    func color(of tool: Tool) -> Drawing.RGBA { colors[tool] ?? tool.defaultColor }
    func width(of tool: Tool) -> Double { widths[tool] ?? tool.defaultWidth }
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

/// The drawing toolbar, after Photos' Markup: undo and redo; the pen, marker, pencil and eraser as pen
/// tips (the one in hand raised, showing its colour and width; tap it again for its width and
/// opacity); "+" for shapes (line, arrow, rectangle, circle, and the angle that measures); the colours
/// and the colour picker; this frame or every frame; Done.
struct MarkupTools: View {
    /// The clips being drawn on (both, when drawing on both at once).
    let clips: [Clip]
    let pen: Pen
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onDone: () -> Void

    @State private var options: Pen.Tool?
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                RoundButton(symbol: "arrow.uturn.backward", action: onUndo)
                    .disabled(!canUndo).opacity(canUndo ? 1 : 0.4)
                    .help("Undo (⌘Z)")
                RoundButton(symbol: "arrow.uturn.forward", action: onRedo)
                    .disabled(!canRedo).opacity(canRedo ? 1 : 0.4)
                    .help("Redo (⇧⌘Z)")
            }
            divider
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Pen.Tool.pens) { tool in
                    tipButton(tool)
                }
                shapes
            }
            .frame(height: 44, alignment: .bottom)
            .clipped()
            divider
            HStack(spacing: 5) {
                ForEach(Palette.all, id: \.self) { swatch($0) }
                colorWheel
            }
            .disabled(pen.tool == .eraser)
            .opacity(pen.tool == .eraser ? 0.35 : 1)
            divider
            Button { pen.always.toggle() } label: {
                Image(systemName: pen.always ? "square.stack.3d.up.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(pen.always ? Theme.onAccent : .white)
                    .background(pen.always ? Theme.accent : Color.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help(pen.always ? "New drawings show on every frame" : "New drawings show on this frame only")
            Button("Done", action: onDone)
                .buttonStyle(ChipStyle(active: true))
                .help("Stop drawing (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .fixedSize()
    }

    // MARK: - Pens

    private func tipButton(_ tool: Pen.Tool) -> some View {
        let chosen = pen.tool == tool
        return Button {
            if chosen { options = tool } else { pen.tool = tool }
        } label: {
            PenTip(tool: tool, color: pen.color(of: tool).solid.color, width: pen.width(of: tool))
                .offset(y: chosen ? 0 : 18)
                .frame(width: 26, height: 44, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(chosen ? "\(tool.title): tap again for its \(tool == .eraser ? "options" : "width and opacity")" : tool.title)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: chosen)
        .popover(isPresented: Binding(get: { options == tool }, set: { if !$0 { options = nil } })) {
            ToolOptions(pen: pen, clips: clips) { options = nil }
                .presentationCompactAdaptation(.popover)
        }
    }

    /// "+": the shapes. The one last used shows; tap it to draw it, or pick another.
    private var shapes: some View {
        let chosen = pen.tool.isShape
        return Menu {
            ForEach(Pen.Tool.shapes) { shape in
                Button { pen.shape = shape; pen.tool = shape } label: {
                    Label(shape.title, systemImage: shape.symbol)
                }
            }
            if chosen {
                Divider()
                Button("Width and opacity…", systemImage: "lineweight") { options = pen.tool }
            }
        } label: {
            Image(systemName: chosen ? pen.tool.symbol : "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(chosen ? Theme.onAccent : .white)
                .frame(width: 32, height: 32)
                .background(chosen ? Theme.accent : Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(chosen ? 0 : 0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 6)
        .help("Shapes: line, arrow, rectangle, circle, and an angle that measures")
        .popover(isPresented: Binding(get: { options != nil && options!.isShape }, set: { if !$0 { options = nil } })) {
            ToolOptions(pen: pen, clips: clips) { options = nil }
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: - Colour

    private func swatch(_ color: Drawing.RGBA) -> some View {
        let on = pen.color.solid == color.solid
        return Button {
            pen.color = color.with(alpha: pen.color.a)
        } label: {
            Circle().fill(color.color)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0).padding(-3))
                .frame(width: 24, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Palette.name(of: color))
    }

    /// Any colour: the system colour picker (on iPhone and iPad the same as Photos'), behind a colour wheel.
    private var colorWheel: some View {
        ColorPicker("", selection: colorBinding, supportsOpacity: true)
            .labelsHidden()
            #if os(macOS)
            // The Mac's picker is a wide well: keep it to a circle, under the wheel.
            .frame(width: 24, height: 24)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                                  center: .center), lineWidth: 4)
                    .background(Circle().fill(pen.color.solid.color).padding(5))
                    .allowsHitTesting(false)
            }
            #endif
            .frame(width: 28, height: 30)
            .help("Any colour")
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { pen.color.color },
            set: { color in
                let r = color.resolve(in: environment)
                pen.color = Drawing.RGBA(Double(r.red), Double(r.green), Double(r.blue), Double(r.opacity))
            })
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 24)
    }
}

/// A tool's width and opacity (the eraser: erase everything).
private struct ToolOptions: View {
    let pen: Pen
    let clips: [Clip]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pen.tool.title).font(.headline)
            if pen.tool == .eraser {
                Text("Drag over a drawing to erase it.").font(.callout).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    for clip in clips {
                        let shown = Set(clip.visibleDrawings.map(\.id))
                        clip.drawings.removeAll { shown.contains($0.id) }
                    }
                    onClose()
                } label: {
                    Label("Erase everything on this frame", systemImage: "trash")
                }
                Button(role: .destructive) {
                    for clip in clips { clip.drawings.removeAll() }
                    onClose()
                } label: {
                    Label(clips.count > 1 ? "Erase all drawings on both clips" : "Erase all drawings on this clip",
                          systemImage: "trash.fill")
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(pen.tool.widths, id: \.self) { width in
                        let on = abs(pen.width - width) < 0.01
                        Button { pen.width = width } label: {
                            Circle()
                                .fill(pen.color.solid.color)
                                .frame(width: min(26, max(4, width * (pen.tool == .marker ? 0.7 : 1.8))),
                                       height: min(26, max(4, width * (pen.tool == .marker ? 0.7 : 1.8))))
                                .frame(width: 34, height: 34)
                                .background(on ? Color.primary.opacity(0.15) : .clear, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Width \(width.formatted()) pt")
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Opacity \(Int((pen.color.a * 100).rounded())) %")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { pen.color.a }, set: { pen.color = pen.color.with(alpha: $0) }), in: 0.1...1)
                        .frame(width: 210)
                }
            }
        }
        .padding(16)
    }
}

/// A pen tip, drawn as in Photos' Markup: a white body with the tool's nib, and a band of its colour
/// as thick as its line.
private struct PenTip: View {
    let tool: Pen.Tool
    let color: Color
    let width: Double

    var body: some View {
        VStack(spacing: 0) {
            nib
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                    .fill(Color.white.opacity(0.94))
                if tool != .eraser {
                    Rectangle()
                        .fill(color)
                        .frame(height: min(9, max(2, tool == .marker ? width / 4 : width)))
                        .padding(.top, 8)
                }
            }
            .frame(width: 20, height: 34)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    @ViewBuilder private var nib: some View {
        switch tool {
        case .pen:
            Nib(top: 1, base: 0.55).fill(color).frame(width: 20, height: 14)
        case .marker:
            Nib(top: 0.5, base: 0.85).fill(color.opacity(0.85)).frame(width: 20, height: 10)
        case .pencil:
            ZStack(alignment: .top) {
                Nib(top: 0.15, base: 1).fill(Color(red: 0.93, green: 0.82, blue: 0.62)).frame(width: 20, height: 16)
                Nib(top: 0.15, base: 1).fill(color).frame(width: 7, height: 6)
            }
        default:
            UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)
                .fill(Color(red: 1, green: 0.72, blue: 0.76)).frame(width: 20, height: 9)
        }
    }
}

/// A nib: narrowing from `base` (share of the width) at the bottom to `top` at the top
/// (a share of the base; a point when small).
private struct Nib: Shape {
    let top: CGFloat
    let base: CGFloat

    func path(in rect: CGRect) -> Path {
        let bottomWidth = rect.width * base
        let topWidth = max(1, bottomWidth * (top < 1 ? top : 0.12))
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - bottomWidth / 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - topWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + bottomWidth / 2, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
