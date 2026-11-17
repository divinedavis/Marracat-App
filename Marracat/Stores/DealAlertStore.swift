import Foundation

/// Price-drop and brand-sale alerts (web/server/deal-alerts.js; owner,
/// 2026-10-04): email plus a push to every phone signed in to the account.
/// (The "Track this price?" prompt after a fourth look was removed on
/// 2026-10-05: it popped up again on every return to the page.)
@MainActor
@Observable
final class DealAlertStore {
    static let shared = DealAlertStore()

    private(set) var prices = Set<String>()
    private(set) var brands = Set<String>()
    /// Brands whose new drops this shopper watches, and the departments
    /// they want to hear about ([] = everything new; owner, 2026-10-20).
    private(set) var drops: [String: [String]] = [:]
    /// The price each tracked product was at when tracked (or last alerted).
    private(set) var trackedAt: [String: Double] = [:]
    private(set) var busy = Set<String>()
    /// The daily digest (owner, 2026-11-15, design C06): price drops, sales,
    /// new drops and last sizes held back and sent together at 9 AM.
    private(set) var digest = false
    var message: String?
    /// A tapped brand-sale notification: open that brand.
    var openBrandRequest: String?

    private var args: [String] { ProcessInfo.processInfo.arguments }
    private var testing: Bool { args.contains("-UITEST_RESET") || args.contains("-OFFLINE_CATALOG") }
    /// UI tests: alerts saved on the phone only, and signed in.
    var stubbed: Bool { args.contains("-DEAL_ALERTS_STUB") }

    // MARK: Alerts

    func refresh(account: AccountStore) async {
        guard !testing, account.signedIn else { return }
        struct Mine: Decodable {
            struct P: Decodable { let productID: String; let price: Double? }
            struct B: Decodable { let brandID: String }
            struct D: Decodable { let brandID: String; let categories: [String] }
            let prices: [P]; let brands: [B]; let drops: [D]?
            let digest: Bool?
        }
        guard let (status, data) = try? await call("", account: account), status == 200,
              let m = try? JSONDecoder().decode(Mine.self, from: data) else { return }
        prices = Set(m.prices.map(\.productID))
        trackedAt = Dictionary(m.prices.compactMap { p in p.price.map { (p.productID, $0) } }, uniquingKeysWith: { a, _ in a })
        brands = Set(m.brands.map(\.brandID))
        drops = Dictionary((m.drops ?? []).map { ($0.brandID, $0.categories) }, uniquingKeysWith: { a, _ in a })
        digest = m.digest ?? false
    }

    /// Turn the daily digest on or off; the phone's time zone says when 9 AM is.
    func setDigest(_ on: Bool, account: AccountStore) async {
        if stubbed { digest = on; return }
        guard account.signedIn else {
            message = String(localized: "Sign in to get a daily digest.", comment: "Digest setting error")
            return
        }
        busy.insert("digest")
        defer { busy.remove("digest") }
        if on { _ = await RestockStore.shared.enableOrderUpdates() }
        let body = try? JSONSerialization.data(withJSONObject: ["digest": on, "tz": TimeZone.current.identifier])
        guard let (status, _) = try? await call("prefs", method: "POST", body: body, account: account), status == 200 else {
            message = String(localized: "That setting couldn't be changed. Try again.", comment: "Digest setting error")
            return
        }
        digest = on
        Analytics.shared.track(on ? "alert_on" : "alert_off", ["kind": .string("digest")])
    }

    /// Signed out: the alerts were the account's, so the phone forgets them
    /// (and Spotlight its followed brands).
    func signedOut() {
        prices = []; brands = []; trackedAt = [:]; drops = [:]; digest = false
    }

    func togglePrice(_ productID: String, account: AccountStore) async {
        await toggle(kind: "price", id: productID, key: "productID", in: \.prices, account: account)
    }

    func toggleBrand(_ brandID: String, account: AccountStore) async {
        await toggle(kind: "brand", id: brandID, key: "brandID", in: \.brands, account: account)
    }

