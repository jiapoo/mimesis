import AreteMedia
import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

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
    /// The speed is the automatic one (`speed` is then only what it came to). Nil in older saves.
    var auto: Bool?
}

/// A comparison as saved: both clips, and how they're shown and played.
struct ComparisonState: Codable {
    var clips: [ClipState?]
    var layout: String
    var linked: Bool
    var linkedSpeed: Double
    /// Nil in comparisons saved before the overlay existed.
    var overlay: OverlayState?
    /// Every segment, and the one chosen (the clips' own states repeat that one). Nil in older saves:
    /// then the clips' states are the one segment.
    var segments: [Segment]?
    var segment: Int?
    /// Each clip's takes and the one showing. Nil without takes.
    var takes: [[TakeState]]?
    var take: [Int]?
}

/// A take as saved: where its video is, when it was filmed, and its share of each segment.
struct TakeState: Codable {
    var bookmark: Data
    /// In a project: the name of the project's own copy.
    var file: String?
    var date: Date
    var parts: [String: Segment.Part]
}

struct OverlayState: Codable {
    var top: Int
    var opacity: Double
    var offset: CGSize
    var scale: Double
    /// Nil in comparisons saved before rotation existed.
    var rotation: Double?
}

/// A comparison saved inside Mimesis before projects were files; moved into a project file on first launch.
struct SavedComparison: Codable {
    var id = UUID()
    var name: String
    var date: Date
    var state: ComparisonState
    var hasFolder: Bool?
}

/// A project file opened or saved lately: where it is (a bookmark, so it's found again after it moves
/// and can be opened again after the app quits) and when.
public struct RecentProject: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var date: Date
    var bookmark: Data
}

/// Projects, and the comparison on screen so it comes back at the next launch.
///
/// A project is a file, `Name.mimesis`, wherever the user saves it: a package (a folder that shows as
/// one file) holding `project.json` (every segment and edit) and the project's own copies of the two
/// videos, so it opens on any Mac, iPad or iPhone, whatever happens to the originals.
@MainActor @Observable
public final class ComparisonStore {
    public nonisolated static let fileExtension = "mimesis"

    /// The projects opened or saved lately, the most recent first.
    public private(set) var recents: [RecentProject] = []
    /// The project on screen, if it was opened from (or saved as) one: Save writes over it.
    public private(set) var currentURL: URL?
    public var currentName: String? { currentURL?.deletingPathExtension().lastPathComponent }
    /// Goes up each time a project is opened.
    public private(set) var opens = 0
    /// Why the last save or open failed, to show.
    public var problem: String?

    private let folder: URL
    private var recentsFile: URL { folder.appendingPathComponent("Recent projects.json") }
    private var lastFile: URL { folder.appendingPathComponent("Last comparison.json") }

    /// - Parameter folder: where to keep the list of recent projects (tests); Application Support/Mimesis otherwise.
    public init(folder: URL? = nil) {
        self.folder = folder ?? ComparisonStore.supportFolder
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        recents = (try? JSONDecoder().decode([RecentProject].self, from: Data(contentsOf: recentsFile))) ?? []
        moveOldProjects()
        refreshRecents()
    }

    /// Application Support/Mimesis: the recent projects, and copies of clips picked from Photos.
    nonisolated static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Mimesis", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Where projects go when the user isn't asked (iPhone and iPad): the app's Documents folder, which
    /// shows in the Files app as "Mimesis".
    public nonisolated static var documentsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: Saving

