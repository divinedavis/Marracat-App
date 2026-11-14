import Foundation

/// Where an order shipped, as Checkout Kit reports it
/// (CheckoutCompletedEvent.Address); its own type so the details logic and
/// its tests don't depend on Checkout Kit.
struct OrderAddress: Equatable {
    var firstName: String?, lastName: String?, name: String?
    var address1: String?, address2: String?, city: String?
    var zoneCode: String?, postalCode: String?, countryCode: String?, phone: String?
}

/// What the shopper types once and every brand's checkout is filled from.
/// Kept on this phone only (BuyerStore); it goes to a brand's Shopify store
/// exactly when that brand's checkout is created, as it would at its own
/// checkout form.
struct BuyerDetails: Codable, Equatable {
    var firstName = ""
    var lastName = ""
    var email = ""
    var phone = ""
    var street = ""
    var extended = ""
    var city = ""
    var region = ""
    var postalCode = ""
    var country = "US"

    var isComplete: Bool {
        [firstName, lastName, street, city, region, postalCode, phone].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            && email.contains("@") && email.contains(".")
    }

    /// Blanks filled from what the signed-in account knows (name, email), so
    /// only phone and address are left to type (owner, 2026-10-03; the website
    /// does the same in web/src/buyer.js). Anything already typed wins.
    func filling(name: String?, email: String?) -> BuyerDetails {
        var d = self
        let parts = (name ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        if d.firstName.trimmingCharacters(in: .whitespaces).isEmpty, let first = parts.first { d.firstName = first }
        if d.lastName.trimmingCharacters(in: .whitespaces).isEmpty, parts.count > 1 { d.lastName = parts.dropFirst().joined(separator: " ") }
        if d.email.trimmingCharacters(in: .whitespaces).isEmpty, let email, email.contains("@"), email.contains(".") { d.email = email }
        return d
    }

    /// A US shipping address a store can price and ship to.
    var hasAddress: Bool {
        [street, city, region, postalCode].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty } && country == "US"
    }

    /// The shopper's details after an order: what the store's checkout
    /// shipped to fills in what Marracat didn't have, so the next brand's
    /// checkout opens with it (owner, 2026-11-02: the address is entered once,
    /// at the first store's checkout, not in a Marracat form first).
    /// Saved details that are already complete stay as they are: one gift
    /// sent elsewhere shouldn't move the shopper's own address. Only US
    /// addresses, as checkouts ship to the 50 states. The order's email is
    /// used only when there's none and it isn't Marracat's own order address.
    func filling(shippedTo a: OrderAddress?, orderEmail: String?, orderPhone: String?) -> BuyerDetails {
        guard !isComplete else { return self }
        var d = self
        func set(_ value: String?, _ key: WritableKeyPath<BuyerDetails, String>) {
            let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty, d[keyPath: key].trimmingCharacters(in: .whitespaces).isEmpty { d[keyPath: key] = v }
        }
        if let email = orderEmail, email.contains("@"), email.contains("."),
           !email.lowercased().hasSuffix("@orders.marracat.com") {
            set(email, \.email)
        }
        if let a, (a.countryCode ?? "US").uppercased() == "US", !(a.address1 ?? "").isEmpty, !(a.postalCode ?? "").isEmpty {
            d.street = a.address1 ?? ""
            d.extended = a.address2 ?? ""
            d.city = a.city ?? ""
            d.region = a.zoneCode ?? ""
            d.postalCode = a.postalCode ?? ""
            d.country = "US"
            set(a.firstName, \.firstName)
            set(a.lastName, \.lastName)
            if d.firstName.isEmpty, let name = a.name {
                let parts = name.split(whereSeparator: \.isWhitespace).map(String.init)
                set(parts.first, \.firstName)
                set(parts.dropFirst().joined(separator: " "), \.lastName)
            }
            set(a.phone, \.phone)
        }
        set(orderPhone, \.phone)
        return d
    }

