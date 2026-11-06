@testable import MimesisKit
import CoreGraphics
import Foundation
import Testing

/// A cutout saved to disk comes back the same.
struct CutoutFileTests {
    @Test func savedCutoutLoadsBackTheSame() throws {
        let width = 36, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 10..<50 { for x in 5..<20 { pixels[y * width + x] = 255 } }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let mask = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        var labels = [UInt8](repeating: 0, count: Cutout.labelSide * Cutout.labelSide)
        for i in 1000..<3000 { labels[i] = 2 }

        let made = Cutout.Masks(masks: [12: mask, 13: mask], labels: [12: labels, 13: labels], frameRate: 60)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).cutout")
        defer { try? FileManager.default.removeItem(at: file) }
        Cutout.save(made, to: file)
        let back = try #require(Cutout.load(file))

        #expect(back.frameRate == 60)
        #expect(Set(back.masks.keys) == [12, 13])
        #expect(back.labels[13] == labels)
        let image = try #require(back.masks[12])
        #expect(image.width == width && image.height == height)
        var read = [UInt8](repeating: 0, count: width * height)
        let context = try #require(CGContext(data: &read, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        #expect(read == pixels)
    }

    @Test func aChangedSpanIsADifferentFile() {
        let url = URL(fileURLWithPath: "/tmp/clip.mov")
        #expect(Cutout.cacheFile(for: url, start: 0, duration: 2) == Cutout.cacheFile(for: url, start: 0, duration: 2))
        #expect(Cutout.cacheFile(for: url, start: 0, duration: 2) != Cutout.cacheFile(for: url, start: 1, duration: 2))
    }
}
