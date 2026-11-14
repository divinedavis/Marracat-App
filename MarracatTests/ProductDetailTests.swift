import XCTest
@testable import Marracat

/// A stand-in origin, so these never touch the network.
private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var body: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { Self.requests.append(url) }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = Self.body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ProductDetailTests: XCTestCase {
    private func store() -> ProductDetailStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.requests = []
        StubProtocol.status = 200
        return ProductDetailStore(session: URLSession(configuration: config))
    }

    /// Each colour's photo arrives with the variants, as an index into the
    /// fetched photo list; the page turns to it on a pick (2026-10-17).
    func testVariantsCarryTheirOwnPhoto() async throws {
        StubProtocol.body = Data(#"{"images":["a.jpg","b.jpg","c.jpg"],"variants":[{"id":1,"title":"Deep Wine","price":1475,"available":true,"image":2},{"id":2,"title":"Cream","price":1475,"available":false}]}"#.utf8)
        let details = store()
        await details.load("brand-123")
        let variants = try XCTUnwrap(details.detail("brand-123")?.variants)
        XCTAssertEqual(variants.first { $0.id == 1 }?.image, 2)
        XCTAssertNil(variants.first { $0.id == 2 }?.image)
    }

    func testFetchesTheDescriptionAndGalleryAProductPageNeeds() async throws {
        StubProtocol.body = Data(#"{"description":"Hand-poured in Brooklyn.","images":["a.jpg","b.jpg","c.jpg"]}"#.utf8)
        let details = store()
        await details.load("brand-123")
        let detail = try XCTUnwrap(details.detail("brand-123"))
        XCTAssertEqual(detail.description, "Hand-poured in Brooklyn.")
        XCTAssertEqual(detail.images?.count, 3)
        XCTAssertEqual(StubProtocol.requests.first?.path, "/api/products/brand-123")
    }

    /// The catalog leaves variants out of anything with sizes or colours, so
    /// the page's fetch must bring them, prices and stock included, or the
    /// product reads as unavailable (build 70).
    func testFetchBringsTheVariantsTheCatalogLeavesOut() async throws {
        StubProtocol.body = Data(#"{"variants":[{"id":42363863728369,"title":"4x6 inches","price":20,"compare_at":null,"available":false},{"id":42363863761137,"title":"5x7 inches","price":25,"compare_at":30,"available":true}]}"#.utf8)
        let details = store()
        await details.load("domoink-5634392293540")
        let variants = try XCTUnwrap(details.detail("domoink-5634392293540")?.variants)
        XCTAssertEqual(variants.map(\.title), ["4x6 inches", "5x7 inches"])
        XCTAssertEqual(variants.last?.compareAt, 30)
        XCTAssertEqual(variants.first(where: \.available)?.price, 25)
    }

    /// A product page is opened from search, from Home, from a list; the
    /// description doesn't change in between.
    func testAsksOncePerProduct() async {
        StubProtocol.body = Data(#"{"description":"x"}"#.utf8)
        let details = store()
        await details.load("brand-123")
        await details.load("brand-123")
        await details.load("brand-123")
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// The page already has the title, price, variants and first image, so a
    /// failed fetch is a shorter page, not a broken one.
    func testAFailedFetchIsSilent() async {
        StubProtocol.status = 500
        StubProtocol.body = Data("nope".utf8)
        let details = store()
        await details.load("brand-123")
        XCTAssertNil(details.detail("brand-123"))
    }

    // MARK: Live stock (2026-10-11: a "Back in stock" push opened a page that
    // still said "Currently unavailable" from a catalog older than the restock)

    private let soldOut = [Variant(id: 51739067744487, title: "Default Title", price: 228, compareAt: 317, available: false)]

    func testLiveStockOverridesAStaleCatalogSoldOut() {
        let live = LiveStock(live: true, available: true,
                             variants: [.init(id: 51739067744487, title: "Default Title", available: true, price: 200, compareAt: 317)])
        let v = LiveStock.overlay(soldOut, live: live, fallbackPrice: 228)
        XCTAssertEqual(v.first?.available, true)
        XCTAssertEqual(v.first?.price, 200)
        XCTAssertEqual(v.first?.compareAt, 317)
        XCTAssertEqual(v.first?.title, "Default Title")
    }

    func testNoLiveAnswerKeepsTheCatalog() {
        XCTAssertEqual(LiveStock.overlay(soldOut, live: nil, fallbackPrice: 228), soldOut)
        XCTAssertEqual(LiveStock.overlay(soldOut, live: LiveStock(live: false), fallbackPrice: 228), soldOut)
    }

    func testStockWithoutPriceKeepsTheCatalogPrice() {
        let live = LiveStock(live: true, available: true, variants: [.init(id: 51739067744487, available: true)])
        let v = LiveStock.overlay(soldOut, live: live, fallbackPrice: 228)
        XCTAssertEqual(v.first?.price, 228)
        XCTAssertEqual(v.first?.available, true)
    }

    func testOptionsTheStoreDoesntListKeepTheCatalogValues() {
        let base = soldOut + [Variant(id: 9, title: "Travel", price: 30, compareAt: nil, available: true)]
        let live = LiveStock(live: true, available: true, variants: [.init(id: 51739067744487, available: true)])
        let v = LiveStock.overlay(base, live: live, fallbackPrice: 228)
        XCTAssertEqual(v.map(\.available), [true, true])
        XCTAssertEqual(v.last?.price, 30)
    }

    func testWithNoCatalogOptionsTheStoresListStandsIn() {
        let live = LiveStock(live: true, available: true, variants: [
            .init(id: 1, title: "S", available: false, price: 20), .init(id: 2, title: "M", available: true)])
        let v = LiveStock.overlay([], live: live, fallbackPrice: 18)
        XCTAssertEqual(v.map(\.title), ["S", "M"])
        XCTAssertEqual(v.map(\.price), [20, 18])
        XCTAssertEqual(v.map(\.available), [false, true])
    }

    func testProductLevelAnswerAppliesToEveryOption() {
        let v = LiveStock.overlay(soldOut, live: LiveStock(live: true, available: true), fallbackPrice: 228)
        XCTAssertEqual(v.first?.available, true)
    }

    func testLoadsLiveStockFreshAndKeepsItBriefly() async throws {
        StubProtocol.body = Data(#"{"id":"sienna-naturals-9444756422887","live":true,"available":true,"variants":[{"id":51739067744487,"title":"Default Title","available":true,"price":228,"compare_at":317}],"checked_at":"2026-10-12T02:26:00Z"}"#.utf8)
        let details = store()
        let t0 = Date()
        await details.loadStock("sienna-naturals-9444756422887", now: t0)
        let live = try XCTUnwrap(details.liveStock("sienna-naturals-9444756422887"))
        XCTAssertEqual(live.variants?.first?.compareAt, 317)
        XCTAssertEqual(StubProtocol.requests.last?.path, "/api/products/sienna-naturals-9444756422887/stock")
        await details.loadStock("sienna-naturals-9444756422887", now: t0.addingTimeInterval(30))
        XCTAssertEqual(StubProtocol.requests.count, 1, "fresh enough: not asked again")
        await details.loadStock("sienna-naturals-9444756422887", now: t0.addingTimeInterval(ProductDetailStore.stockFreshFor + 1))
        XCTAssertEqual(StubProtocol.requests.count, 2, "stale: asked again")
    }

    /// A tapped "Back in stock" push asks the store again, whatever is cached.
    func testForgettingStockMakesTheNextLookAskAgain() async {
        StubProtocol.body = Data(#"{"id":"x","live":true,"available":false,"variants":[]}"#.utf8)
        let details = store()
        await details.loadStock("x")
        details.forgetStock("x")
        XCTAssertNil(details.liveStock("x"))
        await details.loadStock("x")
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testAFailedOrNotLiveStockAnswerKeepsNothing() async {
        let details = store()
        StubProtocol.body = Data(#"{"id":"x","live":false}"#.utf8)
        await details.loadStock("x")
        XCTAssertNil(details.liveStock("x"))
        StubProtocol.status = 503
        StubProtocol.body = Data("down".utf8)
        await details.loadStock("x")
        XCTAssertNil(details.liveStock("x"))
        XCTAssertFalse(details.isCheckingStock("x"))
    }

    /// The bundled catalog is the compact one: no descriptions, one image per
    /// product, and the organic badge decided at build time instead.
    func testTheBundledCatalogIsCompactButStillShops() throws {
        let catalog = CatalogStore(synchronously: true)
        let products = catalog.catalog.products
        XCTAssertGreaterThan(products.count, 30_000)
        XCTAssertTrue(products.allSatisfy { ($0.description ?? "").isEmpty },
                      "descriptions belong to /api/products/:id now")
        XCTAssertTrue(products.allSatisfy { $0.images.count <= 1 })
        // A product with choices travels as option words, not variants: those
        // were 56% of the catalog, and its page fetches them.
        let withOptions = products.filter { !($0.opts ?? []).isEmpty }
        XCTAssertGreaterThan(withOptions.count, 1_000)
        XCTAssertTrue(withOptions.allSatisfy { $0.variants.isEmpty })
        XCTAssertTrue(withOptions.allSatisfy { $0.hasOptions }, "a page must still offer the choice")
        // One thing to buy still goes straight into a basket from a grid.
        XCTAssertGreaterThan(products.filter { $0.variants.count == 1 }.count, 1_000)
        XCTAssertTrue(products.contains { $0.isCertifiedOrganic },
                      "the organic badge should survive losing the description")
    }
}
