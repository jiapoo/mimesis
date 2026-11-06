import AVFoundation
import CoreImage
import SwiftUI

/// Turns the linked comparison into a video file: both clips side by side, or the overlay.
/// Each output frame shows exactly the frames of A and B the linked timeline puts together.
@MainActor @Observable
final class Exporter {
    enum Style: String, CaseIterable, Identifiable {
        case sideBySide, overlay
        var id: Self { self }
        var title: String { self == .sideBySide ? "Side by side" : "Overlay" }
    }

    private(set) var progress: Double?
    private(set) var file: URL?
    private(set) var problem: String?
    private var task: Task<Void, Never>?

    nonisolated static let frameRate = 30.0

    func start(_ comparison: Comparison, style: Style) {
        guard comparison.canLink, let plan = Plan(comparison, style: style) else {
            problem = "Open both clips first."
            return
        }
        file = nil
        problem = nil
        progress = 0
        task = Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try await plan.render { done in Task { @MainActor in self.progress = done } }
                }.value
                file = out
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
            progress = nil
        }
    }

    func cancel() {
        task?.cancel()
        progress = nil
    }

    /// Renders straight to a file (for tests).
    static func export(_ comparison: Comparison, style: Style) async throws -> URL {
        guard let plan = Plan(comparison, style: style) else { throw CocoaError(.featureUnsupported) }
        return try await Task.detached { try await plan.render { _ in } }.value
    }
}

/// Everything rendering needs, gathered on the main actor, then used off it.
private struct Plan: @unchecked Sendable {
    struct Side {
        let url: URL
        let times: [Double]
        let mirrored: Bool
        let size: CGSize
    }

    let style: Exporter.Style
    let a: Side
    let b: Side
    // The overlay: which side is on top, how it sits, and its cut-out masks (one per output frame).
    let topIsA: Bool
    let opacity: Double
    let offset: CGSize
    let scale: CGFloat
    let masks: [CGImage?]
    let tinted: Bool
    let name: String

    @MainActor init?(_ comparison: Comparison, style: Exporter.Style) {
        let range = comparison.range
        let speed = max(0.05, comparison.linkedSpeed)
        // Output seconds play `speed` seconds of the linked timeline each.
        let count = Int(((range.upperBound - range.lowerBound) / speed * Exporter.frameRate).rounded(.down))
        guard count > 1 else { return nil }
        let us = (0..<count).map { range.lowerBound + Double($0) / Exporter.frameRate * speed }
        func side(_ clip: Clip) -> Side? {
            guard let url = clip.url else { return nil }
            return Side(url: url, times: us.map { comparison.clipTime(clip, at: $0) },
                        mirrored: clip.engine.mirroredHorizontally, size: clip.engine.videoSize)
        }
        guard let a = side(comparison.clips[0]), let b = side(comparison.clips[1]) else { return nil }
        self.style = style
        self.a = a
        self.b = b
        topIsA = comparison.overlayTop == 0
        opacity = comparison.overlayOpacity
        offset = comparison.overlayOffset
        scale = comparison.overlayScale
        let top = comparison.clips[comparison.overlayTop]
        let topTimes = topIsA ? a.times : b.times
        if style == .overlay, let cutout = top.cutout, cutout.state == .ready, cutout.enabled {
            masks = topTimes.map { cutout.mask(at: $0) }
            tinted = cutout.tinted
        } else {
            masks = []
            tinted = false
        }
        name = comparison.clips.compactMap(\.url).map { $0.deletingPathExtension().lastPathComponent }
            .joined(separator: " vs ")
    }

