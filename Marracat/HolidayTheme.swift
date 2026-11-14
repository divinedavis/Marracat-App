import Foundation
import SwiftUI
import UIKit

/// Holidays and commemorations the app dresses up for (owner, 2026-10-20:
/// "make the app holiday themed (the splash screen, app logo, and events)").
/// Everything comes from Resources/holidays.json, which the App Store event
/// and art scripts read too, so a day's colours and dates live in one place.
///
/// On a holiday the splash disc, a ring round it and one line naming the day
/// change, the tab bar's pill fills with the day's colours, and (when the
/// shopper turns it on) the Home Screen icon switches. Event links open the
/// day's collection (`HolidayCollection`).
struct Holiday: Decodable, Identifiable, Equatable {
    struct DateRule: Decodable, Equatable {
        let month: Int
        let day: Int?
        /// ISO weekday, 1 = Monday ... 7 = Sunday.
        let weekday: Int?
        /// Which one in the month; -1 is the last.
        let nth: Int?
        let offset: Int?
    }

    struct Span: Decodable, Equatable {
        let from: Int
        let to: Int
    }

    let id: String
    let name: String
    let date: DateRule
    /// The days around the date the app wears it; nil for an event-only day.
    let theme: Span?
    let line: String
    let disc: String
    let ring: [String]
    /// An SF Symbol under the line, or "kinara" (drawn: seven candles).
    let mark: String?
    let icon: String
    let tab: [String]
    /// Extra splash motion: "fireworks" (New Year's; owner, 2026-10-21).
    let effect: String?
    /// The App Store event: its days around the date, which are also the
    /// days Home shows `rows`.
    let event: Event?
    /// Collection ids shown as Home rows while the event runs (owner,
    /// 2026-10-27: "a row or two in the app that has products that match
    /// the event").
    let rows: [String]?
    /// The two colours of the Home banner above those rows.
    let banner: [String]?

    struct Event: Decodable, Equatable {
        let badge: String?
        let name: String?
        let short: String?
        let from: Int
        let to: Int
    }

    /// The day in `year`, in the given calendar.
    func day(in year: Int, calendar: Calendar = .holidays) -> Date? {
        let base: Date
        if let d = date.day {
            guard let fixed = calendar.date(from: DateComponents(year: year, month: date.month, day: d)) else { return nil }
            base = fixed
        } else if let weekday = date.weekday, let nth = date.nth, nth != 0 {
            // Counted by hand: the nth from the first of the month, or back
            // from its last day for nth -1 (Memorial Day).
            let want = weekday % 7 + 1   // Calendar's weekday is 1 = Sunday; the JSON's is ISO.
            guard let first = calendar.date(from: DateComponents(year: year, month: date.month, day: 1)),
                  let days = calendar.range(of: .day, in: .month, for: first)?.count else { return nil }
            if nth > 0 {
                let lead = (want - calendar.component(.weekday, from: first) + 7) % 7
                guard let d = calendar.date(byAdding: .day, value: lead + (nth - 1) * 7, to: first) else { return nil }
                base = d
            } else {
                guard let last = calendar.date(byAdding: .day, value: days - 1, to: first) else { return nil }
                let back = (calendar.component(.weekday, from: last) - want + 7) % 7
                guard let d = calendar.date(byAdding: .day, value: -back, to: last) else { return nil }
                base = d
            }
            guard calendar.component(.month, from: base) == date.month else { return nil }
        } else {
            return nil
        }
        return calendar.date(byAdding: .day, value: date.offset ?? 0, to: base)
    }

    /// The days it themes the app in `year`, or nil for an event-only day.
    func themed(in year: Int, calendar: Calendar = .holidays) -> ClosedRange<Date>? {
        guard let theme, let day = day(in: year, calendar: calendar),
              let a = calendar.date(byAdding: .day, value: theme.from, to: day),
              let b = calendar.date(byAdding: .day, value: theme.to, to: day) else { return nil }
        return a...b
    }

    /// The days its event runs in `year`: when Home shows its rows.
    func eventDays(in year: Int, calendar: Calendar = .holidays) -> ClosedRange<Date>? {
        guard let event, let day = day(in: year, calendar: calendar),
              let a = calendar.date(byAdding: .day, value: event.from, to: day),
              let b = calendar.date(byAdding: .day, value: event.to, to: day) else { return nil }
        return a...b
    }

