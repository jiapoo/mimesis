import AreteMedia
import SwiftUI

/// One clip over the other, see-through, to show where two bodies differ frame by frame.
/// Two ways to touch it, chosen in the bar (`OverlayControls`):
/// - **Move the top clip** (✋): drag to move it, pinch to resize, twist to turn, double-tap to put it back;
/// - **Zoom** (🔍): pinch to zoom the whole picture, both clips together, drag to pan, double-tap to see it all.
struct OverlayPane: View {
    let comparison: Comparison

    @State private var offsetBase: CGSize?
    @State private var scaleBase: CGFloat?
    @State private var rotationBase: Double?
    @State private var zoomBase: CGFloat?
    @State private var panBase: CGSize?

    private var ui: OverlayUI { comparison.overlayUI }
    private var picking: Bool { ui.picking }

    private var top: Clip { comparison.clips[comparison.overlayTop] }
    private var base: Clip { comparison.clips[1 - comparison.overlayTop] }
    private var topLetter: String { comparison.overlayTop == 0 ? "A" : "B" }
    private var readyCutout: Cutout? { top.cutout?.state == .ready ? top.cutout : nil }
    private var baseLetter: String { comparison.overlayTop == 0 ? "B" : "A" }

    var body: some View {
        // Edge to edge like the clips; its own tools float at the top, clear of the panel at the bottom.
        video
    }

    private var video: some View {
        GeometryReader { space in
            let picture = fitted(base.engine.videoSize, in: CGRect(origin: .zero, size: space.size))
            ZStack {
                VideoPlayerRepresentable(player: base.engine.player)
                    .frame(width: space.size.width, height: space.size.height)
                // The top clip, fitted into the picture underneath, then moved and resized: whole, or
                // cut out once its cutout is ready (the player keeps decoding underneath, unseen).
                VideoPlayerRepresentable(player: top.engine.player)
                    .frame(width: picture.width, height: picture.height)
                    .scaleEffect(comparison.overlayScale)
                    .rotationEffect(.degrees(comparison.overlayRotation))
                    .position(
                        x: picture.midX + comparison.overlayOffset.width * picture.width,
                        y: picture.midY + comparison.overlayOffset.height * picture.height)
                    .opacity(readyCutout == nil ? comparison.overlayOpacity : 0)
                    .allowsHitTesting(false)
                if let cutout = readyCutout {
                    CutoutLayer(clip: top, cutout: cutout)
                        .frame(width: picture.width, height: picture.height)
                        .scaleEffect(comparison.overlayScale)
                        .rotationEffect(.degrees(comparison.overlayRotation))
                        .position(
                            x: picture.midX + comparison.overlayOffset.width * picture.width,
                            y: picture.midY + comparison.overlayOffset.height * picture.height)
                        .opacity(comparison.overlayOpacity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: space.size.width, height: space.size.height)
            // Zoomed, both clips together.
            .scaleEffect(base.zoom)
            .offset(base.pan)
            .frame(width: space.size.width, height: space.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard !picking else { return }
                        if !ui.movesTop {
                            let start = panBase ?? base.pan
                            panBase = start
                            base.pan = CGSize(width: start.width + drag.translation.width,
                                              height: start.height + drag.translation.height)
                            return
                        }
                        let start = offsetBase ?? comparison.overlayOffset
                        offsetBase = start
                        comparison.overlayOffset = CGSize(
                            width: start.width + drag.translation.width / max(1, picture.width),
                            height: start.height + drag.translation.height / max(1, picture.height))
                    }
                    .onEnded { _ in offsetBase = nil; panBase = nil })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch in
                        if !ui.movesTop {
                            let start = zoomBase ?? base.zoom
                            zoomBase = start
                            base.zoom = min(8, max(1, start * pinch.magnification))
                            if base.zoom == 1 { base.pan = .zero }
                            return
                        }
                        let start = scaleBase ?? comparison.overlayScale
                        scaleBase = start
                        comparison.overlayScale = min(4, max(0.25, start * pinch.magnification))
                    }
                    .onEnded { _ in scaleBase = nil; zoomBase = nil })
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { turn in
                        guard !picking, ui.movesTop else { return }
                        let start = rotationBase ?? comparison.overlayRotation
                        rotationBase = start
                        comparison.overlayRotation = start + turn.rotation.degrees
                    }
                    .onEnded { _ in rotationBase = nil })
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if ui.movesTop { comparison.resetOverlay() } else { base.resetView() }
                }
            }
            .onTapGesture { location in
                guard picking else { return }
                // Back through the zoom to the unzoomed picture.
                let centre = CGPoint(x: space.size.width / 2, y: space.size.height / 2)
                let unzoomed = CGPoint(
                    x: (location.x - centre.x - base.pan.width) / base.zoom + centre.x,
                    y: (location.y - centre.y - base.pan.height) / base.zoom + centre.y)
                pick(at: unzoomed, picture: picture)
            }
        }
        .background(Color.black)
        .clipped()
        .overlay(alignment: .top) {
            // Only what to read here; its controls are in the bar under the videos.
            HStack(alignment: .top, spacing: 8) {
                badge
                Spacer(minLength: 0)
                if base.zoom > 1 {
                    RoundButton(symbol: "arrow.down.right.and.arrow.up.left") {
                        withAnimation(.easeOut(duration: 0.2)) { base.resetView() }
                    }
                    .help("See the whole picture")
                }
            }
            .padding(10)
        }
        .overlay(alignment: .center) {
            if let hint {
                Text(hint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: ui.problem) { _, problem in
            guard problem != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if ui.problem == problem { ui.problem = nil }
            }
        }
    }

    private var hint: String? {
        if let problem = ui.problem { return problem }
        if picking { return "Tap \(topLetter)'s player" }
        return nil
    }

    private var badge: some View {
        HStack(spacing: 6) {
            letter(topLetter, on: true)
            Text("over").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            letter(baseLetter, on: false)
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

    /// Picks the top clip's subject under a tap: back from the view to the top picture, as filmed.
    private func pick(at location: CGPoint, picture: CGRect) {
        guard let cutout = top.cutout else { return }
        let scale = comparison.overlayScale
        let centre = CGPoint(
            x: picture.midX + comparison.overlayOffset.width * picture.width,
            y: picture.midY + comparison.overlayOffset.height * picture.height)
        // Where the tap falls in the top clip's frame (the size of the picture underneath), unturned and unscaled.
        let angle = -comparison.overlayRotation * .pi / 180
        let dx = location.x - centre.x, dy = location.y - centre.y
        let local = CGPoint(
            x: (dx * cos(angle) - dy * sin(angle)) / scale + picture.width / 2,
            y: (dx * sin(angle) + dy * cos(angle)) / scale + picture.height / 2)
        let shown = fitted(top.engine.videoSize, in: CGRect(origin: .zero, size: picture.size))
        var point = CGPoint(x: (local.x - shown.minX) / shown.width, y: (local.y - shown.minY) / shown.height)
        if top.engine.mirroredHorizontally { point.x = 1 - point.x }
        guard (0...1).contains(point.x), (0...1).contains(point.y) else {
            ui.problem = "Tap on \(topLetter)'s player."
            return
        }
        if cutout.pick(at: top.engine.currentTime, point: point) {
            ui.picking = false
        } else {
            ui.problem = "Nobody there: tap on \(topLetter)'s player."
        }
    }

    /// The video picture inside `rect`, as AVPlayer shows it (fit, centred).
    private func fitted(_ video: CGSize, in rect: CGRect) -> CGRect {
        guard video.width > 0, video.height > 0 else { return rect }
        let scale = min(rect.width / video.width, rect.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }
}
