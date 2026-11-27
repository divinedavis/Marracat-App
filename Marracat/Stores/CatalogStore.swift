import Foundation
import Observation

@Observable
final class CatalogStore {
    private(set) var catalog: Catalog
    /// Filtered holiday collections, keyed by id and catalog (HolidayTheme.swift).
    @ObservationIgnored var collectionCache: [String: [Product]] = [:]
    /// Home can draw: its slice of the catalog (HomeSlice) or the whole of it
    /// has loaded, or an empty fallback if no file can be read.
    private(set) var isReady = false
    /// The whole catalog and its indexes have loaded. Until then only Home's
    /// slice is here, and the screens that need every product — search,
    /// departments, brand pages, the other tabs — wait (FullCatalogGate).
    private(set) var isComplete = false
    private(set) var brandsByID: [String: Brand] = [:]
    private(set) var categoriesByID: [String: Category] = [:]
    /// Each product's position in `catalog.products`. The lookups below hold
    /// positions, not copies: a copy of every product in each of five indexes
    /// was ~250 MB of the launch's memory on 146k products (2026-10-11).
    @ObservationIgnored private var productIndex: [String: Int32] = [:]
    /// This shopper's personal Home rows as last shown (HomeRowsCache), read
    /// beside Home's slice so they're on Home's first frame. Home takes them
    /// once.
    @ObservationIgnored var launchHomeRows: HomeRows?
    /// Shop by style's boards as last worked out (StyleBoardsCache), read
    /// with them. ShopByStyleRow takes them once.
    @ObservationIgnored var launchStyleBoards: StyleBoards?

    /// Changes whenever the products do, including when Home's slice gives
    /// way to the whole catalog under the same date. For memos kept outside.
    var stamp: String { catalog.generatedAt + (isComplete ? "" : "~home") }

    /// Starts empty and fills itself a moment later, in two steps: Home's
    /// slice (a few thousand products, tens of milliseconds), then the whole
    /// catalog, read beside it. Reading and indexing all 146k
    /// products took ~1.4 s of every cold launch, all of it before Home could
    /// draw (owner, 2026-10-11: "any chance we can speed up the loading").
    init(bundle: Bundle = .main, synchronously: Bool = false) {
        catalog = Self.empty
        Self.corruptCacheForTests()
        if synchronously {
            install(Self.prepare(Self.bestLocal(bundle).catalog, complete: true))
        } else {
            // Read AND index off the main thread: building the lookups froze
            // the launch animation mid-flight. All four reads start here, not
            // inside the main-actor task below: that task's body waits for
            // the main thread, which is busy bringing the app up for the
            // first ~0.7 s, so the whole catalog (which the launch cover
            // waits for) used to start that late. Launch to Home had crept
            // from 1.9 s to 2.12 s as the catalog grew to 198k products and
            // failed the ship's ceiling (2026-11-20).
            let rows = Task.detached(priority: .userInitiated) { HomeRowsCache.load() }
            let styles = Task.detached(priority: .userInitiated) { StyleBoardsCache.load() }
            let slice = Task.detached(priority: .userInitiated) { () -> Indexed? in
                guard !ProcessInfo.processInfo.arguments.contains("-NO_HOME_SLICE") else { return nil }
                let t0 = Date()
                guard let c = HomeSlice.load(expecting: Self.onDiskGeneratedAt(bundle), bundle: bundle) else { return nil }
                let indexed = Self.prepare(c, complete: false)
                LaunchTiming.log.notice("launch: home slice \(Int(Date().timeIntervalSince(t0) * 1000), privacy: .public) ms, \(c.products.count, privacy: .public) products")
                return indexed
            }
            // The whole catalog, beside the slice: the cover waits for it.
            let whole = Task.detached(priority: .userInitiated) {
                let t0 = Date()
                let loaded = Self.bestLocal(bundle)
                let t1 = Date()
                let indexed = Self.prepare(loaded.catalog, complete: true)
                LaunchTiming.log.notice("launch: catalog read \(Int(t1.timeIntervalSince(t0) * 1000), privacy: .public) ms, indexed \(Int(Date().timeIntervalSince(t1) * 1000), privacy: .public) ms, \(loaded.catalog.products.count, privacy: .public) products, done at \(LaunchTiming.sinceStart(), privacy: .public) ms")
                return (indexed, loaded.fromBinary)
            }
            Task { @MainActor [weak self] in
                self?.launchHomeRows = await rows.value
                self?.launchStyleBoards = await styles.value
                if let slice = await slice.value { self?.apply(slice) }
                let (ready, fromBinary) = await whole.value
                self?.apply(ready)
                LaunchTiming.log.notice("launch: catalog complete at \(LaunchTiming.sinceStart(), privacy: .public) ms")
                // Read from JSON (a download the binary wasn't written for):
                // the next launch reads the binary copy and its slice instead.
                // Written a few seconds on, at background priority, behind Home.
                guard !fromBinary else { return }
                let loaded = ready.catalog
                Task.detached(priority: .background) {
                    try? await Task.sleep(for: .seconds(5))
                    CatalogBinary.save(loaded)
                    HomeSlice.save(loaded)
                }
            }
        }
    }

    /// A store holding exactly `catalog`, indexed: tests compare Home built
    /// from the slice with Home built from the whole catalog.
    init(catalog: Catalog, complete: Bool = true) {
        self.catalog = Self.empty
        install(Self.prepare(catalog, complete: complete))
    }

    /// UI tests pass -BAD_CATALOG_CACHE to leave a corrupt download in the
    /// cache, before anything reads it: the storefront must still come up.
    /// -OFFLINE_CATALOG opens the bundled catalog, never one an earlier run
    /// on the same simulator downloaded (2026-10-18: the live catalog
    /// restocked the Curves totes and two sold-out tests read it).
    private static func corruptCacheForTests() {
        if ProcessInfo.processInfo.arguments.contains("-OFFLINE_CATALOG"), let url = cacheURL {
            try? FileManager.default.removeItem(at: url)
            CatalogDelta.forget()
        }
        if ProcessInfo.processInfo.arguments.contains("-BAD_CATALOG_CACHE"), let url = cacheURL {
            try? Data("{ not a catalog".utf8).write(to: url, options: .atomic)
        }
    }

    /// The catalog this build shipped with, unless an earlier run downloaded a
    /// newer one. A fresh install of a newer build must not be dragged back to
    /// a stale download, hence the comparison.
    ///
    /// Each copy is ~67MB of JSON and decoding one is most of the launch
    /// splash, so the dates are read from the files' first bytes and only the
    /// newer copy is decoded. Decoding both to compare them was doubling it.
    private static func bestLocal(_ bundle: Bundle) -> (catalog: Catalog, fromBinary: Bool) {
        // A binary copy of exactly the catalog it would open (CatalogBinary):
        // no JSON to parse, strings shared. The build bundles one for the
        // bundled catalog, so even the first launch after an update reads it;
        // the app writes its own for a catalog it downloaded.
        if !ProcessInfo.processInfo.arguments.contains("-NO_CATALOG_BINARY"),
           let binary = CatalogBinary.load(expecting: onDiskGeneratedAt(bundle), bundle: bundle) {
            return (binary, true)
        }
        if let bundledDate = bundledGeneratedAt(bundle) {
            guard let cache = cacheURL, FileManager.default.fileExists(atPath: cache.path) else {
                return (loadBundled(bundle), false)
            }
            if let cachedDate = generatedAt(cache) {
                if cachedDate <= bundledDate { return (loadBundled(bundle), false) }
                return (loadCached() ?? loadBundled(bundle), false)
            }
        }
        // A file that doesn't open with its date: decode both and compare.
        let bundled = loadBundled(bundle)
        if let cached = loadCached(), cached.generatedAt > bundled.generatedAt { return (cached, false) }
        return (bundled, false)
    }

    /// A JSON catalog in the bundle: only a plain `xcodebuild` of a checkout
    /// without the binary has one. Builds ship catalog.bin alone (2026-10-18):
    /// the 105 MB JSON beside it was install size for a fallback the build's
    /// own binary already covers.
    private static func bundledURL(_ bundle: Bundle) -> URL? {
        bundle.url(forResource: "catalog-compact", withExtension: "json")
            ?? bundle.url(forResource: "catalog", withExtension: "json")
    }

    /// The bundled catalog's date: the JSON's first bytes, else the binary's header.
    private static func bundledGeneratedAt(_ bundle: Bundle) -> String? {
        if let json = bundledURL(bundle) { return generatedAt(json) }
        guard let url = CatalogBinary.bundledURL(bundle),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return CatalogBinary.peekGeneratedAt(data)
    }

