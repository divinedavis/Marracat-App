import UIKit

/// What the app lets go when iOS warns it's short of memory (2026-10-18).
/// Nothing listened before: past NSCache's own eviction, the app held on to
/// everything until iOS ended it. Everything dropped here rebuilds on demand.
@MainActor
enum MemoryPressure {
    private static var observer: NSObjectProtocol?

    static func start(catalog: CatalogStore) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak catalog] _ in
            MainActor.assumeIsolated { shed(catalog: catalog) }
        }
    }

    static func shed(catalog: CatalogStore?) {
        ImageLoader.shared.shed()
        catalog?.shed()
        // The in-memory half of the URL cache; what's on disk stays.
        let capacity = URLCache.shared.memoryCapacity
        URLCache.shared.memoryCapacity = 0
        URLCache.shared.memoryCapacity = capacity
        LaunchTiming.log.notice("memory warning: image, search and URL caches dropped")
    }
}