    var oneLineAddress: String {
        [street, extended.isEmpty ? nil : extended, "\(city), \(region) \(postalCode)"].compactMap { $0 }.joined(separator: ", ")
    }
}

/// One brand's checkout as its Shopify store describes it over the Universal
/// Commerce Protocol (ucp.dev): prices in minor units, what's still missing,
/// and the URL that opens this exact checkout, already filled in.
struct UCPCheckout: Decodable {
    enum Status: String, Decodable {
        case incomplete, requiresEscalation = "requires_escalation", readyForComplete = "ready_for_complete",
             completeInProgress = "complete_in_progress", completed, canceled, unknown
        init(from decoder: Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    struct Total: Decodable { let type: String; let amount: Int; let displayText: String? }
    struct Message: Decodable { let type: String; let code: String?; let content: String?; let severity: String?; var path: String? = nil }
    struct LineItem: Decodable {
        struct Item: Decodable { let id: String; let title: String?; let price: Int?; let imageUrl: String? }
        let id: String; let item: Item; let quantity: Int
    }
    /// The fulfillment extension's shapes (ucp.dev/2026-08-25/specification/
    /// shopping/extensions/fulfillment): methods → groups → options, the
    /// buyer's choice being each group's `selected_option_id`.
    struct Fulfillment: Decodable {
        struct Description: Decodable { let plain: String? }
        struct Option: Decodable {
            let id: String; let title: String?; let totals: [Total]?
            /// "Supplementary context for the title (e.g. 'Arrives in 4 business days')".
            var description: Description? = nil
            var carrier: String? = nil
            /// "Earliest / Latest fulfillment date" — no store sends them yet (10/13).
            var earliestFulfillmentTime: String? = nil
            var latestFulfillmentTime: String? = nil
            /// What this option costs, in minor units.
            var price: Int? { totals?.first { $0.type == "total" }?.amount ?? totals?.first?.amount }
        }
        struct Group: Decodable { let id: String; var lineItemIds: [String]? = nil; let selectedOptionId: String?; let options: [Option]? }
        /// A shipping destination as the store echoes it back, with its id.
        struct Destination: Codable, Equatable {
            var id: String?; var type: String?
            var firstName: String?; var lastName: String?; var streetAddress: String?; var extendedAddress: String?
            var addressLocality: String?; var addressRegion: String?; var postalCode: String?; var addressCountry: String?
            var phoneNumber: String?
        }
        struct Method: Decodable {
            let id: String; let type: String; let groups: [Group]?
            var lineItemIds: [String]? = nil
            var selectedDestinationId: String? = nil
            var destinations: [Destination]? = nil
        }
        let methods: [Method]?
    }

    /// A group the shopper can choose a delivery speed for, with the option
    /// the store has selected now.
    struct ShippingChoice {
        let methodID: String
        let groupID: String
        let options: [Fulfillment.Option]
        let selectedID: String?
        var selected: Fulfillment.Option? { options.first { $0.id == selectedID } ?? options.first }
    }

    let id: String
    let status: Status
    let currency: String?
    let continueUrl: String?
    let expiresAt: String?
    let totals: [Total]?
    let messages: [Message]?
    let lineItems: [LineItem]?
    let fulfillment: Fulfillment?

    var continueURL: URL? { continueUrl.flatMap(URL.init) }
    func amount(_ type: String) -> Int? { totals?.first { $0.type == type }?.amount }
    var total: Int? { amount("total") }
    var shipping: Int? { amount("fulfillment") }
    /// The delivery option the store picked for this address, e.g. "UPS® Ground".
    var shippingOption: String? { shippingChoices.first?.selected?.title }
    /// Every group's options, in the store's order (the spec asks platforms to
    /// keep it). Without `supports_multi_group` in our profile a store sends
    /// one group per method, so for Shopify this is one entry.
    var shippingChoices: [ShippingChoice] {
        (fulfillment?.methods ?? []).flatMap { m in
            (m.groups ?? []).compactMap { g in
                guard let options = g.options, !options.isEmpty else { return nil }
                return ShippingChoice(methodID: m.id, groupID: g.id, options: options, selectedID: g.selectedOptionId)
            }
        }
    }
    func selectedOptionID(group: String) -> String? {
        fulfillment?.methods?.flatMap { $0.groups ?? [] }.first { $0.id == group }?.selectedOptionId
    }
    /// Something the store needs from the shopper that the app couldn't supply.
    var blockers: [Message] {
        (messages ?? []).filter { $0.type == "error" }
    }
    var needsAttention: Bool {
        status == .requiresEscalation || status == .canceled || status == .unknown || !blockers.isEmpty
    }
}

enum UCPError: LocalizedError {
    case transport(String)
    case rpc(code: Int, message: String)
    case noCheckout

