import AreteMedia
import AVFoundation
import SwiftUI

/// The workspace for segments, down the left side (a panel that slides in on an iPhone): the list of
/// segments, and for the chosen one each clip's In/Out, sync points and speed, the body's angles, the
/// frames that have drawings, the takes, and notes. Names and notes are edited in place: double-click.
struct SegmentSidebar: View {
    let comparison: Comparison
    var onClose: (() -> Void)?
    /// Choose another video to add to a clip (0 or 1) as a take.
    var onAddTake: (Int) -> Void = { _ in }

    /// What's being typed into, in place.
    private enum Field: Hashable {
        case segment(UUID), note(UUID), about
    }

    @FocusState private var field: Field?
    /// The text being edited, and what it's for (nil: nothing is being edited).
    @State private var editing: Field?
    @State private var text = ""
    @State private var speedFor: Int?
    /// A snapshot's picture, ready to save as a file.
    @State private var saving: PictureFile?
    @State private var savingName = "Snapshot"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    segments
                    if comparison.clips.contains(where: \.isLoaded) {
                        clips
                        AngleGraph(comparison: comparison)
                        drawings
                        snapshots
                        pinned
                        about
                        takes
                    }
                }
                .padding(12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.card)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
        .foregroundStyle(.white)
        // While typing here, the letter keys and Space type: they don't play, link or mark.
        .onChange(of: editing) { _, now in comparison.typing = now != nil }
        .onChange(of: field) { _, now in
            // Clicking away from the field ends the edit, keeping what was typed.
            if now == nil, editing != nil { commit() }
        }
        .onDisappear { comparison.typing = false }
        .fileExporter(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
                      document: saving, contentType: .png, defaultFilename: savingName) { _ in saving = nil }
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

    // MARK: Editing in place

    private func edit(_ what: Field, _ current: String) {
        if editing != nil { commit() }
        text = current
        editing = what
        field = what
    }

    private func commit() {
        guard let what = editing else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch what {
        case .segment(let id):
            if !typed.isEmpty { comparison.renameSegment(id, to: typed) }
        case .note(let id):
            for clip in comparison.clips {
                guard let at = clip.notes.firstIndex(where: { $0.id == id }) else { continue }
                // A note left empty is removed.
                if typed.isEmpty { clip.notes.remove(at: at) } else { clip.notes[at].text = typed }
            }
        case .about:
            comparison.setNotes(typed)
        }
        editing = nil
        field = nil
    }

    private func cancel() {
        // A note just added and never written goes.
        if case .note(let id)? = editing {
            for clip in comparison.clips { clip.notes.removeAll { $0.id == id && $0.text.isEmpty } }
        }
        editing = nil
        field = nil
    }

    /// A one-line field for the text being edited, in a dark well with a crimson edge so it reads as
    /// "being written": Return or a click anywhere else keeps it and goes back to reading, Esc leaves
    /// it as it was.
    private func inlineField(_ what: Field, prompt: String, size: CGFloat = 13) -> some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .focused($field, equals: what)
            .onSubmit { commit() }
            #if os(macOS)
            .onExitCommand { cancel() }
            #endif
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
    }

    /// A click on something else in the panel finishes what's being written first.
    private func leaveField() {
        if editing != nil { commit() }
    }

    // MARK: The list

    private var segments: some View {
        VStack(spacing: 4) {
            ForEach(Array(comparison.segments.enumerated()), id: \.element.id) { index, segment in
                let on = index == comparison.segmentIndex
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(on ? Theme.onAccent : Theme.secondary)
                        .frame(width: 20, height: 20)
                        .background(on ? Theme.accent : Color.white.opacity(0.08), in: Circle())
                    if editing == .segment(segment.id) {
                        inlineField(.segment(segment.id), prompt: "Name")
                    } else {
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
                }
                .padding(.horizontal, 8)
                .frame(height: 34)
                .background(on ? Color.white.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                // Double-click the name to rename it; one click chooses the segment.
                .onTapGesture(count: 2) { edit(.segment(segment.id), segment.name) }
                .onTapGesture {
                    leaveField()
                    comparison.selectSegment(index)
                }
                .help("Click to choose this segment; double-click to rename it; right-click for more")
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { edit(.segment(segment.id), segment.name) }
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
        }
    }

    // MARK: Each clip's share

    /// One card per clip: In, Out, sync and speed side by side, each a name over its value. Tap In or Out
    /// to set it at that clip's playhead (its ✕ clears it), Sync to add or remove a sync point there,
    /// Speed for its slider.
    private var clips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2, id: \.self) { index in
                let clip = comparison.clips[index]
                if clip.isLoaded { card(index, clip) }
            }
            if comparison.linked {
                Text("Linked: choose A or B to change In, Out or sync points.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func card(_ index: Int, _ clip: Clip) -> some View {
        let short = { (v: Double) in v.formatted(.number.precision(.fractionLength(2))) }
        let speed = comparison.speed(of: clip)
        let locked = comparison.linked
        return HStack(spacing: 0) {
            Text(index == 0 ? "A" : "B")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(comparison.selected === clip ? Theme.onAccent : .white)
                .frame(width: 24, height: 24)
                .background(comparison.selected === clip ? Theme.accent : Color.white.opacity(0.14), in: Circle())
                .padding(.horizontal, 8)
            cell("In", clip.trimStart > 0 ? short(clip.trimStart) : "start", set: clip.trimStart > 0,
                 help: "Start clip \(index == 0 ? "A" : "B") here, at its playhead ([)",
                 clear: clip.trimStart > 0 ? { clip.clearTrimStart() } : nil) { clip.setTrimStart() }
                .disabled(locked)
            line
            cell("Out", clip.trimEnd.map(short) ?? "end", set: clip.trimEnd != nil,
                 help: "End clip \(index == 0 ? "A" : "B") here, at its playhead (])",
                 clear: clip.trimEnd != nil ? { clip.clearTrimEnd() } : nil) { clip.setTrimEnd() }
                .disabled(locked)
            line
            cell("Sync", clip.syncHere != nil ? "remove" : (clip.syncs.isEmpty ? "add" : "\(clip.syncs.count) · add"),
                 set: clip.syncHere != nil,
                 help: "Add a sync point at clip \(index == 0 ? "A" : "B")'s playhead, or remove the one there (S)",
                 clear: nil) { clip.toggleSync() }
                .disabled(locked)
            line
            cell("Speed", speedText((speed * 100).rounded() / 100) + (clip.speed == nil ? "" : " ✎"), set: clip.speed != nil,
                 help: clip.speed == nil ? "Automatic: matched to the other clip. Tap to set it yourself." : "Set by hand. Tap, then Auto, to match the other clip again.",
                 clear: clip.speed != nil ? { clip.speed = nil } : nil) { speedFor = index }
                .popover(isPresented: Binding(get: { speedFor == index }, set: { if !$0 { speedFor = nil } }), arrowEdge: .trailing) {
                    VStack(spacing: 8) {
                        VerticalSpeedSlider(speed: Float(speed), accent: Theme.accent) { clip.speed = Double($0) }
                        Button("Auto") { clip.speed = nil }
                            .buttonStyle(ChipStyle(active: clip.speed == nil))
                            .help("The speed that matches the other clip")
                    }
                    .padding(8)
                    .presentationCompactAdaptation(.popover)
                }
        }
        .frame(height: 46)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .contentShape(Rectangle())
    }

    private var line: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 26)
    }

    /// One value of a clip's card: its name over the value, the whole cell a button; set by hand it
    /// shows in the accent, with an ✕ in the corner to clear it.
    private func cell(_ name: String, _ value: String, set: Bool, help: String, clear: (() -> Void)?,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(name.uppercased())
                    .font(.system(size: 8.5, weight: .bold)).kerning(0.5)
                    .foregroundStyle(Theme.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(set ? Theme.accent : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .overlay(alignment: .topTrailing) {
            if let clear {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 14, height: 14)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .padding(2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear \(name)")
            }
        }
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

    // MARK: Snapshots

    /// The moments kept with 📷: tap one to see its frames again (and draw some more); save it as a
    /// picture; they're the report's key frames.
    @ViewBuilder private var snapshots: some View {
        let kept = comparison.segment.snapshots ?? []
        if !kept.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                title("Snapshots")
                ForEach(Array(kept.enumerated()), id: \.element.id) { number, snapshot in
                    HStack(spacing: 8) {
                        Group {
                            // Its picture, as it was in the box; an older one's frames side by side.
                            if let image = snapshot.cgImage {
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 40)
                                    .clipped()
                            } else {
                                HStack(spacing: 1) {
                                    ForEach(Array(snapshot.times.enumerated()), id: \.offset) { index, time in
                                        if let time {
                                            FrameThumb(url: comparison.clips[index].url, time: time)
                                                .frame(width: snapshot.times.compactMap { $0 }.count > 1 ? 40 : 64, height: 40)
                                                .clipped()
                                        }
                                    }
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Snapshot \(number + 1)").font(.system(size: 12, weight: .medium))
                            Text(snapshot.label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { save(snapshot, number: number + 1) } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Save this snapshot as a picture: what was inside its box")
                        Button { comparison.deleteSnapshot(snapshot.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.12), in: Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this snapshot (the drawings on its frames stay)")
                    }
                    .padding(4)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        leaveField()
                        comparison.go(to: snapshot)
                    }
                    .help("Go back to these frames, to look or to draw some more")
                }
            }
        }
    }

    private func save(_ snapshot: Snapshot, number: Int) {
        Task {
            guard let data = await Report.png(of: snapshot, comparison: comparison) else { return }
            savingName = "\(comparison.segment.name) snapshot \(number)"
            saving = PictureFile(data: data)
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
                    // A new note on the frame the clip shows, written right here.
                    let clip = comparison.clips[index]
                    let note = FrameNote(time: clip.engine.currentTime, text: "")
                    clip.notes.append(note)
                    clip.notes.sort { $0.time < $1.time }
                    edit(.note(note.id), "")
                } label: {
                    Label("\(index == 0 ? "A" : "B") here", systemImage: "plus")
                }
                .buttonStyle(ChipStyle())
                .help("Pin a note to the frame clip \(index == 0 ? "A" : "B") is showing: it appears over the clip around that moment, and in exported videos")
            }
            ForEach(all, id: \.note.id) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(item.clip == 0 ? "A" : "B") \(clock(item.note.time))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.2))
                    if editing == .note(item.note.id) {
                        inlineField(.note(item.note.id), prompt: "What to notice here", size: 12)
                    } else {
                        Text(item.note.text).font(.system(size: 12)).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, editing == .note(item.note.id) ? 4 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                // Double-click to change it; one click goes to its frame.
                .onTapGesture(count: 2) { edit(.note(item.note.id), item.note.text) }
                .onTapGesture {
                    leaveField()
                    comparison.go(to: DrawnFrame(clip: item.clip, time: item.note.time, everyFrame: false, overlay: false,
                                                 count: 0, colors: [], ids: []))
                }
                .help("Click to go to this frame; double-click to change the note")
                .contextMenu {
                    Button("Change", systemImage: "pencil") { edit(.note(item.note.id), item.note.text) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        comparison.clips[item.clip].notes.removeAll { $0.id == item.note.id }
                    }
                }
            }
        }
    }

    // MARK: About the segment

    /// A longer note for the whole segment: read as text; double-click to write, Done to finish.
    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                title("About this segment")
                Spacer()
                if editing == .about {
                    Button("Done") { commit() }
                        .buttonStyle(ChipStyle(active: true))
                        .help("Finish writing (or click anywhere else; Esc leaves it as it was)")
                }
            }
            if editing == .about {
                TextField("What to look at in this segment", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(3...12)
                    .focused($field, equals: .about)
                    #if os(macOS)
                    .onExitCommand { cancel() }
                    #endif
                    .padding(8)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(0.8)))
            } else {
                let written = comparison.segment.notes ?? ""
                Text(written.isEmpty ? "Double-click to write what to look at in this segment." : written)
                    .font(.system(size: 12))
                    .foregroundStyle(written.isEmpty ? Theme.secondary : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { edit(.about, written) }
                    .help("Double-click to write")
            }
        }
    }

    // MARK: Takes (progress over time)

    private var takes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title("Takes over time")
                Spacer()
                ForEach(0..<2, id: \.self) { index in
                    if comparison.clips[index].isLoaded {
                        Button { onAddTake(index) } label: { Label(index == 0 ? "A" : "B", systemImage: "plus") }
                            .buttonStyle(ChipStyle())
                            .help("Add the same movement filmed another day to clip \(index == 0 ? "A" : "B"). Each take keeps its own In/Out, sync points and drawings, against the same other clip.")
                    }
                }
            }
            let any = comparison.takes.contains { !$0.isEmpty }
            if !any {
                Text("Add another video of the same movement to a clip to compare days.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            ForEach(0..<2, id: \.self) { index in
                ForEach(Array(comparison.takes[index].enumerated()), id: \.element.id) { at, take in
                    let on = at == comparison.takeIndex[index]
                    HStack(spacing: 8) {
                        Text(index == 0 ? "A" : "B")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(on ? Theme.accent : Color.white.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(take.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 12, weight: on ? .semibold : .regular).monospacedDigit())
                            Text(take.name).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { Task { await comparison.removeTake(at, in: index) } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.12), in: Circle())
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this take from the list (its video file isn't deleted)")
                    }
                    .padding(.horizontal, 8).frame(height: 36)
                    .background(on ? Color.white.opacity(0.10) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await comparison.selectTake(at, in: index) } }
                    .help("Show this take in clip \(index == 0 ? "A" : "B"), as it was left")
                }
            }
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
