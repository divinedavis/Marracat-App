import Foundation
import Testing
@testable import Marracat

/// Skincare and hair filters from what the brand says (catalog/attributes.py;
/// owner, 2026-11-04: "only have filters that reflect skincare in the skincare
/// category and the ones for hair in the hair category"; 2026-11-22: the
/// who-is-it-for groups also show on a page of several departments).
@MainActor
struct AttributeFilterTests {
    private func product(_ id: String, _ category: String, attrs: [String: [String]]? = nil) -> Product {
        Product(id: id, brand: "b", title: id, category: category, productType: nil, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: attrs)
    }

    @Test func theCatalogsAttrsDecodeAndTheFabricStringIsSkipped() throws {
        let json = #"{"id":"s","brand":"b","title":"Serum","category":"skincare","url":"u","price":1,"available":true,"attrs":{"skintype":["oily"],"ingredient":["niacinamide"],"fabric":"cotton","scent":["rose"]}}"#
        let p = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        #expect(p.attrs == ["skintype": ["oily"], "ingredient": ["niacinamide"]])
    }

    @Test func attrsSurviveTheBinaryCatalog() throws {
        let tagged = product("s", "skincare", attrs: ["skintype": ["oily", "combination"], "spf": ["high"]])
        let catalog = Catalog(generatedAt: "2026-11-04T00:00:00Z", categories: [], subcategories: [], brands: [],
                              products: [tagged, product("plain", "skincare")])
        let back = try #require(CatalogBinary.decode(try CatalogBinary.encode(catalog)))
        #expect(back.products == catalog.products)
        #expect(back.products.last?.attrs == nil)
    }

    @Test func skincareGroupsShowOnSkincareOnly() {
        let skin = [product("a", "skincare", attrs: ["skintype": ["dry"], "free": ["oil", "vegan"]]),
                    product("b", "skincare", attrs: ["ingredient": ["retinoid"]])]
        let facets = FilterFacets(products: skin, filters: ProductFilters(), brandName: { _ in nil })
        #expect(facets.groups.contains(.skinType))
        #expect(facets.groups.contains(.ingredient))
        #expect(facets.options[.preferences]?.map(\.id).sorted() == ["oil", "vegan"])
        #expect(!facets.groups.contains(.hairType))

        // Picking a department shows that department's groups alone.
        let mixed = skin + [product("h", "hair", attrs: ["hair": ["4c"], "free": ["sulfate"]])]
        var hairOnly = ProductFilters(); hairOnly.categories = ["hair"]
        let hair = FilterFacets(products: mixed, filters: hairOnly, brandName: { _ in nil })
        #expect(hair.groups.contains(.hairType))
        #expect(!hair.groups.contains(.skinType))
        #expect(hair.options[.preferences]?.map(\.id) == ["sulfate"], "oil-free is a skin preference only")
    }

    /// A brand's store or a wide search spans departments (owner, 2026-11-22,
    /// on a brand selling hair, skin and makeup, where these were hidden): the
    /// who-is-it-for groups show for the departments on the page, each counted
    /// from its own department's products; the rest wait for one department.
    @Test func aPageOfSeveralDepartmentsShowsWhoAProductIsFor() {
        let ps = [product("s1", "skincare", attrs: ["skin": ["eczema", "sensitive"], "skintype": ["sensitive"], "free": ["fragrance", "oil"],
                                                    "ingredient": ["ceramides"], "form": ["cream"], "spf": ["high"]]),
                  product("s2", "skincare", attrs: ["skin": ["acne"]]),
                  product("h1", "hair", attrs: ["hair": ["4c", "fine"], "hairneed": ["sensitive_scalp", "dandruff"], "free": ["sulfate"]]),
                  product("m1", "makeup"),
                  product("t1", "clothing", attrs: ["skin": ["eczema"]])]   // a stray tag outside its department is not counted
        let wide = FilterFacets(products: ps, filters: ProductFilters(), brandName: { _ in nil })
        for g in [FilterGroup.hairType, .hairConcern, .skinConcern, .skinType, .preferences] {
            #expect(wide.groups.contains(g), "\(g) should show on a mixed page")
        }
        for g in [FilterGroup.ingredient, .formulation, .sunProtection, .pack] {
            #expect(!wide.groups.contains(g), "\(g) waits for a single department")
        }
        let count = { (g: FilterGroup, id: String) in wide.options[g]?.first { $0.id == id }?.count }
        #expect(count(.skinConcern, "eczema") == 1)
        #expect(count(.hairConcern, "sensitive_scalp") == 1)
        #expect(count(.hairType, "fine") == 1)
        #expect(Set(wide.options[.preferences]?.map(\.id) ?? []) == ["fragrance", "oil", "sulfate"])

        var f = ProductFilters(); f.attrs = ["skin": ["eczema"]]
        #expect(f.apply(ps).map(\.id).contains("s1"))
        var scalp = ProductFilters(); scalp.attrs = ["hairneed": ["sensitive_scalp"]]
        #expect(scalp.apply(ps).map(\.id) == ["h1"])

        // A page with no hair or skin products shows none of them.
        let clothes = FilterFacets(products: [product("a", "clothing"), product("b", "bags")], filters: ProductFilters(), brandName: { _ in nil })
        #expect(!clothes.groups.contains(where: { $0.attrField != nil }))
    }

