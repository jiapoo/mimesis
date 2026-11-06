import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// The two ways Apple's Vision can cut a player out of a frame. Phase 0 tests which keeps the racket.
public enum MaskMethod: String, CaseIterable, Sendable, Identifiable {
    /// `VNGeneratePersonInstanceMaskRequest`: people only, each one separately.
    case person
    /// `VNGenerateForegroundInstanceMaskRequest`: "lift subject", which may keep what a person holds.
    case foreground

    public var id: Self { self }

    public var title: String {
        switch self {
        case .person: "Person mask"
        case .foreground: "Lift subject"
        }
    }
}

/// One tested frame at preview size: the frame, and each method's mask (white is kept).
/// A method with no mask found nothing in that frame.
public struct ProbeFrame: @unchecked Sendable {
    public let time: Double
    public let image: CGImage
    public let masks: [MaskMethod: CGImage]
    public let instances: [MaskMethod: Int]
}

/// What a run found: the frames, and how long each method took over all of them.
public struct ProbeReport: @unchecked Sendable {
    public var frames: [ProbeFrame] = []
    /// Seconds spent in Vision for each method, mask included, over all frames.
    public var seconds: [MaskMethod: Double] = [:]
    /// The video's frame size, as shown (rotation applied).
    public var size: CGSize = .zero
    public var frameRate: Double = 0

    public func millisecondsPerFrame(_ method: MaskMethod) -> Double {
        frames.isEmpty ? 0 : (seconds[method] ?? 0) * 1000 / Double(frames.count)
    }

    /// How many frames each method found nobody in.
    public func emptyFrames(_ method: MaskMethod) -> Int {
        frames.filter { $0.masks[method] == nil }.count
    }
}

public enum MaskProbeError: LocalizedError {
    case noVideo
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noVideo: "That file has no video in it."
        case .unreadable(let why): "The video couldn't be read: \(why)"
        }
    }
}

public enum MaskProbe {
    /// The most frames one run keeps, so a long span can't fill memory.
    public static let frameLimit = 150

    /// Runs both methods over every frame from `start` for `duration` seconds, at full resolution.
    /// Keeps the frames and masks at `previewWidth` for showing.
    public static func run(
        url: URL,
        start: Double,
        duration: Double,
        previewWidth: CGFloat = 960,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> ProbeReport {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MaskProbeError.noVideo
        }
        let (frameRate, transform, naturalSize) = try await track.load(
            .nominalFrameRate, .preferredTransform, .naturalSize)
        let orientation = Self.orientation(of: transform)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MaskProbeError.unreadable(reader.error?.localizedDescription ?? "unknown")
        }

        let rotated = orientation == .left || orientation == .right
        let shownSize = rotated
            ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize
        let scale = min(1, previewWidth / shownSize.width)
        let previewRect = CGRect(
            x: 0, y: 0,
            width: (shownSize.width * scale).rounded(), height: (shownSize.height * scale).rounded())

        var report = ProbeReport(size: shownSize, frameRate: Double(frameRate))
        // Made once, so each model loads once, as it would in the app.
        let requests: [MaskMethod: VNImageBasedRequest] = [
            .person: VNGeneratePersonInstanceMaskRequest(),
            .foreground: VNGenerateForegroundInstanceMaskRequest(),
        ]

