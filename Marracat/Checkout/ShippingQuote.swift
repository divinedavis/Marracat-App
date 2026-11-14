import CoreLocation
import Foundation
import Observation

/// A brand's standard shipping for what's in the bag, quoted by the brand's
/// own store: the cheapest delivery option it offers to the shopper's ZIP.
/// The shopper can pick a faster one later, on the brand's checkout
/// (owner, 2026-10-14: "show them totals with standard shipping rates. they
/// can change this per item later in the shopify payment sheet").
struct ShippingQuote: Equatable {
    let amountMinor: Int
    let currency: String
    /// The store's name for the option, e.g. "Standard Mail".
    let title: String?
    /// "Est. arrives Oct 17–20", when the store says how long it takes.
    let estimate: String?

    var amount: Double { Double(amountMinor) / 100 }
    var isFree: Bool { amountMinor == 0 }

    /// The cheapest priced option in each delivery group, added up. A Shopify
    /// store sends one group, so this is its cheapest option. Nil when the
    /// store priced nothing (no rate to that ZIP).
    static func standard(from c: UCPCheckout, currency: String) -> ShippingQuote? {
        let cheapest = c.shippingChoices.compactMap { choice in
            choice.options.filter { $0.price != nil }.min { $0.price! < $1.price! }
        }
        guard let first = cheapest.first else { return nil }
        let estimate = DeliveryEstimate.make(title: first.title, description: first.description?.plain,
                                             earliest: first.earliestFulfillmentTime, latest: first.latestFulfillmentTime)
        return ShippingQuote(amountMinor: cheapest.reduce(0) { $0 + $1.price! }, currency: c.currency ?? currency,
                             title: first.title, estimate: estimate?.text)
    }
}

/// Standard-shipping quotes for the bag, one per brand, cached by what's
/// being quoted (brand, items, ZIP) so moving between tabs doesn't ask the
/// stores again. A brand with a UCP endpoint quotes over UCP; a Shopify store
/// whose UCP prices nothing (Fear of God's checkout needs a full address) or
/// that has none quotes from its storefront cart; a Swell store (YEEZY)
/// through marracat.com (owner, 2026-10-16: "anyway we can estimate
/// shipping"). The rest (Big Cartel, WooCommerce) say "Shipping at checkout".
///
/// Privacy: a quote sends the store the items, the ZIP, the state and the
/// country — nothing else. Name, street, email and phone go only when the
/// shopper starts that brand's checkout.
@MainActor @Observable
final class ShippingQuoteStore {
    static let shared = ShippingQuoteStore()

    enum State: Equatable {
        case loading
        case quoted(ShippingQuote)
        /// No UCP endpoint, no rate to this ZIP, or the store didn't answer.
        case atCheckout
    }

    private static let zipKey = "bag.shippingZIP"
    private static let lifetime: TimeInterval = 30 * 60

    /// The ZIP typed in the bag, when the saved details have none.
    var typedZIP: String {
        didSet { UserDefaults.standard.set(typedZIP, forKey: Self.zipKey) }
    }
    private(set) var states: [String: State] = [:]
    private var fetchedAt: [String: Date] = [:]

    init() {
        typedZIP = UserDefaults.standard.string(forKey: Self.zipKey) ?? ""
    }

    /// A US ZIP (5 digits, or ZIP+4).
    nonisolated static func isZIP(_ s: String) -> Bool {
        s.range(of: #"^\d{5}(-\d{4})?$"#, options: .regularExpression) != nil
    }

    /// The ZIP quotes are for: the saved details' first, else the one typed here.
    func zip(details: BuyerDetails?) -> String? {
        let saved = details?.postalCode.trimmingCharacters(in: .whitespaces) ?? ""
        if Self.isZIP(saved) { return saved }
        let typed = typedZIP.trimmingCharacters(in: .whitespaces)
        return Self.isZIP(typed) ? typed : nil
    }

    nonisolated static func key(brand: String, lines: [CartLine], zip: String) -> String {
        brand + "|" + zip + "|" + lines.map { "\($0.variantID):\($0.quantity)" }.sorted().joined(separator: ",")
    }

    /// Can this brand's store price shipping before its checkout?
    nonisolated static func canQuote(_ brand: Brand) -> Bool {
        brand.ucpEndpoint != nil || brand.isShopify || brand.checksOutBySwell
    }

    func state(brand: Brand, lines: [CartLine], zip: String?) -> State? {
        guard Self.canQuote(brand) else { return .atCheckout }
        guard let zip else { return nil }
        return states[Self.key(brand: brand.id, lines: lines, zip: zip)]
    }

    /// Asks every brand that can quote and hasn't recently, all at once.
    func refresh(_ groups: [(brand: Brand, lines: [CartLine])], zip: String?, details: BuyerDetails?, catalog: CatalogStore) async {
        guard let zip else { return }
        let client = UCPClient()
        let pending = groups.filter { g in
            guard Self.canQuote(g.brand) else { return false }
            let key = Self.key(brand: g.brand.id, lines: g.lines, zip: zip)
            if states[key] == .loading { return false }
            if let at = fetchedAt[key], Date.now.timeIntervalSince(at) < Self.lifetime { return false }
            return true
        }
        guard !pending.isEmpty else { return }
        for g in pending { states[Self.key(brand: g.brand.id, lines: g.lines, zip: zip)] = .loading }
        // A Shopify storefront prices by state as well as ZIP.
        let province = pending.contains { $0.brand.isShopify } ? await region(zip: zip, details: details) : nil
        await withTaskGroup(of: (String, State).self) { tasks in
            for g in pending {
                let key = Self.key(brand: g.brand.id, lines: g.lines, zip: zip)
                let brand = g.brand, cartLines = g.lines
                let lines = g.lines.map { UCPLineRequest.make($0, catalog: catalog) }
                tasks.addTask {
                    var quote: ShippingQuote?
                    if let endpoint = brand.ucpEndpoint {
                        quote = (try? await client.quoteShipping(endpoint: endpoint, currency: brand.currencyCode, lines: lines, postalCode: zip)) ?? nil
                    }
                    if quote == nil, brand.isShopify, let province {
                        quote = await StoreRates.shopify(domain: brand.domain, lines: cartLines, zip: zip, state: province)
                    }
                    if quote == nil, brand.checksOutBySwell {
                        quote = await StoreRates.swell(brandID: brand.id, lines: cartLines, zip: zip)
                    }
                    return (key, quote.map(State.quoted) ?? .atCheckout)
                }
            }
            for await (key, state) in tasks {
                states[key] = state
                fetchedAt[key] = .now
            }
        }
    }

    private var regions: [String: String] = [:]

    /// The state a ZIP is in ("NY"): the saved details' when the ZIP is
    /// theirs, else Apple's geocoder, once per ZIP.
    private func region(zip: String, details: BuyerDetails?) async -> String? {
        if let details, details.postalCode.trimmingCharacters(in: .whitespaces) == zip {
            let r = details.region.trimmingCharacters(in: .whitespaces)
            if !r.isEmpty { return r }
        }
        if let known = regions[zip] { return known }
        if UCPClient.stub { return "NY" }
        let found = try? await CLGeocoder().geocodeAddressString("\(zip), United States").first?.administrativeArea
        if let found { regions[zip] = found }
        return found
    }
}

/// Shipping priced by a store outside UCP, for an estimate only: nothing is
/// checked out and no address beyond the ZIP and state is sent.
enum StoreRates {
    /// Each quote runs in its own throwaway session, so a brand's cart cookie
    /// never reaches the shopper's real checkout.
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": AppChannel.userAgent, "Accept": "application/json"]
        return URLSession(configuration: config)
    }

