import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import Vision

/// The player cut out of a clip, frame by frame, for the overlay: a mask per frame from Vision's
/// "lift subject" (which kept the racket in Phase 0's test), made once and kept in memory.
@MainActor @Observable
public final class Cutout {
    public enum State: Equatable {
        case preparing(Double)
        case ready
        case failed(String)
    }

    public private(set) var state: State = .preparing(0)
    /// Draw the clip cut out (true) or whole.
    public var enabled = true
    /// Colour the cut-out player crimson, to tell their body from the one underneath.
    public var tinted = false
    /// The span prepared, in the clip's own seconds; frames outside it show whole.
    public private(set) var span: ClosedRange<Double> = 0...0
    /// True when the trim was longer than a cutout can hold, so only its start was prepared.
    public private(set) var shortened = false

    /// The most frames one cutout keeps (masks are small, but a long clip would still fill memory).
    nonisolated static let frameLimit = 600
    /// Masks are kept this wide; the cutout's edge is softened when scaled up.
    nonisolated static let maskWidth: CGFloat = 360

    private var masks: [Int: CGImage] = [:]
    private var frameRate: Double = 30
    private var task: Task<Void, Never>?
    let url: URL

    init(clip: Clip) {
        url = clip.url ?? URL(fileURLWithPath: "/")
        let fps = Double(clip.engine.fps > 0 ? clip.engine.fps : 30)
        let length = clip.end - clip.trimStart
        let limit = Double(Self.frameLimit) / fps
        shortened = length > limit
        span = clip.trimStart...(clip.trimStart + min(length, limit))
        let (url, start, duration) = (url, span.lowerBound, span.upperBound - span.lowerBound)
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await Cutout.makeMasks(url: url, start: start, duration: duration) { done in
                        Task { @MainActor in
                            if case .preparing = self?.state { self?.state = .preparing(done) }
                        }
                    }
                }.value
                guard let self else { return }
                self.masks = result.masks
                self.frameRate = result.frameRate
                self.state = result.masks.isEmpty ? .failed("Nobody was found to cut out.") : .ready
            } catch is CancellationError {
            } catch {
                #if targetEnvironment(simulator)
                self?.state = .failed("Cutting out needs a real iPhone or iPad (Vision can't run it in Simulator).")
                #else
                self?.state = .failed(error.localizedDescription)
                #endif
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// The mask for the frame at `time` (the clip's own seconds), or the nearest one a frame away.
    func mask(at time: Double) -> CGImage? {
        let index = Int((time * frameRate).rounded())
        return masks[index] ?? masks[index - 1] ?? masks[index + 1]
    }

    // MARK: - Making the masks

    struct Masks: @unchecked Sendable {
        var masks: [Int: CGImage]
        var frameRate: Double
    }

    /// Every frame from `start` for `duration` seconds through lift subject; each mask (all subjects
    /// found, upright as shown, not mirrored) kept `maskWidth` wide, keyed by frame number.
    nonisolated static func makeMasks(
        url: URL, start: Double, duration: Double, progress: @Sendable (Double) -> Void
    ) async throws -> Masks {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MaskProbeError.noVideo
        }
        let (rate, transform) = try await track.load(.nominalFrameRate, .preferredTransform)
        let frameRate = Double(rate > 0 ? rate : 30)
        let orientation = orientation(of: transform)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MaskProbeError.unreadable(reader.error?.localizedDescription ?? "unknown")
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let context = CIContext()
        var masks: [Int: CGImage] = [:]
        while masks.count < frameLimit, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
            try handler.perform([request])
            if let found = request.results?.first, !found.allInstances.isEmpty {
                let full = try found.generateScaledMaskForImage(forInstances: found.allInstances, from: handler)
                var mask = CIImage(cvPixelBuffer: full)
                mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
                let scale = maskWidth / mask.extent.width
                let small = mask.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let rect = CGRect(x: 0, y: 0, width: maskWidth, height: (mask.extent.height * scale).rounded())
                if let image = context.createCGImage(small, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) {
                    masks[Int((time * frameRate).rounded())] = image
                }
            }
            progress(min(1, (time - start) / max(0.001, duration)))
        }
        if reader.status == .failed {
            throw MaskProbeError.unreadable(reader.error?.localizedDescription ?? "unknown")
        }
        return Masks(masks: masks, frameRate: frameRate)
    }

    nonisolated static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// Pulls each frame the player shows from a video output on its item, cuts it out with the
/// prepared mask, and hands back an image with a clear background.
@MainActor
final class CutoutRenderer {
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var orientation: CGImagePropertyOrientation = .up
    private var last: CGImage?
    private var lastKey = ""
    /// The latest frame from the player and its time, kept to draw again when an option changes.
    private var buffer: CVPixelBuffer?
    private var bufferTime: Double = 0
    private let context = CIContext()

    /// The longest side the cutout is drawn at; the view scales it to fit.
    private let maxSide: CGFloat = 1100

    func attach(to item: AVPlayerItem?) {
        guard item !== self.item else { return }
        detach()
        guard let item else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.output = output
        self.item = item
        Task {
            if let track = try? await item.asset.loadTracks(withMediaType: .video).first,
               let transform = try? await track.load(.preferredTransform) {
                orientation = Cutout.orientation(of: transform)
            }
            // A new output gets nothing until the player decodes a frame: while paused, show this one again.
            await item.seek(to: item.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func detach() {
        if let output, let item { item.remove(output) }
        output = nil
        item = nil
        last = nil
        buffer = nil
    }

    /// The frame on screen now, cut out (or whole, without a mask for it).
    func frame(cutout: Cutout, mirrored: Bool) -> CGImage? {
        guard let output, let item else { return last }
        let now = output.itemTime(forHostTime: CACurrentMediaTime())
        var fresh = false
        if output.hasNewPixelBuffer(forItemTime: now) {
            var shown = CMTime.zero
            if let next = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &shown) {
                buffer = next
                bufferTime = shown.seconds
                fresh = true
            }
        }
        // Options that change how the same frame is drawn redraw it.
        let key = "\(cutout.enabled)\(cutout.tinted)\(mirrored)"
        guard fresh || key != lastKey, let buffer else { return last }
        lastKey = key

        var image = CIImage(cvPixelBuffer: buffer)
        // Without a video composition the frames come as encoded; with one (mirroring) they come upright.
        if item.videoComposition == nil { image = image.oriented(orientation) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = CGRect(x: 0, y: 0, width: image.extent.width.rounded(), height: image.extent.height.rounded())

        if cutout.enabled, let maskImage = cutout.mask(at: bufferTime) {
            var mask = CIImage(cgImage: maskImage)
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            if mirrored {
                mask = mask.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
            }
            // A slight blur so the edge doesn't shimmer from frame to frame.
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: extent)
            if cutout.tinted {
                image = image.applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: CIColor(red: 0.925, green: 0.227, blue: 0.333),
                    kCIInputIntensityKey: 0.75,
                ])
            }
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
        }
        last = context.createCGImage(image, from: extent)
        return last
    }
}

/// The top clip in the overlay, cut out, redrawn with every frame the player shows.
struct CutoutLayer: View {
    let clip: Clip
    let cutout: Cutout
    @State private var renderer = CutoutRenderer()

    var body: some View {
        TimelineView(.animation) { _ in
            if let image = renderer.frame(cutout: cutout, mirrored: clip.engine.mirroredHorizontally) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            }
        }
        .onAppear { renderer.attach(to: clip.engine.playerItem) }
        .onChange(of: clip.engine.playerItem) { _, item in renderer.attach(to: item) }
        .onDisappear { renderer.detach() }
    }
}
