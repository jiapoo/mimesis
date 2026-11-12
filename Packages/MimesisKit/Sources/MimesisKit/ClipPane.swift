import AreteMedia
import SwiftUI
import UniformTypeIdentifiers

/// One side: the video in a rounded card, its controls floating over it, and a slim row of tools
/// (trim, sync point, speed) underneath. Pinch to zoom, drag to pan, double-tap to reset.
struct ClipPane: View {
    let clip: Clip
    let letter: String
    let linked: Bool
    let focused: Bool
    /// Two clips on screen, so the focused one is outlined.
    var showsFocus = true
    let onFocus: () -> Void
    let onOpenFile: () -> Void
    let onOpenPhotos: () -> Void
    /// Videos dropped on this clip (two at once fill A and B).
    let onDropped: ([URL]) -> Void
    /// A sideways drag on the video: move this many frames (both clips while linked).
    let onJog: (Int) -> Void
    /// Drawing on this clip (alone, or with the other).
    let drawing: Bool
    let pen: Pen
    /// One Draw for both clips, in the panel: no Draw button of its own.
    let drawsTogether: Bool
    /// The joint angles to write on the skeleton.
    var skeletonAngles: Set<JointAngle> = JointAngle.usual
    /// Open this clip in the editor (turn, flip, crop, trim); and back to how it was before.
    var onEdit: () -> Void = {}
    var onRevert: () -> Void = {}
    /// Its own Draw button: start or stop drawing on this clip.
    let onDraw: () -> Void

    /// How far a finger moves for one frame.
    static let pointsPerFrame: CGFloat = 12

    @State private var zoomBase: CGFloat = 1
    @State private var panBase: CGSize = .zero
    @State private var jogged = 0
    @State private var stroMotion = false
    @State private var dropping = false

