import AreteMedia
import Foundation
import Observation

/// Every moment with one tag, played back to back in clip A: each from a little before the tag to a
/// little after, then the next.
@MainActor @Observable
final class Reel {
    struct Item {
        let url: URL
        let name: String
        let time: Double
    }

    let label: String
    let items: [Item]
    private(set) var index = 0
    private(set) var running = false
    private var task: Task<Void, Never>?

    /// Seconds shown before and after each tagged moment.
    static let before = 1.5
    static let after = 1.5

    init(label: String, items: [Item]) {
        self.label = label
        self.items = items
    }

    /// The window shown around a tag, kept inside the clip.
    static func window(around time: Double, duration: Double) -> ClosedRange<Double> {
        let start = max(0, time - before)
        let end = duration > 0 ? min(duration, time + after) : time + after
        return start...max(start, end)
    }

    func start(in clip: Clip) {
        stop()
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            for (at, item) in self.items.enumerated() {
                guard !Task.isCancelled else { break }
                self.index = at
                if clip.url?.standardizedFileURL != item.url.standardizedFileURL {
                    _ = item.url.startAccessingSecurityScopedResource()
                    await clip.open(item.url)
                }
                // The clip's own trim shouldn't cut the window short.
                clip.clearTrim()
                let window = Self.window(around: item.time, duration: clip.engine.duration)
                await clip.engine.seekToTime(window.lowerBound)
                clip.engine.loopPlayback = false
                clip.engine.play()
                while !Task.isCancelled, clip.engine.currentTime < window.upperBound - 0.03, clip.engine.isPlaying {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                clip.engine.pause()
                try? await Task.sleep(for: .milliseconds(350))
            }
            self.running = false
            clip.engine.loopPlayback = true
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }
}