        while report.frames.count < frameLimit, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)

            var masks: [MaskMethod: CGImage] = [:]
            var instances: [MaskMethod: Int] = [:]
            for method in MaskMethod.allCases {
                guard let request = requests[method] else { continue }
                let clock = ContinuousClock()
                let began = clock.now
                try handler.perform([request])
                var mask: CVPixelBuffer?
                if let found = request.results?.first as? VNInstanceMaskObservation,
                   !found.allInstances.isEmpty {
                    instances[method] = found.allInstances.count
                    mask = try found.generateScaledMaskForImage(
                        forInstances: found.allInstances, from: handler)
                }
                report.seconds[method, default: 0] += (clock.now - began).seconds
                if let mask {
                    masks[method] = render(
                        normalized(CIImage(cvPixelBuffer: mask)), scale: scale, in: previewRect, gray: true)
                }
            }

            let frame = normalized(CIImage(cvPixelBuffer: buffer).oriented(orientation))
            guard let image = render(frame, scale: scale, in: previewRect, gray: false) else { continue }
            report.frames.append(ProbeFrame(time: time, image: image, masks: masks, instances: instances))
            progress(min(1, (time - start) / duration))
        }
        if reader.status == .failed {
            throw MaskProbeError.unreadable(reader.error?.localizedDescription ?? "unknown")
        }
        return report
    }

    // MARK: - Showing the results

    /// The frame cut out by `method` over a checkerboard, or the frame itself for `nil`.
    public static func cutout(_ frame: ProbeFrame, _ method: MaskMethod?) -> CGImage? {
        let image = CIImage(cgImage: frame.image)
        guard let method else { return frame.image }
        let extent = image.extent
        let board = checkerboard.cropped(to: extent)
        guard let mask = frame.masks[method] else { return context.createCGImage(board, from: extent) }
        let cut = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: board,
            kCIInputMaskImageKey: CIImage(cgImage: mask),
        ])
        return context.createCGImage(cut, from: extent)
    }

    /// Up to `rows` frames spread over the run, each as frame | person mask | lift subject.
    public static func contactSheet(_ report: ProbeReport, rows: Int = 6) -> CGImage? {
        guard let first = report.frames.first else { return nil }
        let count = min(rows, report.frames.count)
        let picks = (0..<count).map { report.frames[$0 * (report.frames.count - 1) / max(1, count - 1)] }
        let cell = CGSize(width: first.image.width, height: first.image.height)
        let columns: [MaskMethod?] = [nil] + MaskMethod.allCases
        let gap: CGFloat = 8
        let size = CGSize(
            width: CGFloat(columns.count) * cell.width + CGFloat(columns.count - 1) * gap,
            height: CGFloat(count) * cell.height + CGFloat(count - 1) * gap)
        var sheet = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        for (row, frame) in picks.enumerated() {
            for (column, method) in columns.enumerated() {
                guard let image = cutout(frame, method) else { continue }
                let x = CGFloat(column) * (cell.width + gap)
                // Core Image counts up from the bottom; the first frame goes on top.
                let y = CGFloat(count - 1 - row) * (cell.height + gap)
                sheet = CIImage(cgImage: image)
                    .transformed(by: CGAffineTransform(translationX: x, y: y))
                    .composited(over: sheet)
            }
        }
        return context.createCGImage(sheet, from: sheet.extent)
    }

    /// PNG data for an image, to save or share.
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A summary line for each method, e.g. "Person mask: 23 ms a frame, nobody found in 2 of 120".
    public static func summary(_ report: ProbeReport) -> [String] {
        MaskMethod.allCases.map { method in
            let ms = report.millisecondsPerFrame(method).formatted(.number.precision(.fractionLength(0)))
            let most = report.frames.compactMap { $0.instances[method] }.max() ?? 0
            return "\(method.title): \(ms) ms a frame, nobody found in "
                + "\(report.emptyFrames(method)) of \(report.frames.count), up to \(most) found in a frame"
        }
    }

    // MARK: - Private

    // One shared context, so its caches are shared too.
    private static let context = CIContext()

    private static let checkerboard: CIImage = {
        let board = CIFilter.checkerboardGenerator()
        board.color0 = CIColor(red: 0.8, green: 0.8, blue: 0.8)
        board.color1 = CIColor(red: 0.95, green: 0.95, blue: 0.95)
        board.width = 12
        return board.outputImage ?? CIImage(color: .gray)
    }()

    private static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func render(_ image: CIImage, scale: CGFloat, in rect: CGRect, gray: Bool) -> CGImage? {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if gray {
            return context.createCGImage(
                scaled, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return context.createCGImage(scaled, from: rect)
    }

    /// The way a video's track transform turns it, as Vision and Core Image name it.
    private static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

private extension Duration {
    var seconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
