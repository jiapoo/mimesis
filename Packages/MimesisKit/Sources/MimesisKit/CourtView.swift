import AreteMedia
import CoreImage
import SwiftUI

/// Court mode: the camera shown a few seconds late, so after a stroke you turn to the screen and watch
/// the stroke you just hit. Save the last seconds as clip A or B to compare.
struct CourtView: View {
    /// A saved clip, and which side (0 is A, 1 is B) to open it as.
    let onSave: (URL, Int) -> Void

    @State private var camera = CourtCamera()
    @State private var drawer = FrameDrawer()
    @State private var saving = false
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch camera.state {
            case .starting:
                ProgressView().tint(.white)
            case .unavailable(let why):
                Text(why).foregroundStyle(.white).multilineTextAlignment(.center).padding(40)
            case .running:
                TimelineView(.animation) { _ in
                    if let image = drawer.draw(camera.frame()) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        filling
                    }
                }
                .ignoresSafeArea()
            }
            VStack {
                top
                Spacer()
                if let problem {
                    Text(problem).font(.callout).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: Capsule())
                }
                bottom
            }
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    private var filling: some View {
        VStack(spacing: 10) {
            ProgressView(value: min(1, camera.reach() / max(0.1, camera.delay))).frame(width: 200).tint(Theme.accent)
            Text("Starting \(Int(camera.delay)) s behind…").foregroundStyle(.white.opacity(0.8))
        }
    }

    private var top: some View {
        HStack {
            Button { dismiss() } label: {
                Label("Close", systemImage: "xmark").labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Color.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close Live replay (Esc)")
            Spacer()
            Text(camera.delay == 0 ? "Live" : "\(Int(camera.delay)) s behind")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(camera.delay == 0 ? Color.white : Theme.onAccent)
                .padding(.horizontal, 14).frame(height: 32)
                .background(camera.delay == 0 ? Color.black.opacity(0.5) : Theme.accent, in: Capsule())
                .help("How far behind the camera you're watching")
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
    }

    private var bottom: some View {
        HStack(spacing: 12) {
            RoundButton(symbol: "minus", size: 40) { camera.delay = max(0, camera.delay - 1) }
                .help("Less delay")
            Text(camera.delay == 0 ? "Live" : "\(Int(camera.delay)) s")
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white).frame(minWidth: 50)
            RoundButton(symbol: "plus", size: 40) { camera.delay = min(10, camera.delay + 1) }
                .help("More delay")
            Spacer(minLength: 12)
            Menu {
                Button("As clip A") { save(as: 0) }
                Button("As clip B") { save(as: 1) }
            } label: {
                Label(saving ? "Saving…" : "Save last \(Int(CourtCamera.saveSpan)) s", systemImage: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16).frame(height: 44)
                    .background(Theme.accent, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(saving || camera.state != .running)
            .help("Keep the last \(Int(CourtCamera.saveSpan)) seconds you watched as a clip to compare")
        }
        .padding(12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func save(as side: Int) {
        saving = true
        problem = nil
        Task {
            do {
                let file = try await camera.saveLast()
                onSave(file, side)
                dismiss()
            } catch {
                problem = "Nothing to save yet: wait for the picture to start."
            }
            saving = false
        }
    }
}

/// Turns camera frames into images to show, with one Core Image context kept for all of them.
@MainActor
final class FrameDrawer {
    private let context = CIContext()

    func draw(_ frame: CIImage?) -> CGImage? {
        guard let frame else { return nil }
        return context.createCGImage(frame, from: frame.extent)
    }
}
