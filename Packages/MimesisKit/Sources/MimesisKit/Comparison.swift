import AreteMedia
import Foundation
import Observation

/// One side of a comparison: a video, how it's trimmed, its sync point, its speed, and how it's shown.
@MainActor @Observable
public final class Clip {
    public let engine = VideoEngine()
    public private(set) var url: URL?

    /// The trim, in the clip's own seconds. `trimEnd` nil is the clip's end.
    public var trimStart: Double = 0 { didSet { applyBounds() } }
    public var trimEnd: Double? { didSet { applyBounds() } }
    /// The moment that lines up with the other clip's sync point (e.g. contact). Nil is the trim start.
    public var sync: Double?
    /// How fast this clip plays against the other, to match their motions (0.8× slows it down).
    public var speed: Double = 1
    /// Zoom (1 is the whole frame) and pan, in points; only how it's shown.
    public var zoom: CGFloat = 1
    public var pan: CGSize = .zero

    public init() {
        engine.isMuted = true
    }

    public var isLoaded: Bool { url != nil }
    public var name: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    public var end: Double { trimEnd ?? engine.duration }
    public var syncTime: Double { sync ?? trimStart }
    /// One frame, in the clip's own seconds.
    public var frameLength: Double { 1 / Double(engine.fps > 0 ? engine.fps : 30) }

    public func open(_ newURL: URL) async {
        url?.stopAccessingSecurityScopedResource()
        _ = newURL.startAccessingSecurityScopedResource()
        engine.cleanup()
        url = newURL
        trimStart = 0
        trimEnd = nil
        sync = nil
        speed = 1
        zoom = 1
        pan = .zero
        await engine.loadVideo(url: newURL)
    }

    public func close() {
        engine.cleanup()
        url?.stopAccessingSecurityScopedResource()
        url = nil
    }

    /// Trim start or end at the playhead.
    public func setTrimStart() {
        trimStart = min(engine.currentTime, end - frameLength)
        if let sync, sync < trimStart { self.sync = trimStart }
    }

    public func setTrimEnd() {
        let at = max(engine.currentTime, trimStart + frameLength)
        trimEnd = at >= engine.duration - 0.01 ? nil : at
        if let sync, sync > end { self.sync = end }
    }

    public func clearTrim() {
        trimStart = 0
        trimEnd = nil
    }

    public func setSync() {
        sync = min(max(engine.currentTime, trimStart), end)
    }

    public func toggleMirror() {
        Task { await engine.setMirror(horizontal: !engine.mirroredHorizontally, vertical: false) }
    }

    public func resetView() {
        zoom = 1
        pan = .zero
    }

    private func applyBounds() {
        engine.setPlaybackBounds(trimStart...max(trimStart, end))
    }
}

/// Two clips side by side: each played on its own, or linked so they play and step together,
/// lined up at their sync points and each at its own speed.
@MainActor @Observable
public final class Comparison {
    public enum Layout: String, CaseIterable, Identifiable {
        case both, left, right
        public var id: Self { self }
        public var title: String {
            switch self {
            case .both: "Both"
            case .left: "Left"
            case .right: "Right"
            }
        }
    }

    public let clips = [Clip(), Clip()]
    public var layout: Layout = .both
    /// Which pane the keys and the shared controls act on while not linked.
    public var focus = 0

    /// Linked: one play button, one timeline; both clips move together.
    public var linked = false {
        didSet {
            guard linked != oldValue else { return }
            for clip in clips { clip.engine.pause() }
            stopTicker()
            isPlaying = false
            if linked { Task { await seek(to: position) } }
        }
    }

    /// The speed both clips play at while linked, on top of each one's own speed (0.25× for slow motion).
    public var linkedSpeed: Double = 1 {
        didSet { if isPlaying { applyRates() } }
    }

    public private(set) var isPlaying = false
    private var ticker: Task<Void, Never>?

    public init() {}

    /// The clips shown, and opened.
    public var shown: [Clip] {
        switch layout {
        case .both: clips.filter(\.isLoaded)
        case .left: clips[0].isLoaded ? [clips[0]] : []
        case .right: clips[1].isLoaded ? [clips[1]] : []
        }
    }

    public var canLink: Bool { clips.allSatisfy(\.isLoaded) }

