import SwiftUI

/// What the overlay's controls in the bar and the overlay itself share.
@MainActor @Observable
final class OverlayUI {
    /// Touches move the top clip (true), or zoom and pan the whole picture (false).
    var movesTop = true
    /// Waiting for a tap on the player to keep in the cutout.
    var picking = false
    var aligning = false
    /// Shown over the overlay for a few seconds (auto-align couldn't, nobody where tapped…).
    var problem: String?
    /// Asking whether to remove the overlay's drawings so the top clip can move; then `pending` runs.
    var askingToUnlock = false
    var pending: (() -> Void)?

    /// Runs `change` (something that moves, resizes, turns, mirrors or swaps the top clip). Drawings made
    /// in the overlay sit where the two pictures were: with any there, asks first, as they'd be removed.
    func moving(_ comparison: Comparison, _ change: @escaping () -> Void) {
        if comparison.overlayDrawings == 0 {
            change()
        } else {
            pending = change
            askingToUnlock = true
        }
    }

    /// Lines the top clip up with the one underneath: by the bodies (hips and feet), or the backgrounds.
    func align(_ comparison: Comparison, byBackground: Bool = false) {
        guard comparison.overlayDrawings == 0 else {
            moving(comparison) { [weak self] in self?.align(comparison, byBackground: byBackground) }
            return
        }
        aligning = true
        problem = nil
        Task {
            do {
                if byBackground {
                    try await comparison.alignBackgrounds()
                } else {
                    try await comparison.autoAlign()
                }
            } catch {
                #if targetEnvironment(simulator)
                problem = "Lining up needs a real iPhone or iPad (Vision can't run it in Simulator)."
                #else
                problem = error.localizedDescription
                #endif
            }
            aligning = false
        }
    }
}

/// The overlay's controls, in the bar under the videos (none over the picture): what touches do (move the
/// top clip, or zoom), how see-through the top clip is, the cutout, and a menu with the rest.
struct OverlayControls: View {
    let comparison: Comparison
    /// Narrow (an iPhone): a shorter slider, and icons for words.
    var compact = false

    private var ui: OverlayUI { comparison.overlayUI }
    private var top: Clip { comparison.clips[comparison.overlayTop] }
    private var base: Clip { comparison.clips[1 - comparison.overlayTop] }
    private var topLetter: String { comparison.overlayTop == 0 ? "A" : "B" }
    private var baseLetter: String { comparison.overlayTop == 0 ? "B" : "A" }

    var body: some View {
        HStack(spacing: 8) {
            modeSwitch
            sizeButtons
            opacity
            cutout
        }
        .foregroundStyle(.white)
    }

    /// ✋ moves the top clip; 🔍 zooms both.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            mode("hand.draw", on: ui.movesTop, help: "Touches move, resize and turn \(topLetter)") { ui.movesTop = true }
            mode("plus.magnifyingglass", on: !ui.movesTop, help: "Touches zoom and pan the whole picture, both clips") {
                ui.movesTop = false
            }
        }
        .padding(2)
        .background(Theme.raised, in: Capsule())
        .fixedSize()
    }

    private func mode(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Theme.onAccent : Color.white.opacity(0.75))
                .frame(width: 30, height: 26)
                .background(on ? Theme.accent : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var opacity: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            SlimSlider(value: Binding(get: { comparison.overlayOpacity }, set: { comparison.overlayOpacity = $0 }),
                       range: 0.1...0.9)
                .frame(width: compact ? 70 : 110)
            Text("\(Int((comparison.overlayOpacity * 100).rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 30, alignment: .leading)
        }
        .help("How see-through \(topLetter) is over \(baseLetter)")
    }

    /// Cut the top player out: a button to start, its progress (tap to stop), then on / off.
    @ViewBuilder private var cutout: some View {
        switch top.cutout?.state {
        case nil:
            Button { top.makeCutout() } label: {
                Label(compact ? "" : "Cut out", systemImage: "person.crop.rectangle")
            }
            .buttonStyle(ChipStyle(active: true))
            .fixedSize()
            .help("Find the player in every frame of \(topLetter)'s trim, so only the player shows over \(baseLetter)")
        case .preparing(let done)?:
            Button { top.dropCutout() } label: {
                HStack(spacing: 6) {
                    ProgressView(value: done)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                    Text("\(Int(done * 100))%").monospacedDigit()
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(ChipStyle())
            .fixedSize()
            .help("Cutting out \(topLetter)… tap to stop")
        case .ready?:
            if let cutout = top.cutout {
                Button { cutout.enabled.toggle() } label: {
                    Label(compact ? "" : "Cutout", systemImage: "person.crop.rectangle")
                }
                .buttonStyle(ChipStyle(active: cutout.enabled))
                .fixedSize()
                .help(cutout.shortened ? "Only the first \(Cutout.frameLimit) frames of the trim are cut out: trim \(topLetter) to the swing"
                      : "Show \(topLetter) cut out, or whole")
            }
        case .failed(let why)?:
            Button { top.makeCutout() } label: {
                Label(compact ? "" : "Try again", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(ChipStyle())
            .fixedSize()
            .help(why)
        }
    }

    /// − and +: with ✋ they resize the top clip, with 🔍 they zoom the whole picture (for a mouse; or pinch).
    private var sizeButtons: some View {
        HStack(spacing: 4) {
            RoundButton(symbol: "minus") {
                if ui.movesTop { ui.moving(comparison) { resize(by: 1 / 1.1) } } else { zoomView(by: 1 / 1.25) }
            }
            .disabled(!ui.movesTop && base.zoom <= 1)
            .help(ui.movesTop ? "Make \(topLetter) smaller (or pinch)" : "Zoom out (or pinch)")
            RoundButton(symbol: "plus") {
                if ui.movesTop { ui.moving(comparison) { resize(by: 1.1) } } else { zoomView(by: 1.25) }
            }
            .help(ui.movesTop ? "Make \(topLetter) bigger (or pinch)" : "Zoom in on both clips (or pinch)")
        }
    }

    private func zoomView(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            base.zoom = min(8, max(1, base.zoom * factor))
            if base.zoom == 1 { base.pan = .zero }
        }
    }

    private func resize(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.12)) {
            comparison.overlayScale = min(4, max(0.25, comparison.overlayScale * factor))
        }
    }
}