    var tabColors: [Color] { tab.map(Color.init(hex:)) }
}

struct HolidayCollection: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let queries: [String]
    let categories: [String]
    let shipsFrom: [String]?
    let bestSellers: Bool?
    /// A filtered collection (the Home event rows, 2026-10-27): products
    /// whose title matches `match` (case-insensitive) or which carry one of
    /// `tags`, narrowed by the rest. Without `match` or `tags` every product
    /// is a candidate (the deal rows).
    var match: String? = nil
    var tags: [String]? = nil
    var exclude: String? = nil
    var only: [String]? = nil
    var notCategories: [String]? = nil
    var notBrands: [String]? = nil
    /// Books must also have this in the title ("cookbook" in For the cook).
    var booksNeed: String? = nil
    var minOff: Int? = nil
    /// Past it is usually a placeholder compare-at price, not a markdown.
    var maxOff: Int? = nil
    /// In dollars.
    var maxPrice: Double? = nil
    /// Titles matching it come first.
    var lead: String? = nil
    /// "off": biggest markdown first; otherwise newest first.
    var order: String? = nil

    var isFiltered: Bool { match != nil || tags != nil || minOff != nil || maxPrice != nil }

    /// In-stock products with a photo that pass the filters, ranked, then
    /// dealt one brand at a time so a shop with hundreds of matches takes
    /// turns. Pure, so Home can run it off the main thread.
    func picks(from products: [Product], limit: Int = 200) -> [Product] {
        func rx(_ p: String?) -> NSRegularExpression? { p.flatMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) } }
        func hit(_ r: NSRegularExpression?, _ s: String) -> Bool {
            r?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        let inc = rx(match), exc = rx(exclude), first = rx(lead)
        let tagSet = Set((tags ?? []).map { $0.lowercased() })
        let notCats = Set(notCategories ?? []), notBrand = Set(notBrands ?? [])
        let onlyCats = only.map(Set.init)
        var kept: [(Product, Bool)] = []
        for p in products where p.available && !p.images.isEmpty {
            if let onlyCats, !onlyCats.contains(p.category) { continue }
            if notCats.contains(p.category) || notBrand.contains(p.brand) { continue }
            if let maxPrice, p.usdPrice >= maxPrice { continue }
            if minOff != nil || maxOff != nil {
                guard let off = p.percentOff, off >= (minOff ?? 0), off <= (maxOff ?? 100) else { continue }
            }
            if inc != nil || !tagSet.isEmpty {
                guard hit(inc, p.title) || p.tags.contains(where: { tagSet.contains($0.lowercased()) }) else { continue }
            }
            if hit(exc, p.title) { continue }
            if let booksNeed, p.category == "books", !p.title.localizedCaseInsensitiveContains(booksNeed) { continue }
            kept.append((p, hit(first, p.title)))
        }
        let ranked = kept.sorted { a, b in
            if order == "off" { return (a.0.percentOff ?? 0) > (b.0.percentOff ?? 0) }
            if a.1 != b.1 { return a.1 }
            return (a.0.publishedAt ?? "") > (b.0.publishedAt ?? "")
        }.map(\.0)
        return CatalogStore.spread(ranked, limit: limit)
    }
}

enum HolidayCalendar {
    private struct File: Decodable {
        let holidays: [Holiday]
        let collections: [HolidayCollection]
    }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static var holidays: [Holiday] { file?.holidays ?? [] }
    static var collections: [HolidayCollection] { file?.collections ?? [] }

    static func collection(_ id: String) -> HolidayCollection? { collections.first { $0.id == id } }

    /// The holidays whose event runs on `date` and have Home rows, the one
    /// ending soonest first, at most two (Thanksgiving and Black Friday
    /// overlap the gift season). `-HOLIDAY <id>` shows that day's alone.
    static func events(on date: Date = Date(), calendar: Calendar = .holidays) -> [Holiday] {
        if let forced { return holidays.filter { $0.id == forced && $0.rows != nil } }
        if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") { return [] }
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        var on: [(Holiday, Date)] = []
        for h in holidays where h.rows != nil {
            for y in [year - 1, year, year + 1] {
                if let range = h.eventDays(in: y, calendar: calendar), range.contains(day) { on.append((h, range.upperBound)) }
            }
        }
        return on.sorted { $0.1 < $1.1 }.prefix(2).map(\.0)
    }

