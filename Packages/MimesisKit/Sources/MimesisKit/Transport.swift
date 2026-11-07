import AreteMedia
import SwiftUI

/// The panel at the bottom, laid out as in Arete's player: the timeline on top (the time, a progress
/// bar for the whole clip, and the frame ruler), and every button in one row underneath: the clip's
/// own tools on the left, play in the middle, link, draw, undo and speed on the right.
/// Floating and see-through over the videos (Mac, iPad); docked under them on an iPhone.
struct Transport: View {
    let comparison: Comparison
    /// Under the clips instead of over them (an iPhone): the same panel, on the canvas.
    var docked = false
    /// More controls at the end of the row (the layout and the app's menu, with no top bar there).
    var extras: AnyView?
    @Environment(Library.self) private var library

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(spacing: docked ? 6 : 8) {
            timeline
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.top, docked ? 6 : 10)
        .padding(.bottom, docked ? 4 : 10)
        .background {
            if docked {
                Theme.canvas
            } else {
                // See-through: the videos show under it.
                shape.fill(Color.black.opacity(0.22))
                    .background(.ultraThinMaterial.opacity(0.35), in: shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
            }
        }
        .overlay(alignment: .top) {
            if docked { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .frame(maxWidth: docked ? .infinity : 960)
        .disabled(comparison.focused == nil)
    }

    // MARK: - The timeline

    @ViewBuilder private var timeline: some View {
        if comparison.watchingBoth && !comparison.linked {
            // Watching both, not linked: a slim timeline for each.
            VStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { index in
                    if comparison.clips[index].isLoaded { mini(comparison.clips[index], letter: index == 0 ? "A" : "B") }
                }
            }
        } else {
            VStack(spacing: 2) {
                marks
                ruler(compact: docked)
            }
        }
    }

    private func mini(_ clip: Clip, letter: String) -> some View {
        let engine = clip.engine
        let trimmed = clip.trimStart > 0 || clip.trimEnd != nil
        return HStack(spacing: 10) {
            Text(letter)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Color.white.opacity(0.18), in: Circle())
            Timeline(
                range: 0...max(0.01, engine.duration),
                value: engine.currentTime,
                highlight: trimmed ? clip.trimStart...clip.end : nil,
                marker: clip.syncs.first,
                onScrub: { t in
                    if engine.isPlaying { engine.pause() }
                    engine.seekFast(t)
                },
                onEnd: { t in Task { await engine.seekToTime(t) } })
            Text(clock(engine.currentTime))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundStyle(.white)
    }

    // MARK: - The row of buttons

    private var buttons: some View {
        HStack(spacing: 8) {
            // Left: which clip, and its own tools.
            HStack(spacing: 6) {
                focusPicker
                if let clip = comparison.selected {
                    ClipTools(clip: clip, linked: comparison.linked)
                }
            }
            Spacer(minLength: 6)
            // Middle: play.
            HStack(spacing: 8) {
                RoundButton(symbol: "backward.frame.fill", size: 32) { comparison.step(-1) }
                    .help("One frame back (,)")
                playButton(size: docked ? 40 : 44)
                RoundButton(symbol: "forward.frame.fill", size: 32) { comparison.step(1) }
                    .help("One frame forward (.)")
            }
            Spacer(minLength: 6)
            // Right: link, draw on both, undo, speed.
            HStack(spacing: 8) {
                RoundButton(symbol: "link", active: comparison.linked, size: 32) {
                    comparison.linked.toggle()
                }
                .disabled(!comparison.canLink)
                .opacity(comparison.canLink ? 1 : 0.4)
                .help("Link: play and step both clips together, lined up at their sync points (L)")
                if comparison.drawsTogether {
                    RoundButton(symbol: "pencil.tip", active: comparison.drawing == .both, size: 32) {
                        comparison.toggleDrawingBoth()
                    }
                    .help("Draw on both clips")
                }
                RoundButton(symbol: "arrow.uturn.backward", size: 32) { comparison.history.undo(comparison) }
                    .disabled(!comparison.history.canUndo)
                    .opacity(comparison.history.canUndo ? 1 : 0.4)
                    .help("Undo (⌘Z)")
                if comparison.history.canRedo {
                    RoundButton(symbol: "arrow.uturn.forward", size: 32) { comparison.history.redo(comparison) }
                        .help("Redo (⇧⌘Z)")
                }
                speedMenu
                if let extras { extras }
            }
        }
    }

    /// Which clip the controls drive: A, B, or both (A+B: nothing dimmed, play and step move both).
    /// Tapping a clip picks it too.
    @ViewBuilder private var focusPicker: some View {
        let both = comparison.canLink
        HStack(spacing: 2) {
            option("A", on: !comparison.watchingBoth && comparison.focused === comparison.clips[0],
                   shown: both || comparison.clips[0].isLoaded) { select(0) }
            if both {
                option("A+B", on: comparison.watchingBoth, shown: true) { comparison.watchingBoth = true }
                    .help("Both clips: neither dimmed; play and the frame steps move both (Esc)")
            }
            option("B", on: !comparison.watchingBoth && comparison.focused === comparison.clips[1],
                   shown: both || comparison.clips[1].isLoaded) { select(1) }
        }
        .padding(2)
        .background(Theme.raised, in: Capsule())
        .fixedSize()
        .help("Which clip the tools and timeline are for (Tab)")
    }

    @ViewBuilder
    private func option(_ title: String, on: Bool, shown: Bool, action: @escaping () -> Void) -> some View {
        if shown {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on ? Theme.onAccent : Color.white.opacity(0.7))
                    .padding(.horizontal, title.count > 1 ? 8 : 0)
                    .frame(minWidth: 26, minHeight: 26)
                    .background(on ? Theme.accent : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func select(_ index: Int) {
        switch comparison.layout {
        case .left, .right: comparison.layout = index == 0 ? .left : .right
        default: comparison.focus = index
        }
        comparison.watchingBoth = false
    }

    private func playButton(size: CGFloat) -> some View {
        Button { comparison.togglePlay() } label: {
            Image(systemName: comparison.anyPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: size, height: size)
                .background(Theme.accent, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Play / pause (Space)")
    }

    /// The clip on the ruler and its marks: always the focused one, linked or not.
    private var rulerClip: Clip? { comparison.focused }

    /// A strip over the ruler's progress bar: diamonds for sync points, dots for drawings. Tap one to go there.
    @ViewBuilder private var marks: some View {
        if let clip = rulerClip, clip.engine.duration > 0 {
            let duration = clip.engine.duration
            let drawingTimes = Array(Set(clip.drawings.map { ($0.time * 100).rounded() / 100 })).sorted()
            GeometryReader { space in
                let x = { (t: Double) in CGFloat(t / duration) * space.size.width }
                ZStack(alignment: .topLeading) {
                    // Tagged moments: small yellow tags.
                    ForEach(clip.url.flatMap { library.entry(for: $0)?.tags } ?? []) { tag in
                        markButton(at: tag.time, clip: clip) {
                            Image(systemName: "tag.fill").font(.system(size: 8))
                                .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.2))
                        }
                        .position(x: x(tag.time), y: 7)
                        .help(tag.label)
                    }
                    ForEach(drawingTimes, id: \.self) { t in
                        markButton(at: t, clip: clip) {
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                        }
                        .position(x: x(t), y: 7)
                    }
                    ForEach(Array(clip.syncs.enumerated()), id: \.offset) { index, t in
                        SyncDiamond(
                            clip: clip, index: index, width: space.size.width, movable: !comparison.linked,
                            onJump: { jump(to: t, clip: clip) })
                        .position(x: x(t), y: 7)
                    }
                }
            }
            .frame(height: 14)
            .help("Sync points, tags and drawings: tap one to go there")
        }
    }

    private func jump(to time: Double, clip: Clip) {
        if comparison.linked {
            comparison.pause()
            let u = comparison.linkedTime(of: clip, at: time)
            Task { await comparison.seek(to: u) }
        } else {
            clip.engine.pause()
            Task { await clip.engine.seekToTime(time) }
        }
    }

    private func markButton(at time: Double, clip: Clip, @ViewBuilder label: () -> some View) -> some View {
        Button {
            jump(to: time, clip: clip)
        } label: {
            label().frame(width: 22, height: 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// AreteMedia's FrameRulerTimeline, styled as in Arete's player.
    @ViewBuilder private func ruler(compact: Bool) -> some View {
        if comparison.linked, let lead = comparison.focused {
            // The focused clip's own frames; a seek on it moves the shared timeline, so the other follows.
            let range = comparison.range
            areteRuler(
                compact: compact,
                currentTime: lead.engine.currentTime,
                duration: lead.engine.duration,
                fps: lead.engine.fps,
                onSeek: { t in comparison.scrub(to: comparison.linkedTime(of: lead, at: t)) },
                trimStart: comparison.clipTime(lead, at: range.lowerBound),
                trimEnd: comparison.clipTime(lead, at: range.upperBound),
                onDraggingChanged: { dragging in
                    if dragging {
                        comparison.pause()
                    } else {
                        Task { await comparison.seek(to: comparison.position) }
                    }
                })
        } else if let clip = comparison.focused {
            let engine = clip.engine
            areteRuler(
                compact: compact,
                currentTime: engine.currentTime,
                duration: engine.duration,
                fps: engine.fps,
                onSeek: { engine.seekFast($0) },
                trimStart: clip.trimStart > 0 || clip.trimEnd != nil ? clip.trimStart : nil,
                trimEnd: clip.trimStart > 0 || clip.trimEnd != nil ? clip.end : nil,
                onDraggingChanged: { dragging in
                    if dragging { engine.pause() } else { engine.finalizeAfterScrub() }
                })
        } else {
            areteRuler(compact: compact, currentTime: 0, duration: 1, fps: 30, onSeek: { _ in })
        }
    }

    private var speed: Double {
        comparison.linked ? comparison.linkedSpeed : Double(comparison.focused?.engine.playbackSpeed ?? 1)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.1, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { value in
                Button { setSpeed(value) } label: {
                    if abs(value - speed) < 0.001 {
                        Label(speedText(value), systemImage: "checkmark")
                    } else {
                        Text(speedText(value))
                    }
                }
            }
        } label: {
            Text(speedText(speed))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 44, minHeight: 30)
                .background(Theme.raised, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private func setSpeed(_ value: Double) {
        if comparison.linked {
            comparison.linkedSpeed = value
        } else {
            comparison.focused?.engine.playbackSpeed = Float(value)
        }
    }
}

/// AreteMedia's frame ruler with Arete's player look: white ticks on a dark translucent bar,
/// the overall progress bar above it, and the playhead, time and trim in the accent.
@MainActor
private func areteRuler(
    compact: Bool = false,
    currentTime: TimeInterval, duration: TimeInterval, fps: Float,
    onSeek: @escaping (TimeInterval) -> Void,
    trimStart: TimeInterval? = nil, trimEnd: TimeInterval? = nil,
    onDraggingChanged: ((Bool) -> Void)? = nil
) -> some View {
    FrameRulerTimeline(
        currentTime: currentTime, duration: duration, fps: fps, onSeek: onSeek,
        trimStart: trimStart, trimEnd: trimEnd,
        majorTickHeight: compact ? 22 : 36, mediumTickHeight: compact ? 15 : 24, minorTickHeight: compact ? 9 : 14,
        tickSpacing: 14,
        majorLineWidth: 3.0, mediumLineWidth: 1.8, minorLineWidth: 1.2,
        showProgressBar: true,
        cornerRadius: 12,
        majorColor: .white, mediumColor: .white.opacity(0.88), minorColor: .white.opacity(0.72),
        backgroundFill: .black.opacity(0.28),
        timeCurrentColor: Theme.accent, progressFillColor: Theme.accent.opacity(0.45),
        progressDotColor: Theme.accent, accent: Theme.accent,
        onDraggingChanged: onDraggingChanged)
        .foregroundStyle(Color.white)
}

/// A sync point over the ruler: tap to go there; drag sideways to move it (not while linked),
/// a frame at a time, never past its neighbours or out of the trim. The clip shows the frame as it moves.
private struct SyncDiamond: View {
    let clip: Clip
    let index: Int
    let width: CGFloat
    let movable: Bool
    let onJump: () -> Void

    @State private var from: Double?

    var body: some View {
        Image(systemName: "diamond.fill")
            .font(.system(size: from == nil ? 10 : 13))
            .foregroundStyle(Theme.accent)
            .frame(width: 22, height: 14)
            .contentShape(Rectangle())
            .onTapGesture(perform: onJump)
            // Right-click (Mac) or press and hold (iPhone, iPad): remove it.
            .contextMenu {
                Button("Go to sync point", systemImage: "arrow.right.to.line") { onJump() }
                Button("Remove sync point", systemImage: "trash", role: .destructive) {
                    if clip.syncs.indices.contains(index) { clip.syncs.remove(at: index) }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { drag in
                        guard movable, clip.syncs.indices.contains(index) else { return }
                        let start = from ?? clip.syncs[index]
                        if from == nil {
                            from = start
                            clip.engine.pause()
                        }
                        let frame = clip.frameLength
                        let low = index > 0 ? clip.syncs[index - 1] + frame : clip.trimStart
                        let high = index + 1 < clip.syncs.count ? clip.syncs[index + 1] - frame : clip.end
                        let raw = start + Double(drag.translation.width / max(1, width)) * clip.engine.duration
                        let snapped = (raw / frame).rounded() * frame
                        let time = min(max(snapped, low), high)
                        clip.syncs[index] = time
                        clip.engine.seekFast(time)
                    }
                    .onEnded { _ in
                        if let time = clip.syncs.indices.contains(index) ? clip.syncs[index] : nil {
                            Task { await clip.engine.seekToTime(time) }
                        }
                        from = nil
                    },
                isEnabled: movable)
            .animation(.easeOut(duration: 0.1), value: from == nil)
    }
}
