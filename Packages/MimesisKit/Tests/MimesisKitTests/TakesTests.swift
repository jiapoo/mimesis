@testable import MimesisKit
import Foundation
import Testing

/// Several takes of a clip, each with its own edits (opt-in: set MIMESIS_CLIP_A and MIMESIS_CLIP_B).
@MainActor
struct TakesTests {
    nonisolated static let paths = (ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"],
                                    ProcessInfo.processInfo.environment["MIMESIS_CLIP_B"])

    @Test(.enabled(if: paths.0 != nil && paths.1 != nil))
    func eachTakeKeepsItsEditsAndAProjectKeepsThemAll() async throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent("mimesis-takes-\(UUID().uuidString)")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: home) }
        let first = home.appendingPathComponent("monday.mp4"), second = home.appendingPathComponent("friday.mp4")
        let reference = home.appendingPathComponent("pro.mp4")
        try files.copyItem(at: URL(fileURLWithPath: Self.paths.0!), to: first)
        try files.copyItem(at: URL(fileURLWithPath: Self.paths.0!), to: second)
        try files.copyItem(at: URL(fileURLWithPath: Self.paths.1!), to: reference)

        let comparison = Comparison()
        await comparison.clips[0].open(first)
        await comparison.clips[1].open(reference)
        comparison.clips[0].trimStart = 1
        comparison.clips[1].trimStart = 0.5

        await comparison.addTake(second, to: 0)
        #expect(comparison.takes[0].count == 2)
        #expect(comparison.clips[0].url == second)
        // The new take starts afresh; the other clip is untouched.
        #expect(comparison.clips[0].trimStart == 0 && comparison.clips[1].trimStart == 0.5)
        comparison.clips[0].trimStart = 2

        let monday = try #require(comparison.takes[0].firstIndex { $0.url == first })
        await comparison.selectTake(monday, in: 0)
        #expect(comparison.clips[0].url == first && comparison.clips[0].trimStart == 1)

        // A project keeps every take's video and edits.
        let store = ComparisonStore(folder: home.appendingPathComponent("store"))
        let project = home.appendingPathComponent("Progress.mimesis")
        let saved = store.save(comparison, to: project)
        #expect(saved)
        #expect(files.fileExists(atPath: project.appendingPathComponent("friday.mp4").path))
        for original in [first, second, reference] { try files.removeItem(at: original) }

        let reopened = Comparison()
        let opened = await store.open(project, into: reopened)
        #expect(opened)
        #expect(reopened.takes[0].count == 2)
        #expect(reopened.clips[0].name == "monday" && reopened.clips[0].trimStart == 1)
        let friday = try #require(reopened.takes[0].firstIndex { $0.name == "friday" })
        await reopened.selectTake(friday, in: 0)
        #expect(reopened.clips[0].name == "friday" && reopened.clips[0].trimStart == 2)
    }
}
