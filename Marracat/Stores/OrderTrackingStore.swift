import Foundation
import Observation
import os

/// Delivery tracking that survives Apple Pay (web/server/order-tracking.js).
///
/// Apple Pay and Shop Pay give the brand the wallet's email, so the Marracat
/// order email (RelayStore) never hears about those orders. What the app does
/// hold is the UCP checkout it built on the review screen: when Checkout Kit
/// reports that checkout paid, its id goes to the server, which asks the store
/// for the order's status page and follows it to "Delivered", pushing each
/// step. This store sends the id and reads the progress back.
///
/// Keyed by the same per-install device key as restock alerts, so it works
/// signed out; the push token is the one those alerts registered.
@MainActor
@Observable
final class OrderTrackingStore {
    static let shared = OrderTrackingStore()

    private(set) var orders: [TrackedOrder] = []
    /// An order whose tracking notification was tapped, waiting to open.
    var openRequest: TrackedOrderRequest?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let stubbed = ProcessInfo.processInfo.arguments.contains("-CHECKOUT_STUB")
    @ObservationIgnored private let log = Logger(subsystem: "com.divinedavis.marracat", category: "tracking")
    private static let cacheKey = "orderTracking.v1"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        if let data = defaults.data(forKey: Self.cacheKey), let saved = try? JSONDecoder().decode([TrackedOrder].self, from: data) {
            orders = saved
        }
    }

    /// A paid Shopify checkout, whichever button paid (owner, 2026-10-13).
    /// `checkoutID` is the UCP checkout the review built, when there is one;
    /// without it the order is keyed by `orderID`, Checkout Kit's
    /// (gid://shopify/OrderIdentity/…), which is also how Your Orders finds it.
    /// `items` name the push: "KOBA skincare shipped your Keep It Together Headband".
    func register(brandID: String, checkoutID: String?, orderID: String?, items: [String] = []) async {
        guard let checkoutID = checkoutID ?? orderID else { return }
        if stubbed {
            // UI tests: what the server reports right after payment, or, with
            // -TRACKING_SHIPPED, once the brand has shipped it (and with
            // -TRACKING_DELIVERED too, once it has arrived).
            let shipped = ProcessInfo.processInfo.arguments.contains("-TRACKING_SHIPPED")
            let delivered = ProcessInfo.processInfo.arguments.contains("-TRACKING_DELIVERED")
            let problem = ProcessInfo.processInfo.arguments.contains("-TRACKING_PROBLEM")
            orders.insert(TrackedOrder(brandID: brandID, checkoutID: checkoutID, orderID: orderID,
                                       permalink: "https://marracat.com/#/stub-order-status", state: delivered ? "delivered" : shipped ? "shipped" : "confirmed",
                                       carrier: shipped ? "USPS" : nil,
                                       trackingNumber: shipped ? "9400111899223197428490" : nil, trackingURL: nil,
                                       created: Date().timeIntervalSince1970 * 1000, updated: Date().timeIntervalSince1970 * 1000,
                                       // -TRACKING_PROBLEM: the carrier then failed to deliver it.
                                       trackingStatus: problem ? "failure" : nil,
                                       trackingDetail: problem ? "Delivery attempted - no access to delivery location" : nil), at: 0)
            save()
            return
        }
        var body: [String: Any] = ["brandID": brandID]
        if checkoutID != orderID { body["checkoutID"] = checkoutID }
        if let orderID { body["orderID"] = orderID }
        if let first = items.first { body["itemTitle"] = String(first.prefix(200)); body["itemCount"] = min(items.count, 999) }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let (status, reply) = try? await call(method: "POST", body: data) else {
            log.error("tracking: couldn't reach the server for \(brandID, privacy: .public)")
            return
        }
        if status == 201 { apply(reply) }
        log.info("tracking: registered \(brandID, privacy: .public) order, HTTP \(status)")
    }

    /// Shopify orders on this phone from the last 30 days the server doesn't
    /// follow yet: an order placed before every order was registered (RIPL
    /// EFEK #1417, 2026-10-10), or one whose registration never reached the
    /// server. Each is tried once a launch at most.
    static func unregistered(_ records: [CheckoutRecord], tracked: [TrackedOrder], now: Date = .now) -> [CheckoutRecord] {
        let known = Set(tracked.compactMap { $0.orderID.flatMap(number) })
        return records.filter { r in
            guard let id = r.orderID, id.hasPrefix("gid://shopify/"), let n = number(id) else { return false }
            return !known.contains(n) && now.timeIntervalSince(r.date) < 30 * 86_400
        }
    }

    @ObservationIgnored private var triedThisLaunch = Set<String>()

    func registerMissing(orders records: [CheckoutRecord], titles: (CheckoutRecord) -> [String]) async {
        guard !stubbed else { return }
        let missing = Self.unregistered(records, tracked: orders).filter { !triedThisLaunch.contains($0.orderID ?? "") }
        guard !missing.isEmpty else { return }
        // What the server already follows first, so nothing registers twice.
        if let (status, data) = try? await call(), status == 200 { apply(data) }
        for r in Self.unregistered(missing, tracked: orders) {
            triedThisLaunch.insert(r.orderID ?? "")
            await register(brandID: r.brandID, checkoutID: nil, orderID: r.orderID, items: titles(r))
        }
    }

    func refresh() async {
        guard !stubbed, !orders.isEmpty, let (status, data) = try? await call(), status == 200 else { return }
        apply(data)
    }

    /// The tracked order behind one of Your Orders. Checkout Kit names it
    /// OrderIdentity, the store Order; the number is the same.
    func tracked(for record: CheckoutRecord) -> TrackedOrder? {
        guard let id = record.orderID.flatMap(Self.number) else { return nil }
        return orders.first { $0.brandID == record.brandID && $0.orderID.flatMap(Self.number) == id }
    }

    /// The tracker steps it has reached, in RelayEvent form so Your Orders
    /// reads them exactly like the order email's.
    func events(for record: CheckoutRecord) -> [RelayEvent] {
        guard let t = tracked(for: record), let state = t.state, ["shipped", "out_for_delivery", "delivered"].contains(state) else { return [] }
        return [RelayEvent(id: -Int(t.created / 1000), received: t.updated ?? t.created, kind: state,
                           carrier: t.carrier, trackingNumber: t.trackingNumber)]
    }

    /// Names the items of tracked orders registered before the app sent them
    /// (order-tracking.js PATCH /items), once per order.
    func syncItemNames(orders: [CheckoutRecord], titles: (CheckoutRecord) -> [String]) async {
        guard !stubbed else { return }
        let sentListName = "orderTracking.itemsSent.v1"
        var sent = Set(defaults.stringArray(forKey: sentListName) ?? [])
        for record in orders {
            guard tracked(for: record) != nil, let id = record.orderID, let number = Self.number(id), !sent.contains(number),
                  let first = titles(record).first else { continue }
            let body: [String: Any] = ["orderID": id, "itemTitle": String(first.prefix(200)), "itemCount": min(max(titles(record).count, 1), 999)]
            guard let data = try? JSONSerialization.data(withJSONObject: body),
                  let (status, _) = try? await call(method: "PATCH", body: data, path: "/items"), status == 200 else { continue }
            sent.insert(number)
        }
        defaults.set(Array(sent), forKey: sentListName)
    }

    static func number(_ gid: String) -> String? {
        gid.split(separator: "/").last.map(String.init)?.split(separator: "?").first.map(String.init)
    }

    private func apply(_ data: Data) {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        orders = reply.orders
        save()
    }

    /// Unit tests: what the server would have reported.
    func stubOrders(_ list: [TrackedOrder]) { orders = list }

    private func save() { defaults.set(try? JSONEncoder().encode(orders), forKey: Self.cacheKey) }

    func clear() {
        orders = []
        defaults.removeObject(forKey: Self.cacheKey)
        guard !stubbed else { return }
        Task { _ = try? await call(method: "DELETE") }
    }

    private struct Reply: Decodable { let orders: [TrackedOrder] }

    private func call(method: String = "GET", body: Data? = nil, path: String = "") async throws -> (Int, Data) {
        guard AppChannel.reachesOrderServer else { throw URLError(.cancelled) }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/orders/tracked" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Which order a tapped tracking notification is about (order-tracking.js
/// `trackedOrder`): its Shopify order when the server knows it, else the brand.
struct TrackedOrderRequest: Equatable {
    let orderID: String?
    let brandID: String
}

/// One order the server follows: where it is and how to see it at the brand.
struct TrackedOrder: Codable, Equatable {
    let brandID: String
    let checkoutID: String
    var orderID: String?
    /// The brand's own order status page.
    var permalink: String?
    /// confirmed, shipped, out_for_delivery or delivered.
    var state: String?
    var carrier: String?
    var trackingNumber: String?
    var trackingURL: String?
    let created: Double
    var updated: Double?
    /// The carrier's status (EasyPost words: failure, return_to_sender, …)
    /// and its own last message, for a problem's explanation.
    var trackingStatus: String?
    var trackingDetail: String?

    var statusPage: URL? {
        guard let permalink, let url = URL(string: permalink), url.scheme == "https" else { return nil }
        return url
    }

    /// Where "Track package" goes: the brand's status page, else the
    /// carrier's own tracking page for the number (no status page to read).
    var trackPage: URL? {
        if let statusPage { return statusPage }
        guard let trackingURL, let url = URL(string: trackingURL), url.scheme == "https" else { return nil }
        return url
    }
}
