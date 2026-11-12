import AreteMedia
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
    /// The file's size in bytes; with the name it finds the same clip on another device. Nil in older libraries.
    var size: Int?
    /// When the notes or tags last changed, so the newer copy wins when syncing.
    var changed: Date?
    /// Tags removed here, so syncing doesn't bring them back from another device.
    var removedTags: [UUID]?

    /// The same clip on every device: its name and size.
    var syncKey: String? { size.map { "clip:\(name)|\($0)" } }

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
    public static let presets = ["Good", "Mistake", "Key moment", "To review"]

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
        var clip = LibraryClip(bookmark: bookmark, path: Self.key(url), name: url.deletingPathExtension().lastPathComponent,
                               added: .now)
        clip.size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        // Notes and tags made for this clip on another device.
        if let key = clip.syncKey, let remote = sync?.read(key) { Self.merge(remote, into: &clip) }
        clips.insert(clip, at: 0)
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
        touched(at)
    }

    public func removeTag(_ tag: MomentTag, from clip: LibraryClip) {
        guard let at = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[at].tags.removeAll { $0.id == tag.id }
        clips[at].removedTags = (clips[at].removedTags ?? []) + [tag.id]
        touched(at)
    }

    public func setNotes(_ notes: String, for clip: LibraryClip) {
        guard let at = clips.firstIndex(where: { $0.id == clip.id }), clips[at].notes != notes else { return }
        clips[at].notes = notes
        touched(at)
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

    // MARK: - Syncing notes and tags through iCloud

    /// Shares notes and tags with the user's other devices; nil when iCloud isn't available.
    private var sync: LibrarySync?

    /// Starts syncing through `store` (iCloud's key-value store in the app).
    func startSync(_ store: LibrarySync) {
        sync = store
        store.onChange = { [weak self] keys in self?.pull(keys) }
        pull(nil)
        for index in clips.indices { push(index) }
    }

    /// What one clip's notes and tags look like in iCloud.
    struct Shared: Codable {
        var notes: String
        var tags: [MomentTag]
        var removed: [UUID]
        var changed: Date
    }

    private func touched(_ index: Int) {
        clips[index].changed = .now
        save()
        push(index)
    }

    private func push(_ index: Int) {
        guard let sync, let key = clips[index].syncKey else { return }
        let clip = clips[index]
        sync.write(Shared(notes: clip.notes, tags: clip.tags, removed: clip.removedTags ?? [],
                          changed: clip.changed ?? clip.added), for: key)
    }

    /// Takes what other devices changed (all keys when nil) into the matching clips here.
    private func pull(_ keys: [String]?) {
        guard let sync else { return }
        var changedAny = false
        for index in clips.indices {
            guard let key = clips[index].syncKey, keys?.contains(key) ?? true, let remote = sync.read(key) else { continue }
            let before = (clips[index].notes, clips[index].tags)
            Self.merge(remote, into: &clips[index])
            if before != (clips[index].notes, clips[index].tags) { changedAny = true }
        }
        if changedAny { save() }
    }

    /// Tags: everyone's, except those removed anywhere. Notes: the newer copy's.
    static func merge(_ remote: Shared, into clip: inout LibraryClip) {
        let removed = Set(remote.removed + (clip.removedTags ?? []))
        var tags = clip.tags
        for tag in remote.tags where !tags.contains(where: { $0.id == tag.id }) { tags.append(tag) }
        clip.tags = tags.filter { !removed.contains($0.id) }.sorted { $0.time < $1.time }
        clip.removedTags = Array(removed)
        if remote.changed > (clip.changed ?? .distantPast) || clip.notes.isEmpty {
            if !remote.notes.isEmpty || remote.changed > (clip.changed ?? .distantPast) { clip.notes = remote.notes }
            clip.changed = max(remote.changed, clip.changed ?? .distantPast)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
