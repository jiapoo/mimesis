import Foundation

/// One of several videos that take turns in a clip (A or B): the same movement filmed on another day.
/// Each keeps its own share of every segment (In/Out, sync points, speed, drawings, notes), so going
/// back to a take shows it as it was left, against the same other clip.
public struct Take: Identifiable, Equatable {
    public var id = UUID()
    public var url: URL
    /// When it was filmed (the file's date), to list the takes in order and see progress over time.
    public var date: Date
    /// Its share of each segment, by the segment's id.
    var parts: [UUID: Segment.Part] = [:]

    public var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL, date: Date? = nil) {
        self.url = url
        self.date = date ?? Take.filmed(url)
    }

    /// The file's creation date (when it was filmed, for a video straight from a camera).
    static func filmed(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
    }
}

extension Comparison {
    /// Puts what the clip shows into its take (before another take goes on).
    private func stashTake(_ index: Int) {
        guard takes[index].indices.contains(takeIndex[index]) else { return }
        storeSegment()
        var parts: [UUID: Segment.Part] = [:]
        for segment in segments { parts[segment.id] = segment.parts[index] }
        takes[index][takeIndex[index]].parts = parts
    }

    /// Adds another video to a clip as a new take and shows it. The video there now becomes the first
    /// take, if it wasn't one yet.
    public func addTake(_ url: URL, to index: Int) async {
        let clip = clips[index]
        linked = false
        drawing = nil
        if takes[index].isEmpty, let current = clip.url {
            takes[index] = [Take(url: current)]
            takeIndex[index] = 0
        }
        stashTake(index)
        // Already a take: show it.
        if let at = takes[index].firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            await selectTake(at, in: index)
            return
        }
        await clip.open(url)
        for at in segments.indices { segments[at].parts[index] = Segment.Part() }
        loadSegment(segmentIndex)
        takes[index].append(Take(url: url))
        // In the order they were filmed.
        let added = takes[index].last!.id
        takes[index].sort { $0.date < $1.date }
        takeIndex[index] = takes[index].firstIndex { $0.id == added } ?? takes[index].count - 1
    }

    /// Shows another take in the clip, as it was left.
    public func selectTake(_ at: Int, in index: Int) async {
        guard takes[index].indices.contains(at), at != takeIndex[index] || clips[index].url != takes[index][at].url else { return }
        linked = false
        drawing = nil
        stashTake(index)
        let take = takes[index][at]
        await clips[index].open(take.url)
        for i in segments.indices { segments[i].parts[index] = take.parts[segments[i].id] ?? Segment.Part() }
        takeIndex[index] = at
        loadSegment(segmentIndex)
        goToStart()
    }

    /// Takes a take off the list (its video file stays). The one showing: another is shown first.
    public func removeTake(_ at: Int, in index: Int) async {
        guard takes[index].indices.contains(at), takes[index].count > 1 else { return }
        if at == takeIndex[index] {
            await selectTake(at == 0 ? 1 : at - 1, in: index)
        }
        guard takes[index].indices.contains(at), at != takeIndex[index] else { return }
        let showing = takes[index][takeIndex[index]].id
        takes[index].remove(at: at)
        takeIndex[index] = takes[index].firstIndex { $0.id == showing } ?? 0
        if takes[index].count == 1 { takes[index] = [] }
    }
}
