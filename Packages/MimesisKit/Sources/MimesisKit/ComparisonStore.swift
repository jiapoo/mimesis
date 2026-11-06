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

/// A comparison the user saved by name.
public struct SavedComparison: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var date: Date
    var state: ComparisonState
}

/// Keeps the saved comparisons, and the one on screen so it comes back at the next launch.
/// Stored as JSON in Application Support.
@MainActor @Observable
public final class ComparisonStore {
    public private(set) var saved: [SavedComparison] = []

    private let folder: URL
    private var savedFile: URL { folder.appendingPathComponent("Saved comparisons.json") }
    private var lastFile: URL { folder.appendingPathComponent("Last comparison.json") }

    public init() {
        folder = ComparisonStore.supportFolder
        saved = (try? JSONDecoder().decode([SavedComparison].self, from: Data(contentsOf: savedFile))) ?? []
    }

    /// Application Support/Mimesis: saved comparisons, and copies of clips picked from Photos.
    nonisolated static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Mimesis", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func save(_ comparison: Comparison, as name: String) {
        guard let state = comparison.state() else { return }
        saved.insert(SavedComparison(name: name, date: .now, state: state), at: 0)
        write(saved, to: savedFile)
    }

    public func delete(_ item: SavedComparison) {
        saved.removeAll { $0.id == item.id }
        write(saved, to: savedFile)
    }

    public func open(_ item: SavedComparison, into comparison: Comparison) async {
        await comparison.restore(item.state)
    }

    /// The comparison on screen, remembered for the next launch.
    public func remember(_ comparison: Comparison) {
        if let state = comparison.state() {
            write(state, to: lastFile)
        } else {
            try? FileManager.default.removeItem(at: lastFile)
        }
    }

    /// Opens what was on screen last time, if anything.
    public func restoreLast(into comparison: Comparison) async {
        guard let data = try? Data(contentsOf: lastFile),
              let state = try? JSONDecoder().decode(ComparisonState.self, from: data) else { return }
        await comparison.restore(state)
    }

    private func write(_ value: some Encodable, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Turning a comparison into a state and back

#if os(macOS)
private let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
private let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
#else
private let bookmarkOptions: URL.BookmarkCreationOptions = []
private let resolveOptions: URL.BookmarkResolutionOptions = []
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
    func restore(_ state: ClipState) async -> Bool {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: state.bookmark, options: resolveOptions,
                                 bookmarkDataIsStale: &stale) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        let exists = FileManager.default.fileExists(atPath: url.path)
        if accessing { url.stopAccessingSecurityScopedResource() }
        guard exists else { return false }
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

    func restore(_ state: ComparisonState) async {
        linked = false
        for (clip, saved) in zip(clips, state.clips) {
            if let saved {
                if await !clip.restore(saved) { clip.close() }
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
