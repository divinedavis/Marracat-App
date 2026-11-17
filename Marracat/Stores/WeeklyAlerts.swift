import Foundation
import UserNotifications

/// Two opt-in alerts made on the phone (owner, 2026-11-15, designs D05 and
/// D03): "Sunday picks", new products from the brands this shopper follows,
/// and "Picked for you", one brand they don't know yet in a department they
/// already shop (never one they never touched: owner, 2026-11-09). Both are
/// promotional, so both stay off until the shopper turns them on under
/// You › Notifications (App Review 4.5.4), and each comes at most once a week.
///
/// Each is a calendar notification for its next slot, rebuilt whenever the
/// app comes to the front, so it carries what's new as of the last open.
@MainActor
enum WeeklyAlerts {
    static let picksKey = "alerts.weeklyPicks", brandKey = "alerts.brandIdeas", shownKey = "alerts.brandIdeasShown"
    static let picksID = "weekly-picks", brandID = "brand-idea"

    static var picksOn: Bool {
        get { UserDefaults.standard.bool(forKey: picksKey) }
        set { UserDefaults.standard.set(newValue, forKey: picksKey) }
    }
    static var brandIdeasOn: Bool {
        get { UserDefaults.standard.bool(forKey: brandKey) }
        set { UserDefaults.standard.set(newValue, forKey: brandKey) }
    }

    /// The hour an alert goes out: when this shopper is usually in the app
    /// (ShoppingRhythm), kept between 8 am and 8 pm, else `fallback`.
    static func hour(fallback: Int) -> Int { hour(fallback: fallback, usual: ShoppingRhythm.shared.usualHour()) }

    static func hour(fallback: Int, usual: Int?) -> Int {
        guard let usual else { return fallback }
        return min(max(usual, 8), 20)
    }

