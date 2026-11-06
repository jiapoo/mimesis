@testable import MimesisKit
import CoreGraphics
import CoreImage
import Foundation
import Testing

/// On a real clip with two players (opt-in: set MIMESIS_TWO_PLAYER_CLIP to its path): picking the left
/// one and following them keeps nothing of the right one.
struct PickClipTests {
    static let clip = ProcessInfo.processInfo.environment["MIMESIS_TWO_PLAYER_CLIP"]

    @Test(.enabled(if: clip != nil)) func pickingTheLeftPlayerDropsTheRightOne() async throws {
        let url = URL(fileURLWithPath: Self.clip!)
        let made = try await Cutout.makeMasks(url: url, start: 5, duration: 1) { _ in }
        let frames = made.labels.keys.sorted()
        // A frame with both players; tap the left one's centre.
        let seed = try #require(frames.first { Set(made.labels[$0]!).subtracting([0]).count > 1 })
        let map = made.labels[seed]!
        let centres = Set(map).subtracting([0]).compactMap { label in Cutout.centre(of: label, in: map).map { (label, $0) } }
        let left = try #require(centres.min { $0.1.x < $1.1.x })
        let side = CGFloat(Cutout.labelSide)
        let picked = try #require(Cutout.label(near: CGPoint(x: left.1.x / side, y: left.1.y / side), in: map))

        // Before picking, the right player is there.
        #expect(brightness(made.masks[seed]!, rightOf: 0.7) > 0.001)

        var label = picked, previous = map, checked = 0
        let context = CIContext()
        for frame in frames.drop(while: { $0 < seed }) {
            let labels = made.labels[frame]!
            if frame != seed { label = try #require(Cutout.follow(label, from: previous, into: labels)) }
            previous = labels
            let all = made.masks[frame]!
            let only = try #require(Cutout.only(label, in: all, labels: labels, context: context))
            #expect(brightness(only, rightOf: 0.7) < 0.001, "frame \(frame): something kept on the right")
            #expect(brightness(only, rightOf: 0) > 0.001, "frame \(frame): the left player was lost")
            checked += 1
        }
        #expect(checked > 10)
    }

    /// The mean of a grey mask's pixels to the right of `fraction` of its width (0–1).
    func brightness(_ image: CGImage, rightOf fraction: CGFloat) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let from = Int(CGFloat(width) * fraction)
        var sum = 0
        for y in 0..<height { for x in from..<width { sum += Int(pixels[y * width + x]) } }
        return Double(sum) / Double(max(1, (width - from) * height) * 255)
    }
}
