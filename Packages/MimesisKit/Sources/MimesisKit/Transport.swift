import AreteMedia
import SwiftUI

/// The floating panel at the bottom: Arete's two timelines (a progress bar for the whole clip, and a
/// frame ruler for exact frames), then link, frame steps, play and speed.
/// Linked, it moves both clips, the ruler counting clip A's frames; otherwise the selected clip.
struct Transport: View {
    let comparison: Comparison
    @Environment(Library.self) private var library

    var body: some View {
        // While playing, only the play controls: the tools and timelines come back on pause.
        let full = !comparison.anyPlaying
        VStack(spacing: 6) {
            if full, let clip = comparison.focused {
                HStack(spacing: 8) {
                    Text(clip === comparison.clips[0] ? "A" : "B")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 20, height: 20)
                        .background(Theme.accent, in: Circle())
                        .help("The tools are clip \(clip === comparison.clips[0] ? "A" : "B")'s: tap the other clip to switch")
                    ClipTools(clip: clip, linked: comparison.linked)
                }
            }
            if full {
                marks
                ruler
            }
            HStack(spacing: 12) {
                RoundButton(symbol: "link", active: comparison.linked, size: 34) {
                    comparison.linked.toggle()
                }
                .disabled(!comparison.canLink)
                .opacity(comparison.canLink ? 1 : 0.4)
                .help("Link: play and step both clips together, lined up at their sync points (L)")

                Text(status)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    RoundButton(symbol: "backward.frame.fill", size: 34) { comparison.step(-1) }
                        .help("One frame back (,)")
                    Button { comparison.togglePlay() } label: {
                        Image(systemName: comparison.anyPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.onAccent)
                            .frame(width: 48, height: 48)
                            .background(Theme.accent, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Play / pause (Space)")
                    RoundButton(symbol: "forward.frame.fill", size: 34) { comparison.step(1) }
                        .help("One frame forward (.)")
                }

                speedMenu
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        // See-through, floating over the videos.
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .frame(maxWidth: 900)
        .animation(.easeOut(duration: 0.2), value: full)
        .disabled(comparison.focused == nil)
    }

    /// The clip on the ruler (A while linked, else the selected one), for its marks.
    private var rulerClip: Clip? {
        comparison.linked ? comparison.clips.first : comparison.focused
    }

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
            let u = (time - clip.syncTime) / clip.speed
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
    @ViewBuilder private var ruler: some View {
        if comparison.linked, let lead = comparison.clips.first {
            // Clip A's own time; a seek on it moves the shared timeline, so B follows.
            let range = comparison.range
            areteRuler(
                currentTime: lead.engine.currentTime,
                duration: lead.engine.duration,
                fps: Float(Double(lead.engine.fps)),
                onSeek: { t in comparison.scrub(to: (t - lead.syncTime) / lead.speed) },
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
            areteRuler(currentTime: 0, duration: 1, fps: 30, onSeek: { _ in })
        }
    }

    /// Which clip the controls move, and where the linked timeline is against the sync point.
    private var status: String {
        if comparison.linked {
            var parts = ["A + B", "\(seconds(comparison.position)) from sync"]
            if let section = comparison.section {
                parts.append("phase \(section.index) of \(section.count)")
            }
            let pace = comparison.sectionSpeed
            if abs(pace - 1) > 0.005 { parts.append("B at \(speedText((pace * 100).rounded() / 100))") }
            return parts.joined(separator: "  ·  ")
        }
        guard let clip = comparison.focused else { return "" }
        let letter = clip === comparison.clips[0] ? "A" : "B"
        guard let first = clip.syncs.first else { return letter }
        return "\(letter)  ·  \(seconds(clip.engine.currentTime - first)) from sync"
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
    currentTime: TimeInterval, duration: TimeInterval, fps: Float,
    onSeek: @escaping (TimeInterval) -> Void,
    trimStart: TimeInterval? = nil, trimEnd: TimeInterval? = nil,
    onDraggingChanged: ((Bool) -> Void)? = nil
) -> some View {
    FrameRulerTimeline(
        currentTime: currentTime, duration: duration, fps: fps, onSeek: onSeek,
        trimStart: trimStart, trimEnd: trimEnd,
        majorTickHeight: 36, mediumTickHeight: 24, minorTickHeight: 14,
        tickSpacing: 14,
        majorLineWidth: 3.0, mediumLineWidth: 1.8, minorLineWidth: 1.2,
        showProgressBar: true,
        cornerRadius: 12,
        majorColor: .white, mediumColor: .white.opacity(0.88), minorColor: .white.opacity(0.72),
        backgroundFill: .black.opacity(0.42),
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
