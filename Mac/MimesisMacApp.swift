import MimesisKit
import SwiftUI

@main
struct MimesisMacApp: App {
    var body: some Scene {
        Window("Mimesis", id: "main") {
            // Phase 0: the masking test. The comparison view replaces it in Phase 1.
            MaskLabView()
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
