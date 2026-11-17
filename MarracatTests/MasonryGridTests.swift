import XCTest
@testable import Marracat

/// The brand page's masonry grid (owner, 2026-11-15, alternative #3).
final class MasonryGridTests: XCTestCase {
    private func product(_ id: String) -> Product {
        Product(id: id, brand: "b", title: id, category: "skincare", productType: nil, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil)
    }

    func testAPhotoKeepsItsShapeWhateverTheList() {
        let a = MasonryProductGrid.shape("gently-soap-123")
        XCTAssertEqual(a, MasonryProductGrid.shape("gently-soap-123"))
        XCTAssertTrue(MasonryProductGrid.shapes.contains(a))
    }

    func testTwoColumnsOnAPhoneMoreOnAnIPad() {
        XCTAssertEqual(MasonryProductGrid.columnCount(for: 366), 2)
        XCTAssertEqual(MasonryProductGrid.columnCount(for: 0), 2)
        XCTAssertGreaterThanOrEqual(MasonryProductGrid.columnCount(for: 1000), 5)
    }

    func testEveryProductOnceColumnsStayLevelAndInListOrder() {
        let products = (0..<21).map { product("p\($0)") }
        let cols = MasonryProductGrid.layout(products, columns: 2)
        XCTAssertEqual(cols.flatMap { $0.map(\.index) }.sorted(), Array(0..<21))
        for col in cols { XCTAssertEqual(col.map(\.index), col.map(\.index).sorted(), "top to bottom follows the list") }
        let height = cols.map { $0.reduce(CGFloat(0)) { $0 + MasonryProductGrid.shape($1.product.id) + 0.45 } }
        XCTAssertLessThan(abs(height[0] - height[1]), 1.8, "shortest-first keeps the columns within one tile")
        XCTAssertEqual(cols[0].first?.index, 0, "the first product starts the left column")
    }
}