    /// A Shopify store's own rates (the storefront cart's
    /// /cart/shipping_rates.json): the lines go in a fresh cart, then the
    /// cheapest rate to the ZIP. Nil when the store rates nothing or refuses.
    static func shopify(domain: String, lines: [CartLine], zip: String, state: String) async -> ShippingQuote? {
        if UCPClient.stub { return ShippingQuote(amountMinor: 700, currency: "USD", title: "Standard", estimate: nil) }
        guard let add = URL(string: "https://\(domain)/cart/add.js"),
              var comps = URLComponents(string: "https://\(domain)/cart/shipping_rates.json") else { return nil }
        let s = session()
        defer { s.invalidateAndCancel() }
        var request = URLRequest(url: add)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let items = lines.map { ["id": $0.variantID, "quantity": $0.quantity] as [String: Any] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["items": items])
        guard let (_, added) = try? await s.data(for: request), (added as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        comps.queryItems = [URLQueryItem(name: "shipping_address[zip]", value: zip),
                            URLQueryItem(name: "shipping_address[country]", value: "US"),
                            URLQueryItem(name: "shipping_address[province]", value: state)]
        guard let url = comps.url, let (data, response) = try? await s.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return shopifyRates(data)
    }

    /// The cheapest of a /cart/shipping_rates.json reply.
    static func shopifyRates(_ data: Data) -> ShippingQuote? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = top["shipping_rates"] as? [[String: Any]] else { return nil }
        let priced = rates.compactMap { r -> (Int, [String: Any])? in
            guard let text = r["price"] as? String, let p = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), p >= 0 else { return nil }
            return (NSDecimalNumber(decimal: p * 100).intValue, r)
        }
        guard let (minor, rate) = priced.min(by: { $0.0 < $1.0 }) else { return nil }
        let currency = (rate["currency"] as? String).flatMap { $0.count == 3 ? $0 : nil } ?? "USD"
        return ShippingQuote(amountMinor: minor, currency: currency, title: rate["name"] as? String, estimate: nil)
    }

    /// A Swell store's rating, through marracat.com (web/server/swell.js:
    /// only the server holds the store's key).
    static func swell(brandID: String, lines: [CartLine], zip: String) async -> ShippingQuote? {
        if UCPClient.stub { return ShippingQuote(amountMinor: 1699, currency: "USD", title: "Standard Shipping", estimate: nil) }
        var comps = URLComponents(string: "https://marracat.com/api/ship-quote/swell")
        comps?.queryItems = [URLQueryItem(name: "brand", value: brandID), URLQueryItem(name: "zip", value: zip),
                             URLQueryItem(name: "items", value: lines.map { "\($0.productID):\($0.variantID):\($0.quantity)" }.joined(separator: ","))]
        guard let url = comps?.url else { return nil }
        let s = session()
        defer { s.invalidateAndCancel() }
        guard let (data, response) = try? await s.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let q = top["quote"] as? [String: Any], let amount = q["amount"] as? Double, amount >= 0 else { return nil }
        return ShippingQuote(amountMinor: Int((amount * 100).rounded()), currency: (q["currency"] as? String) ?? "USD",
                             title: q["title"] as? String, estimate: nil)
    }
}

extension UCPLineRequest {
    /// A cart line as the store's checkout takes it, priced as it was added.
    @MainActor static func make(_ line: CartLine, catalog: CatalogStore) -> UCPLineRequest {
        let price = CartStore.unitPrice(line, catalog: catalog)
        return UCPLineRequest(variantID: line.variantID, quantity: line.quantity, unitPriceMinor: Int((price * 100).rounded()))
    }
}
