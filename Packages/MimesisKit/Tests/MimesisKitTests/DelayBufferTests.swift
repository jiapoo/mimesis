@testable import MimesisKit
import Testing

/// Watching a few seconds late, and saving what was just watched.
struct DelayBufferTests {
    /// 30 frames a second from 0 to `until`, each frame its own number.
    func filled(keep: Double, until: Double) -> DelayBuffer<Int> {
        var buffer = DelayBuffer<Int>(keep: keep)
        for i in 0...Int(until * 30) { buffer.append(i, at: Double(i) / 30) }
        return buffer
    }

    @Test func showsTheFrameFromDelaySecondsAgo() {
        let buffer = filled(keep: 12, until: 20)
        // At 20 s with a 5 s delay: the frame from 15 s, number 450.
        #expect(buffer.frame(delayed: 5, now: 20) == 450)
        #expect(buffer.frame(delayed: 0, now: 20) == 600)
    }

    @Test func nothingUntilTheDelayHasPassed() {
        let buffer = filled(keep: 12, until: 2)
        #expect(buffer.frame(delayed: 5, now: 2) == nil)
        #expect(buffer.frame(delayed: 1, now: 2) == 30)
    }

    @Test func dropsFramesOlderThanItKeeps() {
        let buffer = filled(keep: 12, until: 20)
        #expect(buffer.reach(now: 20) <= 12.01)
        #expect(buffer.entries.count == 361)
        // Asking further back than it keeps finds nothing.
        #expect(buffer.frame(delayed: 15, now: 20) == nil)
    }

    @Test func savesTheSecondsJustWatched() {
        let buffer = filled(keep: 12, until: 20)
        // Watching 5 s late, "the last 6 s" are 9–15 s.
        let span = buffer.span(6, endingAt: 20 - 5)
        #expect(span.first?.frame == 271)
        #expect(span.last?.frame == 450)
        #expect(span.count == 180)
    }
}
