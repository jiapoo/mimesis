@testable import MimesisKit
import CoreGraphics
import Foundation
import Testing

/// A StroMotion image of a real serve (opt-in: set MIMESIS_CLIP_A; MIMESIS_OUT to keep the image).
struct StroMotionClipTests {
    static let clip = ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"]

    @Test(.enabled(if: clip != nil)) func makesOneImageOfTheMotion() async throws {
        let url = URL(fileURLWithPath: Self.clip!)
        let made = try await Cutout.makeMasks(url: url, start: 1.5, duration: 1.5) { _ in }
        let times = StroMotion.times(in: 1.5...2.95, count: 6)
        #expect(times.count == 6 && times.first == 1.5 && abs(times.last! - 2.95) < 1e-9)
        let masks = times.map { t in made.masks[Int((t * made.frameRate).rounded())] }
        #expect(masks.allSatisfy { $0 != nil })
        let image = try await StroMotion.make(url: url, times: times, masks: masks, mirrored: false)
        #expect(image.width > 0)
        if let out = ProcessInfo.processInfo.environment["MIMESIS_OUT"] {
            try MaskProbe.png(image)?.write(to: URL(fileURLWithPath: out))
        }
    }
}