    /// `-HOLIDAY <id>` (launch-argument defaults) dresses the app for one day
    /// whatever the date: UI tests, screenshots and previewing a theme.
    private static var forced: String? { UserDefaults.standard.string(forKey: "HOLIDAY") }

    /// The holiday the app wears on `date`, by the shopper's calendar day.
    /// Overlapping themes go to the shortest, so a single day beats the
    /// season around it (Thanksgiving inside the gift season).
    static func current(on date: Date = Date(), calendar: Calendar = .holidays) -> Holiday? {
        if let forced { return forced == "none" ? nil : holidays.first { $0.id == forced } }
        // UI tests see the everyday app unless they name a day: a run on a
        // holiday mustn't change what every other test looks for.
        if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") { return nil }
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        var best: (Holiday, Int)?
        for h in holidays {
            for y in [year - 1, year, year + 1] {
                guard let range = h.themed(in: y, calendar: calendar), range.contains(day) else { continue }
                let length = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 0
                if best == nil || length < best!.1 { best = (h, length) }
            }
        }
        return best?.0
    }
}

extension Calendar {
    /// Gregorian in the device's time zone: a holiday starts at the shopper's
    /// midnight, wherever they are.
    static var holidays: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }
}

extension Color {
    /// "#RRGGBB".
    init(hex: String) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// The Home Screen icon. On by default (owner, 2026-10-20: "holiday app
/// icons should be auto on by default and the users can turn it off in
/// their settings"); iOS shows its own "You have changed the icon" alert on
/// each switch, which no app can hide.
enum HolidayIcon {
    static let settingKey = "holidayIcons"

    static var enabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    /// The icon this day should have: the holiday's while one is on and the
    /// setting is, the everyday one otherwise.
    static func wanted(on date: Date = Date()) -> String? {
        guard enabled, let h = HolidayCalendar.current(on: date) else { return nil }
        return h.icon
    }

    /// Switch to the wanted icon if it isn't already showing. Only while the
    /// app is active: iOS refuses the change from the background.
    @MainActor
    static func apply() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, app.applicationState == .active else { return }
        // UI tests never get the system's icon alert over what they check.
        guard !ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") else { return }
        let want = wanted()
        guard app.alternateIconName != want else { return }
        app.setAlternateIconName(want) { _ in }
    }
}

extension CatalogStore {
    /// A holiday collection's products: each query's best matches and each
    /// department's, plus brands shipping from the named regions, mixed
    /// across brands with what's in stock first. Capped so a page stays quick.
    func products(inCollection id: String) -> [Product] {
        guard let c = HolidayCalendar.collection(id) else { return [] }
        if c.isFiltered {
            // Filtering 150,000 titles takes a moment: once per catalog.
            let key = "\(id)|\(catalog.generatedAt)|\(catalog.products.count)"
            if let hit = collectionCache[key] { return hit }
            let picked = c.picks(from: catalog.products)
            collectionCache[key] = picked
            return picked
        }
        var seen = Set<String>()
        var picked: [Product] = []
        func take<S: Sequence>(_ products: S, _ limit: Int) where S.Element == Product {
            var n = 0
            for p in products where p.available && n < limit && seen.insert(p.id).inserted {
                picked.append(p)
                n += 1
            }
        }
        for q in c.queries { take(search(q), 40) }
        for cat in c.categories { take(interleaveBrands(Array(products(in: cat))), 60) }
        if let regions = c.shipsFrom {
            let ids = Set(brands.filter { regions.contains($0.shipsFrom ?? "") }.map(\.id))
            take(interleaveBrands(catalog.products.filter { ids.contains($0.brand) }), 400)
        }
        if c.bestSellers == true {
            take(catalog.products.filter { $0.bestRank != nil }.sorted { $0.bestRank! < $1.bestRank! }, 200)
        }
        return inStockFirst(interleaveBrands(Array(picked.prefix(400))))
    }
}
