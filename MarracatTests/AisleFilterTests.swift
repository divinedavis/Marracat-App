import Foundation
import Testing
@testable import Marracat

/// The Type group: aisles inside a department, so Clothing narrows to pants,
/// sweatshirts or dresses (owner, 2026-11-08: "we need better filtering for
/// clothes, we need pants, sweatshirts, etc.").
@MainActor
struct AisleFilterTests {
    private func product(_ id: String, _ category: String, subs: [String], brand: String = "b") -> Product {
        Product(id: id, brand: brand, title: id, category: category, productType: nil, subs: subs, price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: nil)
    }

    private let names = ["clothing:pants": "Pants & Trousers", "clothing:sweatshirts": "Sweatshirts & Hoodies",
                         "clothing:sets": "Loungewear & Sets", "shoes:sneakers": "Sneakers"]

    private var products: [Product] {
        [product("jogger", "clothing", subs: ["pants", "sets"]),
         product("chino", "clothing", subs: ["pants"], brand: "other"),
         product("hoodie", "clothing", subs: ["sweatshirts"]),
         product("trainer", "shoes", subs: ["sneakers"])]
    }

    @Test func typeListsEachAisleWithItsCount() {
        let facets = FilterFacets(products: products, filters: ProductFilters(), brandName: { _ in nil },
                                  aisleName: { names[$0] })
        #expect(facets.groups.contains(.aisle))
        let counts = Dictionary(uniqueKeysWithValues: (facets.options[.aisle] ?? []).map { ($0.name, $0.count) })
        #expect(counts == ["Pants & Trousers": 2, "Sweatshirts & Hoodies": 1, "Loungewear & Sets": 1, "Sneakers": 1])
        #expect(facets.options[.aisle]?.first?.name == "Pants & Trousers", "most products first")
    }

    @Test func pickingAnAisleNarrowsAndOtherGroupsFollow() {
        var f = ProductFilters(); f.aisles = ["clothing:pants"]
        #expect(f.apply(products).map(\.id) == ["jogger", "chino"])
        #expect(f.activeCount == 1)
        let facets = FilterFacets(products: products, filters: f, brandName: { $0 }, aisleName: { names[$0] })
        #expect(facets.remaining == 2)
        #expect(Set(facets.options[.brand]?.map(\.id) ?? []) == ["b", "other"], "brands count only pants")
        #expect(facets.options[.aisle]?.count == 4, "the Type group ignores its own choice")
        // Two aisles are either one.
        f.aisles.insert("clothing:sweatshirts")
        #expect(f.apply(products).map(\.id) == ["jogger", "chino", "hoodie"])
    }

    @Test func aCategoryChoiceLimitsTheTypes() {
        var f = ProductFilters(); f.categories = ["shoes"]
        let facets = FilterFacets(products: products, filters: f, brandName: { _ in nil }, aisleName: { names[$0] })
        #expect(facets.options[.aisle]?.map(\.id) == ["shoes:sneakers"])
        #expect(!facets.groups.contains(.aisle), "one choice narrows nothing, so no row")
    }

    @Test func anAisleTheCatalogDoesntNameIsLeftOut() {
        let facets = FilterFacets(products: [product("x", "clothing", subs: ["mystery"])] + products,
                                  filters: ProductFilters(), brandName: { _ in nil }, aisleName: { names[$0] })
        #expect(!(facets.options[.aisle] ?? []).contains { $0.id == "clothing:mystery" })
    }

    @Test func typeTilesCarryAPhotoPreferringInStock() {
        func photo(_ id: String, _ sub: String, image: String, available: Bool) -> Product {
            var p = product(id, "clothing", subs: [sub])
            p.images = [image]; p.available = available
            return p
        }
        let ps = [photo("old", "pants", image: "https://x/sold.jpg", available: false),
                  photo("new", "pants", image: "https://x/instock.jpg", available: true)]
        let facets = FilterFacets(products: ps + [product("h", "clothing", subs: ["sweatshirts"])],
                                  filters: ProductFilters(), brandName: { _ in nil }, aisleName: { names[$0] })
        #expect(facets.options[.aisle]?.first { $0.id == "clothing:pants" }?.image == "https://x/instock.jpg")
        #expect(facets.options[.aisle]?.first { $0.id == "clothing:sweatshirts" }?.image == nil)
    }

    /// Category tiles get a photo too (owner, 2026-11-09).
    @Test func categoryTilesCarryAPhotoPreferringInStock() {
        func photo(_ id: String, _ category: String, image: String?, available: Bool) -> Product {
            var p = product(id, category, subs: ["pants"])
            p.images = image.map { [$0] } ?? []; p.available = available
            return p
        }
        let ps = [photo("old", "clothing", image: "https://x/sold.jpg", available: false),
                  photo("new", "clothing", image: "https://x/instock.jpg", available: true),
                  photo("bare", "shoes", image: nil, available: true)]
        let facets = FilterFacets(products: ps, filters: ProductFilters(), brandName: { _ in nil }, aisleName: { names[$0] })
        #expect(facets.options[.category]?.first { $0.id == "clothing" }?.image == "https://x/instock.jpg")
        #expect(facets.options[.category]?.first { $0.id == "shoes" }?.image == nil)
    }
}