    /// Watch a brand's new drops, in these departments ([] = all), or change
    /// which. True when it took.
    @discardableResult
    func watchDrops(_ brandID: String, categories: [String], account: AccountStore) async -> Bool {
        await setDrops(brandID, categories: categories, account: account)
    }

    @discardableResult
    func stopDrops(_ brandID: String, account: AccountStore) async -> Bool {
        await setDrops(brandID, categories: nil, account: account)
    }

    private func setDrops(_ brandID: String, categories: [String]?, account: AccountStore) async -> Bool {
        if stubbed { drops[brandID] = categories; return true }
        guard account.signedIn else {
            message = String(localized: "Sign in to hear about new drops.", comment: "New-drop alert error")
            return false
        }
        busy.insert(brandID)
        defer { busy.remove(brandID) }
        if categories != nil { _ = await RestockStore.shared.enableOrderUpdates() }
        var payload: [String: Any] = ["brandID": brandID]
        if let categories { payload["categories"] = categories }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        guard let (status, _) = try? await call("drops", method: categories == nil ? "DELETE" : "POST", body: body, account: account) else {
            message = String(localized: "That alert couldn't be changed. Try again.", comment: "Price alert error")
            return false
        }
        switch status {
        case 200, 201:
            let was = drops[brandID] != nil
            drops[brandID] = categories
            Analytics.shared.track(categories == nil ? "alert_off" : "alert_on",
                                   ["kind": .string("brand_drops"), "brand": .string(brandID)])
            if categories != nil && !was { Analytics.shared.track("brand_follow", ["brand": .string(brandID)]) }
            return true
        case 401: message = String(localized: "Sign in again to hear about new drops.", comment: "New-drop alert error")
        case 429: message = String(localized: "You have as many alerts as you can. Remove one first.", comment: "Price alert error")
        default: message = String(localized: "That alert couldn't be changed. Try again.", comment: "Price alert error")
        }
        return false
    }

    private func toggle(kind: String, id: String, key: String, in set: ReferenceWritableKeyPath<DealAlertStore, Set<String>>, account: AccountStore) async {
        let on = self[keyPath: set].contains(id)
        if stubbed { if on { self[keyPath: set].remove(id) } else { self[keyPath: set].insert(id) }; return }
        guard account.signedIn else { message = String(localized: "Sign in to get price and sale alerts.", comment: "Price alert error"); return }
        busy.insert(id)
        defer { busy.remove(id) }
        // The email goes either way; a push too when notifications are on.
        if !on { _ = await RestockStore.shared.enableOrderUpdates() }
        let body = try? JSONSerialization.data(withJSONObject: [key: id])
        guard let (status, _) = try? await call(kind, method: on ? "DELETE" : "POST", body: body, account: account) else {
            message = String(localized: "That alert couldn't be changed. Try again.", comment: "Price alert error")
            return
        }
        switch status {
        case 200, 201:
            if on { self[keyPath: set].remove(id) } else { self[keyPath: set].insert(id) }
            Analytics.shared.track(on ? "alert_off" : "alert_on",
                                   ["kind": .string(kind == "brand" ? "brand_sale" : "price"),
                                    (kind == "brand" ? "brand" : "product"): .string(id)])
            // A brand-sale alert is how the app follows a brand (EVENTS.md).
            if kind == "brand" { Analytics.shared.track(on ? "brand_unfollow" : "brand_follow", ["brand": .string(id)]) }
        case 401: message = String(localized: "Sign in again to get price and sale alerts.", comment: "Price alert error")
        case 429: message = String(localized: "You have as many alerts as you can. Remove one first.", comment: "Price alert error")
        default: message = String(localized: "That alert couldn't be changed. Try again.", comment: "Price alert error")
        }
    }

    // MARK: Network

    private func call(_ path: String, method: String = "GET", body: Data? = nil, account: AccountStore) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: "https://marracat.com/api/alerts" + (path.isEmpty ? "" : "/\(path)"))!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        account.authorize(&r)
        let (data, response) = try await URLSession.shared.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