    var body: some View {
        Group {
            if clip.isLoaded {
                video
            } else {
                empty.background(Theme.card)
            }
        }
        // Focus, with two clips on screen: the other clip steps back (dimmed), and the focused one gets a
        // soft crimson ring, inset and rounded, with a faint glow.
        .overlay {
            Color.black
                .opacity(showsFocus && !focused && !dropping ? 0.32 : 0)
                .allowsHitTesting(false)
        }
        .overlay {
            // Flush with the clip's edge, corners softly rounded.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2.5)
                .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                .opacity((focused && showsFocus) || dropping ? 1 : 0)
                .scaleEffect((focused && showsFocus) || dropping ? 1 : 0.985)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: focused)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { isVideo($0) || isProject($0) }
            guard !videos.isEmpty else { return false }
            onDropped(videos)
            return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.15), value: focused)
        .sheet(isPresented: $stroMotion) { StroMotionView(clip: clip, letter: letter) }
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(spacing: 18) {
            EchoMark()
                .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text("Clip \(letter)").font(.system(size: 17, weight: .semibold))
                Text(letter == "A" ? "Yours, or the one to learn from" : "The one to compare it with")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                Button(action: onOpenFile) { Label("Files", systemImage: "folder") }
                    .buttonStyle(ChipStyle(active: true))
                    .help("Open a video file as clip \(letter)")
                Button(action: onOpenPhotos) { Label("Photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(ChipStyle())
                    .help("Pick a video from Photos as clip \(letter)")
            }
            Text("or drop a video here").font(.system(size: 12)).foregroundStyle(Theme.secondary.opacity(0.7))
            Label("Film in Slo-mo (240 fps), or at least 60 fps, for smooth slow motion", systemImage: "lightbulb")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .padding(8))
    }

    // MARK: - Video

    private var video: some View {
        GeometryReader { space in
            ZStack {
                VideoPlayerRepresentable(player: clip.engine.player)
                // In the same frame as the video, so drawings zoom and pan with it.
                // (Space held while drawing: the drags go to the video, to pan it, as in Photoshop.)
                DrawingLayer(surface: clip, editing: drawing && !pen.pans, pen: pen)
                // On the Mac the video's own view takes the clicks; a clear layer over it gives them to
                // the gestures below (focus on click, double-click to fit, drag to step or pan).
                if !drawing || pen.pans {
                    Color.clear.contentShape(Rectangle())
                }
            }
                .scaleEffect(clip.zoom)
                .offset(clip.pan)
                .frame(width: space.size.width, height: space.size.height)
                // The skeleton follows the zoomed picture, but is drawn at its own size, so it stays sharp.
                .overlay {
                    if clip.showsSkeleton {
                        SkeletonLayer(pose: clip.shownPose, videoSize: clip.engine.videoSize, mirrored: clip.engine.mirroredHorizontally,
                                      angles: skeletonAngles, zoom: clip.zoom, pan: clip.pan)
                    }
                }
                // The degrees of drawn angles, likewise.
                .overlay { DrawingLabels(surface: clip, zoom: clip.zoom, pan: clip.pan) }
                .clipped()
                .contentShape(Rectangle())
                .drawingPointer(pen, on: drawing)
                .gesture(
                    MagnifyGesture()
                        .onChanged { clip.zoom = min(8, max(1, zoomBase * $0.magnification)) }
                        .onEnded { _ in
                            zoomBase = clip.zoom
                            if clip.zoom == 1 { clip.pan = .zero; panBase = .zero }
                        })
                .simultaneousGesture(
                    // Zoomed in: drag to pan. Otherwise drag sideways to move frame by frame.
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag in
                            // While drawing, the drag belongs to the drawing.
                            guard !drawing || pen.pans else { return }
                            if drawing { pen.grabbing = true }
                            // Space held while drawing moves the picture, zoomed or not; it never steps frames.
                            if clip.zoom > 1 || drawing {
                                clip.pan = CGSize(
                                    width: panBase.width + drag.translation.width,
                                    height: panBase.height + drag.translation.height)
                            } else {
                                let frames = Int((drag.translation.width / Self.pointsPerFrame).rounded(.towardZero))
                                if frames != jogged {
                                    onJog(frames - jogged)
                                    jogged = frames
                                }
                            }
                        }
                        .onEnded { _ in
                            panBase = clip.pan
                            jogged = 0
                            pen.grabbing = false
                        })
                .onTapGesture(count: 2) { resetView() }
                // Focus the moment the pointer goes down: no waiting to rule out a double-click
                // (that wait went missing while the other clip played).
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !focused && !drawing { onFocus() } })
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            // The letter and time always; the clip's buttons only on the focused clip.
            // (The drawing tools float over both clips, from the comparison.)
            HStack(alignment: .top, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    badge(name: false, time: true)
                    badge(name: false, time: false)
                }
                Spacer(minLength: 0)
                // Linked, both clips are one: each keeps its buttons (mirror, sound, open…).
                if (focused || linked) && !drawing {
                    actions.transition(.opacity)
                } else if drawing, clip.zoom > 1 || clip.pan != .zero {
                    // Zoomed or moved while drawing: one button puts the whole frame back.
                    RoundButton(symbol: "arrow.down.right.and.arrow.up.left", action: resetView)
                        .help("Fit the whole frame")
                }
            }
            .padding(10)
        }
        // Notes pinned around this moment, above the timeline.
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(clip.visibleNotes) { note in
                    Label(note.text, systemImage: "text.bubble.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(red: 1, green: 0.84, blue: 0.2)).frame(width: 3).padding(.vertical, 5)
                        }
                }
            }
            .padding(.leading, 12)
            .padding(.bottom, 96)
            .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: drawing)
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func badge(name: Bool, time: Bool) -> some View {
        HStack(spacing: 8) {
            Text(letter)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(focused ? Theme.onAccent : .white)
                .frame(width: 22, height: 22)
                .background(focused ? Theme.accent : Color.white.opacity(0.18), in: Circle())
            if name {
                Text(clip.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 200)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if time {
                Text(clock(clip.engine.currentTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            // Slow motion needs frames: below 50 a second it jumps, so always say so; above, only with room.
            let fps = Int(clip.engine.fps.rounded())
            if clip.engine.duration > 0, time, name || fps < 50 {
                Text("\(fps) fps")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(fps < 50 ? Color(red: 1, green: 0.84, blue: 0.2) : Theme.secondary)
                    .help(fps < 50 ? "Filmed at \(fps) frames a second: slow motion will jump. Film in Slo-mo (240 fps) or at least 60 fps."
                          : "Filmed at \(fps) frames a second")
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 4)
        .padding(.trailing, name || time ? 10 : 4)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.45), in: Capsule())
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if clip.zoom > 1 || clip.pan != .zero {
                RoundButton(symbol: "arrow.down.right.and.arrow.up.left", action: resetView)
                    .help("Fit the whole frame")
            }
            if !drawsTogether {
                RoundButton(symbol: "pencil.tip", active: drawing) {
                    onFocus()
                    clip.engine.pause()
                    onDraw()
                }
                .help("Draw lines, arrows, circles and angles on the frame")
            }
            RoundButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        active: clip.engine.mirroredHorizontally, action: clip.toggleMirror)
                .help("Mirror side to side (⇧⌘H)")
            RoundButton(symbol: skeletonSymbol, active: clip.showsSkeleton) {
                onFocus()
                clip.toggleSkeleton()
            }
            .help(skeletonHelp)
            RoundButton(symbol: "crop.rotate", action: onEdit)
                .help("Edit this clip: turn, flip, crop or trim it (⌘T). The clip becomes the edited copy; the original isn't changed.")
            Menu {
                Button(clip.engine.isMuted ? "Sound on" : "Sound off",
                       systemImage: clip.engine.isMuted ? "speaker.wave.2" : "speaker.slash") {
                    clip.engine.isMuted.toggle()
                }
                Divider()
                Button("Open video…", systemImage: "folder", action: onOpenFile)
                Button("From Photos…", systemImage: "photo.on.rectangle", action: onOpenPhotos)
                Divider()
                Button("Clear trim", systemImage: "scissors", action: clip.clearTrim)
                    .disabled(clip.trimStart == 0 && clip.trimEnd == nil)
                Button("Clear sync points", systemImage: "diamond") { clip.syncs = [] }
                    .disabled(clip.syncs.isEmpty || linked)
                Divider()
                Button("StroMotion…", systemImage: "figure.run") { stroMotion = true }
                Button("Edit clip…", systemImage: "crop.rotate", action: onEdit)
                if clip.beforeEdit != nil {
                    Button("Revert to the original", systemImage: "arrow.uturn.backward", action: onRevert)
                }
                Divider()
                Button("Close", systemImage: "xmark", role: .destructive, action: clip.close)
                    .disabled(linked)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for clip \(letter): sound, open another video, clear the trim or sync points, StroMotion, close")
        }
        .fixedSize()
    }

    /// A figure; an hourglass while the body is being found.
    private var skeletonSymbol: String {
        if clip.showsSkeleton, case .preparing? = clip.poseTrack?.state { return "hourglass" }
        return "figure.arms.open"
    }

    private var skeletonHelp: String {
        switch clip.poseTrack?.state {
        case .preparing(let done)? where clip.showsSkeleton: "Finding the body… \(Int(done * 100)) %"
        case .failed(let why)? where clip.showsSkeleton: why
        default: "Skeleton: follow the body through this clip's stretch and show its joints and their angles"
        }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) { clip.resetView() }
        zoomBase = 1
        panBase = .zero
    }

}

