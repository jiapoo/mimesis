@testable import MimesisKit
import Foundation
import PDFKit
import Testing

/// The report of a comparison of two real clips (opt-in: set MIMESIS_CLIP_A and MIMESIS_CLIP_B; MIMESIS_OUT keeps it).
@MainActor
struct ReportTests {
    nonisolated static let paths = (ProcessInfo.processInfo.environment["MIMESIS_CLIP_A"],
                                    ProcessInfo.processInfo.environment["MIMESIS_CLIP_B"])

    @Test(.enabled(if: paths.0 != nil && paths.1 != nil))
    func aReportHasEachSegmentsKeyFrames() async throws {
        let comparison = Comparison()
        await comparison.clips[0].open(URL(fileURLWithPath: Self.paths.0!))
        await comparison.clips[1].open(URL(fileURLWithPath: Self.paths.1!))
        let a = comparison.clips[0], b = comparison.clips[1]
        a.trimStart = 0.5
        a.trimEnd = 2.5
        a.syncs = [1]
        b.syncs = [1]
        a.drawings = [Drawing(kind: .arrow, points: [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.6, y: 0.4)],
                              time: 1.5, always: false, color: Palette.crimson, width: 4, brush: .pen)]
        b.notes = [FrameNote(time: 2, text: "Weight on the back foot")]
        comparison.renameSegment(to: "First")
        comparison.addSegment(named: "Second")

        #expect(Report.keyFrames(Segment.Part(syncs: [1], notes: [FrameNote(time: 1, text: "x")]), clip: 0).count == 1)
        let file = try await Report.make(comparison, title: "Test") { _ in }
        let pdf = try #require(PDFDocument(url: file))
        #expect(pdf.pageCount >= 1)
        let words = pdf.string ?? ""
        #expect(words.contains("First") && words.contains("Second") && words.contains("Weight on the back foot"))
        if let out = ProcessInfo.processInfo.environment["MIMESIS_OUT"] {
            try? FileManager.default.removeItem(atPath: out + "/report.pdf")
            try FileManager.default.copyItem(atPath: file.path, toPath: out + "/report.pdf")
        }
    }
}
