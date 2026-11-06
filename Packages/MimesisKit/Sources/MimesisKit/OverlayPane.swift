import AreteMedia
import SwiftUI

/// One clip over the other, see-through, to show where two bodies differ frame by frame.
/// Drag to move the top clip, pinch to resize it, double-tap to put it back.
struct OverlayPane: View {
    let comparison: Comparison

    @State private var offsetBase: CGSize?
    @State private var scaleBase: CGFloat?

    private var top: Clip { comparison.clips[comparison.overlayTop] }
    private var base: Clip { comparison.clips[1 - comparison.overlayTop] }
    private var topLetter: String { comparison.overlayTop == 0 ? "A" : "B" }
    private var baseLetter: String { comparison.overlayTop == 0 ? "B" : "A" }

    var body: some View {
        VStack(spacing: 8) {
            video
            tools
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous).strokeBorder(Theme.line))
    }

    private var video: some View {
        GeometryReader { space in
            let picture = fitted(base.engine.videoSize, in: CGRect(origin: .zero, size: space.size))
            ZStack {
                VideoPlayerRepresentable(player: base.engine.player)
                    .frame(width: space.size.width, height: space.size.height)
                // The top clip, fitted into the picture underneath, then moved and resized.
                VideoPlayerRepresentable(player: top.engine.player)
                    .frame(width: picture.width, height: picture.height)
                    .scaleEffect(comparison.overlayScale)
                    .position(
                        x: picture.midX + comparison.overlayOffset.width * picture.width,
                        y: picture.midY + comparison.overlayOffset.height * picture.height)
                    .opacity(comparison.overlayOpacity)
                    .allowsHitTesting(false)
            }
            .frame(width: space.size.width, height: space.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let start = offsetBase ?? comparison.overlayOffset
                        offsetBase = start
                        comparison.overlayOffset = CGSize(
                            width: start.width + drag.translation.width / max(1, picture.width),
                            height: start.height + drag.translation.height / max(1, picture.height))
                    }
                    .onEnded { _ in offsetBase = nil })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch in
                        let start = scaleBase ?? comparison.overlayScale
                        scaleBase = start
                        comparison.overlayScale = min(4, max(0.25, start * pinch.magnification))
                    }
                    .onEnded { _ in scaleBase = nil })
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { comparison.resetOverlay() }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(alignment: .topLeading) { badge.padding(10) }
        .overlay(alignment: .topTrailing) { actions.padding(10) }
    }

    private var badge: some View {
        HStack(spacing: 6) {
            letter(topLetter, on: true)
            Text("over").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            letter(baseLetter, on: false)
            Text("\(top.name) over \(base.name)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.white)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.45), in: Capsule())
    }

    private func letter(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(on ? Theme.onAccent : .white)
            .frame(width: 22, height: 22)
            .background(on ? Theme.accent : Color.white.opacity(0.18), in: Circle())
    }

    private var actions: some View {
        HStack(spacing: 6) {
            RoundButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        active: top.engine.mirroredHorizontally, action: top.toggleMirror)
                .help("Mirror the top clip side to side, e.g. a right-hander to match a left-hander")
            RoundButton(symbol: "arrow.up.arrow.down") {
                comparison.overlayTop = 1 - comparison.overlayTop
                comparison.resetOverlay()
            }
            .help("Swap which clip is on top")
            RoundButton(symbol: "arrow.counterclockwise", action: comparison.resetOverlay)
                .help("Put the top clip back where it started (or double-tap)")
                .disabled(comparison.overlayOffset == .zero && comparison.overlayScale == 1)
        }
    }

    private var tools: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(Theme.secondary)
            Slider(value: Binding(get: { comparison.overlayOpacity }, set: { comparison.overlayOpacity = $0 }),
                   in: 0.1...0.9)
                .frame(maxWidth: 260)
            Text("\(topLetter) \(Int((comparison.overlayOpacity * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 52, alignment: .leading)
            Spacer(minLength: 8)
            Text(comparison.linked ? "Drag to move \(topLetter), pinch to resize"
                 : "Link the clips to play them together")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }

    /// The video picture inside `rect`, as AVPlayer shows it (fit, centred).
    private func fitted(_ video: CGSize, in rect: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return rect }
        let scale = min(rect.width / video.width, rect.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
