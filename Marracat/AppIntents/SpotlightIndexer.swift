import AppIntents
import CoreSpotlight
import CryptoKit
import UIKit
import os

/// One Spotlight entry: a saved or recently viewed product, or a followed or
/// premier brand.
struct SpotlightEntry: Hashable {
    let destination: AppDestination
    let title: String
    let subtitle: String
    let keywords: [String]
    let imageURL: String?
    /// Saved and followed outrank premier, which outranks recently viewed.
    let priority: Int
    /// The product's price, for its entity.
    var price: String = ""
    var brandName: String = ""

    var id: String { destination.spotlightID ?? "" }

    /// What the index holds for it: an entry whose fingerprint hasn't changed
    /// isn't sent again.
    var fingerprint: String {
        [title, subtitle, keywords.joined(separator: ","), imageURL ?? "", String(priority), price].joined(separator: "|")
    }
}

/// What goes into Spotlight (owner, 2026-10-14). Only what this shopper made
/// on this phone — saved items, followed brands, recently viewed (only while
/// personalization is on) — plus the dozen premier brands everyone sees on
/// Home. Never the ~147k-product catalog: Spotlight is for getting back to
/// what you already found.
enum SpotlightIndexer {
    static let maxSaved = 300
    static let maxRecent = 30

    enum Priority {
        static let saved = 30, followed = 25, premier = 20, recent = 10
    }

    static func entries(saved: [String], recentlyViewed: [String], personalization: Bool,
                        followedBrands: Set<String>, premierBrandIDs: [String],
                        product: (String) -> Product?, brand: (String) -> Brand?) -> [SpotlightEntry] {
        var out: [SpotlightEntry] = []
        var seen = Set<String>()
        func add(_ e: SpotlightEntry) { if seen.insert(e.id).inserted { out.append(e) } }

        func productEntry(_ p: Product, priority: Int) -> SpotlightEntry {
            let brandName = brand(p.brand)?.name ?? ""
            let price = p.price.formatted(.currency(code: p.currencyCode))
            return SpotlightEntry(destination: .product(p.id), title: p.title,
                                  subtitle: brandName.isEmpty ? price : "\(brandName) · \(price)",
                                  keywords: [brandName, p.productType ?? ""].filter { !$0.isEmpty },
                                  imageURL: p.images.first, priority: priority, price: price, brandName: brandName)
        }
        func brandEntry(_ b: Brand, priority: Int) -> SpotlightEntry {
            SpotlightEntry(destination: .brand(b.id), title: b.name, subtitle: b.tagline ?? String(localized: "Shop \(b.name) on Marracat", comment: "Spotlight result subtitle for a brand with no tagline; the argument is a brand name"),
                           keywords: [b.name, "Marracat"], imageURL: b.image, priority: priority)
        }

        for id in saved.prefix(maxSaved) { if let p = product(id) { add(productEntry(p, priority: Priority.saved)) } }
        for id in followedBrands.sorted() { if let b = brand(id) { add(brandEntry(b, priority: Priority.followed)) } }
        for id in premierBrandIDs { if let b = brand(id) { add(brandEntry(b, priority: Priority.premier)) } }
        if personalization {
            for id in recentlyViewed.prefix(maxRecent) { if let p = product(id) { add(productEntry(p, priority: Priority.recent)) } }
        }
        return out
    }

    /// Ids to delete and entries to (re)send, given what was last indexed.
    static func diff(indexed: [String: String], wanted: [SpotlightEntry]) -> (delete: [String], send: [SpotlightEntry]) {
        let wantedIDs = Set(wanted.map(\.id))
        let delete = indexed.keys.filter { !wantedIDs.contains($0) }.sorted()
        let send = wanted.filter { indexed[$0.id] != $0.fingerprint }
        return (delete, send)
    }
}

/// Keeps the index in step with the shopper: after a save or unsave, a
/// follow, a view, a sign-in, and cleared on sign-out and account deletion.
/// Writes run one after another, off the main thread.
@MainActor
final class SpotlightSync: NSObject {
    static let shared = SpotlightSync()

    /// A named index, as Apple asks (the default index is for prototyping).
    nonisolated static let indexName = "com.divinedavis.marracat.spotlight"
    private static let indexedKey = "spotlight.indexed"
    private static let log = Logger(subsystem: "com.divinedavis.marracat", category: "spotlight")

    private lazy var index: CSSearchableIndex = {
        let index = CSSearchableIndex(name: Self.indexName)
        index.indexDelegate = self
        return index
    }()
    /// The last write; each new one waits for it, so a sign-out's clear can't
    /// land after the sync that follows it.
    private var chain: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    /// Syncs this instance has scheduled (tests: the host app's stays at zero).
    private(set) var scheduled = 0
    /// Times Spotlight asked for everything again (its index was lost).
    private(set) var reindexAllRequests = 0

    /// Where the record of what was indexed lives. The app's is standard
    /// defaults; a test makes its own SpotlightSync on a private suite.
    private let defaults: UserDefaults
    /// Off in the unit-test host. Unit tests run inside the app, and the host's
    /// own syncs (scheduled at launch and when its catalog lands, a couple of
    /// seconds later) wrote this same record under the tests: the sign-out test
    /// read back the host's entries whenever a write landed between its clear
    /// and its check, so it failed only in longer runs (2026-10-14).
    private let enabled: Bool

    init(defaults: UserDefaults = .standard, enabled: Bool = SpotlightSync.enabledInThisProcess) {
        self.defaults = defaults
        self.enabled = enabled
    }

    nonisolated static var enabledInThisProcess: Bool {
        let p = ProcessInfo.processInfo
        return CSSearchableIndex.isIndexingAvailable() && !p.arguments.contains("-NO_SPOTLIGHT")
            && p.environment["XCTestConfigurationFilePath"] == nil
    }

