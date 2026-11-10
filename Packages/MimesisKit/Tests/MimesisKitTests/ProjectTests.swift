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
        try files.createDirectory(at: home.appendingPathComponent("store"), withIntermediateDirectories: true)
        let comparison = Comparison()
        await comparison.clips[0].open(originals[0])
        await comparison.clips[1].open(originals[1])
        comparison.clips[0].trimStart = 0.5
        comparison.clips[0].syncs = [1]
        comparison.clips[1].syncs = [0.75]
        comparison.clips[1].speed = 0.8

        let hadProject = store.saveCurrent(comparison)
        #expect(!hadProject)
        store.save(comparison, as: "Serve")
        #expect(store.current?.name == "Serve")

        // Edit, and save over it: still one project.
        comparison.clips[0].syncs = [1, 2]
        let savedOver = store.saveCurrent(comparison)
        #expect(savedOver)
        #expect(store.saved.count == 1)

        // The originals go; a new store (the next launch) opens the project from its own copies.
        for clip in comparison.clips { clip.close() }
        for original in originals { try files.removeItem(at: original) }
        let later = ComparisonStore(folder: home.appendingPathComponent("store"))
        let project = try #require(later.saved.first)
        let reopened = Comparison()
        await later.open(project, into: reopened)
        let bothOpen = reopened.clips[0].isLoaded && reopened.clips[1].isLoaded
        #expect(bothOpen)
        #expect(reopened.clips[0].trimStart == 0.5)
        #expect(reopened.clips[0].syncs == [1, 2])
        #expect(reopened.clips[1].speed == 0.8)
        #expect(reopened.clips[0].name == "A mine")
        #expect(later.currentID == project.id)

        later.delete(project)
        #expect(later.saved.isEmpty)
    }
}
