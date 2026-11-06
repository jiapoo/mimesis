import AreteMedia
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The main screen: clip A and clip B side by side (or one of them), with one floating transport
/// that plays the selected clip, or both once they're linked.
public struct ComparisonView: View {
    @State private var comparison = Comparison()
    @State private var importing: Int?
    @State private var photoPick: PhotosPickerItem?
    @State private var photoTarget: Int?
    @State private var maskTest = false
    @State private var store = ComparisonStore()
    @State private var naming = false
    @State private var newName = ""
    @State private var browsing = false
    @State private var exporting = false
    @State private var court = false
    @State private var library = Library()
    @State private var showingLibrary = false
    @State private var reel: Reel?
    /// Videos sent from another app, waiting to be put in A or B.
    @State private var incoming: [URL] = []
    @Environment(\.scenePhase) private var scenePhase

    private let preload: [URL?]

    /// - Parameter preload: clips to open as A and B at launch (for testing).
    public init(preload: [URL?] = []) {
        self.preload = preload
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            if !anyLoaded {
                WelcomeView(
                    onOpenFile: { importing = $0 },
                    onOpenPhotos: { photoTarget = $0 },
                    onCourt: { court = true },
                    onLibrary: library.clips.isEmpty ? nil : { showingLibrary = true })
            } else {
            GeometryReader { space in
                let wide = space.size.width >= space.size.height
                let layout = wide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
                layout {
                    if comparison.layout == .overlay {
                        OverlayPane(comparison: comparison)
                    }
                    ForEach(paneIndices, id: \.self) { index in
                        ClipPane(
                            clip: comparison.clips[index],
                            letter: index == 0 ? "A" : "B",
                            linked: comparison.linked,
                            focused: comparison.focus == index && !comparison.linked && comparison.clips[index].isLoaded,
                            onFocus: { comparison.focus = index },
                            onOpenFile: { importing = index },
                            onOpenPhotos: { photoTarget = index },
                            onDropped: { url in open(url, in: index) },
                            onJog: { frames in
                                if !comparison.linked { comparison.focus = index }
                                comparison.step(frames)
                            })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            if let reel, reel.running {
                ReelBar(reel: reel)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            // The timelines only once there's a clip to move through.
            Transport(comparison: comparison)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: anyLoaded)
        // A video sent from another app (Share › Mimesis, Open With, the Dock icon).
        .onOpenURL { url in Inbox.shared.receive([url]) }
        .onChange(of: Inbox.shared.urls, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            let sent = Inbox.shared.take()
            // Two sent together ("Compare in Mimesis" from Arete or Imago): A and B, no question.
            if sent.count >= 2 {
                incoming.removeAll()
                open(Self.keep(sent[0]), in: 0)
                open(Self.keep(sent[1]), in: 1)
                comparison.layout = .both
            } else {
                for url in sent { receive(url) }
            }
        }
        .confirmationDialog(
            incoming.first.map { "Open “\($0.deletingPathExtension().lastPathComponent)” as" } ?? "",
            isPresented: Binding(get: { !incoming.isEmpty && bothLoaded }, set: { if !$0 { incoming.removeAll() } }),
            titleVisibility: .visible
        ) {
            Button("Clip A") { place(in: 0) }
            Button("Clip B") { place(in: 1) }
            Button("Cancel", role: .cancel) { incoming.removeAll() }
        }
        .environment(library)
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .background(keys)
        .task {
            if preload.contains(where: { $0 != nil }) {
                for (index, url) in preload.prefix(2).enumerated() {
                    if let url { await comparison.clips[index].open(url) }
                }
            } else {
                // Carry on where the last session left off.
                await store.restoreLast(into: comparison)
            }
            if let sync = LibrarySync() { library.startSync(sync) }
        }
        // Remember the comparison a second after it last changed, and when the app goes to the background.
        .task(id: snapshot) {
            // Every clip opened goes into the library.
            for url in comparison.clips.compactMap(\.url) { library.record(url) }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { store.remember(comparison) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { store.remember(comparison) }
        }
        .alert("Save comparison", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                store.save(comparison, as: name.isEmpty ? defaultName : name)
            }
        } message: {
            Text("Both clips, with their trims, sync points, speeds, mirroring and drawings.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $court) {
            CourtView { url, side in open(url, in: side) }
        }
        #else
        .sheet(isPresented: $court) {
            CourtView { url, side in open(url, in: side) }
        }
        #endif
        .sheet(isPresented: $showingLibrary) {
            LibraryView(library: library, onOpen: { url, side, time in
                showingLibrary = false
                open(url, in: side, at: time)
            }, onPlayAll: { label in
                showingLibrary = false
                playAll(label)
            })
        }
        .sheet(isPresented: $exporting) {
            ExportView(comparison: comparison)
        }
        .sheet(isPresented: $browsing) {
            SavedComparisonsView(store: store) { item in
                browsing = false
                Task { await store.open(item, into: comparison) }
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: [.movie]
        ) { result in
            if case .success(let url) = result, let index = importing { open(url, in: index) }
            importing = nil
        }
        .photosPicker(
            isPresented: Binding(get: { photoTarget != nil }, set: { if !$0 { photoTarget = nil } }),
            selection: $photoPick, matching: .videos)
        .onChange(of: photoPick) { _, item in
            guard let item else { return }
            let index = photoTarget ?? comparison.focus
            photoPick = nil
            Task {
                if let movie = try? await item.loadTransferable(type: PickedMovie.self) {
                    open(movie.url, in: index)
                }
            }
        }
        .sheet(isPresented: $maskTest) {
            NavigationStack {
                MaskLabView()
                    .navigationTitle("Masking test")
                    .toolbar { Button("Done") { maskTest = false } }
            }
            .themedSheet(width: 800, height: 600)
        }
    }

    private var paneIndices: [Int] {
        switch comparison.layout {
        case .both: [0, 1]
        case .left: [0]
        case .right: [1]
        case .overlay: []
        }
    }

    private var anyLoaded: Bool { comparison.clips.contains(where: \.isLoaded) }

    private var topBar: some View {
        HStack(spacing: 12) {
            // The name beside the mark when there's room; the mark alone on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    EchoMark().frame(width: 22, height: 22)
                    Text("Mimesis").font(.system(size: 17, weight: .semibold)).fixedSize()
                }
                EchoMark().frame(width: 24, height: 24)
            }
            .frame(minWidth: 24, alignment: .leading)
            .layoutPriority(-1)

            Spacer(minLength: 0)

            if anyLoaded { layoutSwitch }

            Spacer(minLength: 0)

            menu
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var layoutSwitch: some View {
            HStack(spacing: 2) {
                ForEach(Comparison.Layout.allCases) { layout in
                    let on = comparison.layout == layout
                    let unavailable = layout == .overlay && !comparison.canLink
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { comparison.layout = layout }
                    } label: {
                        Text(layout.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                            .padding(.horizontal, 12)
                            .frame(minWidth: 40, minHeight: 30)
                            .background(on ? Color.white : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable)
                    .opacity(unavailable ? 0.4 : 1)
                    .help(layout == .overlay ? "One clip over the other, see-through: open both clips first" : "")
                }
            }
            .padding(3)
            .background(Theme.raised, in: Capsule())
            .focusEffectDisabled()
            .fixedSize()
    }

    private var menu: some View {
            Menu {
                Button("Save comparison…", systemImage: "square.and.arrow.down") {
                    newName = defaultName
                    naming = true
                }
                .disabled(!comparison.clips.contains(where: \.isLoaded))
                .keyboardShortcut("s", modifiers: .command)
                Button("Saved comparisons…", systemImage: "list.bullet.rectangle") { browsing = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Library…", systemImage: "books.vertical") { showingLibrary = true }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Court mode…", systemImage: "camera.viewfinder") { court = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Export video…", systemImage: "film") { exporting = true }
                    .disabled(!comparison.canLink)
                    .keyboardShortcut("e", modifiers: .command)
                #if DEBUG
                Divider()
                Button("Masking test…", systemImage: "person.crop.rectangle") { maskTest = true }
                #endif
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Theme.raised, in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    private var bothLoaded: Bool { comparison.clips.allSatisfy(\.isLoaded) }

    /// A video from another app: into an empty side straight away, else ask which.
    private func receive(_ url: URL) {
        guard url.isFileURL else { return }
        let kept = Self.keep(url)
        if let empty = comparison.clips.firstIndex(where: { !$0.isLoaded }), incoming.isEmpty {
            open(kept, in: empty)
        } else {
            incoming.append(kept)
        }
    }

    private func place(in side: Int) {
        guard !incoming.isEmpty else { return }
        let url = incoming.removeFirst()
        open(url, in: side)
        // Two sent together: the second goes in the other side.
        if let next = incoming.first {
            incoming.removeFirst()
            open(next, in: 1 - side)
        }
    }

    /// On iPhone and iPad a sent video lives in a temporary inbox (or another app's folder, for a while):
    /// keep a copy with the clips Mimesis owns, so the library and saved comparisons can open it again.
    /// On the Mac the file stays where it is.
    private static func keep(_ url: URL) -> URL {
        #if os(iOS)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copy = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: copy.path) {
            let same = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) == (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            if same { return copy }
            copy = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(UUID().uuidString.prefix(4)).\(url.pathExtension)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return url
        }
        #else
        return url
        #endif
    }

    /// Every moment tagged `label`, back to back in clip A, shown alone.
    private func playAll(_ label: String) {
        let items = library.moments(labelled: label).compactMap { moment in
            moment.clip.resolve().map { Reel.Item(url: $0, name: moment.clip.name, time: moment.tag.time) }
        }
        guard !items.isEmpty else { return }
        reel?.stop()
        comparison.linked = false
        comparison.focus = 0
        comparison.layout = .left
        let made = Reel(label: label, items: items)
        reel = made
        made.start(in: comparison.clips[0])
    }

    /// "serve vs serve2"
    private var defaultName: String {
        comparison.clips.filter(\.isLoaded).map(\.name).joined(separator: " vs ")
    }

    /// Everything a saved comparison keeps, so a change to any of it is remembered.
    private var snapshot: String {
        let clips = comparison.clips.map { clip in
            "\(clip.url?.path ?? "-")|\(clip.trimStart)|\(clip.trimEnd ?? -1)|\(clip.syncs)|\(clip.speed)|\(clip.engine.mirroredHorizontally)|\(clip.drawings.hashValue)|\(clip.cutout?.state == .ready)|\(clip.cutout?.boxed == true)|\(clip.cutout?.pickedAt.map { "\($0.time),\($0.point.x)" } ?? "-")"
        }
        return clips.joined(separator: ";") + "|\(comparison.layout)|\(comparison.linked)|\(comparison.linkedSpeed)"
            + "|\(comparison.overlayTop)|\(comparison.overlayOpacity)|\(comparison.overlayOffset.width),\(comparison.overlayOffset.height)|\(comparison.overlayScale)|\(comparison.overlayRotation)"
    }

    private func open(_ url: URL, in index: Int, at time: Double? = nil) {
        comparison.linked = false
        comparison.focus = index
        Task {
            let clip = comparison.clips[index]
            if clip.url?.standardizedFileURL != url.standardizedFileURL { await clip.open(url) }
            if let time { await clip.engine.seekToTime(time) }
        }
    }

    /// Keys, as in Movist, for both clips while linked, else the selected one;
    /// plus [ ] for the trim and S for the sync point.
    @ViewBuilder private var keys: some View {
        Group {
            if let clip = comparison.focused, !comparison.linked {
                key("[") { clip.setTrimStart() }
                key("]") { clip.setTrimEnd() }
                key("s") { clip.toggleSync() }
                key("\t") { comparison.focus = 1 - comparison.focus }
            }
            key("l") { if comparison.canLink { comparison.linked.toggle() } }
        }
        .hidden()
        if comparison.linked {
            Group {
                key(.space) { comparison.togglePlay() }
                key(",") { comparison.step(-1) }
                key(".") { comparison.step(1) }
                key(.leftArrow) { comparison.step(-1) }
                key(.rightArrow) { comparison.step(1) }
                key(.home) { comparison.pause(); Task { await comparison.seek(to: comparison.range.lowerBound) } }
            }
            .hidden()
        } else if let clip = comparison.focused {
            MovistKeys(engine: clip.engine)
        }
    }

    private func key(_ k: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: [])
    }
}

extension Comparison.Layout {
    var label: String {
        switch self {
        case .both: "A | B"
        case .left: "A"
        case .right: "B"
        case .overlay: "Overlay"
        }
    }
}

/// Seconds from the sync point, signed: "−0.43 s", "+1.20 s", "0.00 s".
func seconds(_ value: Double) -> String {
    let value = (value * 100).rounded() / 100
    if value == 0 { return "0.00 s" }
    return (value > 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2))) + " s"
}

func speedText(_ speed: Double) -> String {
    speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
}

/// A video picked from Photos, copied to a file the app can open (and open again later).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            // Kept in Application Support, so a saved comparison can open it again later.
            let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

/// The saved comparisons: tap one to open it, swipe (or Delete) to remove it.
struct SavedComparisonsView: View {
    let store: ComparisonStore
    let onOpen: (SavedComparison) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.saved.isEmpty {
                    ContentUnavailableView(
                        "No saved comparisons", systemImage: "list.bullet.rectangle",
                        description: Text("Save one from the ⋯ menu to come back to it later."))
                } else {
                    List {
                        ForEach(store.saved) { item in
                            Button { onOpen(item) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.body.weight(.medium))
                                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(item) }
                            }
                            .listRowBackground(Theme.card)
                        }
                        .onDelete { offsets in
                            for index in offsets { store.delete(store.saved[index]) }
                        }
                    }
                }
            }
            .navigationTitle("Saved comparisons")
            .toolbar { Button("Done") { dismiss() } }
        }
        .themedSheet(width: 420, height: 360)
    }
}

/// While a reel plays: which moment of how many, and Stop.
struct ReelBar: View {
    let reel: Reel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(Theme.accent)
            Text("\(reel.label) \(reel.index + 1) of \(reel.items.count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
            if reel.items.indices.contains(reel.index) {
                Text("\(reel.items[reel.index].name) at \(clock(reel.items[reel.index].time))")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            Button("Stop") { reel.stop() }.buttonStyle(ChipStyle(active: true))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .frame(maxWidth: 900)
    }
}
