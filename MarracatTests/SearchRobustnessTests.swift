import XCTest
@testable import Marracat

/// Search robustness and colours in search (owner, 2026-10-15), after a
/// shopper's "musthavejoy" found nothing, "pink shirt women" found far less
/// than "pink shirt", and five minutes of pink searches ended on earrings.
/// The website does the same (web/tests/search-words.test.js).
@MainActor
final class SearchRobustnessTests: XCTestCase {
    func testWordsFoldAndPluralsMeetTheirSingular() {
        XCTAssertEqual(SearchWords.fold("Adèle Dejak"), "adele dejak")
        XCTAssertEqual(SearchWords.tokens("Women’s Dresses"), ["womens", "dresses"])
        XCTAssertEqual(SearchWords.singular("dresses"), "dress")
        XCTAssertEqual(SearchWords.singular("watches"), "watch")
        XCTAssertEqual(SearchWords.singular("shirts"), "shirt")
        XCTAssertEqual(SearchWords.singular("dress"), "dress")
    }

    func testWomenAndMenArePreferencesNotRequiredWords() {
        let split = SearchWords.splitAudience(["pink", "shirt", "womens"])
        XCTAssertEqual(split.words, ["pink", "shirt"])
        XCTAssertEqual(split.audience, .women)
        XCTAssertNil(SearchWords.splitAudience(["womens"]).audience, "a lone audience word stays a word")
        XCTAssertEqual(SearchWords.audienceFit("pink shirt", .women), 0)
        XCTAssertEqual(SearchWords.audienceFit("womens pink shirt", .women), 1)
        XCTAssertEqual(SearchWords.audienceFit("unisex pink shirt", .women), 1)
        XCTAssertEqual(SearchWords.audienceFit("mens pink shirt", .women), -1)
    }

    func testRunTogetherAndMisspelledWordsAreRespelled() {
        let vocab = ["must": 40, "have": 90, "joy": 30, "hoodie": 500, "ban": 3, "bangs": 4]
        let uses = { (w: String) in vocab[w] ?? 0 }
        XCTAssertEqual(SearchWords.splitRunTogether("musthavejoy", uses: uses), "must have joy")
        XCTAssertNil(SearchWords.splitRunTogether("bangsi", uses: uses), "no two-letter pieces")
        XCTAssertEqual(SearchWords.closestWord("hodie", vocab: vocab.map { ($0.key, $0.value) }), "hoodie")
        XCTAssertEqual(SearchWords.distance("teh", "the"), 1, "a swap is one edit")
        XCTAssertNil(SearchWords.respell("must have joy", uses: uses, vocab: { [] }))
    }

    func testABrandTypedAsOneWordFindsTheBrand() throws {
        XCTAssertEqual(SearchWords.squash("Fear of God"), "fearofgod")
        XCTAssertEqual(SearchWords.squash("Adèle-Dejak"), "adeledejak")
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        for typed in ["fearofgod", "FearOfGod", "fearof"] {
            XCTAssertTrue(catalog.suggestions(typed).contains { $0.kind == .brand("fear-of-god") }, typed)
        }
        let relaxed = try XCTUnwrap(catalog.relaxedSearch("fearofgod"))
        XCTAssertEqual(relaxed.query, "Fear of God")
        XCTAssertTrue(relaxed.results.contains { $0.brand == "fear-of-god" })
    }

    private func product(_ title: String, category: String = "clothing", variants: [String] = []) -> Product {
        Product(id: title, brand: "b", title: title, category: category, productType: nil, subs: [], price: 10,
                compareAt: nil, images: [], url: "https://b.example/p", available: true,
                variants: variants.enumerated().map { Variant(id: Int64($0.offset + 1), title: $0.element, price: 10, compareAt: nil, available: true) },
                tags: [], description: nil, publishedAt: nil, bestRank: nil, currency: "USD")
    }

    func testColoursComeFromTitlesToo() {
        XCTAssertEqual(ProductFacets.colorFamilies(product("Exotic Bloom | Metallic Pink Earrings", category: "jewelry")), ["Pinks"])
        XCTAssertEqual(ProductFacets.colorFamilies(product("Rose Gold Hoops", category: "jewelry")), ["Golds"])
        XCTAssertEqual(ProductFacets.colorFamilies(product("Classic Tee", variants: ["Blush / M", "Navy / L"])), ["Pinks", "Blues"])
        XCTAssertEqual(ProductFacets.colorFamilies(product("Black TV Moms Sweatshirt")), [], "who it's for, not its colour")
        XCTAssertEqual(ProductFacets.colorFamilies(product("Shea Butter", category: "skincare", variants: ["Lavender"])), [])
        XCTAssertEqual(ProductFacets.family(ofWord: "blush"), "Pinks")
        XCTAssertEqual(ProductFacets.family(ofWord: "blues"), "Blues")
    }

