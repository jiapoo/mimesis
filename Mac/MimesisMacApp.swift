import MimesisKit
import SwiftUI

@main
struct MimesisMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Mimesis", id: "main") {
            // Two clips side by side; the masking test is in its toolbar.
            ComparisonView(preload: Self.preload)
                .frame(minWidth: 1000, minHeight: 640)
        }
    }

    /// Debug only: `Mimesis -Left <path> -Right <path>` opens those clips at launch.
    private static var preload: [URL?] {
        #if DEBUG
        ["Left", "Right"].map { UserDefaults.standard.string(forKey: $0).map(URL.init(fileURLWithPath:)) }
        #else
        []
        #endif
    }
}

/// Videos opened with Mimesis (Finder's Open With, dropped on the Dock icon) go to the comparison screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Inbox.shared.receive(urls) }
    }
}
