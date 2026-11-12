import AreteMedia
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
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
    /// Who-is-where maps are kept this many cells across and down (stretched over the picture).
    nonisolated static let labelSide = 128

    /// More than one subject was found in some frame, so there's someone to pick.
    public private(set) var hasSeveral = false
    /// The player picked, frame by frame (the label at each frame); nil keeps everyone found.
    public private(set) var picked: [Int: UInt8]? { didSet { pickGeneration += 1 } }
    /// Changes with every pick, so the frame on screen is drawn again.
    private(set) var pickGeneration = 0
    /// A soft-edged box around the player instead of their outline: for when the outline loses the racket.
    public var boxed = false { didSet { pickGeneration += 1 } }
    private var boxMasks: [Int: CGImage] = [:]

    private var masks: [Int: CGImage] = [:]
    /// For each frame, which subject each cell of the picture belongs to (0 is nobody).
    private var labels: [Int: [UInt8]] = [:]
    /// The picked player's masks, made when first shown.
    private var pickedMasks: [Int: CGImage] = [:]
    private let context = CIContext()
    private var frameRate: Double = 30
    private var task: Task<Void, Never>?
    let url: URL

    /// Where on the clip the picked player was tapped (clip time, and 0–1 as filmed), to pick them again
    /// when a saved comparison is reopened.
    public private(set) var pickedAt: (time: Double, point: CGPoint)?

    /// - Parameters:
    ///   - fresh: make the masks again even when a saved copy exists.
    ///   - pickAt: once ready, pick the player at this tap (from a saved comparison).
    init(clip: Clip, fresh: Bool = false, pickAt: (time: Double, point: CGPoint)? = nil) {
        url = clip.url ?? URL(fileURLWithPath: "/")
        let fps = Double(clip.engine.fps > 0 ? clip.engine.fps : 30)
        let length = clip.end - clip.trimStart
        let limit = Double(Self.frameLimit) / fps
        shortened = length > limit
        span = clip.trimStart...(clip.trimStart + min(length, limit))
        let (url, start, duration) = (url, span.lowerBound, span.upperBound - span.lowerBound)
        let file = Self.cacheFile(for: url, start: start, duration: duration)
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if !fresh, let file, let saved = Cutout.load(file) { return saved }
                    let made = try await Cutout.makeMasks(url: url, start: start, duration: duration) { done in
                        Task { @MainActor in
                            if case .preparing = self?.state { self?.state = .preparing(done) }
                        }
                    }
                    if let file { Cutout.save(made, to: file) }
                    return made
                }.value
                guard let self else { return }
                self.masks = result.masks
                self.labels = result.labels
                self.frameRate = result.frameRate
                self.hasSeveral = result.labels.values.contains { Set($0).subtracting([0]).count > 1 }
                self.state = result.masks.isEmpty ? .failed("Nobody was found to cut out.") : .ready
                if let pickAt { _ = self.pick(at: pickAt.time, point: pickAt.point) }
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

    /// The mask for the frame at `time` (the clip's own seconds), or the nearest one a frame away:
    /// everyone found, or only the picked player.
    func mask(at time: Double) -> CGImage? {
        let index = Int((time * frameRate).rounded())
        guard let frame = [index, index - 1, index + 1].first(where: { masks[$0] != nil }) else { return nil }
        if boxed {
            if let made = boxMasks[frame] { return made }
            guard let map = labels[frame], let all = masks[frame] else { return nil }
            let made = Self.box(around: picked?[frame], labels: map, width: all.width, height: all.height, context: context)
            boxMasks[frame] = made
            return made
        }
        guard let picked else { return masks[frame] }
        if let made = pickedMasks[frame] { return made }
        guard let label = picked[frame], let all = masks[frame], let map = labels[frame] else { return nil }
        let made = Self.only(label, in: all, labels: map, context: context)
        pickedMasks[frame] = made
        return made
    }

    // MARK: - Picking one player

    /// Picks the subject at `point` (0–1 across and down, as filmed) in the frame at `time`, then follows
    /// them through every other frame by how much they overlap from one frame to the next.
    /// False when nobody is there.
    func pick(at time: Double, point: CGPoint) -> Bool {
        let index = Int((time * frameRate).rounded())
        guard let frame = [index, index - 1, index + 1].first(where: { labels[$0] != nil }),
              let map = labels[frame], let start = Self.label(near: point, in: map) else { return false }
        var chosen: [Int: UInt8] = [frame: start]
        let frames = labels.keys.sorted()
        guard let at = frames.firstIndex(of: frame) else { return false }
        for direction in [1, -1] {
            var previous = (frame: frame, label: start)
            var i = at + direction
            while frames.indices.contains(i) {
                let next = frames[i]
                if let map = labels[next], let before = labels[previous.frame],
                   let label = Self.follow(previous.label, from: before, into: map) {
                    chosen[next] = label
                    previous = (next, label)
                }
                i += direction
            }
        }
        picked = chosen
        pickedAt = (time, point)
        pickedMasks = [:]
        boxMasks = [:]
        return true
    }

    /// Back to everyone found.
    func pickEveryone() {
        picked = nil
        pickedAt = nil
        boxMasks = [:]
        pickedMasks = [:]
    }

    /// The subject at `point`, or the nearest one within a few cells (a tap needn't be exact).
    nonisolated static func label(near point: CGPoint, in map: [UInt8]) -> UInt8? {
        let side = labelSide
        let cx = Int(point.x * CGFloat(side)), cy = Int(point.y * CGFloat(side))
        for radius in 0...6 {
            for y in (cy - radius)...(cy + radius) where y >= 0 && y < side {
                for x in (cx - radius)...(cx + radius) where x >= 0 && x < side {
                    let label = map[y * side + x]
                    if label != 0 { return label }
                }
            }
        }
        return nil
    }

    /// The subject in `next` that overlaps most with `label` in `previous`; if none overlaps
    /// (a fast move), the one whose centre is nearest.
    nonisolated static func follow(_ label: UInt8, from previous: [UInt8], into next: [UInt8]) -> UInt8? {
        var overlap: [UInt8: Int] = [:]
        for i in previous.indices where previous[i] == label && next[i] != 0 {
            overlap[next[i], default: 0] += 1
        }
        if let best = overlap.max(by: { $0.value < $1.value }) { return best.key }
        guard let from = centre(of: label, in: previous) else { return nil }
        let candidates = Set(next).subtracting([0])
        return candidates.min { a, b in
            let ca = centre(of: a, in: next) ?? .zero, cb = centre(of: b, in: next) ?? .zero
            return hypot(ca.x - from.x, ca.y - from.y) < hypot(cb.x - from.x, cb.y - from.y)
        }
    }

    nonisolated static func centre(of label: UInt8, in map: [UInt8]) -> CGPoint? {
        var x = 0, y = 0, count = 0
        for i in map.indices where map[i] == label {
            x += i % labelSide
            y += i / labelSide
            count += 1
        }
        return count == 0 ? nil : CGPoint(x: Double(x) / Double(count), y: Double(y) / Double(count))
    }

    /// A soft-edged box around `label` (or everyone found, for nil), padded so a swing's racket fits:
    /// a mask `width` × `height`, white inside.
    nonisolated static func box(around label: UInt8?, labels map: [UInt8], width: Int, height: Int,
                                context: CIContext) -> CGImage? {
        let side = labelSide
        var minX = side, minY = side, maxX = -1, maxY = -1
        for i in map.indices where label.map({ map[i] == $0 }) ?? (map[i] != 0) {
            let x = i % side, y = i / side
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= minX else { return nil }
        // Cells to the mask's pixels (counting down from the top), padded by a quarter of the box's size.
        let sx = CGFloat(width) / CGFloat(side), sy = CGFloat(height) / CGFloat(side)
        var rect = CGRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                          width: CGFloat(maxX - minX + 1) * sx, height: CGFloat(maxY - minY + 1) * sy)
        rect = rect.insetBy(dx: -rect.width * 0.25, dy: -rect.height * 0.12)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Image counts up from the bottom.
        let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
        let soft = min(rect.width, rect.height) * 0.08
        let box = CIImage(color: .white).cropped(to: flipped.intersection(extent))
            .composited(over: CIImage(color: .black).cropped(to: extent))
            .clampedToExtent().applyingGaussianBlur(sigma: soft).cropped(to: extent)
        return context.createCGImage(box, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// Everyone's mask, kept only where `label` is: their area from the who-is-where map, widened a
    /// little so a thin racket at its edge isn't clipped.
    nonisolated static func only(_ label: UInt8, in all: CGImage, labels map: [UInt8], context: CIContext) -> CGImage? {
        let side = labelSide
        let area = Data(map.map { $0 == label ? 255 : 0 })
        guard let provider = CGDataProvider(data: area as CFData),
              let areaImage = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let extent = CGRect(x: 0, y: 0, width: all.width, height: all.height)
        let region = CIImage(cgImage: areaImage)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(side), y: extent.height / CGFloat(side)))
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 6])
            .cropped(to: extent)
        let kept = CIImage(cgImage: all).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: region,
        ])
        return context.createCGImage(kept, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    // MARK: - Making the masks

    struct Masks: @unchecked Sendable {
        var masks: [Int: CGImage]
        var labels: [Int: [UInt8]]
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
        var labels: [Int: [UInt8]] = [:]
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
                let frame = Int((time * frameRate).rounded())
                if let image = context.createCGImage(small, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) {
                    masks[frame] = image
                }
                labels[frame] = shrink(found.instanceMask)
            }
            progress(min(1, (time - start) / max(0.001, duration)))
        }
        if reader.status == .failed {
            throw MaskProbeError.unreadable(reader.error?.localizedDescription ?? "unknown")
        }
        return Masks(masks: masks, labels: labels, frameRate: frameRate)
    }

    /// Vision's who-is-where map (one byte a cell, stretched over the picture), sampled `labelSide` square.
    nonisolated static func shrink(_ map: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let row = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let side = labelSide
        var out = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            let sy = min(height - 1, y * height / side)
            for x in 0..<side {
                out[y * side + x] = base[sy * row + min(width - 1, x * width / side)]
            }
        }
        return out
    }

    // MARK: - Saved copies

    /// What a saved cutout holds: each frame's mask as a PNG and its who-is-where map compressed.
    private struct SavedMasks: Codable {
        var frameRate: Double
        var masks: [Int: Data]
        var labels: [Int: Data]
    }

    /// The saved copy for this clip and span, in Application Support/Mimesis/Cutouts. The clip's
    /// size and modification date are part of the name, so an edited file is cut out again.
    nonisolated static func cacheFile(for url: URL, start: Double, duration: Double) -> URL? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = [
            url.standardizedFileURL.path,
            String(values?.fileSize ?? 0),
            String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0),
            String(format: "%.3f-%.3f", start, duration),
            "v1",
        ].joined(separator: "|")
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Cutouts", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return folder.appendingPathComponent("\(name).cutout")
    }

    nonisolated static func save(_ made: Masks, to file: URL) {
        var saved = SavedMasks(frameRate: made.frameRate, masks: [:], labels: [:])
        for (frame, mask) in made.masks {
            if let png = MaskProbe.png(mask) { saved.masks[frame] = png }
        }
        for (frame, map) in made.labels {
            if let packed = try? (Data(map) as NSData).compressed(using: .lzfse) { saved.labels[frame] = packed as Data }
        }
        guard let data = try? PropertyListEncoder().encode(saved) else { return }
        try? data.write(to: file, options: .atomic)
    }

    nonisolated static func load(_ file: URL) -> Masks? {
        guard let data = try? Data(contentsOf: file),
              let saved = try? PropertyListDecoder().decode(SavedMasks.self, from: data) else { return nil }
        var made = Masks(masks: [:], labels: [:], frameRate: saved.frameRate)
        for (frame, png) in saved.masks {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            made.masks[frame] = image
        }
        for (frame, packed) in saved.labels {
            guard let map = try? (packed as NSData).decompressed(using: .lzfse) else { return nil }
            made.labels[frame] = [UInt8](map as Data)
        }
        return made.masks.isEmpty ? nil : made
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
    private weak var player: AVPlayer?
    private var orientation: CGImagePropertyOrientation = .up
    private var last: CGImage?
    private var lastKey = ""
    /// The latest frame from the player and its time, kept to draw again when an option changes.
    private var buffer: CVPixelBuffer?
    private var bufferTime: Double = 0
    private let context = CIContext()

    /// The longest side the cutout is drawn at; the view scales it to fit.
    private let maxSide: CGFloat = 1100

    func attach(to item: AVPlayerItem?, player: AVPlayer?) {
        guard item !== self.item else { return }
        detach()
        guard let item else { return }
        self.player = player
        // In ordinary (Rec. 709) colours: an HDR video (an iPhone's) is converted on the way, as the
        // player converts it for the screen. Left as filmed, its frames came out far too bright here.
        let output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
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
        if let output, let item {
            item.remove(output)
            // The player decodes differently while an output reads its frames, and for an HDR video
            // (an iPhone's) it kept doing so afterwards: the picture stayed far too bright. Taking the
            // video out of the player and putting it back makes it start again as it was.
            if let player, player.currentItem === item {
                let time = item.currentTime(), rate = player.rate
                player.replaceCurrentItem(with: nil)
                player.replaceCurrentItem(with: item)
                item.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil)
                if rate > 0 { player.rate = rate }
            }
        }
        player = nil
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
        let key = "\(cutout.enabled)\(cutout.tinted)\(mirrored)\(cutout.picked?.count ?? -1)\(cutout.pickGeneration)"
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
        .onAppear { renderer.attach(to: clip.engine.playerItem, player: clip.engine.player) }
        .onChange(of: clip.engine.playerItem) { _, item in renderer.attach(to: item, player: clip.engine.player) }
        .onDisappear { renderer.detach() }
    }
}
