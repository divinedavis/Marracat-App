import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import WidgetKit
import os

/// Building the widgets' snapshot (Shared/WidgetSnapshot.swift) from the
/// stores. Pure, so WidgetTests runs it without the app's singletons.
enum WidgetSnapshotBuilder {
    static let maxDrops = 12
    static let maxBrands = 12
    static let productsPerBrand = 3
    static let maxOrders = 5
    /// Orders older than this drop off, and delivered ones after `deliveredFor`.
    static let orderWindow: TimeInterval = 30 * 86_400
    static let deliveredFor: TimeInterval = 3 * 86_400

    /// The price each saved item had when it was first seen saved on this
    /// phone. Items no longer saved are forgotten; new ones start at today's
    /// price (a markdown the brand already had still counts, via compareAt).
    static func baselines(saved: [String], old: [String: Double], price: (String) -> Double?) -> [String: Double] {
        var out: [String: Double] = [:]
        for id in saved {
            if let was = old[id] { out[id] = was } else if let p = price(id) { out[id] = p }
        }
        return out
    }

    struct Drop: Equatable {
        let product: Product
        let was: Double
        let percent: Int
    }

    /// Saved, in-stock items cheaper than the highest of: the price when
    /// saved, the price a price alert was set at, and the brand's own
    /// compare-at price. Deepest first; 1% or more.
    static func drops(saved: [String], product: (String) -> Product?, baselines: [String: Double],
                      trackedAt: [String: Double]) -> [Drop] {
        var out: [Drop] = []
        for id in saved {
            guard let p = product(id), p.available, p.price > 0 else { continue }
            let was = [baselines[id], trackedAt[id], p.compareAt].compactMap { $0 }.max() ?? 0
            guard was > p.price + 0.009 else { continue }
            let percent = Int(((was - p.price) / was * 100).rounded())
            if percent >= 1 { out.append(Drop(product: p, was: was, percent: percent)) }
        }
        // Stable: ties keep the saved order (newest save first).
        return out.enumerated().sorted { a, b in
            a.element.percent != b.element.percent ? a.element.percent > b.element.percent : a.offset < b.offset
        }.map(\.element)
    }

