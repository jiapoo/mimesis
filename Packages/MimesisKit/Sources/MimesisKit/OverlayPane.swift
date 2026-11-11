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
                // (Each player view belongs to its video: made again when the two change places.)
                VideoPlayerRepresentable(player: base.engine.player)
                    .id(ObjectIdentifier(base))
                    .frame(width: space.size.width, height: space.size.height)
                // The top clip, fitted into the picture underneath, then moved and resized: whole, or
                // cut out once its cutout is ready (the player keeps decoding underneath, unseen).
                VideoPlayerRepresentable(player: top.engine.player)
                    .id(ObjectIdentifier(top))
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
                // Drawings over the two together, on the picture underneath (so they zoom with it).
                DrawingLayer(clip: base, editing: comparison.drawing != nil && !comparison.pen.panning, pen: comparison.pen, overlay: true)
                    .frame(width: space.size.width, height: space.size.height)
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
                        // (Space held while drawing pans, whatever touches usually do.)
                        if !ui.movesTop || comparison.pen.panning {
                            let start = panBase ?? base.pan
                            panBase = start
                            base.pan = CGSize(width: start.width + drag.translation.width,
                                              height: start.height + drag.translation.height)
                            return
                        }
                        guard unlocked() else { return }
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
                        guard unlocked() else { return }
                        let start = scaleBase ?? comparison.overlayScale
                        scaleBase = start
                        comparison.overlayScale = min(4, max(0.25, start * pinch.magnification))
                    }
                    .onEnded { _ in scaleBase = nil; zoomBase = nil })
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { turn in
                        guard !picking, ui.movesTop else { return }
                        guard unlocked() else { return }
                        let start = rotationBase ?? comparison.overlayRotation
                        rotationBase = start
                        comparison.overlayRotation = start + turn.rotation.degrees
                    }
                    .onEnded { _ in rotationBase = nil })
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if !ui.movesTop { base.resetView() } else if unlocked() { comparison.resetOverlay() }
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
            // Everything the overlay needs is here, over the picture, so the bar underneath is the same
            // in every layout. First row: what's on top, and what moves the top clip. Second row: what
            // touches do, the size or zoom, how see-through the top clip is, and the cutout.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    badge
                    Spacer(minLength: 0)
                    adjustments
                    if base.zoom > 1 {
                        RoundButton(symbol: "arrow.down.right.and.arrow.up.left") {
                            withAnimation(.easeOut(duration: 0.2)) { base.resetView() }
                        }
                        .help("See the whole picture")
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { controls(compact: false); cutoutOptions }
                    HStack(spacing: 6) { controls(compact: true); cutoutOptions }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { controls(compact: true); cutoutOptions } }
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
        .confirmationDialog(
            "This segment has \(comparison.overlayDrawings) drawing\(comparison.overlayDrawings == 1 ? "" : "s") made in the overlay",
            isPresented: Binding(get: { ui.askingToUnlock }, set: { if !$0 { ui.askingToUnlock = false } }),
            titleVisibility: .visible
        ) {
            Button("Remove the drawings and move \(topLetter)", role: .destructive) {
                comparison.removeOverlayDrawings()
                ui.pending?()
                ui.pending = nil
            }
            Button("Keep the drawings", role: .cancel) { ui.pending = nil }
        } message: {
            Text("They were drawn over the two clips as they sit now. Moving, resizing, turning, mirroring or swapping \(topLetter) would leave them in the wrong place, so they're removed first. (Undo brings them back.)")
        }
        .confirmationDialog(
            "Put \(baseLetter) on top?",
            isPresented: Binding(get: { ui.askingToSwap }, set: { if !$0 { ui.askingToSwap = false } }),
            titleVisibility: .visible
        ) {
            Button("Swap and remove \(topLetter)'s cutout", role: .destructive) {
                top.dropCutout()
                comparison.overlayTop = 1 - comparison.overlayTop
                comparison.resetOverlay()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(topLetter) is cut out. With \(baseLetter) on top, \(topLetter) is shown whole underneath, so its cutout is removed. You can cut \(baseLetter) out afterwards.")
        }
        .onChange(of: ui.problem) { _, problem in
            guard problem != nil else { return }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if ui.problem == problem { ui.problem = nil }
            }
        }
    }

    private func controls(compact: Bool) -> some View {
        OverlayControls(comparison: comparison, compact: compact)
            .padding(4)
            .background(Color.black.opacity(0.35), in: Capsule())
    }

    /// Swap, mirror, line up (the bodies, or the backgrounds), turn, put back.
    private var adjustments: some View {
        HStack(spacing: 6) {
            RoundButton(symbol: "arrow.up.arrow.down") { ui.swapTop(comparison) }
                .help("Swap: \(baseLetter) on top")
            RoundButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        active: top.engine.mirroredHorizontally) { ui.moving(comparison) { top.toggleMirror() } }
                .help("Mirror \(topLetter) side to side, e.g. a right-hander to match a left-hander")
            divider
            RoundButton(symbol: ui.aligning ? "hourglass" : "person.2") { ui.align(comparison) }
                .disabled(ui.aligning)
                .help("Line up the bodies: put \(topLetter)'s hips and feet on \(baseLetter)'s, from the frames on screen")
            RoundButton(symbol: ui.aligning ? "hourglass" : "square.on.square.dashed") {
                ui.align(comparison, byBackground: true)
            }
            .disabled(ui.aligning)
            .help("Line up the backgrounds: for two clips filmed at the same place, so everything that stands still matches")
            divider
            RoundButton(symbol: "rotate.left") { ui.moving(comparison) { comparison.overlayRotation -= 1 } }
                .help("Turn \(topLetter) 1° anticlockwise (or twist with two fingers)")
            Text("\(Int(comparison.overlayRotation.rounded()))°")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 26)
                .help("How far \(topLetter) is turned")
            RoundButton(symbol: "rotate.right") { ui.moving(comparison) { comparison.overlayRotation += 1 } }
                .help("Turn \(topLetter) 1° clockwise")
            divider
            RoundButton(symbol: "arrow.counterclockwise") {
                ui.moving(comparison) { withAnimation(.easeOut(duration: 0.2)) { comparison.resetOverlay() } }
            }
            .disabled(comparison.overlayOffset == .zero && comparison.overlayScale == 1 && comparison.overlayRotation == 0)
            .help("Put \(topLetter) back where it started (or double-tap with ✋)")
        }
        .padding(4)
        .background(Color.black.opacity(0.35), in: Capsule())
    }

    /// Once cut out: a box instead of the outline, a crimson tint, one player or everyone, cut out again.
    @ViewBuilder private var cutoutOptions: some View {
        if let cutout = top.cutout, cutout.state == .ready, cutout.enabled {
            HStack(spacing: 6) {
                RoundButton(symbol: "rectangle.dashed", active: cutout.boxed) { cutout.boxed.toggle() }
                    .help("A soft box around \(topLetter)'s person instead of their outline, for when the outline loses what they hold")
                RoundButton(symbol: "paintbrush", active: cutout.tinted) { cutout.tinted.toggle() }
                    .help("Tint \(topLetter)'s person crimson, to tell the two bodies apart")
                if cutout.hasSeveral {
                    RoundButton(symbol: "hand.tap", active: ui.picking || cutout.picked != nil) { ui.picking.toggle() }
                        .help("Keep only one person when \(topLetter) has others in frame: then tap them")
                    if cutout.picked != nil {
                        RoundButton(symbol: "person.2") { cutout.pickEveryone() }
                            .help("Show everyone found in \(topLetter), not only the person picked")
                    }
                }
                RoundButton(symbol: "arrow.clockwise") { top.makeCutout(fresh: true) }
                    .help("Cut out again, e.g. after changing \(topLetter)'s trim")
            }
            .padding(4)
            .background(Color.black.opacity(0.35), in: Capsule())
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 18)
    }

    /// Whether the top clip may move now. With drawings made in this overlay it's locked: asks (once per
    /// touch) whether to remove them.
    private func unlocked() -> Bool {
        if comparison.overlayDrawings == 0 { return true }
        if !ui.askingToUnlock {
            ui.pending = nil
            ui.askingToUnlock = true
        }
        return false
    }

    private var hint: String? {
        if let problem = ui.problem { return problem }
        if picking { return "Tap the person in \(topLetter)" }
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
            ui.problem = "Tap on the person in \(topLetter)."
            return
        }
        if cutout.pick(at: top.engine.currentTime, point: point) {
            ui.picking = false
        } else {
            ui.problem = "Nobody there: tap on the person in \(topLetter)."
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