    /// `generated_at` from the first bytes of a catalog file. The build script
    /// and the published catalog both write it as the first key; anything
    /// else returns nil and the caller decodes in full.
    static func generatedAt(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 96) else { return nil }
        return generatedAt(head: head)
    }

    /// The same, from bytes already in memory — a downloaded catalog.
    static func generatedAt(head: Data) -> String? {
        guard case let text = String(decoding: head.prefix(96), as: UTF8.self),
              let key = text.range(of: #"^\s*\{\s*"generated_?[aA]t"\s*:\s*""#, options: .regularExpression),
              let end = text[key.upperBound...].firstIndex(of: "\"") else { return nil }
        let date = String(text[key.upperBound..<end])
        return date.isEmpty ? nil : date
    }

    private static let empty = Catalog(generatedAt: "", categories: [], subcategories: [],
                                       brands: [], products: [])

    /// A catalog with its lookups already built, so swapping one in is a
    /// handful of assignments rather than a pass over every product. Every
    /// list is positions into `catalog.products`.
    private struct Indexed {
        let catalog: Catalog
        /// The whole catalog, not Home's slice of it.
        let complete: Bool
        let brands: [String: Brand]
        let categories: [String: Category]
        let products: [String: Int32]
        let subcategories: [String: Subcategory]
        let subCounts: [String: Int]
        let byBrand: [String: [Int32]]
        let byCategory: [String: [Int32]]
        let sortedBrands: [Brand]
        // Home's whole-catalog sorts, done here off the main thread: under the
        // splash they held it for half a second after the catalog landed.
        let deals: [Int32]
        let newArrivals: [Int32]
        let discover: (day: Int, products: [Int32])
    }

    /// A product's searchable text, lowercased. Made for the products a search
    /// visits (the word index's candidates), or for all of them once the first
    /// search that has to read every product asks (`searchTextForAll`): kept
    /// for every product from launch, it was a lowercased copy of every title
    /// and tag list held for searches most launches never run (2026-10-11).
    struct SearchText {
        let title: String
        let rest: String
        /// Folded as the query is (SearchWords.fold): "Women's" reads "womens".
        init(_ p: Product) {
            title = SearchWords.fold(p.title)
            rest = SearchWords.fold(([p.productType ?? ""] + p.tags).joined(separator: " "))
        }
    }

    /// Every lookup and sort Home needs, built off the main thread. The
    /// independent pieces run side by side on all cores: one after another
    /// they were ~380 ms of the splash on 120k products (2026-10-02).
    private static func prepare(_ c: Catalog, complete: Bool) -> Indexed {
        let day = today
        let all = c.products
        var products: [String: Int32] = [:], subCounts: [String: Int] = [:]
        var byBrand: [String: [Int32]] = [:], byCategory: [String: [Int32]] = [:]
        var deals: [Int32] = [], newArrivals: [Int32] = [], discover: [Int32] = []
        let jobs: [() -> Void] = [
            { products.reserveCapacity(all.count)
              // The first of a repeated id wins, as the old Dictionary(uniquingKeysWith:)
              // did: walked backwards, the last write is the first product, with
              // one lookup each instead of two.
              for i in all.indices.reversed() { products[all[i].id] = Int32(i) } },
            { subCounts = all.reduce(into: [String: Int]()) { counts, p in
                for leaf in p.subs { counts["\(p.category):\(leaf)", default: 0] += 1 }
            } },
            // Grouping keeps catalog order, so these match what a filter returned.
            { for (i, p) in all.enumerated() { byBrand[p.brand, default: []].append(Int32(i)) } },
            { for (i, p) in all.enumerated() { byCategory[p.category, default: []].append(Int32(i)) } },
            { deals = CatalogOrder.deals(all) },
            { newArrivals = CatalogOrder.newArrivals(all, asOf: c.generatedAt) },
            { discover = makeDiscover(all, day: day) },
        ]
        // Each job writes only its own variable, and concurrentPerform returns
        // after all of them finish.
        jobs.withUnsafeBufferPointer { run in
            DispatchQueue.concurrentPerform(iterations: run.count) { run[$0]() }
        }
        return Indexed(catalog: c, complete: complete,
                       brands: Dictionary(c.brands.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                       categories: Dictionary(c.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                       products: products,
                       subcategories: Dictionary(c.subcategories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                       subCounts: subCounts, byBrand: byBrand, byCategory: byCategory,
                       sortedBrands: c.brands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                       deals: deals, newArrivals: newArrivals, discover: (day, discover))
    }

    private static var today: Int { Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0 }

    /// Hash each product once, then sort by the key: hashing inside the
    /// comparator ran ~n log n string hashes on every Home render.
    private static func makeDiscover(_ products: [Product], day: Int) -> [Int32] {
        let keyed: [(UInt64, Int32)] = CatalogOrder.gather(products) { p, i in
            p.available && !p.keptOffHome ? (hash(p.id, seed: day), i) : nil
        }
        return keyed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Swaps a prepared catalog in. Home's slice, then the whole catalog under
    /// the same date; a whole catalog always replaces a slice, whatever its date.
    @MainActor
    private func apply(_ ready: Indexed) {
        isReady = true
        guard ready.catalog.generatedAt >= catalog.generatedAt || (ready.complete && !isComplete) else { return }
        // A newer publish supersedes what FreshCatalog fetched over the old one.
        if ready.catalog.generatedAt > catalog.generatedAt, !catalog.generatedAt.isEmpty { FreshCatalog.shared.clear() }
        catalogGeneration += 1
        install(ready)
        ProductFacets.reset()
        // Search's indexes are for the whole catalog; Home's slice never searches.
        if ready.complete { warmTitleIndex() }
    }

    private func install(_ ready: Indexed) {
        catalog = ready.catalog
        brandsByID = ready.brands
        BrandCountry.update(from: ready.brands.values)
        FX.update(from: ready.brands.values)
        categoriesByID = ready.categories
        productIndex = ready.products
        subcategoriesByID = ready.subcategories
        subCounts = ready.subCounts
        productsByBrand = ready.byBrand
        productsByCategory = ready.byCategory
        sortedBrands = ready.sortedBrands
        // Every memo was built from the catalog we just replaced. Missing one
        // is how Home ended up ordering its brands off an empty catalog.
        cachedTerms = nil
        cachedSegments = nil
        cachedWordIndex = nil
        searchWordIndex = nil
        lastCompletions = nil
        dealsIndex = ready.deals
        newArrivalsIndex = ready.newArrivals
        discoverMemo = ready.discover
        searchTextMemo = nil
        searchMemo = [:]
        discoverRowMemo = nil
        isReady = true
        isComplete = ready.complete
    }

    /// Where the app looks for a newer catalog than the one in the build. The
    /// host lives here and nowhere else, so moving it is a one-line change.
    /// v3 carries every product a brand has in stock, without the description
    /// and spare images a product page fetches for itself — which is what
    /// makes whole stores affordable. v2 stays published, capped, for builds
    /// that read those fields straight out of the catalog.
    static let remoteURL = URL(string: "https://marracat.com/catalog-v3.json")!

    static var cacheURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("catalog-v3.json")
    }

    private static func decode(_ data: Data) throws -> Catalog {
        try decodeInParallel(data, snakeCase: !data.starts(with: Data(#"{"generatedAt""#.utf8)))
    }

    /// The catalog, with its products decoded in parallel chunks.
    ///
    /// One JSONDecoder over 120k products took ~750 ms of the ~3.3 s splash
    /// (2026-10-02). The products array is the file's last key, and in it
    /// `},{"id":"` only ever separates two products (a quote inside a string is
    /// escaped, and variant ids are numbers), so the array is cut at that
    /// pattern near N even points and each piece decoded on its own core. If
    /// the file isn't shaped like that, or any piece fails, it decodes whole.
    static func decodeInParallel(_ data: Data, snakeCase: Bool) throws -> Catalog {
        func decoder() -> JSONDecoder {
            let d = JSONDecoder()
            if snakeCase { d.keyDecodingStrategy = .convertFromSnakeCase }
            return d
        }
        func whole() throws -> Catalog { try decoder().decode(Catalog.self, from: data) }
        let pieces = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        guard pieces > 1, data.startIndex == 0, data.count > 1_000_000,
              let key = data.range(of: Data(#","products":["#.utf8)) else { return try whole() }
        let open = key.upperBound - 1
        // The array closes the file: `]` then the object's `}`.
        var end = data.count - 1
        while end > open, [0x20, 0x0A, 0x0D, 0x09].contains(data[end]) { end -= 1 }
        guard data[end] == UInt8(ascii: "}"), data[end - 1] == UInt8(ascii: "]") else { return try whole() }
        let close = end - 1
        let boundary = Data(#"},{"id":""#.utf8)
        var cuts: [Int] = []
        for k in 1..<pieces {
            let target = open + (close - open) * k / pieces
            if let r = data.range(of: boundary, in: target..<close), cuts.last.map({ r.lowerBound + 2 > $0 }) ?? true {
                cuts.append(r.lowerBound + 2)   // the next product's "{"
            }
        }
        var ranges: [Range<Int>] = []
        var start = open + 1
        for cut in cuts { ranges.append(start..<(cut - 1)); start = cut }   // cut - 1 is the comma
        ranges.append(start..<close)

        var head = Data(data[..<(open + 1)])
        head.append(UInt8(ascii: "]"))
        head.append(data[(close + 1)...])
        var catalog = try decoder().decode(Catalog.self, from: head)

        var parts = [[Product]?](repeating: nil, count: ranges.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: ranges.count) { i in
            var chunk = Data([UInt8(ascii: "[")])
            chunk.append(data[ranges[i]])
            chunk.append(UInt8(ascii: "]"))
            let products = try? decoder().decode([Product].self, from: chunk)
            lock.lock(); parts[i] = products; lock.unlock()
        }
        guard parts.allSatisfy({ $0 != nil }) else { return try whole() }
        catalog.products = parts.flatMap { $0! }
        return catalog
    }

    private static func loadCached() -> Catalog? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let catalog = try? decode(data),
              // Never swap in something empty: a truncated download would wipe
              // the storefront.
              !catalog.products.isEmpty, !catalog.brands.isEmpty else { return nil }
        return catalog
    }

    /// Fetches the published catalog and keeps it for next launch. Brands and
    /// prices then change without an App Store build.
    ///
    /// It deliberately does NOT swap into the running session. A catalog
    /// arriving mid-browse reshuffles Home under the shopper and changes the
    /// results they're reading — the same complaint that made Home pin its
    /// page in the first place. The exception is a session that has no catalog
    /// at all, where anything beats an empty storefront.
    ///
    /// Anything that goes wrong — offline, a bad response, a half-written file
    /// — leaves the current catalog alone.
    @MainActor
    func refreshFromRemote(session: URLSession = .shared) async {
        guard !checkingRemote else { return }
        checkingRemote = true
        defer { checkingRemote = false }
        lastRemoteCheck = .now
        // Against the whole local catalog, not Home's slice of it or the empty
        // store of the first moments: "newer than" and the interests scan's
        // "new since" both need it.
        while !isComplete { try? await Task.sleep(for: .milliseconds(250)) }
        let current = catalog.generatedAt
        // A newer catalog already waits on disk for the next launch: this
        // session's catalog is no base for a delta, and the whole file would
        // come down again. The background refresh takes it from there.
        guard Self.onDiskGeneratedAt() <= current else { return }
        guard let fetched = await Self.downloadNewer(than: current, base: catalog, session: session) else { return }
        // Interests: what's new or back in this catalog, against what the
        // shopper described (Interests.swift).
        let previous = catalog
        Task.detached(priority: .utility) {
            await InterestsStore.scan(before: InterestsStore.availability(previous), current: fetched)
        }
        // Only a session with nothing to show adopts it straight away.
        if catalog.products.isEmpty {
            apply(await Task.detached(priority: .utility) { Self.prepare(fetched, complete: true) }.value)
        }
    }

    @ObservationIgnored private var lastRemoteCheck: Date?
    @ObservationIgnored private var checkingRemote = false

    /// Back in the foreground after `interval`: ask for a newer catalog again,
    /// not only at launch (2026-10-18, owner: check stock more often). The
    /// catalog refreshes every 3 h and a delta is ~0.5 MB; it's kept for the
    /// next launch, as at launch. Nothing until the launch's own check ran.
    @MainActor
    func refreshIfStale(now: Date = .now, after interval: TimeInterval = 30 * 60, session: URLSession = .shared) async {
        guard let last = lastRemoteCheck, now.timeIntervalSince(last) >= interval else { return }
        await refreshFromRemote(session: session)
    }

    /// The catalog this phone would open with next: the cached download if
    /// it's newer than the bundle, else the bundle. Read from the files' first
    /// bytes, without decoding.
    static func onDiskGeneratedAt(_ bundle: Bundle = .main) -> String {
        let bundled = bundledGeneratedAt(bundle) ?? ""
        let cached = cacheURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? generatedAt($0) : nil } ?? ""
        return max(bundled, cached)
    }

    /// Download the published catalog if it's newer than `current`, check it
    /// decodes whole, and cache it for the next launch. Used at launch, behind
    /// the shopper. Nil when nothing newer arrived; anything that goes wrong
    /// leaves the cache alone.
    static func downloadNewer(than current: String, base: Catalog? = nil, session: URLSession = .shared) async -> Catalog? {
        // A delta against the catalog in hand first (CatalogDelta): ~0.5 MB
        // instead of 13.9. `base` is that catalog, whole.
        switch await deltaCheck(than: current, session: session) {
        case .current: return nil
        case .delta(let data):
            if let base, base.generatedAt == current {
                let applied = await Task.detached(priority: .utility) { () -> Catalog? in
                    guard let file = CatalogDelta.decode(data), file.generatedAt > current,
                          let c = CatalogDelta.apply(file, to: base) else { return nil }
                    keep(c, fingerprint: file.to)
                    return c
                }.value
                if let applied { return applied }
            }
        case .unavailable: break
        }
        guard let (data, tag) = await fetchVerified(than: current, session: session) else { return nil }
        // Decode it at low priority, behind whatever the
        // shopper is doing, only to make sure it's whole before caching it.
        let fetched = await Task.detached(priority: .utility) { () -> Catalog? in
            guard let c = try? Self.decode(data), !c.products.isEmpty, !c.brands.isEmpty,
                  c.generatedAt > current else { return nil }
            // Its binary copy and Home's slice first, then the JSON: the
            // JSON's date is what the next launch opens, and a launch that
            // finds it without its binary decodes 105 MB of JSON instead
            // (2026-10-18). Killed in between, the next launch just opens
            // the catalog it had.
            CatalogBinary.save(c)
            HomeSlice.save(c)
            if let url = Self.cacheURL, (try? data.write(to: url, options: .atomic)) != nil {
                CatalogDelta.remember(CatalogDelta.fingerprint(data), for: c.generatedAt)
            }
            return c
        }.value
        if let tag { UserDefaults.standard.set(tag, forKey: Self.etagKey) }
        return fetched
    }

    /// The background refresh's half (2026-10-18): fetch a newer catalog,
    /// check its signature and keep the file, without decoding 155k products
    /// in an app-refresh window on battery. Decoding it, its binary copy and
    /// Home's slice wait for BackgroundRefresh's charging task
    /// (`finishPendingDownload`); a launch before that reads the JSON, as one
    /// always could. True when a newer catalog was kept.
    static func downloadForLater(than current: String, session: URLSession = .shared) async -> Bool {
        switch await deltaCheck(than: current, session: session) {
        case .current: return false
        case .delta(let data):
            // Kept as it came; the charging task applies it to the catalog on disk.
            guard let url = CatalogDelta.pendingURL, (try? data.write(to: url, options: .atomic)) != nil else { return false }
            UserDefaults.standard.set(current, forKey: pendingFromKey)
            return true
        case .unavailable: break
        }
        guard let (data, tag) = await fetchVerified(than: current, session: session),
              let url = cacheURL, (try? data.write(to: url, options: .atomic)) != nil else { return false }
        if let date = generatedAt(head: data) { CatalogDelta.remember(CatalogDelta.fingerprint(data), for: date) }
        if let pending = CatalogDelta.pendingURL { try? FileManager.default.removeItem(at: pending) }
        if let tag { UserDefaults.standard.set(tag, forKey: Self.etagKey) }
        // What the interests scan compares the new catalog against.
        UserDefaults.standard.set(current, forKey: pendingFromKey)
        return true
    }

    /// The charging task's half: the kept download decoded, checked, and
    /// written as the binary and Home's slice; with each product's stock in
    /// the catalog it replaced (read before the new binary is written over
    /// it), for the interests scan. Nil when nothing is waiting (or it's
    /// broken, which removes it: the next launch opens the previous catalog).
    static func finishPendingDownload(bundle: Bundle = .main) -> (catalog: Catalog, before: [String: Bool]?)? {
        guard let from = UserDefaults.standard.string(forKey: pendingFromKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingFromKey)
        if let pending = CatalogDelta.pendingURL, let data = try? Data(contentsOf: pending) {
            // A delta: applied to the catalog the phone opens, if that's still
            // the one it was fetched against.
            try? FileManager.default.removeItem(at: pending)
            let base = bestLocal(bundle).catalog
            guard base.generatedAt == from, let file = CatalogDelta.decode(data), file.generatedAt > from,
                  let c = CatalogDelta.apply(file, to: base) else {
                // The next refresh takes the whole catalog instead of this delta again.
                CatalogDelta.forget()
                return nil
            }
            let before = CatalogBinary.availability(expecting: from, bundle: bundle)
            keep(c, fingerprint: file.to)
            return (c, before)
        }
        guard let url = cacheURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let c = loadCached() else {
            try? FileManager.default.removeItem(at: url)
            UserDefaults.standard.removeObject(forKey: etagKey)
            return nil
        }
        let before = CatalogBinary.availability(expecting: from, bundle: bundle)
        CatalogBinary.save(c)
        HomeSlice.save(c)
        return (c, before)
    }

    private static let pendingFromKey = "catalog.v3.pendingFrom"

    /// A catalog built from a delta, kept as a download is: its binary copy
    /// and Home's slice, then the JSON whose date the next launch opens, then
    /// its fingerprint for the next delta.
    private static func keep(_ c: Catalog, fingerprint: String) {
        CatalogBinary.save(c)
        HomeSlice.save(c)
        guard let url = cacheURL, let json = try? CatalogDelta.cacheJSON(c),
              (try? json.write(to: url, options: .atomic)) != nil else { return }
        CatalogDelta.remember(fingerprint, for: c.generatedAt)
    }

    enum DeltaCheck { case current, delta(Data), unavailable }

    /// Whether a delta can bring the cached catalog dated `current` up to
    /// date: `.current` when the newest published version is the one held,
    /// `.delta` with its checked bytes, else `.unavailable` and the caller
    /// fetches the whole catalog as before.
    static func deltaCheck(than current: String, session: URLSession) async -> DeltaCheck {
        let cached = cacheURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? generatedAt($0) : nil }
        guard let fp = CatalogDelta.fingerprint(of: current, cached: cached, bundled: bundledGeneratedAt(.main)) else {
            return .unavailable
        }
        func get(_ url: URL) async -> Data? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsConstrainedNetworkAccess = false
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        guard let list = await get(CatalogDelta.manifestsURL) else { return .unavailable }
        let versions = String(decoding: list, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        if versions.first == fp { return .current }
        guard versions.contains(fp), let data = await get(CatalogDelta.url(from: fp)),
              let date = generatedAt(head: data), date > current,
              await CatalogSignature.verify(data, from: CatalogDelta.url(from: fp), session: session) else { return .unavailable }
        return .delta(data)
    }

    /// The published catalog's bytes and ETag, when it's newer than `current`
    /// and signed by the publisher.
    private static func fetchVerified(than current: String, session: URLSession) async -> (Data, String?)? {
        var request = URLRequest(url: Self.remoteURL)
        request.timeoutInterval = 20
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        // The app shares a large URLCache with the image loader, which would
        // hand back a cached catalog without ever asking the server — the
        // freshness check has to reach the origin. The ETag below keeps that
        // cheap: an unchanged catalog answers 304 with no body.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // ~105 MB: not on Low Data Mode (2026-10-18). The phone keeps the
        // catalog it has; the background refresh fetches it on Wi-Fi.
        request.allowsConstrainedNetworkAccess = false
        if let tag = UserDefaults.standard.string(forKey: Self.etagKey) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else { return nil }   // 304: what we have is current
        let tag = http.value(forHTTPHeaderField: "ETag")
        // Most launches end here. The published catalog is usually the one this
        // build bundled, and the check used to decode all 67 MB to learn that,
        // then skip saving the ETag because it wasn't newer — so every launch
        // downloaded and decoded it again, for seconds of CPU and a few hundred
        // MB just as Home appeared (2026-09-28). The date is the file's first key.
        if let date = Self.generatedAt(head: data), date <= current {
            if let tag { UserDefaults.standard.set(tag, forKey: Self.etagKey) }
            return nil
        }
        // Genuinely newer: it must carry the publisher's signature before it
        // is trusted (CatalogSignature). A missing or bad one keeps what we
        // have and doesn't store the ETag, so the next launch asks again.
        guard await CatalogSignature.verify(data, from: Self.remoteURL, session: session) else { return nil }
        return (data, tag)
    }

    private static let etagKey = "catalog.v3.etag"

    private static func loadBundled(_ bundle: Bundle) -> Catalog {
        // The build bundles the compact catalog; the full one beside it in the
        // repo is what the scripts and the website read, and is excluded from
        // the app target. Older checkouts that only have the full one still
        // work, which keeps a plain `xcodebuild test` honest.
        guard let url = bundledURL(bundle), let data = try? Data(contentsOf: url) else {
            // The shipped build: its catalog is the binary, whatever the cache holds.
            return CatalogBinary.bundledURL(bundle)
                .flatMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
                .flatMap(CatalogBinary.decode) ?? empty
        }
        // make_compact.py writes the bundle with the app's own key spelling;
        // converting 100k products' keys from snake case was half the read.
        // A checkout that only has the full, snake-case catalog still decodes.
        do {
            return try decodeInParallel(data, snakeCase: !data.starts(with: Data(#"{"generatedAt""#.utf8)))
        } catch {
            assertionFailure("catalog.json failed to decode: \(error)")
            return empty
        }
    }



    /// The owner's permanent Home lineup. Which brands these are doesn't change
    /// with prices, stock or the catalog; the order they appear in and the
    /// product each one shows change on every refresh (see `BrandMix`). The
    /// list lives in HomeSlice, which bundles every product they have.
    static let premierBrandIDs = HomeSlice.premierBrandIDs

    /// Premier brands the owner wants shown by one kind of product (HomeSlice).
    static let premierFeatureKinds = HomeSlice.premierFeatureKinds

    var premierBrands: [Brand] { Self.premierBrandIDs.compactMap(brand) }

    func isPremier(_ brandID: String) -> Bool { Self.premierBrandIDs.contains(brandID) }

    var categories: [Category] { catalog.categories.filter { !products(in: $0.id).isEmpty } }
    /// Sorted once per catalog: Home and every product grid ask for this on
    /// each render, and a localized sort of 500+ names adds up.
    var brands: [Brand] { _ = catalog; return sortedBrands }

    func brand(_ id: String) -> Brand? { brandsByID[id] }
    func category(_ id: String) -> Category? { categoriesByID[id] }
    /// A product as fresh as this phone has it: the store's live copy where
    /// FreshCatalog fetched one, a brand-new arrival, else the catalog's.
    /// Off the main thread (Siri's background search) it's the catalog's.
    func product(_ id: String) -> Product? {
        let base = baseProduct(id)
        guard Thread.isMainThread else { return base }
        return MainActor.assumeIsolated {
            if let base { return FreshCatalog.shared.current(base) }
            return FreshCatalog.shared.arrival(id)
        }
    }

    /// The catalog's own copy, without FreshCatalog's.
    func baseProduct(_ id: String) -> Product? {
        let products = catalog.products   // read through observation
        return productIndex[id].map { products[Int($0)] }
    }

    /// Looked up, not filtered: Home asks for every brand's products on each
    /// render, and scanning the whole catalog per brand froze the launch once
    /// the catalog passed 500 brands and 24k products.
    func products(in category: String) -> ProductList {
        ProductList(catalog.products, productsByCategory[category] ?? [])
    }

    /// In-stock first, then the rest — a grid that opens with sold-out rows
    /// reads as a broken shop.
    func inStockFirst(_ products: [Product]) -> [Product] {
        products.filter(\.available) + products.filter { !$0.available }
    }

    func products(for brand: String) -> ProductList {
        ProductList(catalog.products, productsByBrand[brand] ?? [])
    }

    /// What a category breaks down into on Browse — its aisles, biggest first.
    /// These are curated in catalog/taxonomy.py and linked to products at build
    /// time, so "Face Wash & Cleansers" is a real place, not a guess at a title.
    func subcategories(in category: String, limit: Int = 24) -> [Subcategory] {
        catalog.subcategories
            .filter { $0.category == category }
            .sorted { productCount($0.id) > productCount($1.id) }
            .prefix(limit)
            .map { $0 }
    }

    func subcategory(_ id: String) -> Subcategory? { subcategoriesByID[id] }

    func products(inSub id: String) -> [Product] {
        guard let sub = subcategoriesByID[id] else { return [] }
        let leaf = String(id.drop(while: { $0 != ":" }).dropFirst())
        return products(in: sub.category).filter { $0.subs.contains(leaf) }
    }

    func productCount(_ subID: String) -> Int { subCounts[subID] ?? 0 }

    @ObservationIgnored private var subcategoriesByID: [String: Subcategory] = [:]
    @ObservationIgnored private var subCounts: [String: Int] = [:]
    @ObservationIgnored private var productsByBrand: [String: [Int32]] = [:]
    @ObservationIgnored private var sortedBrands: [Brand] = []
    @ObservationIgnored private var productsByCategory: [String: [Int32]] = [:]

    /// Words that describe what a thing is made of or looks like.
    private static let materials: Set<String> = [
        "leather", "silk", "satin", "matte", "ceramic", "diamond", "velvet", "linen", "cotton", "denim",
        "metallic", "reversible", "body", "face", "hair", "skin", "glass", "wool", "canvas",
    ]

    /// In-stock markdowns, deepest first.
    // Home re-renders whenever the tab bar shows or hides, and each of these
    // sorted the whole catalog every time — long enough, at 24k products, to
    // hold the keyboard up after a search suggestion was tapped. They depend
    // only on the catalog, so they're computed once per catalog (`prepare`).
    var deals: ProductList { ProductList(catalog.products, dealsIndex) }

    var newArrivals: ProductList { ProductList(catalog.products, newArrivalsIndex) }

    @ObservationIgnored private var dealsIndex: [Int32] = []
    @ObservationIgnored private var newArrivalsIndex: [Int32] = []
    @ObservationIgnored private var discoverMemo: (day: Int, products: [Int32])?
    @ObservationIgnored private var searchMemo: [String: [Product]] = [:]
    @ObservationIgnored private var searchTextMemo: [SearchText]?
    @ObservationIgnored private var discoverRowMemo: (key: String, products: [Product])?

    /// Home's "Discover more" grid: today's shuffle, reordered by this launch's
    /// mix, hidden items removed, spread across brands. Shuffling and spreading
    /// 20k products on every Home render is what made the tab bar lag, and the
    /// answer only changes with the day, the refresh round, or what's hidden.
    /// Empty until the whole catalog is in: a shuffle of Home's slice would be
    /// a different grid a second later. `departments`: the shopper's own
    /// (owner, 2026-11-09: "if they never purchase dog food or search for it
    /// we should never show it"); empty for all.
    func discoverRow(mix: BrandMix, hidden: Set<String>, limit: Int, departments: Set<String> = []) -> [Product] {
        guard isComplete else { return [] }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let key = "\(day)|\(mix.key)|\(limit)|\(hidden.sorted().joined(separator: ","))|\(departments.sorted().joined(separator: ","))"
        let source = discover
        if let memo = discoverRowMemo, memo.key == key { return memo.products }
        // `discover` is already today's random order, so its head is as random
        // a pool as the whole; reshuffling all 86k in-stock products for a
        // 40-tile grid held the main thread under the launch splash.
        let pool = departments.isEmpty ? Array(source.prefix(max(4000, limit * 50)))
            : Array(source.lazy.filter { departments.contains($0.category) }.prefix(max(4000, limit * 50)))
        let row = spread(mix.shuffle(pool).filter { !hidden.contains($0.id) }, limit: limit)
        discoverRowMemo = (key, row)
        return row
    }

    /// What a department's top picks on Home draw on: in stock, and none of
    /// the products kept off Home (`Product.keptOffHome`).
    func homePicks(in category: String) -> [Product] {
        products(in: category).filter { $0.available && !$0.keptOffHome }
    }

    /// A stable-per-day shuffle so "Discover more" changes daily, not per scroll.
    var discover: ProductList {
        let day = Self.today
        let products = catalog.products
        if let memo = discoverMemo, memo.day == day { return ProductList(products, memo.products) }
        let shuffled = Self.makeDiscover(products, day: day)
        discoverMemo = (day, shuffled)
        return ProductList(products, shuffled)
    }

    /// One in-stock product per brand, round-robin, so no single brand floods a row.
    /// With a `mix`, brands take turns leading the row and each brand shows a
    /// different product every round (Home's pull-to-refresh).
    func spread(_ products: [Product], limit: Int, mix: BrandMix? = nil) -> [Product] {
        Self.spread(products, limit: limit, mix: mix)
    }

    /// `spread`, reading nothing of the store's: safe off the main thread.
    static func spread(_ products: [Product], limit: Int, mix: BrandMix? = nil) -> [Product] {
        var buckets: [String: [Product]] = [:]
        var order: [String] = []
        for p in products {
            if buckets[p.brand] == nil { order.append(p.brand) }
            buckets[p.brand, default: []].append(p)
        }
        if let mix {
            order = mix.arrange(order, id: { $0 }, step: limit)
            for (b, ps) in buckets {
                let k = mix.round % ps.count
                buckets[b] = Array(ps[k...] + ps[..<k])
            }
        }
        var out: [Product] = []
        var round = 0
        while out.count < limit {
            var added = false
            for b in order where round < buckets[b]!.count {
                out.append(buckets[b]![round]); added = true
                if out.count == limit { break }
            }
            if !added { break }
            round += 1
        }
        return out
    }

    /// Spreads a ranked list across brands so no brand takes row after row:
    /// each slot goes to the best remaining product whose brand hasn't come up
    /// in the last two. Ranking otherwise survives — a brand only waits its
    /// turn when it just had one — and products that rank the same fall in a
    /// stable-per-day brand order, so the same brand doesn't always lead.
    func interleaveBrands(_ products: [Product], seed: Int? = nil) -> [Product] {
        interleaveBrands(products.map { ($0, 0) }, seed: seed)
    }

    func interleaveBrands(_ ranked: [(Product, Int)], seed: Int? = nil) -> [Product] {
        Self.interleaveBrands(ranked, seed: seed)
    }

    static func interleaveBrands(_ ranked: [(Product, Int)], seed: Int? = nil) -> [Product] {
        // One brand: nothing to spread, but the ranking still holds. A search
        // whose matches were all one brand's came back in catalog order, so
        // "pink top women" could lead with a plain Classic Top over Womens
        // Pink Top (found matching the website's search, 2026-10-31). Stable,
        // so equal scores keep their order.
        guard Set(ranked.map { $0.0.brand }).count > 1 else {
            guard ranked.contains(where: { $0.1 != ranked[0].1 }) else { return ranked.map(\.0) }
            return ranked.enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map(\.element.0)
        }
        let s = seed ?? Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        // Brands by number and products by position, so the work below reads
        // arrays of numbers. Looking brands up by name in every comparison
        // and at every slot made a search with thousands of matches from
        // hundreds of brands slow: "candle", 17,000 matches, took 2.7 s in
        // the simulator, nearly all of it here (2026-11-20). The order that
        // comes out is the one this always made.
        var number: [String: Int] = [:]
        var hashes: [UInt64] = []          // each brand's hash, computed once
        var brandOf: [Int] = []            // each product's brand
        brandOf.reserveCapacity(ranked.count)
        for (p, _) in ranked {
            if let k = number[p.brand] { brandOf.append(k); continue }
            number[p.brand] = hashes.count
            brandOf.append(hashes.count)
            hashes.append(Self.hash(p.brand, seed: s))
        }
        let scores = ranked.map(\.1)
        // Best first; equal scores in the day's brand order, then by id.
        let order = ranked.indices.sorted { a, b in
            if scores[a] != scores[b] { return scores[a] > scores[b] }
            let (ha, hb) = (hashes[brandOf[a]], hashes[brandOf[b]])
            return ha != hb ? ha < hb : ranked[a].0.id < ranked[b].0.id
        }
        var buckets = [[Int]](repeating: [], count: hashes.count)
        for i in order { buckets[brandOf[i]].append(i) }
        var head = [Int](repeating: 0, count: buckets.count)
        // The score of the product each brand has waiting.
        var waiting = buckets.map { scores[$0[0]] }
        var active = Array(buckets.indices)
        var out: [Product] = []
        out.reserveCapacity(ranked.count)
        var recent: [Int] = []
        while !active.isEmpty {
            // The brand with the best product waiting, and the best among
            // brands that haven't just been shown, in one pass.
            var best = -1, bestScore = Int.min, bestHash = UInt64.max
            var fresh = -1, freshScore = Int.min, freshHash = UInt64.max
            for k in active {
                let score = waiting[k], h = hashes[k]
                if best < 0 || score > bestScore || (score == bestScore && h < bestHash) {
                    (best, bestScore, bestHash) = (k, score, h)
                }
                if !recent.contains(k), fresh < 0 || score > freshScore || (score == freshScore && h < freshHash) {
                    (fresh, freshScore, freshHash) = (k, score, h)
                }
            }
            // Once only one brand has anything left, the tail is unavoidably its own.
            let spread = fresh >= 0 ? fresh : best
            // Spreading brands breaks ties between equally good matches; it must
            // never put a weaker one above a stronger one. A search for vitamin
            // D showed a Vitamin C serum between the two real results, because
            // both real ones came from the same brand.
            let b = bestScore > waiting[spread] ? best : spread
            out.append(ranked[buckets[b][head[b]]].0)
            head[b] += 1
            if head[b] == buckets[b].count {
                active.remove(at: active.firstIndex(of: b)!)
            } else {
                waiting[b] = scores[buckets[b][head[b]]]
            }
            recent.append(b)
            if recent.count > 2 { recent.removeFirst() }
        }
        return out
    }

    func search(_ query: String) -> [Product] {
        _ = catalog
        let key = query.lowercased()
        if let hit = searchMemo[key] { return hit }
        let results = runSearch(query)
        // A handful of recent queries is all Home and the overlay re-ask for.
        if searchMemo.count >= 24 { searchMemo.removeAll() }
        searchMemo[key] = results
        return results
    }

    /// Memory warning: the caches that rebuild on demand go (MemoryPressure).
    func shed() {
        searchTextMemo = nil
        searchMemo.removeAll()
    }

    /// Every product's search text, made on the first search that needs all
    /// of it and kept for this catalog.
    private func searchTextForAll() -> [SearchText] {
        if let searchTextMemo, searchTextMemo.count == catalog.products.count { return searchTextMemo }
        let made = Self.searchTexts(catalog.products)
        searchTextMemo = made
        return made
    }

    /// Every product's search text, made on every core.
    static func searchTexts(_ products: [Product]) -> [SearchText] {
        var out = [SearchText?](repeating: nil, count: products.count)
        let slices = products.count < 2000 ? 1 : CatalogBinary.pieces
        out.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: slices) { slice in
                for i in (products.count * slice / slices)..<(products.count * (slice + 1) / slices) {
                    buffer[i] = SearchText(products[i])
                }
            }
        }
        return out.map { $0! }
    }

    /// What search reads, copied out of the store so Siri and Shortcuts
    /// (AppIntents/) can search on a background thread. The arrays are
    /// copy-on-write, so taking one copies nothing.
    struct SearchSnapshot: @unchecked Sendable {
        let catalog: Catalog
        let brands: [String: Brand]
        let categories: [String: Category]
        let wordIndex: SearchWordIndex?

        /// The same results, in the same order, as `CatalogStore.search`.
        func search(_ query: String) -> [Product] {
            CatalogStore.runSearch(query, catalog: catalog, brands: brands, categories: categories,
                                   wordIndex: wordIndex, allText: { catalog.products.map(SearchText.init) })
        }
    }

    var searchSnapshot: SearchSnapshot {
        SearchSnapshot(catalog: catalog, brands: brandsByID, categories: categoriesByID, wordIndex: searchWordIndex)
    }

    /// When a search finds nothing because of one word no product uses —
    /// "bulk t shirts" has no "bulk" anywhere — drop words until something
    /// matches, the way Amazon shows "No results for X. Results for Y."
    /// Each round keeps the shorter query with the most hits; on a tie the
    /// earlier word goes, since leading words are usually modifiers and the
    /// thing being shopped for comes last. Never down to words that only name
    /// a business ("xennial co" is not "co"). Nil when the full query already
    /// matches or nothing does.
    func relaxedSearch(_ query: String) -> (query: String, results: [Product])? {
        // "independent" is no word to keep while dropping others (dropOwnership).
        var tokens = SearchWords.dropOwnership(SearchWords.tokens(query))
        guard !tokens.isEmpty, search(query).isEmpty else { return nil }
        // A brand's name run together ("fearofgod") is that brand: the split
        // below can't make "of", which is under three letters.
        let squashed = SearchWords.squash(query)
        if squashed.count >= 4, let b = brands.first(where: { SearchWords.squash($0.name) == squashed }) {
            let results = search(b.name)
            if !results.isEmpty { return (b.name, results) }
        }
        // First the same words spelled as products spell them: "musthavejoy"
        // -> "must have joy", "hodie" -> "hoodie" (owner, 2026-10-15).
        if let index = searchWordIndex, index.generatedAt == catalog.generatedAt,
           let fixed = SearchWords.respell(query, uses: index.uses, vocab: { index.vocabulary }) {
            let results = search(fixed)
            if !results.isEmpty { return (fixed, results) }
            tokens = SearchWords.dropOwnership(SearchWords.tokens(fixed))
        }
        guard tokens.count > 1 else { return nil }
        while tokens.count > 1 {
            var best: (tokens: [String], results: [Product])?
            for i in tokens.indices {
                var shorter = tokens
                shorter.remove(at: i)
                if SearchWords.onlyFiller(shorter) { continue }
                let results = search(shorter.joined(separator: " "))
                if best == nil || results.count > best!.results.count { best = (shorter, results) }
            }
            guard let best else { return nil }
            if !best.results.isEmpty { return (best.tokens.joined(separator: " "), best.results) }
            tokens = best.tokens
        }
        return nil
    }

    /// What a search that found nothing, or only a guess, probably meant
    /// (SearchWords.alternatives): brands spelled close to it, a looser
    /// respelling, its own words. Each finds products. Empty until the word
    /// index is ready.
    func alternatives(_ query: String, excluding: String? = nil) -> [String] {
        guard let index = searchWordIndex, index.generatedAt == catalog.generatedAt else { return [] }
        return SearchWords.alternatives(query, brandNames: brands.map(\.name), vocab: { index.vocabulary },
                                        count: { self.search($0).count }, excluding: excluding)
    }

    struct PersonalPicks: Equatable {
        let phrase: String
        let searched: Bool
        let products: [Product]
    }

    /// "Picked for you" above a short search (owner, 2026-11-03: someone who
    /// has been searching or looking at charms and searches "fruit" sees a
    /// charm or two): up to two products matching the search together with
    /// something the shopper has been looking at (SearchWords.interests),
    /// from the departments that interest is shopped in (so a felting kit
    /// is no bag charm), and not already among the search's first two. Nil
    /// for a search of three or more words, one saying "independent" or one
    /// that is a brand's whole name. Reads only what is on this device.
    func personalPicks(_ query: String, recentSearches: [String], recentlyViewed: [String]) -> PersonalPicks? {
        let said = SearchWords.tokens(query)
        let words = SearchWords.dropOwnership(SearchWords.splitAudience(said).words)
        guard (1...2).contains(words.count), !SearchWords.saysOwnership(said),
              !brands.contains(where: { SearchWords.namesBrand(words, brandName: $0.name).full }) else { return nil }
        // Each viewed product's first aisle: its name for the phrase, and
        // which aisles go by that name, where its picks must come from.
        var aisleIDs: [String: Set<String>] = [:]
        let aisles = recentlyViewed.prefix(20).compactMap { id -> String? in
            guard let p = product(id), let leaf = p.subs.first, let sub = subcategory("\(p.category):\(leaf)") else { return nil }
            aisleIDs[sub.name, default: []].insert("\(p.category):\(leaf)")
            return sub.name
        }
        // Nothing looked at yet (most first visits): no searches run at all.
        let interests = SearchWords.interests(query: query, recentSearches: recentSearches, viewedAisles: aisles)
        guard !interests.isEmpty else { return nil }
        // In the order the results page shows them: sold-out last.
        let top = Set(inStockFirst(search(query)).prefix(2).map(\.id))
        for interest in interests {
            let sample = inStockFirst(search(interest.phrase)).prefix(200)
            guard !sample.isEmpty else { continue }
            var byDepartment: [String: Int] = [:]
            for p in sample { byDepartment[p.category, default: 0] += 1 }
            let departments = Set(byDepartment.filter { $0.value * 5 >= sample.count }.keys)
            // A viewed aisle ("Keychains & Charms") picks from that aisle only:
            // its name's words also fit charm earrings.
            let inAisle = interest.searched ? nil : aisleIDs[interest.phrase]
            let picks = inStockFirst(search(query + " " + interest.phrase))
                .filter { p in
                    p.available && departments.contains(p.category) && !top.contains(p.id)
                        && (inAisle.map { ids in p.subs.contains { ids.contains("\(p.category):\($0)") } } ?? true)
                }
                .prefix(2)
            if !picks.isEmpty { return PersonalPicks(phrase: interest.phrase, searched: interest.searched, products: Array(picks)) }
        }
        return nil
    }

    private func runSearch(_ query: String) -> [Product] {
        Self.runSearch(query, catalog: catalog, brands: brandsByID, categories: categoriesByID,
                       wordIndex: searchWordIndex, allText: { self.searchTextForAll() })
    }

    static func runSearch(_ query: String, catalog: Catalog, brands brandsByID: [String: Brand],
                                  categories categoriesByID: [String: Category], wordIndex searchWordIndex: SearchWordIndex?,
                                  allText searchTextForAll: () -> [SearchText]) -> [Product] {
        // "women"/"men" narrow by who a product is marked for rather than
        // being words it must hold (owner, 2026-10-15: "pink shirt women").
        let (said, audience) = SearchWords.splitAudience(SearchWords.tokens(query))
        // "independent" is who every brand is, not a word to require (owner, 2026-11-01).
        let tokens = SearchWords.dropOwnership(said)
        guard !tokens.isEmpty else { return [] }
        // A colour word also finds a product that comes in that colour: "pink
        // top" finds a top with a Pink variant or a Blush title. Only beside
        // other words, which pick the candidates; alone it reads as text.
        let colorFamily: [String: String] = tokens.count > 1
            ? Dictionary(tokens.compactMap { t in ProductFacets.family(ofWord: t).map { (t, $0) } }, uniquingKeysWith: { a, _ in a })
            : [:]
        // Other words for a search word (SearchWords.alternates): "keyring"
        // finds a keychain, and beside other words "fruit" finds a cherry.
        // A word with others can't narrow candidates by itself.
        let alternates: [String: [String]] = Dictionary(tokens.compactMap { t in
            let alts = SearchWords.alternates(SearchWords.singular(t), beside: tokens.count > 1)
            return alts.isEmpty ? nil : (t, alts)
        }, uniquingKeysWith: { a, _ in a })
        let indexed = tokens.filter { colorFamily[$0] == nil && alternates[$0] == nil }
        // "vitamin d" is one thing, not a product with a "vitamin" and a "d" in
        // it. A title that says the whole phrase outranks anything that merely
        // holds the words apart.
        // Singular words, so "bag charms" says the phrase "Bag Charm" does.
        let phrase = said.count > 1 ? said.map(SearchWords.singular).joined(separator: " ") : ""
        var scored: [(Product, Int)] = []
        let brandNames = brandsByID.mapValues { SearchWords.fold($0.name) }
        let categoryNames = categoriesByID.mapValues { SearchWords.fold($0.name) }
        // Only products that could match every word: the index's smallest
        // candidate list, in catalog order. Scoring below is unchanged, so the
        // results are the same as checking every product (2026-10-02).
        let products = catalog.products
        let order: [Int] = searchWordIndex.flatMap { ix in
            ix.generatedAt == catalog.generatedAt ? ix.candidates(for: indexed.map(SearchWords.singular)) : nil
        } ?? Array(products.indices)
        // A search that visits most of the catalog (before the index lands, or
        // a very common word) reads the text made once for every product; the
        // rest lowercase just the products they visit.
        let prepared: [SearchText]? = order.count > products.count / 4 ? searchTextForAll() : nil
        for i in order {
            let p = products[i]
            let brandName = brandNames[p.brand] ?? ""
            let categoryName = categoryNames[p.category] ?? ""
            let text = prepared?[i] ?? SearchText(p)
            let title = text.title
            let rest = text.rest
            var score = 0
            var allMatched = true
            for t in tokens {
                let singular = SearchWords.singular(t)
                if Self.matchesTerm(title, singular) { score += 4 }
                else if Self.matchesTerm(brandName, singular) { score += 3 }
                else if Self.matchesTerm(categoryName, singular) { score += 2 }
                else if Self.matchesTerm(rest, singular) { score += 1 }
                // A word the search only starts — "butter" in "Buttercream", or
                // a word still being typed. Kept, but never near the top.
                //
                // One or two letters are excluded: the "d" of "vitamin d"
                // starts "Dark", "Day" and "Detangling" too, which is how a
                // search for vitamin D came back holding Vitamin C serums.
                // A letter that short carries no signal as a prefix.
                else if singular.count >= 3,
                        [title, brandName, categoryName, rest].contains(where: { Self.startsWord($0, singular) }) {
                    score += 1
                } else if let alts = alternates[t], alts.contains(where: { Self.matchesTerm(title, $0) }) {
                    score += 3
                } else if let alts = alternates[t], alts.contains(where: { Self.matchesTerm(rest, $0) }) {
                    score += 1
                } else if let family = colorFamily[t], ProductFacets.colorFamilies(p).contains(family) {
                    score += 2
                } else { allMatched = false; break }
            }
            if allMatched {
                let fit = SearchWords.audienceFit(title + " " + rest, audience)
                guard fit >= 0 else { continue }
                if !phrase.isEmpty, Self.matchesTerm(title, phrase) { score += 10 }
                scored.append((p, score + fit * 2 + (p.available ? 1 : 0)))
            }
        }
        // A search naming a brand leads with it: "fraiche" puts Fraîche
        // Studios before Crème Fraîche (SearchWords.leadsWithBrand).
        scored = Self.rankBrandsAndDepartments(scored, tokens: tokens, brandNames: brandNames)
        // Results come back mixed across brands, so a brand with a deep catalog
        // can't own page after page of one search.
        return Self.interleaveBrands(scored)
    }

    /// A brand the search names leads (leadWithBrands); otherwise a
    /// department the search barely touches goes below the rest, so a felting
    /// kit is no bag charm (SearchWords.offDepartments).
    static func rankBrandsAndDepartments(_ scored: [(Product, Int)], tokens: [String], brandNames: [String: String]) -> [(Product, Int)] {
        let led = leadWithBrands(scored, tokens: tokens, brandNames: brandNames)
        if led.map(\.1) != scored.map(\.1) { return led }
        var counts: [String: Int] = [:]
        for (p, _) in scored { counts[p.category, default: 0] += 1 }
        let off = SearchWords.offDepartments(counts, total: scored.count, words: tokens.count)
        guard !off.isEmpty else { return scored }
        return scored.map { off.contains($0.0.category) ? ($0.0, $0.1 - SearchWords.offDepartmentPenalty) : $0 }
    }

    /// The scores with SearchWords.brandLeadBonus added to the products of
    /// every brand the search names and leads with.
    static func leadWithBrands(_ scored: [(Product, Int)], tokens: [String], brandNames: [String: String]) -> [(Product, Int)] {
        var named: [String: (matches: Bool, full: Bool, words: Int)] = [:]
        for (id, name) in brandNames {
            let n = SearchWords.namesBrand(tokens, brandName: name)
            if n.matches { named[id] = n }
        }
        guard !named.isEmpty else { return scored }
        var own: [String: Int] = [:]
        for (p, _) in scored where named[p.brand] != nil { own[p.brand, default: 0] += 1 }
        let lead = Set(named.keys.filter { SearchWords.leadsWithBrand(named[$0]!, own: own[$0] ?? 0, others: scored.count - (own[$0] ?? 0)) })
        guard !lead.isEmpty else { return scored }
        return scored.map { lead.contains($0.0.brand) ? ($0.0, $0.1 + SearchWords.brandLeadBonus) : $0 }
    }

    /// What the search field suggests as you type, Amazon-style: categories and
    /// kinds of product that match — trending ones first, then the rest by how
    /// many brand best-sellers they hold — then brands, then product titles.
    func suggestions(_ query: String, limit: Int = 10) -> [SearchSuggestion] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, isComplete, !searchIndexWarming else { return [] }
        let sq = Self.singular(q)
        // Then sentence finishing: what the typed words run on to in real
        // product titles ("laundry detergent" → "… sheets", "… pods"), the way
        // Amazon completes a query. A finish that is also a curated aisle or
        // kind keeps that term's destination.
        let termsByKey = Dictionary(suggestionTerms.map { (Self.matchKey($0.text), $0) }, uniquingKeysWith: { a, _ in a })
        // A brand typed without its spaces ("fearofgod") matches its name run
        // together, from the third letter on.
        let squashed = SearchWords.squash(q)
        let exactBrands = brands.filter { b in
            let n = b.name.lowercased()
            return n.hasPrefix(q) || n.contains(" " + q)
                || (squashed.count >= 3 && SearchWords.squash(n).hasPrefix(squashed))
        }
        // Then brands whose name holds every typed word, in any order and not
        // side by side: "aqua water" finds Aqua Equity Water, "skincare koba"
        // finds KOBA skincare. Words under two letters are ignored so "a" or
        // "&" can't match half the list. Brand rows stay capped below, and
        // exact matches keep the lead.
        let typedWords = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
        let exactIDs = Set(exactBrands.map(\.id))
        let wordBrands = typedWords.count < 2 ? [] : brands.filter { b in
            guard !exactIDs.contains(b.id) else { return false }
            let nameWords = b.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return typedWords.allSatisfy { w in nameWords.contains { $0.hasPrefix(w) } }
        }
        let brandHits = exactBrands + wordBrands
        let brandRows = min(2, brandHits.count)
        // Trending picks still lead (live best-seller data), then the finishes.
        var finished = Set<String>()
        var out: [SearchSuggestion] = suggestionTerms
            .filter { $0.trending && $0.matches(q, sq) }
            .sorted { $0.heat > $1.heat }
            .prefix(max(0, limit - 2))
            .map { t in
                finished.insert(Self.matchKey(t.text))
                return SearchSuggestion(text: t.text, kind: t.kind, image: t.image, trending: true,
                                        subtitle: subtitle(for: t))
            }
        out += completions(query).filter { !finished.contains(Self.matchKey($0.text)) }
            // Never negative: eight trending "shea" terms plus two brands
            // made it -1, and prefix(-1) crashed the app on every "shea"
            // (2026-10-20; the arithmetic dates from 2026-09-21).
            .prefix(max(0, limit - 1 - brandRows - out.count)).map { c in
            if let t = termsByKey[Self.matchKey(c.text)] {
                return SearchSuggestion(text: t.text, kind: t.kind, image: t.image ?? c.image, trending: t.trending,
                                        subtitle: subtitle(for: t))
            }
            return SearchSuggestion(text: c.text, kind: .query, image: c.image, trending: false,
                                    subtitle: c.category.flatMap { category($0)?.name })
        }
        finished.formUnion(out.map { Self.matchKey($0.text) })
        out += suggestionTerms
            .filter { $0.matches(q, sq) && finished.insert(Self.matchKey($0.text)).inserted }
            .sorted { ($0.trending ? 1 : 0, $0.heat, $0.count) > ($1.trending ? 1 : 0, $1.heat, $1.count) }
            .prefix(max(0, limit - 2))
            .map { t in
                SearchSuggestion(text: t.text, kind: t.kind, image: t.image, trending: t.trending,
                                 subtitle: subtitle(for: t))
            }
        out = Array(out.prefix(max(0, limit - 1 - brandRows)))
        for b in brandHits.prefix(brandRows) {
            out.append(SearchSuggestion(text: b.name, kind: .brand(b.id),
                                        image: products(for: b.id).first?.images.first ?? b.image, trending: false,
                                        subtitle: String(localized: "Brand", comment: "Search suggestion subtitle: this suggestion is a brand")))
        }
        var seen = Set(out.map { $0.text.lowercased() })
        for p in catalog.products where out.count < limit {
            let t = p.title.lowercased()
            guard Self.startsWord(t, q), seen.insert(t).inserted else { continue }
            out.append(SearchSuggestion(text: p.title, kind: .query, image: p.images.first, trending: false,
                                        subtitle: category(p.category)?.name))
        }
        // The words themselves, offered back as a search of their own, first.
        //
        // Without this a shopper who types "durag" is offered one aisle and a
        // handful of single products, and nothing that means "show me all of
        // them". A word only earns its own row above when most of the brands
        // using it sit in one department, and durags are split between Hair
        // Care and Accessories, so "durag" never qualified. This row doesn't
        // care: it runs the text search, which already ranks every durag first.
        out.removeAll { $0.kind == .query && $0.text.lowercased() == q }
        out.insert(SearchSuggestion(text: query.trimmingCharacters(in: .whitespaces), kind: .query,
                                    image: out.first?.image, trending: false,
                                    subtitle: String(localized: "Search all products", comment: "Search suggestion subtitle"), searchesAll: true), at: 0)
        return Array(out.prefix(limit))
    }

    /// Words that end a finished phrase badly ("laundry detergent for").
    private static let completionStop: Set<String> = [
        "and", "for", "with", "the", "of", "in", "on", "to", "or", "from", "your", "our", "a", "an", "&",
    ]
    /// Colours beyond `phraseModifiers`, for dropping colour-only finishes.
    private static let completionColours: Set<String> = [
        "tan", "purple", "grey", "gray", "orange", "yellow", "cream", "nude", "olive", "burgundy", "maroon",
        "teal", "lavender", "lilac", "camel", "khaki", "charcoal", "coral", "rust", "sage", "mint", "rose",
        "chocolate", "espresso", "mocha", "taupe", "blush", "wine", "emerald", "cognac", "multi", "small",
        "medium", "large", "xl", "xxl",
    ]

    /// Store notices, not kinds of product: a finish stops before them.
    private static let completionNotices: Set<String> = ["pre-order", "preorder", "sale", "restock", "sold"]

    /// Merges "hoodie"/"hoodies" and "gummy"/"gummies" when counting finishes.
    static func matchKey(_ phrase: String) -> String {
        phrase.lowercased().split(separator: " ").map { part -> String in
            var w = String(part)
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { w.removeLast() }
            if w.count > 3, w.hasSuffix("ie") { w.removeLast(2); w += "y" }
            return w
        }.joined(separator: " ")
    }

    /// Product titles cut into lowercased word runs at the punctuation that
    /// separates a title's parts ("Shea Butter Soap - Lavender | 4oz"), and at
    /// "by", which starts a brand credit, so a finish never runs across them.
    @ObservationIgnored private var cachedSegments: [(product: Int, words: [String])]?
    private var titleSegments: [(product: Int, words: [String])] {
        if let cachedSegments { return cachedSegments }
        let out = Self.makeTitleSegments(catalog.products)
        cachedSegments = out
        return out
    }

    /// The same segments as one pass, cut on every core in order-keeping
    /// slices and joined in order.
    static func makeTitleSegmentsInParallel(_ products: [Product]) -> [(product: Int, words: [String])] {
        let slices = products.count < 2000 ? 1 : min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var parts = [[(product: Int, words: [String])]](repeating: [], count: slices)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: slices) { slice in
                let lo = products.count * slice / slices, hi = products.count * (slice + 1) / slices
                out[slice] = makeTitleSegments(products, range: lo..<hi)
            }
        }
        return parts.flatMap { $0 }
    }

    static func makeTitleSegments(_ products: [Product], range: Range<Int>? = nil) -> [(product: Int, words: [String])] {
        var out: [(product: Int, words: [String])] = []
        for i in range ?? products.indices {
            let p = products[i]
            var words: [String] = []
            func flush() { if !words.isEmpty { out.append((i, words)); words = [] } }
            var word = ""
            func endWord() {
                guard !word.isEmpty else { return }
                word = word.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                guard !word.isEmpty else { flush(); return }   // a lone " - " separates parts
                if word == "by" { flush() } else { words.append(word) }
                word = ""
            }
            for ch in p.title.lowercased() {
                // A hyphen inside a word keeps it whole ("pre-order", "leave-in").
                if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-" {
                    word.append(ch)
                } else if ch == " " {
                    endWord()
                } else if ch == "&" {
                    endWord(); words.append("&")
                } else {
                    endWord(); flush()
                }
            }
            endWord(); flush()
        }
        return out
    }

    /// Every word of every product's title, brand, department, type and tags,
    /// with the products that hold it, for search. Built in the background
    /// once a catalog lands; until then search checks every product.
    struct SearchWordIndex {
        let generatedAt: String
        let words: [String]          // sorted, unique
        let postings: [[Int32]]      // products holding words[i], ascending

        /// How many products hold exactly `word` (0 for none).
        func uses(_ word: String) -> Int {
            var lo = 0, hi = words.count
            while lo < hi { let mid = (lo + hi) / 2; if words[mid] < word { lo = mid + 1 } else { hi = mid } }
            return lo < words.count && words[lo] == word ? postings[lo].count : 0
        }

        /// Every word with its uses, for correcting a misspelling.
        var vocabulary: [(String, Int)] { zip(words, postings.lazy.map(\.count)).map { ($0, $1) } }

        /// Products that could match all of `terms` (each a word or the start
        /// of one), ascending; nil when every product could.
        func candidates(for terms: [String]) -> [Int]? {
            var best: (lo: Int, hi: Int, size: Int)?
            for term in terms where !term.isEmpty {
                var lo = 0, hi = words.count
                while lo < hi { let mid = (lo + hi) / 2; if words[mid] < term { lo = mid + 1 } else { hi = mid } }
                var end = lo, size = 0
                while end < words.count, words[end].hasPrefix(term) { size += postings[end].count; end += 1 }
                if best == nil || size < best!.size { best = (lo, end, size) }
            }
            guard let best else { return nil }
            if best.hi - best.lo == 1 { return postings[best.lo].map(Int.init) }
            var seen = Set<Int32>(minimumCapacity: best.size), out: [Int] = []
            out.reserveCapacity(best.size)
            for w in best.lo..<best.hi { for p in postings[w] where seen.insert(p).inserted { out.append(Int(p)) } }
            return out.sorted()
        }

        static func build(_ c: Catalog) -> SearchWordIndex {
            let brandNames = Dictionary(c.brands.map { ($0.id, SearchWords.fold($0.name)) }, uniquingKeysWith: { a, _ in a })
            let categoryNames = Dictionary(c.categories.map { ($0.id, SearchWords.fold($0.name)) }, uniquingKeysWith: { a, _ in a })
            let products = c.products
            let slices = products.count < 2000 ? 1 : min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
            var parts = [[String: [Int32]]](repeating: [:], count: slices)
            parts.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: slices) { slice in
                    var map: [String: [Int32]] = [:]
                    for i in (products.count * slice / slices)..<(products.count * (slice + 1) / slices) {
                        let p = products[i], text = SearchText(p)
                        var seen = Set<Substring>()
                        for field in [text.title, brandNames[p.brand] ?? "", categoryNames[p.category] ?? "", text.rest] {
                            for w in field.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where seen.insert(w).inserted {
                                map[String(w), default: []].append(Int32(i))
                            }
                        }
                    }
                    out[slice] = map
                }
            }
            var merged = parts[0]
            for part in parts.dropFirst() { for (w, ps) in part { merged[w, default: []].append(contentsOf: ps) } }
            let words = merged.keys.sorted()
            return SearchWordIndex(generatedAt: c.generatedAt, words: words, postings: words.map { merged[$0]! })
        }
    }
    @ObservationIgnored private(set) var searchWordIndex: SearchWordIndex?
    /// Tests build the index straight away (the app builds it in the background).
    func buildSearchIndexNow() { searchWordIndex = SearchWordIndex.build(catalog) }

    /// Where each title word sits, so a keystroke visits only the titles that
    /// contain what was typed instead of every title in the catalog.
    private struct TitleWordIndex {
        var at: [String: [(seg: Int, pos: Int)]] = [:]
        var byKey: [String: [String]] = [:]
        var sorted: [String] = []
    }
    @ObservationIgnored private var cachedWordIndex: TitleWordIndex?
    private var titleWordIndex: TitleWordIndex {
        if let cachedWordIndex { return cachedWordIndex }
        let ix = Self.makeWordIndex(titleSegments)
        cachedWordIndex = ix
        return ix
    }

    private static func makeWordIndex(_ segments: [(product: Int, words: [String])]) -> TitleWordIndex {
        var ix = TitleWordIndex()
        for (s, seg) in segments.enumerated() {
            for (i, w) in seg.words.enumerated() { ix.at[w, default: []].append((s, i)) }
        }
        ix.sorted = ix.at.keys.sorted()
        for w in ix.sorted { ix.byKey[matchKey(w), default: []].append(w) }
        return ix
    }

    /// Builds the title index and suggestion vocabulary off the main thread once
    /// a catalog lands, so the first letter typed into search doesn't pay for
    /// them (over a second together on the full catalog).
    @MainActor
    /// Bumped on every catalog swap. Two catalogs can share a generatedAt (the
    /// bundled one and a download of the same feed, or a cache written from a
    /// different cut), so the stamp alone let an index warmed for one land on
    /// the other, and completions read past the end of the products (crashed
    /// on "ca" in the simulator, 2026-10-04).
    @ObservationIgnored private var catalogGeneration = 0

    @MainActor
    private func warmTitleIndex() {
        let snapshot = catalog, byCategory = productsByCategory, stamp = catalogGeneration
        searchIndexWarming = true
        Task { @MainActor [weak self] in
            // userInitiated: someone can reach the search field the moment the
            // splash clears, and this has to be done by then.
            let built = await Task.detached(priority: .userInitiated) {
                () -> ([(product: Int, words: [String])], TitleWordIndex, [SuggestionTerm], SearchWordIndex) in
                // The title index and the suggestion vocabulary don't depend on
                // each other, so they're built side by side, and the titles are
                // cut on every core (~0.6 s on one core at 120k products).
                // The suggestion terms and the word index are read back from the
                // last launch's when the catalog and build match (SearchCache).
                let key = SearchCache.key(snapshot)
                let saved = SearchCache.load(key: key, generatedAt: snapshot.generatedAt, products: snapshot.products.count)
                var segments: [(product: Int, words: [String])] = [], index = TitleWordIndex()
                var terms: [SuggestionTerm] = saved?.terms ?? []
                var search: SearchWordIndex? = saved?.words
                DispatchQueue.concurrentPerform(iterations: saved == nil ? 3 : 1) { job in
                    switch job {
                    case 0:
                        segments = Self.makeTitleSegmentsInParallel(snapshot.products)
                        index = Self.makeWordIndex(segments)
                    case 1: terms = Self.buildSuggestionTerms(snapshot, byCategory: byCategory)
                    default: search = SearchWordIndex.build(snapshot)
                    }
                }
                if saved == nil {
                    let made = SearchCache.Indexes(terms: terms, words: search!)
                    Task.detached(priority: .background) { SearchCache.save(made, key: key) }
                }
                return (segments, index, terms, search!)
            }.value
            guard let self, self.catalogGeneration == stamp else { return }
            if self.cachedWordIndex == nil { self.cachedSegments = built.0; self.cachedWordIndex = built.1 }
            if self.cachedTerms == nil { self.cachedTerms = built.2 }
            self.searchWordIndex = built.3
            // Searches cached before the index were right, just slower; keep them.
            self.searchIndexWarming = false
        }
    }

    /// True while the title index and suggestion vocabulary are being built in
    /// the background. Suggestions wait for them rather than building them again
    /// on the main thread: typing straight after the splash used to freeze the
    /// keyboard for seconds while the first letter rebuilt everything. Observed,
    /// so the suggestion list fills in the moment they land.
    private(set) var searchIndexWarming = false

    /// Title words the shopper's last word could be: the word itself and its
    /// plural/singular forms, plus every word it starts while still typing.
    private func titleWords(for word: String, stillTyping: Bool) -> [String] {
        let ix = titleWordIndex
        // In a fixed order (the word forms, then the prefix matches, both
        // alphabetical in the index), never a Set's: with more starts than
        // maxCompletionStarts the order decides which are kept, and a Set's
        // order changes from run to run, so a short prefix ("bl") suggested
        // different finishes on each launch.
        var seen = Set<String>(), out: [String] = []
        for w in ix.byKey[Self.matchKey(word)] ?? [] where seen.insert(w).inserted { out.append(w) }
        if stillTyping {
            var lo = 0, hi = ix.sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if ix.sorted[mid] < word { lo = mid + 1 } else { hi = mid } }
            while lo < ix.sorted.count, ix.sorted[lo].hasPrefix(word) {
                if seen.insert(ix.sorted[lo]).inserted { out.append(ix.sorted[lo]) }
                lo += 1
            }
        }
        return out
    }

    @ObservationIgnored private var lastCompletions: (query: String, result: [Completion])?
    private static let maxCompletionStarts = 6000
    /// Tests pin this to 1 to check the parallel tally against a single pass.
    nonisolated(unsafe) static var completionSlices: Int?

    /// Ways to finish what's typed, drawn from product titles: the typed words
    /// (the last one may be half-typed) followed by up to three more. A finish
    /// counts when two brands use it, or one brand in three different titles —
    /// fewer is one product's name, not something people shop for. Ranked by
    /// brands, then titles; a finish on a whole typed word beats one that
    /// stretches a half word ("wig" before "wiggle"), and a fragment gives way
    /// to the longer phrase that carries most of it ("… for sensitive" to
    /// "… for sensitive skin").
    func completions(_ query: String) -> [Completion] {
        if Self.completionSlices == nil, let lastCompletions, lastCompletions.query == query { return lastCompletions.result }
        let typed = query.lowercased().split(separator: " ").map(String.init)
        // One letter matches too much of the catalog to finish anything useful
        // ("s" starts tens of thousands of title words); the aisles and kinds
        // below cover it until a second letter narrows things down.
        guard let lastTyped = typed.last, typed.count > 1 || lastTyped.count >= 2 else { return [] }
        let head = Array(typed.dropLast())
        let wordDone = query.hasSuffix(" ")
        struct Tally { var forms: [String: Int] = [:]; var brands = Set<String>(); var titles = Set<String>()
                       var products: [Int] = []; var exactWord = false }
        let products = catalog.products
        let segments = titleSegments
        let lastKey = Self.matchKey(lastTyped)
        // Where the typed phrase could start: every place its first word appears.
        var starts: [(seg: Int, pos: Int)] = head.isEmpty
            ? titleWords(for: lastTyped, stillTyping: !wordDone).flatMap { titleWordIndex.at[$0] ?? [] }
            : titleWordIndex.at[head[0]] ?? []
        // A bound on work per keystroke, whatever the catalog grows to.
        if starts.count > Self.maxCompletionStarts { starts = Array(starts.prefix(Self.maxCompletionStarts)) }
        // The starts are tallied on every core in order-keeping slices, then
        // merged slice by slice, so the result is what one pass would give: a
        // two-letter query ("ca") spent ~550 ms here on one core (2026-10-02).
        let slices = Self.completionSlices ?? (starts.count < 400 ? 1 : min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8))
        var partials = [[String: Tally]](repeating: [:], count: slices)
        partials.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: slices) { slice in
                var tallies: [String: Tally] = [:]
                let lo = starts.count * slice / slices, hi = starts.count * (slice + 1) / slices
                for (s, i) in starts[lo..<hi] {
                    guard s < segments.count else { continue }
                    let seg = segments[s]
                    let w = seg.words
                    guard seg.product < products.count, i + typed.count <= w.count else { continue }
                    let p = products[seg.product]
                    guard w[i..<(i + head.count)].elementsEqual(head) else { continue }
                    let last = w[i + head.count]
                    let exact = last == lastTyped || Self.matchKey(last) == lastKey
                    guard exact || (!wordDone && last.hasPrefix(lastTyped)) else { continue }
                    var phrase = Array(w[i..<(i + typed.count)])
                    // Once per start, not once per finish length: lowercasing whole
                    // titles four times over was most of a two-letter keystroke.
                    let lowerTitle = p.title.lowercased()
                    for n in 0...3 {
                        if n > 0 {
                            let next = i + typed.count + n - 1
                            guard next < w.count, w[next].count > 1 || w[next] == "&",
                                  !w[next].contains(where: \.isNumber),
                                  !Self.completionNotices.contains(w[next]) else { break }
                            phrase.append(w[next])
                            if Self.completionStop.contains(w[next]) || w[next].count < 3 { continue }
                        }
                        // Colours and sizes alone aren't a kind to shop ("bag in black").
                        let added = phrase.dropFirst(typed.count)
                        if !added.isEmpty, added.allSatisfy({ Self.completionStop.contains($0) || Self.phraseModifiers.contains($0)
                                                              || Self.completionColours.contains($0) }) { continue }
                        let text = phrase.joined(separator: " ")
                        let key = Self.matchKey(text)
                        // In place: copying a tally out and back copied its sets on
                        // every match (a third of a second on a two-letter query).
                        tallies[key, default: Tally()].forms[text, default: 0] += 1
                        tallies[key]!.brands.insert(p.brand)
                        if tallies[key]!.titles.insert(lowerTitle).inserted { tallies[key]!.products.append(seg.product) }
                        if exact { tallies[key]!.exactWord = true }
                    }
                }
                out[slice] = tallies
            }
        }
        var tallies = partials[0]
        for part in partials.dropFirst() {
            for (key, t) in part {
                tallies[key, default: Tally()].forms.merge(t.forms, uniquingKeysWith: +)
                tallies[key]!.brands.formUnion(t.brands)
                // A product counts once per title, first sighting first, as in one pass.
                for i in t.products where tallies[key]!.titles.insert(products[i].title.lowercased()).inserted {
                    tallies[key]!.products.append(i)
                }
                if t.exactWord { tallies[key]!.exactWord = true }
            }
        }
        let kept = tallies.filter { $0.value.titles.count >= 2 && ($0.value.brands.count >= 2 || $0.value.titles.count >= 3) }
        func score(_ t: Tally) -> Int { 3 * t.brands.count + t.titles.count }
        var result: [Completion] = []
        // The best score among each phrase's one-word-longer finishes, in one
        // pass. (Comparing every finish with every other was quadratic: on a
        // two-letter query it held the main thread for minutes.)
        var bestChild: [String: Int] = [:]
        for (key, t) in kept {
            guard let space = key.lastIndex(of: " ") else { continue }
            let parent = String(key[..<space])
            bestChild[parent] = max(bestChild[parent] ?? 0, score(t))
        }
        var candidates: [(text: String, tally: Tally)] = []
        for (key, t) in kept {
            // A fragment gives way when a longer finish carries most of its brands.
            if key.split(separator: " ").count > typed.count,
               let child = bestChild[key], Double(child) >= 0.7 * Double(score(t)) {
                continue
            }
            candidates.append((t.forms.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key, t))
        }
        // Only a handful are ever shown, so rank first and give just the leaders
        // a photo and an aisle: a two-letter query ("sh") keeps thousands of
        // finishes, and grouping every one's products cost a third of a second.
        // Ties go alphabetically, so the list doesn't reshuffle between runs.
        candidates.sort { ($0.tally.exactWord ? 1 : 0, score($0.tally), -$0.text.count, $1.text)
                        > ($1.tally.exactWord ? 1 : 0, score($1.tally), -$1.text.count, $0.text) }
        for (text, t) in candidates.prefix(40) {
            let ps = t.products.map { products[$0] }
            let home = Dictionary(grouping: ps, by: \.category).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            result.append(Completion(text: text, image: thumbnail(ps), category: home,
                                     score: score(t), exactWord: t.exactWord))
        }
        result.sort { ($0.exactWord ? 1 : 0, $0.score, -$0.text.count, $1.text) > ($1.exactWord ? 1 : 0, $1.score, -$1.text.count, $0.text) }
        lastCompletions = (query, result)
        return result
    }

    /// "Category" for a category itself; for a kind of product ("lashes"), the
    /// category it mostly sits in — so every suggestion says what aisle it's in.
    private func subtitle(for t: SuggestionTerm) -> String? {
        switch t.kind {
        case .category: return String(localized: "Category", comment: "Search suggestion kind")
        case .subcategory, .query: return t.category.flatMap { category($0)?.name }
        case .brand: return String(localized: "Brand", comment: "Search suggestion kind")
        }
    }

    /// Built on first use — the catalog never changes while the app runs.
    @ObservationIgnored private var cachedTerms: [SuggestionTerm]?
    private var suggestionTerms: [SuggestionTerm] {
        if let cachedTerms { return cachedTerms }
        let terms = Self.buildSuggestionTerms(catalog, byCategory: productsByCategory)
        cachedTerms = terms
        return terms
    }

    /// Product kinds too vague to suggest on their own.
    private static let vagueTypes: Set<String> = [
        "custom", "bundle", "bundles", "default", "lifestyle", "accessory", "apparel", "apparel & accessories",
        "ready to wear", "other", "misc", "product", "products", "gift", "gifts", "sale", "new", "all",
    ]

    /// Every category, plus each Shopify product type that two or more brands
    /// use (one brand's house name, like "curlmix fresh", isn't a kind of
    /// product). Heat counts products in the top 10 of their brand's
    /// best-sellers, weighted by rank; the 3 hottest categories and 10 hottest
    /// kinds are "trending".
    static func buildSuggestionTerms(_ catalog: Catalog, byCategory: [String: [Int32]]) -> [SuggestionTerm] {
        // Static so it can run off the main thread: about a second over the
        // full catalog, which used to land on the first letter typed.
        func products(in id: String) -> [Product] { (byCategory[id] ?? []).map { catalog.products[Int($0)] } }
        func products(inSub id: String) -> [Product] {
            let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return [] }
            return products(in: parts[0]).filter { $0.subs.contains(parts[1]) }
        }
        var categories: [SuggestionTerm] = []
        for c in catalog.categories {
            let ps = products(in: c.id)
            guard !ps.isEmpty else { continue }
            let text = c.name.lowercased()
            categories.append(SuggestionTerm(text: text, key: singular(text), kind: .category(c.id),
                                             image: thumbnail(ps), count: ps.count, heat: heat(ps),
                                             category: c.id, brandCount: Set(ps.map(\.brand)).count))
        }
        let categoryKeys = Set(categories.map(\.key))

        // The curated aisles. They suggest like categories do and open a real
        // grid rather than running a text search.
        var aisles: [SuggestionTerm] = []
        for sub in catalog.subcategories {
            let ps = products(inSub: sub.id)
            guard !ps.isEmpty else { continue }
            let text = sub.name.lowercased()
            aisles.append(SuggestionTerm(text: text, key: singular(text), kind: .subcategory(sub.id),
                                         image: thumbnail(ps), count: ps.count, heat: heat(ps),
                                         category: sub.category, brandCount: Set(ps.map(\.brand)).count))
        }

        var groups: [String: (forms: [String: (brands: Set<String>, count: Int)], products: [Product], brands: Set<String>)] = [:]
        for p in catalog.products {
            let form = (p.productType ?? "").lowercased()
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard (3...24).contains(form.count), !form.contains(where: \.isNumber),
                  !vagueTypes.contains(form) else { continue }
            let key = singular(form)
            guard !categoryKeys.contains(key) else { continue }
            groups[key, default: ([:], [], [])].forms[form, default: ([], 0)].brands.insert(p.brand)
            groups[key]!.forms[form]!.count += 1
            groups[key]!.products.append(p)
            groups[key]!.brands.insert(p.brand)
        }
        var kinds: [SuggestionTerm] = []
        for (key, g) in groups where g.brands.count >= 2 {
            // Show the spelling the most brands use ("earrings" over "earring"),
            // then the most products: one brand's 15 "Shea Butters" outvoted
            // three brands' "Shea Butter" when products alone decided (2026-11-08).
            let text = g.forms.max { ($0.value.brands.count, $0.value.count, $1.key) < ($1.value.brands.count, $1.value.count, $0.key) }!.key
            let grouped = Dictionary(grouping: g.products, by: \.category)
            let home = grouped.max { $0.value.count < $1.value.count }?.key
            let inHome = home.map { Set(grouped[$0]?.map(\.brand) ?? []).count } ?? 0
            kinds.append(SuggestionTerm(text: text, key: key, kind: .query, image: thumbnail(g.products),
                                        count: g.products.count, heat: heat(g.products),
                                        category: home, brandCount: inHome))
        }

        func markHottest(_ list: inout [SuggestionTerm], _ n: Int) {
            let hot = Set(list.filter { $0.heat > 0 }.sorted { $0.heat > $1.heat }.prefix(n).map(\.key))
            for i in list.indices where hot.contains(list[i].key) { list[i].trending = true }
        }
        markHottest(&categories, 3)
        markHottest(&aisles, 6)
        markHottest(&kinds, 10)
        let taken = categoryKeys.union(aisles.map(\.key)).union(kinds.map(\.key))
        return categories + aisles + kinds + titlePhraseTerms(catalog, skipping: taken)
    }

    private func heat(_ ps: [Product]) -> Int { Self.heat(ps) }
    private func thumbnail(_ ps: [Product]) -> String? { Self.thumbnail(ps) }

    private static func heat(_ ps: [Product]) -> Int {
        ps.reduce(0) { $0 + max(0, 10 - ($1.bestRank ?? 10)) }
    }

    private static func thumbnail(_ ps: [Product]) -> String? {
        let best = ps.filter(\.available).min { ($0.bestRank ?? .max) < ($1.bestRank ?? .max) }
        return (best ?? ps.first)?.images.first
    }

    /// Words that can't sit in a suggestable phrase.
    private static let phraseStop: Set<String> = [
        "the", "and", "for", "with", "your", "our", "new", "sale", "set", "kit", "pack", "size", "color", "colour",
        "that", "this", "from", "into", "more", "than", "also", "when", "what", "over", "only", "you", "are", "was",
        "has", "have", "will", "can", "its", "all", "any", "not", "but", "off", "out", "per", "pre", "non", "sub",
        "best", "top", "free", "full", "half", "one", "two", "three",
    ]

    /// Words that describe a product instead of naming one.
    private static let phraseModifiers: Set<String> = [
        "black", "white", "blue", "red", "pink", "gold", "green", "brown", "dark", "deep", "light", "silver",
        "navy", "ivory", "beige", "mini", "small", "medium", "large", "travel", "bundle", "duo", "trio", "kids",
        "men", "women", "unisex", "limited", "edition", "classic", "original", "signature", "luxe", "premium",
        "natural", "organic", "vegan", "plus", "pro", "max",
    ]

    /// The phrases people actually type — "shea butter", "lip gloss", "tote
    /// bag" — mined from product titles, so any kind of thing the catalog
    /// sells can be searched as a kind and not just as one brand's product
    /// name. A phrase qualifies when two or more brands use it, its products
    /// sit mostly in one category, and it names a thing rather than a colour or
    /// size. A single word needs a wider following (4+ brands, 5+ products):
    /// one word on its own is usually noise ("raw", "lid").
    private static func titlePhraseTerms(_ catalog: Catalog, skipping taken: Set<String>) -> [SuggestionTerm] {
        // The phrase has to END in a word brands themselves publish as a kind of
        // product ("bag", "butter", "conditioner"), or titles throw up colours,
        // sizes and marketing words as if they were categories.
        var headCounts: [String: Int] = [:]
        for p in catalog.products {
            guard let last = (p.productType ?? "").lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init).last, last.count > 2 else { continue }
            headCounts[last, default: 0] += 1
        }
        let heads = Set(headCounts.filter { $0.value >= 3 }.keys)
        // Buckets are mutated in place and hold product positions, not copies:
        // reading a bucket out, appending and writing it back copied its growing
        // product list on every phrase of every title — 5.6 s of a cold first
        // keystroke on the 101k-product catalog.
        struct Bucket {
            var brands: Set<String> = []
            var products: [Int] = []
            var brandsByCategory: [String: Set<String>] = [:]
        }
        var buckets: [String: Bucket] = [:]
        for (index, p) in catalog.products.enumerated() {
            let words = p.title.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !$0.allSatisfy(\.isNumber) && !phraseStop.contains($0) }
            guard !words.isEmpty else { continue }
            var seen = Set<String>()
            for n in 1...3 where words.count >= n {
                for i in 0...(words.count - n) {
                    let phrase = words[i..<(i + n)].joined(separator: " ")
                    guard heads.contains(words[i + n - 1]), seen.insert(phrase).inserted else { continue }
                    buckets[phrase, default: Bucket()].brands.insert(p.brand)
                    buckets[phrase]!.products.append(index)
                    buckets[phrase]!.brandsByCategory[p.category, default: []].insert(p.brand)
                }
            }
        }
        // "tote bag" and "tote bags" share a key; one suggestion, the form
        // more products use, not both in dictionary order (2026-11-08).
        var out: [String: SuggestionTerm] = [:]
        for (phrase, b) in buckets {
            let words = phrase.split(separator: " ").map(String.init)
            guard let last = words.last, !phraseModifiers.contains(last),
                  !words.allSatisfy({ phraseModifiers.contains($0) }) else { continue }
            let single = words.count == 1
            guard b.brands.count >= (single ? 4 : 2), b.products.count >= (single ? 5 : 2) else { continue }
            guard let top = b.brandsByCategory.max(by: { $0.value.count < $1.value.count }),
                  Double(top.value.count) / Double(b.brands.count) >= 0.6 else { continue }
            let key = singular(phrase)
            guard !taken.contains(key) else { continue }
            // Most products wins; a tie goes to the shorter, then earlier, form.
            if let kept = out[key], (kept.count, -kept.text.count, phrase) > (b.products.count, -phrase.count, kept.text) { continue }
            let products = b.products.map { catalog.products[$0] }
            out[key] = SuggestionTerm(text: phrase, key: key, kind: .query, image: thumbnail(products),
                                      count: products.count, heat: heat(products),
                                      category: top.key, brandCount: top.value.count)
        }
        return Array(out.values)
    }

    /// A grouping key, not a display form: "earrings" and "earring" meet at
    /// "earring", "glasses" at "glass".
    static func singular(_ phrase: String) -> String {
        phrase.split(separator: " ").map { part -> String in
            let w = String(part)
            if w.count > 4, ["sses", "xes", "ches", "shes"].contains(where: w.hasSuffix) { return String(w.dropLast(2)) }
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        }.joined(separator: " ")
    }

    /// Does `needle` start a word in `text`? Searching "butter" should find
    /// "Shea Butter Soap" and, as someone types, "butterfly" — but not the
    /// "Buttercream" in a colour name, which is where a plain substring match
    /// put a sports bra in a shea butter search. Both sides are lowercased.
    /// A word or phrase on word boundaries, where a final one- or two-letter
    /// word may carry digits: "d" finds "D3" and "vitamin b" finds "Vitamin
    /// B12", because in a supplement name the letter and its number are one
    /// term. Everything else defers to `matchesWord`.
    /// Whether `needle`'s bytes appear in `text` at all: a memmem over UTF-8,
    /// far cheaper than String.range(of:), which bridges to Foundation on
    /// every call. The word checks below only run where this says yes; on
    /// 120k products that took a cold search from ~670 ms (2026-10-02).
    static func containsBytes(_ text: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var text = text, needle = needle
        return text.withUTF8 { t in
            needle.withUTF8 { n in
                guard let tb = t.baseAddress, let nb = n.baseAddress, t.count >= n.count else { return false }
                return memmem(tb, t.count, nb, n.count) != nil
            }
        }
    }

    static func matchesTerm(_ text: String, _ term: String) -> Bool {
        guard containsBytes(text, term) else { return false }
        if matchesWord(text, term) { return true }
        guard let last = term.split(separator: " ").last, last.count <= 2,
              last.allSatisfy(\.isLetter) else { return false }
        var from = text.startIndex
        while let r = text.range(of: term, range: from..<text.endIndex) {
            let startsWord = r.lowerBound == text.startIndex
                || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
            if startsWord {
                var end = r.upperBound
                while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
                if end > r.upperBound, end == text.endIndex || !(text[end].isLetter || text[end].isNumber) {
                    return true
                }
            }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    static func startsWord(_ text: String, _ needle: String) -> Bool {
        guard containsBytes(text, needle) else { return false }
        var from = text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex { return true }
            let prev = text[text.index(before: r.lowerBound)]
            if !prev.isLetter && !prev.isNumber { return true }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    /// Does `needle` appear as a whole word in `text` (a trailing "s"/"es" is
    /// still the same word)? Both sides lowercased.
    static func matchesWord(_ text: String, _ needle: String) -> Bool {
        guard containsBytes(text, needle) else { return false }
        var from = text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            let startsWord = r.lowerBound == text.startIndex
                || !(text[text.index(before: r.lowerBound)].isLetter || text[text.index(before: r.lowerBound)].isNumber)
            if startsWord {
                var end = r.upperBound
                for _ in 0..<2 where end < text.endIndex && (text[end] == "s" || text[end] == "e") {
                    end = text.index(after: end)
                }
                if end == text.endIndex || !(text[end].isLetter || text[end].isNumber) { return true }
            }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    static func hash(_ s: String, seed: Int) -> UInt64 {
        let start: UInt64 = 1469598103934665603 &+ UInt64(truncatingIfNeeded: seed)
        // The same bytes either way; a native string hands them over in one piece.
        if let h = s.utf8.withContiguousStorageIfAvailable({ bytes -> UInt64 in
            var h = start
            for b in bytes { h = (h ^ UInt64(b)) &* 1099511628211 }
            return h
        }) { return h }
        var h = start
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return h
    }
}

/// A Home row shaped by this shopper's own activity.
struct ForYouRow: Identifiable {
    let id: String
    let title: String
    let products: [Product]
    /// Products placed from other departments (the reserved slots), so their
    /// taps are counted as "dept_mix".
    var reserved: Set<String> = []

    /// The short name this row's views and taps are counted under (Analytics).
    var track: String { id.hasPrefix("search") ? "search" : id.hasPrefix("aisle") ? "aisle" : id }
}

extension CatalogStore {
    /// Home's personalized rows, built on-device from what this shopper did.
    /// Amazon relates items by what other customers bought together
    /// (item-to-item collaborative filtering). Marracat has no purchase data
    /// across shoppers, so it uses the content-based kind the same paper
    /// suggests for thin histories: items sharing a kind, category and tags
    /// with what you searched for, viewed or saved. One "Inspired by your
    /// search" row per recent search (up to two), then related items. Empty
    /// for a new shopper.
    func forYou(searches: [String], viewed: [String], saved: [String], hidden: [String] = [],
                purchased: [String] = [], mix: BrandMix? = nil,
                memory: SearchMemory = SearchMemory(), now: Date = .now) -> [ForYouRow] {
        var rows: [ForYouRow] = []
        let excluded = Set(hidden + purchased)
        var shown = Set(viewed).union(excluded)
        // Only departments the shopper has shown interest in (owner, 2026-11-09).
        let touched = touchedDepartments(viewed: viewed, saved: saved, purchased: purchased, searches: searches)
        let fits = { (p: Product) in touched.isEmpty || touched.contains(p.category) }
        // Owner, 2026-10-10: searches the shopper acted on come first, holiday
        // searches expire, and a search that was really one product's name
        // becomes "More from <brand>" or "<kind> like this".
        let ordered = Self.searchRowQueries(searches, memory: memory, now: now)
        for q in ordered where rows.count < 2 {
            let results = search(q)
            if let named = Self.lookedUpProduct(q, in: results) {
                guard let row = productLookupRow(named, shown: shown, mix: mix) else { continue }
                rows.append(row)
                shown.formUnion(row.products.map(\.id))
                continue
            }
            let hits = spread(results.filter { $0.available && !shown.contains($0.id) && fits($0) }.distinctLooking(), limit: 12, mix: mix)
            guard hits.count >= 4 else { continue }
            rows.append(ForYouRow(id: "search:\(q.lowercased())", title: String(localized: "Inspired by your search for “\(q)”", comment: "Home row title; the argument is a past search"), products: hits))
            shown.formUnion(hits.map(\.id))
        }
        // What they bought or liked, aisle by aisle: other brands' and the
        // same brand's (owner, 2026-11-09).
        for row in aisleRows(seeds: purchased + saved, shown: shown, excluded: excluded, mix: mix) {
            rows.append(row)
            shown.formUnion(row.products.map(\.id))
        }
        // Explicit likes outweigh incidental views. Recency is represented by
        // position in bounded, most-recent-first histories. No demographic or
        // sensitive-trait inference, or data from other apps, enters this score.
        var categoryWeight: [String: Double] = [:], brandWeight: [String: Double] = [:]
        var subWeight: [String: Double] = [:]
        func seed(_ ids: [String], strength: Double) {
            for (index, id) in ids.prefix(30).enumerated() {
                guard let p = product(id), !excluded.contains(id) else { continue }
                let weight = strength / (1 + Double(index) / 6)
                categoryWeight[p.category, default: 0] += weight
                brandWeight[p.brand, default: 0] += weight * 0.4
                for sub in p.subs { subWeight[p.category + ":" + sub, default: 0] += weight * 1.5 }
            }
        }
        seed(saved, strength: 5)
        seed(viewed, strength: 1)
        // Nothing viewed or saved scores every product 0, and only scores
        // above 0 make the row: skip scoring all 146k for nothing (it was a
        // quarter of a second of Home's build on a new shopper's launch).
        guard !categoryWeight.isEmpty else { return rows }
        let (categoryW, brandW, subW) = (categoryWeight, brandWeight, subWeight)
        func score(_ p: Product) -> Double {
            categoryW[p.category, default: 0] + brandW[p.brand, default: 0]
                + p.subs.reduce(0) { $0 + subW[p.category + ":" + $1, default: 0] }
        }
        let seeds = Set(saved + viewed)
        // Scored once each: score() builds strings, and calling it inside a
        // comparator ran it ~n log n times on the main thread. The scoring is
        // split across the cores (it was most of the ~0.3 s Home's personal
        // rows took on 146k products, 2026-10-11), and only the best 180 are
        // kept (`best`): sorting every scored product to take the first 180
        // was 140 ms of the freeze on the first tab switch after launch
        // (owner, 2026-11-20). The row is the same one, product for product.
        let products = catalog.products, shownNow = shown, touchedNow = touched
        let slices = products.count < 4000 ? 1 : min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        let ranked = Self.best(180, of: products.count, slices: slices, score: { i in
            let p = products[i]
            guard p.available, !shownNow.contains(p.id), !seeds.contains(p.id),
                  touchedNow.isEmpty || touchedNow.contains(p.category) else { return nil }
            let s = score(p)
            return s > 0 ? s : nil
        }, id: { products[$0].id }).map { products[$0] }
        // Round-robin keeps a prolific brand from occupying the whole row.
        // Limit the candidate pool so refresh preserves relevance.
        let pool = ranked.distinctLooking()
        let related = spread(pool, limit: 12, mix: mix)
        if related.count >= 4 {
            let lean = departmentLean(viewed: viewed, saved: saved, purchased: purchased)
            let mixed = reservingOtherDepartments(related, pool: pool, lean: lean, searched: searchedDepartments(searches),
                                                  seeds: (saved + viewed + purchased).compactMap(product), excluded: shown.union(seeds), mix: mix)
            let products = mixed.products.distinctLooking()
            rows.append(ForYouRow(id: "related", title: saved.isEmpty ? String(localized: "Related to items you viewed", comment: "Home row title") : String(localized: "Inspired by your likes", comment: "Home row title"),
                                  products: products, reserved: mixed.reserved.intersection(products.map(\.id))))
        }
        return rows
    }

    /// The `limit` best of `count` candidates, best first: the highest
    /// scores, equal scores in `id` order, as sorting them all and taking the
    /// first `limit` would give. `score` is nil for a candidate that isn't
    /// one. The candidates are split across `slices` threads, each keeping
    /// only its own best `limit`, so nothing the size of the catalog is ever
    /// sorted; `score` and `id` run on those threads.
    static func best(_ limit: Int, of count: Int, slices: Int, score: (Int) -> Double?, id: (Int) -> String) -> [Int] {
        guard limit > 0, count > 0 else { return [] }
        func ahead(_ a: (Int, Double), _ b: (Int, Double)) -> Bool {
            a.1 == b.1 ? id(a.0) < id(b.0) : a.1 > b.1
        }
        let slices = max(1, min(slices, count))
        var parts = [[(Int, Double)]](repeating: [], count: slices)
        parts.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: slices) { slice in
                var kept: [(Int, Double)] = []
                kept.reserveCapacity(limit + 1)
                for i in (count * slice / slices)..<(count * (slice + 1) / slices) {
                    guard let s = score(i) else { continue }
                    let found = (i, s)
                    if kept.count == limit, !ahead(found, kept[limit - 1]) { continue }
                    // After everything it doesn't beat, where a stable sort would put it.
                    var low = 0, high = kept.count
                    while low < high {
                        let mid = (low + high) / 2
                        if ahead(found, kept[mid]) { high = mid } else { low = mid + 1 }
                    }
                    kept.insert(found, at: low)
                    if kept.count > limit { kept.removeLast() }
                }
                out[slice] = kept
            }
        }
        return parts.joined().sorted(by: ahead).prefix(limit).map(\.0)
    }

    /// The recent searches `forYou` tries for its "Inspired by your search"
    /// rows, in the order it tries them (owner, 2026-10-10): searches the
    /// shopper acted on come first, and holiday searches expire.
    static func searchRowQueries(_ searches: [String], memory: SearchMemory = SearchMemory(), now: Date = .now) -> [String] {
        let candidates = searches.prefix(8).filter { !memory.isExpired($0, now: now) }
        return candidates.filter { memory.actedOn($0) } + candidates.filter { !memory.actedOn($0) }
    }

    /// Runs searches someone is about to ask for on a background thread and
    /// keeps their results, so `search` answers them at once. Home's personal
    /// rows search the shopper's recent searches on the main thread; done
    /// there on the way out of Home, they were most of a freeze on the first
    /// tab switch after launch (owner, 2026-11-20). Only the first
    /// `limit` not already answered; a catalog that changes meanwhile drops
    /// the results.
    ///
    /// With the store's own copy of every product's search text, not
    /// `SearchSnapshot`'s, which makes it again for each search that reads
    /// most of the catalog ("candle" has other words for it, so it does):
    /// that was 1.5 s a search here. Made on this thread if the store has
    /// none yet, and kept.
    @MainActor
    func warmSearches(_ queries: [String], limit: Int = 4) async {
        guard isComplete else { return }
        var keys = Set<String>()
        let wanted = queries.filter { searchMemo[$0.lowercased()] == nil && keys.insert($0.lowercased()).inserted }.prefix(limit)
        guard !wanted.isEmpty else { return }
        let catalog = catalog, brands = brandsByID, categories = categoriesByID, index = searchWordIndex, stamp = catalogGeneration
        let kept = searchTextMemo.flatMap { $0.count == catalog.products.count ? $0 : nil }
        let started = Date()
        let (found, made) = await Task.detached(priority: .userInitiated) { () -> ([(String, [Product])], [SearchText]?) in
            var texts = kept
            let found = wanted.map { q in
                (q.lowercased(), Self.runSearch(q, catalog: catalog, brands: brands, categories: categories, wordIndex: index, allText: {
                    if let texts { return texts }
                    let all = Self.searchTexts(catalog.products)
                    texts = all
                    return all
                }))
            }
            return (found, kept == nil ? texts : nil)
        }.value
        LaunchTiming.log.notice("search: warmed \(found.count, privacy: .public) searches off the main thread in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms at \(LaunchTiming.sinceStart(), privacy: .public) ms")
        guard stamp == catalogGeneration else { return }
        if searchTextMemo == nil, let made { searchTextMemo = made }
        for (key, results) in found where searchMemo[key] == nil {
            if searchMemo.count >= 24 { searchMemo.removeAll() }
            searchMemo[key] = results
        }
    }

    /// The product a search named outright, if it was a lookup rather than a
    /// browse: three or more words matching one result's title (owner's
    /// "Late Registration Yeezy Bear Lapel Pin", 2026-10-10). Only the top few
    /// results are checked, so it costs nothing beyond the search itself.
    static func lookedUpProduct(_ q: String, in results: [Product]) -> Product? {
        func norm(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
                .split(separator: " ").joined(separator: " ")
        }
        let query = norm(q)
        guard query.split(separator: " ").count >= 3 else { return nil }
        let matches = results.prefix(5).filter { p in
            let title = norm(p.title)
            if title == query { return true }
            let (short, long) = title.count < query.count ? (title, query) : (query, title)
            return long.contains(short) && Double(short.count) >= 0.8 * Double(long.count)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// For a product-name search: the brand's other products, else the same
    /// kind of thing from anyone.
    private func productLookupRow(_ p: Product, shown: Set<String>, mix: BrandMix?) -> ForYouRow? {
        let skip = shown.union([p.id])
        let more = spread(products(for: p.brand).filter { $0.available && !skip.contains($0.id) }.distinctLooking(), limit: 12, mix: mix)
        if more.count >= 4, let b = brand(p.brand) {
            return ForYouRow(id: "search:brand:\(p.brand)", title: String(localized: "More from \(b.name)", comment: "Home row title; the argument is a brand name"), products: more)
        }
        let alike = spread(Array(related(to: [p], excluding: skip).prefix(120)).distinctLooking(), limit: 12, mix: mix)
        guard alike.count >= 4 else { return nil }
        let kind = p.productType.flatMap { $0.isEmpty ? nil : $0 }
            ?? p.subs.first.flatMap { subcategory(p.category + ":" + $0)?.name }
            ?? categoriesByID[p.category]?.name ?? String(localized: "Picks", comment: "Fallback word for a kind of product")
        return ForYouRow(id: "search:kind:\(p.id)", title: String(localized: "\(kind.capitalized) like this", comment: "Home row title; the argument is a kind of product, like Lashes"), products: alike)
    }

    /// How much each department figures in this shopper's history: saves
    /// count most, then orders, then views, recent ones more than old.
    func departmentLean(viewed: [String], saved: [String], purchased: [String]) -> [(category: String, weight: Double)] {
        var w: [String: Double] = [:]
        func add(_ ids: [String], _ strength: Double) {
            for (i, id) in ids.prefix(60).enumerated() {
                guard let p = product(id) else { continue }
                w[p.category, default: 0] += strength / (1 + Double(i) / 10)
            }
        }
        add(saved, 5); add(purchased, 3); add(viewed, 1)
        return w.map { ($0.key, $0.value) }.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.category < $1.category }
    }

    /// The departments a shopper has shown interest in: bought from, liked,
    /// looked at, or searched for (a department with a quarter or more of a
    /// recent search's top results). Personal rows show only these (owner,
    /// 2026-11-09: "if they never purchase dog food or search for it we
    /// should never show it"). Empty for a shopper with no history, who sees
    /// the whole store.
    func touchedDepartments(viewed: [String], saved: [String], purchased: [String], searches: [String]) -> Set<String> {
        var out = Set<String>()
        for id in viewed.prefix(60) + saved.prefix(200) + purchased.prefix(200) {
            if let p = product(id) { out.insert(p.category) }
        }
        out.formUnion(searchedDepartments(searches))
        return out
    }

    /// The same for a shopper's history; empty with personalization off.
    @MainActor
    func touchedDepartments(of shopper: ShopperStore) -> Set<String> {
        guard shopper.personalizationEnabled else { return [] }
        return touchedDepartments(viewed: shopper.recentlyViewed, saved: shopper.saved,
                                  purchased: shopper.checkouts.flatMap(\.productIDs), searches: shopper.recentSearches)
    }

    /// The departments recent searches were about, most recent first.
    ///
    /// Never a search just for this at launch (2026-11-09): Home asks the
    /// moment the whole catalog lands, on the main thread. While the word
    /// index is still being built a search reads every product, and two
    /// recent searches took launch from 1.97 s to 6.9 s that way (8f917a7;
    /// the ship's perf gate caught it); even with the index in, they cost
    /// ~250 ms before Home took a touch. So each query's answer is saved
    /// (`SearchedDepartments`) and read back: a query searched this session
    /// answers from its memoized results and refreshes the saved answer
    /// (Home's own search rows search every recent query when they rebuild,
    /// so that happens each session); one with a saved answer uses it; only
    /// a query with neither is searched, and not while the index warms.
    func searchedDepartments(_ searches: [String]) -> [String] {
        var out: [String] = []
        var known = SearchedDepartments.load(), changed = false
        for q in searches.prefix(8) {
            let key = q.lowercased()
            let departments: [String]
            if Self.searchesNow(warming: searchIndexWarming, memoized: searchMemo[key] != nil, saved: known[key] != nil) {
                departments = Self.departments(of: search(q))
                if known[key] != departments { known[key] = departments; changed = true }
            } else {
                departments = known[key] ?? []
            }
            for c in departments where !out.contains(c) { out.append(c) }
        }
        if changed { SearchedDepartments.save(known, keeping: searches) }
        return out
    }

    /// Whether `searchedDepartments` runs a query now: when its results are
    /// already memoized (free), or when nothing is saved for it and the word
    /// index isn't mid-build (never started, as in tests, counts as ready).
    static func searchesNow(warming: Bool, memoized: Bool, saved: Bool) -> Bool { memoized || (!saved && !warming) }

    /// The departments holding a quarter or more of a search's top 20, biggest first.
    static func departments(of results: [Product]) -> [String] {
        let top = results.prefix(20)
        guard !top.isEmpty else { return [] }
        let counts = Dictionary(grouping: top, by: \.category).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .filter { $0.value * 4 >= top.count }.map(\.key)
    }

    /// "More for your laundry" (owner, 2026-11-09: "if someone buys, searches
    /// or likes a laundry item they should see items that match well with
    /// that like different laundry detergent brands, the same detergent
    /// brands but different items like dryer sheets"): for each of the first
    /// aisles the shopper bought from or liked, other brands' products in
    /// that aisle in turn with the same brand's other products in the
    /// department, those sharing an aisle with it first.
    func aisleRows(seeds: [String], shown: Set<String>, excluded: Set<String>, limit: Int = 2, mix: BrandMix? = nil) -> [ForYouRow] {
        var rows: [ForYouRow] = []
        var aislesDone: Set<String> = []
        var taken = shown.union(excluded)
        for id in seeds.prefix(40) where rows.count < limit {
            guard let seed = product(id),
                  let sub = seed.subs.first(where: { subcategory("\(seed.category):\($0)") != nil }) else { continue }
            let key = "\(seed.category):\(sub)"
            guard !aislesDone.contains(key), let aisle = subcategory(key) else { continue }
            aislesDone.insert(key)
            let seedSubs = Set(seed.subs), title = seed.title.lowercased()
            let open = products(in: seed.category).filter { $0.available && !taken.contains($0.id) && $0.id != seed.id }
            let others = spread(open.filter { $0.brand != seed.brand && !seedSubs.isDisjoint(with: $0.subs) }.distinctLooking(), limit: 8, mix: mix)
            let brand = open.filter { $0.brand == seed.brand && $0.title.lowercased() != title }.distinctLooking()
            let sameBrand = Array((brand.filter { !seedSubs.isDisjoint(with: $0.subs) } + brand.filter { seedSubs.isDisjoint(with: $0.subs) }).prefix(6))
            var picked: [Product] = []
            for i in 0..<max(others.count, sameBrand.count) where picked.count < 12 {
                if i < others.count { picked.append(others[i]) }
                if i < sameBrand.count, picked.count < 12 { picked.append(sameBrand[i]) }
            }
            guard picked.count >= 4 else { continue }
            rows.append(ForYouRow(id: "aisle:\(key)", title: String(localized: "More for your \(aisle.name.lowercased())", comment: "Home row title: more for an aisle the shopper bought from or liked; the argument is the aisle's name, e.g. laundry"), products: picked))
            taken.formUnion(picked.map(\.id))
        }
        return rows
    }

    /// Departments that read as one kind of shopping: an outfit and what
    /// goes with it.
    static let fashionDepartments: Set<String> = ["clothing", "shoes", "jewelry", "accessories", "bags"]
    static func departmentKind(_ category: String) -> String { fashionDepartments.contains(category) ? "fashion" : category }
    /// Keeps 3-4 slots of a taste row for departments other than the one (or
    /// two) the shopper leans on most (owner, 2026-10-10: "lets reserve 3-4
    /// slots for other departments"), so Home doesn't narrow to one aisle.
    /// Clothing, shoes, jewelry, accessories and bags count as one here
    /// (`fashionDepartments`): earrings beside a dress still read as clothes
    /// (owner, 2026-11-09). The slots come only from departments the shopper
    /// bought from, liked, looked at (`lean`) or searched (`searched`), one
    /// per kind, never one they've shown no interest in (owner, 2026-11-09:
    /// "if they never purchase dog food or search for it we should never show
    /// it"); with none, the row stays as it is. A slot's product comes from
    /// the aisles the shopper's own items (`seeds`) sit in. Placed through the
    /// row (3rd, 6th, 9th, 12th), not tacked on the end. Hidden and bought
    /// items never fill them.
    func reservingOtherDepartments(_ row: [Product], pool: [Product], lean: [(category: String, weight: Double)],
                                   searched: [String] = [], seeds: [Product] = [],
                                   excluded: Set<String>, mix: BrandMix? = nil) -> (products: [Product], reserved: Set<String>) {
        guard row.count >= 4 else { return (row, []) }
        let reserve = row.count >= 10 ? 4 : 3
        let kind = Self.departmentKind
        var byKind: [String: Double] = [:]
        for l in lean { byKind[kind(l.category), default: 0] += l.weight }
        let kinds = byKind.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var dominantKinds: Set<String> = []
        if let top = kinds.first {
            dominantKinds.insert(top.key)
            if kinds.count > 1, kinds[1].value >= 0.75 * top.value { dominantKinds.insert(kinds[1].key) }
        } else if let most = Dictionary(grouping: row, by: { kind($0.category) }).max(by: { $0.value.count < $1.value.count })?.key {
            dominantKinds.insert(most)
        }
        let dominant = { (c: String) in dominantKinds.contains(kind(c)) }
        let already = row.filter { !dominant($0.category) }.count
        let need = max(0, reserve - already)
        guard need > 0 else { return (row, []) }
        var departments: [String] = []
        for c in lean.map(\.category) + searched where !dominant(c) && !departments.contains(c) { departments.append(c) }
        let aisles = Dictionary(grouping: seeds, by: \.category).mapValues { Set($0.flatMap(\.subs)) }
        var picks: [Product] = []
        var taken = Set(row.map(\.id)).union(excluded)
        var kindsUsed: Set<String> = []
        for c in departments where picks.count < need && !kindsUsed.contains(kind(c)) {
            let open = products(in: c).filter { $0.available && !taken.contains($0.id) }
            let subs = aisles[c] ?? []
            let candidate = pool.first { $0.category == c && !taken.contains($0.id) && $0.available }
                ?? spread(open.filter { !subs.isDisjoint(with: $0.subs) }, limit: 1, mix: mix).first
                ?? spread(open, limit: 1, mix: mix).first
            if let p = candidate { picks.append(p); taken.insert(p.id); kindsUsed.insert(kind(c)) }
        }
        guard !picks.isEmpty else { return (row, []) }
        // Drop the lowest-ranked dominant-department items to make room.
        var kept = row
        var toDrop = picks.count
        for i in kept.indices.reversed() where toDrop > 0 && dominant(kept[i].category) {
            kept.remove(at: i); toDrop -= 1
        }
        let slots = [2, 5, 8, 11]
        for (n, p) in picks.enumerated() { kept.insert(p, at: min(slots[n], kept.count)) }
        return (Array(kept.prefix(row.count)), Set(picks.map(\.id)))
    }

    /// In-stock products most like `seeds`, across brands: the same kind of
    /// product counts most, then the same category, then shared tags. A
    /// product has to share a kind or category — tags alone ("sale", "new")
    /// say nothing.
    func related(to seeds: [Product], excluding: Set<String>) -> [Product] {
        guard !seeds.isEmpty else { return [] }
        let kinds = Set(seeds.compactMap { $0.productType?.lowercased() }.filter { !$0.isEmpty })
        let categories = Set(seeds.map(\.category))
        let tags = Set(seeds.flatMap { $0.tags.map { $0.lowercased() } })
        var scored: [(product: Product, score: Int)] = []
        for p in catalog.products where p.available && !excluding.contains(p.id) {
            var s = 0
            if let k = p.productType?.lowercased(), kinds.contains(k) { s += 3 }
            if categories.contains(p.category) { s += 2 }
            guard s > 0 else { continue }
            s += min(3, p.tags.reduce(0) { $0 + (tags.contains($1.lowercased()) ? 1 : 0) })
            scored.append((p, s))
        }
        return scored.sorted { $0.score > $1.score }.map(\.product)
    }
}

extension Array {
    /// The same items starting `k` places along and wrapping round:
    /// `[a, b, c].rotated(by: 1)` is `[b, c, a]`. What a pull to refresh does
    /// to a row that has one right order (best match first, most due first):
    /// nothing is dropped, something else leads.
    func rotated(by k: Int) -> [Element] {
        guard count > 1 else { return self }
        let k = ((k % count) + count) % count
        return k == 0 ? self : Array(self[k...] + self[..<k])
    }
}

/// Which brands Home leads with. Brands are shuffled once per launch; each
/// pull-to-refresh bumps `round`, which rotates every list past the brands
/// that were just up front, so the page comes back led by ones you didn't
/// just see — until the rotation wraps around.
struct BrandMix: Equatable {
    private(set) var round = 0
    private let seed: Int

    init(seed: Int = BrandMix.launchSeed) { self.seed = seed }

    /// This launch's seed was picked by the launch before it, which saved the
    /// images it leads with; the next launch's seed is picked now, for the same
    /// reason. Home still opens different every launch.
    private static let seedKey = "home.nextSeed"
    static let launchSeed: Int = {
        let d = UserDefaults.standard
        let current = (d.object(forKey: seedKey) as? Int) ?? Int.random(in: 0...Int.max)
        d.set(Int.random(in: 0...Int.max), forKey: seedKey)
        return current
    }()
    static var nextLaunchSeed: Int { _ = launchSeed; return UserDefaults.standard.integer(forKey: seedKey) }

    mutating func next() { round += 1 }

    /// Identifies this launch's arrangement at its current round.
    var key: String { "\(seed)-\(round)" }

    /// Shuffles `items` by this launch's seed, then rotates `step` places per round.
    func arrange<T>(_ items: [T], id: (T) -> String, step: Int) -> [T] {
        guard !items.isEmpty else { return [] }
        // Each id hashed once, then sorted by the hash (the same order as
        // hashing inside the comparator, which hashed ~n log n times: Home
        // arranges all 1,300 brands several times per draw).
        let shuffled = items.map { (CatalogStore.hash(id($0), seed: seed), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        let k = (round * max(step, 1)) % shuffled.count
        return Array(shuffled[k...] + shuffled[..<k])
    }

    /// The premier brands in a fresh order every round, so no one brand owns
    /// the first slot.
    func premierOrder<T>(_ items: [T], id: (T) -> String) -> [T] {
        let s = seed &+ round &* 7919
        return items.map { (CatalogStore.hash(id($0), seed: s), $0) }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The product a premier brand shows this round. Its catalog stays in a
    /// fixed order; each launch starts somewhere different in it and every
    /// refresh moves one product along, so a refresh always shows the next
    /// product instead of a random draw that could repeat.
    ///
    /// One product per title: Fear of God lists each colourway of a hoodie as
    /// its own product under the same name, and stepping onto the same hoodie
    /// in another colour reads as nothing having changed.
    ///
    /// A brand in `premierFeatureKinds` shows only that kind, and a sold-out
    /// one before none at all: Curves' totes come in limited drops and are
    /// often all sold out, and the owner wants a tote there regardless.
    func featured(_ products: some Sequence<Product>, brand: String) -> Product? {
        var products = products.filter { !$0.images.isEmpty }
        if let kind = CatalogStore.premierFeatureKinds[brand] {
            products = products.filter { $0.title.lowercased().contains(kind) }
        }
        if products.contains(where: \.available) || CatalogStore.premierFeatureKinds[brand] == nil {
            products = products.filter(\.available)
        }
        var titles = Set<String>()
        let pool = products.filter { titles.insert($0.title.lowercased()).inserted }
        guard !pool.isEmpty else { return nil }
        let start = Int(CatalogStore.hash(brand, seed: seed) % UInt64(pool.count))
        return pool[(start + round) % pool.count]
    }

    /// A fresh shuffle every round, for grids with no brand order to keep.
    func shuffle(_ products: [Product]) -> [Product] {
        let s = seed &+ round
        return products
            .map { (CatalogStore.hash($0.id, seed: s), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

struct SearchSuggestion: Identifiable, Hashable {
    enum Kind: Hashable, Codable {
        case category(String)
        /// An aisle inside a category, by `Subcategory.id`.
        case subcategory(String)
        case brand(String)
        /// Runs a search for the text.
        case query
    }
    let text: String
    let kind: Kind
    let image: String?
    let trending: Bool
    /// The grey line under the name: "Brand", "Category", or — for a kind of
    /// product or a product title — the category it sits in.
    var subtitle: String? = nil
    /// The echo of what the shopper typed, which runs the text search. It is
    /// pinned above the ranked suggestions and isn't one of them, so it keeps
    /// its own identity rather than competing with the trending picks.
    var searchesAll = false
    var id: String { "\(kind)|\(text)" }
}

/// One way to finish a search, mined from product titles.
struct Completion {
    let text: String
    let image: String?
    let category: String?
    let score: Int
    let exactWord: Bool
}

/// A suggestable phrase and what's behind it. Codable for SearchCache.
struct SuggestionTerm: Codable {
    let text: String
    let key: String
    let kind: SearchSuggestion.Kind
    let image: String?
    let count: Int
    let heat: Int
    /// The category its products mostly sit in — what makes it a subcategory.
    var category: String? = nil
    /// How many brands sell it *in that category*. One brand's sideline (a bag
    /// label's throw blanket) isn't a subcategory of Bags.
    var brandCount: Int = 0
    var trending = false

    /// The typed text starts the phrase or one of its words ("gloss" finds "lip gloss").
    func matches(_ q: String, _ singularQ: String) -> Bool {
        text.hasPrefix(q) || text.contains(" " + q) || key.hasPrefix(singularQ) || key.contains(" " + singularQ)
    }
}


/// Some of the catalog's products, by position: what a brand, a department
/// or one of Home's whole-catalog orders holds. It reads like an array of
/// products, but holds 4 bytes per product instead of a 320-byte copy, so the
/// store's indexes no longer hold the catalog over again (2026-10-11).
struct ProductList: RandomAccessCollection {
    private let all: [Product]
    private let positions: [Int32]

    init(_ all: [Product], _ positions: [Int32]) {
        self.all = all
        self.positions = positions
    }

    var startIndex: Int { 0 }
    var endIndex: Int { positions.count }
    subscript(i: Int) -> Product { all[Int(positions[i])] }
}


/// What departments each recent search was about, kept between launches so
/// Home needn't run those searches again before the word index is ready
/// (`CatalogStore.searchedDepartments`). On the device only, beside the
/// recent searches themselves; `-UITEST_RESET` and "Clear history" drop it
/// with them, since only current searches are kept.
enum SearchedDepartments {
    static let key = "search.departments"

    static func load(_ defaults: UserDefaults = .standard) -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    /// Saves the answers for the shopper's current searches only.
    static func save(_ known: [String: [String]], keeping searches: [String], defaults: UserDefaults = .standard) {
        let current = Set(searches.map { $0.lowercased() })
        defaults.set(known.filter { current.contains($0.key) }, forKey: key)
    }
}
