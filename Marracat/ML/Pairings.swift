import SwiftUI

/// "Frequently bought together" (owner, 2026-10-02): products from different
/// departments that shoppers put in the same cart or order. The server counts
/// each pair once per phone and only shows a pair three different phones have
/// made (web/server/pairings.js). Until a product has such pairs, the row
/// shows style-matched picks from other departments ("Pairs well with").
@MainActor
enum Pairings {
    private static var cache: [String: [String]] = [:]

    /// A cart or an order: what was chosen together. Sent once per set.
    static func report(_ productIDs: [String]) {
        let ids = Array(Set(productIDs)).sorted()
        guard ids.count >= 2, ids.count <= 20,
              let body = try? JSONSerialization.data(withJSONObject: ["products": ids]) else { return }
        let key = "pairs.sent." + ids.joined(separator: ",").hashValue.description
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        var request = URLRequest(url: URL(string: "https://marracat.com/api/pairs")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        Task.detached(priority: .background) { _ = try? await URLSession.shared.data(for: request) }
    }

    /// Learned pairs for a product, best first (empty until there are some).
    static func learned(for productID: String) async -> [String] {
        if let hit = cache[productID] { return hit }
        var comps = URLComponents(string: "https://marracat.com/api/pairs")!
        comps.queryItems = [URLQueryItem(name: "product", value: productID)]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 10
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        struct Reply: Decodable { let pairs: [String] }
        let ids = (try? await URLSession.shared.data(for: request))
            .flatMap { try? JSONDecoder().decode(Reply.self, from: $0.0) }?.pairs ?? []
        cache[productID] = ids
        return ids
    }

    private static var complementCache: [String: [String]] = [:]
    /// Replaced in tests.
    static var fetchComplements: (String) async -> [String] = Pairings.requestComplements

    /// What the brand's own store suggests with this product (Shopify's
    /// complementary recommendations, via marracat.com), once per product per
    /// launch. Empty when the store suggests nothing.
    static func complements(for productID: String) async -> [String] {
        if let hit = complementCache[productID] { return hit }
        let ids = await fetchComplements(productID)
        complementCache[productID] = ids
        return ids
    }

    static func clearCaches() { cache = [:]; complementCache = [:] }

    private static func requestComplements(_ productID: String) async -> [String] {
        guard let escaped = productID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://marracat.com/api/products/\(escaped)/complements") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        struct Reply: Decodable { let products: [String] }
        return (try? await URLSession.shared.data(for: request))
            .flatMap { try? JSONDecoder().decode(Reply.self, from: $0.0) }?.products ?? []
    }

    /// Which source fills the row: the brand's suggestions, then what
    /// shoppers bought together, then (nil) the style-matched fallback.
    enum Source: Equatable { case complements, boughtTogether }
    static func choose(complements: [Product], learned: [Product]) -> (source: Source, products: [Product])? {
        if complements.count >= 4 { return (.complements, Array(complements.prefix(12))) }
        if learned.count >= 4 { return (.boughtTogether, Array(learned.prefix(12))) }
        return nil
    }
}

struct PairingsRow: View {
    let product: Product
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @State private var row: (title: String, products: [Product], track: String)?

    var body: some View {
        Group {
            if let row, row.products.count >= 4 {
                ProductRow(title: row.title, products: row.products, track: row.track).accessibilityIdentifier("pairsRow")
            } else {
                Color.clear.frame(height: 0)   // so .task below starts (see AsyncProductRow)
            }
        }
        .task(id: product.id) {
            // Owner, 2026-10-10: the brand's own suggestions first ("Goes well
            // with"), then shoppers' pairs, then the style-matched fallback.
            // This product's department and the ones the shopper has shown
            // interest in, nothing else (owner, 2026-11-09: "if they never
            // purchase dog food or search for it we should never show it").
            var allowed = catalog.touchedDepartments(of: shopper)
            if !allowed.isEmpty { allowed.insert(product.category) }
            let usable = { (ids: [String]) in
                ids.compactMap(catalog.product).filter { $0.available && $0.id != product.id && (allowed.isEmpty || allowed.contains($0.category)) }
            }
            let complements = usable(await Pairings.complements(for: product.id))
            let learned = complements.count >= 4 ? [] : usable(await Pairings.learned(for: product.id))
            switch Pairings.choose(complements: complements, learned: learned) {
            case let (.complements, products)?: row = (String(localized: "Goes well with", comment: "Product row title on a product page"), products, "complements")
            case let (.boughtTogether, products)?: row = (String(localized: "Frequently bought together", comment: "Product row title on a product page"), products, "pairs")
            case nil: row = (String(localized: "Pairs well with", comment: "Product row title on a product page"), await MeaningPicks.pairsWell(with: product, catalog: catalog, allowed: allowed), "pairs_style")
            }
        }
    }
}
