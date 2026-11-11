import AVFoundation
import CoreImage
import SwiftUI

/// StroMotion: a whole motion in one image, the player cut out at several moments over one background,
/// the earlier ones a little fainter, so the path of the racket and body reads at a glance.
enum StroMotion {
    /// Moments spread evenly over `span`, first and last included.
    static func times(in span: ClosedRange<Double>, count: Int) -> [Double] {
        guard count > 1 else { return [span.lowerBound] }
        return (0..<count).map { span.lowerBound + (span.upperBound - span.lowerBound) * Double($0) / Double(count - 1) }
    }

    /// - Parameters:
    ///   - masks: the cut-out mask for each of `times` (nil leaves that moment out).
    ///   - mirrored: the clip is shown mirrored, so the image is too.
    nonisolated static func make(url: URL, times: [Double], masks: [CGImage?], mirrored: Bool) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        nonisolated(unsafe) let frames = generator

        func frame(at time: Double) async throws -> CIImage {
            var image = CIImage(cgImage: try await frames.image(at: CMTime(seconds: time, preferredTimescale: 600)).image)
            if mirrored {
                image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
            }
            return image
        }

        guard let first = times.first else { throw CocoaError(.featureUnsupported) }
        // The background: the first moment, with the player standing where the motion starts.
        var picture = try await frame(at: first)
        let extent = picture.extent
        for (index, time) in times.enumerated() where index > 0 {
            guard masks.indices.contains(index), let maskImage = masks[index] else { continue }
            let still = try await frame(at: time)
            var mask = CIImage(cgImage: maskImage)
            mask = mask.transformed(by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            if mirrored {
                mask = mask.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -extent.width, y: 0))
            }
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: extent)
            // Earlier moments fainter: from 55% up to solid for the last.
            let strength = 0.55 + 0.45 * Double(index) / Double(max(1, times.count - 1))
            mask = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            ])
            picture = still.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: picture, kCIInputMaskImageKey: mask,
            ])
        }
        guard let image = CIContext().createCGImage(picture, from: extent) else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}

/// Make a StroMotion image of one clip: how many moments, then share or save it.
struct StroMotionView: View {
    let clip: Clip
    let letter: String
    @State private var count = 6
    /// Between the first and last sync point (e.g. racket drop to finish) rather than the whole trim.
    @State private var bySyncs = false
    @State private var image: CGImage?
    @State private var file: URL?
    @State private var making = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("StroMotion").font(.title2.weight(.semibold))
            Text("Clip \(letter)'s person at \(count) moments across \(bySyncs ? "its sync points" : "its trim") "
                 + "(\(clock(chosenSpan.lowerBound)) – \(clock(chosenSpan.upperBound))), in one picture. "
                 + "Pick a person in the overlay if others are in frame.")
                .font(.callout).foregroundStyle(.secondary)
            if clip.syncs.count >= 2 {
                Picker("Span", selection: $bySyncs) {
                    Text("Whole trim").tag(false)
                    Text("First to last sync point").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(making)
            }

            Stepper(value: $count, in: 3...12) {
                Text("\(count) moments").monospacedDigit()
            }
            .disabled(making)

            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let cutout = clip.cutout, case .preparing(let done) = cutout.state {
                    ProgressView(value: done) { Text("Finding the person… \(Int(done * 100))%") }
                } else if making {
                    ProgressView("Putting it together…")
                } else if let problem {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if let file {
                    ShareLink(item: file) { Label("Share or save", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
                Button(image == nil ? "Make" : "Make again") { make() }
                    .buttonStyle(.bordered)
                    .disabled(making)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .themedSheet(width: 480, height: 360)
    }

    private var chosenSpan: ClosedRange<Double> {
        if bySyncs, let first = clip.syncs.first, let last = clip.syncs.last, last > first { return first...last }
        return clip.trimStart...max(clip.trimStart, clip.end)
    }

    private func make() {
        guard let url = clip.url else { return }
        making = true
        problem = nil
        image = nil
        file = nil
        Task {
            defer { making = false }
            // The cutout first (from its saved copy when there is one).
            if clip.cutout == nil || clip.cutout?.state != .ready { clip.makeCutout() }
            while let cutout = clip.cutout, case .preparing = cutout.state { try? await Task.sleep(for: .milliseconds(200)) }
            guard let cutout = clip.cutout, cutout.state == .ready else {
                if case .failed(let why)? = clip.cutout?.state { problem = why } else { problem = "Nobody could be found." }
                return
            }
            let wanted = chosenSpan
            let span = max(wanted.lowerBound, cutout.span.lowerBound)...max(max(wanted.lowerBound, cutout.span.lowerBound),
                                                                              min(wanted.upperBound, cutout.span.upperBound))
            let times = StroMotion.times(in: span, count: count)
            let masks = times.map { cutout.mask(at: $0) }
            do {
                let made = try await StroMotion.make(url: url, times: times, masks: masks, mirrored: clip.engine.mirroredHorizontally)
                image = made
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(clip.name) StroMotion.png")
                try MaskProbe.png(made)?.write(to: out)
                file = out
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