    /// Baby products carry the skin concerns a parent shops by, and free-of.
    @Test func babyShowsSkinConcernsAndPreferences() {
        let ps = [product("b1", "baby", attrs: ["skin": ["eczema", "sensitive"], "free": ["fragrance"]]), product("b2", "baby")]
        let facets = FilterFacets(products: ps, filters: ProductFilters(), brandName: { _ in nil })
        #expect(facets.groups.contains(.skinConcern))
        #expect(facets.options[.skinConcern]?.map(\.id).sorted() == ["eczema", "sensitive"])
        #expect(facets.options[.preferences]?.map(\.id) == ["fragrance"])
        #expect(AttrFilter.label("hairneed", "sensitive_scalp") == "Sensitive scalp")
        #expect(AttrFilter.label("hair", "low_porosity") == "Low porosity")
        #expect(AttrFilter.label("skin", "razor_bumps") == "Razor bumps & ingrowns")
    }

    @Test func aChoiceNarrowsAndKeepsItsOwnGroupsCounts() {
        let ps = [product("a", "skincare", attrs: ["skintype": ["dry"]]),
                  product("b", "skincare", attrs: ["skintype": ["oily"]]),
                  product("c", "skincare")]
        var f = ProductFilters(); f.attrs = ["skintype": ["dry"]]
        #expect(f.apply(ps).map(\.id) == ["a"])
        #expect(f.activeCount == 1)
        let facets = FilterFacets(products: ps, filters: f, brandName: { _ in nil })
        #expect(facets.remaining == 1)
        #expect(Set(facets.options[.skinType]?.map(\.id) ?? []) == ["dry", "oily"], "its own group ignores its own choice")
        f.clear()
        #expect(f.attrs.isEmpty)
    }

    @Test func everyValueHasALabelAndEveryGroupAField() {
        for g in FilterGroup.allCases where g.attrField != nil {
            #expect(AttrFilter.specs[g.attrField!] != nil, "\(g)")
        }
        #expect(Set(AttrFilter.fields) == Set(FilterGroup.allCases.compactMap(\.attrField)))
        #expect(AttrFilter.label("ingredient", "vitamin_c") == "Vitamin C")
    }

    /// Women / Men (owner, 2026-11-08): decoded from attrs, offered across
    /// departments, unisex under both.
    @Test func genderDecodesAndFiltersAcrossDepartments() throws {
        let json = #"{"id":"g","brand":"b","title":"Hoodie","category":"clothing","url":"u","price":1,"available":true,"attrs":{"gender":["men","women"]}}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        #expect(decoded.attrs?["gender"] == ["men", "women"])

        let ps = [product("w", "clothing", attrs: ["gender": ["women"]]),
                  product("m", "clothing", attrs: ["gender": ["men"]]),
                  product("u", "clothing", attrs: ["gender": ["men", "women"]]),
                  product("bag", "bags")]
        let wide = FilterFacets(products: ps, filters: ProductFilters(), brandName: { _ in nil })
        #expect(wide.groups.contains(.gender), "a mixed search still offers Gender")
        #expect(Dictionary(uniqueKeysWithValues: (wide.options[.gender] ?? []).map { ($0.id, $0.count) }) == ["women": 2, "men": 2])
        var f = ProductFilters(); f.attrs = ["gender": ["women"]]
        #expect(f.apply(ps).map(\.id) == ["w", "u"], "unisex shows under Women")
        #expect(AttrFilter.label("gender", "men") == "Men")
    }
}

