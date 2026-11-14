import Foundation
import Observation

/// Faster catalog refreshes for what this shopper keeps coming back to
/// (owner, 2026-10-20/21). The catalog itself refreshes every 3 hours; on
/// top of it, this phone keeps a brand fresher when its shopper:
///   - viewed one of its products 4+ times in a week, or
///   - visited the brand's page 4+ times in a week:
///     last look under a day ago -> every 5 min, 1-3 days -> 15 min,
///     3-7 days -> 30 min, otherwise the 3-hour catalog;
/// and keeps the stock of products with a restock alert at most 5 minutes
/// old. Looks are counted on the phone only; marracat.com is asked for a
/// brand (web/server/brand-fresh.js), never told who looked. Refreshes run
/// when the app comes forward and before a brand or product is shown, never
/// in the background, so there's no battery cost.
@MainActor
@Observable
final class FreshCatalog {
    static let shared = FreshCatalog()

    /// Fresher copies of catalog products (price, sale price, stock,
    /// options), by product id.
    private(set) var overlay: [String: Product] = [:]
    /// Products a brand added since the last catalog publish, newest first.
    /// They show on the brand's page until the next publish sorts them.
    private(set) var arrivals: [String: [Product]] = [:]

    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var stockAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight = Set<String>()
    @ObservationIgnored private var log: Log
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var session: URLSession = .shared
    @ObservationIgnored var origin = URL(string: "https://marracat.com")!

    static let restockEvery: TimeInterval = 5 * 60
    private static let key = "freshCatalog.log"
    private static let week: TimeInterval = 7 * 86_400

    /// The shopper's looks, kept a week: product views (with the product's
    /// brand) and brand-page visits, as seconds since 1970.
    struct Log: Codable, Equatable {
        var products: [String: [Double]] = [:]
        var productBrand: [String: String] = [:]
        var brands: [String: [Double]] = [:]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = (defaults.data(forKey: Self.key)).flatMap { try? JSONDecoder().decode(Log.self, from: $0) } ?? Log()
    }

    // MARK: The rule

    /// How often looks like these keep a brand fresh, or nil for the
    /// 3-hour catalog.
    nonisolated static func interval(looks: [Date], now: Date = .now) -> TimeInterval? {
        let recent = looks.filter { now.timeIntervalSince($0) < week && $0 <= now }
        guard recent.count >= 4, let last = recent.max() else { return nil }
        let ago = now.timeIntervalSince(last)
        if ago < 86_400 { return 5 * 60 }
        if ago < 3 * 86_400 { return 15 * 60 }
        return 30 * 60
    }

    /// The fastest any of the brand's products or its page has earned.
    func interval(forBrand brand: String, now: Date = .now) -> TimeInterval? {
        var best = Self.interval(looks: (log.brands[brand] ?? []).map(Date.init(timeIntervalSince1970:)), now: now)
        for (id, times) in log.products where log.productBrand[id] == brand {
            if let i = Self.interval(looks: times.map(Date.init(timeIntervalSince1970:)), now: now) { best = min(best ?? i, i) }
        }
        return best
    }

    // MARK: Looks

    func productViewed(_ product: Product, now: Date = .now) {
        log.products[product.id, default: []].append(now.timeIntervalSince1970)
        log.productBrand[product.id] = product.brand
        prune(now: now)
    }

    func brandVisited(_ brand: String, now: Date = .now) {
        log.brands[brand, default: []].append(now.timeIntervalSince1970)
        prune(now: now)
    }

    /// A week of looks, at most 200 products and 100 brands, saved.
    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.week
        func trim(_ d: [String: [Double]], cap: Int) -> [String: [Double]] {
            let kept = d.mapValues { Array($0.filter { $0 >= cutoff }.suffix(50)) }.filter { !$0.value.isEmpty }
            guard kept.count > cap else { return kept }
            let newest = kept.sorted { ($0.value.max() ?? 0) > ($1.value.max() ?? 0) }.prefix(cap)
            return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        log.products = trim(log.products, cap: 200)
        log.brands = trim(log.brands, cap: 100)
        log.productBrand = log.productBrand.filter { log.products[$0.key] != nil }
        if let data = try? JSONEncoder().encode(log) { defaults.set(data, forKey: Self.key) }
    }

