import Foundation
import Observation

/// A moment tagged in a clip: "forehand" at 3.20 s.
public struct MomentTag: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var time: Double
    public var label: String
}

/// A clip the library knows: where it is (a bookmark, to open it again), its notes and tagged moments.
public struct LibraryClip: Codable, Identifiable {
    public var id = UUID()
    var bookmark: Data
    /// The file's path when it was added, to recognise it when it's opened again.
    var path: String
    public var name: String
    public var added: Date
    public var notes: String = ""
    public var tags: [MomentTag] = []

    /// The file again, or nil when it can't be found.
    func resolve() -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: resolveOptions, bookmarkDataIsStale: &stale)
        else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Every clip opened in Mimesis, newest first, with notes and tagged moments; kept as JSON in Application Support.
@MainActor @Observable
public final class Library {
    public private(set) var clips: [LibraryClip] = []
    /// Suggested tags; labels the user makes are added after them.
    public static let presets = ["Forehand", "Backhand", "Serve", "Return", "Volley", "Smash", "Good", "Fault"]

    private let file: URL

    public convenience init() {
        self.init(file: ComparisonStore.supportFolder.appendingPathComponent("Library.json"))
    }

    init(file: URL) {
        self.file = file
        clips = (try? JSONDecoder().decode([LibraryClip].self, from: Data(contentsOf: file))) ?? []
    }

    /// Every label used, presets first.
    public var labels: [String] {
        var seen = Self.presets
        for clip in clips { for tag in clip.tags where !seen.contains(tag.label) { seen.append(tag.label) } }
        return seen
    }

    /// Remembers a clip that was opened (once; opening it again changes nothing).
    public func record(_ url: URL) {
        guard index(of: url) == nil, let bookmark = try? url.bookmarkData(options: bookmarkOptions) else { return }
        clips.insert(LibraryClip(bookmark: bookmark, path: Self.key(url), name: url.deletingPathExtension().lastPathComponent,
                                 added: .now), at: 0)
        save()
    }

    public func entry(for url: URL) -> LibraryClip? {
        index(of: url).map { clips[$0] }
    }

    /// Tags the moment at `time` in the clip at `url` (adding the clip if it's new).
    public func tag(_ url: URL, at time: Double, label: String) {
        record(url)
        guard let at = index(of: url) else { return }
        clips[at].tags.append(MomentTag(time: time, label: label))
        clips[at].tags.sort { $0.time < $1.time }
        save()
    }

    public func removeTag(_ tag: MomentTag, from clip: LibraryClip) {
        guard let at = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[at].tags.removeAll { $0.id == tag.id }
        save()
    }

    public func setNotes(_ notes: String, for clip: LibraryClip) {
        guard let at = clips.firstIndex(where: { $0.id == clip.id }), clips[at].notes != notes else { return }
        clips[at].notes = notes
        save()
    }

    public func remove(_ clip: LibraryClip) {
        clips.removeAll { $0.id == clip.id }
        save()
    }

    /// Every tagged moment with `label` across the library, clip by clip, in time order.
    public func moments(labelled label: String) -> [(clip: LibraryClip, tag: MomentTag)] {
        clips.flatMap { clip in clip.tags.filter { $0.label == label }.map { (clip, $0) } }
    }

    private func index(of url: URL) -> Int? {
        let key = Self.key(url)
        return clips.firstIndex { $0.path == key }
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
