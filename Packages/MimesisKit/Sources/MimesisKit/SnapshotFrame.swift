import AreteMedia
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// A snapshot in two clicks: the first puts a box over the clips (all of them, A and B, a little in from
// the edges), to drag bigger, smaller or elsewhere by its eight handles; the second keeps what's inside
// the box, exactly as it is on screen.

extension EnvironmentValues {
    /// Set while a snapshot is being made: each clip's frame on screen as a picture, shown in place of
    /// its player (a video's own view can't be drawn into a picture).
    @Entry var stills: SnapshotStills?
    /// Only the pictures, with what's drawn on them: no letters, times, buttons or focus ring. Set while
    /// the snapshot's box is up (so what's in the box is what's kept), and while it's taken.
    @Entry var cleanPicture = false
}

/// The frames on screen as pictures, by clip.
struct SnapshotStills {
    var frames: [ObjectIdentifier: CGImage] = [:]
    var cutouts: [ObjectIdentifier: CGImage] = [:]
}

/// A clip's video: its player, or, while a snapshot is made, the frame it shows as a picture, fitted the
/// same way.
struct ClipPicture: View {
    let clip: Clip
    @Environment(\.stills) private var stills

    var body: some View {
        if let stills {
            if let frame = stills.frames[ObjectIdentifier(clip)] {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black
            }
        } else {
            VideoPlayerRepresentable(player: clip.engine.player)
        }
    }
}

/// The snapshot's box over the clips: the rest dimmed, a dashed outline and eight handles. Drag a
/// handle to resize it, inside to move it, outside to draw a new one.
struct SnapshotFrame: View {
    @Binding var box: CGRect
    let area: CGSize

    @State private var start: CGRect?
    @State private var handle: BoxHandle?
    @State private var drawingNew = false
    #if os(macOS)
    @State private var pointer: PointerStyle?
    #endif

    /// Never smaller than this across or down.
    private let smallest: CGFloat = 40

    var body: some View {
        ZStack {
            // Dim what's left out.
            Path { path in
                path.addRect(CGRect(origin: .zero, size: area))
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            SelectionBox(box, handleSize: 11)
            // Its size, in the box's top left corner (or under it, where there's no room).
            Text("\(Int(box.width.rounded())) × \(Int(box.height.rounded()))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
                .fixedSize()
                .position(x: box.minX + 44, y: box.minY > 30 ? box.minY - 16 : box.minY + 18)
                .allowsHitTesting(false)
        }
        .frame(width: area.width, height: area.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if start == nil {
                        start = box
                        handle = BoxHandle.at(drag.startLocation, in: box, grab: 18)
                        drawingNew = handle == nil && !box.contains(drag.startLocation)
                    }
                    guard let start else { return }
                    let at = clamp(drag.location)
                    if let handle {
                        box = handle.resize(start, to: at, minimum: smallest)
                    } else if drawingNew {
                        let from = clamp(drag.startLocation)
                        guard hypot(at.x - from.x, at.y - from.y) > 4 else { return }
                        box = CGRect(x: min(from.x, at.x), y: min(from.y, at.y),
                                     width: max(smallest, abs(at.x - from.x)), height: max(smallest, abs(at.y - from.y)))
                    } else {
                        var moved = start.offsetBy(dx: drag.translation.width, dy: drag.translation.height)
                        moved.origin.x = min(max(0, moved.minX), area.width - moved.width)
                        moved.origin.y = min(max(0, moved.minY), area.height - moved.height)
                        box = moved
                    }
                    box = fitted(box)
                }
                .onEnded { _ in start = nil; handle = nil; drawingNew = false })
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let at):
                if let handle = BoxHandle.at(at, in: box, grab: 18) { pointer = handle.pointer }
                else if box.contains(at) { pointer = .grabIdle }
                else { pointer = .rectSelection }
            case .ended:
                pointer = nil
            }
        }
        .pointerStyle(pointer)
        #endif
        .onChange(of: area) { _, _ in box = fitted(box) }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), area.width), y: min(max(0, point.y), area.height))
    }

    /// Inside the clips, whatever the window does.
    private func fitted(_ rect: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: area)
        let inside = rect.intersection(bounds)
        return inside.isNull ? SnapshotFrame.start(in: area) : inside
    }

    /// The box kept last time ("x y width height", shares of the area), fitted to the area now; nil
    /// if there's none, or it's too small to use.
    static func remembered(_ text: String, in area: CGSize) -> CGRect? {
        let values = text.split(separator: " ").compactMap { Double($0) }
        guard values.count == 4 else { return nil }
        let box = CGRect(x: values[0] * area.width, y: values[1] * area.height,
                         width: values[2] * area.width, height: values[3] * area.height)
            .intersection(CGRect(origin: .zero, size: area))
        guard !box.isNull, box.width >= 40, box.height >= 40 else { return nil }
        return box
    }

    /// `box` as shares of `area`, to remember.
    static func shares(of box: CGRect, in area: CGSize) -> String {
        guard area.width > 0, area.height > 0 else { return "" }
        return [box.minX / area.width, box.minY / area.height, box.width / area.width, box.height / area.height]
            .map { String(format: "%.4f", $0) }.joined(separator: " ")
    }

    /// Where the box starts the first time: all of the clips, a little in from their edges so its handles are easy
    /// to reach.
    static func start(in area: CGSize) -> CGRect {
        let inset = min(28, min(area.width, area.height) / 8)
        return CGRect(origin: .zero, size: area).insetBy(dx: inset, dy: inset)
    }
}

// MARK: - Taking it

@MainActor
enum SnapshotCapture {
    /// Each clip's frame on screen now, as a picture: mirrored as shown, at the video's own size (up to
    /// 4K across), and the top clip's cutout as it's drawn.
    static func stills(of comparison: Comparison) async -> SnapshotStills {
        var stills = SnapshotStills()
        for clip in comparison.clips where clip.isLoaded {
            guard let item = clip.engine.playerItem else { continue }
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.appliesPreferredTrackTransform = true
            generator.videoComposition = item.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 3840, height: 3840)
            let time = item.currentTime()
            if let frame = try? await generator.image(at: time.isValid ? time : .zero).image {
                stills.frames[ObjectIdentifier(clip)] = frame
            }
            if let cutout = clip.cutout, cutout.state == .ready, cutout.enabled,
               let image = cutout.renderer.frame(cutout: cutout, mirrored: clip.engine.mirroredHorizontally) {
                stills.cutouts[ObjectIdentifier(clip)] = image
            }
        }
        return stills
    }

    /// `picture` (the clips as laid out on screen, `size` across and down) drawn into an image at the
    /// screen's `scale`, then cut to `box`: what was inside the box, exactly. As JPEG data, to keep.
    static func take<Picture: View>(_ picture: Picture, size: CGSize, box: CGRect, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: picture.frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.isOpaque = true
        guard let whole = renderer.cgImage else { return nil }
        let cut = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: whole.width, height: whole.height))
        guard !cut.isNull, let image = whole.cropping(to: cut) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension Snapshot {
    /// The picture kept with it (the box's contents), if it has one.
    var cgImage: CGImage? {
        guard let image,
              let source = CGImageSourceCreateWithData(image as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
