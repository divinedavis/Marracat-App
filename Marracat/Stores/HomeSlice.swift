import Foundation

/// The few thousand products Home's first screen is built from, so a cold
/// launch shows Home without waiting for all 146k products and their indexes
/// (owner, 2026-10-11: "any chance we can speed up the loading of the app?").
/// The full catalog loads right behind it; until it lands, the screens that
/// need the whole catalog (search, departments, brand pages) wait for it as
/// they always did (CatalogStore.isComplete).
///
/// The slice is chosen so Home's rows come out the same from it as from the
/// whole catalog: every product of a premier brand (the carousel and the
/// circles step through each one's whole list), each brand's first product
/// and first in-stock one with a photo, and the heads of the lists Home
/// spreads across brands — deals, new arrivals and each department's in-stock
/// products — deep enough for the first round of `CatalogStore.spread`. Rows
/// that depend on the shopper (searches, views, restock) wait for the full
/// catalog.
///
/// It's written beside the catalog's binary copy (CatalogBinary), as a small
/// catalog of its own with the same date: by the build for the bundle
/// (scripts/catalog_binary/main.swift via catalog/make_compact.py), and by the app
/// for a catalog it downloads. Plain Foundation, so the build tool compiles it.
enum HomeSlice {
    /// The owner's permanent Home lineup (CatalogStore.premierBrandIDs).
    /// Bevel came off on 2026-09-22: Walker & Company sold it to Procter &
    /// Gamble, so it is no longer an independent brand to lead with.
    /// The list may be longer than the carousel's premier slots — the extras
    /// rotate through the same slots instead of adding pages.
    /// Curves by Sean Brown joined on 2026-09-28, featuring its totes only
    /// (see `premierFeatureKinds`). Telfar joined on 2026-10-10. On
    /// 2026-10-30 the owner took off Sweet July, The Renae Brand and RIPL EFEK
    /// and added Big Mouth Toothbrush. RIPL EFEK came back on 2026-11-02.
    /// On 2026-11-04 the owner cut the list to seven ("1, 2, 4, 7, 9, 8, and
    /// 11 - so 7 slots only"): KOBA, The Honey Pot, Frederick Benjamin and
    /// Big Mouth Toothbrush came off.
    static let premierBrandIDs = [
        "fear-of-god", "fenty-beauty", "cecred", "sienna-naturals",
        "telfar", "curves", "ripl-efek",
    ]

    /// Premier brands the owner wants shown by one kind of product: Home
    /// features only products whose title has this word. Curves sells rugs,
    /// chairs and bedding too, but leads with its tote.
    static let premierFeatureKinds = ["curves": "tote"]

    /// The most any of Home's spread rows takes (its 12-tile rows).
    static let rowLimit = 12
    /// Spare products per list, so a few hidden ones still leave a full row.
    static let spare = 1

    /// Positions in `c.products` of the slice, ascending (catalog order).
    static func indices(_ c: Catalog) -> [Int] {
        let products = c.products
        var keep = [Bool](repeating: false, count: products.count)
        let premier = Set(premierBrandIDs)

        // Premier brands whole; every brand's first product and first in-stock
        // one with a photo (carousel pages and brand circles); every
        // department's first product (Home lists departments that have any).
        var firstOfBrand = Set<String>(), firstShownOfBrand = Set<String>(), firstOfCategory = Set<String>()
        for (i, p) in products.enumerated() {
            if premier.contains(p.brand) { keep[i] = true }
            if firstOfBrand.insert(p.brand).inserted { keep[i] = true }
            if p.available, !p.images.isEmpty, firstShownOfBrand.insert(p.brand).inserted { keep[i] = true }
            if firstOfCategory.insert(p.category).inserted { keep[i] = true }
        }

        // The head of each brand's run in a ranked list. `spread` deals one
        // product per brand per round, so a row of `limit` needs at most
        // ceil(limit / brands) from each.
        func keepHeads(_ ranked: [Int32], limit: Int) {
            var brands = Set<String>()
            for i in ranked { brands.insert(products[Int(i)].brand) }
            let depth = (limit + max(brands.count, 1) - 1) / max(brands.count, 1) + spare
            var taken: [String: Int] = [:]
            for i in ranked {
                let b = products[Int(i)].brand
                let n = taken[b, default: 0]
                guard n < depth else { continue }
                taken[b] = n + 1
                keep[Int(i)] = true
            }
        }
        keepHeads(CatalogOrder.deals(products), limit: rowLimit)
        keepHeads(CatalogOrder.newArrivals(products, asOf: c.generatedAt), limit: 4)
        // Each department's in-stock products, in catalog order ("Top picks"
        // rows and the "Shop <department>" cards).
        var byCategory: [String: [Int32]] = [:]
        for (i, p) in products.enumerated() where p.available && !p.keptOffHome { byCategory[p.category, default: []].append(Int32(i)) }
        for list in byCategory.values { keepHeads(list, limit: rowLimit) }

        return keep.indices.filter { keep[$0] }
    }

