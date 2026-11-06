import MimesisKit
import SwiftUI

@main
struct MimesisMacApp: App {
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
