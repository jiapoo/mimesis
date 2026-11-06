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

    private let preload: [URL?]

    /// - Parameter preload: clips to open as A and B at launch (for testing).
    public init(preload: [URL?] = []) {
        self.preload = preload
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { space in
                let wide = space.size.width >= space.size.height
                let layout = wide ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
                layout {
                    ForEach(paneIndices, id: \.self) { index in
                        ClipPane(
                            clip: comparison.clips[index],
                            letter: index == 0 ? "A" : "B",
                            linked: comparison.linked,
                            focused: comparison.focus == index && !comparison.linked && comparison.clips[index].isLoaded,
                            onFocus: { comparison.focus = index },
                            onOpenFile: { importing = index },
                            onOpenPhotos: { photoTarget = index },
                            onDropped: { url in open(url, in: index) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            Transport(comparison: comparison)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .background(keys)
        .task {
            for (index, url) in preload.prefix(2).enumerated() {
                if let url { await comparison.clips[index].open(url) }
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
            .frame(minWidth: 800, minHeight: 600)
        }
    }

    private var paneIndices: [Int] {
        switch comparison.layout {
        case .both: [0, 1]
        case .left: [0]
        case .right: [1]
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                EchoMark().frame(width: 22, height: 22)
                Text("Mimesis").font(.system(size: 15, weight: .semibold))
            }

            Spacer()

            HStack(spacing: 2) {
                ForEach(Comparison.Layout.allCases) { layout in
                    let on = comparison.layout == layout
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { comparison.layout = layout }
                    } label: {
                        Text(layout.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(on ? Color.black : Color.white.opacity(0.75))
                            .frame(width: 52, height: 26)
                            .background(on ? Color.white : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Theme.raised, in: Capsule())
            .focusEffectDisabled()

            Spacer()

            Menu {
                Button("Masking test…", systemImage: "person.crop.rectangle") { maskTest = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Theme.raised, in: Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func open(_ url: URL, in index: Int) {
        comparison.linked = false
        comparison.focus = index
        Task { await comparison.clips[index].open(url) }
    }

    /// Keys, as in Movist, for both clips while linked, else the selected one;
    /// plus [ ] for the trim and S for the sync point.
    @ViewBuilder private var keys: some View {
        Group {
            if let clip = comparison.focused, !comparison.linked {
                key("[") { clip.setTrimStart() }
                key("]") { clip.setTrimEnd() }
                key("s") { clip.setSync() }
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

/// A video picked from Photos, copied to a file the app can open.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Picked", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
