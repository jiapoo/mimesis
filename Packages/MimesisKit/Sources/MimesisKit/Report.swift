import AreteMedia
import AVFoundation
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A report to share: a PDF with, for each segment, its notes and timing, and its key frames (the
/// frames with drawings, pinned notes or sync points) from both clips, with the drawings on them, the
/// note, and the joint angle when the body has been measured.
@MainActor
enum Report {
    struct KeyFrame {
        let clip: Int
        let time: Double
        var labels: [String]
    }

    /// The key frames of one clip's share of a segment, in time order.
    static func keyFrames(_ part: Segment.Part, clip: Int) -> [KeyFrame] {
        var byTime: [Double: [String]] = [:]
        func add(_ time: Double, _ label: String) {
            // Within a hundredth of a second is the same frame.
            let key = (time * 100).rounded() / 100
            if !(byTime[key] ?? []).contains(label) { byTime[key, default: []].append(label) }
        }
        for (index, sync) in part.syncs.enumerated() { add(sync, "Sync \(index + 1)") }
        for drawing in part.drawings where !drawing.always && drawing.overlay != true { add(drawing.time, "Drawing") }
        for note in part.notes ?? [] { add(note.time, "“\(note.text)”") }
        return byTime.keys.sorted().prefix(24).map { KeyFrame(clip: clip, time: $0, labels: byTime[$0]!) }
    }

    /// Makes the PDF in a temporary folder and returns it.
    static func make(_ comparison: Comparison, title: String, progress: @escaping (Double) -> Void) async throws -> URL {
        comparison.storeSegment()
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(title) report.pdf")
        try? FileManager.default.removeItem(at: file)
        var box = page
        guard let context = CGContext(file as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }

        let margin: CGFloat = 40
        var y: CGFloat = 0
        func newPage() {
            if y > 0 { context.endPDFPage() }
            context.beginPDFPage(nil)
            // Draw from the top down.
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            y = margin
        }
        func room(_ height: CGFloat) { if y + height > page.height - margin { newPage() } }
        func text(_ string: String, size: CGFloat, bold: Bool = false, gray: CGFloat = 0, at x: CGFloat = margin, width: CGFloat? = nil) {
            let height = draw(string, in: context, at: CGPoint(x: x, y: y), width: width ?? page.width - margin - x,
                              size: size, bold: bold, gray: gray)
            y += height
        }

        let jobs = comparison.segments.flatMap { segment in
            segment.parts.enumerated().flatMap { index, part in keyFrames(part, clip: index) }
        }.count + comparison.segments.reduce(0) { $0 + ($1.snapshots?.count ?? 0) }
        var done = 0

        newPage()
        text(title, size: 22, bold: true)
        y += 2
        let names = comparison.clips.enumerated().filter { $0.element.isLoaded }
            .map { "\($0.offset == 0 ? "A" : "B"): \($0.element.name)" }.joined(separator: "     ")
        text("\(Date.now.formatted(date: .long, time: .omitted))     \(names)", size: 10, gray: 0.4)
        y += 14

        for (index, segment) in comparison.segments.enumerated() {
            room(120)
            text(segment.name, size: 16, bold: true)
            y += 2
            // Each clip's stretch and speed.
            for (at, part) in segment.parts.enumerated() where comparison.clips[at].isLoaded {
                let clip = comparison.clips[at]
                let end = part.trimEnd ?? clip.engine.duration
                var line = "\(at == 0 ? "A" : "B"): \(short(part.trimStart)) – \(short(end)) s (\(short(end - part.trimStart)) s)"
                for (number, sync) in part.syncs.enumerated() { line += "   sync \(number + 1) at +\(short(sync - part.trimStart)) s" }
                if let speed = part.speed { line += "   speed \(speedText(speed))" }
                text(line, size: 10, gray: 0.25)
            }
            if let notes = segment.notes, !notes.isEmpty {
                y += 4
                text(notes, size: 11)
            }
            y += 10

            // The key frames, two to a row.
            let frames = segment.parts.enumerated().flatMap { at, part in
                comparison.clips[at].isLoaded ? keyFrames(part, clip: at) : []
            }
            let width = (page.width - margin * 2 - 16) / 2
            var column = 0
            var rowHeight: CGFloat = 0
            var rowTop = y
            for frame in frames {
                let clip = comparison.clips[frame.clip]
                guard let url = clip.url else { continue }
                let part = segment.parts[frame.clip]
                let image = await picture(url: url, time: frame.time, mirrored: clip.engine.mirroredHorizontally,
                                          drawings: part.drawings, frameLength: clip.frameLength)
                done += 1
                progress(Double(done) / Double(max(1, jobs)))
                guard let image else { continue }
                let height = width * CGFloat(image.height) / CGFloat(max(1, image.width))
                let capped = min(height, 300)
                let shown = CGSize(width: capped * CGFloat(image.width) / CGFloat(max(1, image.height)), height: capped)
                if column == 0 {
                    room(shown.height + 46)
                    rowTop = y
                    rowHeight = 0
                }
                let x = margin + CGFloat(column) * (width + 16)
                // Images draw upright in a y-up space: flip around this one.
                context.saveGState()
                context.translateBy(x: x, y: rowTop + shown.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: shown))
                context.restoreGState()
                var caption = "\(frame.clip == 0 ? "A" : "B") · \(short(frame.time)) s · " + frame.labels.joined(separator: " · ")
                // The joint angle there, when this segment's body has been measured.
                if index == comparison.segmentIndex, let track = clip.poseTrack, track.state == .ready {
                    let size = clip.engine.videoSize
                    let aspect = size.height > 0 ? size.width / size.height : 1
                    if let degrees = track.pose(at: frame.time)?.angle(comparison.graphAngle, aspect: aspect) {
                        caption += " · \(comparison.graphAngle.title.lowercased()) \(Int(degrees.rounded()))°"
                    }
                }
                let captionHeight = draw(caption, in: context, at: CGPoint(x: x, y: rowTop + shown.height + 4), width: width,
                                         size: 9.5, bold: false, gray: 0.2)
                rowHeight = max(rowHeight, shown.height + 4 + captionHeight + 12)
                column += 1
                if column == 2 {
                    column = 0
                    y = rowTop + rowHeight
                }
            }
            if column != 0 { y = rowTop + rowHeight }
            // The snapshots: each the clips side by side as they were kept, across the page.
            let snapshots = segment.snapshots ?? []
            for (number, snapshot) in snapshots.enumerated() {
                let image = await picture(of: snapshot, in: segment, comparison: comparison)
                done += 1
                progress(Double(done) / Double(max(1, jobs)))
                guard let image else { continue }
                let full = page.width - margin * 2
                let height = min(360, full * CGFloat(image.height) / CGFloat(max(1, image.width)))
                let shown = CGSize(width: height * CGFloat(image.width) / CGFloat(max(1, image.height)), height: height)
                room(shown.height + 30)
                context.saveGState()
                context.translateBy(x: margin, y: y + shown.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: shown))
                context.restoreGState()
                y += shown.height + 4
                text("Snapshot \(number + 1) · \(snapshot.label)", size: 9.5, gray: 0.2)
                y += 12
            }
            if frames.isEmpty && snapshots.isEmpty {
                text("No key frames yet: add a sync point, a drawing or a note on a frame, or take a snapshot.", size: 10, gray: 0.5)
            }
            y += 16
        }
        context.endPDFPage()
        context.closePDF()
        return file
    }

    /// A snapshot's picture: the frame of each clip it kept, with that frame's drawings, side by side
    /// at one height (a single clip: that clip alone). No buttons, rings or timeline: only the pictures.
    static func picture(of snapshot: Snapshot, in segment: Segment, comparison: Comparison) async -> CGImage? {
        var frames: [CGImage] = []
        for (index, time) in snapshot.times.enumerated() {
            let clip = comparison.clips[index]
            guard let time, let url = clip.url else { continue }
            if let frame = await picture(url: url, time: time, mirrored: clip.engine.mirroredHorizontally,
                                         drawings: segment.parts[index].drawings, frameLength: clip.frameLength) {
                frames.append(frame)
            }
        }
        guard let first = frames.first else { return nil }
        guard frames.count > 1 else { return first }
        let height = frames.map(\.height).max() ?? first.height
        let gap = 4
        let widths = frames.map { Int((Double($0.width) * Double(height) / Double(max(1, $0.height))).rounded()) }
        let width = widths.reduce(0, +) + gap * (frames.count - 1)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return first }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for (frame, frameWidth) in zip(frames, widths) {
            context.draw(frame, in: CGRect(x: x, y: 0, width: frameWidth, height: height))
            x += frameWidth + gap
        }
        return context.makeImage()
    }

    /// A snapshot's picture as a PNG file's data.
    static func png(of snapshot: Snapshot, comparison: Comparison) async -> Data? {
        comparison.storeSegment()
        guard let image = await picture(of: snapshot, in: comparison.segment, comparison: comparison) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func short(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    /// A clip's frame at `time`, mirrored as shown, with the drawings of that frame on it.
    nonisolated static func picture(url: URL, time: Double, mirrored: Bool, drawings: [Drawing], frameLength: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        guard let frame = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image else { return nil }
        let size = CGSize(width: frame.width, height: frame.height)
        guard let context = CGContext(data: nil, width: frame.width, height: frame.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return frame }
        if mirrored {
            context.translateBy(x: size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.draw(frame, in: CGRect(origin: .zero, size: size))
        if mirrored {
            context.scaleBy(x: -1, y: 1)
            context.translateBy(x: -size.width, y: 0)
        }
        let shown = DrawingImage.visible(drawings.filter { $0.overlay != true }, at: time, frameLength: frameLength)
        if let marks = DrawingImage.image(shown, size: size, mirrored: mirrored) {
            context.draw(marks, in: CGRect(origin: .zero, size: size))
        }
        return context.makeImage()
    }

    /// Draws wrapped text with its top left at `point` in a top-down context; returns its height.
    private static func draw(_ string: String, in context: CGContext, at point: CGPoint, width: CGFloat,
                             size: CGFloat, bold: Bool, gray: CGFloat) -> CGFloat {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: 2000), nil)
        let height = ceil(fit.height) + 2
        context.saveGState()
        // Text lays out in a y-up space: flip around its box.
        context.translateBy(x: point.x, y: point.y + height)
        context.scaleBy(x: 1, y: -1)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return height
    }
}

/// Make the report, watch it being put together, then share or save it.
struct ReportView: View {
    let comparison: Comparison
    let title: String
    @State private var progress: Double?
    @State private var file: URL?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Report").font(.title2.weight(.semibold))
            Text("A PDF to share: each segment with its notes and timing, its key frames (those with a sync point, a drawing or a pinned note) from both clips, with the drawings on them, and its snapshots.")
                .font(.callout).foregroundStyle(.secondary)
            if let progress {
                ProgressView(value: progress) { Text("Putting it together… \(Int(progress * 100)) %") }
            } else if let file {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
            } else if let problem {
                Text(problem).foregroundStyle(.red)
            }
            HStack {
                Button("Close") { dismiss() }.help("Close the report")
                Spacer()
                if let file {
                    #if os(macOS)
                    ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { saveAs(file) } label: { Label("Save as…", systemImage: "square.and.arrow.down") }
                        .help("Choose where to save the PDF, and its name")
                        .buttonStyle(.borderedProminent)
                    #else
                    ShareLink(item: file) { Label("Share or save", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    #endif
                } else {
                    Button("Make the report") { make() }
                        .help("A PDF of every segment: its marked frames, drawings, angles and notes")
                        .buttonStyle(.borderedProminent)
                        .disabled(progress != nil)
                }
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .themedSheet(width: 440)
        .presentationDetents([.medium, .large])
    }

    private func make() {
        progress = 0
        problem = nil
        Task {
            do {
                file = try await Report.make(comparison, title: title) { progress = $0 }
            } catch {
                problem = "Couldn't make the report: \(error.localizedDescription)"
            }
            progress = nil
        }
    }

    #if os(macOS)
    private func saveAs(_ file: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = file.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.copyItem(at: file, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            dismiss()
        } catch {
            problem = "Couldn't save the report: \(error.localizedDescription)"
        }
    }
    #endif
}

/// A picture to save as a file (a snapshot).
struct PictureFile: FileDocument {
    static let readableContentTypes: [UTType] = [.png]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
