import AVFoundation
import CoreImage
import Vision

/// Where a body is in a frame: hip centre, feet and neck (when seen), in the picture as filmed
/// (0–1 across and down).
struct BodyPoints: Sendable {
    var hips: CGPoint
    var feet: CGPoint?
    var neck: CGPoint?

    func mirrored() -> BodyPoints {
        func flip(_ p: CGPoint?) -> CGPoint? { p.map { CGPoint(x: 1 - $0.x, y: $0.y) } }
        return BodyPoints(hips: flip(hips)!, feet: flip(feet), neck: flip(neck))
    }
}

enum AlignError: LocalizedError {
    case noFrame(String)
    case noBody(String)

    var errorDescription: String? {
        switch self {
        case .noFrame(let clip): "Couldn't read \(clip)'s frame."
        case .noBody(let clip): "No body found in \(clip)'s frame: step to a frame where the whole body shows."
        }
    }
}

extension Comparison {
    /// Moves and resizes the top clip so its player's hips sit on the other player's hips, and its
    /// hips-to-feet height matches. Uses the frames on screen now.
    func autoAlign() async throws {
        let top = clips[overlayTop], base = clips[1 - overlayTop]
        let topName = overlayTop == 0 ? "A" : "B", baseName = overlayTop == 0 ? "B" : "A"
        guard let topURL = top.url, let baseURL = base.url else { return }
        async let topBody = Self.body(in: topURL, at: top.engine.currentTime, name: topName)
        async let baseBody = Self.body(in: baseURL, at: base.engine.currentTime, name: baseName)
        var (t, b) = try await (topBody, baseBody)
        // Mirroring is only how a clip is shown: the points are found as filmed, so flip them to match.
        if top.engine.mirroredHorizontally { t = t.mirrored() }
        if base.engine.mirroredHorizontally { b = b.mirrored() }
        // Size both bodies by the same measure: hips to feet when both show their feet, else hips to neck.
        let (topEnd, baseEnd): (CGPoint, CGPoint)
        if let tf = t.feet, let bf = b.feet {
            (topEnd, baseEnd) = (tf, bf)
        } else if let tn = t.neck, let bn = b.neck {
            (topEnd, baseEnd) = (tn, bn)
        } else {
            throw AlignError.noBody(t.feet == nil && t.neck == nil ? topName : baseName)
        }

        // Work in the picture underneath, sized as filmed; everything below is a share of it, so any size works.
        let baseSize = base.engine.videoSize, topSize = top.engine.videoSize
        guard baseSize.width > 0, topSize.width > 0 else { return }
        // The top clip as first placed: fitted into the picture underneath, centred.
        let fit = min(baseSize.width / topSize.width, baseSize.height / topSize.height)
        let fitted = CGSize(width: topSize.width * fit, height: topSize.height * fit)
        let inset = CGPoint(x: (baseSize.width - fitted.width) / 2, y: (baseSize.height - fitted.height) / 2)
        // A top point, from the centre of its frame, before scaling.
        func fromCentre(_ p: CGPoint) -> CGPoint {
            CGPoint(x: inset.x + p.x * fitted.width - baseSize.width / 2,
                    y: inset.y + p.y * fitted.height - baseSize.height / 2)
        }
        func inBase(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * baseSize.width, y: p.y * baseSize.height) }

