import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share › Mimesis: takes the one or two videos shared (from Arete, Imago, Photos, Files, Messages…),
/// copies them into the folder Mimesis shares with this extension, and opens Mimesis, which puts them in
/// A and B. Only a "Sending to Mimesis…" card shows meanwhile.
final class ShareViewController: UIViewController {
    /// The folder Mimesis and this extension share (an App Group); Mimesis empties its Inbox when it opens.
    static let group = "group.com.ljworkshop.mimesis"

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.047, green: 0.051, blue: 0.063, alpha: 1)
        status.text = "Sending to Mimesis…"
        status.textColor = .white
        status.font = .systemFont(ofSize: 17, weight: .semibold)
        status.numberOfLines = 0
        status.textAlignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        Task { await send() }
    }

    private func send() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
        guard !providers.isEmpty,
              let inbox = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: Self.group)?
                .appendingPathComponent("Inbox", isDirectory: true)
        else {
            finish("Mimesis takes videos: share one or two.")
            return
        }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // A batch of its own, numbered, so Mimesis keeps their order (the first is A).
        let batch = Int(Date().timeIntervalSince1970 * 1000)
        var saved = 0
        for (index, provider) in providers.prefix(2).enumerated() {
            if await copy(provider, to: inbox, named: "\(batch)-\(index)") { saved += 1 }
        }
        guard saved > 0 else {
            finish("Couldn't read the video.")
            return
        }
        if openMimesis() {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            finish("Sent. Open Mimesis to compare.")
        }
    }

    /// Copies the shared video into the inbox (the provider's file only lasts while it's being read).
    private func copy(_ provider: NSItemProvider, to folder: URL, named name: String) async -> Bool {
        await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url else { return done.resume(returning: false) }
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                // The original name after the number, so Mimesis can name the clip.
                let target = folder.appendingPathComponent("\(name)~\(url.deletingPathExtension().lastPathComponent).\(ext)")
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: url, to: target)
                    done.resume(returning: true)
                } catch {
                    done.resume(returning: false)
                }
            }
        }
    }

    /// Opens Mimesis (mimesis://inbox). A share extension may not open apps directly, so this goes up the
    /// responder chain to the app and asks it, as share extensions do.
    private func openMimesis() -> Bool {
        guard let url = URL(string: "mimesis://inbox") else { return false }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), current !== self, NSStringFromClass(type(of: current)).contains("Application") {
                typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: Open.self)
                open(current, selector, url, [:], nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish(_ message: String) {
        status.text = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
