import Foundation
import Observation

/// Videos sent to Mimesis from elsewhere (Open With, the Dock icon, Share › Mimesis), waiting for the
/// comparison screen to take them. Filled by the app (the Mac's app delegate, or onOpenURL), even
/// before the screen is up.
@MainActor @Observable
public final class Inbox {
    public static let shared = Inbox()
    public private(set) var urls: [URL] = []

    public func receive(_ urls: [URL]) {
        self.urls.append(contentsOf: urls.filter(\.isFileURL))
    }

    func take() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }

    /// Batches handed over by Share › Mimesis, one at a time (two videos shared together stay together).
    public private(set) var batches: [[URL]] = []

    func takeBatch() -> [URL]? {
        batches.isEmpty ? nil : batches.removeFirst()
    }

    #if os(iOS)
    /// The folder Mimesis shares with Share › Mimesis (an App Group).
    public static let group = "group.com.ljworkshop.mimesis"

    /// Takes in what Share › Mimesis left in the shared folder: each video moves into Mimesis's own clips
    /// (where the library can find it again), keeping the name it had, and each share stays one batch,
    /// in order, so two videos shared together become A and B.
    public func collectShared() {
        let files = FileManager.default
        guard let inbox = files.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
            .appendingPathComponent("Inbox", isDirectory: true),
              let waiting = try? files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil),
              !waiting.isEmpty
        else { return }
        let clips = ComparisonStore.supportFolder.appendingPathComponent("Clips", isDirectory: true)
        try? files.createDirectory(at: clips, withIntermediateDirectories: true)
        // "<batch>-<index>~<name>.<ext>"
        let grouped = Dictionary(grouping: waiting) { $0.lastPathComponent.split(separator: "-").first.map(String.init) ?? "" }
        for key in grouped.keys.sorted() {
            var batch: [URL] = []
            for file in grouped[key]!.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent.split(separator: "~", maxSplits: 1).last.map(String.init) ?? file.lastPathComponent
                var target = clips.appendingPathComponent(name)
                if files.fileExists(atPath: target.path) {
                    target = clips.appendingPathComponent(
                        "\(target.deletingPathExtension().lastPathComponent) \(UUID().uuidString.prefix(4)).\(target.pathExtension)")
                }
                do {
                    try files.moveItem(at: file, to: target)
                    batch.append(target)
                } catch {
                    try? files.removeItem(at: file)
                }
            }
            if !batch.isEmpty { batches.append(batch) }
        }
    }
    #endif
}