        let topHeight = hypot(fromCentre(topEnd).x - fromCentre(t.hips).x, fromCentre(topEnd).y - fromCentre(t.hips).y)
        let baseHeight = hypot(inBase(baseEnd).x - inBase(b.hips).x, inBase(baseEnd).y - inBase(b.hips).y)
        guard topHeight > 1 else { return }
        let scale = min(4, max(0.25, baseHeight / topHeight))
        // Put the top hips on the base hips: the frame's centre goes where that leaves it.
        let hips = fromCentre(t.hips), target = inBase(b.hips)
        let centre = CGPoint(x: target.x - scale * hips.x, y: target.y - scale * hips.y)
        overlayScale = scale
        overlayRotation = 0
        overlayOffset = CGSize(
            width: (centre.x - baseSize.width / 2) / baseSize.width,
            height: (centre.y - baseSize.height / 2) / baseSize.height)
    }

    /// The most confident body in the exact frame at `time`.
    nonisolated private static func body(in url: URL, at time: Double, name: String) async throws -> BodyPoints {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else {
            throw AlignError.noFrame(name)
        }
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let bodies = request.results ?? []
        guard let body = bodies.max(by: { $0.confidence < $1.confidence }),
              let points = try? body.recognizedPoints(.all) else { throw AlignError.noBody(name) }
        // Vision counts up from the bottom; the overlay counts down from the top.
        func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
            guard let found = points[joint], found.confidence > 0.25 else { return nil }
            return CGPoint(x: found.location.x, y: 1 - found.location.y)
        }
        func middle(_ a: CGPoint?, _ b: CGPoint?) -> CGPoint? {
            switch (a, b) {
            case let (a?, b?): CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            case let (a?, nil): a
            case let (nil, b?): b
            default: nil
            }
        }
        guard let hips = point(.root) ?? middle(point(.leftHip), point(.rightHip)) else { throw AlignError.noBody(name) }
        return BodyPoints(hips: hips, feet: middle(point(.leftAnkle), point(.rightAnkle)), neck: point(.neck))
    }
}

// MARK: - Lining up the backgrounds (clips filmed at the same place)

/// How the top clip's picture lines up with the one underneath: resized about its centre by `scale`,
/// then moved by `shift` (pixels of the picture underneath, y counting up).
struct BackgroundMatch: Sendable {
    var scale: CGFloat
    var shift: CGPoint
    /// How different the two pictures still are where they overlap (0 is identical, 1 is opposite).
    var difference: Double
}

enum BackgroundError: LocalizedError {
    case noMatch
    var errorDescription: String? { "The backgrounds don't match: are both clips filmed at the same place?" }
}

extension Comparison {
    /// Moves and resizes the top clip so its background sits on the other's, for two clips filmed at the
    /// same place (the court lines and fences line up, whoever is playing). Uses the frames on screen now.
    func alignBackgrounds() async throws {
        let top = clips[overlayTop], base = clips[1 - overlayTop]
        guard let topURL = top.url, let baseURL = base.url else { return }
        async let topFrame = Self.frameImage(topURL, at: top.engine.currentTime, mirrored: top.engine.mirroredHorizontally)
        async let baseFrame = Self.frameImage(baseURL, at: base.engine.currentTime, mirrored: base.engine.mirroredHorizontally)
        let (t, b) = try await (topFrame, baseFrame)
        let match = try await Task.detached { try Self.matchBackgrounds(base: b, top: t) }.value
        // The overlay draws the top clip fitted into the picture underneath, resized about the centre,
        // then moved by a share of the picture (y counting down).
        overlayScale = match.scale
        overlayRotation = 0
        overlayOffset = CGSize(width: match.shift.x / CGFloat(b.width), height: -match.shift.y / CGFloat(b.height))
    }

