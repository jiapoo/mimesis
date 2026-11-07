import Foundation
import Observation

/// The pen the drawing tools set: shape, colour, size, and whether new drawings show on every frame.
/// One for the whole comparison, so drawing on both clips at once uses the same pen.
@MainActor @Observable
final class Pen {
    var tool: Drawing.Kind = .line
    var ink: Drawing.Ink = .crimson
    var size: Drawing.Size = .medium
    var always = false
}

/// Undo and redo for every edit to the clips: trims, sync points, speeds and drawings (⌘Z, ⇧⌘Z).
///
/// Rather than each edit saying what it changed, the comparison's edits are looked at a moment after
/// they stop changing (`record`), and the state before is kept. So a sync point dragged across fifty
/// frames is one step to undo, and nothing that edits a clip can forget to be undoable.
@MainActor @Observable
final class EditHistory {
    struct ClipState: Equatable {
        var url: URL?
        var trimStart: Double
        var trimEnd: Double?
        var syncs: [Double]
        var speed: Double
        var drawings: [Drawing]
    }

    typealias State = [ClipState]

    private var undos: [State] = []
    private var redos: [State] = []
    private var current: State?
    /// Set while an undo or redo puts a state back, so recording it isn't a new edit.
    private var restoring: State?

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }

    static func state(of comparison: Comparison) -> State {
        comparison.clips.map {
            ClipState(url: $0.url, trimStart: $0.trimStart, trimEnd: $0.trimEnd, syncs: $0.syncs,
                      speed: $0.speed, drawings: $0.drawings)
        }
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
        if before.map(\.url) != now.map(\.url) {
            undos.removeAll()
            redos.removeAll()
            return
        }
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
        restoring = state
        current = state
        for (clip, saved) in zip(comparison.clips, state) where clip.url == saved.url {
            clip.trimStart = saved.trimStart
            clip.trimEnd = saved.trimEnd
            clip.syncs = saved.syncs
            clip.speed = saved.speed
            clip.drawings = saved.drawings
        }
    }
}
