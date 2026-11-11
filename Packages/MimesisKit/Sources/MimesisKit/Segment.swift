import Foundation

/// A named stretch of the comparison, like a layer: for each clip its start and end (In / Out), the
/// moments inside that should line up (sync points), its speed, and what was drawn on it; and where
/// the top clip sits in the overlay. A comparison has one or more; the clips show the chosen one.
///
/// How a segment plays, linked: the two starts line up. Once both clips have an end, the ends line
/// up too: the longer stretch plays at 1× and the shorter is slowed to last as long (1.0 s against
/// 1.2 s plays at 0.83×). Sync points in between pair up in order and split the stretch into phases,
/// each matched the same way. A speed set by hand on a clip replaces its matching, until reset.
public struct Segment: Codable, Identifiable, Equatable {
    /// One clip's share of a segment.
    public struct Part: Codable, Equatable {
        public var trimStart: Double = 0
        public var trimEnd: Double?
        public var syncs: [Double] = []
        /// Set by hand; nil plays at the speed that matches the other clip.
        public var speed: Double?
        public var drawings: [Drawing] = []
        /// Notes pinned to frames of this clip. Nil in older saves.
        public var notes: [FrameNote]?
    }

    /// Where the top clip sits over the other in the overlay.
    public struct Placement: Codable, Equatable {
        public var top = 1
        public var offset: CGSize = .zero
        public var scale: Double = 1
        public var rotation: Double = 0
    }

    public var id = UUID()
    public var name: String
    public var parts = [Part(), Part()]
    public var placement = Placement()
    /// What to look at in it, in the user's words.
    public var notes: String?

    public init(name: String) {
        self.name = name
    }
}

/// A note pinned to a frame of a clip: shown over the clip around that moment, marked on the timeline,
/// listed in the sidebar and written into exported videos.
public struct FrameNote: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var time: Double
    public var text: String

    /// How long before and after its frame a note shows while playing.
    static let reach = 0.75
}

/// What lines one clip up in a segment, for working out how the two play together.
struct SegmentSide {
    var start: Double
    /// Nil when no Out is set: the clip plays on to its end, unmatched.
    var end: Double?
    var keys: [Double] = []
    var speed: Double?
}

extension Warp {
    /// How the two clips of a segment run against linked time (seconds from the segment's start, on
    /// the screen at 1×).
    static func pair(_ a: SegmentSide, _ b: SegmentSide) -> (a: Warp, b: Warp) {
        // The moments that line up: the starts, the sync points in order, and the ends once both are set.
        var ta = [a.start], tb = [b.start]
        for (ka, kb) in zip(a.keys, b.keys) where ka > ta[ta.count - 1] && kb > tb[tb.count - 1] {
            if let end = a.end, ka >= end { continue }
            if let end = b.end, kb >= end { continue }
            ta.append(ka)
            tb.append(kb)
        }
        if let ea = a.end, let eb = b.end, ea > ta[ta.count - 1], eb > tb[tb.count - 1] {
            ta.append(ea)
            tb.append(eb)
        }
        // Each phase lasts as long as the longer of the two: that one plays at 1×, the other slower.
        var us = [0.0]
        for i in 1..<max(1, ta.count) {
            us.append(us[i - 1] + max(ta[i] - ta[i - 1], tb[i] - tb[i - 1]))
        }
        func warp(_ side: SegmentSide, _ ts: [Double]) -> Warp {
            if let speed = side.speed { return Warp(u: [0], t: [side.start], outside: max(0.05, speed)) }
            return Warp(u: us, t: ts, outside: 1)
        }
        return (warp(a, ta), warp(b, tb))
    }

    /// The clip's speed over the matched stretch as a whole (1 with nothing to match).
    var overall: Double {
        guard u.count > 1, let u0 = u.first, let u1 = u.last, u1 > u0 else { return outside }
        return (t[t.count - 1] - t[0]) / (u1 - u0)
    }
}

// MARK: - A comparison's segments

extension Comparison {
    public var segment: Segment { segments[segmentIndex] }

