import Foundation
import Testing
@testable import Marracat

/// The Country group: the country each brand is based in (owner, 2026-11-26:
/// "Let's put a filter for the country the company is founded").
@MainActor
struct CountryFilterTests {
    private func brand(_ id: String, _ country: String?) -> Brand {
        var b = Brand(id: id, name: id, domain: "\(id).example", category: "clothing", tagline: nil, shopify: true, platform: nil, image: nil)
        b.country = country
        return b
    }

    private func product(_ id: String, brand: String, category: String = "clothing") -> Product {
        Product(id: id, brand: brand, title: id, category: category, productType: nil, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: nil)
    }

    /// Two Lagos brands, one London brand, one Atlanta brand, and one whose
    /// country nobody recorded.
    private var products: [Product] {
        BrandCountry.update(from: [brand("lagos-one", "NG"), brand("lagos-two", "ng"), brand("london-co", "GB"),
                                   brand("atlanta-co", "US"), brand("unknown-co", nil)])
        return [product("agbada", brand: "lagos-one"), product("kaftan", brand: "lagos-one"), product("wrapper", brand: "lagos-two"),
                product("trench", brand: "london-co"), product("tee", brand: "atlanta-co", category: "shoes"),
                product("mystery", brand: "unknown-co")]
    }

    private func facets(_ f: ProductFilters = ProductFilters()) -> FilterFacets {
        FilterFacets(products: products, filters: f, brandName: { $0 })
    }

    @Test func countriesAreListedByNameWithTheirCounts() {
        let facets = facets()
        #expect(facets.groups.contains(.country))
        let english = Locale(identifier: "en_US")
        let counts = Dictionary(uniqueKeysWithValues: (facets.options[.country] ?? []).map { (BrandCountry.name($0.id, locale: english), $0.count) })
        #expect(counts == ["Nigeria": 3, "United Kingdom": 1, "United States": 1])
        #expect(facets.options[.country]?.first?.id == "NG", "most products first")
    }

    @Test func pickingACountryKeepsOnlyItsBrands() {
        var f = ProductFilters(); f.countries = ["NG"]
        #expect(f.apply(products).map(\.id) == ["agbada", "kaftan", "wrapper"])
        #expect(f.activeCount == 1)
        f.countries.insert("GB")
        #expect(f.apply(products).map(\.id) == ["agbada", "kaftan", "wrapper", "trench"], "two countries are either one")
    }

    @Test func aBrandWithNoCountryOnRecordIsInNoCountry() {
        var f = ProductFilters(); f.countries = ["NG", "GB", "US"]
        #expect(!f.apply(products).map(\.id).contains("mystery"))
        #expect(!(facets().options[.country] ?? []).contains { $0.count == 0 })
    }

    @Test func theOtherGroupsFollowTheCountryAndItIgnoresItsOwnChoice() {
        var f = ProductFilters(); f.countries = ["NG"]
        let facets = facets(f)
        #expect(facets.remaining == 3)
        #expect(Set(facets.options[.brand]?.map(\.id) ?? []) == ["lagos-one", "lagos-two"], "only Nigerian brands are offered")
        #expect(facets.options[.country]?.count == 3, "the Country group still offers the others")
        #expect(facets.options[.category]?.map(\.id) == ["clothing"])
    }

    @Test func aBrandChoiceLimitsTheCountries() {
        var f = ProductFilters(); f.brands = ["london-co"]
        let facets = facets(f)
        #expect(facets.options[.country]?.map(\.id) == ["GB"])
        #expect(!facets.groups.contains(.country), "one choice narrows nothing, so no row")
    }

    @Test func aCountrysTileIsItsFlagNotAProductPhoto() {
        // Owner, 2026-11-26: "For the country image on mobile use the country flag".
        #expect(BrandCountry.flag("NG") == "🇳🇬")
        #expect(BrandCountry.flag("gb") == "🇬🇧")
        #expect(BrandCountry.flag("US") == "🇺🇸")
        #expect(BrandCountry.flag("Nigeria") == nil)
        #expect(BrandCountry.flag("") == nil)
        var withPhotos = products
        for i in withPhotos.indices { withPhotos[i].images = ["https://x.example/\(i).jpg"] }
        let facets = FilterFacets(products: withPhotos, filters: ProductFilters(), brandName: { $0 })
        #expect((facets.options[.country] ?? []).allSatisfy { $0.image == nil }, "no product photo is picked for a country")
        #expect((facets.options[.brand] ?? []).contains { $0.image != nil }, "the other groups keep their photos")
    }

    @Test func aCodeThatIsNotACountryIsIgnored() {
        #expect(BrandCountry.valid("ng") == "NG")
        #expect(BrandCountry.valid("Nigeria") == nil)
        #expect(BrandCountry.valid("") == nil)
        #expect(BrandCountry.valid(nil) == nil)
        BrandCountry.update(from: [brand("odd", "africa")])
        #expect(BrandCountry.of("odd") == nil)
    }

    @Test func aBrandsCountryComesOffTheCatalog() throws {
        let json = #"{"id":"koba","name":"KOBA","domain":"koba.example","category":"skincare","tagline":"","shopify":true,"country":"GB"}"#
        #expect(try JSONDecoder().decode(Brand.self, from: Data(json.utf8)).country == "GB")
    }
}
