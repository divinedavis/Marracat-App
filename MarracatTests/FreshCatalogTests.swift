import XCTest
@testable import Marracat

/// Faster refreshes for what a shopper keeps coming back to (owner,
/// 2026-10-20/21): the 5 / 15 / 30 minute rule, which brands it covers, and
/// how a store's live copy lays over the catalog.
@MainActor
final class FreshCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    private let day: TimeInterval = 86_400

    private func fresh() -> FreshCatalog {
        let d = UserDefaults(suiteName: "fresh-catalog-test")!
        d.removePersistentDomain(forName: "fresh-catalog-test")
        return FreshCatalog(defaults: d)
    }

    func testFourLooksInAWeekSpeedUpAndCoolDown() {
        XCTAssertNil(FreshCatalog.interval(looks: [ago(60), ago(120), ago(180)], now: now), "three looks: the 3-hour catalog")
        XCTAssertEqual(FreshCatalog.interval(looks: [ago(day * 2), ago(day), ago(3600), ago(60)], now: now), 5 * 60)
        XCTAssertEqual(FreshCatalog.interval(looks: [ago(day * 2.5), ago(day * 2), ago(day * 1.5), ago(day * 1.2)], now: now), 15 * 60)
        XCTAssertEqual(FreshCatalog.interval(looks: [ago(day * 6), ago(day * 5), ago(day * 4), ago(day * 3.5)], now: now), 30 * 60)
        XCTAssertNil(FreshCatalog.interval(looks: [ago(day * 9), ago(day * 8), ago(day * 2), ago(60)], now: now),
                     "looks older than a week don't count")
    }

    func testABrandTakesTheFastestOfItsProductsAndItsPage() {
        let f = fresh()
        let p = product("telfar-1", brand: "telfar")
        for t in [day * 2.5, day * 2, day * 1.5, day * 1.2] { f.productViewed(p, now: ago(t)) }
        XCTAssertEqual(f.interval(forBrand: "telfar", now: now), 15 * 60, "a product's views speed up its whole brand")
        for t in [3600.0, 1800, 600, 60] { f.brandVisited("telfar", now: ago(t)) }
        XCTAssertEqual(f.interval(forBrand: "telfar", now: now), 5 * 60, "page visits too; the fastest wins")
        XCTAssertNil(f.interval(forBrand: "koba-skincare", now: now))
        XCTAssertTrue(f.isDue("telfar", now: now), "never fetched yet")
        f.forget()
        XCTAssertNil(f.interval(forBrand: "telfar", now: now), "clearing history forgets the looks")
    }

    func testTheStoresCopyLaysOverTheCatalog() throws {
        let catalog = CatalogStore(synchronously: true)
        let known = try XCTUnwrap(catalog.catalog.products.first { $0.available && !$0.variants.isEmpty })
        let f = FreshCatalog.shared
        defer { f.clear() }
        var live = known
        live.price = known.price + 1
        live.compareAt = nil
        live.available = false
        live.category = ""   // the server doesn't know departments
        let newcomer = Product(id: known.brand + "-999999999999", brand: known.brand, title: "Just dropped", category: "",
                           productType: nil, subs: [], price: 20, compareAt: nil, images: ["https://example.com/a.jpg"],
                           url: "https://example.com/p", available: true, variants: [], tags: [], description: nil,
                           publishedAt: "2026-10-21", bestRank: nil, currency: "USD")
        f.merge([live, newcomer], brand: known.brand, catalog: catalog)
        let seen = try XCTUnwrap(catalog.product(known.id))
        XCTAssertEqual(seen.price, known.price + 1, "the store's price")
        XCTAssertFalse(seen.available, "the store's stock")
        XCTAssertEqual(seen.category, known.category, "the catalog's department stays")
        XCTAssertEqual(catalog.baseProduct(known.id)?.price, known.price, "the catalog itself is untouched")
        let arrival = try XCTUnwrap(catalog.product(newcomer.id), "a new product is found by id")
        XCTAssertEqual(arrival.category, catalog.brand(known.brand)?.category, "placed in its brand's department")
        XCTAssertEqual(f.arrivals[known.brand]?.map(\.id), [newcomer.id])
        // A copy identical to the catalog's lays nothing over it.
        f.merge([known], brand: known.brand, catalog: catalog)
        XCTAssertNil(f.overlay[known.id])
    }

    func testLiveStockUpdatesARestockAlertProduct() throws {
        let catalog = CatalogStore(synchronously: true)
        let known = try XCTUnwrap(catalog.catalog.products.first { !$0.available && !$0.variants.isEmpty })
        let f = FreshCatalog.shared
        defer { f.clear() }
        let v = known.variants[0]
        f.applyStock(LiveStock(live: true, available: true, variants: [.init(id: v.id, title: v.title, available: true)]), to: known)
        XCTAssertTrue(catalog.product(known.id)?.available == true)
        XCTAssertTrue(catalog.product(known.id)?.variants.first?.available == true)
    }

    private func product(_ id: String, brand: String) -> Product {
        Product(id: id, brand: brand, title: id, category: "bags", productType: nil, subs: [], price: 10, compareAt: nil,
                images: [], url: "https://example.com", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, currency: "USD")
    }
}
