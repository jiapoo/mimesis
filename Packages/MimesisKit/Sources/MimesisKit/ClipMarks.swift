import AreteMedia
import CoreGraphics
import Foundation

/// A clip is something drawn on: AreteMedia's drawing views (the layer, the tools, an angle's degrees)
/// read and change its drawings, and ask it which frame is on screen.
extension Clip: DrawingSurface {
    public var drawingTime: Double { engine.currentTime }
    public var drawingFrameLength: Double { frameLength }
    public var drawingPictureSize: CGSize { engine.videoSize }
    public var drawingMirrored: Bool { engine.mirroredHorizontally }

    /// The body in the frame the player really shows: after a quick seek (linked clips, scrubbing)
    /// that can be a few frames from the time asked for, and the skeleton then sat beside the body.
    var shownPose: BodyPose? {
        let asked = engine.currentTime
        let shown = engine.player?.currentTime().seconds ?? asked
        return poseTrack?.pose(at: shown.isFinite ? shown : asked)
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

