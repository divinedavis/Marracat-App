import XCTest
@testable import Marracat

/// SearchCache (2026-10-18): search's suggestion terms and word index, saved
/// for the catalog they came from and read back on the next launch.
final class SearchCacheTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString).bin")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func item(_ id: String, _ title: String, brand: String = "b", type: String? = "tote bag") -> Product {
        Product(id: id, brand: brand, title: title, category: "bags", productType: type, subs: [],
                price: 20, compareAt: nil, images: ["https://img.example/\(id).jpg"], url: "https://b.example/\(id)",
                available: true, variants: [], tags: ["Canvas"], description: nil, publishedAt: nil, bestRank: 1, clean: false)
    }

    private func small(_ date: String = "2026-10-18", ids: [String] = ["a", "b", "c"]) -> Catalog {
        Catalog(generatedAt: date, categories: [], subcategories: [], brands: [],
                products: ids.enumerated().map { item($1, "Canvas Tote Bag \($1)", brand: $0 % 2 == 0 ? "x" : "y") })
    }

    private func assertSame(_ a: SearchCache.Indexes, _ b: SearchCache.Indexes, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.words.words, b.words.words, file: file, line: line)
        XCTAssertEqual(a.words.postings, b.words.postings, file: file, line: line)
        XCTAssertEqual(a.words.generatedAt, b.words.generatedAt, file: file, line: line)
        XCTAssertEqual(a.terms.count, b.terms.count, file: file, line: line)
        for (x, y) in zip(a.terms, b.terms) {
            XCTAssertTrue(x.text == y.text && x.key == y.key && x.kind == y.kind && x.image == y.image && x.count == y.count
                          && x.heat == y.heat && x.category == y.category && x.brandCount == y.brandCount
                          && x.trending == y.trending, "\(x.text) != \(y.text)", file: file, line: line)
        }
    }

    /// The whole bundled catalog: what's read back is exactly what was built,
    /// and reading it is far cheaper than building it.
    @MainActor
    func testSavedIndexesReadBackIdenticalOnTheBundledCatalog() throws {
        let catalog = CatalogStore(synchronously: true).catalog
        XCTAssertGreaterThan(catalog.products.count, 50_000)
        var t = Date()
        let built = SearchCache.build(catalog)
        let buildMs = Date().timeIntervalSince(t) * 1000
        let key = SearchCache.key(catalog)
        SearchCache.save(built, key: key, to: file)
        t = Date()
        let read = try XCTUnwrap(SearchCache.load(key: key, generatedAt: catalog.generatedAt,
                                                  products: catalog.products.count, from: file))
        let loadMs = Date().timeIntervalSince(t) * 1000
        print("SearchCache: built in \(Int(buildMs)) ms, read in \(Int(loadMs)) ms, \(read.terms.count) terms, \(read.words.words.count) words")
        assertSame(built, read)
        XCTAssertLessThan(loadMs, buildMs / 3, "reading the saved indexes should be far cheaper than building them")
        XCTAssertFalse(CatalogStore(catalog: catalog).search("tote").isEmpty)
    }

    func testAnotherCatalogsFileIsIgnored() {
        let c = small()
        SearchCache.save(SearchCache.build(c), key: SearchCache.key(c, build: "1"), to: file)
        XCTAssertNotNil(SearchCache.load(key: SearchCache.key(c, build: "1"), generatedAt: c.generatedAt, products: 3, from: file))
        XCTAssertNil(SearchCache.load(key: SearchCache.key(c, build: "2"), generatedAt: c.generatedAt, products: 3, from: file),
                     "a new app build rebuilds")
        XCTAssertNil(SearchCache.load(key: SearchCache.key(small(ids: ["a", "b", "d"]), build: "1"),
                                      generatedAt: c.generatedAt, products: 3, from: file),
                     "same date and size, different products")
    }

    func testKeyFollowsTheProductsNotJustTheDate() {
        XCTAssertEqual(SearchCache.key(small(), build: "1"), SearchCache.key(small(), build: "1"))
        XCTAssertNotEqual(SearchCache.key(small(), build: "1"), SearchCache.key(small("2026-10-19"), build: "1"))
        XCTAssertNotEqual(SearchCache.key(small(ids: ["a", "b", "c"]), build: "1"), SearchCache.key(small(ids: ["a", "c", "b"]), build: "1"))
    }

    /// A posting past the end of the catalog in hand would crash a search.
    func testPostingPastTheEndIsRefused() {
        let c = small()
        let key = SearchCache.key(c, build: "1")
        SearchCache.save(SearchCache.build(c), key: key, to: file)
        XCTAssertNil(SearchCache.load(key: key, generatedAt: c.generatedAt, products: 2, from: file))
    }

    func testTruncatedOrMissingFileIsIgnored() throws {
        let c = small()
        let key = SearchCache.key(c, build: "1")
        XCTAssertNil(SearchCache.load(key: key, generatedAt: c.generatedAt, products: 3, from: file))
        SearchCache.save(SearchCache.build(c), key: key, to: file)
        let data = try Data(contentsOf: file)
        for cut in [4, data.count / 2, data.count - 1] {
            try data.prefix(cut).write(to: file)
            XCTAssertNil(SearchCache.load(key: key, generatedAt: c.generatedAt, products: 3, from: file), "cut at \(cut)")
        }
    }
}
