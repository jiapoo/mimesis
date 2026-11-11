@testable import MimesisKit
import Foundation
import Testing

/// A project keeps its own copies of the videos and every edit (opt-in: set MIMESIS_CLIP_A and MIMESIS_CLIP_B).
@MainActor
struct ProjectTests {
    nonisolated static let paths = (ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"],
                                    ProcessInfo.processInfo.environment["MIMESIS_CLIP_B"])

    @Test(.enabled(if: paths.0 != nil && paths.1 != nil))
    func aProjectOpensAgainWithoutTheOriginals() async throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("mimesis-project-\(UUID().uuidString)")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }
        // The originals, somewhere they can be deleted from.
        let originals = [home.appendingPathComponent("mine.mp4"), home.appendingPathComponent("pro.mp4")]
        try files.copyItem(at: URL(fileURLWithPath: Self.paths.0!), to: originals[0])
        try files.copyItem(at: URL(fileURLWithPath: Self.paths.1!), to: originals[1])

        let store = ComparisonStore(folder: home.appendingPathComponent("store"))
        let comparison = Comparison()
        await comparison.clips[0].open(originals[0])
        await comparison.clips[1].open(originals[1])
        comparison.clips[0].trimStart = 0.5
        comparison.clips[0].syncs = [1]
        comparison.clips[1].syncs = [0.75]
        comparison.clips[1].speed = 0.8
        comparison.addSegment(named: "Second")
        comparison.clips[0].trimStart = 2

        let hadProject = store.saveCurrent(comparison)
        #expect(!hadProject)
        // A project is a file wherever the user says: a package with the edits and the videos.
        let file = home.appendingPathComponent("Somewhere").appendingPathComponent("Compare.mimesis")
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = store.save(comparison, to: file)
        #expect(saved)
        #expect(store.currentName == "Compare")
        #expect(files.fileExists(atPath: file.appendingPathComponent("project.json").path))
        #expect(files.fileExists(atPath: file.appendingPathComponent("mine.mp4").path))

        // Edit, and save over it: still one project, one recent.
        comparison.clips[0].syncs = [2.5]
        let savedOver = store.saveCurrent(comparison)
        #expect(savedOver)
        #expect(store.recents.count == 1)

        // The originals go; the next launch opens the project from the recent list, from its own copies.
        for clip in comparison.clips { clip.close() }
        for original in originals { try files.removeItem(at: original) }
        let later = ComparisonStore(folder: home.appendingPathComponent("store"))
        let recent = try #require(later.recents.first)
        #expect(recent.name == "Compare")
        let reopened = Comparison()
        let opened = await later.open(recent, into: reopened)
        #expect(opened)
        let bothOpen = reopened.clips[0].isLoaded && reopened.clips[1].isLoaded
        #expect(bothOpen)
        // The segment that was chosen, and the other one.
        #expect(reopened.segments.map(\.name) == ["Segment 1", "Second"])
        #expect(reopened.clips[0].trimStart == 2 && reopened.clips[0].syncs == [2.5])
        reopened.selectSegment(0)
        #expect(reopened.clips[0].trimStart == 0.5 && reopened.clips[1].speed == 0.8)
        #expect(reopened.clips[0].name == "mine")

        // Moved away: opening it says so, and it leaves the list.
        try files.removeItem(at: file)
        let again = await later.open(recent, into: Comparison())
        #expect(!again && later.recents.isEmpty && later.problem != nil)
    }
}
