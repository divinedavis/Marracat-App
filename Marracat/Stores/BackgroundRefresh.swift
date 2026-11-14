import BackgroundTasks
import Foundation
import os

/// Catalog work while the app is closed (owner, 2026-10-02), in two tasks
/// since 2026-10-18:
/// - the refresh, which iOS runs now and then for a short window (often on
///   battery): download the newest catalog, check its signature, keep it;
/// - processing, which runs only on external power: decode it, write its
///   binary copy and Home's slice, and match it against the shopper's
///   interests, and build search's indexes (SearchCache). Decoding 155k
///   products had been inside the refresh window.
/// A launch before the processing task reads the kept JSON, as before.
enum BackgroundRefresh {
    static let identifier = "com.divinedavis.marracat.catalog-refresh"
    static let processingIdentifier = "com.divinedavis.marracat.catalog-process"
    private static let log = Logger(subsystem: "com.divinedavis.marracat", category: "background")

    /// From application(_:didFinishLaunchingWithOptions:): iOS requires the
    /// handlers to be registered before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return task.setTaskCompleted(success: false) }
            schedule()   // the next one, whatever happens to this one
            let work = Task.detached(priority: .utility) {
                let kept = await CatalogStore.downloadForLater(than: CatalogStore.onDiskGeneratedAt())
                if kept { scheduleProcessing() }
                await MeaningIndex.shared.refreshVectors()
                log.info("background: catalog \(kept ? "downloaded, decoding on charge" : "unchanged", privacy: .public)")
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            let work = Task.detached(priority: .utility) {
                if let done = CatalogStore.finishPendingDownload() {
                    if let before = done.before { await InterestsStore.scan(before: before, current: done.catalog) }
                    // Search's indexes too, so the first launch on this catalog
                    // reads them instead of building them (SearchCache).
                    if !Task.isCancelled { SearchCache.save(SearchCache.build(done.catalog), key: SearchCache.key(done.catalog)) }
                }
                log.info("background: pending catalog processed")
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Ask for the next run. iOS treats the date as "not before" and decides
    /// the rest; asking again replaces the pending request.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // The catalog refreshes every 3 h (2026-10-18); iOS still decides when.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { log.info("background: not scheduled (\(error.localizedDescription, privacy: .public))") }
    }

    /// The decode, for when the phone is on power. No network: the file is here.
    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do { try BGTaskScheduler.shared.submit(request) }
        catch { log.info("background: processing not scheduled (\(error.localizedDescription, privacy: .public))") }
    }
}
