import Foundation

/// When this shopper shops each aisle (owner, 2026-11-16: "if a user usually
/// looks for toilet paper the last week of each month we should know that").
///
/// Every search, product page, save, add to cart and order is noted against
/// the aisle it belongs to ("household:toilet-paper"), with its time. That
/// log turns into rhythms (`Rhythm`): the same part of each month, the same
/// day of the week, or every so many days. An aisle whose time has come fills
/// Home's "Time to restock?" row and lifts it to the top of Home, and the
/// shopper's usual hour sets when their opted-in weekly alerts arrive.
///
/// Aisles rather than products, so a shopper who buys a different toilet
/// paper each month, or only searches for it, still has a rhythm. Kept on the
/// phone only and never sent anywhere; the "Personalized recommendations"
/// switch turns it off and clears it, with TasteProfile.
@MainActor
final class ShoppingRhythm {
    static let shared = ShoppingRhythm()

    enum Kind: String, Codable { case search, view, save, cart, purchase }
    struct Event: Codable, Equatable {
        let aisle: String
        let kind: Kind
        let at: Date
    }

    private(set) var events: [Event] = []
    var enabled = true { didSet { if !enabled { clear() } } }
    /// Where products and searches find their aisle (set once at launch).
    weak var catalog: CatalogStore?
    private let defaults: UserDefaults
    static let key = "rhythm.events.v1"
    /// A year and a bit: a monthly rhythm needs several months to show.
    static let maxAge: TimeInterval = 400 * 86_400
    static let keep = 2_000
    /// The same thing again within the hour (a product page reopened, a
    /// search run twice) is one event.
    static let repeatWindow: TimeInterval = 3_600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved
        }
    }

    func record(aisle: String, _ kind: Kind, at: Date = .now) {
        guard enabled else { return }
        events = Self.adding(Event(aisle: aisle, kind: kind, at: at), to: events)
        defaults.set(try? JSONEncoder().encode(events), forKey: Self.key)
    }

    /// A product looked at, saved, carted or bought.
    func record(product id: String, _ kind: Kind, at: Date = .now) {
        guard enabled, let catalog, let p = catalog.product(id), let aisle = Self.aisle(of: p, catalog: catalog) else { return }
        record(aisle: aisle, kind, at: at)
    }

    /// A search, noted against the aisle most of its top results sit in.
    func searched(_ results: [Product], at: Date = .now) {
        guard enabled, let catalog, let aisle = Self.dominantAisle(results, catalog: catalog) else { return }
        record(aisle: aisle, .search, at: at)
    }

    func clear() {
        events = []
        defaults.removeObject(forKey: Self.key)
    }

    func rhythms(now: Date = .now, calendar: Calendar = .current) -> [Rhythm] {
        enabled ? Rhythm.find(events, now: now, calendar: calendar) : []
    }

    /// The hour this shopper is usually in the app, if they have one.
    func usualHour(now: Date = .now, calendar: Calendar = .current) -> Int? {
        enabled ? Rhythm.usualHour(events, now: now, calendar: calendar) : nil
    }

    /// Products for the aisles due now, closest to their usual time first, a
    /// few per aisle: what this shopper bought there before, then what they
    /// looked at there, then the aisle's others, never hidden or sold out.
    func dueProducts(catalog: CatalogStore, bought: [String], touched: [String], hidden: Set<String>,
                     now: Date = .now, calendar: Calendar = .current, perAisle: Int = 4) -> [Product] {
        let due = rhythms(now: now, calendar: calendar).filter { $0.isDue(now: now, calendar: calendar) }
        guard !due.isEmpty else { return [] }
        let rank = Dictionary((bought + touched).enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Product] = []
        var taken = Set<String>()
        for r in due.sorted(by: { $0.closeness(now: now, calendar: calendar) < $1.closeness(now: now, calendar: calendar) }) {
            let open = catalog.products(inSub: r.aisle).filter { $0.available && !hidden.contains($0.id) && !taken.contains($0.id) }
            let known = open.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
            let others = catalog.spread(open.filter { rank[$0.id] == nil }.distinctLooking(), limit: perAisle)
            let picked = Array((known + others).distinctLooking().prefix(perAisle))
            out += picked
            taken.formUnion(picked.map(\.id))
        }
        return out
    }

    // MARK: Pure parts

    static func adding(_ e: Event, to events: [Event]) -> [Event] {
        let repeated = events.reversed().prefix { e.at.timeIntervalSince($0.at) < repeatWindow }
            .contains { $0.aisle == e.aisle && $0.kind == e.kind }
        guard !repeated else { return events }
        var out = events.filter { e.at.timeIntervalSince($0.at) < maxAge } + [e]
        if out.count > keep { out.removeFirst(out.count - keep) }
        return out
    }

    /// The first of the product's aisles the catalog knows.
    static func aisle(of p: Product, catalog: CatalogStore) -> String? {
        p.subs.lazy.map { "\(p.category):\($0)" }.first { catalog.subcategory($0) != nil }
    }

    /// The aisle holding 40% or more of a search's top 20 (at least three),
    /// or nil for a search that spans many ("gift", a brand's name).
    static func dominantAisle(_ results: [Product], catalog: CatalogStore) -> String? {
        let top = results.prefix(20)
        let counts = Dictionary(grouping: top.compactMap { aisle(of: $0, catalog: catalog) }, by: { $0 }).mapValues(\.count)
        guard let best = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              best.value >= 3, best.value * 5 >= top.count * 2 else { return nil }
        return best.key
    }
}