    var errorDescription: String? {
        switch self {
        case .transport(let s): return s
        case .rpc(_, let m): return m
        case .noCheckout: return String(localized: "The store didn't return a checkout.", comment: "Checkout error from the store")
        }
    }
}

/// A line the shopper wants, with what the app already knows about it: the
/// stand-in checkout (UI tests, -CHECKOUT_STUB) prices from it.
struct UCPLineRequest {
    let variantID: Int64
    let quantity: Int
    let unitPriceMinor: Int
}

/// Talks JSON-RPC to a store's UCP endpoint (`https://<shop>/api/ucp/mcp`).
/// Anonymous tier: any store answers cart and checkout tools without a key,
/// so the phone calls the store directly and nothing passes through
/// marracat.com. Completing a checkout by API and Shop Pay tokens need
/// permissions Shopify grants case by case; until then the shopper pays on the
/// store's own checkout page, opened at `continue_url`.
struct UCPClient {
    static let profileURL = "https://marracat.com/.well-known/ucp"
    static let stub = ProcessInfo.processInfo.arguments.contains("-CHECKOUT_STUB")
    var session: URLSession = .shared

    func createCheckout(endpoint: URL, currency: String, lines: [UCPLineRequest], buyer: BuyerDetails) async throws -> UCPCheckout {
        if Self.stub { return Self.stubCheckout(endpoint: endpoint, currency: currency, lines: lines) }
        let body = Self.createBody(currency: currency, lines: lines, buyer: buyer)
        return try await call(endpoint: endpoint, method: "create_checkout", arguments: body)
    }

    /// The bag's standard-shipping quote: a checkout created with only the
    /// items and a ZIP, read for its cheapest delivery option. Shopify stores
    /// price delivery from postal code + country alone (verified live
    /// 2026-10-14, Brown Girl Jane: Standard Mail $8 / USPS Priority $15 to
    /// 11201, with "Enter a first name" etc. as messages); a country without
    /// a ZIP gets no options. No name, street, email or phone is sent.
    func quoteShipping(endpoint: URL, currency: String, lines: [UCPLineRequest], postalCode: String, country: String = "US") async throws -> ShippingQuote? {
        if Self.stub { return ShippingQuote.standard(from: Self.stubCheckout(endpoint: endpoint, currency: currency, lines: lines), currency: currency) }
        let c = try await call(endpoint: endpoint, method: "create_checkout",
                               arguments: Self.quoteBody(currency: currency, lines: lines, postalCode: postalCode, country: country))
        return ShippingQuote.standard(from: c, currency: currency)
    }

    static func quoteBody(currency: String, lines: [UCPLineRequest], postalCode: String, country: String) -> [String: Any] {
        ["checkout": [
            "currency": currency,
            "line_items": lines.map { ["quantity": $0.quantity, "item": ["id": "gid://shopify/ProductVariant/\($0.variantID)"]] },
            "fulfillment": ["methods": [["type": "shipping", "line_item_ids": [],
                                         "destinations": [["postal_code": postalCode, "address_country": country]]]]],
        ]]
    }

