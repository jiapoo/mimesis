import SwiftUI

/// Every clip opened, with its notes and tagged moments. Filter by a tag to see that moment across all
/// clips ("every backhand"); tap a moment to open its clip there, as A or B.
struct LibraryView: View {
    let library: Library
    /// Open this clip as A (0) or B (1), at this time.
    let onOpen: (URL, Int, Double?) -> Void
    /// Play every moment with this tag back to back.
    let onPlayAll: (String) -> Void

    @State private var filter: String?
    @State private var missing: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.clips.isEmpty {
                    ContentUnavailableView(
                        "No clips yet", systemImage: "books.vertical",
                        description: Text("Every clip you open is kept here. Tag moments with the tag button on a clip."))
                } else if let filter {
                    momentList(filter)
                } else {
                    clipList
                }
            }
            .navigationTitle(filter.map { "\($0) moments" } ?? "Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.help("Close the library") }
                ToolbarItem(placement: .primaryAction) { filterMenu }
                if let filter {
                    ToolbarItem(placement: .primaryAction) {
                        Button { onPlayAll(filter) } label: { Label("Play all", systemImage: "play.rectangle.on.rectangle") }
                            .help("Play every \(filter) moment back to back in clip A")
                    }
                }
            }
            .alert("Clip not found", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(missing ?? "The clip") has been moved or deleted.")
            }
        }
        .themedSheet(width: 520, height: 480)
    }

    private var filterMenu: some View {
        Menu {
            Button { filter = nil } label: { Label("All clips", systemImage: filter == nil ? "checkmark" : "") }
            Divider()
            ForEach(library.labels.filter { !library.moments(labelled: $0).isEmpty }, id: \.self) { label in
                Button { filter = label } label: {
                    Label("\(label) (\(library.moments(labelled: label).count))", systemImage: filter == label ? "checkmark" : "")
                }
            }
        } label: {
            Label(filter ?? "All clips", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - All clips

    private var clipList: some View {
        List {
            ForEach(library.clips) { clip in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.name).font(.body.weight(.semibold))
                            Text(clip.added.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        openButtons(clip, time: nil)
                    }
                    NotesField(text: clip.notes) { library.setNotes($0, for: clip) }
                    if !clip.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(clip.tags) { tag in tagChip(tag, in: clip) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    Button("Remove from library", systemImage: "trash", role: .destructive) { library.remove(clip) }
                }
                .listRowBackground(Theme.card)
            }
            .onDelete { offsets in
                for index in offsets { library.remove(library.clips[index]) }
            }
        }
    }

    private func tagChip(_ tag: MomentTag, in clip: LibraryClip) -> some View {
        Menu {
            Button("Open as A at \(clock(tag.time))") { open(clip, side: 0, at: tag.time) }
            Button("Open as B at \(clock(tag.time))") { open(clip, side: 1, at: tag.time) }
            Divider()
            Button("Remove tag", systemImage: "trash", role: .destructive) { library.removeTag(tag, from: clip) }
        } label: {
            Label("\(tag.label) \(clock(tag.time))", systemImage: "tag.fill")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color(red: 1, green: 0.84, blue: 0.2), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - One tag across all clips

    private func momentList(_ label: String) -> some View {
        List {
            ForEach(library.moments(labelled: label), id: \.tag.id) { moment in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moment.clip.name).font(.body.weight(.medium))
                        Text("at \(clock(moment.tag.time))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    openButtons(moment.clip, time: moment.tag.time)
                }
                .listRowBackground(Theme.card)
            }
        }
    }

    private func openButtons(_ clip: LibraryClip, time: Double?) -> some View {
        HStack(spacing: 6) {
            Button("A") { open(clip, side: 0, at: time) }
            Button("B") { open(clip, side: 1, at: time) }
        }
        .buttonStyle(.bordered)
        .help("Open as clip A or clip B" + (time.map { " at \(clock($0))" } ?? ""))
    }

    private func open(_ clip: LibraryClip, side: Int, at time: Double?) {
        guard let url = clip.resolve() else {
            missing = clip.name
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        onOpen(url, side, time)
    }
}

/// A clip's notes, saved when editing ends.
private struct NotesField: View {
    @State private var text: String
    let onSave: (String) -> Void

    init(text: String, onSave: @escaping (String) -> Void) {
        _text = State(initialValue: text)
        self.onSave = onSave
    }

    var body: some View {
        TextField("Notes", text: $text, axis: .vertical)
            .font(.callout)
            .lineLimit(1...4)
            .onSubmit { onSave(text) }
            .onDisappear { onSave(text) }
    }
}
