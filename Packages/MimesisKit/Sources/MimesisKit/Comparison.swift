import AreteMedia
import Foundation
import Observation

/// One side of a comparison: a video, how it's trimmed, its sync points, its speed, and how it's shown.
@MainActor @Observable
public final class Clip {
    public let engine = VideoEngine()
    public private(set) var url: URL?

    /// The trim, in the clip's own seconds. `trimEnd` nil is the clip's end.
    public var trimStart: Double = 0 { didSet { applyBounds() } }
    public var trimEnd: Double? { didSet { applyBounds() } }
    /// Moments that line up with the other clip's, in order (e.g. racket drop, contact, finish).
    /// The first lines the clips up; with more, each section between them plays at the speed that
    /// makes the other clip's matching section line up too. Sorted.
    public var syncs: [Double] = []
    /// How fast this clip plays against the other, to match their motions (0.8× slows it down).
    public var speed: Double = 1
    /// Zoom (1 is the whole frame) and pan, in points; only how it's shown.
    public var zoom: CGFloat = 1
    public var pan: CGSize = .zero
    /// Lines, arrows, circles and angles drawn on the clip.
    public var drawings: [Drawing] = []
    /// The player cut out of this clip for the overlay, once asked for (not saved: it's made again).
    public private(set) var cutout: Cutout?

    public init() {
        engine.isMuted = true
    }

    public var isLoaded: Bool { url != nil }
    public var name: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    public var end: Double { trimEnd ?? engine.duration }
    /// The first sync point: where the clips line up. The trim start when there's none.
    public var syncTime: Double { syncs.first ?? trimStart }
    /// The sync point at the playhead (within half a frame), if any.
    public var syncHere: Int? {
        syncs.firstIndex { abs($0 - engine.currentTime) <= frameLength / 2 }
    }
    /// One frame, in the clip's own seconds.
    public var frameLength: Double { 1 / Double(engine.fps > 0 ? engine.fps : 30) }

    public func open(_ newURL: URL) async {
        url?.stopAccessingSecurityScopedResource()
        _ = newURL.startAccessingSecurityScopedResource()
        engine.cleanup()
        url = newURL
        trimStart = 0
        trimEnd = nil
        syncs = []
        speed = 1
        zoom = 1
        pan = .zero
        drawings = []
        dropCutout()
        await engine.loadVideo(url: newURL)
    }

    public func close() {
        dropCutout()
        engine.cleanup()
        url?.stopAccessingSecurityScopedResource()
        url = nil
    }

    /// Trim start or end at the playhead.
    public func setTrimStart() {
        trimStart = min(engine.currentTime, end - frameLength)
        syncs.removeAll { $0 < trimStart }
    }

    public func setTrimEnd() {
        let at = max(engine.currentTime, trimStart + frameLength)
        trimEnd = at >= engine.duration - 0.01 ? nil : at
        syncs.removeAll { $0 > end }
    }

    public func clearTrim() {
        trimStart = 0
        trimEnd = nil
    }

    /// Adds a sync point at the playhead, or removes the one that's there.
    public func toggleSync() {
        if let here = syncHere {
            syncs.remove(at: here)
        } else {
            syncs.append(min(max(engine.currentTime, trimStart), end))
            syncs.sort()
        }
    }

    public func toggleMirror() {
        Task { await engine.setMirror(horizontal: !engine.mirroredHorizontally, vertical: false) }
    }

    /// Starts cutting the player out of the trimmed clip, for the overlay: from the saved copy when
    /// there is one, unless `fresh`; then picks the player tapped at `pickAt`, if given.
    public func makeCutout(fresh: Bool = false, pickAt: (time: Double, point: CGPoint)? = nil) {
        dropCutout()
        cutout = Cutout(clip: self, fresh: fresh, pickAt: pickAt)
    }

    public func dropCutout() {
        cutout?.cancel()
        cutout = nil
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
        case both, left, right, overlay
        public var id: Self { self }
        public var title: String {
            switch self {
            case .both: "Both"
            case .left: "Left"
            case .right: "Right"
            case .overlay: "Overlay"
            }
        }
    }

    public let clips = [Clip(), Clip()]
    public var layout: Layout = .both
    /// Which pane the keys and the shared controls act on while not linked.
    public var focus = 0

