import AreteMedia
import SwiftUI

/// One clip over the other, see-through, to show where two bodies differ frame by frame.
/// Drag to move the top clip, pinch to resize it, double-tap to put it back.
struct OverlayPane: View {
    let comparison: Comparison

    @State private var offsetBase: CGSize?
    @State private var scaleBase: CGFloat?
    @State private var rotationBase: Double?
    @State private var aligning = false
    @State private var picking = false
    @State private var alignProblem: String?

    private var top: Clip { comparison.clips[comparison.overlayTop] }
    private var base: Clip { comparison.clips[1 - comparison.overlayTop] }
    private var topLetter: String { comparison.overlayTop == 0 ? "A" : "B" }
    private var readyCutout: Cutout? { top.cutout?.state == .ready ? top.cutout : nil }
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
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        guard !picking else { return }
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
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { turn in
                        guard !picking else { return }
                        let start = rotationBase ?? comparison.overlayRotation
                        rotationBase = start
                        comparison.overlayRotation = start + turn.rotation.degrees
                    }
                    .onEnded { _ in rotationBase = nil })
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { comparison.resetOverlay() }
            }
            .onTapGesture { location in
                guard picking else { return }
                pick(at: location, picture: picture)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(alignment: .topLeading) { badge.padding(10) }
        .overlay(alignment: .topTrailing) { actions.padding(10) }
        .overlay(alignment: .bottom) {
            if let alignProblem {
                Text(alignProblem)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .padding(10)
                    .onTapGesture { self.alignProblem = nil }
                    .task {
                        try? await Task.sleep(for: .seconds(5))
                        self.alignProblem = nil
                    }
            }
        }
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
            RoundButton(symbol: aligning ? "hourglass" : "figure.stand") { align() }
                .help("Auto-align: put \(topLetter)'s hips and feet on \(baseLetter)'s, from the frames on screen")
                .disabled(aligning)
            RoundButton(symbol: "minus.magnifyingglass") { resize(by: 1 / 1.1) }
                .help("Make the top clip smaller")
            RoundButton(symbol: "plus.magnifyingglass") { resize(by: 1.1) }
                .help("Make the top clip bigger")
            RoundButton(symbol: "arrow.up.arrow.down") {
                comparison.overlayTop = 1 - comparison.overlayTop
                comparison.resetOverlay()
            }
            .help("Swap which clip is on top")
            RoundButton(symbol: "arrow.counterclockwise", action: comparison.resetOverlay)
                .help("Put the top clip back where it started (or double-tap)")
                .disabled(comparison.overlayOffset == .zero && comparison.overlayScale == 1 && comparison.overlayRotation == 0)
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
            HStack(spacing: 4) {
                RoundButton(symbol: "rotate.left", size: 26) { comparison.overlayRotation -= 1 }
                    .help("Turn \(topLetter) 1° anticlockwise (or twist with two fingers)")
                Text("\(Int(comparison.overlayRotation.rounded()))°")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 30)
                RoundButton(symbol: "rotate.right", size: 26) { comparison.overlayRotation += 1 }
                    .help("Turn \(topLetter) 1° clockwise")
            }
            Spacer(minLength: 8)
            cutoutControls
        }
        .foregroundStyle(.white)
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
            alignProblem = "Tap on \(topLetter)'s player."
            return
        }
        if cutout.pick(at: top.engine.currentTime, point: point) {
            picking = false
        } else {
            alignProblem = "Nobody there: tap on \(topLetter)'s player."
        }
    }

    private func align() {
        aligning = true
        alignProblem = nil
        Task {
            do {
                try await comparison.autoAlign()
            } catch {
                #if targetEnvironment(simulator)
                alignProblem = "Auto-align needs a real iPhone or iPad (Vision can't run it in Simulator)."
                #else
                alignProblem = error.localizedDescription
                #endif
            }
            aligning = false
        }
    }

    private func resize(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.12)) {
            comparison.overlayScale = min(4, max(0.25, comparison.overlayScale * factor))
        }
    }

    /// Cut the top player out: a button to start, progress while it works, then on/off and tint.
    @ViewBuilder private var cutoutControls: some View {
        switch top.cutout?.state {
        case nil:
            Button { top.makeCutout() } label: { Label("Cut out \(topLetter)", systemImage: "person.crop.rectangle") }
                .buttonStyle(ChipStyle(active: true))
                .help("Find the player in every frame of \(topLetter)'s trim, so only the player shows over the other clip")
        case .preparing(let done)?:
            ProgressView(value: done).frame(width: 120)
            Text("Cutting out… \(Int(done * 100))%").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Button("Stop") { top.dropCutout() }.buttonStyle(ChipStyle())
        case .ready?:
            if let cutout = top.cutout {
                Button { cutout.enabled.toggle() } label: { Label("Cutout", systemImage: "person.crop.rectangle") }
                    .buttonStyle(ChipStyle(active: cutout.enabled))
                    .help(cutout.shortened ? "Only the first \(Cutout.frameLimit) frames of the trim are cut out: trim \(topLetter) to the swing"
                          : "Show \(topLetter) cut out, or whole")
                Button { cutout.boxed.toggle() } label: { Label("Box", systemImage: "rectangle.dashed") }
                    .buttonStyle(ChipStyle(active: cutout.boxed))
                    .disabled(!cutout.enabled)
                    .help("A soft box around \(topLetter)'s player instead of their outline, for when the outline loses the racket")
                Button { cutout.tinted.toggle() } label: { Label("Tint", systemImage: "paintbrush") }
                    .buttonStyle(ChipStyle(active: cutout.tinted))
                    .disabled(!cutout.enabled)
                    .help("Colour \(topLetter)'s player crimson, to tell the two bodies apart")
                if cutout.hasSeveral && cutout.enabled {
                    if cutout.picked != nil {
                        Button { cutout.pickEveryone() } label: { Label("Everyone", systemImage: "person.2") }
                            .buttonStyle(ChipStyle())
                            .help("Show everyone found in \(topLetter), not only the player picked")
                    }
                    Button { picking.toggle() } label: {
                        Label(picking ? "Tap a player" : "Pick player", systemImage: "hand.tap")
                    }
                    .buttonStyle(ChipStyle(active: picking || cutout.picked != nil))
                    .help("Keep only one player when \(topLetter) has others in frame (an opponent, a coach): tap them")
                }
                RoundButton(symbol: "arrow.clockwise") { top.makeCutout(fresh: true) }
                    .help("Cut out again, e.g. after changing \(topLetter)'s trim")
            }
        case .failed(let why)?:
            Text(why).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            Button("Try again") { top.makeCutout() }.buttonStyle(ChipStyle())
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