    /// Signed out or history cleared: the looks go with it.
    func forget() {
        log = Log()
        defaults.removeObject(forKey: Self.key)
    }

    /// Drops every fresher copy: a new catalog publish supersedes them.
    func clear() {
        overlay = [:]
        arrivals = [:]
        fetchedAt = [:]
        stockAt = [:]
    }

    // MARK: Reading

    /// The freshest copy of a product this phone has.
    func current(_ product: Product) -> Product { overlay[product.id] ?? product }

    func arrival(_ id: String) -> Product? {
        for list in arrivals.values { if let p = list.first(where: { $0.id == id }) { return p } }
        return nil
    }

    // MARK: Refreshing

    private var testing: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-OFFLINE_CATALOG") || args.contains("-UITEST_RESET")
    }

    /// Every brand that's due, a few at a time: when the app comes forward.
    func refreshDue(catalog: CatalogStore, now: Date = .now) async {
        let brands = Set(log.brands.keys).union(log.productBrand.values)
        let due = brands.filter { isDue($0, now: now) }.prefix(8)
        await withTaskGroup(of: Void.self) { group in
            for (i, brand) in due.enumerated() where i < 3 { group.addTask { await self.refresh(brand, catalog: catalog, now: now) } }
        }
        for brand in due.dropFirst(3) { await refresh(brand, catalog: catalog, now: now) }
    }

    /// Before a brand's page or product shows: only if it's due.
    func refreshIfDue(_ brand: String, catalog: CatalogStore, now: Date = .now) async {
        guard isDue(brand, now: now) else { return }
        await refresh(brand, catalog: catalog, now: now)
    }

    func isDue(_ brand: String, now: Date = .now) -> Bool {
        guard let every = interval(forBrand: brand, now: now) else { return false }
        guard let last = fetchedAt[brand] else { return true }
        return now.timeIntervalSince(last) >= every
    }

    private func refresh(_ brand: String, catalog: CatalogStore, now: Date) async {
        guard !testing, !inFlight.contains(brand) else { return }
        inFlight.insert(brand)
        defer { inFlight.remove(brand) }
        fetchedAt[brand] = now
        guard let url = URL(string: "/api/brands/\(brand)/fresh", relativeTo: origin) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        struct Reply: Decodable { let products: [Product] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data) else { return }
        merge(reply.products, brand: brand, catalog: catalog)
    }

    /// The store's live copy over the catalog's. A product the catalog has
    /// keeps its department, aisles, tags and badges and takes the store's
    /// price, sale price, stock and options; one it doesn't is a new
    /// arrival, placed in the brand's own department until the next publish.
    func merge(_ fresh: [Product], brand: String, catalog: CatalogStore) {
        var next = overlay
        var added: [Product] = []
        for f in fresh where f.brand == brand {
            if let known = catalog.baseProduct(f.id) {
                var p = known
                p.price = f.price
                p.compareAt = f.compareAt
                p.available = f.available
                if !f.variants.isEmpty { p.variants = f.variants }
                next[p.id] = p == known ? nil : p
            } else {
                var p = f
                if p.category.isEmpty { p.category = catalog.brand(brand)?.category ?? "" }
                added.append(p)
            }
        }
        overlay = next
        arrivals[brand] = added.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
    }

    /// Restock-alert products' stock, at most `restockEvery` old: when the
    /// app comes forward and the alerts are listed.
    func refreshRestock(_ ids: [String], catalog: CatalogStore, now: Date = .now) async {
        guard !testing else { return }
        for id in ids.prefix(20) {
            if let at = stockAt[id], now.timeIntervalSince(at) < Self.restockEvery { continue }
            stockAt[id] = now
            guard let known = catalog.baseProduct(id),
                  let url = URL(string: "/api/products/\(id)/stock", relativeTo: origin) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let live = try? decoder.decode(LiveStock.self, from: data), live.live else { continue }
            applyStock(live, to: known)
        }
    }

    func applyStock(_ live: LiveStock, to known: Product) {
        var p = overlay[known.id] ?? known
        if let available = live.available { p.available = available }
        if let variants = live.variants {
            let byID = Dictionary(variants.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            p.variants = p.variants.map { v in
                guard let l = byID[v.id] else { return v }
                var v = v
                v.available = l.available
                return v
            }
        }
        overlay[known.id] = p
    }
}