    /// The slice as a catalog of its own: every brand, department and aisle,
    /// and the products `indices` picks.
    static func make(_ c: Catalog) -> Catalog {
        var slice = c
        slice.products = indices(c).map { c.products[$0] }
        return slice
    }

    // MARK: Files

    /// The bundled slice, written by the build beside the bundled binary.
    static func bundledURL(_ bundle: Bundle) -> URL? { bundle.url(forResource: "catalog-home", withExtension: "bin") }

    /// The app's own slice of a catalog it downloaded (or read from JSON).
    static var cacheURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("catalog-home-v1.bin")
    }

    /// The slice of exactly the catalog with this date, from the bundle or
    /// the app's cache; nil when neither matches (the launch then waits for
    /// the full catalog, as before).
    ///
    /// The bundle first, in the same order as CatalogBinary.load: a download
    /// can carry the same date as the bundled catalog with other contents
    /// (the catalog is edited after a build without being re-dated: dedupe,
    /// badges; see catalog/make_compact.py), and the slice must be cut from
    /// the catalog the launch then completes with, or Home reshuffles when
    /// the rest lands. Reading the cache first was also why HomeSliceTests
    /// failed on a simulator holding a download of the same date (build 135
    /// ship, 2026-10-12: failed, then passed on the retry).
    static func load(expecting generatedAt: String, bundle: Bundle) -> Catalog? {
        for url in [bundledURL(bundle), cacheURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped),
                  CatalogBinary.peekGeneratedAt(data) == generatedAt,
                  let c = CatalogBinary.decode(data), c.generatedAt == generatedAt, !c.products.isEmpty else { continue }
            return c
        }
        return nil
    }

    /// Writes the app's slice of `c` unless one for the same catalog is there.
    static func save(_ c: Catalog) {
        guard let url = cacheURL, !c.products.isEmpty else { return }
        if let existing = try? Data(contentsOf: url, options: .alwaysMapped),
           CatalogBinary.peekGeneratedAt(existing) == c.generatedAt { return }
        guard let data = try? CatalogBinary.encode(make(c)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension Product {
    /// Sex toys and their gear (the catalog files them all under Wellness >
    /// Sexual Wellness, catalog/department_rules.py `file_adult`). They stay
    /// in search, their department and their brand's page, but not on Home's
    /// shared rows, deals or new arrivals (owner, 2026-11-16): someone who
    /// never looked for them shouldn't meet them. Rows built from the
    /// shopper's own searches and views still show them.
    var keptOffHome: Bool { subs.contains("sexual-wellness") }
}

/// The catalog-wide orders Home and the grids read, as positions into the
/// products array (4 bytes each, instead of a 320-byte copy of every product).
/// Shared by CatalogStore and HomeSlice so the slice ranks exactly as the
/// whole catalog does. Ties keep catalog order, which is what the stable sort
/// these replaced did, so a subset in catalog order ranks the same way.
enum CatalogOrder {
    /// In-stock markdowns, deepest first.
    static func deals(_ products: [Product]) -> [Int32] {
        var out: [(Int32, Int)] = []
        for (i, p) in products.enumerated() where p.available && !p.keptOffHome {
            if let off = p.percentOff { out.append((Int32(i), off)) }
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// How far back "New" reaches.
    static let newArrivalDays = 30

    /// In stock and put on the brand's own site in the `newArrivalDays`
    /// before the catalog was built, newest first (owner, 2026-10-27: New
    /// "should be new products that appear on the Shopify brands' sites, not
    /// the entire catalog"). Counted back from the catalog's own date, not
    /// today, so the slice and the whole catalog always agree.
    static func newArrivals(_ products: [Product], asOf generatedAt: String) -> [Int32] {
        let since = newArrivalCutoff(generatedAt)
        var out: [(Int32, String)] = []
        for (i, p) in products.enumerated() where p.available && !p.keptOffHome {
            // ISO 8601 dates compare as text; the day is enough.
            guard let at = p.publishedAt, at.prefix(10) >= since else { continue }
            out.append((Int32(i), at))
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// "yyyy-MM-dd", `newArrivalDays` before the catalog's date (UTC).
    static func newArrivalCutoff(_ generatedAt: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let day = f.date(from: String(generatedAt.prefix(10))) ?? Date()
        return f.string(from: cal.date(byAdding: .day, value: -newArrivalDays, to: day) ?? day)
    }
}
