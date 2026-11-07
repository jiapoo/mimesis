import AreteMedia
import SwiftUI

/// The floating panel at the bottom: Arete's two timelines (a progress bar for the whole clip, and a
/// frame ruler for exact frames), then link, frame steps, play and speed.
/// Linked, it moves both clips, the ruler counting clip A's frames; otherwise the selected clip.
struct Transport: View {
    let comparison: Comparison
    /// Docked under the clips on a phone held sideways: one slim ruler and one row, always all there,
    /// so the clips never jump in size when playback starts.
    var docked = false
    /// More controls at the end of the docked row (the layout and the app's menu, with no top bar there).
    var extras: AnyView?
    @Environment(Library.self) private var library

    var body: some View {
        if docked { dock } else { panel }
    }

    /// The phone's dock: the ruler, then the clip's tools on the left and playback on the right.
    private var dock: some View {
        VStack(spacing: 4) {
            marks
            ruler(compact: true)
            HStack(spacing: 8) {
                focusPicker
                if let clip = comparison.focused {
                    ClipTools(clip: clip, linked: comparison.linked)
                } else {
                    Spacer(minLength: 0)
                }
                Divider().frame(height: 22).overlay(Color.white.opacity(0.15))
                RoundButton(symbol: "link", active: comparison.linked, size: 32) {
                    comparison.linked.toggle()
                }
                .disabled(!comparison.canLink)
                .opacity(comparison.canLink ? 1 : 0.4)
                RoundButton(symbol: "backward.frame.fill", size: 32) { comparison.step(-1) }
                playButton(size: 40)
                RoundButton(symbol: "forward.frame.fill", size: 32) { comparison.step(1) }
                speedMenu
                if let extras { extras }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(Theme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .disabled(comparison.focused == nil)
    }

    /// Which clip the controls drive: A or B. Tapping a clip does the same.
    @ViewBuilder private var focusPicker: some View {
        let both = comparison.clips.allSatisfy(\.isLoaded)
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { index in
                let clip = comparison.clips[index]
                let on = comparison.focused === clip
                if both || on {
                    Button {
                        select(index)
                    } label: {
                        Text(index == 0 ? "A" : "B")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(on ? Theme.onAccent : Color.white.opacity(0.7))
                            .frame(width: 26, height: 26)
                            .background(on ? Theme.accent : .clear, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(2)
        .background(Theme.raised, in: Capsule())
        .fixedSize()
        .help("Which clip the tools and timeline are for (Tab)")
    }

    private func select(_ index: Int) {
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

    @ViewBuilder private var panel: some View {
        // While playing, only the play controls: the tools and timelines come back on pause.
        let full = !comparison.anyPlaying
        VStack(spacing: 6) {
            if full, let clip = comparison.focused {
                HStack(spacing: 8) {
                    focusPicker
                    ClipTools(clip: clip, linked: comparison.linked)
                }
            }
            if full {
                marks
                ruler(compact: false)
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
                    playButton(size: 48)
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