    // MARK: Overlay

    /// The clip drawn on top in the overlay (0 is A, 1 is B); the other is underneath.
    public var overlayTop = 1
    /// How see-through the top clip is (0 hidden, 1 solid).
    public var overlayOpacity = 0.5
    /// Where the top clip sits over the other, as a share of the picture underneath (0, 0 is centred).
    public var overlayOffset: CGSize = .zero
    /// The top clip's size against the picture underneath (1 fits it).
    public var overlayScale: CGFloat = 1
    /// The top clip turned about its centre, in degrees clockwise (for a camera that wasn't level).
    public var overlayRotation: Double = 0

    public func resetOverlay() {
        overlayOffset = .zero
        overlayScale = 1
        overlayRotation = 0
    }

    /// Linked: one play button, one timeline; both clips move together.
    public var linked = false {
        didSet {
            guard linked != oldValue else { return }
            for clip in clips {
                clip.engine.pause()
                // Linked play loops the shared span itself; on their own, each clip loops.
                clip.engine.loopPlayback = !linked
            }
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
        case .overlay: clips.filter(\.isLoaded)
        }
    }

    public var canLink: Bool { clips.allSatisfy(\.isLoaded) }

    // MARK: - The linked timeline
    //
    // Time on it is seconds of clip A's motion from its first sync point (A at its own speed), so A
    // just plays. Clip B follows a warp through the paired sync points: between two of them it runs
    // at whatever speed makes its section last as long as A's, and outside them at its own speed.

    private var a: Clip { clips[0] }
    private var b: Clip { clips[1] }

    /// How many sync points pair up: the fewer of the two clips' counts.
    public var pairs: Int { min(a.syncs.count, b.syncs.count) }

    private func warp(_ clip: Clip) -> Warp {
        let a0 = a.syncTime
        if clip === a {
            return Warp(u: [0], t: [a0], outside: a.speed)
        }
        let n = pairs
        guard n > 0 else { return Warp(u: [0], t: [b.syncTime], outside: b.speed) }
        var us: [Double] = [], ts: [Double] = []
        for i in 0..<n {
            let u = (a.syncs[i] - a0) / a.speed, t = b.syncs[i]
            // Keep only points that move forward in both clips.
            if let lastU = us.last, let lastT = ts.last, u <= lastU || t <= lastT { continue }
            us.append(u)
            ts.append(t)
        }
        return Warp(u: us, t: ts, outside: b.speed)
    }

    public func clipTime(_ clip: Clip, at u: Double) -> Double {
        warp(clip).time(at: u)
    }

    /// Where on the linked timeline `clip` shows its own time `t`: the inverse of `clipTime`.
    public func linkedTime(of clip: Clip, at t: Double) -> Double {
        warp(clip).u(at: t)
    }

    /// Where the linked timeline is, read from clip A.
    public var position: Double {
        warp(a).u(at: a.engine.currentTime)
    }

    /// The span both clips cover, within their trims.
    public var range: ClosedRange<Double> {
        guard a.isLoaded, b.isLoaded else { return 0...0 }
        let wa = warp(a), wb = warp(b)
        let low = max(wa.u(at: a.trimStart), wb.u(at: b.trimStart))
        let high = min(wa.u(at: a.end), wb.u(at: b.end))
        return low...max(low, high)
    }

    /// How fast B runs against A in the section the playhead is in (1 is the same pace).
    public var sectionSpeed: Double {
        warp(b).slope(at: position) / a.speed
    }

    /// Which section the playhead is in (1-based) and how many there are, when there's more than one sync point.
    public var section: (index: Int, count: Int)? {
        let w = warp(b)
        guard w.u.count > 1 else { return nil }
        let u = position
        guard u >= w.u[0], u <= w.u[w.u.count - 1] else { return nil }
        let index = (w.u.lastIndex { $0 <= u } ?? 0) + 1
        return (min(index, w.u.count - 1), w.u.count - 1)
    }

    /// The smallest step that still moves a clip by a frame.
    private var frameStep: Double {
        min(a.frameLength / a.speed, b.frameLength / max(0.01, warp(b).slope(at: position)))
    }

