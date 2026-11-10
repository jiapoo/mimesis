import Foundation
import Observation

/// What a saved comparison remembers about one clip: the file (as a bookmark, so it can be found and
/// opened again after the app quits) and everything that lines it up with the other clip.
struct ClipState: Codable {
    var bookmark: Data
    var trimStart: Double
    var trimEnd: Double?
    /// The first sync point; comparisons saved before there could be several keep only this.
    var sync: Double?
    var syncs: [Double]?
    var speed: Double
    var mirrored: Bool
    /// Nil in comparisons saved before drawing existed.
    var drawings: [Drawing]?
    /// The clip had a cutout (made again from its saved copy on reopening), and the player picked in it:
    /// clip time, then 0–1 across and down as filmed.
    var cutout: Bool?
    var pick: [Double]?
    /// The cutout drawn as a soft box rather than an outline.
    var box: Bool?
    /// In a project: the name of the project's own copy of the video, in the project's folder.
    var file: String?
}

/// A comparison as saved: both clips, and how they're shown and played.
struct ComparisonState: Codable {
    var clips: [ClipState?]
    var layout: String
    var linked: Bool
    var linkedSpeed: Double
    /// Nil in comparisons saved before the overlay existed.
    var overlay: OverlayState?
}

struct OverlayState: Codable {
    var top: Int
    var opacity: Double
    var offset: CGSize
    var scale: Double
    /// Nil in comparisons saved before rotation existed.
    var rotation: Double?
}

/// A project: a comparison saved by name, with every edit (trims, sync points, speeds, drawings, the
/// overlay) and its own copies of the two videos, so it opens again whatever happens to the originals.
public struct SavedComparison: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    /// When it was last saved or opened: the most recent first.
    public var date: Date
    var state: ComparisonState
    /// Has its own folder with copies of the videos (nil in comparisons saved before projects).
    var hasFolder: Bool?
}

/// Keeps the saved comparisons, and the one on screen so it comes back at the next launch.
/// Stored as JSON in Application Support.
@MainActor @Observable
public final class ComparisonStore {
    public private(set) var saved: [SavedComparison] = []
    /// The project on screen, if it was opened from (or saved as) one: Save writes over it.
    public private(set) var currentID: UUID?
    public var current: SavedComparison? { saved.first { $0.id == currentID } }

    private let folder: URL
    private var savedFile: URL { folder.appendingPathComponent("Saved comparisons.json") }
    private var lastFile: URL { folder.appendingPathComponent("Last comparison.json") }

    /// - Parameter folder: where to keep them (tests); Application Support/Mimesis otherwise.
    public init(folder: URL? = nil) {
        self.folder = folder ?? ComparisonStore.supportFolder
        saved = (try? JSONDecoder().decode([SavedComparison].self, from: Data(contentsOf: savedFile))) ?? []
    }

