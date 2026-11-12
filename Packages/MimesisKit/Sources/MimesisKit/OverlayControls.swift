import AreteMedia
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
    /// Asking whether to swap which clip is on top, which removes the top clip's cutout.
    var askingToSwap = false

    /// Swaps which clip is on top (and so which one is cut out). With a cutout made, asks first: it
    /// belongs to the clip on top, and goes with the swap.
    func swapTop(_ comparison: Comparison) {
        moving(comparison) { [weak self] in
            if comparison.clips[comparison.overlayTop].cutout != nil {
                self?.askingToSwap = true
            } else {
                comparison.overlayTop = 1 - comparison.overlayTop
                comparison.resetOverlay()
            }
        }
    }
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

/// "A over B": which clip is on top in the overlay. The whole of it is a button: a click swaps them.
struct OverlayBadge: View {
    let comparison: Comparison
    /// Over the video (dark glass), or in a bar (raised).
    var onVideo = false

    var body: some View {
        let top = comparison.overlayTop == 0 ? "A" : "B", base = comparison.overlayTop == 0 ? "B" : "A"
        Button { comparison.overlayUI.swapTop(comparison) } label: {
            HStack(spacing: 6) {
                letter(top, on: true)
                Text("over").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                letter(base, on: false)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: onVideo ? 30 : 36)
            .background(onVideo ? Color.black.opacity(0.45) : Theme.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(top) is on top of \(base), see-through. Click to put \(base) on top instead.")
    }

    private func letter(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(on ? Theme.onAccent : .white)
            .frame(width: 22, height: 22)
            .background(on ? Theme.accent : Color.white.opacity(0.18), in: Circle())
    }
}

/// The overlay's controls, in the bar under the videos (none over the picture): what touches do (move the
/// top clip, or zoom), how see-through the top clip is, the cutout, and a menu with the rest.
struct OverlayControls: View {
    let comparison: Comparison
    /// Narrow (an iPhone): a shorter slider, and icons for words.
    var compact = false
    /// Which of the controls: all of them; the essentials (what touches do, how see-through, the
    /// cutout), for a row with little room; or only the size buttons, for the popover with the rest.
    enum Part { case all, essential, size }
    var part: Part = .all

    private var ui: OverlayUI { comparison.overlayUI }
    private var top: Clip { comparison.clips[comparison.overlayTop] }
    private var base: Clip { comparison.clips[1 - comparison.overlayTop] }
    private var topLetter: String { comparison.overlayTop == 0 ? "A" : "B" }
    private var baseLetter: String { comparison.overlayTop == 0 ? "B" : "A" }

    var body: some View {
        HStack(spacing: 8) {
            if part != .size { modeSwitch }
            if part != .essential { sizeButtons }
            if part != .size {
                opacity
                cutout
            }
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
                .lineLimit(1)
                .fixedSize()
                .frame(width: 32, alignment: .leading)
        }
        .help("How see-through \(topLetter) is over \(baseLetter)")
    }

    /// The cutout, in one chip: which clip is cut out (its letter: tap it for the other clip), then
    /// Cut out to make it, its progress while it's made (tap to stop), and once made the switch between
    /// cut out and whole, with an ✕ to remove the cutout altogether.
    private var cutout: some View {
        HStack(spacing: 0) {
            Button { ui.swapTop(comparison) } label: {
                Text(topLetter)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                    .padding(.leading, 4)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(topLetter) is on top, and is the one cut out. Tap to put \(baseLetter) on top instead.")
            cutoutAction
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .background(Color.white.opacity(0.10), in: Capsule())
        .fixedSize()
    }

    @ViewBuilder private var cutoutAction: some View {
        switch top.cutout?.state {
        case nil:
            Button { top.makeCutout() } label: {
                Label(compact ? "" : "Cut out", systemImage: "person.crop.rectangle")
                    .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Find the person in every frame of \(topLetter)'s stretch, so only they show over \(baseLetter)")
        case .preparing(let done)?:
            Button { top.dropCutout() } label: {
                HStack(spacing: 6) {
                    ProgressView(value: done).progressViewStyle(.circular).controlSize(.mini)
                    Text("\(Int(done * 100))%").monospacedDigit()
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cutting out \(topLetter)… tap to stop")
        case .ready?:
            if let cutout = top.cutout {
                Button { cutout.enabled.toggle() } label: {
                    Label(compact ? "" : (cutout.enabled ? "Cut out" : "Whole"),
                          systemImage: cutout.enabled ? "person.crop.rectangle.fill" : "rectangle")
                        .foregroundStyle(cutout.enabled ? Theme.accent : .white)
                        .padding(.leading, 8).padding(.trailing, 4).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(cutout.shortened ? "Only the first \(Cutout.frameLimit) frames are cut out: set \(topLetter)'s In and Out around the movement"
                      : "Show \(topLetter) cut out, or whole (the cutout is kept)")
                Button { top.dropCutout() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.3), in: Circle())
                        .frame(width: 26, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove the cutout: \(topLetter) goes back to how it was")
            }
        case .failed(let why)?:
            Button { top.makeCutout() } label: {
                Label(compact ? "" : "Try again", systemImage: "exclamationmark.triangle")
                    .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
