@testable import MimesisKit
import Foundation
import Testing

/// How the two clips of a segment play together, and keeping several segments apart.
@MainActor
struct SegmentTests {
    @Test func theShorterStretchIsSlowedToLastAsLongAsTheLonger() {
        // A: 2.0 to 3.2 (1.2 s). B: 5.0 to 6.0 (1.0 s).
        let pair = Warp.pair(SegmentSide(start: 2, end: 3.2), SegmentSide(start: 5, end: 6))
        #expect(abs(pair.a.overall - 1) < 1e-9)
        #expect(abs(pair.b.overall - 1 / 1.2) < 1e-9)
        // Both start together and end together.
        #expect(pair.a.time(at: 0) == 2 && pair.b.time(at: 0) == 5)
        #expect(abs(pair.a.time(at: 1.2) - 3.2) < 1e-9 && abs(pair.b.time(at: 1.2) - 6) < 1e-9)
    }

    @Test func withoutAnEndOnBothTheClipsPlayAtTheirOwnPace() {
        let pair = Warp.pair(SegmentSide(start: 2, end: 3.2), SegmentSide(start: 5, end: nil))
        #expect(pair.a.overall == 1 && pair.b.overall == 1)
        #expect(pair.b.time(at: 1) == 6)
    }

    @Test func syncPointsSplitTheSegmentIntoPhasesMatchedOneByOne() {
        // To contact: A takes 1.0 s, B 0.5 s. After it: A 0.5 s, B 1.0 s.
        let pair = Warp.pair(SegmentSide(start: 0, end: 1.5, keys: [1]), SegmentSide(start: 10, end: 11.5, keys: [10.5]))
        // Contact at the same moment, 1 s in; the end at 2 s.
        #expect(pair.a.time(at: 1) == 1 && pair.b.time(at: 1) == 10.5)
        #expect(pair.a.time(at: 2) == 1.5 && pair.b.time(at: 2) == 11.5)
        // Nobody is ever sped up: the longer phase plays at 1×, the other at half speed.
        #expect(pair.a.slope(at: 0.5) == 1 && pair.b.slope(at: 0.5) == 0.5)
        #expect(pair.a.slope(at: 1.5) == 0.5 && pair.b.slope(at: 1.5) == 1)
    }

    @Test func aSpeedSetByHandReplacesTheMatching() {
        let pair = Warp.pair(SegmentSide(start: 2, end: 3.2), SegmentSide(start: 5, end: 6, speed: 1))
        #expect(pair.b.overall == 1)
        #expect(pair.b.time(at: 1) == 6)
        #expect(pair.a.overall == 1)
    }

    @Test func eachSegmentKeepsItsOwnEdits() {
        let comparison = Comparison()
        let a = comparison.clips[0], b = comparison.clips[1]
        a.trimStart = 1
        a.trimEnd = 2
        b.syncs = [0.5]
        comparison.overlayRotation = 12

        comparison.addSegment()
        #expect(comparison.segments.count == 2 && comparison.segmentIndex == 1)
        // A new segment starts with the whole clips, the overlay where it was.
        #expect(a.trimStart == 0 && a.trimEnd == nil && b.syncs.isEmpty)
        #expect(comparison.overlayRotation == 12)
        a.trimStart = 3
        b.speed = 0.7
        comparison.renameSegment(to: "Serve")

        comparison.selectSegment(0)
        #expect(a.trimStart == 1 && a.trimEnd == 2 && b.syncs == [0.5] && b.speed == nil)
        comparison.selectSegment(1)
        #expect(a.trimStart == 3 && b.speed == 0.7 && comparison.segment.name == "Serve")

        // Undo takes back an edit in the chosen segment, and only that.
        let history = comparison.history
        history.record(comparison)
        a.trimStart = 4
        history.record(comparison)
        history.undo(comparison)
        #expect(a.trimStart == 3 && comparison.segmentIndex == 1)

        comparison.deleteSegment()
        #expect(comparison.segments.count == 1 && a.trimStart == 1)
    }

    @Test func drawingsMadeInTheOverlayAreKeptApartAndRemovedTogether() {
        let comparison = Comparison()
        let a = comparison.clips[0]
        var over = Drawing(kind: .line, points: [.zero, CGPoint(x: 1, y: 1)], time: 0, always: true,
                           color: Palette.crimson, width: 3, brush: .pen)
        over.overlay = true
        let own = Drawing(kind: .line, points: [.zero, CGPoint(x: 1, y: 1)], time: 0, always: true,
                          color: Palette.crimson, width: 3, brush: .pen)
        a.drawings = [own, over]
        #expect(comparison.overlayDrawings == 1)
        #expect(a.visibleDrawings(overlay: false).map(\.id) == [own.id])
        #expect(a.visibleDrawings(overlay: true).map(\.id) == [over.id])
        comparison.removeOverlayDrawings()
        #expect(a.drawings.map(\.id) == [own.id])
    }

    @Test func swappingAAndBTakesEachVideosEditsWithIt() {
        let comparison = Comparison()
        let first = comparison.clips[0], second = comparison.clips[1]
        first.trimStart = 1
        second.syncs = [0.5]
        comparison.addSegment()
        first.trimStart = 3
        comparison.focus = 0
        comparison.overlayTop = 1

        comparison.swapClips()
        #expect(comparison.clips[1] === first && comparison.clips[0] === second)
        // In the chosen segment, and in the other one.
        #expect(comparison.clips[1].trimStart == 3)
        #expect(comparison.focus == 1 && comparison.overlayTop == 0)
        comparison.selectSegment(0)
        #expect(comparison.clips[1].trimStart == 1 && comparison.clips[0].syncs == [0.5])
    }
}
