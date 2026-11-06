import MimesisKit
import SwiftUI

@main
struct MimesisApp: App {
    var body: some Scene {
        WindowGroup {
            // Phase 0: the masking test. The comparison view replaces it in Phase 1.
            MaskLabView()
        }
    }
}
