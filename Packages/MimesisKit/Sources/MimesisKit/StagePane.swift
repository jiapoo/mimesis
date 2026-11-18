import AreteMedia
import MotionCore
import MotionKit
import SwiftUI

/// The 3D layout (on trial): the clips small on the left, to check against, and the two bodies in 3D
/// on a stage to look round, moving with the same timeline.
struct StagePane: View {
    let comparison: Comparison

    @State private var camera = StageCamera.threeQuarter
    /// One body standing in the other (to compare shapes), or the two side by side.
    @State private var together = true
    /// Both turned to face the front as their stretch starts, so clips filmed from different sides compare.
    @State private var faceSame = true
    /// Each body moves across the floor as it did in its video (roughly: from one camera); off, it
    /// stays on the spot, which compares shapes best.
    @State private var travels = false
    /// Which hand grips in each clip (holds the racket, the bat, the club): chosen by hand, since the
    /// tracking can't tell (on two serves the busier wrist was the tossing one).
    @State private var grips: [BodySide?] = [nil, nil]

    private static let colors: [Color] = [Theme.accent, Color(red: 0.3, green: 0.85, blue: 1)]
    private var loaded: [(index: Int, clip: Clip)] {
        comparison.clips.enumerated().filter { $0.element.isLoaded }.map { (index: $0.offset, clip: $0.element) }
    }

    var body: some View {
        HStack(spacing: 1) {
            // The videos themselves, small: what the 3D was made from.
            VStack(spacing: 1) {
                ForEach(loaded, id: \.index) { item in
                    VideoPlayerRepresentable(player: item.clip.engine.player)
                        .id(ObjectIdentifier(item.clip))
                        .overlay(alignment: .topLeading) { letter(item.index).padding(8) }
                        .background(Color.black)
                }
            }
            .frame(maxWidth: 260)
            MotionStage(figures: figures, camera: $camera)
                .background(Color(red: 0.02, green: 0.04, blue: 0.09))
                .overlay(alignment: .top) { controls.padding(10) }
                .overlay(alignment: .bottomLeading) { readings.padding(.leading, 12).padding(.bottom, 150) }
                .overlay { status }
        }
        .background(Color.black)
        .onAppear(perform: track)
        .onChange(of: stretches) { _, _ in track() }
    }

    // MARK: The figures

    /// Each clip's stretch and look, to follow the body again when one changes.
    private var stretches: [String] {
        loaded.map { "\($0.clip.url?.path ?? "")|\($0.clip.trimStart)|\($0.clip.end)|\($0.clip.engine.mirroredHorizontally)" }
    }

    private func track() {
        for item in loaded {
            let clip = item.clip
            guard let url = clip.url else { continue }
            let range = clip.trimStart...max(clip.trimStart + 0.01, clip.end)
            let mirrored = clip.engine.mirroredHorizontally
            if let have = clip.motion, have.url == url, have.range == range, have.mirrored == mirrored { continue }
            clip.motion?.cancel()
            clip.motion = MotionTrack(url: url, range: range, fps: Double(clip.engine.fps > 0 ? clip.engine.fps : 30), mirrored: mirrored)
        }
    }

    /// The pose a clip shows now: at the time its player is really on.
    private func pose(_ clip: Clip) -> Pose3D? {
        let asked = clip.engine.currentTime
        let shown = clip.engine.player?.currentTime().seconds ?? asked
        guard var pose = clip.motion?.pose(at: shown.isFinite ? shown : asked) else { return nil }
        // Turned by the same amount all through: the way the body faces as its stretch starts goes to the
        // front, and how it turns after that is kept.
        if faceSame, let first = clip.motion?.motion?.poses.compactMap({ $0 }).first {
            pose = pose.turned(by: -first.facing)
        }
        return pose
    }

    /// How far a clip's body has moved across the floor since its stretch began, turned as its pose is.
    private func travel(_ clip: Clip) -> Vec3 {
        let asked = clip.engine.currentTime
        let shown = clip.engine.player?.currentTime().seconds ?? asked
        var moved = clip.motion?.travel(at: shown.isFinite ? shown : asked) ?? .zero
        if faceSame, let first = clip.motion?.motion?.poses.compactMap({ $0 }).first {
            moved = moved.turned(by: -first.facing)
        }
        return moved
    }

    private var figures: [StageFigure] {
        let items = loaded
        return items.map { item in
            let side = items.count > 1 && !together ? (item.index == 0 ? -0.7 : 0.7) : 0
            return StageFigure(id: item.index == 0 ? "A" : "B", pose: pose(item.clip), color: Self.colors[item.index],
                               offset: side, opacity: items.count > 1 && together && item.index == 1 ? 0.6 : 1,
                               shift: travels ? travel(item.clip) : .zero,
                               // The modelled mannequin (with hands and feet), posed from the tracking.
                               character: BodyCharacter.mannequin,
                               // The hand chosen for this clip grips (as round a handle); the other rests.
                               grip: grips[item.index])
        }
    }

