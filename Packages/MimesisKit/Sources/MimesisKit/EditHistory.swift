import Foundation
import Observation

/// Undo and redo for every edit to the comparison: its segments (their In/Out, sync points, speeds,
/// drawings and overlay placement), adding, renaming and removing them (⌘Z, ⇧⌘Z).
///
/// Rather than each edit saying what it changed, the comparison's edits are looked at a moment after
/// they stop changing (`record`), and the state before is kept. So a sync point dragged across fifty
/// frames is one step to undo, and nothing that edits a clip can forget to be undoable.
@MainActor @Observable
final class EditHistory {
    struct State: Equatable {
        var urls: [URL?]
        var segments: [Segment]
        var index: Int
    }

    private var undos: [State] = []
    private var redos: [State] = []
    private var current: State?
    /// Set while an undo or redo puts a state back, so recording it isn't a new edit.
    private var restoring: State?

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }

    static func state(of comparison: Comparison) -> State {
        comparison.storeSegment()
        return State(urls: comparison.clips.map(\.url), segments: comparison.segments, index: comparison.segmentIndex)
    }

    /// Notes the comparison as it is now: after an edit, the state before it can be undone.
    func record(_ comparison: Comparison) {
        let now = Self.state(of: comparison)
        defer { current = now }
        if let restoring, restoring == now {
            self.restoring = nil
            return
        }
        guard let before = current, before != now else { return }
        // Another video opened: its edits are a fresh start.
        if before.urls != now.urls {
            undos.removeAll()
            redos.removeAll()
            return
        }
        // Only another segment chosen: nothing to undo.
        if before.segments == now.segments { return }
        undos.append(before)
        if undos.count > 200 { undos.removeFirst() }
        redos.removeAll()
    }

    func undo(_ comparison: Comparison) {
        // An edit not yet recorded is the one to undo.
        record(comparison)
        guard let state = undos.popLast() else { return }
        redos.append(Self.state(of: comparison))
        apply(state, to: comparison)
    }

    func redo(_ comparison: Comparison) {
        record(comparison)
        guard let state = redos.popLast() else { return }
        undos.append(Self.state(of: comparison))
        apply(state, to: comparison)
    }

    private func apply(_ state: State, to comparison: Comparison) {
        guard state.urls == comparison.clips.map(\.url) else { return }
        restoring = state
        current = state
        comparison.segments = state.segments
        comparison.loadSegment(min(state.index, state.segments.count - 1))
    }
}
