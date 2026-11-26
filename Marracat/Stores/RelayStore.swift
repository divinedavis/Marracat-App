import Foundation
import Observation

/// The Marracat order email (web/server/relay.js): a private
/// u-…@orders.marracat.com address that goes to a brand's checkout instead of
/// the shopper's own email. The brand's order and shipping emails reach the
/// server, which forwards them to the shopper and reads the order number and
/// tracking out of them; this store fetches those readings for Your Orders.
///
/// Behind a server flag: while it's off for an account, `address` stays nil
/// and every checkout gets the shopper's own email, exactly as before.
///
/// Signed out (owner, 2026-10-13), the install gets an address of its own,
/// keyed to its device key (/api/relay/guest): the same prefill on UCP
/// checkouts and cart links, the emails read into Your Orders and pushed to
/// this phone, but nothing forwarded (there's no inbox). Signing in merges
/// it into the account, which keeps one address.
///
/// Everything that changes the store runs on the main thread (`@MainActor`
/// on each async method). They used to run wherever Swift put them, and the
/// app asks for a refresh from two places as it opens: two background
/// threads set `address` at the same moment and the app crashed
/// (2026-11-26, build 201, in the ship's own speed test).
@Observable
final class RelayStore {
    static let shared = RelayStore()

    private(set) var enabled = false
    private(set) var address: String?
    /// Where the server forwards the brands' emails (nil for a guest).
    private(set) var forwardTo: String?
    /// The address belongs to this install, not an account: merged into the
    /// account on the next refresh after signing in.
    private(set) var guest = false
    private(set) var events: [RelayEvent] = []
    /// An order-email notification that was tapped, waiting to open its order.
    var openRequest: OrderEventRequest?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var account: AccountStore?
    /// Tests hand in a session that answers by itself and say the server may
    /// be reached; the app never passes either.
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let reachesServerOverride: Bool?
    private var reachesServer: Bool { reachesServerOverride ?? AppChannel.reachesOrderServer }
    private static let cacheKey = "relay.cache.v1"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared, reachesServer: Bool? = nil) {
        self.defaults = defaults
        self.session = session
        self.reachesServerOverride = reachesServer
        if let data = defaults.data(forKey: Self.cacheKey), let c = try? JSONDecoder().decode(Cache.self, from: data) {
            enabled = c.enabled; address = c.address; forwardTo = c.forwardTo; events = c.events; guest = c.guest ?? false
        }
        if ProcessInfo.processInfo.arguments.contains("-RELAY_STUB") { stub() }
    }

    func attach(_ account: AccountStore) { self.account = account }

    /// The email a brand's checkout should get for this shopper.
    func checkoutEmail(realEmail: String) -> String {
        enabled ? (address ?? realEmail) : realEmail
    }

    /// Whether an order was placed with the relay address.
    static func isRelay(_ email: String?) -> Bool {
        email?.lowercased().hasSuffix("@orders.marracat.com") == true
    }

    /// Asks the server whether this account (or, signed out, this install)
    /// has the order email, and the order events it has read since. Just
    /// signed in on a phone that had a guest address: merges it first.
    @MainActor
    func refresh() async {
        guard let account, reachesServer else { return }
        guard account.signedIn else { return await refreshGuest() }
        if guest {
            // The server takes this phone's guest address only into the
            // account signed in on it, and only with this phone's own key.
            let key = RestockStore.installKey
            if let (status, _) = try? await account.mobile("relay", method: "PUT", body: Data("{}".utf8), deviceKey: key),
               (200..<500).contains(status) {
                guest = false
            }
        }
        if let (status, data) = try? await account.mobile("relay"), status == 200,
           let state = try? JSONDecoder().decode(State.self, from: data) {
            enabled = state.enabled
            address = state.enabled ? state.address : nil
            forwardTo = state.enabled ? state.forwardTo : nil
        }
        if let (status, data) = try? await account.mobile("relay/events"), status == 200,
           let r = try? JSONDecoder().decode(EventsReply.self, from: data) {
            events = r.events
        }
        save()
    }

    @MainActor
    private func refreshGuest() async {
        if let (status, data) = await guestCall(), status == 200, let state = try? JSONDecoder().decode(State.self, from: data) {
            enabled = state.enabled
            address = state.enabled ? state.address : nil
            forwardTo = nil
            guest = address != nil
        }
        if enabled, let (status, data) = await guestCall("/events"), status == 200,
           let r = try? JSONDecoder().decode(EventsReply.self, from: data) {
            events = r.events
        }
        save()
    }

    /// Makes sure the address exists. Signed in, it forwards to the account's
    /// own sign-in email (the server ignores `forwardTo`); signed out, it's
    /// this install's. Returns the address, or nil when the order email is off.
    @MainActor @discardableResult
    func prepare(forwardTo: String, deviceKey: String?) async -> String? {
        guard enabled, let account, reachesServer else { return address }
        guard account.signedIn else {
            if let (status, data) = await guestCall(method: "PUT"), status == 200,
               let state = try? JSONDecoder().decode(State.self, from: data) {
                enabled = state.enabled
                address = state.address ?? address
                self.forwardTo = nil
                guest = address != nil
                save()
            }
            return address
        }
        guard forwardTo.contains("@"), !Self.isRelay(forwardTo) else { return address }
        let body = try? JSONSerialization.data(withJSONObject: ["forwardTo": forwardTo])
        if let (status, data) = try? await account.mobile("relay", method: "PUT", body: body, deviceKey: deviceKey), status == 200,
           let state = try? JSONDecoder().decode(State.self, from: data) {
            enabled = state.enabled
            address = state.address ?? address
            self.forwardTo = state.forwardTo ?? forwardTo
            guest = false
            save()
        }
        return address
    }

    /// Before a cart link opens (it's built synchronously): the address, if
    /// the order email is on and there isn't one yet.
    @MainActor
    func ensureAddress() async {
        guard enabled, address == nil, let account else { return }
        let email = account.user?.email ?? ""
        let key = RestockStore.installKey
        await prepare(forwardTo: email, deviceKey: key)
    }

    /// Lets the server reach this phone with order updates once the shopper
    /// has allowed notifications.
    @MainActor
    func linkDevice(_ deviceKey: String) async {
        guard let forwardTo else { return }
        await prepare(forwardTo: forwardTo, deviceKey: deviceKey)
    }

    /// A call to the guest order email, as this install.
    @MainActor
    private func guestCall(_ path: String = "", method: String = "GET") async -> (Int, Data)? {
        guard reachesServer else { return nil }
        let key = RestockStore.installKey
        var request = URLRequest(url: URL(string: "https://marracat.com/api/relay/guest" + path)!)
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(key, forHTTPHeaderField: "X-Marracat-Device")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The events that belong to one order: the brand's emails received after
    /// it was placed and before that brand's next order, narrowed to its order
    /// number once a confirmation names it. Brands write one number several
    /// ways ("#11906" confirmed, "#KOBA-11906" shipped), so numbers compare by
    /// `orderKey`; a number an earlier order of the brand already claimed is
    /// never this one's (two KOBA orders a minute apart, 2026-10-08).
    func events(for record: CheckoutRecord, brand: Brand?, allOrders: [CheckoutRecord]) -> [RelayEvent] {
        let mine = events.filter { Self.sameBrand($0, brand: brand) }
        guard !mine.isEmpty else { return [] }
        let orders = allOrders.filter { $0.brandID == record.brandID }.sorted { $0.date < $1.date }
        var claimed = Set<String>()
        for (i, order) in orders.enumerated() {
            let start = max(order.date.addingTimeInterval(-3600), i > 0 ? orders[i - 1].date : .distantPast)
            let next = i + 1 < orders.count ? orders[i + 1].date : .distantFuture
            let window = mine.filter { $0.date >= start && $0.date < next }
            let open = { (e: RelayEvent) in e.orderName.map(Self.orderKey).map { !claimed.contains($0) } ?? false }
            let byDate = window.sorted { $0.date < $1.date }
            let name = (byDate.first { $0.kind == "confirmation" && open($0) } ?? byDate.first(where: open))?.orderName.map(Self.orderKey)
            if order.id == record.id {
                guard let name else { return window.filter { $0.orderName == nil || open($0) } }
                return mine.filter { $0.orderName.map(Self.orderKey) == name || ($0.orderName == nil && window.contains($0)) }
            }
            if let name { claimed.insert(name) }
        }
        return []
    }

    /// One order number however the brand wrote it: "#KOBA-11906", "11906"
    /// and "#11906" are all "11906".
    static func orderKey(_ name: String) -> String {
        let s = name.lowercased().replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
        if let dash = s.lastIndex(of: "-"), s[..<dash].allSatisfy(\.isLetter), !s[s.index(after: dash)...].isEmpty {
            return String(s[s.index(after: dash)...])
        }
        return s
    }

    /// The order an order-email notification is about (relay.js `orderEvent`):
    /// the brand's order whose events carry that number, else its latest.
    func record(brandDomain: String, orderName: String?, brands: [Brand], orders: [CheckoutRecord]) -> CheckoutRecord? {
        let event = RelayEvent(id: 0, received: 0, kind: "other", brandName: nil, brandDomain: brandDomain, orderName: nil)
        guard let brand = brands.first(where: { Self.sameBrand(event, brand: $0) }) else { return nil }
        let theirs = orders.filter { $0.brandID == brand.id }.sorted { $0.date > $1.date }
        if let orderName {
            let key = Self.orderKey(orderName)
            if let hit = theirs.first(where: { r in events(for: r, brand: brand, allOrders: orders).contains { $0.orderName.map(Self.orderKey) == key } }) {
                return hit
            }
        }
        return theirs.first
    }

    /// What each order held, by the order number its brand emails use, for
    /// the server to name in pushes (relay.js setItems): "Your Keep It Together
    /// Headband from KOBA skincare arrives today." Orders already sent are skipped.
    func itemNames(orders: [CheckoutRecord], brand: (String) -> Brand?, titles: (CheckoutRecord) -> [String],
                   alreadySent: Set<String>) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for record in orders {
            guard let b = brand(record.brandID), let first = titles(record).first else { continue }
            let named = events(for: record, brand: b, allOrders: orders).compactMap { e in
                e.orderName.map { (name: $0, domain: e.brandDomain ?? b.domain) } }
            guard let hit = named.first else { continue }
            let key = "\(hit.domain)|\(Self.orderKey(hit.name))"
            guard !alreadySent.contains(key) else { continue }
            out.append(["brandDomain": hit.domain, "orderName": hit.name, "itemTitle": String(first.prefix(200)),
                        "itemCount": min(max(titles(record).count, 1), 999), "key": key])
        }
        return out
    }

    /// Sends `itemNames` once per order; remembers what the server took.
    @MainActor
    func syncItemNames(orders: [CheckoutRecord], brand: (String) -> Brand?, titles: (CheckoutRecord) -> [String]) async {
        guard let account, reachesServer, account.signedIn else { return }
        let sentListName = "relay.itemsSent.v1"
        let sent = Set(defaults.stringArray(forKey: sentListName) ?? [])
        let batch = Array(itemNames(orders: orders, brand: brand, titles: titles, alreadySent: sent).prefix(50))
        guard !batch.isEmpty else { return }
        let body = try? JSONSerialization.data(withJSONObject: ["orders": batch.map { $0.filter { $0.key != "key" } }])
        guard let (status, _) = try? await account.mobile("relay/items", method: "PUT", body: body), status == 200 else { return }
        defaults.set(Array(sent.union(batch.compactMap { $0["key"] as? String })), forKey: sentListName)
    }

    static func sameBrand(_ event: RelayEvent, brand: Brand?) -> Bool {
        guard let brand else { return false }
        let strip = { (d: String) in d.lowercased().replacingOccurrences(of: "www.", with: "") }
        if let d = event.brandDomain.map(strip) {
            let b = strip(brand.domain)
            return d == b || d.hasSuffix("." + b) || b.hasSuffix("." + d)
        }
        if let n = event.brandName?.lowercased() { return n == brand.name.lowercased() }
        return false
    }

    /// How far an order has got: 0 ordered, 1 shipped, 2 out for delivery, 3 delivered.
    static func step(_ events: [RelayEvent]) -> Int {
        events.reduce(0) { best, e in
            max(best, stepIndex(e.kind), stepIndex(e.trackingStep ?? ""))
        }
    }
    private static func stepIndex(_ kind: String) -> Int {
        switch kind { case "shipped": 1; case "out_for_delivery": 2; case "delivered": 3; default: 0 }
    }

    // MARK: Storage

    private struct State: Decodable { let enabled: Bool; let address: String?; let forwardTo: String? }
    private struct EventsReply: Decodable { let events: [RelayEvent] }
    private struct Cache: Codable { var enabled: Bool; var address: String?; var forwardTo: String?; var events: [RelayEvent]; var guest: Bool? }

    private func save() {
        defaults.set(try? JSONEncoder().encode(Cache(enabled: enabled, address: address, forwardTo: forwardTo, events: events, guest: guest)), forKey: Self.cacheKey)
    }

    /// Signing out or deleting the account forgets the address and events.
    func clear() {
        enabled = false; address = nil; forwardTo = nil; events = []; guest = false
        defaults.removeObject(forKey: Self.cacheKey)
    }

    /// UI tests: an account with the order email and a shipped order.
    private func stub() {
        enabled = true
        address = "u-test2k7m9q@orders.marracat.com"
    }
    func stubEvents(_ list: [RelayEvent]) { events = list }
    func stubOrderEmails(brand: Brand) {
        guard ProcessInfo.processInfo.arguments.contains("-RELAY_STUB") else { return }
        let now = Date().timeIntervalSince1970 * 1000 + 1000
        events = [
            RelayEvent(id: 2, received: now + 1000, kind: "shipped", brandName: brand.name, brandDomain: brand.domain,
                       orderName: "#1042", carrier: "USPS", trackingNumber: "9400111899223197428490", trackingStatus: "in_transit", trackingStep: "shipped"),
            RelayEvent(id: 1, received: now, kind: "confirmation", brandName: brand.name, brandDomain: brand.domain, orderName: "#1042"),
        ] + events
    }
}

/// One brand email the server read: which order, what happened, tracking.
/// Which order a tapped order-email notification is about (relay.js `orderEvent`).
struct OrderEventRequest: Equatable {
    let brandDomain: String
    let orderName: String?
}

struct RelayEvent: Codable, Equatable, Identifiable {
    let id: Int
    let received: Double
    let kind: String
    var brandName: String?
    var brandDomain: String?
    var orderName: String?
    var carrier: String?
    var trackingNumber: String?
    var trackingStatus: String?
    var trackingStep: String?
    /// The carrier's own last message (relay.js), for a problem's explanation.
    var trackingDetail: String?
    /// The carrier's expected delivery day ("2026-10-09").
    var estDelivery: String?

    var date: Date { Date(timeIntervalSince1970: received / 1000) }
}
