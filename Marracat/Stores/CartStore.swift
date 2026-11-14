import Foundation
import Observation

struct CartLine: Codable, Identifiable, Hashable {
    var id: String { "\(productID)#\(variantID)" }
    let productID: String
    let variantID: Int64
    var quantity: Int
    /// What was chosen and what it cost, captured when it went in the basket.
    ///
    /// The catalog only carries variants for products that have exactly one,
    /// because variant lists were 56% of it and a product page fetches its own.
    /// A basket that reads its prices out of the catalog would empty itself.
    /// Older carts were saved without these, so they stay optional and fall
    /// back to the catalog.
    var option: String? = nil
    var unitPrice: Double? = nil
    var currency: String? = nil
}

/// Checkout happens on each brand's own store: Shopify cart permalinks
/// (`/cart/<variant>:<qty>,…`) pre-fill that brand's cart, so the brand keeps
/// the sale, the customer, and the fulfilment.
@Observable
final class CartStore {
    private static let key = "cart.lines.v1"
    private var activeKey = CartStore.key
    private let defaults: UserDefaults

    private(set) var lines: [CartLine] = [] {
        didSet {
            save()
            // A change made here (not one read from the account) is sent to
            // the account's cart, which the website shares (CartSync).
            if !applyingRemote && !switching { syncState.dirty = true; onChange?() }
        }
    }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var applyingRemote = false
    @ObservationIgnored private var switching = false

