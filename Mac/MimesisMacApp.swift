import MimesisKit
import SwiftUI

@main
struct MimesisMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Each button's explanation shows after 0.4 s of hovering, not the Mac's usual 1.5 s or so.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        Window("Mimesis", id: "main") {
            // Two clips side by side; the masking test is in its toolbar.
            ComparisonView(preload: Self.preload)
                .frame(minWidth: 1000, minHeight: 640)
        }
        // File › projects, export, report, library, Live replay; Edit › Undo, Redo, Edit Clip, Swap.
        .commands { MimesisCommands() }
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
    /// Debug only: `Mimesis -WindowSize 1440x900` sizes the window, its frame included, for App Store
    /// screenshots (a background script can't resize it).
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        guard let text = UserDefaults.standard.string(forKey: "WindowSize") else { return }
        let parts = text.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            window.setFrame(NSRect(x: 40, y: 40, width: parts[0], height: parts[1]), display: true)
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Inbox.shared.receive(urls) }
    }

    /// Quitting with changes not saved: Save, Don't Save or Cancel. With nothing to save, just quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard MenuRequests.shared.hasUnsaved else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = MenuRequests.shared.projectName.map { String(localized: "Save the changes to “\($0)” before quitting?") }
                ?? String(localized: "Save this comparison as a project before quitting?")
            alert.informativeText = String(localized: "Changes not saved in a project are lost.")
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Saved by the comparison screen (it may ask where), which then quits.
                MenuRequests.shared.pending = .saveThenQuit
                return .terminateCancel
            case .alertSecondButtonReturn:
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }
}
