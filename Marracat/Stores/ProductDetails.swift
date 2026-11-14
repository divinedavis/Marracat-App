import Foundation
import Observation

/// The parts of a product only its own page needs: the description, the
/// images after the first, and — for anything with sizes or colours — the
/// variants, which the catalog leaves out (it carries option words instead).
///
/// The published catalog carries neither. Dropping them is what lets the app
/// list every product a brand has in stock rather than the first eighty —
/// they are 60% of a product's bytes and are read on one screen. See
/// catalog/publish_snapshots.py.
struct ProductDetail: Decodable, Sendable {
    let description: String?
    let images: [String]?
    let variants: [Variant]?
    /// What the store calls each option, in variant-title order ("Color",
    /// "Size"; catalog/build_catalog.py option_names). Absent for stores
    /// that don't name them.
    var optionNames: [String]? = nil
}

/// The brand's own store's stock right now (web/server/live-stock.js): each
/// option's availability and, for dollar products, its price. The catalog is
/// refreshed about every 12 hours and the phone's copy can be older, so a
/// product could read "Currently unavailable" while the store — and the
/// "Back in stock" push that opened the page — said otherwise (2026-10-11).
struct LiveStock: Decodable, Sendable, Equatable {
    struct Option: Decodable, Sendable, Equatable {
        let id: Int64
        var title: String?
        var available: Bool
        var price: Double?
        var compareAt: Double?
    }
    let live: Bool
    var available: Bool?
    var variants: [Option]?

    /// Catalog variants with the store's answer laid over them. Options the
    /// store doesn't list keep the catalog's values; with no catalog options
    /// yet, the store's own list stands in. No live answer: unchanged.
    static func overlay(_ base: [Variant], live: LiveStock?, fallbackPrice: Double) -> [Variant] {
        guard let live, live.live else { return base }
        guard let options = live.variants, !options.isEmpty else {
            // Product-level only: it applies to every option.
            guard let available = live.available else { return base }
            return base.map { var v = $0; v.available = available; return v }
        }
        if base.isEmpty {
            return options.map {
                Variant(id: $0.id, title: $0.title ?? "", price: $0.price ?? fallbackPrice,
                        compareAt: $0.price == nil ? nil : $0.compareAt, available: $0.available)
            }
        }
        let byID = Dictionary(options.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return base.map { v in
            guard let o = byID[v.id] else { return v }
            var next = v
            next.available = o.available
            if let price = o.price { next.price = price; next.compareAt = o.compareAt }
            return next
        }
    }
}

@MainActor
@Observable
final class ProductDetailStore {
    /// What has been fetched this session. A product page is opened again and
    /// again — from search, from Home, from a list — and the description does
    /// not change between those.
    private var loaded: [String: ProductDetail] = [:]
    private var loading: Set<String> = []
    private let session: URLSession
    private let origin: URL

    init(session: URLSession = .shared, origin: URL = URL(string: "https://marracat.com")!) {
        self.session = session
        self.origin = origin
    }

    func detail(_ id: String) -> ProductDetail? { loaded[id] }

    /// Live stock, kept briefly: unlike the description it changes, and the
    /// server already shares one store fetch between shoppers for ~90 s.
    private var stock: [String: (value: LiveStock, at: Date)] = [:]
    private var stockLoading: Set<String> = []
    static let stockFreshFor: TimeInterval = 60
    /// UI tests: no live stock (the catalog is what they assert against),
    /// unless -LIVE_STOCK_IN stands in a store that has everything in stock.
    @ObservationIgnored private let testing = ProcessInfo.processInfo.arguments.contains("-UITEST_RESET")
    @ObservationIgnored private let stubInStock = ProcessInfo.processInfo.arguments.contains("-LIVE_STOCK_IN")

    func liveStock(_ id: String) -> LiveStock? { stock[id]?.value }

    /// True while the store is being asked, so a sold-out page can say it's
    /// checking instead of flashing "Currently unavailable".
    func isCheckingStock(_ id: String) -> Bool { stockLoading.contains(id) }

    /// Forget a product's live stock, so the next look asks the store again
    /// (a tapped "Back in stock" push).
    func forgetStock(_ id: String) { stock[id] = nil }

    /// Asks marracat.com for the brand's live stock. Silent on failure: the
    /// catalog's stock stays, as before. Never blocks the page.
    func loadStock(_ id: String, now: Date = .now) async {
        if let hit = stock[id], now.timeIntervalSince(hit.at) < Self.stockFreshFor { return }
        guard !stockLoading.contains(id) else { return }
        if testing && !stubInStock { return }
        if stubInStock {
            stock[id] = (LiveStock(live: true, available: true, variants: nil), now)
            return
        }
        guard let url = URL(string: "/api/products/\(id)/stock", relativeTo: origin) else { return }
        stockLoading.insert(id)
        defer { stockLoading.remove(id) }
        var request = URLRequest(url: url)
        // Short: a slow store shows the catalog's stock, not a spinner.
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? Self.decoder.decode(LiveStock.self, from: data), value.live else { return }
        stock[id] = (value, now)
    }

    /// True while a page's fetch is in flight, so it can say it's checking
    /// stock instead of calling a product with no variants yet unavailable.
    func isLoading(_ id: String) -> Bool { loading.contains(id) }

    /// Variants arrive as `compare_at`, like the catalog.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Fills in a product's description and gallery. Silent on failure: the
    /// page already has the title, price, variants and first image, so a
    /// missing description is a smaller page, not a broken one.
    func load(_ id: String) async {
        guard loaded[id] == nil, !loading.contains(id) else { return }
        guard let url = URL(string: "/api/products/\(id)", relativeTo: origin) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let detail = try? Self.decoder.decode(ProductDetail.self, from: data) else { return }
        loaded[id] = detail
    }
}
