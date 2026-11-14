import Foundation

/// When this shopper was last here, for Home's "New since your last visit"
/// and its refresh on coming back (owner, 2026-11-08: returning shoppers
/// opened Home 4–5 days a week and saw the same page; "lets refresh and do a
/// new since your last visit").
///
/// A visit ends when the app goes to the background. Coming back counts as a
/// new visit once `gap` has passed, so a quick trip to Messages doesn't
/// reshuffle Home under the shopper.
enum VisitClock {
    static let gap: TimeInterval = 30 * 60
    private static let leftKey = "visit.leftAt"
    private static let sinceKey = "visit.since"
    /// Set once this time in front has been counted, so asking again (Home
    /// asks each time its tab reappears) can't start another visit. Holds
    /// this run's id, so a relaunch after the app was killed in front is
    /// still an arrival.
    private static let countedKey = "visit.countedIn"
    private static let run = UUID().uuidString

    /// The app went to the background: this visit ends now.
    static func left(at now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: leftKey)
        defaults.removeObject(forKey: countedKey)
    }

    /// The app is in front (launch or return). True when this starts a new
    /// visit: the first launch ever, or `gap` or more since the last one
    /// ended. A new visit makes the end of the last one `since`.
    ///
    /// Only the first ask after coming to the front counts: Home asks every
    /// time its tab reappears (onChange(of: scenePhase, initial: true)), and
    /// each of those had been a "new visit" (a 400 ms rebuild, a reshuffle
    /// and a jump to the top on every Home tap) on a first launch, or once
    /// the app had been in front for half an hour (owner, 2026-11-11: "i
    /// think there is a delay when i touch on the home button").
    @discardableResult
    static func arrived(at now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard defaults.string(forKey: countedKey) != run else { return false }
        defaults.set(run, forKey: countedKey)
        if let forced = forcedHoursAgo {
            defaults.set(now.addingTimeInterval(-forced * 3600).timeIntervalSince1970, forKey: sinceKey)
            return true
        }
        let left = defaults.double(forKey: leftKey)
        guard left == 0 || now.timeIntervalSince1970 - left >= gap else { return false }
        if left > 0 { defaults.set(left, forKey: sinceKey) } else { defaults.removeObject(forKey: sinceKey) }
        return true
    }

    /// When the last visit ended, for "New since your last visit"; nil on the
    /// first visit ever.
    static func since(defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: sinceKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// UI tests: `-LAST_VISIT_HOURS_AGO 48` makes every launch a return after
    /// that long.
    private static var forcedHoursAgo: Double? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LAST_VISIT_HOURS_AGO"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func date(_ published: String) -> Date? { iso.date(from: published) ?? isoFraction.date(from: published) }

    /// The products for "New since your last visit": in stock, published
    /// after `since`, from `candidates` (the catalog's new arrivals, newest
    /// first). Brands this shopper looked at, saved or bought from come first,
    /// then everyone else's, each spread one brand at a time.
    static func newSince(_ since: Date, candidates: some Sequence<Product>, favoredBrands: Set<String>,
                         hidden: Set<String>, limit: Int = 12, mix: BrandMix? = nil) -> [Product] {
        var favored: [Product] = [], rest: [Product] = []
        for p in candidates where p.available && !hidden.contains(p.id) {
            guard let at = p.publishedAt.flatMap(date), at > since else { continue }
            if favoredBrands.contains(p.brand) { favored.append(p) } else { rest.append(p) }
        }
        let first = CatalogStore.spread(favored, limit: limit, mix: mix)
        return first + CatalogStore.spread(rest, limit: limit - first.count, mix: mix)
    }
}
