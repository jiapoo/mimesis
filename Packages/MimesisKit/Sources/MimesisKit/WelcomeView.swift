import SwiftUI

/// The first screen, before any clip is open: what Mimesis does, and the ways to start.
struct WelcomeView: View {
    @State private var droppingOnScreen = false
    @State private var droppingOn: Int?
    let onOpenFile: (Int) -> Void
    let onOpenPhotos: (Int) -> Void
    /// Videos dropped on a clip's card (its side) or anywhere else on the screen (nil).
    let onDropped: ([URL], Int?) -> Void
    let onCourt: () -> Void
    /// Nil until the library has clips.
    let onLibrary: (() -> Void)?
    /// The most recent projects, to open with one tap.
    var recent: [RecentProject] = []
    var onOpenProject: (RecentProject) -> Void = { _ in }
    var onAllProjects: () -> Void = {}
    /// Find a project file to open.
    var onBrowseProject: () -> Void = {}

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// A phone on its side: two columns, the welcome on the left and the ways in on the right.
    private var sideways: Bool { verticalSizeClass == .compact }
    #else
    private let sideways = false
    #endif

    var body: some View {
        ScrollView {
            Group {
                if sideways {
                    HStack(alignment: .center, spacing: 36) {
                        hero(alignment: .leading).frame(maxWidth: 300, alignment: .leading)
                        VStack(spacing: 10) {
                            slots
                            ways
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 28) {
                        hero(alignment: .center).padding(.top, 24)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { slots }
                            VStack(spacing: 12) { slots }
                        }
                        .frame(maxWidth: 640)
                        ways.frame(maxWidth: 640)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, sideways ? 8 : 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Dropped anywhere but a card: into the first empty side (two: A and B).
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { isVideo($0) || isProject($0) }
            guard !videos.isEmpty else { return false }
            onDropped(videos, nil)
            return true
        } isTargeted: { droppingOnScreen = $0 }
        .overlay {
            if droppingOnScreen {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func hero(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: sideways ? 10 : 14) {
            EchoMark().frame(width: sideways ? 56 : 76, height: sideways ? 56 : 76)
            Text("Compare two videos")
                .font(.system(size: sideways ? 24 : 28, weight: .bold))
            Text("Put your video beside the one you learn from: line them up, slow them down, draw on them, and see where they differ.")
                .font(.system(size: sideways ? 14 : 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .frame(maxWidth: 420)
            if sideways {
                Label("Film in Slo-mo (240 fps), or at least 60 fps, for smooth slow motion", systemImage: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
                    .padding(.top, 4)
            }
        }
    }

    /// The other ways in: film at the court, or the library.
    private var ways: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onBrowseProject) {
                    Label("Open project", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WideButtonStyle())
                .help("Open a project file (Name.mimesis): both videos and every edit, as they were saved")
                Button(action: onCourt) {
                    Label("Live replay", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WideButtonStyle())
                .help("Film with this device and watch each attempt again a few seconds later, hands-free")
                if let onLibrary, sideways {
                    Button(action: onLibrary) {
                        Label("Library", systemImage: "books.vertical")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WideButtonStyle())
                    .help("Every video opened in Mimesis, with its tags")
                }
            }
            if let onLibrary, !sideways {
                Button(action: onLibrary) {
                    Label("Open from your library", systemImage: "books.vertical")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WideButtonStyle())
                .help("Every video opened in Mimesis, with its tags")
            }
            if !recent.isEmpty {
                // Recent projects: one tap to carry on.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Recent projects").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        Spacer()
                        Button("All…", action: onAllProjects)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .help("Every recent project, with where it is; delete one, or find another")
                    }
                    ForEach(recent.prefix(sideways ? 2 : 4)) { project in
                        Button { onOpenProject(project) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "rectangle.split.2x1").foregroundStyle(Theme.accent)
                                Text(project.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(project.date.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open this project: both videos and every edit")
                    }
                }
                .padding(.top, 4)
            }
            #if os(macOS)
            Label("Or drop one or two videos, or a project, here", systemImage: "arrow.down.doc")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary.opacity(0.8))
            #endif
            if !sideways {
                Label("Film in Slo-mo (240 fps), or at least 60 fps, for smooth slow motion", systemImage: "lightbulb")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder private var slots: some View {
        slot(0, title: "Clip A", detail: "Yours")
        slot(1, title: "Clip B", detail: "The one to learn from")
    }

    private func slot(_ side: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(side == 0 ? "A" : "B")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { onOpenPhotos(side) } label: {
                    Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipStyle(active: true))
                .help("Pick a video from Photos as clip \(side == 0 ? "A" : "B")")
                Button { onOpenFile(side) } label: {
                    Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipStyle())
                .help("Open a video file as clip \(side == 0 ? "A" : "B")")
            }
        }
        .padding(sideways ? 12 : 16)
        .frame(minWidth: 260, maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous)
            .strokeBorder(droppingOn == side ? Theme.accent : Theme.line, lineWidth: droppingOn == side ? 2 : 1))
        // Drop a video on this card: it goes in as this clip.
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { isVideo($0) || isProject($0) }
            guard !videos.isEmpty else { return false }
            onDropped(videos, videos.count >= 2 ? nil : side)
            return true
        } isTargeted: { droppingOn = $0 ? side : (droppingOn == side ? nil : droppingOn) }
    }
}

/// A full-width quiet button for the welcome screen's other ways in.
struct WideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 48)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}
