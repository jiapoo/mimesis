@testable import MimesisKit
import AreteMedia
import AVFoundation
import Foundation
import Testing

/// Exporting a linked comparison of two real clips (opt-in: set MIMESIS_CLIP_A and MIMESIS_CLIP_B).
@MainActor
struct ExportClipTests {
    nonisolated static let paths = (ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"],
                        ProcessInfo.processInfo.environment["MIMESIS_CLIP_B"])

    @Test(.enabled(if: paths.0 != nil && paths.1 != nil), arguments: [Exporter.Style.sideBySide, .overlay])
    func exportsTheLinkedSpan(style: Exporter.Style) async throws {
        let comparison = Comparison()
        await comparison.clips[0].open(URL(fileURLWithPath: Self.paths.0!))
        await comparison.clips[1].open(URL(fileURLWithPath: Self.paths.1!))
        // A from 0.5 to 2.5 s with sync points at 1 and 2; B from its start with sync points at 1 and 1.5.
        // Phases: A 0.5 s against B 1 s (1 s on screen), then A 1 s against B 0.5 s (1 s); after that A has
        // 0.5 s left and B the rest of its video: the span runs as long as the longer one (B), and A
        // waits on its last frame.
        let a = comparison.clips[0], b = comparison.clips[1]
        a.trimStart = 0.5
        a.trimEnd = 2.5
        a.syncs = [1, 2]
        b.syncs = [1, 1.5]
        comparison.overlayScale = 1.5
        comparison.overlayRotation = 15
        // Marks on every frame: an angle on A (yellow), an arrow on B (crimson).
        a.drawings = [Drawing(kind: .angle, points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.5)],
                              time: 1, always: true, color: Palette.yellow, width: 3, brush: .pen),
                      Drawing(kind: .freehand, points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.25), CGPoint(x: 0.4, y: 0.2)],
                              time: 1, always: true, color: Palette.cyan, width: 20, brush: .marker)]
        b.drawings = [Drawing(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.6, y: 0.4)],
                              time: 1, always: true, color: Palette.crimson, width: 5, brush: .pen)]
        comparison.linked = true
        let range = comparison.range
        let length = 2 + (b.engine.duration - 1.5)
        #expect(abs((range.upperBound - range.lowerBound) - length) < 0.01)
        // A never goes past its Out.
        #expect(abs(comparison.clipTime(a, at: range.upperBound) - 2.5) < 0.001)

        let file = try await Exporter.export(comparison, style: style)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        print("Exported \(style): \(file.path), \(duration) s, \(size)")
        #expect(abs(duration - length) < 0.1)
        if style == .sideBySide { #expect(size == CGSize(width: 1920, height: 1080)) }
        // A frame from the middle is there and isn't blank.
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(frame.width > 0)
    }
}
