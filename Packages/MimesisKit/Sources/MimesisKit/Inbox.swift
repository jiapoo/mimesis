import Foundation
import Observation

/// Videos sent to Mimesis from elsewhere (Open With, the Dock icon, Share › Mimesis), waiting for the
/// comparison screen to take them. Filled by the app (the Mac's app delegate, or onOpenURL), even
/// before the screen is up.
@MainActor @Observable
public final class Inbox {
    public static let shared = Inbox()
    public private(set) var urls: [URL] = []

    public func receive(_ urls: [URL]) {
        self.urls.append(contentsOf: urls.filter(\.isFileURL))
    }

    func take() -> [URL] {
        defer { urls.removeAll() }
        return urls
    }
}