    /// Writes what the clips show back into the chosen segment (the clips hold it while it's worked on).
    func storeSegment() {
        guard segments.indices.contains(segmentIndex) else { return }
        for (index, clip) in clips.enumerated() {
            segments[segmentIndex].parts[index] = Segment.Part(
                trimStart: clip.trimStart, trimEnd: clip.trimEnd, syncs: clip.syncs, speed: clip.speed,
                drawings: clip.drawings, notes: clip.notes.isEmpty ? nil : clip.notes)
        }
        segments[segmentIndex].placement = Segment.Placement(
            top: overlayTop, offset: overlayOffset, scale: overlayScale, rotation: overlayRotation)
    }

    /// Shows a segment on the clips.
    func loadSegment(_ index: Int) {
        guard segments.indices.contains(index) else { return }
        segmentIndex = index
        let segment = segments[index]
        for (clip, part) in zip(clips, segment.parts) {
            clip.trimStart = part.trimStart
            clip.trimEnd = part.trimEnd
            clip.syncs = part.syncs
            clip.speed = part.speed
            clip.drawings = part.drawings
            clip.notes = part.notes ?? []
        }
        overlayTop = segment.placement.top
        overlayOffset = segment.placement.offset
        overlayScale = segment.placement.scale
        overlayRotation = segment.placement.rotation
    }

    /// Chooses a segment: both clips go to its start.
    public func selectSegment(_ index: Int) {
        guard segments.indices.contains(index), index != segmentIndex else { return }
        let wasLinked = linked
        if wasLinked { pause() } else { clips.forEach { $0.engine.pause() } }
        drawing = nil
        storeSegment()
        loadSegment(index)
        goToStart()
    }

    /// Both clips to the segment's start (lined up, when linked).
    public func goToStart() {
        if linked {
            Task { await seek(to: loopStart) }
        } else {
            for clip in clips where clip.isLoaded {
                Task { await clip.engine.seekToTime(clip.trimStart) }
            }
        }
    }

    /// A new, empty segment after the others, chosen: the whole clips, until In and Out are set.
    public func addSegment(named name: String? = nil) {
        storeSegment()
        var segment = Segment(name: name ?? nextSegmentName)
        // The overlay stays as it is until moved.
        segment.placement = segments[segmentIndex].placement
        segments.append(segment)
        drawing = nil
        loadSegment(segments.count - 1)
    }

    /// A copy of the chosen segment (its In/Out, sync points, speeds and drawings), to vary.
    public func duplicateSegment() {
        storeSegment()
        var copy = segments[segmentIndex]
        copy.id = UUID()
        copy.name += " copy"
        segments.insert(copy, at: segmentIndex + 1)
        loadSegment(segmentIndex + 1)
    }

    public func renameSegment(to name: String) {
        segments[segmentIndex].name = name
    }

    /// Removes the chosen segment (never the last one: that one is emptied instead).
    public func deleteSegment() {
        drawing = nil
        if segments.count == 1 {
            segments = [Segment(name: "Segment 1")]
            loadSegment(0)
        } else {
            segments.remove(at: segmentIndex)
            loadSegment(min(segmentIndex, segments.count - 1))
        }
        goToStart()
    }

    private var nextSegmentName: String {
        var number = segments.count + 1
        while segments.contains(where: { $0.name == "Segment \(number)" }) { number += 1 }
        return "Segment \(number)"
    }

    /// Another video in a clip: its share of every segment starts afresh.
    public func clipReplaced(_ index: Int) {
        for at in segments.indices { segments[at].parts[index] = Segment.Part() }
    }

    /// Everything back to one empty segment (a new comparison).
    public func resetSegments() {
        segments = [Segment(name: "Segment 1")]
        segmentIndex = 0
    }

    // MARK: Speed

    /// The speed a clip plays at over the segment while linked: set by hand, or what matches the other.
    public func speed(of clip: Clip) -> Double {
        clip.speed ?? warp(clip).overall
    }

    // MARK: Overlay drawings

    /// Drawings made in the overlay sit where the two pictures were then: the placement is locked
    /// while there are any, and moving the top clip removes them (after a warning).
    public var overlayDrawings: Int {
        clips.reduce(0) { $0 + $1.drawings.filter { $0.overlay == true }.count }
    }

    public func removeOverlayDrawings() {
        for clip in clips { clip.drawings.removeAll { $0.overlay == true } }
    }
}