    /// The account cart's stamp at the last sync, and whether this phone has
    /// changes it hasn't sent; kept per account, beside the lines.
    struct SyncState: Codable { var updated: Double = 0; var dirty = false }
    var syncState: SyncState {
        get { defaults.data(forKey: activeKey + ".sync").flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState() }
        set { if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: activeKey + ".sync") } }
    }

    /// The account's cart, as read from the server: it replaces this one.
    func applyRemote(_ remote: [CartLine]) {
        applyingRemote = true
        lines = remote
        applyingRemote = false
    }

    /// A cart started signed out joins the account's on sign-in, keeping the
    /// larger quantity of anything in both.
    func mergeIn(_ guest: [CartLine]) {
        guard !guest.isEmpty else { return }
        var merged = lines
        for g in guest {
            if let i = merged.firstIndex(where: { $0.id == g.id }) { merged[i].quantity = max(merged[i].quantity, g.quantity) }
            else { merged.append(g) }
        }
        lines = merged
    }

    static func merge(_ a: [CartLine], _ b: [CartLine]) -> [CartLine] {
        var out = a
        for l in b {
            if let i = out.firstIndex(where: { $0.id == l.id }) { out[i].quantity = max(out[i].quantity, l.quantity) }
            else { out.append(l) }
        }
        return out
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([CartLine].self, from: data) {
            lines = saved
        }
    }

    func activate(_ accountID: String?) {
        activeKey = accountID.map { "cart.account." + $0 } ?? Self.key
        switching = true
        lines = defaults.data(forKey: activeKey).flatMap { try? JSONDecoder().decode([CartLine].self, from: $0) } ?? []
        switching = false
    }
    func eraseAccountCache() { defaults.removeObject(forKey: activeKey); defaults.removeObject(forKey: activeKey + ".sync"); activate(nil) }

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }

    func add(productID: String, variantID: Int64, quantity: Int = 1,
             option: String? = nil, unitPrice: Double? = nil, currency: String? = nil) {
        SearchMemory.recordAction()
        Analytics.log("add_to_cart", ["product": .string(productID), "qty": .int(quantity)])
        let together = Array(Set(lines.map(\.productID) + [productID]))
        Task { @MainActor in
            TasteProfile.shared.record(productID, .cart)
            Pairings.report(together)
        }
        if let i = lines.firstIndex(where: { $0.productID == productID && $0.variantID == variantID }) {
            lines[i].quantity = min(lines[i].quantity + quantity, 10)
        } else {
            lines.append(CartLine(productID: productID, variantID: variantID, quantity: min(quantity, 10),
                                  option: option, unitPrice: unitPrice, currency: currency))
        }
    }

    func setQuantity(_ quantity: Int, for line: CartLine) {
        guard let i = lines.firstIndex(of: line) else { return }
        if quantity <= 0 { lines.remove(at: i) } else { lines[i].quantity = min(quantity, 10) }
    }

    func remove(_ line: CartLine) {
        Analytics.log("remove_from_cart", ["product": .string(line.productID), "qty": .int(line.quantity)])
        lines.removeAll { $0.id == line.id }
    }

    func remove(brand: String, catalog: CatalogStore) {
        lines.removeAll { catalog.product($0.productID)?.brand == brand }
    }

    /// Lines grouped by brand, in the order brands were first added.
    func groups(catalog: CatalogStore) -> [(brand: Brand, lines: [CartLine])] {
        var order: [String] = []
        var byBrand: [String: [CartLine]] = [:]
        for line in lines {
            guard let b = catalog.product(line.productID)?.brand else { continue }
            if byBrand[b] == nil { order.append(b) }
            byBrand[b, default: []].append(line)
        }
        return order.compactMap { id in
            catalog.brand(id).map { ($0, byBrand[id] ?? []) }
        }
    }

    func subtotal(_ lines: [CartLine], catalog: CatalogStore) -> Double {
        lines.reduce(0) { sum, line in
            sum + Self.unitPrice(line, catalog: catalog) * Double(line.quantity)
        }
    }

    /// What one of these costs: what it cost when it was added, or the catalog
    /// if this line predates that being recorded.
    static func unitPrice(_ line: CartLine, catalog: CatalogStore) -> Double {
        if let price = line.unitPrice { return price }
        let p = catalog.product(line.productID)
        return (p?.variants.first { $0.id == line.variantID }?.price) ?? p?.price ?? 0
    }

    func subtotalsByCurrency(_ lines: [CartLine], catalog: CatalogStore) -> [(currency: String, amount: Double)] {
        var totals: [String: Double] = [:]
        for line in lines {
            guard let p = catalog.product(line.productID) else { continue }
            let currency = line.currency ?? p.currencyCode
            totals[currency, default: 0] += Self.unitPrice(line, catalog: catalog) * Double(line.quantity)
        }
        return totals.keys.sorted().map { (currency: $0, amount: totals[$0]!) }
    }

    /// Tags every order so the brand can see it came from Marracat: `ref` shows
    /// as a referral code in the order's Conversion summary, `note` in its
    /// Notes (shopify.dev/docs/apps/build/checkout/create-cart-permalinks).
    static let referral = "marracat"
    static let orderNote = "Order placed through the Marracat app"

    static func checkoutURL(brand: Brand, lines: [CartLine], checkoutEmail: String? = nil, buyer: BuyerDetails? = nil) -> URL? {
        guard !lines.isEmpty else { return nil }
        guard brand.isShopify else { return wooCheckoutURL(brand: brand, lines: lines) }
        // Its permalink goes nowhere; the review screen builds its checkout.
        guard !brand.checksOutByUCP else { return nil }
        let items = lines.map { "\($0.variantID):\($0.quantity)" }.joined(separator: ",")
        var comps = URLComponents(string: "https://\(brand.domain)/cart/\(items)")
        var query = [URLQueryItem(name: "ref", value: referral), URLQueryItem(name: "note", value: orderNote)]
        if let currency = brand.currency {
            query.append(URLQueryItem(name: "currency", value: currency))
        }
        // The Marracat order email when it's on for this account (RelayStore):
        // it's what lets the order be followed, so it wins. Off, the email
        // given, else the shopper's own from their saved details.
        let relay = RelayStore.shared.enabled ? RelayStore.shared.address : nil
        if let email = relay ?? checkoutEmail ?? buyer.map(\.email).flatMap({ $0.isEmpty ? nil : $0 }) {
            query.append(URLQueryItem(name: "checkout[email]", value: email))
        }
        if let buyer { query += shippingPrefill(buyer) }
        comps?.queryItems = query
        // URLComponents leaves "+" bare in a query, and a store reads a bare
        // "+" as a space: "+1 718…" would arrive as " 1 718…". Encode it.
        let encoded = comps?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        comps?.percentEncodedQuery = encoded
        return comps?.url
    }

    /// The saved shipping address as cart-permalink checkout fields, so a
    /// brand without a UCP checkout still opens filled in. Names from
    /// shopify.dev/docs/apps/build/checkout/create-cart-permalinks
    /// ("checkout[shipping_address][first_name|last_name|address1|address2|
    /// city|province|country|zip]"); `phone` isn't in that table but a live
    /// Shopify checkout filled its shipping phone from it (parallelxstore.com,
    /// 2026-10-13). Blank fields are left out rather than sent empty.
    static func shippingPrefill(_ b: BuyerDetails) -> [URLQueryItem] {
        let fields: [(String, String)] = [("first_name", b.firstName), ("last_name", b.lastName), ("address1", b.street),
                                          ("address2", b.extended), ("city", b.city), ("province", b.region),
                                          ("zip", b.postalCode), ("country", b.country), ("phone", b.phone)]
        return fields.compactMap { key, value in
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : URLQueryItem(name: "checkout[shipping_address][\(key)]", value: v)
        }
    }

    /// WooCommerce 10.0 (July 2025) added shareable checkout links: every
    /// line in one URL, and the store answers with a redirect to its own
    /// checkout holding that cart (developer.woocommerce.com/docs/best-practices/
    /// urls-and-routing/checkout-urls). A Woo product's one variant id is its
    /// product id. Only brands verified to work get the link; for the rest
    /// (Ten To One, whose checkout sits behind an age gate) Buy Now opens the
    /// product on the brand's own site.
    private static func wooCheckoutURL(brand: Brand, lines: [CartLine]) -> URL? {
        if brand.checksOutByBigCartel { return URL(string: "https://\(brand.bigCartelHost)/checkout") }
        if brand.checksOutBySwell {
            let items = lines.map { "\($0.productID):\($0.variantID):\($0.quantity)" }.joined(separator: ",")
            var comps = URLComponents(string: "https://marracat.com/go/swell")
            comps?.queryItems = [URLQueryItem(name: "brand", value: brand.id), URLQueryItem(name: "items", value: items)]
            return comps?.url
        }
        if brand.checksOutByWooAddToCart { return URL(string: "https://\(brand.domain)/checkout/") }
        guard brand.checksOutByWooLink else { return brand.storeURL }
        let items = lines.map { "\($0.variantID):\($0.quantity)" }.joined(separator: ",")
        var comps = URLComponents(string: "https://\(brand.domain)/checkout-link/")
        comps?.queryItems = [URLQueryItem(name: "products", value: items)]
        return comps?.url
    }

    /// For an older Woo store: one add-to-cart request per line, loaded in
    /// order in the checkout's own browser session before its checkout page.
    /// Requests the checkout sheet makes before the brand's checkout, in
    /// order: an older WooCommerce store's add-to-cart links, or a Big Cartel
    /// cart's form posts, one per line (its cart takes one item a post).
    static func cartSteps(brand: Brand, lines: [CartLine]) -> [URLRequest] {
        if brand.checksOutByBigCartel {
            return lines.compactMap { line in
                guard let url = URL(string: "https://\(brand.bigCartelHost)/cart") else { return nil }
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                r.httpBody = Data("cart%5Badd%5D%5Bid%5D=\(line.variantID)&cart%5Badd%5D%5Bquantity%5D=\(line.quantity)".utf8)
                return r
            }
        }
        return wooAddToCartSteps(brand: brand, lines: lines).map { URLRequest(url: $0) }
    }

    static func wooAddToCartSteps(brand: Brand, lines: [CartLine]) -> [URL] {
        guard brand.checksOutByWooAddToCart else { return [] }
        return lines.compactMap { line in
            var comps = URLComponents(string: "https://\(brand.domain)/")
            comps?.queryItems = [URLQueryItem(name: "add-to-cart", value: String(line.variantID)),
                                 URLQueryItem(name: "quantity", value: String(line.quantity))]
            return comps?.url
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(lines) { defaults.set(data, forKey: activeKey) }
    }
}