    /// Re-make both for their next slot, or take them away if off.
    static func refresh(catalog: CatalogStore, shopper: ShopperStore) async {
        guard catalog.isComplete, !ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") else { return }
        let center = UNUserNotificationCenter.current()
        if picksOn, let card = picksCard(catalog: catalog, shopper: shopper) {
            await LocalAlert.schedule(id: picksID, title: card.t, body: card.s ?? "", card: card,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour(fallback: 9), minute: 0, weekday: 1), repeats: false))
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [picksID])
        }
        if brandIdeasOn, let card = brandCard(catalog: catalog, shopper: shopper) {
            await LocalAlert.schedule(id: brandID, title: String(localized: "Picked for you: \(card.t)", comment: "Notification title; the argument is a brand"),
                                      body: card.s ?? "", card: card,
                                      trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour(fallback: 12), minute: 0, weekday: 4), repeats: false))
            remember(card.bid)
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [brandID])
        }
    }

    /// Turning one on asks for notifications if this phone hasn't been asked yet.
    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: Sunday picks

    /// Brands this shopper follows: sale alerts, watched drops, and what they saved.
    static func followed(catalog: CatalogStore, shopper: ShopperStore) -> Set<String> {
        let alerts = DealAlertStore.shared
        return alerts.brands.union(alerts.drops.keys).union(shopper.saved.compactMap { catalog.product($0)?.brand })
    }

    static func picksCard(catalog: CatalogStore, shopper: ShopperStore, now: Date = .now) -> AlertCard? {
        let brands = followed(catalog: catalog, shopper: shopper)
        let fresh = brands.flatMap { catalog.products(for: $0) }
            .filter { $0.available && !$0.images.isEmpty && isRecent($0.publishedAt, now: now) }
        let picks = spread(fresh.sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }, perBrand: 2, limit: 5)
        guard picks.count >= 3 else { return nil }
        let names = Array(NSOrderedSet(array: picks.compactMap { catalog.brand($0.brand)?.name })) as? [String] ?? []
        var card = AlertCard(k: .picks, t: String(localized: "\(picks.count) new picks for your week", comment: "Alert card title; the argument is a count"))
        card.s = names.count > 3
            ? String(localized: "From \(names.prefix(3).joined(separator: ", ")) and \(names.count - 3) more you follow", comment: "Alert card line; brand names, then a count")
            : String(localized: "From \(ListFormatter.localizedString(byJoining: names)), brands you follow", comment: "Alert card line; brand names")
        card.items = picks.prefix(3).map { item($0) }
        card.when = DateComponents(calendar: .current, hour: hour(fallback: 9)).date.map { $0.formatted(date: .omitted, time: .shortened) }
        card.open = AppDestination.picks(String(localized: "Your Sunday picks", comment: "Screen title"), picks.map(\.id)).url.absoluteString
        return card
    }

    // MARK: A brand they'd like

    static func brandCard(catalog: CatalogStore, shopper: ShopperStore) -> AlertCard? {
        let touched = catalog.touchedDepartments(of: shopper)
        guard !touched.isEmpty else { return nil }
        // The department they shop most: the most items viewed or saved in it.
        var weight: [String: Int] = [:]
        for id in shopper.recentlyViewed + shopper.saved + shopper.saved {
            if let c = catalog.product(id)?.category, touched.contains(c) { weight[c, default: 0] += 1 }
        }
        guard let department = weight.max(by: { $0.value < $1.value })?.key ?? touched.sorted().first else { return nil }
        let skip = followed(catalog: catalog, shopper: shopper)
            .union(shopper.recentlyViewed.compactMap { catalog.product($0)?.brand })
            .union(shown)
        let best = catalog.brands
            .filter { !skip.contains($0.id) }
            .map { brand -> (Brand, [Product]) in (brand, catalog.products(for: brand.id).filter(\.available)) }
            .filter { _, products in products.filter { $0.category == department }.count >= 8 }
            .max { a, b in a.1.filter { $0.category == department }.count < b.1.filter { $0.category == department }.count }
        guard let (brand, products) = best else { return nil }
        var departments: [String: Int] = [:]
        for p in products { departments[p.category, default: 0] += 1 }
        let names = departments.sorted { $0.value > $1.value }.prefix(3).compactMap { catalog.category($0.key)?.name }
        let because = catalog.category(department)?.name.lowercased() ?? department
        var card = AlertCard(k: .brand, t: brand.name)
        card.s = String(localized: "\(ListFormatter.localizedString(byJoining: names)) · because you shop \(because)",
                        comment: "Alert card line; departments, then the department the shopper shops")
        card.img = AlertImage.small(BrandStoreView.heroPhoto(brand, Array(catalog.products(for: brand.id))), width: 900)
        card.tag = String(localized: "Picked for you", comment: "Alert card tag")
        card.count = String(localized: "\(products.count) items", comment: "Alert card: how many products a brand has")
        card.bid = brand.id
        card.open = AppDestination.brand(brand.id).url.absoluteString
        return card
    }

    private static var shown: Set<String> { Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? []) }

    private static func remember(_ brand: String?) {
        guard let brand else { return }
        var list = UserDefaults.standard.stringArray(forKey: shownKey) ?? []
        if !list.contains(brand) { list.append(brand) }
        UserDefaults.standard.set(Array(list.suffix(60)), forKey: shownKey)
    }

    // MARK: Helpers

    static func item(_ p: Product) -> AlertCard.Item {
        AlertCard.Item(id: p.id, t: p.title, p: Money.string(p.price, currency: p.currencyCode), img: AlertImage.small(p.images.first))
    }

    /// Published in the last ten days.
    nonisolated static func isRecent(_ published: String?, now: Date) -> Bool {
        guard let published else { return false }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: published) ?? ISO8601DateFormatter().date(from: published) else { return false }
        return now.timeIntervalSince(date) < 10 * 86400 && date <= now.addingTimeInterval(86400)
    }

    /// A few from each brand, so one big drop doesn't fill the card.
    nonisolated static func spread(_ products: [Product], perBrand: Int, limit: Int) -> [Product] {
        var count: [String: Int] = [:], out: [Product] = []
        for p in products where count[p.brand, default: 0] < perBrand {
            count[p.brand, default: 0] += 1
            out.append(p)
            if out.count == limit { break }
        }
        return out
    }
}
