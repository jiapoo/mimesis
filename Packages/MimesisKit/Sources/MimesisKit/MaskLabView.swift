import AreteMedia
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Phase 0's masking test: open a clip, choose a span, and see each frame cut out by both of
/// Vision's methods side by side, with how long each took.
@MainActor @Observable
final class MaskLab {
    var url: URL?
    var clipLength: Double = 0
    var start: Double = 0
    var span: Double = 2
    var progress: Double?
    var report: ProbeReport?
    var error: String?
    var index = 0 { didSet { refresh() } }
    private(set) var shown: [CGImage?] = []
    private(set) var sheetFile: URL?
    private var task: Task<Void, Never>?

    static let columns: [MaskMethod?] = [nil] + MaskMethod.allCases

    var frame: ProbeFrame? {
        guard let report, report.frames.indices.contains(index) else { return nil }
        return report.frames[index]
    }

    func open(_ picked: URL) async {
        url?.stopAccessingSecurityScopedResource()
        _ = picked.startAccessingSecurityScopedResource()
        url = picked
        report = nil
        error = nil
        start = 0
        clipLength = (try? await AVURLAsset(url: picked).load(.duration).seconds) ?? 0
        span = min(2, max(0.5, clipLength))
    }

    func run() {
        guard let url else { return }
        task?.cancel()
        progress = 0
        error = nil
        let (start, span) = (start, span)
        task = Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try await MaskProbe.run(url: url, start: start, duration: span) { done in
                        Task { @MainActor in self.progress = done }
                    }
                }.value
                self.report = report
                sheetFile = Self.writeSheet(report)
                index = 0
                refresh()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }

    func step(_ by: Int) {
        guard let count = report?.frames.count, count > 0 else { return }
        index = min(count - 1, max(0, index + by))
    }

    private func refresh() {
        shown = frame.map { frame in Self.columns.map { MaskProbe.cutout(frame, $0) } } ?? []
    }

    private static func writeSheet(_ report: ProbeReport) -> URL? {
        guard let sheet = MaskProbe.contactSheet(report), let data = MaskProbe.png(sheet) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Mask test.png")
        return (try? data.write(to: file)) != nil ? file : nil
    }
}

public struct MaskLabView: View {
    @State private var lab = MaskLab()
    @State private var picking = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let error = lab.error {
                Text(error).foregroundStyle(.red)
            }
            if let report = lab.report {
                results(report)
            } else {
                ContentUnavailableView(
                    "Masking test",
                    systemImage: "person.crop.rectangle",
                    description: Text("Open a clip, choose a couple of seconds with a full swing, "
                        + "and see which way of cutting the player out keeps the racket."))
            }
        }
        .padding()
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie]) { result in
            if case .success(let url) = result { Task { await lab.open(url) } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open video…") { picking = true }
                if let url = lab.url {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let file = lab.sheetFile {
                    ShareLink(item: file) { Label("Contact sheet", systemImage: "square.and.arrow.up") }
                }
            }
            if lab.url != nil, lab.clipLength > 0 {
                HStack {
                    Text("From \(lab.start, format: .number.precision(.fractionLength(1))) s")
                        .monospacedDigit().frame(width: 90, alignment: .leading)
                    Slider(value: $lab.start, in: 0...max(0.01, lab.clipLength - lab.span))
                    Picker("For", selection: $lab.span) {
                        ForEach([1.0, 2.0, 3.0].filter { $0 <= max(1, lab.clipLength) }, id: \.self) {
                            Text("\(Int($0)) s").tag($0)
                        }
                    }
                    .fixedSize()
                    if let progress = lab.progress {
                        ProgressView(value: progress).frame(width: 100)
                    } else {
                        Button("Test") { lab.run() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func results(_ report: ProbeReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(report.frames.count) frames at \(Int(report.size.width))×\(Int(report.size.height)), "
                + "\(Int(report.frameRate.rounded())) fps")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(MaskProbe.summary(report), id: \.self) { Text($0).font(.caption) }

            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(MaskLab.columns.enumerated()), id: \.offset) { column, method in
                    VStack(spacing: 4) {
                        if lab.shown.indices.contains(column), let image = lab.shown[column] {
                            Image(decorative: image, scale: 1)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Text(caption(method)).font(.caption)
                    }
                }
            }

            HStack {
                Button { lab.step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Slider(
                    value: Binding(get: { Double(lab.index) }, set: { lab.index = Int($0.rounded()) }),
                    in: 0...Double(max(1, report.frames.count - 1)), step: 1)
                Button { lab.step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Text("\(lab.index + 1) / \(report.frames.count)").monospacedDigit()
            }
        }
    }

    private func caption(_ method: MaskMethod?) -> String {
        guard let method else {
            return lab.frame.map { "Frame at \($0.time.formatted(.number.precision(.fractionLength(2)))) s" } ?? ""
        }
        guard let count = lab.frame?.instances[method] else { return "\(method.title): nobody" }
        return "\(method.title): \(count) found"
    }
}
