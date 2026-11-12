import AreteMedia
import Foundation

/// The last few seconds of frames, oldest first, for watching yourself a few seconds late and for
/// saving what you just watched. Frames older than `keep` seconds are dropped as new ones arrive.
struct DelayBuffer<Frame> {
    struct Entry {
        let time: Double
        let frame: Frame
    }

    /// Seconds of frames kept.
    var keep: Double
    private(set) var entries: [Entry] = []

    init(keep: Double) {
        self.keep = keep
    }

    mutating func append(_ frame: Frame, at time: Double) {
        entries.append(Entry(time: time, frame: frame))
        let cutoff = time - keep
        if let first = entries.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            entries.removeFirst(first)
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// The frame that was live `delay` seconds before `now`: the newest one no later than that,
    /// or nil while the buffer hasn't yet filled that far back.
    func frame(delayed delay: Double, now: Double) -> Frame? {
        let target = now - delay
        guard let first = entries.first, first.time <= target else { return nil }
        // Newest at the end: search backwards, usually only a step or two.
        return entries.last { $0.time <= target }?.frame
    }

    /// The frames from `seconds` before `end` up to `end`, oldest first.
    func span(_ seconds: Double, endingAt end: Double) -> [Entry] {
        entries.filter { $0.time > end - seconds && $0.time <= end }
    }

    /// How many seconds back the buffer reaches from `now`.
    func reach(now: Double) -> Double {
        entries.first.map { now - $0.time } ?? 0
    }
}