/// When one aisle comes round for this shopper.
struct Rhythm: Equatable {
    enum Pattern: Equatable {
        /// The same part of each month: `position` is how far through the
        /// month (0 = the 1st, 0.8 = around the 24th), give or take `spread` days.
        case monthly(position: Double, spread: Double)
        /// The same day each week (1 = Sunday, as Calendar counts).
        case weekly(weekday: Int)
        /// Every `days` days or so.
        case every(days: Double)
    }

    let aisle: String
    let pattern: Pattern
    /// When the aisle was last shopped (the start of the latest visit).
    let last: Date
    let lastPurchase: Date?

    /// Activity a few days apart is one visit to the aisle: a search on
    /// Monday and the order on Wednesday are the same need.
    static let visitGap: TimeInterval = 3 * 86_400
    /// Rhythms need this many separate visits to count.
    static let minVisits = 3
    /// A rhythm opens this many days before its usual time.
    static let lead: Double = 2
    private static let day: TimeInterval = 86_400

    struct Visit: Equatable {
        let start: Date
        let purchased: Bool
    }

    /// Each aisle's events grouped into visits, oldest first.
    static func visits(_ events: [ShoppingRhythm.Event]) -> [String: [Visit]] {
        var out: [String: [Visit]] = [:]
        for (aisle, evs) in Dictionary(grouping: events, by: \.aisle) {
            var visits: [Visit] = []
            var start: Date?, previous: Date?, bought = false
            for e in evs.sorted(by: { $0.at < $1.at }) {
                if let p = previous, e.at.timeIntervalSince(p) <= visitGap {
                    bought = bought || e.kind == .purchase
                } else {
                    if let s = start { visits.append(Visit(start: s, purchased: bought)) }
                    start = e.at; bought = e.kind == .purchase
                }
                previous = e.at
            }
            if let s = start { visits.append(Visit(start: s, purchased: bought)) }
            out[aisle] = visits
        }
        return out
    }

    /// Every aisle with a rhythm that is still going, most specific pattern
    /// first: the part of the month, then the weekday, then a steady gap.
    static func find(_ events: [ShoppingRhythm.Event], now: Date, calendar: Calendar) -> [Rhythm] {
        var out: [Rhythm] = []
        let purchases = Dictionary(grouping: events.filter { $0.kind == .purchase }, by: \.aisle).mapValues { $0.map(\.at).max()! }
        for (aisle, visits) in visits(events) where visits.count >= minVisits {
            let starts = visits.map(\.start)
            guard let pattern = monthly(starts, calendar: calendar) ?? weekly(starts, calendar: calendar) ?? every(starts),
                  let last = starts.last else { continue }
            let rhythm = Rhythm(aisle: aisle, pattern: pattern, last: last, lastPurchase: purchases[aisle])
            // Three cycles without a visit: the habit has stopped.
            guard now.timeIntervalSince(last) <= 3 * rhythm.cycleDays * day else { continue }
            out.append(rhythm)
        }
        return out.sorted { $0.aisle < $1.aisle }
    }

    var cycleDays: Double {
        switch pattern {
        case .monthly: 30.4
        case .weekly: 7
        case .every(let days): days
        }
    }

    // MARK: Detection

    /// Visits in three or more months, three quarters of them within a week
    /// of the same point in the month.
    static func monthly(_ starts: [Date], calendar: Calendar) -> Pattern? {
        let months = Set(starts.map { calendar.dateComponents([.year, .month], from: $0) })
        guard months.count >= minVisits else { return nil }
        let positions = starts.map { position(of: $0, calendar: calendar) }
        guard let center = circularMean(positions) else { return nil }
        let inliers = positions.filter { abs(wrap($0 - center)) * 30.4 <= 7 }
        let inlierMonths = Set(zip(starts, positions).filter { abs(wrap($0.1 - center)) * 30.4 <= 7 }
            .map { calendar.dateComponents([.year, .month], from: $0.0) })
        guard inlierMonths.count >= minVisits, Double(inliers.count) >= 0.75 * Double(positions.count),
              let tight = circularMean(inliers) else { return nil }
        let spread = min(7, max(2, inliers.map { abs(wrap($0 - tight)) * 30.4 }.max() ?? 0))
        return .monthly(position: tight, spread: spread)
    }

