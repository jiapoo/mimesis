import AVFoundation
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
        case .noBody(let clip): "No body found in \(clip)'s frame: step to a frame where the whole player shows."
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
