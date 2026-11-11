import AVFoundation
import SwiftUI

/// The workspace for segments, down the left side (a panel that slides in on an iPhone): the list of
/// segments, and for the chosen one each clip's In/Out, sync points and speed, the frames that have
/// drawings, and notes.
struct SegmentSidebar: View {
    let comparison: Comparison
    var onClose: (() -> Void)?

    @State private var renaming: Segment.ID?
    @State private var name = ""
    /// The note being written or changed: its clip, its id when it exists already.
    @State private var noting: (clip: Int, id: UUID?)?
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    segments
                    if comparison.clips.contains(where: \.isLoaded) {
                        clips
                        AngleGraph(comparison: comparison)
                        drawings
                        pinned
                        notes
                    }
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .foregroundStyle(.white)
        .alert("Rename segment", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Take 1, Slow part…", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let name = name.trimmingCharacters(in: .whitespaces)
                if let renaming, !name.isEmpty { comparison.renameSegment(renaming, to: name) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Segments").font(.system(size: 13, weight: .bold))
            Spacer()
            RoundButton(symbol: "plus", size: 26) { comparison.addSegment() }
                .help("New segment: another stretch of the two clips, with its own In/Out, sync points, speeds and drawings")
            if let onClose {
                RoundButton(symbol: "sidebar.left", size: 26, action: onClose)
                    .help("Hide the segments")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    // MARK: The list

    private var segments: some View {
        VStack(spacing: 4) {
            ForEach(Array(comparison.segments.enumerated()), id: \.element.id) { index, segment in
                let on = index == comparison.segmentIndex
                Button { comparison.selectSegment(index) } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(on ? Theme.onAccent : Theme.secondary)
                            .frame(width: 20, height: 20)
                            .background(on ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                        Text(segment.name)
                            .font(.system(size: 13, weight: on ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        let count = comparison.drawingCount(in: index)
                        if count > 0 {
                            Label("\(count)", systemImage: "pencil.tip")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                        if let length = comparison.length(of: index) {
                            Text(clock(length))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(on ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose this segment: both clips go to its start")
                .contextMenu {
                    Button("Rename…", systemImage: "pencil") {
                        name = segment.name
                        renaming = segment.id
                    }
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        comparison.selectSegment(index)
                        comparison.duplicateSegment()
                    }
                    if index > 0 {
                        Button("Move up", systemImage: "arrow.up") { comparison.moveSegment(index, by: -1) }
                    }
                    if index < comparison.segments.count - 1 {
                        Button("Move down", systemImage: "arrow.down") { comparison.moveSegment(index, by: 1) }
                    }
                    Divider()
                    Button(comparison.segments.count > 1 ? "Delete" : "Clear", systemImage: "trash", role: .destructive) {
                        comparison.selectSegment(index)
                        comparison.deleteSegment()
                    }
                }
            }
            HStack(spacing: 6) {
                Button("Rename") {
                    name = comparison.segment.name
                    renaming = comparison.segment.id
                }
                Button("Duplicate") { comparison.duplicateSegment() }
                Button(comparison.segments.count > 1 ? "Delete" : "Clear") { comparison.deleteSegment() }
            }
            .buttonStyle(ChipStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    // MARK: Each clip's share

    private var clips: some View {
        VStack(alignment: .leading, spacing: 10) {
            title("In, Out, sync and speed")
            ForEach(0..<2, id: \.self) { index in
                let clip = comparison.clips[index]
                if clip.isLoaded {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(index == 0 ? "A" : "B")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 20, height: 20)
                                .background(Color.white.opacity(0.18), in: Circle())
                            Text(span(clip))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.secondary)
                        }
                        // Each acts at that clip's own playhead.
                        ScrollView(.horizontal, showsIndicators: false) {
                            ClipTools(clip: clip, comparison: comparison)
                        }
                    }
                }
            }
            if comparison.linked {
                Text("Linked: choose A or B to move its In, Out or sync points.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
    }

    /// "0.57 – 1.27 s · 0.70 s"
    private func span(_ clip: Clip) -> String {
        let start = clip.trimStart, end = clip.end
        guard clip.trimStart > 0 || clip.trimEnd != nil else { return "whole clip · \(clock(end))" }
        let short = { (v: Double) in v.formatted(.number.precision(.fractionLength(2))) }
        return "\(short(start)) – \(short(end)) s · \(clock(end - start))"
    }

    // MARK: Drawings

    private var drawings: some View {
        let frames = comparison.drawnFrames
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                title("Drawings")
                Spacer()
                if frames.count > 1 {
                    RoundButton(symbol: "chevron.left", size: 24) { comparison.goToDrawing(next: false) }
                        .help("The frame with drawings before this one")
                    RoundButton(symbol: "chevron.right", size: 24) { comparison.goToDrawing(next: true) }
                        .help("The next frame with drawings")
                }
            }
            if frames.isEmpty {
                Text("None in this segment yet. Draw with ✏ on a clip.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            } else {
                ForEach(frames) { frame in
                    Button { comparison.go(to: frame) } label: {
                        HStack(spacing: 8) {
                            FrameThumb(url: comparison.clips[frame.clip].url, time: frame.time)
                                .frame(width: 64, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(frame.clip == 0 ? "A" : "B") · \(frame.everyFrame ? "every frame" : clock(frame.time))\(frame.overlay ? " · overlay" : "")")
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                HStack(spacing: 3) {
                                    ForEach(Array(frame.colors.prefix(6).enumerated()), id: \.offset) { _, color in
                                        Circle().fill(color.solid.color).frame(width: 7, height: 7)
                                    }
                                    Text("\(frame.count)").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(4)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to this frame")
                    .contextMenu {
                        Button("Delete these drawings", systemImage: "trash", role: .destructive) { comparison.delete(frame) }
                    }
                }
            }
        }
    }

    // MARK: Notes pinned to frames

    private var pinned: some View {
        let index = comparison.clips.firstIndex { $0 === comparison.focused } ?? 0
        let all: [(clip: Int, note: FrameNote)] = comparison.clips.enumerated()
            .flatMap { at, clip in clip.notes.map { (clip: at, note: $0) } }
            .sorted { ($0.clip, $0.note.time) < ($1.clip, $1.note.time) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                title("Notes on frames")
                Spacer()
                Button {
                    noteText = ""
                    noting = (index, nil)
                } label: {
                    Label("\(index == 0 ? "A" : "B") here", systemImage: "plus")
                }
                .buttonStyle(ChipStyle())
                .help("Pin a note to the frame clip \(index == 0 ? "A" : "B") is showing: it appears over the clip around that moment, and in exported videos")
            }
            ForEach(all, id: \.note.id) { item in
                Button {
                    comparison.go(to: DrawnFrame(clip: item.clip, time: item.note.time, everyFrame: false, overlay: false,
                                                 count: 0, colors: [], ids: []))
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(item.clip == 0 ? "A" : "B") \(clock(item.note.time))")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.2))
                        Text(item.note.text).font(.system(size: 12)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go to this frame")
                .contextMenu {
                    Button("Change…", systemImage: "pencil") {
                        noteText = item.note.text
                        noting = (item.clip, item.note.id)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        comparison.clips[item.clip].notes.removeAll { $0.id == item.note.id }
                    }
                }
            }
        }
        .alert(noting?.id == nil ? "Note on this frame" : "Change the note",
               isPresented: Binding(get: { noting != nil }, set: { if !$0 { noting = nil } })) {
            TextField("What to notice here", text: $noteText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                guard let noting else { return }
                let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                let clip = comparison.clips[noting.clip]
                if let id = noting.id, let at = clip.notes.firstIndex(where: { $0.id == id }) {
                    if text.isEmpty { clip.notes.remove(at: at) } else { clip.notes[at].text = text }
                } else if !text.isEmpty {
                    clip.notes.append(FrameNote(time: clip.engine.currentTime, text: text))
                    clip.notes.sort { $0.time < $1.time }
                }
            }
        }
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            title("About this segment")
            TextField("What to look at in this segment", text: Binding(
                get: { comparison.segment.notes ?? "" },
                set: { comparison.setNotes($0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(3...10)
                .padding(8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func title(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(Theme.secondary)
    }
}

/// A small picture of one frame of a video.
struct FrameThumb: View {
    let url: URL?
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .task(id: "\(url?.path ?? "")-\(time)") {
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 200, height: 200)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            image = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image
        }
    }
}

// MARK: - What the sidebar asks of a comparison

/// A frame of a clip that has drawings, in the chosen segment.
struct DrawnFrame: Identifiable {
    let clip: Int
    let time: Double
    let everyFrame: Bool
    let overlay: Bool
    let count: Int
    let colors: [Drawing.RGBA]
    let ids: Set<UUID>
    var id: String { "\(clip)-\(time)-\(everyFrame)-\(overlay)" }
}

extension Comparison {
    func renameSegment(_ id: Segment.ID, to name: String) {
        guard let at = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[at].name = name
    }

    func setNotes(_ notes: String) {
        segments[segmentIndex].notes = notes.isEmpty ? nil : notes
    }

    func moveSegment(_ index: Int, by step: Int) {
        let target = index + step
        guard segments.indices.contains(index), segments.indices.contains(target) else { return }
        storeSegment()
        let chosen = segments[segmentIndex].id
        segments.swapAt(index, target)
        segmentIndex = segments.firstIndex { $0.id == chosen } ?? segmentIndex
    }

    /// How many drawings a segment has (the chosen one's are on the clips).
    func drawingCount(in index: Int) -> Int {
        if index == segmentIndex { return clips.reduce(0) { $0 + $1.drawings.count } }
        return segments[index].parts.reduce(0) { $0 + $1.drawings.count }
    }

    /// How long a segment lasts on screen: its longer stretch, once a clip has an In or Out.
    func length(of index: Int) -> Double? {
        var lengths: [Double] = []
        for (at, clip) in clips.enumerated() where clip.isLoaded {
            let start = index == segmentIndex ? clip.trimStart : segments[index].parts[at].trimStart
            let end = index == segmentIndex ? clip.trimEnd : segments[index].parts[at].trimEnd
            guard start > 0 || end != nil else { continue }
            lengths.append((end ?? clip.engine.duration) - start)
        }
        return lengths.max()
    }

    /// The frames with drawings in the chosen segment, clip A's first, in time order.
    var drawnFrames: [DrawnFrame] {
        var frames: [DrawnFrame] = []
        for (index, clip) in clips.enumerated() {
            let groups = Dictionary(grouping: clip.drawings) { drawing in
                "\(drawing.always ? -1 : (drawing.time / clip.frameLength).rounded())|\(drawing.overlay == true)"
            }
            for group in groups.values {
                guard let first = group.first else { continue }
                frames.append(DrawnFrame(
                    clip: index, time: first.time, everyFrame: first.always, overlay: first.overlay == true,
                    count: group.count, colors: group.map(\.resolvedColor), ids: Set(group.map(\.id))))
            }
        }
        return frames.sorted { ($0.clip, $0.time) < ($1.clip, $1.time) }
    }

    /// Shows a frame that has drawings: its clip chosen (linked, both clips move), where it was drawn
    /// (the overlay for drawings made there).
    func go(to frame: DrawnFrame) {
        let clip = clips[frame.clip]
        if frame.overlay, canLink { layout = .overlay } else if layout == .overlay { layout = .both }
        if linked {
            pause()
            Task { await seek(to: linkedTime(of: clip, at: frame.time)) }
        } else {
            if layout == .left || layout == .right { layout = frame.clip == 0 ? .left : .right }
            focus = frame.clip
            clip.engine.pause()
            Task { await clip.engine.seekToTime(frame.time) }
        }
    }

    /// The next (or previous) frame with drawings on the chosen clip, round and round.
    func goToDrawing(next: Bool) {
        let index = clips.firstIndex { $0 === focused } ?? 0
        let own = drawnFrames.filter { $0.clip == index && !$0.everyFrame }
        let frames = own.isEmpty ? drawnFrames.filter { !$0.everyFrame } : own
        guard !frames.isEmpty else { return }
        let now = clips[frames[0].clip].engine.currentTime, half = clips[frames[0].clip].frameLength / 2
        let target = next
            ? frames.first { $0.clip == frames[0].clip && $0.time > now + half } ?? frames.first!
            : frames.last { $0.clip == frames[0].clip && $0.time < now - half } ?? frames.last!
        go(to: target)
    }

    func delete(_ frame: DrawnFrame) {
        clips[frame.clip].drawings.removeAll { frame.ids.contains($0.id) }
    }
}
