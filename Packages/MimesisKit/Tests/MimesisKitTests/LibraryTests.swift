@testable import MimesisKit
import Foundation
import Testing

/// The library: clips remembered once, tagged moments kept in order and found by label, all saved.
@MainActor
struct LibraryTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID())", isDirectory: true)

    func clip(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data([0]).write(to: url)
        return url
    }

    @Test func remembersTagsAndFindsThemByLabel() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Library.json")
        let serve = try clip("serve.mov"), rally = try clip("rally.mov")
        let library = Library(file: file)
        library.record(serve)
        library.record(serve)
        #expect(library.clips.count == 1)
        library.tag(serve, at: 3.2, label: "Serve")
        library.tag(serve, at: 1.0, label: "Fault")
        library.tag(rally, at: 5.0, label: "Forehand")
        library.tag(rally, at: 2.0, label: "Serve")
        #expect(library.clips.count == 2)
        #expect(library.entry(for: serve)?.tags.map(\.time) == [1.0, 3.2])
        #expect(library.moments(labelled: "Serve").count == 2)
        #expect(library.labels.prefix(Library.presets.count) == Library.presets[...])

        // Saved: a new library on the same file has it all, and finds the files again.
        let again = Library(file: file)
        #expect(again.clips.count == 2)
        #expect(again.moments(labelled: "Forehand").first?.tag.time == 5.0)
        #expect(again.entry(for: rally)?.resolve() != nil)
    }

    @Test func customLabelsComeAfterThePresets() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = Library(file: folder.appendingPathComponent("Library.json"))
        library.tag(try clip("drill.mov"), at: 1, label: "Split step")
        #expect(library.labels.last == "Split step")
    }
}