    func getCheckout(endpoint: URL, id: String) async throws -> UCPCheckout {
        try await call(endpoint: endpoint, method: "get_checkout", arguments: ["id": id])
    }

    /// The `create_checkout` arguments minus `meta`, which `call` adds.
    ///
    /// Whatever the shopper has given goes in, and blanks stay out. Without a
    /// saved address there's no destination: the store's own checkout asks
    /// for it, where Shop Pay or Apple Pay fill it in one tap (owner,
    /// 2026-11-02, from a creator who typed her address in Marracat and then
    /// again at Shop Pay). A store still returns a `continue_url` for a
    /// checkout with no address or contact, as status "incomplete" (checked
    /// live on Styl Charm, 2026-11-02).
    static func createBody(currency: String, lines: [UCPLineRequest], buyer: BuyerDetails) -> [String: Any] {
        func given(_ pairs: [(String, String)]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in pairs {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out[k] = t }
            }
            return out
        }
        var checkout: [String: Any] = [
            "currency": currency,
            "line_items": lines.map { ["quantity": $0.quantity, "item": ["id": "gid://shopify/ProductVariant/\($0.variantID)"]] },
            // The same tag the cart permalinks carry, so the brand sees where the order came from.
            "attribution": ["referring_domain": "marracat.com", "utm_source": CartStore.referral, "utm_medium": "app"],
        ]
        let person = given([("email", buyer.email.contains("@") ? buyer.email : ""), ("first_name", buyer.firstName),
                            ("last_name", buyer.lastName), ("phone_number", buyer.phone)])
        if !person.isEmpty { checkout["buyer"] = person }
        if buyer.hasAddress {
            var destination = given([("first_name", buyer.firstName), ("last_name", buyer.lastName), ("street_address", buyer.street),
                                     ("extended_address", buyer.extended), ("address_locality", buyer.city), ("address_region", buyer.region),
                                     ("postal_code", buyer.postalCode), ("phone_number", buyer.phone)])
            destination["address_country"] = buyer.country
            checkout["fulfillment"] = ["methods": [["type": "shipping", "line_item_ids": [], "destinations": [destination]]]]
        }
        return ["checkout": checkout]
    }

    private func call(endpoint: URL, method: String, arguments: [String: Any]) async throws -> UCPCheckout {
        var args = arguments
        args["meta"] = ["ucp-agent": ["profile": Self.profileURL]]
        let rpc: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": method, "arguments": args]]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: rpc)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UCPError.transport(String(localized: "No response from the store.", comment: "Checkout error from the store")) }
        guard (200..<300).contains(http.statusCode) else { throw UCPError.transport(String(localized: "The store answered HTTP \(http.statusCode).", comment: "Checkout error from the store")) }
        return try Self.parse(data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
    }

    /// The checkout inside a JSON-RPC reply. Shopify puts it in
    /// `result.structuredContent` next to a `ucp` negotiation envelope, and
    /// flags `isError` even for a checkout that merely needs a phone number —
    /// so a checkout with an id wins over the flag.
    static func parse(_ data: Data, contentType: String = "application/json") throws -> UCPCheckout {
        var payload = data
        if contentType.contains("text/event-stream") {
            // Streamable HTTP may frame the one reply as SSE: take the last data line.
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            guard let last = lines.last else { throw UCPError.transport(String(localized: "Empty reply from the store.", comment: "Checkout error from the store")) }
            payload = Data(last.utf8)
        }
        guard let top = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw UCPError.noCheckout }
        if let err = top["error"] as? [String: Any] {
            let detail = (err["data"] as? [String: Any])?["content"] as? String
            throw UCPError.rpc(code: err["code"] as? Int ?? -1, message: detail ?? err["message"] as? String ?? String(localized: "The store refused the request.", comment: "Checkout error from the store"))
        }
        guard let result = top["result"] as? [String: Any],
              var checkout = result["structuredContent"] as? [String: Any], checkout["id"] is String else {
            if let content = (top["result"] as? [String: Any])?["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String { throw UCPError.transport(String(text.prefix(200))) }
            throw UCPError.noCheckout
        }
        checkout["ucp"] = nil
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UCPCheckout.self, from: JSONSerialization.data(withJSONObject: checkout))
    }

