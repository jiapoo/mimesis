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
            opacity
            cutout
            menu
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

    /// Everything else: swap, mirror, line them up, size and turn, put back, and the cutout's options.
    private var menu: some View {
        Menu {
            Button("Swap: \(baseLetter) on top", systemImage: "arrow.up.arrow.down") {
                comparison.overlayTop = 1 - comparison.overlayTop
                comparison.resetOverlay()
            }
            Button(top.engine.mirroredHorizontally ? "Unmirror \(topLetter)" : "Mirror \(topLetter)",
                   systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                   action: top.toggleMirror)
            Divider()
            // The whole picture (both clips): also pinch, with 🔍 on.
            Button("Zoom in", systemImage: "plus.magnifyingglass") { zoomView(by: 1.25) }
            Button("Zoom out", systemImage: "minus.magnifyingglass") { zoomView(by: 1 / 1.25) }
                .disabled(base.zoom <= 1)
            Divider()
            Button("Line up the bodies", systemImage: "figure.stand") { align() }
                .disabled(ui.aligning)
            Button("Line up the backgrounds", systemImage: "square.on.square.dashed") { align(byBackground: true) }
                .disabled(ui.aligning)
            Divider()
            Button("\(topLetter) bigger", systemImage: "plus.square") { resize(by: 1.1) }
            Button("\(topLetter) smaller", systemImage: "minus.square") { resize(by: 1 / 1.1) }
            Button("Turn 1° left (now \(Int(comparison.overlayRotation.rounded()))°)", systemImage: "rotate.left") {
                comparison.overlayRotation -= 1
            }
            Button("Turn 1° right", systemImage: "rotate.right") { comparison.overlayRotation += 1 }
            Button("Put \(topLetter) back", systemImage: "arrow.counterclockwise", action: comparison.resetOverlay)
                .disabled(comparison.overlayOffset == .zero && comparison.overlayScale == 1 && comparison.overlayRotation == 0)
            if let cutout = top.cutout, cutout.state == .ready {
                Divider()
                Toggle(isOn: Binding(get: { cutout.boxed }, set: { cutout.boxed = $0 })) {
                    Label("Box instead of outline", systemImage: "rectangle.dashed")
                }
                .disabled(!cutout.enabled)
                Toggle(isOn: Binding(get: { cutout.tinted }, set: { cutout.tinted = $0 })) {
                    Label("Tint \(topLetter) crimson", systemImage: "paintbrush")
                }
                .disabled(!cutout.enabled)
                if cutout.hasSeveral && cutout.enabled {
                    Button("Pick the player…", systemImage: "hand.tap") { ui.picking = true }
                    if cutout.picked != nil {
                        Button("Show everyone", systemImage: "person.2") { cutout.pickEveryone() }
                    }
                }
                Button("Cut out again", systemImage: "arrow.clockwise") { top.makeCutout(fresh: true) }
            }
        } label: {
            Image(systemName: ui.aligning ? "hourglass" : "square.2.layers.3d")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.raised, in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Overlay: swap, mirror, line up, size and turn, the cutout's options")
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

    private func align(byBackground: Bool = false) {
        ui.aligning = true
        ui.problem = nil
        Task {
            do {
                if byBackground {
                    try await comparison.alignBackgrounds()
                } else {
                    try await comparison.autoAlign()
                }
            } catch {
                #if targetEnvironment(simulator)
                ui.problem = "Lining up needs a real iPhone or iPad (Vision can't run it in Simulator)."
                #else
                ui.problem = error.localizedDescription
                #endif
            }
            ui.aligning = false
        }
    }
}
