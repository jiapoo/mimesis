@testable import MimesisKit
import AVFoundation
import CoreImage
import Testing

/// Saving the seconds just watched in court mode writes a clip that plays back at the right length.
struct CourtClipTests {
    @Test func savedFramesBecomeAClip() async throws {
        let context = CIContext()
        var entries: [DelayBuffer<CVPixelBuffer>.Entry] = []
        // 3 s at 30 frames a second, 854 × 480, each frame a different grey.
        for i in 0..<90 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 854, 480, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
            let frame = try #require(buffer)
            let grey = CGFloat(i) / 90
            context.render(CIImage(color: CIColor(red: grey, green: grey, blue: grey)).cropped(to: CGRect(x: 0, y: 0, width: 854, height: 480)),
                           to: frame)
            entries.append(.init(time: 100 + Double(i) / 30, frame: frame))
        }
        let file = try await CourtCamera.write(entries)
        defer { try? FileManager.default.removeItem(at: file) }
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(duration - 3) < 0.1)
        #expect(size == CGSize(width: 854, height: 480))
    }
}