    // MARK: - The linked timeline
    //
    // Time on it is seconds of motion from the sync points: 0 is both sync points, and at `u`
    // each clip shows `sync + u × speed` of its own time.

    public func clipTime(_ clip: Clip, at u: Double) -> Double {
        clip.syncTime + u * clip.speed
    }

    /// Where the linked timeline is, read from the first clip shown.
    public var position: Double {
        guard let lead = shown.first ?? clips.first(where: \.isLoaded) else { return 0 }
        return (lead.engine.currentTime - lead.syncTime) / lead.speed
    }

    /// The span every shown clip covers, within its trim.
    public var range: ClosedRange<Double> {
        let spans = shown.map { clip in
            ((clip.trimStart - clip.syncTime) / clip.speed)...((clip.end - clip.syncTime) / clip.speed)
        }
        guard let first = spans.first else { return 0...0 }
        let low = spans.map(\.lowerBound).max() ?? first.lowerBound
        let high = spans.map(\.upperBound).min() ?? first.upperBound
        return low...max(low, high)
    }

    /// The smallest step that still moves a clip by a frame.
    private var frameStep: Double {
        shown.map { $0.frameLength / $0.speed }.min() ?? 1 / 30
    }

    public func seek(to u: Double) async {
        let u = min(max(u, range.lowerBound), range.upperBound)
        // Both seeks at once, then wait for both.
        let seeks = shown.map { clip in
            let time = clipTime(clip, at: u)
            return Task { await clip.engine.seekToTime(time) }
        }
        for seek in seeks { await seek.value }
    }

    /// While scrubbing: quick, roughly placed frames.
    public func scrub(to u: Double) {
        let u = min(max(u, range.lowerBound), range.upperBound)
        for clip in shown { clip.engine.seekFast(clipTime(clip, at: u)) }
    }

    /// The clip the shared controls act on while not linked.
    public var focused: Clip? {
        clips.indices.contains(focus) && clips[focus].isLoaded ? clips[focus] : clips.first(where: \.isLoaded)
    }

    /// Frame steps: both clips while linked, else the focused one.
    public func step(_ frames: Int) {
        guard linked else {
            guard let clip = focused else { return }
            clip.engine.pause()
            let target = clip.engine.currentTime + Double(frames) * clip.frameLength
            Task { await clip.engine.seekToTime(target) }
            return
        }
        pause()
        let target = position + Double(frames) * frameStep
        Task { await seek(to: target) }
    }

    // MARK: - Playing

    public func togglePlay() {
        if linked {
            isPlaying ? pause() : play()
        } else {
            focused?.engine.togglePlayPause()
        }
    }

    /// Playing, linked or the focused clip.
    public var anyPlaying: Bool {
        linked ? isPlaying : focused?.engine.isPlaying ?? false
    }

    public func play() {
        guard linked, !shown.isEmpty else { return }
        isPlaying = true
        Task {
            // From the start again when at the end; and always from lined-up frames.
            let from = position >= range.upperBound - frameStep ? range.lowerBound : position
            await seek(to: from)
            guard isPlaying else { return }
            applyRates()
            for clip in shown {
                clip.engine.loopPlayback = false
                clip.engine.play()
            }
            startTicker()
        }
    }

    /// Pauses, and puts the clips back on exactly matching frames.
    public func pause() {
        guard linked else { return }
        let wasPlaying = isPlaying
        isPlaying = false
        stopTicker()
        for clip in clips { clip.engine.pause() }
        if wasPlaying { Task { await seek(to: position) } }
    }

    private func applyRates() {
        for clip in shown { clip.engine.playbackSpeed = Float(clip.speed * linkedSpeed) }
    }

    /// While linked and playing: loops at the end of the span both cover, and pulls a clip that
    /// drifted more than a frame and a half back in line.
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying, let lead = self.shown.first else { return }
                let u = self.position
                if u >= self.range.upperBound - self.frameStep {
                    for clip in self.shown { clip.engine.pause() }
                    await self.seek(to: self.range.lowerBound)
                    guard self.isPlaying else { return }
                    for clip in self.shown { clip.engine.play() }
                    continue
                }
                for clip in self.shown where clip !== lead {
                    let expected = self.clipTime(clip, at: u)
                    if abs(clip.engine.currentTime - expected) > 1.5 * clip.frameLength * max(1, clip.speed) {
                        clip.engine.seekFast(expected)
                    }
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