    /// Saves what's on screen as the project file at `url` (made, or written over), and makes it the
    /// project on screen.
    @discardableResult
    public func save(_ comparison: Comparison, to url: URL) -> Bool {
        guard let state = comparison.state() else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let files = FileManager.default
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            let kept = keepVideos(of: comparison, state: state, in: url)
            let data = try JSONEncoder().encode(kept)
            try data.write(to: url.appendingPathComponent("project.json"), options: .atomic)
            currentURL = url
            note(url)
            return true
        } catch {
            problem = "Couldn't save the project: \(error.localizedDescription)"
            return false
        }
    }

    /// Saves over the project on screen. False when there's none (ask where to save).
    @discardableResult
    public func saveCurrent(_ comparison: Comparison) -> Bool {
        guard let url = currentURL else { return false }
        return save(comparison, to: url)
    }

    /// Copies each clip's video into the project (unless it's the copy already there), and notes its
    /// name in the state. On the same disk the copy takes no extra room until one of them changes.
    private func keepVideos(of comparison: Comparison, state: ComparisonState, in target: URL) -> ComparisonState {
        var state = state
        let files = FileManager.default
        var kept: Set<String> = ["project.json"]
        for (index, clip) in comparison.clips.enumerated() {
            guard let url = clip.url, state.clips[index] != nil else { continue }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            // A video already in this project keeps its name (even after A and B are swapped).
            var name = url.lastPathComponent
            if url.deletingLastPathComponent().standardizedFileURL != target.standardizedFileURL {
                name = "\(url.deletingPathExtension().lastPathComponent).\(ext)"
                // Two different videos with one name: the second gets a number.
                if kept.contains(name) { name = "\(url.deletingPathExtension().lastPathComponent) 2.\(ext)" }
                let copy = target.appendingPathComponent(name)
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
        // The other takes' videos too.
        for (slot, takes) in comparison.takes.enumerated() {
            for (at, take) in takes.enumerated() where state.takes?[slot].indices.contains(at) == true {
                var name = take.url.lastPathComponent
                if take.url.deletingLastPathComponent().standardizedFileURL != target.standardizedFileURL {
                    let copy = target.appendingPathComponent(name)
                    let same = files.fileExists(atPath: copy.path)
                        && (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) == (try? take.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    if !same {
                        if files.fileExists(atPath: copy.path) {
                            name = "\(take.url.deletingPathExtension().lastPathComponent) \(at + 1).\(take.url.pathExtension)"
                        }
                        do { try files.copyItem(at: take.url, to: target.appendingPathComponent(name)) } catch { continue }
                    }
                }
                state.takes?[slot][at].file = name
                kept.insert(name)
            }
        }
        // A video replaced since the last save: its old copy goes.
        for old in (try? files.contentsOfDirectory(atPath: target.path)) ?? [] where !kept.contains(old) {
            try? files.removeItem(at: target.appendingPathComponent(old))
        }
        return state
    }

    // MARK: Opening

    /// Opens the project file at `url`. False (with `problem` set) when it can't be read.
    @discardableResult
    public func open(_ url: URL, into comparison: Comparison) async -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        guard let data = try? Data(contentsOf: url.appendingPathComponent("project.json")),
              let state = try? JSONDecoder().decode(ComparisonState.self, from: data) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            problem = "“\(url.lastPathComponent)” isn't a Mimesis project, or can't be read."
            return false
        }
        // Access is kept while the project is open: its videos play from inside it.
        await comparison.restore(state, videos: url)
        currentURL = url
        note(url)
        opens += 1
        return true
    }

    /// Opens a recent project. False when its file is gone (it's then dropped from the list).
    @discardableResult
    public func open(_ recent: RecentProject, into comparison: Comparison) async -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, options: projectResolve, bookmarkDataIsStale: &stale),
              (url.startAccessingSecurityScopedResource() || true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) else {
            problem = "“\(recent.name)” has been moved or deleted."
            forget(recent)
            return false
        }
        return await open(url, into: comparison)
    }

    /// Where a recent project is now (found through its bookmark, even after it's been moved).
    public func location(of recent: RecentProject) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: recent.bookmark, options: projectResolve.union(.withoutUI), bookmarkDataIsStale: &stale)
    }

    /// Where a recent project is, to read: on the Mac its full path ("~/Documents/Serve.mimesis"); on
    /// iPhone and iPad where it shows in the Files app.
    public func path(of recent: RecentProject) -> String {
        guard let url = location(of: recent) else { return "Moved or deleted" }
        #if os(macOS)
        return (url.path as NSString).abbreviatingWithTildeInPath
        #else
        if url.path.hasPrefix(Self.documentsFolder.path) { return "Files › On My \(UIDevice.current.model) › Mimesis › \(url.lastPathComponent)" }
        return url.deletingLastPathComponent().lastPathComponent + " › " + url.lastPathComponent
        #endif
    }

    /// Deletes a project's file (on the Mac: to the Trash, so it can be put back) and drops it from
    /// the list. False (with `problem` set) when the file couldn't be removed.
    @discardableResult
    public func delete(_ recent: RecentProject) -> Bool {
        guard let url = location(of: recent), FileManager.default.fileExists(atPath: url.path) else {
            forget(recent)
            return true
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            #if os(macOS)
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { try FileManager.default.removeItem(at: url) }
            #else
            try FileManager.default.removeItem(at: url)
            #endif
            if currentURL?.standardizedFileURL == url.standardizedFileURL { currentURL = nil }
            forget(recent)
            return true
        } catch {
            problem = "Couldn't delete “\(recent.name)”: \(error.localizedDescription)"
            return false
        }
    }

    /// Drops the recent projects whose file is gone: deleted, or sitting in the Trash (a bookmark
    /// follows a file there, so it would otherwise stay in the list, and open).
    public func refreshRecents() {
        let kept = recents.filter { recent in
            guard let url = location(of: recent) else { return false }
            if url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) { return false }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path)
        }
        guard kept.count != recents.count else { return }
        recents = kept
        write(recents, to: recentsFile)
    }

    public func forget(_ recent: RecentProject) {
        recents.removeAll { $0.id == recent.id }
        write(recents, to: recentsFile)
    }

    /// Puts a project at the top of the recent ones.
    private func note(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: projectBookmark) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        // The same file again keeps its place in the list's identity (it only moves to the top).
        var id = UUID()
        recents.removeAll { recent in
            var stale = false
            let other = try? URL(resolvingBookmarkData: recent.bookmark, options: projectResolve.union(.withoutUI), bookmarkDataIsStale: &stale)
            guard other?.standardizedFileURL == url.standardizedFileURL else { return false }
            id = recent.id
            return true
        }
        recents.insert(RecentProject(id: id, name: name, date: .now, bookmark: bookmark), at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        write(recents, to: recentsFile)
    }

    /// Starts afresh: both clips closed, no project.
    public func closeProject(_ comparison: Comparison) {
        comparison.linked = false
        for clip in comparison.clips { clip.close() }
        comparison.resetSegments()
        currentURL?.stopAccessingSecurityScopedResource()
        currentURL = nil
    }

    /// A free name for a new project in the Documents folder: "Name.mimesis", "Name 2.mimesis"…
    public func documentURL(named name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = Self.documentsFolder.appendingPathComponent(clean).appendingPathExtension(Self.fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = Self.documentsFolder.appendingPathComponent("\(clean) \(number)").appendingPathExtension(Self.fileExtension)
            number += 1
        }
        return url
    }

    /// Projects saved inside Mimesis before they were files: each becomes a project file in Documents.
    private func moveOldProjects() {
        let files = FileManager.default
        let oldList = folder.appendingPathComponent("Saved comparisons.json")
        guard let old = try? JSONDecoder().decode([SavedComparison].self, from: Data(contentsOf: oldList)) else { return }
        for item in old.reversed() {
            let videos = folder.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(item.id.uuidString, isDirectory: true)
            let target = documentURL(named: item.name)
            do {
                if files.fileExists(atPath: videos.path) {
                    try files.moveItem(at: videos, to: target)
                } else {
                    try files.createDirectory(at: target, withIntermediateDirectories: true)
                }
                try JSONEncoder().encode(item.state).write(to: target.appendingPathComponent("project.json"))
                note(target)
            } catch {}
        }
        try? files.removeItem(at: oldList)
    }

    // MARK: The comparison on screen

    /// The comparison on screen, remembered for the next launch.
    public func remember(_ comparison: Comparison) {
        if let state = comparison.state() {
            write(state, to: lastFile)
            let bookmark = currentURL.flatMap { try? $0.bookmarkData(options: projectBookmark) }
            UserDefaults.standard.set(bookmark, forKey: "currentProjectFile")
        } else {
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    /// Opens what was on screen last time, if anything.
    public func restoreLast(into comparison: Comparison) async {
        guard let data = try? Data(contentsOf: lastFile),
              let state = try? JSONDecoder().decode(ComparisonState.self, from: data) else { return }
        // Still the project it was: its videos are opened from inside it.
        var project: URL?
        if let bookmark = UserDefaults.standard.data(forKey: "currentProjectFile") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: projectResolve, bookmarkDataIsStale: &stale),
               (url.startAccessingSecurityScopedResource() || true),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                project = url
            }
        }
        await comparison.restore(state, videos: project)
        currentURL = project
    }

    private func write(_ value: some Encodable, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

#if os(macOS)
/// A project file is written to, so its bookmark allows writing (unlike a clip's).
let projectBookmark: URL.BookmarkCreationOptions = [.withSecurityScope]
let projectResolve: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
let projectBookmark: URL.BookmarkCreationOptions = []
let projectResolve: URL.BookmarkResolutionOptions = []
#endif

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
            bookmark: bookmark, trimStart: trimStart, trimEnd: trimEnd, sync: syncs.first, syncs: syncs, speed: speed ?? 1,
            mirrored: engine.mirroredHorizontally, drawings: drawings,
            cutout: cutout?.state == .ready ? true : nil,
            pick: cutout?.pickedAt.map { [$0.time, $0.point.x, $0.point.y] },
            box: cutout?.boxed == true ? true : nil, auto: speed == nil)
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
        // Saved before speeds could be automatic: 1× was "not set".
        speed = state.auto ?? (state.speed == 1) ? nil : state.speed
        drawings = state.drawings ?? []
        if state.mirrored { await engine.setMirror(horizontal: true, vertical: false) }
        if state.cutout == true {
            let pick = state.pick.flatMap { $0.count == 3 ? (time: $0[0], point: CGPoint(x: $0[1], y: $0[2])) : nil }
            makeCutout(pickAt: pick)
            cutout?.boxed = state.box ?? false
        }
        await engine.seekToTime(trimStart)
        return true
    }
}

