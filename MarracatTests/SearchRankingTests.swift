import XCTest
@testable import Marracat

/// A search whose matches all come from one brand still leads with its best
/// match, as the website's search does (owner, 2026-10-31: "make sure both
/// search works the same").
final class SearchRankingTests: XCTestCase {
    private func item(_ id: String, _ title: String) -> Product {
        Product(id: id, brand: "b", title: title, category: "clothing", productType: nil, subs: [],
                price: 20, compareAt: nil, images: [], url: "u", available: true, variants: [],
                tags: [], description: nil, publishedAt: nil, bestRank: nil)
    }

    func testOneBrandsMatchesKeepTheirRanking() {
        let ranked = [(item("classic", "Classic Top"), 7), (item("womens", "Womens Pink Top"), 21), (item("pink", "Pink Top"), 19)]
        XCTAssertEqual(CatalogStore.interleaveBrands(ranked, seed: 1).map(\.id), ["womens", "pink", "classic"])
    }

    func testEqualScoresKeepCatalogOrder() {
        let ranked = [(item("x", "X"), 0), (item("y", "Y"), 0), (item("z", "Z"), 0)]
        XCTAssertEqual(CatalogStore.interleaveBrands(ranked, seed: 1).map(\.id), ["x", "y", "z"])
    }
}
