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
    @State private var dropping = false

    var body: some View {
        Group {
            if clip.isLoaded {
                VStack(spacing: 8) {
                    video
                    tools
                }
                .padding(8)
            } else {
                empty
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous)
                .strokeBorder(focused || dropping ? Theme.accent : Theme.line, lineWidth: focused || dropping ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onDropped(url)
            return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.15), value: focused)
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(alignment: .topLeading) { badge.padding(10) }
        .overlay(alignment: .topTrailing) { actions.padding(10) }
        .overlay(alignment: .bottom) {
            if drawing {
                DrawingTools(clip: clip, tool: $tool, ink: $ink, always: $always) { drawing = false }
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: drawing)
    }

    private var badge: some View {
        HStack(spacing: 8) {
            Text(letter)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(focused ? Theme.onAccent : .white)
                .frame(width: 22, height: 22)
                .background(focused ? Theme.accent : Color.white.opacity(0.18), in: Circle())
            Text(clip.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 200)
                .fixedSize(horizontal: true, vertical: false)
            Text(clock(clip.engine.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        .foregroundStyle(.white)
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.45), in: Capsule())
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
            RoundButton(symbol: clip.engine.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                clip.engine.isMuted.toggle()
            }
            .help("Sound (M)")
            Menu {
                Button("Open video…", systemImage: "folder", action: onOpenFile)
                Button("From Photos…", systemImage: "photo.on.rectangle", action: onOpenPhotos)
                Divider()
                Button("Clear trim", systemImage: "scissors", action: clip.clearTrim)
                    .disabled(clip.trimStart == 0 && clip.trimEnd == nil)
                Button("Clear sync points", systemImage: "diamond") { clip.syncs = [] }
                    .disabled(clip.syncs.isEmpty || linked)
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
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.2)) { clip.resetView() }
        zoomBase = 1
        panBase = .zero
    }

    // MARK: - Tools

    /// "Add sync", "Sync 2 of 3" when on one, "3 syncs" otherwise.
    private var syncLabel: String {
        if let here = clip.syncHere { return clip.syncs.count == 1 ? "Sync" : "Sync \(here + 1) of \(clip.syncs.count)" }
        switch clip.syncs.count {
        case 0: return "Add sync"
        case 1: return "1 sync"
        default: return "\(clip.syncs.count) syncs"
        }
    }

    /// Trim, sync point and speed: what lines this clip up with the other.
    private var tools: some View {
        HStack(spacing: 6) {
            Button { onFocus(); clip.setTrimStart() } label: { Text("In") }
                .buttonStyle(ChipStyle(active: clip.trimStart > 0))
                .help("Start the clip at the playhead ([)")
            Button { onFocus(); clip.setTrimEnd() } label: { Text("Out") }
                .buttonStyle(ChipStyle(active: clip.trimEnd != nil))
                .help("End the clip at the playhead (])")
            Text("\(clock(clip.trimStart)) – \(clock(clip.end))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer(minLength: 6)

            Button { onFocus(); clip.toggleSync() } label: {
                Label(syncLabel, systemImage: clip.syncHere == nil ? "diamond" : "diamond.fill")
            }
            .buttonStyle(ChipStyle(active: !clip.syncs.isEmpty))
            .disabled(linked)
            .help("Mark this frame as a sync point, or unmark it (S). Sync points pair up in order with the "
                + "other clip's: the first lines the clips up, more make each phase in between line up too.")

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