    /// The thumbnail file for an image URL, and what to download for it.
    static func thumbName(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    struct Inputs {
        var saved: [String]
        var signedIn: Bool
        var product: (String) -> Product?
        var brand: (String) -> Brand?
        var category: (String) -> Category?
        var brandProducts: (String) -> [Product]
        var premierBrandIDs: [String]
        var featureKinds: [String: String]
        var baselines: [String: Double]
        var trackedAt: [String: Double]
        var checkouts: [CheckoutRecord]
        /// An order's progress: its step (0–3), Your Orders' headline and carrier.
        var progress: (CheckoutRecord) -> (step: Int, headline: String, carrier: String?, delivered: Date?)
        var now: Date = .now
    }

    /// The snapshot, and for each thumbnail it names the image to shrink into it.
    static func build(_ i: Inputs) -> (WidgetSnapshot, thumbs: [String: String]) {
        var thumbs: [String: String] = [:]
        func thumb(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let name = thumbName(raw)
            thumbs[name] = raw
            return name
        }
        func price(_ value: Double, _ code: String) -> String { value.formatted(.currency(code: code)) }

        var s = WidgetSnapshot()
        s.signedIn = i.signedIn
        s.savedCount = i.saved.count

        let drops = drops(saved: i.saved, product: i.product, baselines: i.baselines, trackedAt: i.trackedAt).prefix(maxDrops)
        s.priceDrops = drops.map { d in
            WidgetProduct(id: d.product.id, title: d.product.title, brandName: i.brand(d.product.brand)?.name ?? "",
                          category: d.product.category, price: price(d.product.price, d.product.currencyCode),
                          was: price(d.was, d.product.currencyCode), percentOff: d.percent, thumb: thumb(d.product.images.first))
        }
        var seenDepartments = Set<String>()
        s.dropDepartments = s.priceDrops.compactMap { p in
            guard seenDepartments.insert(p.category).inserted, let c = i.category(p.category) else { return nil }
            return WidgetDepartment(id: c.id, name: c.name)
        }.sorted { $0.name < $1.name }

        s.brands = i.premierBrandIDs.prefix(maxBrands).compactMap { id -> WidgetBrand? in
            guard let b = i.brand(id) else { return nil }
            let products = featured(i.brandProducts(id), kind: i.featureKinds[id])
            let tiles = products.prefix(productsPerBrand).map { p in
                WidgetProduct(id: p.id, title: p.title, brandName: b.name, category: p.category,
                              price: price(p.price, p.currencyCode), thumb: thumb(p.images.first))
            }
            return WidgetBrand(id: b.id, name: b.name, tagline: b.tagline?.isEmpty == false ? b.tagline : nil,
                               thumb: thumb(b.image ?? products.first?.images.first), products: Array(tiles))
        }

        s.orders = i.checkouts
            .filter { i.now.timeIntervalSince($0.date) < orderWindow }
            .sorted { $0.date > $1.date }
            .compactMap { r -> WidgetOrder? in
                let p = i.progress(r)
                if p.step >= 3, let at = p.delivered, i.now.timeIntervalSince(at) > deliveredFor { return nil }
                let firstProduct = r.productIDs.lazy.compactMap(i.product).first
                let item = r.items?.first?.title ?? firstProduct?.title
                let number = r.orderID.flatMap(orderNumber).flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
                return WidgetOrder(id: r.id.uuidString, brandID: r.brandID, brandName: i.brand(r.brandID)?.name ?? String(localized: "Your order", comment: "Widget fallback when the brand is unknown"),
                                   item: item, itemCount: max(r.itemCount, 1), step: min(max(p.step, 0), 3),
                                   headline: p.headline, carrier: p.carrier, placed: r.date,
                                   thumb: thumb(firstProduct?.images.first),
                                   link: WidgetLink.order(brandID: r.brandID, number: number).absoluteString)
            }
            .prefix(maxOrders).map { $0 }

        return (s, thumbs)
    }

    /// "1042" from gid://shopify/Order/1042?key=… (OrderTrackingStore.number,
    /// which is main-actor bound).
    static func orderNumber(_ gid: String) -> String? {
        gid.split(separator: "/").last.map(String.init)?.split(separator: "?").first.map(String.init)
    }

    /// A premier brand's products with photos, one per title, in stock first;
    /// a brand Home shows by one kind (Curves' totes) shows only that kind.
    static func featured(_ products: [Product], kind: String?) -> [Product] {
        var pool = products.filter { !$0.images.isEmpty }
        if let kind { pool = pool.filter { $0.title.lowercased().contains(kind) } }
        if pool.contains(where: \.available) { pool = pool.filter(\.available) }
        var titles = Set<String>()
        return pool.filter { titles.insert($0.title.lowercased()).inserted }
    }
}

/// Keeps the widgets' snapshot in step with the app: after a save, a price
/// change (a new catalog or a price alert), an order update, a sign-in; and
/// cleared on sign-out and account deletion. Only the widgets whose part
/// changed are reloaded (WidgetCenter.reloadTimelines(ofKind:)); reloads asked
/// for while the app is in the foreground don't count against a widget's
/// daily budget (WidgetKit, "Keeping a widget up to date").
@MainActor
final class WidgetSync {
    static let shared = WidgetSync()

    private static let baselineKey = "widgets.savedPrices.v1"
    private static let log = Logger(subsystem: "com.divinedavis.marracat", category: "widgets")
    /// Downloads per sync at most; the rest come with the next one.
    static let maxDownloads = 40

    private var pending: Task<Void, Never>?
    /// Bumped by `clear`, so a sync that started before a sign-out never
    /// writes the previous account's items back.
    private var generation = 0
    private let defaults: UserDefaults
    private let session: URLSession
    /// Off in the unit-test host (WidgetTests points the store at a temporary
    /// folder and the host app must not write into it) and with -NO_WIDGETS.
    private var enabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-NO_WIDGETS")
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
    }

