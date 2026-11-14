import Foundation
import Testing
@testable import Marracat

/// Price sorts compare in dollars (a creator, 2026-10-16: "handbags" low to
/// high opened on €350 bags because every euro item sorted before any dollar one).
struct PriceSortTests {
    private func product(_ id: String, _ price: Double, _ currency: String) -> Product {
        Product(id: id, brand: "b", title: id, category: "bags", productType: nil, subs: [],
                price: price, compareAt: nil, images: [], url: "https://b.example/\(id)",
                available: true, variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil, currency: currency)
    }

    @Test func lowToHighMixesCurrenciesByDollarPrice() {
        // At the fallback rates: €350 ≈ $392, £20 ≈ $26.
        let ps = [product("eur", 350, "EUR"), product("usd", 45, "USD"), product("gbp", 20, "GBP")]
        #expect(ProductSort.priceLow.apply(ps).map(\.id) == ["gbp", "usd", "eur"])
        #expect(ProductSort.priceHigh.apply(ps).map(\.id) == ["eur", "usd", "gbp"])
    }
}
