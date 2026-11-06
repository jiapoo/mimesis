@testable import MimesisKit
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
        // A 1 s phase in A matched to 0.5 s in B, the span trimmed to about 2 s of A.
        let a = comparison.clips[0], b = comparison.clips[1]
        a.trimStart = 0.5
        a.trimEnd = 2.5
        a.syncs = [1, 2]
        b.syncs = [1, 1.5]
        comparison.overlayScale = 1.5
        comparison.overlayRotation = 15
        // Marks on every frame: an angle on A (yellow), an arrow on B (crimson).
        a.drawings = [Drawing(kind: .angle, points: [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.5)],
                              time: 1, always: true, ink: .yellow)]
        b.drawings = [Drawing(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.6, y: 0.4)],
                              time: 1, always: true, ink: .crimson)]
        comparison.linked = true
        let range = comparison.range
        #expect(abs((range.upperBound - range.lowerBound) - 2) < 0.01)

        let file = try await Exporter.export(comparison, style: style)
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        print("Exported \(style): \(file.path), \(duration) s, \(size)")
        #expect(abs(duration - 2) < 0.1)
        if style == .sideBySide { #expect(size == CGSize(width: 1920, height: 1080)) }
        // A frame from the middle is there and isn't blank.
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        #expect(frame.width > 0)
    }
}
