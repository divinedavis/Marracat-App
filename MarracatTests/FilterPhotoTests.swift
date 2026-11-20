import Foundation
import Testing
@testable import Marracat

/// Every filter group shows its choices as photos, not just Category and Type
/// (owner, 2026-11-11: "lets have images for all categories for the filters
/// wherever we have a filter pill").
@MainActor
struct FilterPhotoTests {
    private func product(_ id: String, brand: String = "b", price: Double = 20, subs: [String] = ["pants"],
                         image: String?, available: Bool = true) -> Product {
        Product(id: id, brand: brand, title: id, category: "clothing", productType: nil, subs: subs, price: price,
                compareAt: nil, images: image.map { [$0] } ?? [], url: "https://b.example/\(id)", available: available,
                variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil, attrs: nil)
    }

    private func facets(_ ps: [Product]) -> FilterFacets {
        FilterFacets(products: ps, filters: ProductFilters(), brandName: { $0 }, aisleName: { $0 })
    }

    /// Badges lead the sheet's groups (owner, 2026-11-20: "make badges the
    /// first item"); the rest keep their order.
    @Test func badgesLeadTheGroups() {
        #expect(FilterGroup.allCases.first == .badges)
        #expect(FilterGroup.allCases.dropFirst().prefix(3) == [.category, .aisle, .gender])
        let f = facets([product("cheap", brand: "a", price: 10, image: "https://x/cheap.jpg"),
                        product("dear", brand: "c", price: 300, image: "https://x/dear.jpg")])
        #expect(f.groups == FilterGroup.allCases.filter(f.groups.contains), "the sheet lists them in that order")
    }

    @Test func brandPriceAndOfferTilesCarryAPhoto() {
        let f = facets([product("cheap", brand: "a", price: 10, image: "https://x/cheap.jpg"),
                        product("dear", brand: "c", price: 300, image: "https://x/dear.jpg")])
        #expect(f.options[.brand]?.first { $0.id == "a" }?.image == "https://x/cheap.jpg")
        #expect(f.options[.brand]?.first { $0.id == "c" }?.image == "https://x/dear.jpg")
        #expect(f.options[.price]?.first { $0.id == "Under $25" }?.image == "https://x/cheap.jpg")
        #expect(f.options[.price]?.first { $0.id == "$250 and up" }?.image == "https://x/dear.jpg")
        #expect(f.options[.offers]?.first { $0.id == "In stock" }?.image != nil)
    }

    @Test func tilesInAGroupAvoidRepeatingAPhoto() {
        // Pants lead (three products), so it takes the first photo; Sets
        // would show the same jogger, and gets the next one instead.
        let f = facets([product("p1", subs: ["pants", "sets"], image: "https://x/1.jpg"),
                        product("p2", subs: ["pants", "sets"], image: "https://x/2.jpg"),
                        product("p3", subs: ["pants"], image: "https://x/3.jpg")])
        #expect(f.options[.aisle]?.first { $0.id == "clothing:pants" }?.image == "https://x/1.jpg")
        #expect(f.options[.aisle]?.first { $0.id == "clothing:sets" }?.image == "https://x/2.jpg")
    }

    @Test func aRepeatBeatsAnEmptyTile() {
        let f = facets([product("only", subs: ["pants", "sets"], image: "https://x/only.jpg"),
                        product("bare", subs: ["pants"], image: nil)])
        #expect(f.options[.aisle]?.first { $0.id == "clothing:sets" }?.image == "https://x/only.jpg")
    }

    @Test func inStockStillWinsOverSoldOut() {
        let sold = (0..<PhotoPicks.depth).map { product("s\($0)", price: 10, image: "https://x/sold\($0).jpg", available: false) }
        let f = facets(sold + [product("in", price: 10, image: "https://x/in.jpg"),
                               product("dear", price: 300, image: "https://x/dear.jpg")])
        #expect(f.options[.price]?.first { $0.id == "Under $25" }?.image == "https://x/in.jpg")
    }
}

/// Badges have their own filter group, out of Offers (owner, 2026-11-11:
/// "instead of having the badges in offers, have badges section for
/// filtering with the images of the badge for the tiles").
@MainActor
struct BadgeFilterGroupTests {
    private func product(_ id: String, available: Bool = true, compareAt: Double? = nil, tags: [String] = []) -> Product {
        Product(id: id, brand: "b", title: id, category: "skincare", productType: nil, subs: [], price: 20,
                compareAt: compareAt, images: [], url: "https://b.example/\(id)", available: available,
                variants: [], tags: tags, description: nil, publishedAt: nil, bestRank: nil, attrs: nil)
    }

    @Test func offersKeepsStockAndSaleAndBadgesGetTheRest() {
        for o in ProductFilters.Offer.allCases {
            #expect(o.isBadge == (o != .inStock && o != .onSale))
            #expect((o.tile != nil) == o.isBadge, "every badge has a tile look: \(o)")
        }
        #expect(ProductFilters.Offer.clean.shortTitle == "Clean")
        #expect(ProductFilters.Offer.organic.tile?.word == "ORGANIC")
        #expect(ProductFilters.Offer.trueMetal.tile?.word == "TRUE METAL")
    }

    @Test func eachGroupCountsIgnoringItsOwnChoiceOnly() {
        // Two in stock (one on sale), one sold out on sale.
        let ps = [product("a"), product("b", compareAt: 40), product("c", available: false, compareAt: 40)]
        var f = ProductFilters()
        f.offers = [.inStock]
        let facets = FilterFacets(products: ps, filters: f, brandName: { $0 })
        let offers = Dictionary(uniqueKeysWithValues: (facets.options[.offers] ?? []).map { ($0.id, $0.count) })
        // Offers ignores its own In stock choice: On sale counts the sold-out one too.
        #expect(offers["In stock"] == 2)
        #expect(offers["On sale"] == 2)
        #expect(facets.options[.badges] == nil || facets.options[.badges]!.allSatisfy { ProductFilters.Offer(rawValue: $0.id)!.isBadge })
        #expect(!(facets.options[.offers] ?? []).contains { ProductFilters.Offer(rawValue: $0.id)!.isBadge })
    }

    @Test func aBadgeChoiceAndAStockChoiceBothNarrow() {
        let ps = [product("a"), product("b", available: false)]
        var f = ProductFilters()
        f.offers = [.inStock]
        #expect(f.matches(ps[0]) && !f.matches(ps[1]))
        #expect(f.matches(ps[1], ignoring: .offers), "Offers' own tally ignores In stock")
        #expect(!f.matches(ps[1], ignoring: .badges), "Badges' tally still honours In stock")
        #expect(f.activeCount == 1)
    }
}