    /// A checkout the way a store would answer, without a store: UI tests run
    /// the whole flow on it. Two delivery speeds worded the way Shopify stores
    /// word them (live replies, 2026-10-13): Standard $5 "3 to 5 business
    /// days" (selected unless `selected` says otherwise) and Express $15
    /// "1 to 2 business days". Ready to pay.
    static func stubCheckout(endpoint: URL, currency: String, lines: [UCPLineRequest], selected: String = "o1") -> UCPCheckout {
        let subtotal = lines.reduce(0) { $0 + $1.unitPriceMinor * $1.quantity }
        let shipping = selected == "o2" ? 1500 : 500
        let lineIDs = lines.map { "line-\($0.variantID)" }
        let json: [String: Any] = [
            "id": "gid://shopify/Checkout/stub-\(endpoint.host ?? "store")", "status": "ready_for_complete", "currency": currency,
            "continue_url": "https://marracat.com/#/stub-checkout/\(endpoint.host ?? "store")/\(selected)", "expires_at": "2099-01-01T00:00:00Z",
            "totals": [["type": "subtotal", "amount": subtotal], ["type": "fulfillment", "amount": shipping], ["type": "total", "amount": subtotal + shipping]],
            "messages": [],
            "line_items": lines.map { ["id": "line-\($0.variantID)", "quantity": $0.quantity,
                                        "item": ["id": "gid://shopify/ProductVariant/\($0.variantID)", "price": $0.unitPriceMinor]] },
            "fulfillment": ["methods": [["id": "shipping", "type": "shipping", "line_item_ids": lineIDs, "selected_destination_id": "d1",
                                        "destinations": [["id": "d1", "type": "shipping_address", "address_country": "US"]],
                                        "groups": [["id": "g1", "line_item_ids": lineIDs, "selected_option_id": selected,
                                        "options": [["id": "o1", "title": "Standard", "description": ["plain": "3 to 5 business days"],
                                                     "totals": [["type": "total", "amount": 500]]],
                                                    ["id": "o2", "title": "Express", "description": ["plain": "1 to 2 business days"],
                                                     "totals": [["type": "total", "amount": 1500]]]]]]]]],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try! decoder.decode(UCPCheckout.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

extension String {
    /// nil for an empty or all-space string, for `??` defaults.
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

extension UCPClient {
    /// A brand's checkout built over UCP from whatever the shopper has given:
    /// saved details, else the account's name and email, else nothing. The
    /// store's own checkout asks for anything missing, where Shop Pay or
    /// Apple Pay fill it in (owner, 2026-11-02: no Marracat details form
    /// before checkout). The order email is Marracat's order address when
    /// it's on, so the order is followed to "Delivered". nil when the brand
    /// has no UCP or its store doesn't answer; the caller falls back to the
    /// cart link.
    @MainActor static func buildCheckout(brand: Brand, lines: [UCPLineRequest], saved: BuyerDetails?,
                                         accountName: String?, accountEmail: String?) async -> UCPCheckout? {
        guard let endpoint = brand.ucpEndpoint else { return nil }
        var details = (saved ?? BuyerDetails()).filling(name: accountName, email: accountEmail)
        let relay = RelayStore.shared
        if relay.enabled, let address = await relay.prepare(forwardTo: details.email, deviceKey: RestockStore.installKey) {
            details.email = address
        }
        guard let c = try? await UCPClient().createCheckout(endpoint: endpoint, currency: brand.currencyCode, lines: lines, buyer: details),
              c.continueURL != nil else { return nil }
        return c
    }
}
