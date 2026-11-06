@testable import MimesisKit
import AVFoundation
import CoreImage
import Foundation
import Testing

/// Lining up two pictures of the same place (opt-in: set MIMESIS_CLIP_A to a clip; its first frame is used).
struct BackgroundMatchTests {
    static let clip = ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"]

    @Test(.enabled(if: clip != nil)) func findsAKnownZoomAndShift() async throws {
        let base = try await Comparison.frameImage(URL(fileURLWithPath: Self.clip!), at: 0, mirrored: false)
        let extent = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        // The top picture: the same scene zoomed in 1.15× and moved (+25, −10), as if filmed a bit closer.
        let moved = CIImage(cgImage: base).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y)
                .concatenating(CGAffineTransform(scaleX: 1.15, y: 1.15))
                .concatenating(CGAffineTransform(translationX: centre.x + 25, y: centre.y - 10)))
            .cropped(to: extent)
        let top = try #require(CIContext().createCGImage(moved, from: extent))

        let match = try Comparison.matchBackgrounds(base: base, top: top)
        print("match", match)
        // Undoing it: resize by 1 / 1.15 and move back by (−25, +10) / 1.15.
        #expect(abs(match.scale - 1 / 1.15) < 0.025)
        #expect(abs(match.shift.x - (-25 / 1.15)) < 4)
        #expect(abs(match.shift.y - (10 / 1.15)) < 4)
    }

    static let other = ProcessInfo.processInfo.environment["MIMESIS_CLIP_B"]

    @Test(.enabled(if: clip != nil && other != nil)) func twoDifferentPlacesDontMatch() async throws {
        let base = try await Comparison.frameImage(URL(fileURLWithPath: Self.clip!), at: 0, mirrored: false)
        let top = try await Comparison.frameImage(URL(fileURLWithPath: Self.other!), at: 0, mirrored: false)
        #expect(throws: BackgroundError.self) { try Comparison.matchBackgrounds(base: base, top: top) }
    }
}
