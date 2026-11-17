import XCTest
@testable import Marracat

/// Sex toys stay off Home's shared rows (owner, 2026-11-16): deals, new
/// arrivals, Discover more and each department's top picks. Search, their
/// department and their brand's page still list them.
final class KeptOffHomeTests: XCTestCase {
    private func item(_ id: String, subs: [String], category: String = "wellness", brand: String? = nil) -> Product {
        Product(id: id, brand: brand ?? id, title: id, category: category, productType: nil, subs: subs,
                price: 20, compareAt: 40, images: ["https://img.example/\(id).jpg"], url: "https://b.example/\(id)",
                available: true, variants: [], tags: [], description: nil, publishedAt: "2026-11-15T00:00:00Z",
                bestRank: 1, clean: false)
    }

    func testOnlyTheSexualWellnessAisleIsKeptOffHome() {
        XCTAssertTrue(item("harness", subs: ["sexual-wellness"]).keptOffHome)
        XCTAssertFalse(item("pads", subs: ["womens-health"]).keptOffHome)
        XCTAssertFalse(item("tote", subs: [], category: "bags").keptOffHome)
    }

    func testDealsAndNewArrivalsLeaveThemOut() {
        let products = [item("harness", subs: ["sexual-wellness"]), item("pads", subs: ["womens-health"])]
        XCTAssertEqual(CatalogOrder.deals(products).map { products[Int($0)].id }, ["pads"])
        XCTAssertEqual(CatalogOrder.newArrivals(products, asOf: "2026-11-16").map { products[Int($0)].id }, ["pads"])
    }

    func testTheHomeSliceCarriesNoneForTheDepartmentRows() {
        // A brand's first product is still in the slice (its circle decides
        // on it), but deals and a department's top picks never draw on them.
        let products = [item("pads", subs: ["womens-health"], brand: "hp")]
            + (0..<20).map { item("toy\($0)", subs: ["sexual-wellness"], brand: "nytc") }
        let c = Catalog(generatedAt: "2026-11-16", categories: [], subcategories: [], brands: [], products: products)
        XCTAssertEqual(HomeSlice.indices(c).map { products[$0].id }, ["pads", "toy0"])
    }
}
