import Foundation

// Home Screen and Lock Screen widgets (owner-approved queue item 3,
// 2026-10-14): price drops on saved items, a featured premier brand, and the
// orders the app tracks.
//
// The app writes one small snapshot (a few kilobytes of JSON) plus a handful
// of pre-shrunk JPEG thumbnails into the App Group container; the widget
// extension only reads them. Never the catalog: a widget extension is killed
// past about 30 MB (Apple DTS on the developer forums), and the catalog is
// ~147k products. Compiled into the app and the extension (project.yml
// `sources: - path: Shared`), so it uses nothing else from either.

/// The widgets' kind strings, which WidgetCenter.reloadTimelines(ofKind:) takes.
enum WidgetKind {
    static let priceDrops = "MarracatPriceDrops"
    static let featuredBrand = "MarracatFeaturedBrand"
    static let orders = "MarracatOrders"
    static let all = [priceDrops, featuredBrand, orders]
}

/// The marracat:// links a tapped widget opens. The same shapes the app
/// already handles: AppDestination (product, brand, deals, orders) and the
/// Live Activity's DeliveryLink (order?brand=…&order=…). WidgetTests checks
/// both parse every link built here.
enum WidgetLink {
    static func product(_ id: String) -> URL { path("product", id) }
    static func brand(_ id: String) -> URL { path("brand", id) }
    static let deals = URL(string: "marracat://deals")!
    static let orders = URL(string: "marracat://orders")!

    /// One order under You › Orders: by its Shopify order number when there
    /// is one, else the brand's latest order.
    static func order(brandID: String, number: String?) -> URL {
        var c = URLComponents()
        c.scheme = "marracat"; c.host = "order"
        c.queryItems = [URLQueryItem(name: "brand", value: brandID)] + (number.map { [URLQueryItem(name: "order", value: $0)] } ?? [])
        return c.url ?? orders
    }

    private static func path(_ host: String, _ id: String) -> URL {
        var c = URLComponents()
        c.scheme = "marracat"; c.host = host; c.path = "/" + id
        return c.url ?? deals
    }
}

/// Everything the widgets show, as the app last saw it.
struct WidgetSnapshot: Codable, Equatable {
    /// Bumped when the shape changes; the extension ignores any other version
    /// (it shows its empty state until the app writes the new one).
    static let currentVersion = 1

    var version = WidgetSnapshot.currentVersion
    /// Saved items whose price is lower than when they were saved, deepest first.
    var priceDrops: [WidgetProduct] = []
    /// How many items are saved; the empty state says so.
    var savedCount = 0
    /// The departments the price drops are in, for the widget's filter.
    var dropDepartments: [WidgetDepartment] = []
    /// The premier brands in Home's order.
    var brands: [WidgetBrand] = []
    /// Recent orders, newest first.
    var orders: [WidgetOrder] = []
    /// Whether anyone is signed in; only changes the empty states' wording.
    var signedIn = false

    static let empty = WidgetSnapshot()

    /// Which widgets differ between two snapshots, so only those reload.
    func changedKinds(from old: WidgetSnapshot) -> [String] {
        var kinds: [String] = []
        if old.version != version || old.priceDrops != priceDrops || old.savedCount != savedCount
            || old.dropDepartments != dropDepartments || old.signedIn != signedIn { kinds.append(WidgetKind.priceDrops) }
        if old.version != version || old.brands != brands { kinds.append(WidgetKind.featuredBrand) }
        if old.version != version || old.orders != orders || old.signedIn != signedIn { kinds.append(WidgetKind.orders) }
        return kinds
    }

    /// Every thumbnail file it names.
    var thumbNames: Set<String> {
        var names = Set<String>()
        for p in priceDrops { if let t = p.thumb { names.insert(t) } }
        for b in brands {
            if let t = b.thumb { names.insert(t) }
            for p in b.products { if let t = p.thumb { names.insert(t) } }
        }
        for o in orders { if let t = o.thumb { names.insert(t) } }
        return names
    }
}

struct WidgetProduct: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let brandName: String
    let category: String
    /// "$48.00", already formatted in the brand's currency.
    let price: String
    /// The higher price it dropped from, formatted; nil when not a drop.
    var was: String?
    /// Whole percent below `was`; 0 when not a drop.
    var percentOff: Int = 0
    /// A thumbnail file in the container's thumbs folder.
    var thumb: String?

    var url: URL { WidgetLink.product(id) }

    /// What VoiceOver reads: "Fenty Beauty, Gloss Bomb, $16.00, was $21.00, 24% off".
    var spoken: String {
        var parts = [brandName, title, price].filter { !$0.isEmpty }
        if let was { parts.append(String(localized: "was \(was)", comment: "Price drop: the old price; the argument is a price")) }
        if percentOff > 0 { parts.append(String(localized: "\(percentOff)% off", comment: "Price drop: percent off")) }
        return parts.joined(separator: ", ")
    }
}

struct WidgetDepartment: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct WidgetBrand: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    var tagline: String?
    var thumb: String?
    /// A few of its products with photos, for the medium and large sizes.
    var products: [WidgetProduct] = []

    var url: URL { WidgetLink.brand(id) }
}