    // MARK: Over the stage

    /// The views on the left, the options on the right: with their names where there's room, as icons
    /// where there isn't.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(named: true)
            controlRow(named: false)
        }
        .foregroundStyle(.white)
    }

    private func controlRow(named: Bool) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                view("Front", .front)
                view("Side", .side)
                view("Behind", .behind)
                view("Top", .top)
                view("¾", .threeQuarter)
            }
            .padding(2)
            .background(Color.black.opacity(0.45), in: Capsule())
            .fixedSize()
            Spacer(minLength: 0)
            if loaded.count > 1 {
                Button { withAnimation(.easeOut(duration: 0.2)) { together.toggle() } } label: {
                    Label(named ? (together ? "Together" : "Side by side") : "", systemImage: together ? "person.2.fill" : "person.2")
                }
                .buttonStyle(ChipStyle(active: together))
                .fixedSize()
                .help(together ? "One body stands in the other, to compare their shapes. Click to stand them side by side."
                      : "The bodies stand side by side. Click to stand one in the other.")
            }
            ForEach(loaded, id: \.index) { item in
                let grip = grips[item.index]
                Button {
                    grips[item.index] = grip == nil ? .left : grip == .left ? .right : nil
                } label: {
                    Label("\(item.index == 0 ? "A" : "B")\(grip == nil ? "" : grip == .left ? " L" : " R")", systemImage: "hand.raised.fingers.spread")
                }
                .buttonStyle(ChipStyle(active: grip != nil))
                .fixedSize()
                .help("Which hand grips in clip \(item.index == 0 ? "A" : "B") (holds the racket): its fingers close round a handle. Click for left, right, or neither.")
            }
            Button { travels.toggle() } label: { Label(named ? "Travel" : "", systemImage: "figure.walk") }
                .buttonStyle(ChipStyle(active: travels))
                .fixedSize()
                .help("Each body moves across the floor as it did in its video (an estimate, from one camera). Off: it stays on the spot, which compares shapes best.")
            Button { faceSame.toggle() } label: { Label(named ? "Face front" : "", systemImage: "arrow.triangle.merge") }
                .buttonStyle(ChipStyle(active: faceSame))
                .fixedSize()
                .help("Turn each body to face the front as its stretch starts, so clips filmed from different sides compare. Off: as the camera saw them.")
        }
    }

    private func view(_ name: String, _ preset: StageCamera) -> some View {
        let on = abs(camera.yaw - preset.yaw) < 0.01 && abs(camera.pitch - preset.pitch) < 0.01
        return Button {
            withAnimation(.easeOut(duration: 0.25)) { camera = StageCamera(yaw: preset.yaw, pitch: preset.pitch, distance: camera.distance) }
        } label: {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(on ? Theme.onAccent : Color.white.opacity(0.8))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(on ? Theme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Look at the bodies from here (or drag the stage to look round; pinch to come closer)")
    }

    /// The elbows' and knees' true angles (in space, not as flattened by the camera), each clip's.
    private var readings: some View {
        let angles: [BodyAngle] = [.rightElbow, .leftElbow, .rightKnee, .leftKnee]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(angles) { angle in
                HStack(spacing: 8) {
                    Text(angle.title).frame(width: 84, alignment: .leading).foregroundStyle(Theme.secondary)
                    ForEach(loaded, id: \.index) { item in
                        Text(pose(item.clip)?.degrees(angle).map { "\(Int($0.rounded()))°" } ?? "–")
                            .frame(width: 38, alignment: .trailing)
                            .foregroundStyle(Self.colors[item.index])
                    }
                }
            }
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .padding(8)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Each joint's angle in space, whatever side the camera filmed from")
    }

    /// While a body is being followed, how far along; or why there's none.
    @ViewBuilder private var status: some View {
        let lines: [String] = loaded.compactMap { item in
            let name = item.index == 0 ? "A" : "B"
            switch item.clip.motion?.state {
            case .preparing(let done)?: return "Finding \(name)'s body in 3D… \(Int(done * 100)) %"
            case .failed(let why)?: return "\(name): \(why)"
            default: return nil
            }
        }
        if !lines.isEmpty {
            VStack(spacing: 4) { ForEach(lines, id: \.self) { Text($0) } }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
        }
    }

    private func letter(_ index: Int) -> some View {
        Text(index == 0 ? "A" : "B")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Self.colors[index].opacity(index == 0 ? 1 : 0.85), in: Circle())
    }
}
