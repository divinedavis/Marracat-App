import XCTest
@testable import Marracat

/// Search work spread over every core (2026-10-02) must give exactly what a
/// single pass gives.
final class ParallelSearchTests: XCTestCase {
    static let catalog = CatalogStore(synchronously: true)
    override func tearDown() { CatalogStore.completionSlices = nil }

    func testParallelCompletionsMatchASinglePass() {
        let c = Self.catalog
        for q in ["ca", "sh", "vi", "bl", "shea b", "candle ", "black t", "du", "laundry de", "co", "be"] {
            CatalogStore.completionSlices = 1
            let one = c.completions(q).map { "\($0.text)|\($0.score)|\($0.category ?? "")|\($0.exactWord)" }
            CatalogStore.completionSlices = 6
            let many = c.completions(q).map { "\($0.text)|\($0.score)|\($0.category ?? "")|\($0.exactWord)" }
            XCTAssertEqual(one, many, "completions for “\(q)”")
            XCTAssertFalse(one.isEmpty || q == "be" && one.isEmpty, "“\(q)” should complete to something")
        }
    }

    func testParallelTitleSegmentsMatchOnePass() {
        let products = Self.catalog.catalog.products
        let one = CatalogStore.makeTitleSegments(products)
        let many = CatalogStore.makeTitleSegmentsInParallel(products)
        XCTAssertEqual(one.count, many.count)
        XCTAssertEqual(one.map(\.product), many.map(\.product))
        XCTAssertEqual(one.map(\.words), many.map(\.words))
    }

    func testIndexedSearchMatchesCheckingEveryProduct() {
        let full = Self.catalog
        let indexed = CatalogStore(synchronously: true)
        indexed.buildSearchIndexNow()
        let queries = ["vitamin d", "shea butter", "durag", "black tote bag", "candle", "dress", "candles", "d", "vi",
                       "bonnet satin", "t shirt", "café", "14k gold", "kids", "gift set", "hoodie black xl", "zzzqqq",
                       "oil", "body butter vanilla", "mens", "earrings", "it's", "2-pack", "durags"]
        for q in queries {
            XCTAssertEqual(indexed.search(q).map(\.id), full.search(q).map(\.id), "search “\(q)”")
        }
    }
}
