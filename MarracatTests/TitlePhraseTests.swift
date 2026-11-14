import Foundation
import Testing
@testable import Marracat

/// Two spellings of one kind meet at one key and only one is suggested
/// (2026-11-08: the full ship's testTypingSuggestsKindsMinedFromTitles failed
/// when one brand's 15 "Shea Butters" product types outvoted three brands'
/// "Shea Butter").
@MainActor
struct TitlePhraseTests {
    private func product(_ id: String, brand: String, title: String, type: String? = nil) -> Product {
        Product(id: id, brand: brand, title: title, category: "skincare", productType: type, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://\(brand).example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: nil)
    }

    @Test func theCommonerFormOfAPhraseIsSuggested() {
        var products = (0..<4).map { product("t\($0)", brand: "type\($0)", title: "Whipped Cream \($0)", type: "Body Butter") }
        products += (0..<6).map { product("s\($0)", brand: "b\($0 % 3)", title: "Raw Shea Butter Jar \($0)") }
        products += [product("p0", brand: "b0", title: "Shea Butters Sampler"), product("p1", brand: "b1", title: "Shea Butters Duo Box")]
        let catalog = Catalog(generatedAt: "2026-11-08T00:00:00Z", categories: [], subcategories: [], brands: [], products: products)
        let terms = CatalogStore.buildSuggestionTerms(catalog, byCategory: [:])
        let shea = terms.filter { $0.key == CatalogStore.singular("shea butter") }
        #expect(shea.map(\.text) == ["shea butter"], "\(shea.map(\.text))")
    }

    @Test func aKindIsSpelledAsTheMostBrandsSpellIt() {
        var products = (0..<15).map { product("j\($0)", brand: "jones", title: "Whipped \($0)", type: "Shea Butters") }
        products += (0..<3).map { product("s\($0)", brand: "b\($0)", title: "Raw \($0)", type: "Shea Butter") }
        let catalog = Catalog(generatedAt: "2026-11-08T00:00:00Z", categories: [], subcategories: [], brands: [], products: products)
        let shea = CatalogStore.buildSuggestionTerms(catalog, byCategory: [:]).filter { $0.key == CatalogStore.singular("shea butter") }
        #expect(shea.map(\.text) == ["shea butter"], "\(shea.map(\.text))")
    }
}
