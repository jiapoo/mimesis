import SwiftUI

/// Mimesis's look: a dark studio canvas so the video stands out, and one accent,
/// the crimson of the icon (the M with its trail of faded echoes).
enum Theme {
    static let canvas = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let card = Color(red: 0.090, green: 0.094, blue: 0.110)
    static let raised = Color.white.opacity(0.08)
    static let line = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    /// #EC3A55, the top of the icon's gradient: bright enough to read on the dark canvas.
    static let accent = Color(red: 0.925, green: 0.227, blue: 0.333)
    static let onAccent = Color.white
    static let corner: CGFloat = 14
}

/// A round icon button that floats over video: dark glass, or crimson when on.
struct RoundButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Theme.onAccent : Color.white)
                .background(active ? Theme.accent : Color.black.opacity(0.45), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(active ? 0 : 0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A small capsule button for a pane's tools: quiet, or crimson when on.
struct ChipStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(active ? Theme.onAccent : Color.white)
            .background(
                active ? Theme.accent : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: Capsule())
            .contentShape(Capsule())
    }
}

/// A slim timeline: the span, an optional highlighted part (the trim), an optional crimson diamond
/// (the sync point) and the playhead. Drag anywhere to scrub.
struct Timeline: View {
    let range: ClosedRange<Double>
    let value: Double
    var highlight: ClosedRange<Double>?
    var marker: Double?
    let onScrub: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { space in
            let width = space.size.width
            let mid = space.size.height / 2 + 4
            let span = max(0.0001, range.upperBound - range.lowerBound)
            let x = { (v: Double) in CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span) * width }
            let at = { (px: CGFloat) in range.lowerBound + Double(min(max(px, 0), width) / width) * span }

            ZStack {
                Capsule().fill(Color.white.opacity(0.12))
                    .frame(width: width, height: 4)
                    .position(x: width / 2, y: mid)
                if let highlight {
                    let from = x(highlight.lowerBound), to = x(highlight.upperBound)
                    Capsule().fill(Color.white.opacity(0.32))
                        .frame(width: max(4, to - from), height: 4)
                        .position(x: (from + to) / 2, y: mid)
                }
                let start = x(highlight?.lowerBound ?? range.lowerBound)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, x(value) - start), height: 4)
                    .position(x: (start + x(value)) / 2, y: mid)
                if let marker {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent)
                        .position(x: x(marker), y: mid - 11)
                }
                Circle().fill(Color.white)
                    .frame(width: dragging ? 16 : 12, height: dragging ? 16 : 12)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .position(x: x(value), y: mid)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        onScrub(at(drag.location.x))
                    }
                    .onEnded { drag in
                        dragging = false
                        onEnd(at(drag.location.x))
                    })
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 30)
    }
}

extension View {
    /// Every sheet's look: the dark canvas, the accent, and on the Mac a sensible minimum size
    /// (on iPhone and iPad the sheet takes the screen's own size).
    func themedSheet(width: CGFloat, height: CGFloat? = nil) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .presentationBackground(Theme.canvas)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            #if os(macOS)
            .frame(minWidth: width, minHeight: height)
            #endif
    }
}

/// A slim slider for the bar (speed, opacity): a thin track filled in the accent and a small white knob.
/// Smaller than the system's, which on iPhone is too tall for the bar. Drag or tap anywhere along it.
struct SlimSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    @State private var dragging = false

    var body: some View {
        GeometryReader { space in
            let width = space.size.width
            let share = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                / max(0.0001, range.upperBound - range.lowerBound)
            let x = CGFloat(share) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: max(4, x), height: 4)
                Circle().fill(Color.white)
                    .frame(width: dragging ? 16 : 13, height: dragging ? 16 : 13)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(0, x - (dragging ? 8 : 6.5)), width - (dragging ? 16 : 13)))
            }
            .frame(height: space.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let share = min(max(drag.location.x / max(1, width), 0), 1)
                        value = range.lowerBound + Double(share) * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in dragging = false })
            .animation(.easeOut(duration: 0.1), value: dragging)
        }
        .frame(height: 22)
    }
}
