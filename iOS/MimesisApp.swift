import MimesisKit
import SwiftUI

@main
struct MimesisApp: App {
    var body: some Scene {
        WindowGroup {
            // Two clips side by side; the masking test is in its toolbar.
            ComparisonView(preload: Self.preload)
        }
    }

    /// Debug only: launched with `-Left <path> -Right <path>`, opens those clips (Simulator testing).
    private static var preload: [URL?] {
        #if DEBUG
        ["Left", "Right"].map { UserDefaults.standard.string(forKey: $0).map(URL.init(fileURLWithPath:)) }
        #else
        []
        #endif
    }
}
