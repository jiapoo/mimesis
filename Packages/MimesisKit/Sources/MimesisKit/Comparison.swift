import AreteMedia
import Foundation
import Observation

/// One side of a comparison: a video, how it's trimmed, its sync points, its speed, and how it's shown.
@MainActor @Observable
public final class Clip {
    public let engine = VideoEngine()
    public private(set) var url: URL?
    /// Notes pinned to frames (the chosen segment's).
    public var notes: [FrameNote] = []
    /// The notes to show at the playhead.
    var visibleNotes: [FrameNote] {
        let now = engine.currentTime
        return notes.filter { abs($0.time - now) <= max(FrameNote.reach, frameLength) }
    }
    /// The body followed through the clip's stretch, once asked for (not saved: it's found again), and
    /// whether its skeleton shows over the video.
    var poseTrack: PoseTrack?
    public var showsSkeleton = false
    /// The video this clip showed before it was edited (turned, cropped, trimmed), to go back to.
    public var beforeEdit: URL?

    /// The trim, in the clip's own seconds. `trimEnd` nil is the clip's end.
    public var trimStart: Double = 0 { didSet { applyBounds() } }
    public var trimEnd: Double? { didSet { applyBounds() } }
    /// Moments inside the segment that line up with the other clip's, in order (e.g. racket drop,
    /// contact): each phase between them is matched to the other clip's. Sorted.
    public var syncs: [Double] = []
    /// This clip's speed while linked, set by hand; nil plays at the speed that matches the other clip
    /// (see `Segment`).
    public var speed: Double?
    /// Zoom (1 is the whole frame) and pan, in points; only how it's shown.
    public var zoom: CGFloat = 1
    public var pan: CGSize = .zero
    /// Lines, arrows, circles and angles drawn on the clip.
    public var drawings: [Drawing] = []
    /// The player cut out of this clip for the overlay, once asked for (not saved: it's made again).
    public private(set) var cutout: Cutout?

    public init() {
        engine.isMuted = true
        watchPlaying()
    }

    public var isLoaded: Bool { url != nil }
    public var name: String { url?.deletingPathExtension().lastPathComponent ?? "" }
    public var end: Double { trimEnd ?? engine.duration }
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
        poseTrack?.cancel()
        poseTrack = nil
        showsSkeleton = false
        beforeEdit = nil
        trimStart = 0
        trimEnd = nil
        syncs = []
        speed = nil
        zoom = 1
        pan = .zero
        drawings = []
        notes = []
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

    public func clearTrimStart() { trimStart = 0 }
    public func clearTrimEnd() { trimEnd = nil }

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

    /// The trim holds only while playing (from In to Out, looping). Paused, the playhead goes anywhere,
    /// so In and Out can be moved: the engine would otherwise keep every seek and step inside them.
    private func applyBounds() {
        guard engine.isPlaying else { return }
        engine.setPlaybackBounds(trimStart...max(trimStart, end))
    }