    public func seek(to u: Double) async {
        let u = min(max(u, range.lowerBound), range.upperBound)
        // Both seeks at once, then wait for both.
        let seeks = clips.map { clip in
            let time = clipTime(clip, at: u)
            return Task { await clip.engine.seekToTime(time) }
        }
        for seek in seeks { await seek.value }
    }

    /// While scrubbing: quick, roughly placed frames.
    public func scrub(to u: Double) {
        let u = min(max(u, range.lowerBound), range.upperBound)
        for clip in clips { clip.engine.seekFast(clipTime(clip, at: u)) }
    }

    /// The clip the shared controls act on while not linked.
    /// A only or B only on screen: that one. Both: the one last tapped (or the one that's open).
    public var focused: Clip? {
        switch layout {
        case .left: return clips[0].isLoaded ? clips[0] : nil
        case .right: return clips[1].isLoaded ? clips[1] : nil
        default:
            return clips.indices.contains(focus) && clips[focus].isLoaded ? clips[focus] : clips.first(where: \.isLoaded)
        }
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
        } else if let clip = focused {
            // The focused clip only: the other keeps doing what it was doing.
            clip.engine.loopPlayback = true
            clip.engine.togglePlayPause()
        }
    }

    /// Playing: both while linked, else the focused clip (what the play button shows).
    public var anyPlaying: Bool {
        linked ? isPlaying : focused?.engine.isPlaying ?? false
    }

    public func play() {
        guard linked, canLink else { return }
        isPlaying = true
        Task {
            // From the start again when at the end; and always from lined-up frames.
            let from = position >= range.upperBound - frameStep ? range.lowerBound : position
            await seek(to: from)
            guard isPlaying else { return }
            applyRates()
            for clip in clips {
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

    /// A at its own speed; B at its speed for the section the playhead is in.
    private func applyRates() {
        let u = position
        for clip in clips {
            let rate = Float(min(8, max(0.05, warp(clip).slope(at: u) * linkedSpeed)))
            if abs(clip.engine.playbackSpeed - rate) > 0.005 { clip.engine.playbackSpeed = rate }
        }
    }

    /// While linked and playing: loops at the end of the span both cover, changes B's speed as it
    /// enters each section, and pulls B back in line when it drifts more than a frame and a half.
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.isPlaying else { return }
                let u = self.position
                if u >= self.range.upperBound - self.frameStep {
                    for clip in self.clips { clip.engine.pause() }
                    await self.seek(to: self.range.lowerBound)
                    guard self.isPlaying else { return }
                    self.applyRates()
                    for clip in self.clips { clip.engine.play() }
                    continue
                }
                self.applyRates()
                let follower = self.b
                let expected = self.clipTime(follower, at: u)
                let rate = Double(follower.engine.playbackSpeed)
                if abs(follower.engine.currentTime - expected) > 1.5 * follower.frameLength * max(1, rate) {
                    follower.engine.seekFast(expected)
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

/// A piecewise-straight map from linked time `u` to a clip's own time `t`, through matching points.
/// Outside the first and last point it runs at `outside` (the clip's own speed).
struct Warp {
    let u: [Double]
    let t: [Double]
    let outside: Double

    func time(at value: Double) -> Double {
        guard let first = u.first, let last = u.last else { return value * outside }
        if value <= first { return t[0] + (value - first) * outside }
        if value >= last { return t[t.count - 1] + (value - last) * outside }
        let i = (u.lastIndex { $0 <= value } ?? 0)
        let share = (value - u[i]) / (u[i + 1] - u[i])
        return t[i] + share * (t[i + 1] - t[i])
    }

    func u(at time: Double) -> Double {
        guard let first = t.first, let last = t.last else { return time / outside }
        if time <= first { return u[0] + (time - first) / outside }
        if time >= last { return u[u.count - 1] + (time - last) / outside }
        let i = (t.lastIndex { $0 <= time } ?? 0)
        let share = (time - t[i]) / (t[i + 1] - t[i])
        return u[i] + share * (u[i + 1] - u[i])
    }

    /// Clip seconds per second of linked time at `value`: the speed the clip plays at there.
    func slope(at value: Double) -> Double {
        guard u.count > 1, let first = u.first, let last = u.last, value >= first, value < last else { return outside }
        let i = (u.lastIndex { $0 <= value } ?? 0)
        return (t[i + 1] - t[i]) / (u[i + 1] - u[i])
    }
}