extension Comparison {
    /// Nil when no clip is open: nothing to save.
    func state() -> ComparisonState? {
        let clips = clips.map { $0.state() }
        guard clips.contains(where: { $0 != nil }) else { return nil }
        storeSegment()
        // The takes, each with its share of every segment (the one showing: as the clip has it now).
        var savedTakes: [[TakeState]]?
        if takes.contains(where: { !$0.isEmpty }) {
            savedTakes = takes.enumerated().map { slot, list in
                list.enumerated().compactMap { at, take -> TakeState? in
                    guard let bookmark = try? take.url.bookmarkData(options: bookmarkOptions) else { return nil }
                    var parts: [String: Segment.Part] = [:]
                    for segment in segments {
                        parts[segment.id.uuidString] = at == takeIndex[slot] ? segment.parts[slot] : take.parts[segment.id]
                    }
                    return TakeState(bookmark: bookmark, file: nil, date: take.date, parts: parts)
                }
            }
        }
        return ComparisonState(
            clips: clips, layout: layout.rawValue, linked: linked, linkedSpeed: linkedSpeed,
            overlay: OverlayState(top: overlayTop, opacity: overlayOpacity, offset: overlayOffset, scale: overlayScale,
                                  rotation: overlayRotation),
            segments: segments, segment: segmentIndex, takes: savedTakes, take: savedTakes == nil ? nil : takeIndex)
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
        // The segments: as saved, or, from an older save, the one the clips came back with.
        if let saved = state.segments, !saved.isEmpty {
            segments = saved
            segmentIndex = min(max(0, state.segment ?? 0), saved.count - 1)
            // Whatever a clip that couldn't be opened had is kept; the chosen one goes on the clips.
            loadSegment(segmentIndex)
        } else {
            segments = [Segment(name: "Segment 1")]
            segmentIndex = 0
            storeSegment()
        }
        // The takes: each one's video from the project's copy, else where it was.
        takes = [[], []]
        takeIndex = [0, 0]
        if let saved = state.takes {
            for (slot, list) in saved.enumerated().prefix(2) {
                var found: [Take] = []
                var showing = 0
                for (at, item) in list.enumerated() {
                    var url: URL?
                    if let videos, let file = item.file, FileManager.default.fileExists(atPath: videos.appendingPathComponent(file).path) {
                        url = videos.appendingPathComponent(file)
                    } else {
                        var stale = false
                        url = try? URL(resolvingBookmarkData: item.bookmark, options: resolveOptions, bookmarkDataIsStale: &stale)
                        _ = url?.startAccessingSecurityScopedResource()
                    }
                    guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
                    var take = Take(url: url, date: item.date)
                    for (key, part) in item.parts { if let id = UUID(uuidString: key) { take.parts[id] = part } }
                    if at == (state.take?[slot] ?? 0) { showing = found.count }
                    found.append(take)
                }
                if found.count > 1 {
                    takes[slot] = found
                    takeIndex[slot] = showing
                }
            }
        }
        if state.linked, canLink { linked = true }
    }
}
