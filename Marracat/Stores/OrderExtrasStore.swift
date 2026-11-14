import Foundation

/// What Checkout Kit tells us about a placed order beyond the synced
/// CheckoutRecord: the price breakdown, each line's variant and price, where
/// it ships and how it was paid.
///
/// This stays on the phone. The synced profile (web/server/mobile.js) keeps a
/// whitelisted CheckoutRecord and never receives addresses or payment details,
/// so these live in their own store, keyed by brand and order id.
struct OrderExtras: Codable, Equatable {
    struct Line: Codable, Equatable {
        var title: String
        var quantity: Int
        var price: Double?
        var currency: String?
        /// Numeric Shopify variant id, from merchandiseId (gid://shopify/ProductVariant/123).
        var variantID: Int64?
        /// The option chosen, e.g. "Black / M"; nil for a one-option product.
        var option: String?
        var image: String?
    }
    struct ShipTo: Codable, Equatable {
        var name: String?
        var lines: [String]
    }
    var lines: [Line] = []
    var subtotal: Double?
    var shipping: Double?
    /// Discounts off the order, as a positive amount.
    var discounts: Double?
    var taxes: Double?
    var total: Double?
    var currency: String?
    var shipTo: ShipTo?
    var deliveryMethod: String?
    /// "Visa •••• 4242", or just the method's type when no digits were given.
    var payment: String?
    /// Where the brand sends its confirmation and shipping emails.
    var email: String?
}

final class OrderExtrasStore {
    static let shared = OrderExtrasStore()
    private let defaults: UserDefaults
    private let key = "orderExtras.v1"
    private var all: [String: OrderExtras]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: OrderExtras].self, from: $0) } ?? [:]
    }

    static func id(brandID: String, orderID: String) -> String { brandID + "|" + orderID }

    func extras(brandID: String, orderID: String?) -> OrderExtras? {
        guard let orderID else { return nil }
        return all[Self.id(brandID: brandID, orderID: orderID)]
    }

    func save(_ extras: OrderExtras, brandID: String, orderID: String) {
        all[Self.id(brandID: brandID, orderID: orderID)] = extras
        // The newest 200, like the order history itself.
        if all.count > 200 { all = Dictionary(uniqueKeysWithValues: all.suffix(200).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    func removeAll() { all = [:]; defaults.removeObject(forKey: key) }
}

/// Shopify's ids arrive as gids; people read the number at the end.
enum ShopifyIDs {
    /// "gid://shopify/OrderIdentity/8622093435066" → "8622093435066". A bare
    /// number passes through; anything else has no usable id.
    static func number(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let digits = last.split(separator: "?").first.map(String.init) ?? last
        return !digits.isEmpty && digits.allSatisfy(\.isNumber) && digits.count <= 20 ? digits : nil
    }

    /// "gid://shopify/ProductVariant/47248505634985" → 47248505634985.
    static func variant(_ raw: String?) -> Int64? { number(raw).flatMap { Int64($0) } }
}

extension OrderExtras {
    /// Money fields from Checkout Kit's completion event, flattened. The
    /// event types live in ShopifyCheckoutSheetKit; CheckoutFlow maps them.
    static func summarize(address: (name: String?, first: String?, last: String?, line1: String?, line2: String?,
                                    city: String?, zone: String?, postal: String?, country: String?)?) -> ShipTo? {
        guard let a = address else { return nil }
        let name = a.name ?? [a.first, a.last].compactMap { $0 }.joined(separator: " ")
        var lines: [String] = []
        if let l = a.line1, !l.isEmpty { lines.append(l) }
        if let l = a.line2, !l.isEmpty { lines.append(l) }
        let cityLine = [a.city, [a.zone, a.postal].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !cityLine.isEmpty { lines.append(cityLine) }
        if let c = a.country, !c.isEmpty, c != "US" { lines.append(c) }
        guard !lines.isEmpty else { return nil }
        return ShipTo(name: name.isEmpty ? nil : name, lines: lines)
    }

    /// "Visa •••• 4242" from a payment method's type and details.
    static func paymentLabel(type: String, details: [String: String?]) -> String {
        let flat = details.compactMapValues { $0 }
        let brand = flat["brand"] ?? flat["cardBrand"] ?? flat["card_brand"]
        let last4 = flat["last4"] ?? flat["lastDigits"] ?? flat["last_digits"]
        let name = (brand?.isEmpty == false ? brand! : readable(type))
        if let d = last4, !d.isEmpty, d.count <= 4, d.allSatisfy(\.isNumber) { return "\(name) •••• \(d)" }
        return name
    }

    private static func readable(_ type: String) -> String {
        switch type.lowercased() {
        case "creditcard", "credit_card", "card": return String(localized: "Card", comment: "Payment method")
        case "wallet", "applepay", "apple_pay": return "Apple Pay"
        case "shoppay", "shop_pay": return "Shop Pay"
        default: return type.isEmpty ? String(localized: "Paid at checkout", comment: "Payment method when the store gave none") : type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