    private func watchPlaying() {
        withObservationTracking {
            _ = engine.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.playingChanged()
                self.watchPlaying()
            }
        }
    }

    private func playingChanged() {
        if engine.isPlaying {
            applyBounds()
            // Played from outside the trim: from In.
            if engine.currentTime < trimStart - 0.05 || engine.currentTime > end + 0.05 {
                Task { await engine.seekToTime(trimStart) }
            }
        } else {
            // Not straight away: a loop pauses for a moment at Out on its way back to In.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !engine.isPlaying { engine.setPlaybackBounds(nil) }
            }
        }
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

    public private(set) var clips = [Clip(), Clip()]

    /// Swaps the two videos: A becomes B and B becomes A, each with everything that's its own (In/Out,
    /// sync points, speed, drawings, cutout) in every segment. The same video stays selected, and the
    /// same one stays on top in the overlay, so drawings made there are still right.
    public func swapClips() {
        let wasLinked = linked
        if wasLinked { pause() }
        storeSegment()
        clips.swapAt(0, 1)
        for at in segments.indices {
            segments[at].parts.swapAt(0, 1)
            segments[at].placement.top = 1 - segments[at].placement.top
        }
        focus = 1 - focus
        if layout == .left { layout = .right } else if layout == .right { layout = .left }
        overlayTop = 1 - overlayTop
        if drawing == .clip(0) { drawing = .clip(1) } else if drawing == .clip(1) { drawing = .clip(0) }
        if wasLinked { Task { await seek(to: position) } }
    }
    /// The segments (see `Segment`); the clips show `segments[segmentIndex]`.
    public internal(set) var segments = [Segment(name: "Segment 1")]
    public internal(set) var segmentIndex = 0
    public var layout: Layout = .both
    /// Which pane the keys and the shared controls act on while not linked.
    public var focus = 0

    /// The clip picked out on screen (ringed, its own tools in the panel). None while linked ("A+B"):
    /// then both are one, nothing is dimmed, and the controls move both.
    public var selected: Clip? { linked ? nil : focused }

    // MARK: Drawing

    public enum DrawTarget: Equatable {
        case clip(Int)
        /// Both clips at once (linked, or both watched), from the one Draw button in the panel.
        case both
    }

    /// What's being drawn on, if anything.
    public var drawing: DrawTarget?
    let pen = Pen()
    /// The joint angles written on the skeletons.
    var skeletonAngles = JointAngle.usual
    /// The angle graphed in the sidebar.
    var graphAngle = JointAngle.rightElbow
    let history = EditHistory()
    let overlayUI = OverlayUI()

    public func isDrawing(on clip: Clip) -> Bool {
        switch drawing {
        case .both: true
        case .clip(let index): clips[index] === clip
        case nil: false
        }
    }

    /// One Draw for both clips, while linked.
    public var drawsTogether: Bool { canLink && (linked || layout == .overlay) }

    public func toggleDrawingBoth() {
        if drawing == .both {
            drawing = nil
        } else {
            linked ? pause() : clips.forEach { $0.engine.pause() }
            drawing = .both
        }
    }

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
            drawing = nil
            // Linking goes to the sync point: where the two line up, and where play starts.
            if linked { Task { await seek(to: loopStart) } }
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
    // Time on it is seconds on screen (at 1×) from the segment's start. Each clip follows a warp
    // through the moments that line up: the starts, the sync points, and the ends (see `Segment`).

    var a: Clip { clips[0] }
    var b: Clip { clips[1] }

    private func side(_ clip: Clip) -> SegmentSide {
        SegmentSide(start: clip.trimStart, end: clip.trimEnd, keys: clip.syncs, speed: clip.speed)
    }

    func warp(_ clip: Clip) -> Warp {
        let pair = Warp.pair(side(a), side(b))
        return clip === a ? pair.a : pair.b
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

    /// Which phase the playhead is in (1-based) and how many there are, when sync points split the segment.
    public var section: (index: Int, count: Int)? {
        let w = [warp(a), warp(b)].max { $0.u.count < $1.u.count }!
        guard w.u.count > 2 else { return nil }
        let u = position
        guard u >= w.u[0], u <= w.u[w.u.count - 1] else { return nil }
        let index = (w.u.lastIndex { $0 <= u } ?? 0) + 1
        return (min(index, w.u.count - 1), w.u.count - 1)
    }

    /// How fast a clip is playing where the playhead is (before the playback speed).
    public func pace(of clip: Clip) -> Double {
        warp(clip).slope(at: position)
    }

    /// The smallest step that still moves a clip by a frame.
    private var frameStep: Double {
        let u = position
        return min(a.frameLength / max(0.01, warp(a).slope(at: u)), b.frameLength / max(0.01, warp(b).slope(at: u)))
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
        if linked { return isPlaying }
        return focused?.engine.isPlaying ?? false
    }

    public func play() {
        guard linked, canLink else { return }
        isPlaying = true
        Task {
            // From the start again when at the end; and always from lined-up frames.
            let from = position >= range.upperBound - frameStep ? loopStart : position
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

    /// Where a clip's player really is right now (the engine's own time is only refreshed now and then,
    /// too coarse to compare two players by).
    private func liveTime(_ clip: Clip) -> Double {
        guard let time = clip.engine.player?.currentTime().seconds, time.isFinite else { return clip.engine.currentTime }
        return time
    }

    /// A at its own speed; B at its speed for the section the playhead is in, a touch faster or slower
    /// (`nudge`, a share of its speed) while it's catching up with A.
    private func applyRates(at u: Double? = nil, nudge: Double = 0) {
        let u = u ?? position
        for clip in clips {
            var rate = warp(clip).slope(at: u) * linkedSpeed
            if clip === b { rate *= 1 + nudge }
            let speed = Float(min(8, max(0.05, rate)))
            if abs(clip.engine.playbackSpeed - speed) > 0.002 { clip.engine.playbackSpeed = speed }
        }
    }

    /// While linked and playing: loops at the end of the span both cover, changes B's speed as it enters
    /// each section, and keeps B in line with A.
    ///
    /// B is kept in line by playing it very slightly faster or slower until it's back (never seen), not
    /// by jumping it to the right frame: each jump made B stutter, and they came often, because the two
    /// clips were compared by times that are only refreshed a few times a second. A jump is kept for
    /// when B is far out (a hiccup in decoding).
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isPlaying else { return }
                let u = self.warp(self.a).u(at: self.liveTime(self.a))
                if u >= self.range.upperBound - self.frameStep {
                    for clip in self.clips { clip.engine.pause() }
                    await self.seek(to: self.loopStart)
                    guard self.isPlaying else { return }
                    self.applyRates()
                    for clip in self.clips { clip.engine.play() }
                    continue
                }
                let follower = self.b
                // How far B is ahead of where it should be, in its own seconds.
                let drift = self.liveTime(follower) - self.clipTime(follower, at: u)
                let frame = follower.frameLength
                if abs(drift) > max(0.25, 8 * frame) {
                    follower.engine.seekFast(self.clipTime(follower, at: u))
                    self.applyRates(at: u)
                } else if abs(drift) > frame * 0.5 {
                    // Close the gap over about half a second, by at most 6 % of its speed.
                    let slope = max(0.05, self.warp(follower).slope(at: u) * self.linkedSpeed)
                    self.applyRates(at: u, nudge: min(0.06, max(-0.06, -drift / 0.5 / slope)))
                } else {
                    self.applyRates(at: u)
                }
            }
        }
    }

    /// Where linked play starts and loops from: the segment's start.
    public var loopStart: Double { range.lowerBound }

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
