@testable import MimesisKit
import AreteMedia
import Testing

/// The window shown around each tagged moment in a reel.
@MainActor
struct ReelTests {
    @Test func windowAroundATag() {
        #expect(Reel.window(around: 5, duration: 12) == 3.5...6.5)
        // Kept inside the clip at both ends.
        #expect(Reel.window(around: 0.4, duration: 12) == 0...1.9)
        #expect(Reel.window(around: 11.5, duration: 12) == 10...12)
    }
}
