@testable import MimesisKit
import AreteMedia
import CoreGraphics
import CoreImage
import Testing

/// Picking one player in a cutout, and following them from frame to frame.
struct PickTests {
    let side = Cutout.labelSide

    /// A map with `label` filling the given columns, rows 40–100.
    func map(_ blocks: [(label: UInt8, columns: Range<Int>)]) -> [UInt8] {
        var map = [UInt8](repeating: 0, count: side * side)
        for block in blocks {
            for y in 40..<100 { for x in block.columns { map[y * side + x] = block.label } }
        }
        return map
    }

    @Test func tapPicksWhoIsThere() {
        let frame = map([(1, 20..<40), (2, 90..<110)])
        #expect(Cutout.label(near: CGPoint(x: 0.23, y: 0.5), in: frame) == 1)
        #expect(Cutout.label(near: CGPoint(x: 0.78, y: 0.5), in: frame) == 2)
        // Just beside a player still counts; far from anyone doesn't.
        #expect(Cutout.label(near: CGPoint(x: 30.0 / 128, y: 36.0 / 128), in: frame) == 1)
        #expect(Cutout.label(near: CGPoint(x: 0.5, y: 0.05), in: frame) == nil)
    }

    @Test func followsTheSamePlayerWhenVisionRenumbers() {
        let before = map([(1, 20..<40), (2, 90..<110)])
        // Next frame: the left player has moved a little and is now called 2, the right one 1.
        let after = map([(2, 24..<44), (1, 90..<110)])
        #expect(Cutout.follow(1, from: before, into: after) == 2)
        #expect(Cutout.follow(2, from: before, into: after) == 1)
    }

    @Test func aFastMoveFollowsTheNearest() {
        let before = map([(1, 0..<10)])
        let after = map([(1, 30..<40), (2, 110..<120)])
        #expect(Cutout.follow(1, from: before, into: after) == 1)
    }

    @Test func boxCoversThePlayerWithRoomToSwing() throws {
        // A player in columns 20–40, rows 40–100, in a 128 × 128 map; the mask is 256 × 256.
        let frame = map([(1, 20..<40), (2, 90..<110)])
        let image = try #require(Cutout.box(around: 1, labels: frame, width: 256, height: 256, context: CIContext()))
        var pixels = [UInt8](repeating: 0, count: 256 * 256)
        let context = try #require(CGContext(data: &pixels, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        // Drawn into a bitmap, row 0 is the top. The player's middle is solid; a bit beside them still in;
        // the other player and the far corner out.
        func at(_ x: Int, _ y: Int) -> UInt8 { pixels[y * 256 + x] }
        #expect(at(60, 140) > 250)
        #expect(at(36, 140) > 100)
        #expect(at(200, 140) < 5)
        #expect(at(250, 5) < 5)
    }
}
