import XCTest
@testable import Marracat

/// A cold launch draws Home from a slice of the catalog and loads the rest
/// behind it (HomeSlice, 2026-10-11). Home must come out the same from the
/// slice as from the whole catalog, the bundled binary must be the bundled
/// catalog, and nothing that needs every product may run on the slice.
@MainActor
final class HomeSliceTests: XCTestCase {
    private static let bundle = Bundle(for: CatalogStore.self)

    /// The bundled catalog, read from the JSON the build made it from.
    private static let whole: Catalog = {
        let data = try! Data(contentsOf: CatalogSourceFile.compactJSON)
        return try! CatalogStore.decodeInParallel(data, snakeCase: !data.starts(with: Data(#"{"generatedAt""#.utf8)))
    }()

    /// The build bundles the binary of exactly the catalog's JSON, and not
    /// the JSON itself: the first launch after an update reads no JSON, and
    /// the app is 105 MB smaller (2026-10-18).
    func testTheBundledBinaryIsTheBundledCatalog() throws {
        let url = try XCTUnwrap(CatalogBinary.bundledURL(Self.bundle), "catalog.bin isn't in the app: run catalog/make_compact.py")
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        XCTAssertEqual(CatalogBinary.peekGeneratedAt(data), Self.whole.generatedAt, "catalog.bin is of another catalog")
        let binary = try XCTUnwrap(CatalogBinary.load(expecting: Self.whole.generatedAt, bundle: Self.bundle))
        XCTAssertEqual(binary.products, Self.whole.products)
        XCTAssertEqual(binary.brands, Self.whole.brands)
        XCTAssertEqual(binary.categories, Self.whole.categories)
        XCTAssertEqual(binary.subcategories, Self.whole.subcategories)
        XCTAssertNil(CatalogBinary.load(expecting: "1999-01-01", bundle: Self.bundle), "a binary of another date is never used")
    }

    func testTheBundledSliceIsTheBundledCatalogsSlice() throws {
        let slice = try XCTUnwrap(HomeSlice.load(expecting: Self.whole.generatedAt, bundle: Self.bundle))
        XCTAssertEqual(slice.products, HomeSlice.make(Self.whole).products)
        XCTAssertEqual(slice.brands, Self.whole.brands, "every brand, for the circles and the carousel")
        XCTAssertEqual(slice.categories, Self.whole.categories)
        XCTAssertLessThan(slice.products.count, Self.whole.products.count / 5, "the slice is meant to be small")
        XCTAssertNil(HomeSlice.load(expecting: "1999-01-01", bundle: Self.bundle))
    }

    /// A slice the app cut from a download of the same date never stands in
    /// for the bundled one: the full catalog comes from the bundle first
    /// (CatalogBinary), so the slice must too. The cache was read first until
    /// 2026-10-13, which made the test above fail on a simulator that held
    /// such a download (build 135 ship).
    func testACachedSliceOfTheSameDateDoesNotShadowTheBundledOne() throws {
        let url = try XCTUnwrap(HomeSlice.cacheURL)
        let saved = try? Data(contentsOf: url)
        defer {
            if let saved { try? saved.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
        }
        var other = Self.whole
        other.products = Array(Self.whole.products.prefix(25))
        try CatalogBinary.encode(other).write(to: url, options: .atomic)
        let slice = try XCTUnwrap(HomeSlice.load(expecting: Self.whole.generatedAt, bundle: Self.bundle))
        XCTAssertEqual(slice.products, HomeSlice.make(Self.whole).products, "the cached slice won over the bundled one")
    }

    /// The carousel is the premier brands and nothing else: no pages rotating
    /// through other brands (owner, 2026-11-04: "7 slots only").
    func testCarouselIsOnlyThePremierBrands() {
        let c = CatalogStore(catalog: Self.whole)
        for seed in [0, 1, 42] {
            let pages = HeroCarousel.spotlights(c, mix: BrandMix(seed: seed)).map(\.brand.id)
            XCTAssertEqual(pages.count, 7, "seed \(seed)")
            XCTAssertEqual(Set(pages), Set(CatalogStore.premierBrandIDs), "seed \(seed)")
        }
    }

    /// Every row Home opens on — the carousel, the brand circles, the square
    /// cards, deals, new arrivals and each department's top picks — is the
    /// same from the slice as from the whole catalog, whatever this launch's mix.
    func testHomeFromTheSliceIsHomeFromTheWholeCatalog() {
        let full = CatalogStore(catalog: Self.whole)
        let slice = CatalogStore(catalog: HomeSlice.make(Self.whole), complete: false)
        XCTAssertEqual(slice.categories.map(\.id), full.categories.map(\.id))
        XCTAssertEqual(slice.brands.map(\.id), full.brands.map(\.id))
        XCTAssertEqual(slice.deals.count >= 4, full.deals.count >= 4)
        for seed in [0, 1, 42, 7_777, 123_456_789, Int.max / 3] {
            let mix = BrandMix(seed: seed)
            func spot(_ c: CatalogStore) -> [String] {
                HeroCarousel.spotlights(c, mix: mix).map { "\($0.brand.id)|\($0.image ?? "")|\($0.product ?? "")" }
            }
            XCTAssertEqual(spot(slice), spot(full), "carousel, seed \(seed)")
            XCTAssertEqual(HomeImages.urls(slice, mix: mix), HomeImages.urls(full, mix: mix), "images warmed, seed \(seed)")
            var next = mix; next.next()
            XCTAssertEqual(HomeImages.urls(slice, mix: next), HomeImages.urls(full, mix: next), "first refresh, seed \(seed)")
            func row(_ c: CatalogStore, _ products: [Product], _ limit: Int) -> [String] {
                c.spread(products, limit: limit, mix: mix).map(\.id)
            }
            XCTAssertEqual(row(slice, Array(slice.deals), 12), row(full, Array(full.deals), 12), "deals, seed \(seed)")
            XCTAssertEqual(row(slice, Array(slice.deals), 4), row(full, Array(full.deals), 4), "deals card, seed \(seed)")
            XCTAssertEqual(row(slice, Array(slice.newArrivals), 4), row(full, Array(full.newArrivals), 4), "new arrivals, seed \(seed)")
            for c in full.categories {
                for limit in [12, 4] {
                    XCTAssertEqual(row(slice, slice.products(in: c.id).filter(\.available), limit),
                                   row(full, full.products(in: c.id).filter(\.available), limit),
                                   "\(c.id) picks (\(limit)), seed \(seed)")
                }
            }
        }
        for b in full.brands {
            XCTAssertEqual(slice.products(for: b.id).first?.images.first, full.products(for: b.id).first?.images.first,
                           "\(b.id)'s circle")
        }
    }

    /// The slice never answers for the whole catalog: search, suggestions and
    /// the shuffled "Discover more" grid wait for it.
    func testTheSliceWaitsForTheWholeCatalog() {
        let slice = CatalogStore(catalog: HomeSlice.make(Self.whole), complete: false)
        XCTAssertTrue(slice.isReady)
        XCTAssertFalse(slice.isComplete)
        XCTAssertTrue(slice.suggestions("sh").isEmpty)
        XCTAssertTrue(slice.discoverRow(mix: BrandMix(seed: 1), hidden: [], limit: 40).isEmpty)
        XCTAssertNotEqual(slice.stamp, CatalogStore(catalog: Self.whole).stamp, "memos kept outside tell them apart")
        let full = CatalogStore(catalog: Self.whole)
        XCTAssertTrue(full.isComplete)
        XCTAssertEqual(full.discoverRow(mix: BrandMix(seed: 1), hidden: [], limit: 40).count, 40)
    }

    /// The indexes hold positions; what they hand back is the catalog's own products.
    func testListsReadTheCatalogsProducts() throws {
        let full = CatalogStore(catalog: Self.whole)
        let p = try XCTUnwrap(Self.whole.products.dropFirst(500).first { $0.available })
        XCTAssertEqual(full.product(p.id), p)
        XCTAssertEqual(Array(full.products(for: p.brand)), Self.whole.products.filter { $0.brand == p.brand })
        XCTAssertEqual(Array(full.products(in: p.category)), Self.whole.products.filter { $0.category == p.category })
        // Deepest markdowns first, ties in catalog order — the old stable sort.
        let deals = Self.whole.products.filter { $0.available && $0.percentOff != nil }
            .sorted { ($0.percentOff ?? 0) > ($1.percentOff ?? 0) }
        XCTAssertEqual(full.deals.map(\.id), deals.map(\.id))
        // New: in stock and published in the 30 days before the catalog's
        // date, newest first (owner, 2026-10-27: "not the entire catalog").
        let since = CatalogOrder.newArrivalCutoff(Self.whole.generatedAt)
        let fresh = Self.whole.products.filter { $0.available && ($0.publishedAt ?? "").prefix(10) >= since }
            .sorted { ($0.publishedAt ?? "") > ($1.publishedAt ?? "") }
        XCTAssertEqual(full.newArrivals.map(\.id), fresh.map(\.id))
        XCTAssertLessThan(full.newArrivals.count, Self.whole.products.filter(\.available).count / 4, "New is a slice of the catalog, not all of it")
    }

    func testNewReachesBackThirtyDaysFromTheCatalogsDate() {
        XCTAssertEqual(CatalogOrder.newArrivalCutoff("2026-10-27T07:12:00Z"), "2026-09-27")
        XCTAssertEqual(CatalogOrder.newArrivalCutoff("2026-03-01T00:00:00Z"), "2026-01-30")
    }

    /// The New screen deals newest-first one brand at a time, so a shop that
    /// published hundreds of products at once can't fill the screen.
    func testTheNewScreenTakesTurnsByBrand() throws {
        let full = CatalogStore(catalog: Self.whole)
        let shown = CatalogStore.spread(Array(full.newArrivals), limit: full.newArrivals.count)
        XCTAssertEqual(Set(shown.map(\.id)), Set(full.newArrivals.map(\.id)), "every new product still shows")
        let brands = Set(shown.map(\.brand)).count
        try XCTSkipIf(brands < 2)
        XCTAssertEqual(Set(shown.prefix(brands).map(\.brand)).count, brands, "the first round is one product from each brand")
    }
}