    /// Application Support/Mimesis: saved comparisons, and copies of clips picked from Photos.
    nonisolated static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Mimesis", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Application Support/Mimesis/Projects/<id>: a project's own copies of its videos.
    private func folder(of id: UUID) -> URL {
        folder.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Saves what's on screen as a new project.
    public func save(_ comparison: Comparison, as name: String) {
        guard let state = comparison.state() else { return }
        var project = SavedComparison(name: name, date: .now, state: state, hasFolder: true)
        project.state = keepVideos(of: comparison, state: state, in: project.id)
        saved.insert(project, at: 0)
        currentID = project.id
        write(saved, to: savedFile)
    }

    /// Saves what's on screen over the project it came from. False when there's none (ask for a name).
    @discardableResult
    public func saveCurrent(_ comparison: Comparison) -> Bool {
        guard let id = currentID, let at = saved.firstIndex(where: { $0.id == id }),
              let state = comparison.state() else { return false }
        var project = saved.remove(at: at)
        project.state = keepVideos(of: comparison, state: state, in: id)
        project.hasFolder = true
        project.date = .now
        saved.insert(project, at: 0)
        write(saved, to: savedFile)
        return true
    }

    /// Copies each clip's video into the project's folder (unless it's the copy already there), and notes
    /// its name in the state. On the same disk the copy takes no extra room until one of them changes.
    private func keepVideos(of comparison: Comparison, state: ComparisonState, in id: UUID) -> ComparisonState {
        var state = state
        let files = FileManager.default
        let target = folder(of: id)
        try? files.createDirectory(at: target, withIntermediateDirectories: true)
        var kept: Set<String> = []
        for (index, clip) in comparison.clips.enumerated() {
            guard let url = clip.url, state.clips[index] != nil else { continue }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            // Named after the original, so the project's folder reads well: "A serve.mp4".
            let name = "\(index == 0 ? "A" : "B") \(url.deletingPathExtension().lastPathComponent).\(ext)"
            let copy = target.appendingPathComponent(name)
            if url.standardizedFileURL != copy.standardizedFileURL {
                let same = files.fileExists(atPath: copy.path)
                    && (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) == (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                if !same {
                    try? files.removeItem(at: copy)
                    do { try files.copyItem(at: url, to: copy) } catch { continue }
                }
            }
            state.clips[index]?.file = name
            kept.insert(name)
        }
        // A video replaced since the last save: its old copy goes.
        for old in (try? files.contentsOfDirectory(atPath: target.path)) ?? [] where !kept.contains(old) {
            try? files.removeItem(at: target.appendingPathComponent(old))
        }
        return state
    }

    public func rename(_ item: SavedComparison, to name: String) {
        guard let at = saved.firstIndex(where: { $0.id == item.id }) else { return }
        saved[at].name = name
        write(saved, to: savedFile)
    }

    public func delete(_ item: SavedComparison) {
        saved.removeAll { $0.id == item.id }
        if currentID == item.id { currentID = nil }
        try? FileManager.default.removeItem(at: folder(of: item.id))
        write(saved, to: savedFile)
    }

    /// Opens a project, and moves it to the top of the recent ones.
    public func open(_ item: SavedComparison, into comparison: Comparison) async {
        await comparison.restore(item.state, videos: item.hasFolder == true ? folder(of: item.id) : nil)
        currentID = item.id
        if let at = saved.firstIndex(where: { $0.id == item.id }) {
            var project = saved.remove(at: at)
            project.date = .now
            saved.insert(project, at: 0)
            write(saved, to: savedFile)
        }
    }

    /// Starts afresh: both clips closed, no project.
    public func closeProject(_ comparison: Comparison) {
        comparison.linked = false
        for clip in comparison.clips { clip.close() }
        currentID = nil
    }

    /// The comparison on screen, remembered for the next launch.
    public func remember(_ comparison: Comparison) {
        if let state = comparison.state() {
            write(state, to: lastFile)
            UserDefaults.standard.set(currentID?.uuidString, forKey: "currentProject")
        } else {
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    /// Opens what was on screen last time, if anything.
    public func restoreLast(into comparison: Comparison) async {
        guard let data = try? Data(contentsOf: lastFile),
              let state = try? JSONDecoder().decode(ComparisonState.self, from: data) else { return }
        await comparison.restore(state)
        // Still the project it was, if its videos are the project's own copies.
        if let id = UserDefaults.standard.string(forKey: "currentProject").flatMap(UUID.init(uuidString:)),
           saved.contains(where: { $0.id == id }),
           comparison.clips.compactMap(\.url).allSatisfy({ $0.path.contains(id.uuidString) }) {
            currentID = id
        }
    }

    private func write(_ value: some Encodable, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Turning a comparison into a state and back

#if os(macOS)
let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
let bookmarkOptions: URL.BookmarkCreationOptions = []
let resolveOptions: URL.BookmarkResolutionOptions = []
#endif

extension Clip {
    func state() -> ClipState? {
        guard let url, let bookmark = try? url.bookmarkData(options: bookmarkOptions) else { return nil }
        return ClipState(
            bookmark: bookmark, trimStart: trimStart, trimEnd: trimEnd, sync: syncs.first, syncs: syncs, speed: speed,
            mirrored: engine.mirroredHorizontally, drawings: drawings,
            cutout: cutout?.state == .ready ? true : nil,
            pick: cutout?.pickedAt.map { [$0.time, $0.point.x, $0.point.y] },
            box: cutout?.boxed == true ? true : nil)
    }

    /// Opens the clip's file again and puts back its trim, sync point, speed and mirror.
    /// False when the file can't be found any more.
    /// - Parameter videos: a project's folder: its own copy of the video is opened when it's there.
    func restore(_ state: ClipState, videos: URL? = nil) async -> Bool {
        var found: URL?
        if let videos, let file = state.file {
            let copy = videos.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: copy.path) { found = copy }
        }
        if found == nil {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: state.bookmark, options: resolveOptions,
                                     bookmarkDataIsStale: &stale) else { return false }
            let accessing = url.startAccessingSecurityScopedResource()
            let exists = FileManager.default.fileExists(atPath: url.path)
            if accessing { url.stopAccessingSecurityScopedResource() }
            guard exists else { return false }
            found = url
        }
        guard let url = found else { return false }
        await open(url)
        trimStart = state.trimStart
        trimEnd = state.trimEnd
        syncs = state.syncs ?? state.sync.map { [$0] } ?? []
        speed = state.speed
        drawings = state.drawings ?? []
        if state.mirrored { await engine.setMirror(horizontal: true, vertical: false) }
        if state.cutout == true {
            let pick = state.pick.flatMap { $0.count == 3 ? (time: $0[0], point: CGPoint(x: $0[1], y: $0[2])) : nil }
            makeCutout(pickAt: pick)
            cutout?.boxed = state.box ?? false
        }
        await engine.seekToTime(syncTime)
        return true
    }
}

extension Comparison {
    /// Nil when no clip is open: nothing to save.
    func state() -> ComparisonState? {
        let clips = clips.map { $0.state() }
        guard clips.contains(where: { $0 != nil }) else { return nil }
        return ComparisonState(
            clips: clips, layout: layout.rawValue, linked: linked, linkedSpeed: linkedSpeed,
            overlay: OverlayState(top: overlayTop, opacity: overlayOpacity, offset: overlayOffset, scale: overlayScale,
                                  rotation: overlayRotation))
    }

    func restore(_ state: ComparisonState, videos: URL? = nil) async {
        linked = false
        for (clip, saved) in zip(clips, state.clips) {
            if let saved {
                if await !clip.restore(saved, videos: videos) { clip.close() }
            } else {
                clip.close()
            }
        }
        layout = Layout(rawValue: state.layout) ?? .both
        linkedSpeed = state.linkedSpeed
        if let overlay = state.overlay {
            overlayTop = overlay.top
            overlayOpacity = overlay.opacity
            overlayOffset = overlay.offset
            overlayScale = overlay.scale
            overlayRotation = overlay.rotation ?? 0
        }
        if state.linked, canLink { linked = true }
    }
}