    var baselines: [String: Double] {
        get { defaults.dictionary(forKey: Self.baselineKey) as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: Self.baselineKey) }
    }

    /// Re-write a moment after the last change (a burst of saves is one write).
    func schedule(catalog: CatalogStore, shopper: ShopperStore, signedIn: Bool, delay: Duration = .seconds(2)) {
        guard enabled, catalog.isComplete else { return }
        pending?.cancel()
        let generation = self.generation
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            await self.sync(catalog: catalog, shopper: shopper, signedIn: signedIn, generation: generation)
        }
    }

    func sync(catalog: CatalogStore, shopper: ShopperStore, signedIn: Bool, generation: Int? = nil) async {
        let generation = generation ?? self.generation
        let bases = WidgetSnapshotBuilder.baselines(saved: shopper.saved, old: baselines, price: { catalog.product($0)?.price })
        baselines = bases
        let relay = RelayStore.shared, tracking = OrderTrackingStore.shared
        let inputs = WidgetSnapshotBuilder.Inputs(
            saved: shopper.saved, signedIn: signedIn,
            product: catalog.product, brand: catalog.brand, category: catalog.category,
            brandProducts: { Array(catalog.products(for: $0)) },
            premierBrandIDs: CatalogStore.premierBrandIDs, featureKinds: CatalogStore.premierFeatureKinds,
            baselines: bases, trackedAt: DealAlertStore.shared.trackedAt,
            checkouts: shopper.checkouts,
            progress: { r in
                let events = relay.events(for: r, brand: catalog.brand(r.brandID), allOrders: shopper.checkouts) + tracking.events(for: r)
                let step = RelayStore.step(events)
                let carrier = events.last { $0.carrier != nil }?.carrier.map(OrderDetailView.carrierName)
                let delivered = events.last { $0.kind == "delivered" || $0.trackingStep == "delivered" }?.date
                return (step, OrderDetailView.headline(step: step, events: events, placed: r.date), carrier, delivered)
            })
        let (snapshot, thumbs) = WidgetSnapshotBuilder.build(inputs)
        let fetched = await Self.fetchThumbs(thumbs, session: session)
        guard generation == self.generation else { return }
        let old = WidgetStore.read()
        let onDisk = WidgetStore.snapshotURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        // A thumbnail that arrived since the last write changes nothing in the
        // snapshot but should still show, so newly fetched files count too.
        let changed = onDisk ? snapshot.changedKinds(from: old) : WidgetKind.all
        do {
            try WidgetStore.write(snapshot)
            WidgetStore.pruneThumbs(keeping: snapshot.thumbNames)
        } catch {
            Self.log.error("widgets: write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let kinds = fetched ? WidgetKind.all : changed
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        Self.log.notice("widgets: \(snapshot.priceDrops.count, privacy: .public) drops, \(snapshot.brands.count, privacy: .public) brands, \(snapshot.orders.count, privacy: .public) orders; reloaded \(kinds.count, privacy: .public)")
    }

    /// Sign-out or account deletion: the snapshot, its thumbnails and the
    /// saved-price record go; every widget reloads to its empty state. The
    /// next sync writes only what the app now shows (a guest's own saves,
    /// the featured brands).
    func clear() {
        generation += 1
        pending?.cancel()
        WidgetStore.clear()
        defaults.removeObject(forKey: Self.baselineKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Thumbnails

    /// Shrinks each missing thumbnail to WidgetStore.thumbPixels: from the
    /// app's own image cache when it's there, else a small download (the
    /// CDN's resized copy where the store offers one), four at a time.
    /// True when any new file landed.
    private static func fetchThumbs(_ wanted: [String: String], session: URLSession) async -> Bool {
        let missing = Array(wanted.filter { WidgetStore.thumbURL($0.key) == nil }.prefix(maxDownloads))
        var any = false
        for start in stride(from: 0, to: missing.count, by: 4) {
            let batch = missing[start..<min(start + 4, missing.count)]
            let landed = await withTaskGroup(of: Bool.self) { group in
                for (name, raw) in batch {
                    group.addTask {
                        guard let data = await source(raw, session: session), let small = shrink(data) else { return false }
                        return (try? WidgetStore.saveThumb(small, named: name)) != nil
                    }
                }
                var n = false
                for await ok in group where ok { n = true }
                return n
            }
            any = any || landed
        }
        return any
    }

    nonisolated private static func source(_ raw: String, session: URLSession) async -> Data? {
        guard let sized = sizedImageURL(raw, width: WidgetStore.thumbPixels), let original = URL(string: raw) else { return nil }
        for url in [sized, original] {
            if let f = ImageLoader.cachedFile(for: url), let d = try? Data(contentsOf: f) { return d }
            if let d = URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data { return d }
        }
        guard sized.scheme == "https" else { return nil }
        var request = URLRequest(url: sized)
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8 << 20 else { return nil }
        return data
    }

    /// A JPEG no bigger than thumbPixels on its longer side, decoded straight
    /// at that size (ImageIO) so a large original never sits in memory.
    nonisolated static func shrink(_ data: Data, pixels: Int = WidgetStore.thumbPixels) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length <= WidgetStore.maxThumbBytes else { return nil }
        return out as Data
    }
}