    /// What the app last indexed, by id: each entry's fingerprint.
    private(set) var indexed: [String: String]? {
        get { defaults.dictionary(forKey: Self.indexedKey) as? [String: String] }
        set { defaults.set(newValue, forKey: Self.indexedKey) }
    }

    /// Re-index from the stores, a moment after the last change (a burst of
    /// saves is one write).
    func schedule(catalog: CatalogStore, shopper: ShopperStore, delay: Duration = .seconds(2)) {
        guard enabled, catalog.isComplete else { return }
        scheduled += 1
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let wanted = SpotlightIndexer.entries(
                saved: shopper.saved, recentlyViewed: shopper.recentlyViewed,
                personalization: shopper.personalizationEnabled,
                followedBrands: DealAlertStore.shared.brands, premierBrandIDs: CatalogStore.premierBrandIDs,
                product: catalog.product, brand: catalog.brand)
            self.write(wanted)
        }
    }

    private func write(_ wanted: [SpotlightEntry]) {
        let previous = chain, index = self.index
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // Read after the write before it: a sign-out's clear may have just run.
            let known = self.indexed
            // Nothing recorded (a first launch, or defaults wiped): start clean
            // so nothing left over from before survives.
            if known == nil { try? await index.deleteAllSearchableItems() }
            let (delete, send) = SpotlightIndexer.diff(indexed: known ?? [:], wanted: wanted)
            do {
                if !delete.isEmpty { try await index.deleteSearchableItems(withIdentifiers: delete) }
                if !send.isEmpty {
                    let items = await Task.detached(priority: .utility) { send.map(SpotlightItems.item) }.value
                    try await index.indexSearchableItems(items)
                }
                self.indexed = Dictionary(wanted.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { a, _ in a })
                Self.log.notice("spotlight: \(wanted.count, privacy: .public) indexed, \(send.count, privacy: .public) sent, \(delete.count, privacy: .public) removed")
            } catch {
                // Left as it was: the next change tries again from the same record.
                Self.log.error("spotlight: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Sign-out or account deletion: everything this app put in Spotlight goes.
    /// The next sync adds back only what is on the phone now (the premier
    /// brands, and a guest's own saves).
    func removeAll() {
        pending?.cancel()
        let previous = chain, index = self.index
        chain = Task { [weak self] in
            await previous?.value
            self?.indexed = [:]
            try? await index.deleteAllSearchableItems()
            Self.log.notice("spotlight: cleared")
        }
    }

    /// Waits for the writes so far (tests).
    func flush() async { await chain?.value }
}

extension SpotlightSync: CSSearchableIndexDelegate {
    /// Spotlight lost the index: forget what was sent, so the next sync sends all of it.
    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.reindexAllRequests += 1
            self.defaults.removeObject(forKey: Self.indexedKey)
            if let catalog = IntentRouter.shared.catalog, let shopper = IntentRouter.shared.shopper {
                self.schedule(catalog: catalog, shopper: shopper, delay: .zero)
            }
            acknowledgementHandler()
        }
    }

    nonisolated func searchableIndex(_ searchableIndex: CSSearchableIndex, reindexSearchableItemsWithIdentifiers identifiers: [String], acknowledgementHandler: @escaping () -> Void) {
        Task { @MainActor in
            if var known = self.indexed { for id in identifiers { known.removeValue(forKey: id) }; self.indexed = known }
            if let catalog = IntentRouter.shared.catalog, let shopper = IntentRouter.shared.shopper {
                self.schedule(catalog: catalog, shopper: shopper, delay: .zero)
            }
            acknowledgementHandler()
        }
    }
}

/// Building the searchable items, off the main thread.
enum SpotlightItems {
    static func item(_ e: SpotlightEntry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = e.title
        attributes.displayName = e.title
        attributes.contentDescription = e.subtitle
        attributes.keywords = e.keywords
        attributes.rankingHint = NSNumber(value: e.priority)
        attributes.contentURL = e.destination.url
        attributes.thumbnailData = e.imageURL.flatMap(thumbnail)
        if #available(iOS 18.0, *) {
            switch e.destination {
            case .product(let id):
                attributes.associateAppEntity(ProductEntity(id: id, name: e.title, brandName: e.brandName, price: e.price,
                                                            imageURL: e.imageURL.flatMap(URL.init(string:))),
                                              priority: e.priority)
            case .brand(let id):
                attributes.associateAppEntity(BrandEntity(id: id, name: e.title, tagline: e.subtitle), priority: e.priority)
            default: break
            }
        }
        let item = CSSearchableItem(uniqueIdentifier: e.id, domainIdentifier: domain(e.destination), attributeSet: attributes)
        // Saved items stay until they're unsaved; the rest refresh as they change.
        item.expirationDate = .distantFuture
        return item
    }

    static func domain(_ d: AppDestination) -> String {
        switch d {
        case .product: "product"
        case .brand: "brand"
        default: "other"
        }
    }

    /// A small JPEG of the image the app already downloaded, or nothing: the
    /// indexer never downloads. Made once per image and kept in Caches.
    private static func thumbnail(_ urlString: String) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("spotlight-thumbs", isDirectory: true)
        let file = dir.appendingPathComponent(name + ".jpg")
        if let data = try? Data(contentsOf: file) { return data }
        let stored = ImageLoader.cachedFile(for: url).flatMap { try? Data(contentsOf: $0) }
            ?? URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data
        guard let stored, let image = UIImage(data: stored),
              let small = image.preparingThumbnail(of: CGSize(width: 180, height: 180 * image.size.height / max(image.size.width, 1))),
              let data = small.jpegData(compressionQuality: 0.7) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
