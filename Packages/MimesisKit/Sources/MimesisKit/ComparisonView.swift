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
    /// The clip a chooser was opened for. Kept apart from what shows the chooser: the Mac clears that
    /// before it hands over the chosen file, which lost the clip and opened nothing.
    @State private var pickSide = 0
    /// The file chooser is open for a project, not a video (iPhone and iPad).
    @State private var pickingProject = false
    /// The clip (0 or 1) open in the editor.
    @State private var editing: EditTarget?
    @State private var openProblem: String?
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
    #if os(macOS)
    @State private var tabMonitor: Any?
    #endif

    private let preload: [URL?]

    /// - Parameter preload: clips to open as A and B at launch (for testing).
    public init(preload: [URL?] = []) {
        self.preload = preload
    }

    public var body: some View {
        VStack(spacing: 0) {
            // A phone on its side needs all its height for the clips: the dock carries the top bar's controls.
            #if os(iOS)
            if !(phone && anyLoaded) { topBar }
            #endif
            if !anyLoaded {
                WelcomeView(
                    onOpenFile: { importing = $0 },
                    onOpenPhotos: { photoTarget = $0 },
                    onDropped: { urls, side in dropped(urls, on: side) },
                    onCourt: { court = true },
                    onLibrary: library.clips.isEmpty ? nil : { showingLibrary = true },
                    recent: Array(store.recents.prefix(4)),
                    onOpenProject: { item in Task { await store.open(item, into: comparison) } },
                    onAllProjects: { browsing = true })
            } else {
                // As in Arete's player, on every device: the videos edge to edge; the timeline across
                // their bottom, see-through; and a solid bar of buttons under them. (A phone only runs
                // sideways, so the clips are side by side there too.) While drawing, the drawing tools
                // take the timeline's place.
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        GeometryReader { space in
                            panes(wide: space.size.width >= space.size.height)
                        }
                        VStack(spacing: 6) {
                            if let reel, reel.running { ReelBar(reel: reel).padding(.horizontal, 12) }
                            if let target = comparison.drawing {
                                MarkupTools(
                                    clips: target == .both ? comparison.clips.filter(\.isLoaded)
                                        : [comparison.clips[target == .clip(1) ? 1 : 0]],
                                    pen: comparison.pen,
                                    canUndo: comparison.history.canUndo,
                                    canRedo: comparison.history.canRedo,
                                    onUndo: { comparison.history.undo(comparison) },
                                    onRedo: { comparison.history.redo(comparison) },
                                    onDone: { comparison.drawing = nil })
                                .padding(.bottom, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                Transport(comparison: comparison, part: .timeline)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: comparison.drawing)
                    }
                    Transport(comparison: comparison, part: .bar, extras: phone ? AnyView(dockExtras) : nil)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: anyLoaded)
        // A video sent from another app (Share › Mimesis, Open With, the Dock icon).
        .onOpenURL { url in
            #if os(iOS)
            // mimesis://inbox: Share › Mimesis just left videos in the shared folder.
            if url.scheme == "mimesis" {
                Inbox.shared.collectShared()
                return
            }
            #endif
            Inbox.shared.receive([url])
        }
        // Share › Mimesis: each share is one batch (two videos: A and B).
        .onChange(of: Inbox.shared.batches.count, initial: true) { _, count in
            guard count > 0 else { return }
            while let batch = Inbox.shared.takeBatch() { take(batch) }
        }
        .onChange(of: Inbox.shared.urls, initial: true) { _, urls in
            guard !urls.isEmpty else { return }
            take(Inbox.shared.take())
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
        #if os(macOS)
        // On the Mac the top bar is the window's own title bar: no title, the layout in the middle and
        // the menu on the right, level with the close, minimise and zoom buttons.
        .toolbar {
            // Our own capsules, without the glass the system would put around them.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { if anyLoaded { layoutSwitch } }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { menu }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { if anyLoaded { layoutSwitch } }
                ToolbarItem(placement: .primaryAction) { menu }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackground(Theme.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #endif
        .environment(library)
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .background(keys)
        #if os(macOS)
        // Tab never reaches a keyboard shortcut on the Mac: the window takes it to move between controls.
        // Catch it first, unless someone is typing.
        .onAppear {
            guard tabMonitor == nil else { return }
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 48, // Tab
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      !(event.window?.firstResponder is NSText),
                      event.window?.attachedSheet == nil,
                      anyLoaded
                else { return event }
                switchFocus()
                return nil
            }
        }
        .onDisappear {
            if let tabMonitor { NSEvent.removeMonitor(tabMonitor) }
            tabMonitor = nil
        }
        #endif
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
        // Undo: the edits are noted a moment after they stop changing (one step for a whole drag).
        .task(id: snapshot) {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { comparison.history.record(comparison) }
        }
        .task(id: snapshot) {
            // Every clip opened goes into the library.
            for url in comparison.clips.compactMap(\.url) { library.record(url) }
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { store.remember(comparison) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            #if os(iOS)
            // Anything Share › Mimesis left while Mimesis wasn't asked to open.
            if phase == .active { Inbox.shared.collectShared() }
            #endif
            if phase != .active { store.remember(comparison) }
        }
        .alert("Save project", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                store.save(comparison, to: store.documentURL(named: name.isEmpty ? defaultName : name))
            }
        } message: {
            Text("Saved as a file in the Mimesis folder (in the Files app): both videos and every edit. Move or share it from there.")
        }
        .alert("Project", isPresented: Binding(get: { store.problem != nil }, set: { if !$0 { store.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.problem ?? "")
        }
        // The Mac's File menu.
        .onChange(of: MenuRequests.shared.pending) { _, request in
            guard let request else { return }
            MenuRequests.shared.pending = nil
            switch request {
            case .new: store.closeProject(comparison)
            case .open: openProject()
            case .openRecent(let id):
                if let recent = store.recents.first(where: { $0.id == id }) {
                    Task { await store.open(recent, into: comparison) }
                }
            case .save: saveProject()
            case .saveAs: saveProjectAs()
            case .export: if comparison.canLink { exporting = true }
            case .edit: editClip()
            case .swap: if bothLoaded { comparison.swapClips() }
            }
        }
        .onChange(of: store.recents, initial: true) { _, recents in MenuRequests.shared.recents = recents }
        .onChange(of: comparison.clips.map(\.isLoaded), initial: true) { _, loaded in
            MenuRequests.shared.hasClips = loaded.contains(true)
            MenuRequests.shared.hasBoth = loaded.allSatisfy { $0 }
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
        #if os(iOS)
        .fullScreenCover(item: $editing) { target in editor(target) }
        #else
        .sheet(item: $editing) { target in editor(target).frame(minWidth: 860, minHeight: 620) }
        #endif
        .sheet(isPresented: $exporting) {
            ExportView(comparison: comparison)
        }
        .sheet(isPresented: $browsing) {
            SavedComparisonsView(store: store, onOpen: { item in
                browsing = false
                Task { await store.open(item, into: comparison) }
            }, onBrowse: {
                browsing = false
                openProject()
            })
        }
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: pickingProject ? [.mimesisProject, .package] : [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        ) { result in
            defer { pickingProject = false }
            switch result {
            case .success(let url) where pickingProject || url.pathExtension.lowercased() == ComparisonStore.fileExtension:
                Task { await store.open(url, into: comparison) }
            case .success(let url): open(url, in: pickSide)
            case .failure(let error): openProblem = error.localizedDescription
            }
            importing = nil
        }
        .onChange(of: importing) { _, side in if let side { pickSide = side } }
        .onChange(of: photoTarget) { _, side in if let side { pickSide = side } }
        .photosPicker(
            isPresented: Binding(get: { photoTarget != nil }, set: { if !$0 { photoTarget = nil } }),
            selection: $photoPick, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: photoPick) { _, item in
            guard let item else { return }
            let index = pickSide
            photoPick = nil
            Task {
                do {
                    if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                        open(movie.url, in: index)
                    } else {
                        openProblem = "Photos didn't hand over the video. If it's in iCloud, wait for it to download and try again."
                    }
                } catch {
                    openProblem = "Couldn't get the video from Photos: \(error.localizedDescription)"
                }
            }
        }
        .alert("Couldn't open the video", isPresented: Binding(get: { openProblem != nil }, set: { if !$0 { openProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(openProblem ?? "")
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

    /// An iPhone: it runs sideways only, with the dock under the clips.
    private var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// The top bar's controls, at the end of the iPhone's bar: one menu, with the layout at its top.
    private var dockExtras: some View { menu }

    private func choose(_ layout: Comparison.Layout) {
        comparison.layout = layout
        if layout == .left { comparison.focus = 0 }
        if layout == .right { comparison.focus = 1 }
    }

    private var layoutSwitch: some View {
            HStack(spacing: 2) {
                ForEach(Comparison.Layout.allCases) { layout in
                    let on = comparison.layout == layout
                    let unavailable = layout == .overlay && !comparison.canLink
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { choose(layout) }
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
                    .help(layout.explanation)
                }
                if bothLoaded {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 16).padding(.horizontal, 3)
                    Button {
                        withAnimation(.easeOut(duration: 0.25)) { comparison.swapClips() }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 34, height: 30)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Swap A and B: each video keeps its In/Out, sync points, speed and drawings")
                }
            }
            .padding(3)
            .background(Theme.raised, in: Capsule())
            .focusEffectDisabled()
            .fixedSize()
    }

    private var menu: some View {
            Menu {
                if phone && anyLoaded {
                    // No top bar on an iPhone: the layout is here.
                    Section("Show") {
                        ForEach(Comparison.Layout.allCases) { layout in
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { choose(layout) }
                            } label: {
                                Label(layout.label, systemImage: comparison.layout == layout ? "checkmark" : layout.symbol)
                            }
                            .disabled(layout == .overlay && !comparison.canLink)
                        }
                    }
                }
                // A project is a file (Name.mimesis) with every edit and its own copies of the videos.
                // (On the Mac these are in the File menu too, with their keys.)
                Button(store.currentName.map { "Save “\($0)”" } ?? "Save project…", systemImage: "square.and.arrow.down") {
                    saveProject()
                }
                .disabled(!anyLoaded)
                .shortcut("s", [.command])
                Button("Save as…", systemImage: "plus.square.on.square") { saveProjectAs() }
                    .disabled(!anyLoaded)
                    .shortcut("s", [.command, .shift])
                Button("Open project…", systemImage: "folder") { openProject() }
                    .shortcut("o", [.command])
                Menu {
                    ForEach(store.recents.prefix(8)) { item in
                        Button(item.name) { Task { await store.open(item, into: comparison) } }
                    }
                    if store.recents.isEmpty { Text("No projects yet") }
                } label: {
                    Label("Open recent", systemImage: "clock.arrow.circlepath")
                }
                Button("Recent projects…", systemImage: "list.bullet.rectangle") { browsing = true }
                Divider()
                Button("Edit clip \(comparison.focus == 0 ? "A" : "B")…", systemImage: "crop.rotate") { editClip() }
                    .disabled(comparison.focused == nil)
                    .shortcut("t", [.command])
                if phone && bothLoaded {
                    Button("Swap A and B", systemImage: "arrow.left.arrow.right") { comparison.swapClips() }
                }
                Button("New comparison", systemImage: "plus") { store.closeProject(comparison) }
                    .disabled(!anyLoaded)
                    .shortcut("n", [.command])
                Divider()
                Button("Library…", systemImage: "books.vertical") { showingLibrary = true }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Live replay…", systemImage: "camera.viewfinder") { court = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Export video…", systemImage: "film") { exporting = true }
                    .disabled(!comparison.canLink)
                    .shortcut("e", [.command])
                #if DEBUG
                Divider()
                Button("Masking test…", systemImage: "person.crop.rectangle") { maskTest = true }
                #endif
            } label: {
                Image(systemName: phone && anyLoaded ? comparison.layout.symbol : "ellipsis")
                    .font(.system(size: phone ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: phone ? 32 : 36, height: phone ? 32 : 36)
                    .background(Theme.raised, in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(phone && anyLoaded ? "Show A | B, A, B or Overlay; projects, library, Live replay, export"
                  : "Projects, library, Live replay, export")
    }

    /// Videos dropped on the window: two fill A and B; one goes on the side it was dropped on, or, with
    /// no side, into an empty one (else Mimesis asks which).
    private func dropped(_ urls: [URL], on side: Int?) {
        if urls.count >= 2 {
            open(urls[0], in: 0)
            open(urls[1], in: 1)
        } else if let url = urls.first {
            if let side { open(url, in: side) } else { receive(url) }
        }
    }

    /// Videos sent together: two go into A and B with no question; one goes to an empty side (else Mimesis asks).
    private func take(_ sent: [URL]) {
        if openedProject(sent) { return }
        if sent.count >= 2 {
            incoming.removeAll()
            open(Self.keep(sent[0]), in: 0)
            open(Self.keep(sent[1]), in: 1)
            comparison.layout = .both
        } else {
            for url in sent { receive(url) }
        }
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
    /// ⌘S: over the project on screen; with none yet, asks for a name.
    private func saveProject() {
        if !store.saveCurrent(comparison) { saveProjectAs() }
    }

    /// Asks where to save the project and what to call it: the Mac's Save panel; on iPhone and iPad a
    /// name, and it goes in the Mimesis folder in Files.
    private func saveProjectAs() {
        guard anyLoaded else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mimesisProject]
        panel.nameFieldStringValue = (store.currentName ?? defaultName) + "." + ComparisonStore.fileExtension
        panel.canCreateDirectories = true
        panel.title = "Save Project"
        panel.message = "The project keeps every edit and its own copies of both videos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Saved over another project: that one goes first.
        if FileManager.default.fileExists(atPath: url.path), url != store.currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        store.save(comparison, to: url)
        #else
        newName = store.currentName ?? defaultName
        naming = true
        #endif
    }

    /// Opens the selected clip in the editor (turn, flip, crop, trim): ⌘T, or the button on the clip.
    private func editClip(_ index: Int? = nil) {
        let index = index ?? comparison.clips.firstIndex { $0 === comparison.focused } ?? 0
        guard let url = comparison.clips[index].url else { return }
        if comparison.linked { comparison.pause() }
        comparison.clips.forEach { $0.engine.pause() }
        comparison.drawing = nil
        editing = EditTarget(index: index, url: url)
    }

    /// The edited copy takes the clip's place. Its picture or length has changed, so the clip's In/Out,
    /// sync points and drawings start afresh in every segment; the original stays where it was, and the
    /// clip's ⋯ menu can go back to it.
    private func edited(_ index: Int, copy: URL) async -> Bool {
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = comparison.clips[index]
        let original = clip.beforeEdit ?? clip.url
        var kept = folder.appendingPathComponent(copy.lastPathComponent)
        if FileManager.default.fileExists(atPath: kept.path) {
            kept = folder.appendingPathComponent("\(copy.deletingPathExtension().lastPathComponent) \(UUID().uuidString.prefix(4)).\(copy.pathExtension)")
        }
        do { try FileManager.default.copyItem(at: copy, to: kept) } catch { return false }
        comparison.linked = false
        await clip.open(kept)
        clip.beforeEdit = original
        comparison.clipReplaced(index)
        comparison.loadSegment(comparison.segmentIndex)
        editing = nil
        return true
    }

    private func openProject() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mimesisProject]
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.title = "Open Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await store.open(url, into: comparison) }
        #else
        pickingProject = true
        importing = 0
        #endif
    }

    /// Back to the video as it was before it was edited.
    private func revert(_ index: Int) {
        let clip = comparison.clips[index]
        guard let original = clip.beforeEdit else { return }
        comparison.linked = false
        Task {
            await clip.open(original)
            comparison.clipReplaced(index)
            comparison.loadSegment(comparison.segmentIndex)
        }
    }

    /// A project file among what was sent to Mimesis (double-clicked, or opened from Files): opened.
    private func openedProject(_ urls: [URL]) -> Bool {
        guard let project = urls.first(where: { $0.pathExtension.lowercased() == ComparisonStore.fileExtension }) else { return false }
        Task { await store.open(project, into: comparison) }
        return true
    }

    private func editor(_ target: EditTarget) -> some View {
        MediaEditView(url: target.url, accent: Theme.accent,
                      onCancel: { editing = nil },
                      onSave: { copy in await edited(target.index, copy: copy) })
            .background(Theme.canvas.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }

    private var defaultName: String {
        comparison.clips.filter(\.isLoaded).map(\.name).joined(separator: " vs ")
    }

    /// Everything a saved comparison keeps, so a change to any of it is remembered.
    private var snapshot: String {
        let clips = comparison.clips.map { clip in
            "\(clip.url?.path ?? "-")|\(clip.trimStart)|\(clip.trimEnd ?? -1)|\(clip.syncs)|\(clip.speed ?? -1)|\(clip.engine.mirroredHorizontally)|\(clip.drawings.hashValue)|\(clip.cutout?.state == .ready)|\(clip.cutout?.boxed == true)|\(clip.cutout?.pickedAt.map { "\($0.time),\($0.point.x)" } ?? "-")"
        }
        return clips.joined(separator: ";") + "|\(comparison.layout)|\(comparison.linked)|\(comparison.linkedSpeed)"
            + "|\(comparison.segmentIndex)|\(comparison.segments.map(\.name))"
            + "|\(comparison.overlayTop)|\(comparison.overlayOpacity)|\(comparison.overlayOffset.width),\(comparison.overlayOffset.height)|\(comparison.overlayScale)|\(comparison.overlayRotation)"
    }

    private func open(_ url: URL, in index: Int, at time: Double? = nil) {
        comparison.linked = false
        comparison.focus = index
        Task {
            let clip = comparison.clips[index]
            if clip.url?.standardizedFileURL != url.standardizedFileURL {
                await clip.open(url)
                // Another video: its share of every segment starts afresh.
                comparison.clipReplaced(index)
            }
            if let time { await clip.engine.seekToTime(time) }
        }
    }

    /// Keys, as in Movist, for both clips while linked, else the selected one;
    /// plus [ ] for the trim and S for the sync point.
    @ViewBuilder private var keys: some View {
        // Each key looks up the focused clip when pressed: on the Mac a shortcut can keep its first
        // action after the view changes, so one that held a clip kept driving it after Tab.
        Group {
            key("[") { if !comparison.linked { comparison.focused?.setTrimStart() } }
            key("]") { if !comparison.linked { comparison.focused?.setTrimEnd() } }
            key("s") { if !comparison.linked { comparison.focused?.toggleSync() } }
            key("l") { if comparison.canLink { comparison.linked.toggle() } }
            key("\t") { switchFocus() }
            // Esc: stop drawing; else watch both clips (neither dimmed).
            key(.escape) {
                if comparison.drawing != nil {
                    comparison.drawing = nil
                } else if comparison.canLink {
                    comparison.linked = true
                }
            }
            key("z", [.command]) { comparison.history.undo(comparison) }
            key("z", [.command, .shift]) { comparison.history.redo(comparison) }
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
            .id("linked")
        } else if let clip = comparison.focused {
            // A fresh set for each clip, so the keys never drive the one focused before.
            MovistKeys(engine: clip.engine)
                .id(ObjectIdentifier(clip))
        }
    }

    /// Clip A and clip B (or the overlay), touching.
    private func panes(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
        return layout {
            if comparison.layout == .overlay {
                OverlayPane(comparison: comparison)
                    .dropDestination(for: URL.self) { urls, _ in
                        let videos = urls.filter(isVideo)
                        guard !videos.isEmpty else { return false }
                        dropped(videos, on: nil)
                        return true
                    }
            }
            ForEach(paneIndices, id: \.self) { index in
                ClipPane(
                    clip: comparison.clips[index],
                    letter: index == 0 ? "A" : "B",
                    linked: comparison.linked,
                    focused: comparison.selected === comparison.clips[index],
                    showsFocus: paneIndices.count == 2 && !comparison.linked,
                    onFocus: { comparison.focus = index },
                    onOpenFile: { importing = index },
                    onOpenPhotos: { photoTarget = index },
                    onDropped: { urls in dropped(urls, on: index) },
                    onJog: { frames in
                        if !comparison.linked { comparison.focus = index }
                        comparison.step(frames)
                    },
                    drawing: comparison.isDrawing(on: comparison.clips[index]),
                    pen: comparison.pen,
                    drawsTogether: comparison.drawsTogether,
                    onEdit: { editClip(index) },
                    onRevert: { revert(index) },
                    onDraw: {
                        comparison.drawing = comparison.drawing == .clip(index) ? nil : .clip(index)
                    })
            }
        }
        .background(Color.white.opacity(0.08))

    }

    /// Selects the other clip; on the Mac Tab would otherwise just move the keyboard focus.
    private func switchFocus() {
        guard comparison.layout == .both || comparison.layout == .overlay else {
            comparison.layout = comparison.layout == .left ? .right : .left
            return
        }
        // A, then B, then A+B (linked), then A again.
        if comparison.linked {
            comparison.linked = false
            comparison.focus = 0
        } else if comparison.focus == 0 {
            comparison.focus = 1
        } else if comparison.canLink {
            comparison.linked = true
        } else {
            comparison.focus = 0
        }
    }

    private func key(_ k: KeyEquivalent, _ modifiers: EventModifiers = [], action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(k, modifiers: modifiers)
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

    /// What it shows, for its button's tooltip.
    var explanation: String {
        switch self {
        case .both: "Both clips, side by side"
        case .left: "Clip A only, the whole window"
        case .right: "Clip B only, the whole window"
        case .overlay: "One clip over the other, see-through (needs both clips)"
        }
    }

    var symbol: String {
        switch self {
        case .both: "rectangle.split.2x1"
        case .left: "a.square"
        case .right: "b.square"
        case .overlay: "square.2.layers.3d"
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
        // Photos hands a video over as a movie file, an MPEG-4 or a QuickTime movie, depending on the Mac
        // or iPhone and how it was filmed: take any of them.
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { try keep($0.file) }
        FileRepresentation(contentType: .mpeg4Movie) { SentTransferredFile($0.url) } importing: { try keep($0.file) }
        FileRepresentation(contentType: .quickTimeMovie) { SentTransferredFile($0.url) } importing: { try keep($0.file) }
        FileRepresentation(contentType: .video) { SentTransferredFile($0.url) } importing: { try keep($0.file) }
    }

    /// A copy in Application Support (Photos' own file goes away), so a saved comparison can open it again.
    private static func keep(_ file: URL) throws -> Self {
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "mov" : file.pathExtension
        let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: file, to: copy)
        return Self(url: copy)
    }
}

/// The saved comparisons: tap one to open it, swipe (or Delete) to remove it.
struct SavedComparisonsView: View {
    let store: ComparisonStore
    let onOpen: (RecentProject) -> Void
    /// Find a project that isn't in the list.
    let onBrowse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.recents.isEmpty {
                    ContentUnavailableView(
                        "No projects yet", systemImage: "list.bullet.rectangle",
                        description: Text("Save one from the ⋯ menu (⌘S): a file with both videos and every edit."))
                } else {
                    List {
                        // The most recently saved or opened first.
                        ForEach(store.recents) { item in
                            Button { onOpen(item) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.body.weight(.medium))
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if item.name == store.currentName {
                                        Text("Open").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from this list", systemImage: "minus.circle") { store.forget(item) }
                            }
                            .listRowBackground(Theme.card)
                        }
                        .onDelete { offsets in
                            for item in offsets.map({ store.recents[$0] }) { store.forget(item) }
                        }
                    }
                }
            }
            .navigationTitle("Recent projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Open other…", action: onBrowse) }
            }
        }
        .themedSheet(width: 440, height: 400)
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


extension View {
    /// A key for a ⋯ menu item, except on the Mac, where the File menu has the same command with that
    /// key (two holders of one key make it do nothing).
    @ViewBuilder func shortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> some View {
        #if os(macOS)
        self
        #else
        keyboardShortcut(key, modifiers: modifiers)
        #endif
    }
}

/// A clip open in the editor.
struct EditTarget: Identifiable {
    let index: Int
    let url: URL
    var id: String { "\(index)-\(url.path)" }
}
