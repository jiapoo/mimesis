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
    let onDropped: (URL) -> Void
    /// A sideways drag on the video: move this many frames (both clips while linked).
    let onJog: (Int) -> Void

    /// How far a finger moves for one frame.
    static let pointsPerFrame: CGFloat = 12

    @State private var zoomBase: CGFloat = 1
    @State private var panBase: CGSize = .zero
    @State private var jogged = 0
    @State private var drawing = false
    @State private var tool: Drawing.Kind = .line
    @State private var ink: Drawing.Ink = .crimson
    @State private var always = false
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
        // The focused clip: a thin crimson edge (only worth showing with two clips on screen).
        .overlay(
            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .opacity((focused && showsFocus) || dropping ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onDropped(url)
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
                Text(letter == "A" ? "Your swing, or the one to learn from" : "The one to compare it with")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 8) {
                Button(action: onOpenFile) { Label("Files", systemImage: "folder") }
                    .buttonStyle(ChipStyle(active: true))
                Button(action: onOpenPhotos) { Label("Photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(ChipStyle())
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
                DrawingLayer(clip: clip, editing: drawing, tool: tool, ink: ink, always: always)
            }
                .scaleEffect(clip.zoom)
                .offset(clip.pan)
                .frame(width: space.size.width, height: space.size.height)
                .clipped()
                .contentShape(Rectangle())
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
                            guard !drawing else { return }
                            if clip.zoom > 1 {
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
                        })
                .onTapGesture(count: 2) { resetView() }
                .onTapGesture(perform: onFocus)
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            // The letter and time always; the clip's buttons only on the focused clip.
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        badge(name: false, time: true)
                        badge(name: false, time: false)
                    }
                    Spacer(minLength: 0)
                    if focused || drawing {
                        actions.transition(.opacity)
                    }
                }
                if drawing {
                    DrawingTools(clip: clip, tool: $tool, ink: $ink, always: $always) { drawing = false }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(10)
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
            if clip.zoom > 1 {
                RoundButton(symbol: "arrow.down.right.and.arrow.up.left", action: resetView)
                    .help("Fit the whole frame")
            }
            RoundButton(symbol: "pencil.tip", active: drawing) {
                onFocus()
                clip.engine.pause()
                drawing.toggle()
            }
            .help("Draw lines, arrows, circles and angles on the frame")
            RoundButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        active: clip.engine.mirroredHorizontally, action: clip.toggleMirror)
                .help("Mirror side to side (⇧⌘H)")
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
        }
        .fixedSize()
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
    let linked: Bool
    @Environment(Library.self) private var library
    @State private var naming = false
    @State private var newTag = ""

    var body: some View { tools }

    private func onFocus() {}


    /// Tag the moment at the playhead ("Forehand", "Fault"…), to find it again in the library.
    private var tagMenu: some View {
        Menu {
            ForEach(library.labels, id: \.self) { label in
                Button(label) { tag(label) }
            }
            Divider()
            Button("New tag…", systemImage: "plus") {
                newTag = ""
                naming = true
            }
        } label: {
            Image(systemName: "tag")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 28)
                .background(Theme.raised, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tag this moment (a forehand, a fault…) to find it in the library")
        .alert("New tag", isPresented: $naming) {
            TextField("Split step, Kick serve…", text: $newTag)
            Button("Cancel", role: .cancel) {}
            Button("Tag") {
                let label = newTag.trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { tag(label) }
            }
        }
    }

    private func tag(_ label: String) {
        guard let url = clip.url else { return }
        onFocus()
        library.tag(url, at: clip.engine.currentTime, label: label)
    }

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
        .help("Mark this frame as a sync point, or unmark it (S). Sync points pair up in order with the "
            + "other clip's: the first lines the clips up, more make each phase in between line up too.")
    }

    /// Trim, sync point and speed: what lines this clip up with the other.
    private var tools: some View {
        HStack(spacing: 6) {
            // In / Out show where the trim is once it's set.
            Button { onFocus(); clip.setTrimStart() } label: {
                Text(clip.trimStart > 0 ? "In \(short(clip.trimStart))" : "In")
            }
            .buttonStyle(ChipStyle(active: clip.trimStart > 0))
            .help("Start the clip at the playhead ([)")
            Button { onFocus(); clip.setTrimEnd() } label: {
                Text(clip.trimEnd.map { "Out \(short($0))" } ?? "Out")
            }
            .buttonStyle(ChipStyle(active: clip.trimEnd != nil))
            .help("End the clip at the playhead (])")

            Spacer(minLength: 6)

            ViewThatFits(in: .horizontal) {
                syncButton(labelled: true)
                syncButton(labelled: false)
            }

            tagMenu

            Menu {
                ForEach([0.25, 0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button(speedText(value)) { clip.speed = value }
                }
                Divider()
                Button("Slower by 0.05×") { clip.speed = max(0.25, clip.speed - 0.05) }
                Button("Faster by 0.05×") { clip.speed = min(2, clip.speed + 0.05) }
            } label: {
                Label(speedText(clip.speed), systemImage: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(clip.speed == 1 ? Color.white : Theme.onAccent)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(clip.speed == 1 ? Theme.raised : Theme.accent, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(linked)
            .help("This clip's speed against the other, to match the two motions")
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
                    .map { CGPoint(x: ($0.0 - 54 + offset) * scale, y: ($0.1 - 62 + offset) * scale) }
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
