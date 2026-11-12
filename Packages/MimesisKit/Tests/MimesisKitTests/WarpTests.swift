@testable import MimesisKit
import AreteMedia
import Testing

/// Clip B's time against linked time, through paired sync points.
struct WarpTests {
    // Sync points at linked 0, 1, 3 s and B's 10, 12, 13 s: B's first phase runs at 2×, its second at 0.5×.
    let warp = Warp(u: [0, 1, 3], t: [10, 12, 13], outside: 1)

    @Test func timeBetweenSyncPoints() {
        #expect(warp.time(at: 0) == 10)
        #expect(warp.time(at: 0.5) == 11)
        #expect(warp.time(at: 1) == 12)
        #expect(warp.time(at: 2) == 12.5)
        #expect(warp.time(at: 3) == 13)
    }

    @Test func timeOutsideRunsAtTheClipsOwnSpeed() {
        #expect(warp.time(at: -1) == 9)
        #expect(warp.time(at: 4) == 14)
        let slow = Warp(u: [0], t: [5], outside: 0.5)
        #expect(slow.time(at: 2) == 6)
        #expect(slow.time(at: -2) == 4)
    }

    @Test func linkedTimeIsTheInverse() {
        for u in stride(from: -2.0, through: 5, by: 0.25) {
            #expect(abs(warp.u(at: warp.time(at: u)) - u) < 1e-9)
        }
    }

    @Test func speedInEachPhase() {
        #expect(warp.slope(at: 0.5) == 2)
        #expect(warp.slope(at: 2) == 0.5)
        #expect(warp.slope(at: -1) == 1)
        #expect(warp.slope(at: 3) == 1)
    }
}
