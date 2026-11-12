import AreteMedia
import Foundation

/// iCloud's key-value store for the library's notes and tags (each clip a key, its notes and tags JSON).
/// Changes from other devices arrive as `onChange` with the keys that changed.
@MainActor
final class LibrarySync {
    var onChange: (([String]) -> Void)?
    private let store: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?

    /// Nil when this build can't reach iCloud (no iCloud account, or not signed for it).
    init?(store: NSUbiquitousKeyValueStore = .default) {
        guard FileManager.default.ubiquityIdentityToken != nil else { return nil }
        self.store = store
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.onChange?(keys) }
        }
        store.synchronize()
    }

    func read(_ key: String) -> Library.Shared? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Library.Shared.self, from: $0) }
    }

    func write(_ shared: Library.Shared, for key: String) {
        guard let data = try? JSONEncoder().encode(shared), read(key).map({ !Self.same($0, shared) }) ?? true else { return }
        store.set(data, forKey: key)
    }

    private static func same(_ a: Library.Shared, _ b: Library.Shared) -> Bool {
        a.notes == b.notes && a.tags == b.tags && Set(a.removed) == Set(b.removed)
    }
}