    /// Four or more visits over three weeks or more, about a week apart (a
    /// fortnightly habit lands on one weekday too, but is `every`), three
    /// quarters of them on the same day of the week.
    static func weekly(_ starts: [Date], calendar: Calendar) -> Pattern? {
        guard starts.count >= 4, let first = starts.first, let last = starts.last,
              last.timeIntervalSince(first) >= 21 * day else { return nil }
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) / day }.sorted()
        guard gaps[gaps.count / 2] <= 10 else { return nil }
        let days = Dictionary(grouping: starts, by: { calendar.component(.weekday, from: $0) }).mapValues(\.count)
        guard let top = days.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              Double(top.value) >= 0.75 * Double(starts.count) else { return nil }
        return .weekly(weekday: top.key)
    }

    /// A steady gap between visits, from a week to four months, three
    /// quarters of the gaps within a third of the usual one.
    static func every(_ starts: [Date]) -> Pattern? {
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) / day }
        guard gaps.count >= minVisits - 1 else { return nil }
        let median = gaps.sorted()[gaps.count / 2]
        guard (6...120).contains(median) else { return nil }
        let steady = gaps.filter { abs($0 - median) <= median / 3 }
        guard Double(steady.count) >= 0.75 * Double(gaps.count) else { return nil }
        return .every(days: median)
    }

    // MARK: Now

    /// Whether this aisle's time has come and it hasn't been bought yet.
    func isDue(now: Date, calendar: Calendar) -> Bool {
        let since = { (d: Date) in now.timeIntervalSince(d) / Self.day }
        switch pattern {
        case .monthly(let position, let spread):
            let length = Double(calendar.range(of: .day, in: .month, for: now)?.count ?? 30)
            let offset = Self.wrap(Self.position(of: now, calendar: calendar) - position) * length
            guard offset >= -(spread + Self.lead), offset <= spread else { return false }
            // Bought since this month's window opened: done for this month.
            if let p = lastPurchase, since(p) <= offset + spread + Self.lead { return false }
            return true
        case .weekly(let weekday):
            let today = calendar.component(.weekday, from: now)
            guard today == weekday || today % 7 + 1 == weekday else { return false }
            if let p = lastPurchase, since(p) < 2 { return false }
            return true
        case .every(let days):
            let s = since(last)
            guard s >= days - Self.lead - 1, s <= 2 * days else { return false }
            if let p = lastPurchase, since(p) < days - Self.lead - 1 { return false }
            return true
        }
    }

    /// How far from its usual time this aisle is now, in days (0 = right on it).
    func closeness(now: Date, calendar: Calendar) -> Double {
        switch pattern {
        case .monthly(let position, _):
            return abs(Self.wrap(Self.position(of: now, calendar: calendar) - position)) * 30.4
        case .weekly(let weekday):
            return calendar.component(.weekday, from: now) == weekday ? 0 : 1
        case .every(let days):
            return abs(now.timeIntervalSince(last) / Self.day - days)
        }
    }

    // MARK: Hour

    /// The hour (0–23) most of the last 90 days' activity falls around: at
    /// least 8 events, 40% of them within an hour of it.
    static func usualHour(_ events: [ShoppingRhythm.Event], now: Date, calendar: Calendar) -> Int? {
        let hours = events.filter { now.timeIntervalSince($0.at) <= 90 * day }.map { calendar.component(.hour, from: $0.at) }
        guard hours.count >= 8 else { return nil }
        let counts = Dictionary(grouping: hours, by: { $0 }).mapValues(\.count)
        let around = { (h: Int) in (-1...1).reduce(0) { $0 + (counts[(h + $1 + 24) % 24] ?? 0) } }
        guard let best = (0..<24).max(by: { around($0) != around($1) ? around($0) < around($1) : $0 > $1 }),
              Double(around(best)) >= 0.4 * Double(hours.count) else { return nil }
        return best
    }

    // MARK: Month arithmetic

    /// How far through its month a date is, 0 up to 1.
    static func position(of date: Date, calendar: Calendar) -> Double {
        let length = Double(calendar.range(of: .day, in: .month, for: date)?.count ?? 30)
        let c = calendar.dateComponents([.day, .hour], from: date)
        return (Double((c.day ?? 1) - 1) + Double(c.hour ?? 0) / 24) / length
    }

    /// A difference of positions, taken the short way round the month (−0.5…0.5).
    static func wrap(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 1)
        if x > 0.5 { x -= 1 }
        if x < -0.5 { x += 1 }
        return x
    }

    /// The circular mean of positions, nil when they spread evenly round the
    /// month (no point to centre on).
    static func circularMean(_ positions: [Double]) -> Double? {
        guard !positions.isEmpty else { return nil }
        let x = positions.reduce(0) { $0 + cos(2 * .pi * $1) }, y = positions.reduce(0) { $0 + sin(2 * .pi * $1) }
        let n = Double(positions.count)
        guard (x * x + y * y).squareRoot() / n > 0.3 else { return nil }
        let angle = atan2(y, x) / (2 * .pi)
        return angle < 0 ? angle + 1 : angle
    }
}