    func render(progress: @Sendable (Double) -> Void) async throws -> URL {
        let size = outputSize()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name) \(style == .overlay ? "overlay" : "side by side").mp4")
        try? FileManager.default.removeItem(at: file)

        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let generatorA = Self.generator(a.url), generatorB = Self.generator(b.url)
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let count = a.times.count
        for index in 0..<count {
            try Task.checkCancellation()
            let frameA = try await Self.frame(generatorA, at: a.times[index], mirrored: a.mirrored)
            let frameB = try await Self.frame(generatorB, at: b.times[index], mirrored: b.mirrored)
            let image = style == .sideBySide
                ? sideBySide(frameA, frameB, in: size)
                : overlay(frameA, frameB, index: index, in: size)

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: space)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(Exporter.frameRate)))
            progress(Double(index + 1) / Double(count))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return file
    }

    // MARK: - Laying out a frame (Core Image counts up from the bottom)

    private func outputSize() -> CGSize {
        if style == .sideBySide { return CGSize(width: 1920, height: 1080) }
        // The overlay is the picture underneath, its long side 1920, even sizes for the encoder.
        let base = topIsA ? b.size : a.size
        let long = max(base.width, base.height)
        guard long > 0 else { return CGSize(width: 1080, height: 1920) }
        let fit = 1920 / long
        return CGSize(width: (base.width * fit / 2).rounded() * 2, height: (base.height * fit / 2).rounded() * 2)
    }

    private func sideBySide(_ left: CIImage, _ right: CIImage, in size: CGSize) -> CIImage {
        let half = CGSize(width: size.width / 2, height: size.height)
        let l = Self.fit(left, in: CGRect(origin: .zero, size: half))
        let r = Self.fit(right, in: CGRect(x: half.width, y: 0, width: half.width, height: half.height))
        return r.composited(over: l).composited(over: Self.black(size))
    }

    private func overlay(_ frameA: CIImage, _ frameB: CIImage, index: Int, in size: CGSize) -> CIImage {
        let base = topIsA ? frameB : frameA
        var top = topIsA ? frameA : frameB
        let canvas = CGRect(origin: .zero, size: size)
        let under = Self.fit(base, in: canvas)

        // The cutout, then the tint, as on screen.
        if masks.indices.contains(index), let maskImage = masks[index] {
            var mask = CIImage(cgImage: maskImage)
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: top.extent.width / mask.extent.width, y: top.extent.height / mask.extent.height))
            if (topIsA ? a.mirrored : b.mirrored) {
                mask = mask.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -top.extent.width, y: 0))
            }
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: top.extent)
            if tinted {
                top = top.applyingFilter("CIColorMonochrome", parameters: [
                    kCIInputColorKey: CIColor(red: 0.925, green: 0.227, blue: 0.333), kCIInputIntensityKey: 0.75,
                ])
            }
            top = top.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
        }
        // Fitted into the picture underneath, then resized about its centre and moved, as in the overlay.
        var placed = Self.fit(top, in: canvas)
        let centre = CGPoint(x: canvas.midX, y: canvas.midY)
        placed = placed.transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: centre.x + offset.width * size.width,
                                             y: centre.y - offset.height * size.height)))
        placed = placed.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
        ])
        return placed.composited(over: under).cropped(to: canvas).composited(over: Self.black(size))
    }

    private static func fit(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        let scale = min(rect.width / extent.width, rect.height / extent.height)
        let w = extent.width * scale, h = extent.height * scale
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: rect.minX + (rect.width - w) / 2, y: rect.minY + (rect.height - h) / 2))
    }

    private static func black(_ size: CGSize) -> CIImage {
        CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: - Reading frames

    private static func generator(_ url: URL) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        return generator
    }

    /// The exact frame at `time`, mirrored as shown, its origin at zero.
    private static func frame(_ generator: AVAssetImageGenerator, at time: Double, mirrored: Bool) async throws -> CIImage {
        nonisolated(unsafe) let generator = generator
        let image = try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
        var frame = CIImage(cgImage: image)
        if mirrored {
            frame = frame.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -frame.extent.width, y: 0))
        }
        return frame
    }
}

/// Choose how to export, watch it render, then share or save the video.
struct ExportView: View {
    let comparison: Comparison
    @State private var exporter = Exporter()
    @State private var style: Exporter.Style = .sideBySide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export video").font(.title2.weight(.semibold))
            Text("The linked span, both clips lined up at their sync points, at \(speedText(comparison.linkedSpeed)) "
                 + "(set the speed on the transport for slow motion).")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Layout", selection: $style) {
                ForEach(Exporter.Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(exporter.progress != nil)

            if let progress = exporter.progress {
                ProgressView(value: progress) { Text("Rendering… \(Int(progress * 100))%") }
            } else if let file = exporter.file {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
            } else if let problem = exporter.problem {
                Text(problem).foregroundStyle(.red)
            }

            HStack {
                Button("Close") { exporter.cancel(); dismiss() }
                Spacer()
                if let file = exporter.file {
                    ShareLink(item: file) { Label("Share or save", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Export") { exporter.start(comparison, style: style) }
                        .buttonStyle(.borderedProminent)
                        .disabled(exporter.progress != nil || !comparison.canLink)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 440)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { if comparison.layout == .overlay { style = .overlay } }
    }
}
