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
    @State private var reporting = false
    @State private var askingNew = false
    /// What to do once a project asked to be saved under a name is saved (iPhone and iPad).
    @State private var afterSave: (() -> Void)?
    /// The edits' count when the project was last saved or opened (see `unsaved`).
    @State private var savedRevision = 0
    /// Shown for a moment at the top ("Saved …").
    @State private var notice: String?
    /// The file chooser is open to add a take to this clip.
    @State private var takeSide: Int?
    /// The segments' sidebar (kept between launches; an iPhone starts with it hidden).
    @AppStorage("showsSegments") private var showsSidebar = false
    @AppStorage("segmentsWidth") private var sidebarWidth = 272.0
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
    @Environment(\.displayScale) private var displayScale
    /// The snapshot's box, over the clips, while one is being framed.
    @State private var snapBox: CGRect?
    /// The size of the clips' area (where the box goes).
    @State private var panesSize: CGSize = .zero
    /// The last snapshot box, as shares of the clips' area ("x y width height"), so the next one starts
    /// there, whatever the window's size.
    @AppStorage("snapshotBox") private var lastSnapBox = ""
    #if os(macOS)
    @State private var tabMonitor: Any?
    #endif

    private let preload: [URL?]

    /// - Parameter preload: clips to open as A and B at launch (for testing).
    public init(preload: [URL?] = []) {
        self.preload = preload
        // The shared drawing tools (AreteMedia) in Mimesis's crimson.
        DrawingStyle.accent = Theme.accent
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
                    recentPath: { store.path(of: $0) },
                    onOpenProject: { item in Task { await store.open(item, into: comparison) } },
                    onAllProjects: { browsing = true },
                    onBrowseProject: { openProject() })
                    .onAppear { store.refreshRecents() }
            } else {
                // As in Arete's player, on every device: the videos edge to edge; the timeline across
                // their bottom, see-through; and a solid bar of buttons under them. (A phone only runs
                // sideways, so the clips are side by side there too.) While drawing, the drawing tools
                // take the timeline's place.
                HStack(spacing: 0) {
                if showsSidebar && !phone {
                    SegmentSidebar(comparison: comparison, onClose: { withAnimation(.easeOut(duration: 0.2)) { showsSidebar = false } },
                                   onAddTake: { side in takeSide = side; importing = side })
                        .frame(width: sidebarWidth)
                        // Drag its right edge to make it wider or narrower.
                        .overlay(alignment: .trailing) { SidebarEdge(width: $sidebarWidth) }
                        .layoutPriority(1)
                        .transition(.move(edge: .leading))
                }
                VStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        GeometryReader { space in
                            panes(wide: space.size.width >= space.size.height)
                                // While the snapshot's box is up: only the pictures, as they'll be kept.
                                .environment(\.cleanPicture, snapBox != nil)
                        }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { panesSize = $0 }
                        // The snapshot's box: drag it, or its handles; the camera in the bar takes it.
                        .overlay {
                            if snapBox != nil {
                                SnapshotFrame(box: Binding(get: { snapBox ?? .zero }, set: { snapBox = $0 }), area: panesSize)
                                    .transition(.opacity)
                            }
                        }
                        VStack(spacing: 6) {
                            if let reel, reel.running { ReelBar(reel: reel).padding(.horizontal, 12) }
                            // The timeline stays while drawing, to step to another frame; it steps
                            // aside while a snapshot is framed, so the box can reach the bottom.
                            if snapBox == nil {
                                Transport(comparison: comparison, part: .timeline)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: comparison.drawing)
                        .animation(.easeOut(duration: 0.15), value: snapBox == nil)
                    }
                    // The drawing tools, as in Photoshop: the tools down the left, the chosen tool's
                    // options across the top.
                    // (On the right: the segments are on the left.)
                    .overlay(alignment: .topTrailing) {
                        if comparison.drawing != nil {
                            // One column down the right edge, from the top to the timeline: smaller
                            // buttons where it's short (and scrolling if even those don't fit), so
                            // no tool is ever under the timeline.
                            ViewThatFits(in: .vertical) {
                                markup(.strip, compact: false, dense: 0)
                                markup(.strip, compact: false, dense: 1)
                                markup(.strip, compact: false, dense: 2)
                                ScrollView(.vertical, showsIndicators: false) { markup(.strip, compact: false, dense: 2) }
                            }
                            .padding(.trailing, 8)
                            .padding(.top, 8)
                            .padding(.bottom, phone ? 70 : 132)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .overlay {
                        if comparison.drawing != nil {
                            // The whole bar where it fits; a shorter one where it doesn't (an iPhone, or
                            // the sidebar open in a small window). It starts at the top, clear of the
                            // tools on the right, and can be dragged by its handle to anywhere.
                            GeometryReader { area in
                                let top: CGFloat = phone ? 6 : 48
                                let moved = comparison.pen.barOffset
                                ViewThatFits(in: .horizontal) {
                                    markup(.options, compact: false)
                                    markup(.options, compact: true)
                                    // An iPhone: the colour and thickness behind one swatch.
                                    markup(.options, compact: true, mini: true)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.leading, 8)
                                .padding(.trailing, 52)
                                .padding(.top, top)
                                .offset(x: min(max(moved.width, -area.size.width / 2 + 40), area.size.width / 2 - 40),
                                        y: min(max(moved.height, 4 - top), max(4 - top, area.size.height - top - 150)))
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    Transport(comparison: comparison, part: .bar, extras: phone ? AnyView(dockExtras) : nil,
                              sidebarShown: showsSidebar,
                              onSidebar: { withAnimation(.easeOut(duration: 0.2)) { showsSidebar.toggle() } },
                              framing: snapBox != nil,
                              onFrame: frameSnapshot,
                              onSnapshot: takeSnapshot,
                              onCancelFrame: {
                                  rememberSnapBox()
                                  withAnimation(.easeOut(duration: 0.15)) { snapBox = nil }
                              })
                }
                // The clips take what the sidebar leaves, however little: the sidebar is never squeezed
                // or pushed off the window.
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
                #if os(iOS)
                // Typing in the segments' panel: a tap on the clips finishes it.
                .overlay {
                    if comparison.typing {
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
                }
                #endif
                }
                // On an iPhone the segments slide in over the clips.
                .overlay(alignment: .leading) {
                    if showsSidebar && phone {
                        SegmentSidebar(comparison: comparison, onClose: { withAnimation(.easeOut(duration: 0.2)) { showsSidebar = false } },
                                   onAddTake: { side in takeSide = side; importing = side })
                            .frame(width: 300)
                            .shadow(color: .black.opacity(0.5), radius: 12)
                            .transition(.move(edge: .leading))
                    }
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
        // On the Mac the top bar is the window's own title bar: no title, undo and redo and the layout,
        // level with the close, minimise and zoom buttons. (Projects, the library, Live replay, export
        // and the report are in the File menu: no ⋯ button.)
        .toolbar {
            // Our own capsules, without the glass the system would put around them.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { if anyLoaded { UndoButtons(comparison: comparison) } }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { if anyLoaded { layoutSwitch } }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { if anyLoaded { UndoButtons(comparison: comparison) } }
                ToolbarItem(placement: .principal) { if anyLoaded { layoutSwitch } }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackground(Theme.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #endif
        .environment(library)
        // No keyboard-focus ring around buttons: every one of them is clicked or has a key.
        .focusEffectDisabled()
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .background(keys)
        #if os(macOS)
        // Tab never reaches a keyboard shortcut on the Mac: the window takes it to move between controls.
        // Catch it first, unless someone is typing.
        .onAppear {
            guard tabMonitor == nil else { return }
            tabMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { event in
                let text = event.window?.firstResponder as? NSText
                if event.type == .leftMouseDown {
                    // Typing in the segments' panel (a name, a note): a click anywhere outside the field
                    // finishes it, back to reading. (The click still does what it would.)
                    if comparison.typing, let text, let window = event.window, window.attachedSheet == nil,
                       !text.convert(text.bounds, to: nil).insetBy(dx: -6, dy: -6).contains(event.locationInWindow) {
                        window.makeFirstResponder(nil)
                    }
                    return event
                }
                // While drawing, holding Space moves the video with a drag (as in Photoshop), and
                // doesn't play.
                // Space plays and pauses, whatever was clicked last (a layout button kept the key for
                // itself); while drawing it's held to move the picture instead.
                if event.keyCode == 49, event.type == .keyDown, comparison.drawing == nil, text == nil,
                   event.window?.attachedSheet == nil, anyLoaded,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    if !event.isARepeat { comparison.togglePlay() }
                    return nil
                }
                if event.keyCode == 49 {
                    if event.type == .keyUp {
                        let was = comparison.pen.panning
                        comparison.pen.panning = false
                        comparison.pen.grabbing = false
                        return was ? nil : event
                    }
                    if comparison.drawing != nil, text == nil, event.window?.attachedSheet == nil,
                       event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                        comparison.pen.panning = true
                        return nil
                    }
                }
                guard event.type == .keyDown else { return event }
                // While drawing, a letter picks a tool (V select, H hand, P pen, M marker, N pencil,
                // E eraser, L line, A arrow, R rectangle, O circle, G angle).
                if comparison.drawing != nil, text == nil, event.window?.attachedSheet == nil,
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   let typed = event.charactersIgnoringModifiers?.lowercased().first,
                   let tool = Pen.Tool.allCases.first(where: { $0.key == typed }) {
                    comparison.pen.tool = tool
                    return nil
                }
                // ⌘Z and ⇧⌘Z: the Edit menu's own Undo would take them and do nothing (it knows only
                // about typing), so they're caught here; in a text field they're left to the typing.
                if event.keyCode == 6, text == nil, event.window?.attachedSheet == nil, anyLoaded,
                   event.modifierFlags.intersection([.command, .option, .control]) == .command {
                    if event.modifierFlags.contains(.shift) {
                        comparison.history.redo(comparison)
                    } else {
                        comparison.history.undo(comparison)
                    }
                    return nil
                }
                guard event.keyCode == 48, // Tab
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      text == nil,
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
                markSaved()
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
            // A project deleted in Finder (or the Files app) meanwhile leaves the recent ones.
            if phase == .active { store.refreshRecents() }
        }
        .alert("Save project", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if store.save(comparison, to: store.documentURL(named: name.isEmpty ? defaultName : name)) {
                    saved()
                    afterSave?()
                }
                afterSave = nil
            }
        } message: {
            Text("Saved as a file in the Mimesis folder (in the Files app): both videos and every edit. Move or share it from there.")
        }
        .confirmationDialog(
            store.currentName.map { "Save the changes to “\($0)” first?" } ?? "Save this comparison as a project first?",
            isPresented: $askingNew, titleVisibility: .visible
        ) {
            Button("Save") { saveProject(then: closeEverything) }
            Button("Don't Save", role: .destructive) { closeEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Both clips are closed. Changes not saved in a project are lost.")
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
            handle(request)
        }
        .onChange(of: store.recents, initial: true) { _, recents in
            MenuRequests.shared.recentPaths = Dictionary(uniqueKeysWithValues: recents.map { ($0.id, store.path(of: $0)) })
            MenuRequests.shared.recents = recents
        }
        .onChange(of: unsaved, initial: true) { _, unsaved in MenuRequests.shared.hasUnsaved = unsaved }
        .onChange(of: store.currentName, initial: true) { _, name in MenuRequests.shared.projectName = name }
        // A project just opened: nothing to save yet.
        .onChange(of: store.opens) { _, _ in markSaved() }
        .overlay(alignment: .top) { noticeView }
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
        .sheet(isPresented: $reporting) {
            ReportView(comparison: comparison, title: store.currentName ?? defaultName)
        }
        .sheet(isPresented: $exporting) {
            ExportView(comparison: comparison)
        }
        .onChange(of: browsing) { _, showing in if showing { store.refreshRecents() } }
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
            defer { pickingProject = false; takeSide = nil }
            switch result {
            case .success(let url) where pickingProject || url.pathExtension.lowercased() == ComparisonStore.fileExtension:
                Task { await store.open(url, into: comparison) }
            case .success(let url):
                if let side = takeSide {
                    Task { await comparison.addTake(Self.keep(url), to: side) }
                } else {
                    open(url, in: pickSide)
                }
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

            if anyLoaded { UndoButtons(comparison: comparison) }

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

    /// The layout, and in the overlay which clip is on top ("A over B": click to swap).
    private var layoutSwitch: some View {
        HStack(spacing: 8) {
            layoutButtons
            if comparison.layout == .overlay && bothLoaded {
                OverlayBadge(comparison: comparison)
            }
        }
        .fixedSize()
    }

    private var layoutButtons: some View {
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
                Button("New", systemImage: "plus") { newComparison() }
                    .disabled(!anyLoaded)
                    .shortcut("n", [.command])
                Divider()
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
                        // Its full path: two projects can share a name.
                        Button(store.path(of: item)) { Task { await store.open(item, into: comparison) } }
                    }
                    if store.recents.isEmpty { Text("No projects yet") }
                } label: {
                    Label("Open recent", systemImage: "clock.arrow.circlepath")
                }
                Button("Recent projects…", systemImage: "list.bullet.rectangle") { browsing = true }
                #if os(macOS)
                if let url = store.currentURL {
                    Button("Show “\(store.currentName ?? "")” in Finder", systemImage: "magnifyingglass") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                #endif
                Divider()
                Button("Edit clip \(comparison.focus == 0 ? "A" : "B")…", systemImage: "crop.rotate") { editClip() }
                    .disabled(comparison.focused == nil)
                    .shortcut("t", [.command])
                if phone && bothLoaded {
                    Button("Swap A and B", systemImage: "arrow.left.arrow.right") { comparison.swapClips() }
                }
                Divider()
                Button("Library…", systemImage: "books.vertical") { showingLibrary = true }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Live replay…", systemImage: "camera.viewfinder") { court = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Export video…", systemImage: "film") { exporting = true }
                    .disabled(!comparison.canLink)
                    .shortcut("e", [.command])
                Button("Report (PDF)…", systemImage: "doc.richtext") { reporting = true }
                    .disabled(!anyLoaded)
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
        // Kept first: a file dragged from another app (Imago, Photos) can be a temporary copy that's
        // gone a moment after the drop, which left the clip black.
        // A project file dropped on the window: opened.
        if let project = urls.first(where: isProject) {
            _ = project.startAccessingSecurityScopedResource()
            Task { await store.open(project, into: comparison) }
            return
        }
        let urls = urls.map(Self.keepDropped)
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
    /// A dropped file, made safe to open a moment later: access to it is taken now, while the drop still
    /// grants it; and one in a temporary place (a file another app promised and wrote for the drop) is
    /// copied into Mimesis's own clips, because the original goes when the drop ends.
    private static func keepDropped(_ url: URL) -> URL {
        _ = url.startAccessingSecurityScopedResource()
        let path = url.standardizedFileURL.path
        let temporary = path.hasPrefix(NSTemporaryDirectory()) || path.contains("/TemporaryItems/")
            || path.contains("/T/") || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
            || path.contains("/Caches/")
        guard temporary else { return url }
        let folder = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copy = folder.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: copy.path) {
            copy = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(UUID().uuidString.prefix(4)).\(url.pathExtension)")
        }
        return (try? FileManager.default.copyItem(at: url, to: copy)) == nil ? url : copy
    }

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

    /// What the Mac's menu bar asked for.
    private func handle(_ request: MenuRequests.Request) {
        switch request {
        case .new: newComparison()
        case .open: openProject()
        case .openRecent(let id):
            if let recent = store.recents.first(where: { $0.id == id }) {
                Task { await store.open(recent, into: comparison) }
            }
        case .save: saveProject()
        case .saveAs: saveProjectAs()
        case .close: newComparison()
        case .recentProjects: browsing = true
        case .showInFinder:
            #if os(macOS)
            if let url = store.currentURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            #endif
        case .library: showingLibrary = true
        case .liveReplay: court = true
        case .report: if anyLoaded { reporting = true }
        case .maskTest: maskTest = true
        case .saveThenQuit:
            #if os(macOS)
            saveProject(then: {
                MenuRequests.shared.hasUnsaved = false
                NSApp.terminate(nil)
            })
            #endif
        case .export: if comparison.canLink { exporting = true }
        case .edit: editClip()
        case .swap: if bothLoaded { comparison.swapClips() }
        case .undo: comparison.history.undo(comparison)
        case .redo: comparison.history.redo(comparison)
        }
    }

    /// "Saved …", for a moment at the top.
    @ViewBuilder private var noticeView: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.75), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: Saving, closing, quitting

    /// There's something to save: an edit, or another video, since the project was last saved or opened.
    private var unsaved: Bool { anyLoaded && comparison.history.revision != savedRevision }

    /// What's on screen is what's saved (or was just opened): nothing to save until the next edit.
    private func markSaved() {
        comparison.history.record(comparison)
        savedRevision = comparison.history.revision
    }

    /// Says something for a moment at the top of the window ("Saved …").
    private func say(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if notice == text { withAnimation(.easeOut(duration: 0.3)) { notice = nil } }
        }
    }

    /// ⌘S: over the project on screen; with none yet, asks where to save. `then` runs once it's saved.
    private func saveProject(then: (() -> Void)? = nil) {
        if store.saveCurrent(comparison) {
            saved()
            then?()
        } else {
            saveProjectAs(then: then)
        }
    }

    private func saved() {
        markSaved()
        say("Saved “\(store.currentName ?? "")”")
    }

    /// New, or Close: both clips closed, no project. With something not saved, asks first.
    private func newComparison() {
        if unsaved { askingNew = true } else { closeEverything() }
    }

    private func closeEverything() {
        store.closeProject(comparison)
        markSaved()
    }

    /// Asks where to save the project and what to call it: the Mac's Save sheet, on the window; on
    /// iPhone and iPad a name, and it goes in the Mimesis folder in Files. `then` runs once it's saved.
    private func saveProjectAs(then: (() -> Void)? = nil) {
        guard anyLoaded else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mimesisProject]
        panel.nameFieldStringValue = (store.currentName ?? defaultName) + "." + ComparisonStore.fileExtension
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            // Saved over another project: that one goes first.
            if FileManager.default.fileExists(atPath: url.path), url != store.currentURL {
                try? FileManager.default.removeItem(at: url)
            }
            if store.save(comparison, to: url) {
                saved()
                then?()
            }
        }
        // The usual Save sheet, down from the window's title bar.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
        #else
        afterSave = then
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

    private func markup(_ part: MarkupTools<Clip>.Part, compact: Bool, dense: Int = 0, mini: Bool = false) -> some View {
        let target = comparison.drawing
        return MarkupTools(
            part: part,
            surfaces: target == .both ? comparison.clips.filter(\.isLoaded)
                : [comparison.clips[target == .clip(1) ? 1 : 0]],
            pen: comparison.pen,
            onDone: {
                comparison.pen.selected = nil
                comparison.drawing = nil
            },
            compact: compact,
            mini: mini,
            dense: dense)
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
            "\(clip.url?.path ?? "-")|\(clip.trimStart)|\(clip.trimEnd ?? -1)|\(clip.syncs)|\(clip.speed ?? -1)|\(clip.engine.mirroredHorizontally)|\(clip.drawings.hashValue)|\(clip.notes.map { "\($0.time)\($0.text)" })|\(clip.cutout?.state == .ready)|\(clip.cutout?.boxed == true)|\(clip.cutout?.pickedAt.map { "\($0.time),\($0.point.x)" } ?? "-")"
        }
        return clips.joined(separator: ";") + "|\(comparison.layout)|\(comparison.linked)|\(comparison.linkedSpeed)"
            + "|\(comparison.takes.map { $0.map(\.url.lastPathComponent) })\(comparison.takeIndex)"
            + "|\(comparison.segmentIndex)|\(comparison.segments.map { $0.name + ($0.notes ?? "") + "\($0.snapshots?.map(\.id) ?? [])" })"
            + "|\(comparison.overlayTop)|\(comparison.overlayOpacity)|\(comparison.overlayOffset.width),\(comparison.overlayOffset.height)|\(comparison.overlayScale)|\(comparison.overlayRotation)"
    }

    private func open(_ url: URL, in index: Int, at time: Double? = nil) {
        comparison.linked = false
        comparison.focus = index
        Task {
            let clip = comparison.clips[index]
            // (The same file again is opened again when it didn't open the first time.)
            if clip.url?.standardizedFileURL != url.standardizedFileURL || clip.engine.duration <= 0 {
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
            // (While drawing, [ and ] are the thickness: see `MarkupKeys`.)
            if comparison.drawing == nil {
                key("[") { if !comparison.linked { comparison.focused?.setTrimStart() } }
                key("]") { if !comparison.linked { comparison.focused?.setTrimEnd() } }
            }
            key("s") { if !comparison.linked { comparison.focused?.toggleSync() } }
            key("l") { if comparison.canLink { comparison.linked.toggle() } }
            key("\t") { switchFocus() }
            // Esc: put the snapshot's box away; stop drawing; else watch both clips (neither dimmed).
            key(.escape) {
                if snapBox != nil {
                    rememberSnapBox()
                    withAnimation(.easeOut(duration: 0.15)) { snapBox = nil }
                } else if comparison.pen.selected != nil {
                    comparison.pen.selected = nil
                } else if comparison.drawing != nil {
                    comparison.drawing = nil
                } else if comparison.canLink {
                    comparison.linked = true
                }
            }
            // The snapshot's box is up: Return takes it.
            if snapBox != nil { key(.return) { takeSnapshot() } }
            // F: the snapshot's box; again, take it.
            key("f") { if snapBox == nil { frameSnapshot() } else { takeSnapshot() } }
            // D: draw on the clips; again, stop.
            key("d") { if anyLoaded { snapBox = nil; comparison.toggleDrawingBoth() } }
            // B: the skeleton, on the selected clip (both while linked).
            key("b") {
                let clips = comparison.linked ? comparison.clips.filter(\.isLoaded) : [comparison.focused].compactMap { $0 }
                clips.forEach { $0.toggleSkeleton() }
            }
            // ⌥L: loop, or stop at the end.
            key("l", [.option]) { comparison.loops.toggle() }
            // ⌃⌘S: the segments' sidebar.
            key("s", [.control, .command]) { withAnimation(.easeOut(duration: 0.2)) { showsSidebar.toggle() } }
            // ⌘1–⌘4: the layout.
            ForEach(Array(Comparison.Layout.allCases.enumerated()), id: \.offset) { index, layout in
                key(KeyEquivalent(Character("\(index + 1)")), [.command]) {
                    guard anyLoaded, layout != .overlay || comparison.canLink else { return }
                    withAnimation(.easeOut(duration: 0.2)) { choose(layout) }
                }
            }
            // ⌘0: the whole frame again (zoomed or moved).
            key("0", [.command]) { withAnimation(.easeOut(duration: 0.2)) { comparison.clips.forEach { $0.resetView() } } }
            // (On the Mac ⌘Z and ⇧⌘Z are caught before the Edit menu: see the key monitor.)
            #if !os(macOS)
            key("z", [.command]) { comparison.history.undo(comparison) }
            key("z", [.command, .shift]) { comparison.history.redo(comparison) }
            #endif
        }
        .hidden()
        .disabled(comparison.typing)
        // While drawing: the colours, thickness, opacity, this frame or every frame, duplicate, delete.
        if let target = comparison.drawing {
            MarkupKeys(surfaces: target == .both ? comparison.clips.filter(\.isLoaded)
                        : [comparison.clips[target == .clip(1) ? 1 : 0]],
                       pen: comparison.pen, enabled: !comparison.typing && snapBox == nil)
        }
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
            .disabled(comparison.typing)
            .id("linked")
        } else if let clip = comparison.focused {
            // A fresh set for each clip, so the keys never drive the one focused before.
            MovistKeys(engine: clip.engine, enabled: !comparison.typing)
                .id(ObjectIdentifier(clip))
        }
    }

    /// Clip A and clip B (or the overlay), touching.
    private func panes(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
        return layout {
            if comparison.layout == .overlay {
                OverlayPane(comparison: comparison, showsBadge: phone)
                    .dropDestination(for: URL.self) { urls, _ in
                        let videos = urls.filter { isVideo($0) || isProject($0) }
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
                    // (No ring while drawing: the one Draw button draws on both.)
                    showsFocus: paneIndices.count == 2 && !comparison.linked && comparison.drawing == nil,
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
                    skeletonAngles: comparison.skeletonAngles,
                    onEdit: { editClip(index) },
                    onRevert: { revert(index) },
                    onDraw: {
                        comparison.drawing = comparison.drawing == .clip(index) ? nil : .clip(index)
                    })
                // A pane belongs to its video: after A and B are swapped it's made again, so its player
                // view shows the right video (kept, it stayed on the old one and went black).
                .id(ObjectIdentifier(comparison.clips[index]))
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

    // MARK: Snapshot

    /// The camera's first click: stop on this frame and put up the box, over all the clips, a little in
    /// from their edges.
    private func frameSnapshot() {
        guard panesSize.width > 0, panesSize.height > 0 else { return }
        comparison.drawing = nil
        comparison.pauseForSnapshot()
        withAnimation(.easeOut(duration: 0.15)) {
            snapBox = SnapshotFrame.remembered(lastSnapBox, in: panesSize) ?? SnapshotFrame.start(in: panesSize)
        }
    }

    /// Keeps where the box is, for next time.
    private func rememberSnapBox() {
        guard let box = snapBox else { return }
        lastSnapBox = SnapshotFrame.shares(of: box, in: panesSize)
    }

    /// The camera's second click: keep what's inside the box, exactly as it is on screen.
    private func takeSnapshot() {
        guard let box = snapBox else { return }
        rememberSnapBox()
        let size = panesSize
        Task {
            let stills = await SnapshotCapture.stills(of: comparison)
            let picture = panes(wide: size.width >= size.height)
                .environment(\.stills, stills)
                .environment(\.cleanPicture, true)
                .environment(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
            let image = SnapshotCapture.take(picture, size: size, box: box, scale: displayScale)
            comparison.addSnapshot(image: image)
            withAnimation(.easeOut(duration: 0.15)) { snapBox = nil }
            say(image == nil ? "Snapshot kept, without its picture: it couldn't be made"
                : "Snapshot kept: it's in the sidebar, and in the report")
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
        case .both: "Both clips, side by side (⌘1)"
        case .left: "Clip A only, the whole window (⌘2)"
        case .right: "Clip B only, the whole window (⌘3)"
        case .overlay: "One clip over the other, see-through (needs both clips) (⌘4)"
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
    @State private var deleting: RecentProject?

    /// Where a project is, as a path to read: "~/Documents/Compare.mimesis".
    private func path(_ item: RecentProject) -> String { store.path(of: item) }

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
                            HStack(spacing: 10) {
                                Button { onOpen(item) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name).font(.body.weight(.medium))
                                            if item.name == store.currentName {
                                                Text("Open").font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                                            }
                                        }
                                        Text(path(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open this project")
                                #if os(macOS)
                                Button { reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Show in Finder")
                                #endif
                                Button { deleting = item } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Delete this project")
                            }
                            .contextMenu {
                                #if os(macOS)
                                Button("Show in Finder", systemImage: "magnifyingglass") { reveal(item) }
                                #endif
                                Button("Remove from this list", systemImage: "minus.circle") { store.forget(item) }
                                Button("Delete the project…", systemImage: "trash", role: .destructive) { deleting = item }
                            }
                            .listRowBackground(Theme.card)
                        }
                    }
                }
            }
            .navigationTitle("Recent projects")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.help("Close this list") }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open other…", action: onBrowse).help("Find a project file that isn't in this list")
                }
            }
            .confirmationDialog(
                "Delete “\(deleting?.name ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
            ) {
                Button(deleteLabel, role: .destructive) {
                    if let deleting { store.delete(deleting) }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text(deleteMessage)
            }
        }
        .themedSheet(width: 520, height: 420)
    }

    #if os(macOS)
    private let deleteLabel = "Move to Trash"
    private let deleteMessage = "The project file, with its copies of the videos, goes to the Trash. The original videos aren't touched."

    private func reveal(_ item: RecentProject) {
        guard let url = store.location(of: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #else
    private let deleteLabel = "Delete"
    private let deleteMessage = "The project file, with its copies of the videos, is deleted. The original videos aren't touched."
    #endif
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
                .help("Stop playing the tagged moments one after another")
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

/// The sidebar's right edge: drag it to change the sidebar's width (240 to 480 points).
struct SidebarEdge: View {
    @Binding var width: Double
    @State private var from: Double?

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(from == nil ? 0.001 : 0.25))
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = from ?? width
                        from = start
                        width = min(480, max(240, start + drag.translation.width))
                    }
                    .onEnded { _ in from = nil })
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            #endif
            .help("Drag to make the sidebar wider or narrower")
    }
}