    /// The exact frame at `time`, as shown (mirrored when the clip is).
    nonisolated static func frameImage(_ url: URL, at time: Double, mirrored: Bool) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 720, height: 720)
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        guard mirrored else { return image }
        let flipped = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(image.width), y: 0))
        return CIContext().createCGImage(flipped, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image
    }

    /// Tries sizes from 0.7× to 1.4×; at each, finds the shift where the two pictures differ least (coarse,
    /// then pixel by pixel), and the best size and shift win. Works on small grey copies; returns pixels
    /// of `base`, y counting up.
    nonisolated static func matchBackgrounds(base: CGImage, top: CGImage) throws -> BackgroundMatch {
        let context = CIContext()
        let work: CGFloat = 240
        let fullBase = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let shrink = work / max(fullBase.width, fullBase.height)
        let canvas = CGRect(x: 0, y: 0, width: (fullBase.width * shrink).rounded(), height: (fullBase.height * shrink).rounded())
        let w = Int(canvas.width), h = Int(canvas.height)
        let centre = CGPoint(x: canvas.midX, y: canvas.midY)
        let grey = { (image: CIImage) in image.applyingFilter("CIPhotoEffectMono") }
        let baseImage = grey(CIImage(cgImage: base).transformed(by: CGAffineTransform(scaleX: shrink, y: shrink)))
        // The top picture fitted into the one underneath, as the overlay first places it.
        let topCI = CIImage(cgImage: top)
        let fit = min(canvas.width / topCI.extent.width, canvas.height / topCI.extent.height)
        let fitted = grey(topCI.transformed(by: CGAffineTransform(scaleX: fit, y: fit)).transformed(by: CGAffineTransform(
            translationX: (canvas.width - topCI.extent.width * fit) / 2, y: (canvas.height - topCI.extent.height * fit) / 2)))
        guard let baseCG = context.createCGImage(baseImage, from: canvas), let b = pixels(baseCG) else {
            throw BackgroundError.noMatch
        }
        let debug = ProcessInfo.processInfo.environment["MIMESIS_DEBUG_MATCH"] != nil

        var best: BackgroundMatch?
        for step in 0...35 {
            let scale = 0.7 + CGFloat(step) * 0.02
            let sized = fitted.transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
            guard let sizedCG = context.createCGImage(sized, from: canvas), let t = pixels(sizedCG) else { continue }
            // Where the sized top picture has something, rows counting down from the top.
            let e = sized.extent.intersection(canvas)
            let area = (x: Int(e.minX.rounded(.up)), y: h - Int(e.maxY.rounded(.down)),
                        w: Int(e.width.rounded(.down)), h: Int(e.height.rounded(.down)))
            func difference(_ dx: Int, _ dy: Int, every stride: Int) -> Double? {
                // Pixels of the picture underneath that the moved top picture covers.
                let x0 = max(0, area.x + dx), x1 = min(w, area.x + area.w + dx)
                let y0 = max(0, area.y + dy), y1 = min(h, area.y + area.h + dy)
                guard x1 - x0 > w * 2 / 5, y1 - y0 > h * 2 / 5 else { return nil }
                var sum = 0, count = 0
                var y = y0 + 2
                while y < y1 - 2 {
                    var x = x0 + 2
                    let rowB = y * w, rowT = (y - dy) * w
                    while x < x1 - 2 {
                        sum += abs(Int(b[rowB + x]) - Int(t[rowT + x - dx]))
                        count += 1
                        x += stride
                    }
                    y += stride
                }
                return count == 0 ? nil : Double(sum) / Double(count * 255)
            }
            // Coarse: every 3rd shift up to a quarter of the picture, comparing every 3rd pixel.
            let reach = max(w, h) / 4
            var bestShift = (dx: 0, dy: 0), bestDifference = Double.infinity
            for dy in stride(from: -reach, through: reach, by: 3) {
                for dx in stride(from: -reach, through: reach, by: 3) {
                    if let d = difference(dx, dy, every: 3), d < bestDifference { (bestShift, bestDifference) = ((dx, dy), d) }
                }
            }
            // Fine: every shift near the best, every pixel.
            let around = bestShift
            bestDifference = .infinity
            for dy in (around.dy - 3)...(around.dy + 3) {
                for dx in (around.dx - 3)...(around.dx + 3) {
                    if let d = difference(dx, dy, every: 1), d < bestDifference { (bestShift, bestDifference) = ((dx, dy), d) }
                }
            }
            if debug { print(String(format: "scale %.2f shift %4d %4d difference %.4f", scale, bestShift.dx, bestShift.dy, bestDifference)) }
            if bestDifference < best?.difference ?? .infinity {
                // Rows counted down; the overlay's shift counts up.
                best = BackgroundMatch(scale: scale,
                                       shift: CGPoint(x: CGFloat(bestShift.dx) / shrink, y: CGFloat(-bestShift.dy) / shrink),
                                       difference: bestDifference)
            }
        }
        guard let best, best.difference < 0.15 else { throw BackgroundError.noMatch }
        return best
    }

    /// A grey image's pixels, one byte each, rows from the top.
    nonisolated private static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height)
        guard let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

}