    func testTheShoppersSearchesOnTheRealCatalog() throws {
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        XCTAssertTrue(catalog.search("musthavejoy").isEmpty || catalog.search("musthavejoy").allSatisfy { $0.brand == "must-have-joy" })
        let relaxed = try XCTUnwrap(catalog.relaxedSearch("musthavejoy"))
        XCTAssertEqual(relaxed.query.lowercased(), "must have joy", "the brand, by its own name")
        XCTAssertGreaterThan(relaxed.results.filter { $0.brand == "must-have-joy" }.count, relaxed.results.count / 2)
        // "women" no longer has to be in the title; men's shirts are left out.
        let women = catalog.search("pink shirt women")
        XCTAssertGreaterThan(women.count, 30)
        let marked = { (p: Product) in SearchWords.fold(([p.title, p.productType ?? ""] + p.tags).joined(separator: " ")) }
        XCTAssertFalse(women.contains { SearchWords.audienceFit(marked($0), .women) < 0 },
                       "\(women.filter { SearchWords.audienceFit(marked($0), .women) < 0 }.prefix(3).map(\.title))")
        // "dresses" finds titles that say "Dress", not only ones that say "Dresses".
        let dresses = catalog.search("dresses")
        XCTAssertGreaterThan(dresses.filter { SearchWords.tokens($0.title).contains("dress") }.count, 100,
                             "\(dresses.prefix(5).map(\.title))")
        // "pink top" also finds tops that only come in pink.
        let pinkTops = catalog.search("pink top")
        XCTAssertTrue(pinkTops.contains { !$0.title.lowercased().contains("pink") && ProductFacets.colorFamilies($0).contains("Pinks") })
    }

    // Owner, 2026-11-01: October's searches that found nothing were "black
    // owned bag charms" (then only black-coloured charms) and "xennial co"
    // (then 6,627 products for "co"). The website does the same
    // (web/tests/search-words.test.js).
    /// Owner, 2026-11-08: the "independent" card shows whatever words come
    /// before or after it, and for its near spellings (web/tests/search-words.test.js).
    func testIndependentCardShowsForAnyWordsAroundIt() {
        for q in ["independent", "independent brands", "independent bracelets", "bracelets independent",
                  "best independent hair care for kids", "independent", "independent skincare", "independent candles",
                  "independent tees", "independent gifts", "Independent Jewelry"] {
            XCTAssertTrue(SearchWords.saysOwnership(SearchWords.tokens(q)), q)
        }
        for q in ["black bracelets", "black dress", "owned", "black", "blackberry owned"] {
            XCTAssertFalse(SearchWords.saysOwnership(SearchWords.tokens(q)), q)
        }
        XCTAssertEqual(SearchWords.dropOwnership(["blk", "owned", "tees"]), ["tees"])
        XCTAssertEqual(SearchWords.dropOwnership(["candles", "black", "ownd"]), ["candles"])
    }

    func testIndependentIsWhoEveryBrandIsNotARequiredWord() {
        XCTAssertEqual(SearchWords.dropOwnership(["black", "owned", "bag", "charms"]), ["bag", "charms"])
        XCTAssertEqual(SearchWords.dropOwnership(["independent", "hair", "oil"]), ["hair", "oil"])
        XCTAssertEqual(SearchWords.dropOwnership(["black", "own", "business", "tote"]), ["business", "tote"])
        XCTAssertEqual(SearchWords.dropOwnership(["black", "owned"]), ["black", "owned"], "alone it stays")
        XCTAssertEqual(SearchWords.dropOwnership(["black", "bag", "charm"]), ["black", "bag", "charm"], "a colour is still a colour")
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        let charms = catalog.search("bag charms")
        XCTAssertFalse(charms.isEmpty)
        XCTAssertEqual(Set(catalog.search("independent bag charms").map(\.id)), Set(charms.map(\.id)))
        XCTAssertNil(catalog.relaxedSearch("independent xyzzy"), "not relaxed to the phrase alone")
    }

    func testABrandWeDontCarryIsNotRelaxedToFillerWords() {
        XCTAssertTrue(SearchWords.onlyFiller(["co"]))
        XCTAssertFalse(SearchWords.onlyFiller(["bag", "co"]))
        XCTAssertNil(SearchWords.splitRunTogether("xennial", uses: { ["xen": 2, "nial": 1][$0] ?? 0 }), "'nial' is on one product")
        XCTAssertEqual(SearchWords.splitRunTogether("xennial", uses: { ["xen": 2, "nial": 2][$0] ?? 0 }), "xen nial")
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        if catalog.search("xennial co").isEmpty {
            XCTAssertNil(catalog.relaxedSearch("xennial co"), "\(catalog.relaxedSearch("xennial co")?.query ?? "")")
        }
    }
}