struct WidgetOrder: Codable, Equatable, Identifiable {
    /// The app's checkout record id.
    let id: String
    let brandID: String
    let brandName: String
    /// The first item's name.
    var item: String?
    /// How many items the order held.
    var itemCount = 1
    /// 0 ordered, 1 shipped, 2 out for delivery, 3 delivered (RelayStore.step).
    var step = 0
    /// "Shipped Monday, October 13", the same words as Your Orders.
    let headline: String
    /// "USPS" when a carrier is known.
    var carrier: String?
    let placed: Date
    var thumb: String?
    /// marracat://order?… (WidgetLink.order).
    let link: String

    var url: URL { URL(string: link).flatMap { $0.scheme == "marracat" ? $0 : nil } ?? WidgetLink.orders }
    var delivered: Bool { step >= 3 }

    /// "Ripl Efek · Laundry Detergent".
    var title: String { item.map { "\(brandName) · \($0)" } ?? brandName }

    /// One word for the circular Lock Screen widget and tight spots.
    var shortStatus: String {
        switch step {
        case 3: String(localized: "Delivered", comment: "Order step, one short word")
        case 2: String(localized: "Out", comment: "Order step, one short word")
        case 1: String(localized: "Shipped", comment: "Order step, one short word")
        default: String(localized: "Ordered", comment: "Order step, one short word")
        }
    }

    var symbol: String {
        switch step {
        case 3: "checkmark.circle.fill"
        case 2: "box.truck.fill"
        case 1: "shippingbox.fill"
        default: "bag.fill"
        }
    }

    var spoken: String { [title, headline, carrier].compactMap { $0 }.joined(separator: ", ") }
}

// MARK: - The App Group container

/// Reading and writing the snapshot and its thumbnails.
enum WidgetStore {
    /// Registered for both App IDs (scripts/register_in_asc.py) and in both
    /// targets' entitlements (project.yml).
    static let appGroup = "group.com.divinedavis.marracat"

    /// Tests point it at a temporary folder.
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL? {
        if let rootOverride { return rootOverride }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widgets", isDirectory: true)
    }

    static var snapshotURL: URL? { root?.appendingPathComponent("snapshot.json") }
    static var thumbsURL: URL? { root?.appendingPathComponent("thumbs", isDirectory: true) }

    /// The largest thumbnail kept, in pixels on its longer side, and in bytes.
    static let thumbPixels = 240
    static let maxThumbBytes = 80_000

    /// The last snapshot, or the empty one (nothing written yet, cleared,
    /// unreadable, or written by a different version).
    static func read() -> WidgetSnapshot {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              s.version == WidgetSnapshot.currentVersion else { return .empty }
        return s
    }

    /// Readable once the phone has been unlocked after a restart, so Lock
    /// Screen widgets can draw while it's locked again.
    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let root, let url = snapshotURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// A thumbnail's file, if it's there. Names come from the app; anything
    /// that isn't a plain file name is refused.
    static func thumbURL(_ name: String?) -> URL? {
        guard let name, isSafeName(name), let url = thumbsURL?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } && !name.hasPrefix(".")
    }

    static func saveThumb(_ data: Data, named name: String) throws {
        guard isSafeName(name), data.count <= maxThumbBytes, let dir = thumbsURL else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Deletes thumbnails no snapshot names any more.
    static func pruneThumbs(keeping names: Set<String>) {
        guard let dir = thumbsURL, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where !names.contains(f) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    /// Sign-out and account deletion: the snapshot and every thumbnail go.
    static func clear() {
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Timelines

/// What each widget shows for a configuration, kept apart from WidgetKit so
/// the app's unit tests run it (WidgetTests).
enum WidgetTimeline {
    /// How often the featured brand moves on when it rotates.
    static let rotation: TimeInterval = 3 * 60 * 60
    /// Entries handed over at once: a day of rotation.
    static let rotationEntries = 8
    /// The snapshot is re-read at least this often even if the app never
    /// asks, in case a reload request was dropped.
    static let refresh: TimeInterval = 6 * 60 * 60

    /// The price drops, optionally in one department.
    static func priceDrops(_ s: WidgetSnapshot, department: String?) -> [WidgetProduct] {
        guard let department, !department.isEmpty else { return s.priceDrops }
        return s.priceDrops.filter { $0.category == department }
    }

    /// The featured brand at `date`: the one picked, or else the premier
    /// brands in turn, three hours each, the same on every phone at once.
    static func featured(_ s: WidgetSnapshot, pinned: String?, at date: Date) -> WidgetBrand? {
        if let pinned, let b = s.brands.first(where: { $0.id == pinned }) { return b }
        guard !s.brands.isEmpty else { return nil }
        let slot = Int((date.timeIntervalSince1970 / rotation).rounded(.down))
        return s.brands[((slot % s.brands.count) + s.brands.count) % s.brands.count]
    }

    /// Entry dates for the featured brand: now, then each rotation boundary
    /// for a day. A pinned brand needs only the one.
    static func featuredDates(pinned: Bool, now: Date) -> [Date] {
        guard !pinned else { return [now] }
        let next = ((now.timeIntervalSince1970 / rotation).rounded(.down) + 1) * rotation
        return [now] + (0..<(rotationEntries - 1)).map { Date(timeIntervalSince1970: next + Double($0) * rotation) }
    }

    /// Orders, newest first, with or without the delivered ones.
    static func orders(_ s: WidgetSnapshot, includeDelivered: Bool) -> [WidgetOrder] {
        includeDelivered ? s.orders : s.orders.filter { !$0.delivered }
    }
}
