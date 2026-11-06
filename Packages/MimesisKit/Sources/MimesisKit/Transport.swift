import AreteMedia
import SwiftUI

/// The floating panel at the bottom: Arete's two timelines (a progress bar for the whole clip, and a
/// frame ruler for exact frames), then link, frame steps, play and speed.
/// Linked, it moves both clips, the ruler counting clip A's frames; otherwise the selected clip.
struct Transport: View {
    let comparison: Comparison

    var body: some View {
        VStack(spacing: 6) {
            marks
            ruler
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .frame(maxWidth: 900)
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
                    ForEach(drawingTimes, id: \.self) { t in
                        markButton(at: t, clip: clip) {
                            Circle().fill(Color.white).frame(width: 6, height: 6)
                        }
                        .position(x: x(t), y: 7)
                    }
                    ForEach(Array(clip.syncs.enumerated()), id: \.offset) { _, t in
                        markButton(at: t, clip: clip) {
                            Image(systemName: "diamond.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                        }
                        .position(x: x(t), y: 7)
                    }
                }
            }
            .frame(height: 14)
            .help("Sync points and drawings: tap one to go there")
        }
    }

    private func markButton(at time: Double, clip: Clip, @ViewBuilder label: () -> some View) -> some View {
        Button {
            if comparison.linked {
                comparison.pause()
                let u = (time - clip.syncTime) / clip.speed
                Task { await comparison.seek(to: u) }
            } else {
                clip.engine.pause()
                Task { await clip.engine.seekToTime(time) }
            }
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
