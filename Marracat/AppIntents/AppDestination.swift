import Foundation
import Observation

/// A screen that Siri, Shortcuts, a Spotlight result or a marracat:// link
/// opens (owner, 2026-10-14: "do the siri and spotlight now"). Each one is a
/// path on one tab's stack, made of the app's own `Route`s, so it opens
/// exactly the screen a tap inside the app would.
enum AppDestination: Hashable {
    case product(String)
    case brand(String)
    case category(String)
    case search(String)
    case deals
    case orders
    /// A holiday event's collection (marracat://collection/<id>).
    case collection(String)
    /// A shopping alert's products, by id: weekly picks, several price drops
    /// (marracat://picks?title=…&ids=a,b,c; AlertCard.open).
    case picks(String, [String])

    /// The tab whose stack shows it: departments live under Browse, orders
    /// under You, everything else on Home (where shared product links and
    /// notifications already open).
    var tab: AppTab {
        switch self {
        case .category: .browse
        case .orders: .you
        case .product, .brand, .search, .deals, .collection, .picks: .home
        }
    }

    var path: [Route] {
        switch self {
        case .product(let id): [.product(id)]
        case .brand(let id): [.brand(id)]
        case .category(let id): [.category(id)]
        case .search(let q): [.search(q)]
        case .deals: [.deals]
        case .orders: [.checkouts]
        case .collection(let id): [.collection(id)]
        case .picks(let title, let ids): [.picks(title, ids)]
        }
    }

    /// Whether what it names is in the catalog. A link to a product, brand or
    /// department the catalog no longer has (a stale Spotlight result, a
    /// made-up link) opens nothing rather than an empty page. Before the
    /// whole catalog has loaded every id is given the benefit of the doubt.
    func exists(in catalog: CatalogStore) -> Bool {
        guard catalog.isComplete else { return true }
        switch self {
        case .product(let id): return catalog.product(id) != nil
        case .brand(let id): return catalog.brand(id) != nil
        case .category(let id): return catalog.category(id) != nil
        case .collection(let id): return HolidayCalendar.collection(id) != nil
        case .search, .deals, .orders: return true
        case .picks(_, let ids): return ids.contains { catalog.product($0) != nil }
        }
    }

    // MARK: Spotlight

    /// The Spotlight item's unique identifier, "product:<id>" or
    /// "brand:<id>"; tapping the result hands it back
    /// (CSSearchableItemActivityIdentifier). Nil for what isn't indexed.
    var spotlightID: String? {
        switch self {
        case .product(let id): "product:" + id
        case .brand(let id): "brand:" + id
        case .category(let id): "category:" + id
        case .search, .deals, .orders, .collection, .picks: nil
        }
    }

    init?(spotlightID: String) {
        guard let colon = spotlightID.firstIndex(of: ":") else { return nil }
        let kind = spotlightID[..<colon], id = String(spotlightID[spotlightID.index(after: colon)...])
        guard !id.isEmpty else { return nil }
        switch kind {
        case "product": self = .product(id)
        case "brand": self = .brand(id)
        case "category": self = .category(id)
        default: return nil
        }
    }

    // MARK: Links

    /// marracat://product/<id>, marracat://brand/<id>,
    /// marracat://category/<id>, marracat://search?q=…, marracat://deals,
    /// marracat://orders, marracat://collection/<id>. (marracat://order?… is the delivery Live Activity's,
    /// handled by DeliveryLink before this.)
    init?(url: URL) {
        guard url.scheme == "marracat", let host = url.host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let id = parts.count == 1 ? parts[0] : nil
        switch host {
        case "product": guard let id else { return nil }; self = .product(id)
        case "brand": guard let id else { return nil }; self = .brand(id)
        case "category": guard let id else { return nil }; self = .category(id)
        case "search":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            self = .search(String(trimmed.prefix(AppDestination.maxQuery)))
        case "deals": self = .deals
        case "orders": self = .orders
        case "collection": guard let id else { return nil }; self = .collection(id)
        case "picks":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let ids = (items.first { $0.name == "ids" }?.value ?? "").split(separator: ",").map(String.init)
                .filter { !$0.isEmpty && $0.count <= 120 }.prefix(AppDestination.maxPicks)
            guard !ids.isEmpty else { return nil }
            let title = String((items.first { $0.name == "title" }?.value ?? "").prefix(80))
            self = .picks(title, Array(ids))
        default: return nil
        }
    }

    var url: URL {
        var c = URLComponents()
        c.scheme = "marracat"
        switch self {
        case .product(let id): c.host = "product"; c.path = "/" + id
        case .brand(let id): c.host = "brand"; c.path = "/" + id
        case .category(let id): c.host = "category"; c.path = "/" + id
        case .search(let q): c.host = "search"; c.queryItems = [URLQueryItem(name: "q", value: q)]
        case .deals: c.host = "deals"
        case .orders: c.host = "orders"
        case .collection(let id): c.host = "collection"; c.path = "/" + id
        case .picks(let title, let ids): c.host = "picks"; c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        }
        return c.url!
    }

    /// The longest search a link or Siri can start; the search field's own
    /// text is never this long.
    static let maxQuery = 120
    /// The most products a picks link opens.
    static let maxPicks = 24
}

/// Where Siri, Shortcuts and Spotlight reach the running app: the screen they
/// asked for, and the stores their queries read. Set up in `MarracatApp.init`,
/// which runs whether the app was opened by a person or started by the system
/// to answer an intent.
@MainActor @Observable
final class IntentRouter {
    static let shared = IntentRouter()

    /// A screen waiting to open; MarracatApp opens it once the launch splash
    /// is out of the way, the same way it opens a tapped notification.
    var openRequest: AppDestination?

    @ObservationIgnored var catalog: CatalogStore?
    @ObservationIgnored var shopper: ShopperStore?

    func open(_ destination: AppDestination) { openRequest = destination }

    /// The whole catalog, once it has loaded behind Home's slice: an intent
    /// that started the app waits for it (up to `limit`) rather than answer
    /// from a few thousand products. Nil if it never lands.
    func completeCatalog(limit: Duration = .seconds(15)) async -> CatalogStore? {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if let catalog, catalog.isComplete { return catalog }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return catalog?.isComplete == true ? catalog : nil
    }
}
