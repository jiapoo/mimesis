import AreteMedia
import SwiftUI

/// The controls at the bottom, laid out as in Arete's player, in two parts:
/// - `.timeline`: the time, a progress bar for the whole clip and the frame ruler, from edge to edge,
///   see-through over the bottom of the videos;
/// - `.bar`: a solid bar under the videos with every button in one row: the clip's own tools on the
///   left, play in the middle, draw, undo and speed on the right.
struct Transport: View {
    enum Part { case timeline, bar }

    let comparison: Comparison
    let part: Part
    /// More controls at the end of the bar (an iPhone's layout and menu: it has no top bar).
    var extras: AnyView?
    @Environment(Library.self) private var library

    var body: some View {
        switch part {
        case .timeline: timeline
        case .bar: bar
        }
    }

    // MARK: - The timeline

    private var timeline: some View {
        VStack(spacing: 2) {
            if comparison.linked {
                // Linked: how far from sync, the phase, and B's pace in it.
                Text(linkedStatus)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
            }
            marks
            ruler(compact: false)
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 8)
        // A soft shade from below, so the timeline reads over a bright video.
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false))
        .disabled(comparison.focused == nil)
    }

    // MARK: - The bar

    private var bar: some View {
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
                playButton(size: 42)
                RoundButton(symbol: "forward.frame.fill", size: 32) { comparison.step(1) }
                    .help("One frame forward (.)")
            }
            Spacer(minLength: 6)
            // Right: draw on both, undo, speed.
            HStack(spacing: 8) {
                if comparison.drawsTogether {
                    RoundButton(symbol: "pencil.tip.crop.circle", active: comparison.drawing == .both, size: 32) {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .disabled(comparison.focused == nil)
    }

    /// Which clip the controls drive: A, B, or A+B: linked, both playing and stepping together, lined up
    /// at their sync points (L). Tapping a clip picks it too.
    @ViewBuilder private var focusPicker: some View {
        let both = comparison.canLink
        HStack(spacing: 2) {
            option("A", on: !comparison.linked && comparison.focused === comparison.clips[0],
                   shown: both || comparison.clips[0].isLoaded) { select(0) }
            if both {
                Button { comparison.linked = true } label: {
                    HStack(spacing: 3) {
                        Text("A")
                        Image(systemName: "link").font(.system(size: 9, weight: .bold))
                        Text("B")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(comparison.linked ? Theme.onAccent : Color.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .background(comparison.linked ? Theme.accent : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("A+B, linked: both play and step together, lined up at their sync points (L)")
            }
            option("B", on: !comparison.linked && comparison.focused === comparison.clips[1],
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
                    .frame(minWidth: 26, minHeight: 26)
                    .background(on ? Theme.accent : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func select(_ index: Int) {
        comparison.linked = false
        switch comparison.layout {
        case .left, .right: comparison.layout = index == 0 ? .left : .right
        default: comparison.focus = index
        }
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

    /// "+0.20 s from sync · phase 2 of 3 · B at 0.82×"
    private var linkedStatus: String {
        var parts = ["\(seconds(comparison.position)) from sync"]
        if let section = comparison.section {
            parts.append("phase \(section.index) of \(section.count)")
        }
        let pace = comparison.sectionSpeed
        if abs(pace - 1) > 0.005 { parts.append("B at \(speedText((pace * 100).rounded() / 100))") }
        return parts.joined(separator: "  ·  ")
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
