import XCTest
@testable import Marracat

/// Home's personal rows are saved as shown and read back before Home draws
/// (HomeRowsCache, owner 2026-10-11: "we definitely want these two rows to
/// load early"), and no row shows one product twice as a shopper sees it.
@MainActor
final class HomeRowsCacheTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("home-rows-\(UUID().uuidString).json")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: url) }

    private func product(_ id: String, brand: String = "b", title: String? = nil, clean: Bool? = nil, metal: String? = nil) -> Product {
        Product(id: id, brand: brand, title: title ?? "Item \(id)", category: "beauty", productType: "Serum", subs: ["face"],
                price: 38, compareAt: 45, images: ["https://cdn.example/\(id).jpg"], url: "https://b.example/\(id)",
                available: true, variants: [Variant(id: 1, title: "Default Title", price: 38, compareAt: nil, available: true)],
                tags: ["new"], description: nil, publishedAt: "2026-10-01", bestRank: 3, currency: "USD",
                organic: true, clean: clean, metal: metal)
    }

    private var sample: HomeRows {
        HomeRows(picked: (1...6).map { product("p\($0)", clean: $0 == 1, metal: $0 == 2 ? "gold" : nil) },
                 pickedReserved: ["p3"],
                 restock: [product("r1")],
                 rows: [HomeRows.Row(id: "search:organic body wash", title: "Inspired by your search for “organic body wash”",
                                     products: (1...5).map { product("s\($0)") }, reserved: [])],
                 keepShopping: [product("k1"), product("k2")])
    }

    /// Saved, then read back exactly — products with their badges' fields,
    /// titles, reserved slots and all.
    func testTheRowsRoundTrip() throws {
        HomeRowsCache.save(sample, to: url)
        HomeRowsCache.flush()
        let back = try XCTUnwrap(HomeRowsCache.load(from: url))
        XCTAssertEqual(back, sample)
        XCTAssertEqual(back.picked.map(\.id), ["p1", "p2", "p3", "p4", "p5", "p6"])
        XCTAssertEqual(back.picked[0].clean, true, "badge fields survive")
        XCTAssertEqual(back.rows.first?.title, "Inspired by your search for “organic body wash”")
    }

    /// Shop by style's boards (StyleBoardsCache): saved as worked out, read
    /// back for the next launch's first frame; none, or a damaged file, is
    /// nothing, and saving none removes the file.
    func testStyleBoardsRoundTrip() throws {
        let styles = url.deletingLastPathComponent().appendingPathComponent("style-boards-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: styles) }
        XCTAssertNil(StyleBoardsCache.load(from: styles))
        let boards = StyleBoards(boards: [.init(id: "urban-luxe", products: (1...6).map { product("u\($0)") }),
                                          .init(id: "natural-glow", products: (1...6).map { product("n\($0)", clean: true) })])
        StyleBoardsCache.save(boards, to: styles)
        StyleBoardsCache.flush()
        let back = try XCTUnwrap(StyleBoardsCache.load(from: styles))
        XCTAssertEqual(back, boards)
        XCTAssertTrue(back.boards.allSatisfy { b in ShopStyle.all.contains { $0.id == b.id } }, "saved by the ids ShopStyle knows")
        StyleBoardsCache.save(StyleBoards(), to: styles)
        StyleBoardsCache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: styles.path))
        try Data("{ not boards".utf8).write(to: styles)
        XCTAssertNil(StyleBoardsCache.load(from: styles))
    }

    func testNothingSavedReadsAsNothing() {
        XCTAssertNil(HomeRowsCache.load(from: url))
        try? Data("{ not rows".utf8).write(to: url)
        XCTAssertNil(HomeRowsCache.load(from: url), "a damaged file is ignored")
    }

    /// Clearing history (or empty rows) leaves no file behind.
    func testEmptyRowsRemoveTheFile() {
        HomeRowsCache.save(sample, to: url)
        HomeRowsCache.clear(url)
        HomeRowsCache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Products hidden since the rows were saved don't come back; a row left
    /// with fewer than four goes.
    func testHiddenProductsLeaveTheSavedRows() {
        let kept = sample.hiding(["p1", "s1", "s2", "k1"])
        XCTAssertEqual(kept.picked.map(\.id), ["p2", "p3", "p4", "p5", "p6"])
        XCTAssertTrue(kept.rows.isEmpty, "the search row fell to three")
        XCTAssertEqual(kept.keepShopping.map(\.id), ["k2"])
        XCTAssertEqual(sample.hiding([]), sample)
    }

    /// Fenty Hair's shampoo and conditioner read the same on a two-line tile
    /// ("The Rich One Moisture Repair…"): one of them per row. Other brands'
    /// products with the same name stay.
    func testOneTilePerProductAsTheShopperSeesIt() {
        let row = [
            product("a", brand: "fenty-hair", title: "The Rich One Moisture Repair Shampoo"),
            product("b", brand: "fenty-beauty", title: "Total Cleans'r Remove-It-All Cleanser"),
            product("c", brand: "fenty-hair", title: "The Rich One Moisture Repair Conditioner"),
            product("d", brand: "other", title: "The Rich One Moisture Repair Shampoo"),
            product("e", brand: "fenty-beauty", title: "Gloss Bomb Universal Lip Luminizer — Fenty Glow"),
            product("f", brand: "fenty-beauty", title: "Gloss Bomb Universal Lip Luminizer — Fu$$y"),
            product("g", brand: "fenty-beauty", title: "Gloss"),
        ]
        XCTAssertEqual(row.distinctLooking().map(\.id), ["a", "b", "d", "e", "g"])
    }

    /// Home's search and likes rows, built from the real catalog, never show
    /// the same thing twice.
    func testPersonalRowsHaveNoLookalikes() throws {
        let c = CatalogStore(synchronously: true)
        let fentyHair = c.products(for: "fenty-hair").filter(\.available).map(\.id)
        try XCTSkipIf(fentyHair.count < 2, "no Fenty Hair in this catalog")
        let rows = c.forYou(searches: ["moisture repair shampoo", "body wash"], viewed: Array(fentyHair.prefix(3)),
                            saved: Array(fentyHair.prefix(1)))
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let keys = row.products.map([Product].lookKey)
            XCTAssertEqual(Set(keys).count, keys.count, "\(row.title) repeats a product: \(row.products.map(\.title))")
        }
    }
}