/// The focused clip's own tools, in the floating panel: trim In / Out, sync points, a tag, and its speed
/// against the other clip.
struct ClipTools: View {
    let clip: Clip
    let comparison: Comparison
    private var linked: Bool { comparison.linked }
    @State private var showingSpeed = false

    /// Only the speed (in the overlay, whose bar holds the overlay's own controls).
    var speedOnly = false

    @ViewBuilder var body: some View {
        if speedOnly { speedButton } else { tools }
    }

    private var speedButton: some View {
        // The clip's own speed in this segment: automatic (what matches the other clip) until set
        // by hand; the same button and slider as the playback speed, with Auto to go back.
        let speed = comparison.speed(of: clip)
        return Button { showingSpeed.toggle() } label: {
            Label(speedText((speed * 100).rounded() / 100), systemImage: clip.speed == nil ? "gauge.with.dots.needle.50percent" : "hand.point.up.left")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(clip.speed == nil ? Color.white : Theme.onAccent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(clip.speed == nil ? Theme.raised : Theme.accent, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(clip.speed == nil
              ? "This clip's speed when the two play together: automatic, so its In to Out lasts as long as the other clip's (the longer one plays at 1×). Tap to set it yourself."
              : "This clip's speed when the two play together, set by hand. Tap, then Auto, to match the other clip again.")
        .popover(isPresented: $showingSpeed, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                VerticalSpeedSlider(speed: Float(speed), accent: Theme.accent) { clip.speed = Double($0) }
                Button { clip.speed = nil } label: {
                    Text("Auto")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(clip.speed == nil ? Theme.onAccent : Color.primary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(clip.speed == nil ? Theme.accent : Color.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("The speed that matches the other clip")
            }
            .padding(6)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func onFocus() {}

    /// "Add sync", or "Add sync (2)" once there are some.
    private var syncLabel: String {
        switch clip.syncs.count {
        case 0: return "Add sync"
        default: return "Add sync (\(clip.syncs.count))"
        }
    }

    /// "1.27"
    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    private func syncButton(labelled: Bool) -> some View {
        Button { onFocus(); clip.toggleSync() } label: {
            if clip.syncHere != nil {
                // On a sync point: the same button takes it away, and says so.
                Label(labelled ? "Remove sync" : "", systemImage: "xmark")
            } else if labelled {
                Label(syncLabel, systemImage: "diamond")
            } else {
                // Narrow: the diamond, and how many there are.
                Label(clip.syncs.isEmpty ? "" : "\(clip.syncs.count)", systemImage: "diamond")
            }
        }
        .buttonStyle(ChipStyle(active: clip.syncHere != nil))
        .disabled(linked)
        .fixedSize()
        .help("Mark this frame as a sync point inside the segment, or unmark it (S): a moment such as contact. "
            + "Sync points pair up in order with the other clip's, so each phase between them lines up too.")
    }

    /// In or Out: tap to set it at the playhead; once set, its ✕ clears it.
    private func trimButton(label: String, set: Bool, help: String,
                            action: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: action) { Text(label) }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .padding(.trailing, set ? 4 : 10)
                .frame(height: 28)
                .contentShape(Rectangle())
                .help(help)
            if set {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.22), in: Circle())
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 3)
                .help("Clear")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(set ? Theme.onAccent : Color.white)
        .background(set ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
        .fixedSize()
    }

    /// Trim, sync point and speed: what lines this clip up with the other.
    private var tools: some View {
        HStack(spacing: 6) {
            // In / Out show where the trim is once it's set, with an ✕ to take just that one away.
            trimButton(
                label: clip.trimStart > 0 ? "In \(short(clip.trimStart))" : "In",
                set: clip.trimStart > 0,
                help: "This clip's start in the segment: the playhead ([). The two starts line up.",
                action: clip.setTrimStart,
                clear: clip.clearTrimStart)
            trimButton(
                label: clip.trimEnd.map { "Out \(short($0))" } ?? "Out",
                set: clip.trimEnd != nil,
                help: "This clip's end in the segment: the playhead (]). With an end on both clips, the shorter stretch is slowed to finish with the longer.",
                action: clip.setTrimEnd,
                clear: clip.clearTrimEnd)

            ViewThatFits(in: .horizontal) {
                syncButton(labelled: true)
                syncButton(labelled: false)
            }

            speedButton
        }
    }
}

/// The icon's mark: an M with a trail of three faded echoes, drawn at any size.
struct EchoMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 1024
            func m(_ offset: CGFloat) -> Path {
                var path = Path()
                let points: [CGPoint] = [(250, 760), (250, 290), (512, 600), (774, 290), (774, 760)]
                    .map { CGPoint(x: ($0.0 + offset) * scale, y: ($0.1 - 13 + offset) * scale) }
                path.addLines(points)
                return path
            }
            let stroke = StrokeStyle(lineWidth: 96 * scale, lineCap: .round, lineJoin: .round)
            for (offset, opacity) in [(108.0, 0.18), (72.0, 0.32), (36.0, 0.55)] {
                context.stroke(m(offset), with: .color(Theme.accent.opacity(opacity)), style: stroke)
            }
            context.stroke(m(0), with: .color(Theme.accent), style: stroke)
        }
    }
}

/// A clip's own time: "1.23 s".
func clock(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(2))) + " s"
}

/// A Mimesis project file (`Name.mimesis`), for drops.
func isProject(_ url: URL) -> Bool {
    url.isFileURL && url.pathExtension.lowercased() == ComparisonStore.fileExtension
}

/// A file that plays as a video (by its extension), for drops.
func isVideo(_ url: URL) -> Bool {
    url.isFileURL && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false)
}
