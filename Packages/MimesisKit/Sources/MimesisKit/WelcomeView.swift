import SwiftUI

/// The first screen, before any clip is open: what Mimesis does, and the ways to start.
struct WelcomeView: View {
    let onOpenFile: (Int) -> Void
    let onOpenPhotos: (Int) -> Void
    let onCourt: () -> Void
    /// Nil until the library has clips.
    let onLibrary: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    EchoMark().frame(width: 76, height: 76)
                    Text("Compare two swings")
                        .font(.system(size: 28, weight: .bold))
                    Text("Put your stroke beside the one you learn from: line them up at contact, slow them down, and see where you differ.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(.top, 24)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { slots }
                    VStack(spacing: 12) { slots }
                }
                .frame(maxWidth: 640)

                VStack(spacing: 10) {
                    Button(action: onCourt) {
                        Label("Film at the court", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WideButtonStyle())
                    if let onLibrary {
                        Button(action: onLibrary) {
                            Label("Open from your library", systemImage: "books.vertical")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(WideButtonStyle())
                    }
                    Label("Film in Slo-mo (240 fps), or at least 60 fps, for smooth slow motion", systemImage: "lightbulb")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                .frame(maxWidth: 640)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private var slots: some View {
        slot(0, title: "Clip A", detail: "Your swing")
        slot(1, title: "Clip B", detail: "The one to learn from")
    }

    private func slot(_ side: Int, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(side == 0 ? "A" : "B")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button { onOpenPhotos(side) } label: {
                    Label("Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipStyle(active: true))
                Button { onOpenFile(side) } label: {
                    Label("Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipStyle())
            }
        }
        .padding(16)
        .frame(minWidth: 260, maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner + 4, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A full-width quiet button for the welcome screen's other ways in.
struct WideButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(height: 48)
            .background(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
    }
}
