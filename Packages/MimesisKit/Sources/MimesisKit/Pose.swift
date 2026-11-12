import AVFoundation
import SwiftUI
import Vision

/// A body's joints in one frame: where each is in the picture, 0–1 across and down, as filmed.
struct BodyPose: Sendable, Equatable {
    enum Joint: String, CaseIterable, Sendable {
        case nose, neck, root
        case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
        case leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle

        var vision: VNHumanBodyPoseObservation.JointName {
            switch self {
            case .nose: .nose
            case .neck: .neck
            case .root: .root
            case .leftShoulder: .leftShoulder
            case .rightShoulder: .rightShoulder
            case .leftElbow: .leftElbow
            case .rightElbow: .rightElbow
            case .leftWrist: .leftWrist
            case .rightWrist: .rightWrist
            case .leftHip: .leftHip
            case .rightHip: .rightHip
            case .leftKnee: .leftKnee
            case .rightKnee: .rightKnee
            case .leftAnkle: .leftAnkle
            case .rightAnkle: .rightAnkle
            }
        }
    }

    var joints: [Joint: CGPoint]

    /// The lines of the skeleton.
    static let bones: [(Joint, Joint)] = [
        (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    /// The angle at a joint, in degrees (0–180), when its three points were found. `aspect` is the
    /// picture's width over its height, so the angle is the one seen on screen.
    func angle(_ angle: JointAngle, aspect: CGFloat) -> Double? {
        let (a, v, c) = angle.points
        guard let a = joints[a], let v = joints[v], let c = joints[c] else { return nil }
        let u = CGVector(dx: (a.x - v.x) * aspect, dy: a.y - v.y), w = CGVector(dx: (c.x - v.x) * aspect, dy: c.y - v.y)
        let lengths = hypot(u.dx, u.dy) * hypot(w.dx, w.dy)
        guard lengths > 0 else { return nil }
        let cosine = max(-1, min(1, (u.dx * w.dx + u.dy * w.dy) / lengths))
        return acos(cosine) * 180 / .pi
    }

    /// Between two poses (for a time between two samples).
    func blended(with other: BodyPose, share: CGFloat) -> BodyPose {
        var joints: [Joint: CGPoint] = [:]
        for (joint, p) in self.joints {
            guard let q = other.joints[joint] else { continue }
            joints[joint] = CGPoint(x: p.x + (q.x - p.x) * share, y: p.y + (q.y - p.y) * share)
        }
        return BodyPose(joints: joints)
    }
}

/// An angle to measure on the body: at a joint, between the two bones that meet there.
enum JointAngle: String, CaseIterable, Identifiable, Sendable {
    case leftElbow, rightElbow, leftShoulder, rightShoulder, leftHip, rightHip, leftKnee, rightKnee
    var id: Self { self }

    var title: String {
        switch self {
        case .leftElbow: "Left elbow"
        case .rightElbow: "Right elbow"
        case .leftShoulder: "Left shoulder"
        case .rightShoulder: "Right shoulder"
        case .leftHip: "Left hip"
        case .rightHip: "Right hip"
        case .leftKnee: "Left knee"
        case .rightKnee: "Right knee"
        }
    }

    /// One end, the joint itself, the other end.
    var points: (BodyPose.Joint, BodyPose.Joint, BodyPose.Joint) {
        switch self {
        case .leftElbow: (.leftShoulder, .leftElbow, .leftWrist)
        case .rightElbow: (.rightShoulder, .rightElbow, .rightWrist)
        case .leftShoulder: (.leftElbow, .leftShoulder, .leftHip)
        case .rightShoulder: (.rightElbow, .rightShoulder, .rightHip)
        case .leftHip: (.leftShoulder, .leftHip, .leftKnee)
        case .rightHip: (.rightShoulder, .rightHip, .rightKnee)
        case .leftKnee: (.leftHip, .leftKnee, .leftAnkle)
        case .rightKnee: (.rightHip, .rightKnee, .rightAnkle)
        }
    }

    /// Shown on the skeleton by default: the elbows and knees.
    static let usual: Set<JointAngle> = [.leftElbow, .rightElbow, .leftKnee, .rightKnee]
}

/// The body followed through a stretch of a clip: its pose at each sampled frame, found with Vision.
@MainActor @Observable
final class PoseTrack {
    enum State: Equatable {
        case preparing(Double)
        case ready
        case failed(String)
    }

    private(set) var state: State = .preparing(0)
    /// Sample times (sorted) and the pose at each (nil where no body was found).
    private(set) var times: [Double] = []
    private(set) var poses: [BodyPose?] = []
    let range: ClosedRange<Double>
    private var task: Task<Void, Never>?

    /// At most this many frames are looked at; a longer stretch is sampled more thinly.
    static let frameLimit = 360

    init(url: URL, range: ClosedRange<Double>, fps: Double) {
        self.range = range
        let length = max(0.01, range.upperBound - range.lowerBound)
        let count = min(Self.frameLimit, max(2, Int((length * min(fps, 60)).rounded())))
        let times = (0..<count).map { range.lowerBound + length * Double($0) / Double(count - 1) }
        task = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 960, height: 960)
            var found: [BodyPose?] = []
            var last: BodyPose?
            for (index, time) in times.enumerated() {
                if Task.isCancelled { return }
                let pose = await Self.pose(generator, at: time, near: last)
                if let pose { last = pose }
                found.append(pose)
                if index % 4 == 0 {
                    let done = Double(index + 1) / Double(times.count)
                    await MainActor.run { self?.state = .preparing(done) }
                }
            }
            let result = found
            await MainActor.run {
                guard let self else { return }
                self.times = times
                self.poses = result
                if result.contains(where: { $0 != nil }) {
                    self.state = .ready
                } else {
                    #if targetEnvironment(simulator)
                    self.state = .failed("The skeleton needs a real iPhone or iPad (Vision can't find bodies in Simulator).")
                    #else
                    self.state = .failed("No body was found in this stretch.")
                    #endif
                }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// The body in the frame at `time`: with several people, the one nearest the body followed so far
    /// (else the most confident).
    nonisolated private static func pose(_ generator: AVAssetImageGenerator, at time: Double, near last: BodyPose?) async -> BodyPose? {
        nonisolated(unsafe) let generator = generator
        guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return nil }
        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let bodies: [BodyPose] = (request.results ?? []).compactMap { body in
            guard let points = try? body.recognizedPoints(.all) else { return nil }
            var joints: [BodyPose.Joint: CGPoint] = [:]
            for joint in BodyPose.Joint.allCases {
                // Vision counts up from the bottom; the picture counts down from the top.
                if let p = points[joint.vision], p.confidence > 0.2 {
                    joints[joint] = CGPoint(x: p.location.x, y: 1 - p.location.y)
                }
            }
            return joints.count >= 6 ? BodyPose(joints: joints) : nil
        }
        guard !bodies.isEmpty else { return nil }
        func centre(_ pose: BodyPose) -> CGPoint {
            if let root = pose.joints[.root] { return root }
            let all = Array(pose.joints.values)
            return CGPoint(x: all.map(\.x).reduce(0, +) / CGFloat(all.count), y: all.map(\.y).reduce(0, +) / CGFloat(all.count))
        }
        if let last {
            let target = centre(last)
            return bodies.min { hypot(centre($0).x - target.x, centre($0).y - target.y) < hypot(centre($1).x - target.x, centre($1).y - target.y) }
        }
        // The biggest body is the one being filmed.
        func size(_ pose: BodyPose) -> CGFloat {
            let ys = pose.joints.values.map(\.y)
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        return bodies.max { size($0) < size($1) }
    }

    /// The pose at `time`: between the two nearest samples.
    func pose(at time: Double) -> BodyPose? {
        guard !times.isEmpty, time >= range.lowerBound - 0.05, time <= range.upperBound + 0.05 else { return nil }
        let upper = times.firstIndex { $0 >= time } ?? times.count - 1
        let lower = max(0, upper - 1)
        guard let a = poses[lower] ?? poses[upper], let b = poses[upper] ?? poses[lower] else { return nil }
        let span = times[upper] - times[lower]
        guard span > 0 else { return a }
        return a.blended(with: b, share: CGFloat(min(1, max(0, (time - times[lower]) / span))))
    }

    /// An angle at every sample where it could be measured, lightly smoothed: (clip time, degrees).
    func curve(_ angle: JointAngle, aspect: CGFloat) -> [(time: Double, degrees: Double)] {
        let raw: [(Double, Double)] = zip(times, poses).compactMap { time, pose in
            guard let degrees = pose?.angle(angle, aspect: aspect) else { return nil }
            return (time, degrees)
        }
        guard raw.count > 2 else { return raw.map { (time: $0.0, degrees: $0.1) } }
        // Each value with its two neighbours: joints found frame by frame jitter a little.
        return raw.indices.map { i in
            let window = raw[max(0, i - 1)...min(raw.count - 1, i + 1)]
            return (time: raw[i].0, degrees: window.map(\.1).reduce(0, +) / Double(window.count))
        }
    }
}

extension Clip {
    /// Starts following the body through the clip's stretch (its In to Out), or stops showing it.
    func toggleSkeleton() {
        if showsSkeleton {
            showsSkeleton = false
            return
        }
        showsSkeleton = true
        trackPose()
    }

    /// Follows the body through the stretch, unless that's already done for it.
    func trackPose() {
        guard let url else { return }
        let range = trimStart...max(trimStart + 0.01, end)
        if let track = poseTrack, track.range == range, track.state != .failed("") {
            if case .failed = track.state {} else { return }
        }
        poseTrack?.cancel()
        poseTrack = PoseTrack(url: url, range: range, fps: Double(engine.fps > 0 ? engine.fps : 30))
    }
}

/// The skeleton over a clip's video, with the angle at each chosen joint.
struct SkeletonLayer: View {
    let clip: Clip
    let angles: Set<JointAngle>
    /// How far the video is zoomed in, and moved. The skeleton is drawn over the zoomed video, not
    /// zoomed with it: its joints follow the picture, while the lines, dots and numbers are drawn at
    /// their own size, sharp (zoomed with the video they were a small drawing blown up, and blurred).
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    var body: some View {
        let k: CGFloat = 1
        GeometryReader { space in
            let centre = CGPoint(x: space.size.width / 2, y: space.size.height / 2)
            let frame = pictureFrame(in: space.size)
            let aspect = frame.height > 0 ? frame.width / frame.height : 1
            let mirrored = clip.engine.mirroredHorizontally
            if let pose = clip.poseTrack?.pose(at: clip.engine.currentTime) {
                Canvas { context, _ in
                    func at(_ joint: BodyPose.Joint) -> CGPoint? {
                        guard let p = pose.joints[joint] else { return nil }
                        let x = mirrored ? 1 - p.x : p.x
                        let fitted = CGPoint(x: frame.minX + x * frame.width, y: frame.minY + p.y * frame.height)
                        return CGPoint(x: centre.x + (fitted.x - centre.x) * zoom + pan.width,
                                       y: centre.y + (fitted.y - centre.y) * zoom + pan.height)
                    }
                    var bones = Path()
                    for (a, b) in BodyPose.bones {
                        guard let a = at(a), let b = at(b) else { continue }
                        bones.move(to: a)
                        bones.addLine(to: b)
                    }
                    context.stroke(bones, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 4 * k, lineCap: .round))
                    context.stroke(bones, with: .color(Color(red: 0.3, green: 0.85, blue: 1)), style: StrokeStyle(lineWidth: 2 * k, lineCap: .round))
                    for joint in BodyPose.Joint.allCases where joint != .nose {
                        guard let p = at(joint) else { continue }
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3 * k, y: p.y - 3 * k, width: 6 * k, height: 6 * k)), with: .color(.white))
                    }
                    for angle in JointAngle.allCases where angles.contains(angle) {
                        guard let degrees = pose.angle(angle, aspect: aspect), let p = at(angle.points.1) else { continue }
                        let text = Text("\(Int(degrees.rounded()))°")
                            .font(.system(size: 12 * k, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                        let resolved = context.resolve(text)
                        let size = resolved.measure(in: CGSize(width: 80, height: 30))
                        let box = CGRect(x: p.x + 8 * k, y: p.y - size.height / 2 - 2 * k, width: size.width + 8 * k, height: size.height + 4 * k)
                        context.fill(Path(roundedRect: box, cornerRadius: 5 * k), with: .color(.black.opacity(0.6)))
                        context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func pictureFrame(in size: CGSize) -> CGRect {
        let video = clip.engine.videoSize
        guard video.width > 0, video.height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / video.width, size.height / video.height)
        let fitted = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
