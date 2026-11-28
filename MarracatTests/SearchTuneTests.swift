import XCTest
@testable import Marracat

/// Owner, 2026-11-03, after a returning shopper's searches: lead with a brand
/// when its name is searched, synonyms, a charm or two for someone looking at
/// charms, guesses instead of "no matches", and the "independent" notice. The
/// website does the same (web/tests/search-tune.test.js); scripts/
/// search_parity.sh checks both over the whole catalog.
@MainActor
final class SearchTuneTests: XCTestCase {
    func testABrandNameLeadsButAnEverydayWordDoesNot() {
        XCTAssertTrue(SearchWords.namesBrand(["fraiche"], brandName: "Fraîche Studios").matches)
        XCTAssertTrue(SearchWords.namesBrand(["xennial", "co"], brandName: "The Xennial Co").full)
        XCTAssertFalse(SearchWords.namesBrand(["studios"], brandName: "Fraîche Studios").matches, "only the name's first words")
        XCTAssertFalse(SearchWords.leadsWithBrand(SearchWords.namesBrand(["okra"], brandName: "O'kra"), own: 3, others: 58))
        XCTAssertTrue(SearchWords.leadsWithBrand(SearchWords.namesBrand(["fraiche"], brandName: "Fraîche Studios"), own: 20, others: 6))
        XCTAssertTrue(SearchWords.leadsWithBrand(SearchWords.namesBrand(["brandon", "blackwood"], brandName: "Brandon Blackwood"), own: 5, others: 50))
    }

    func testSynonymsBesideOtherWordsOnly() {
        XCTAssertTrue(SearchWords.alternates("keychain", beside: false).contains("key ring"))
        XCTAssertFalse(SearchWords.alternates("keychain", beside: false).contains("charm"))
        XCTAssertTrue(SearchWords.alternates("keychain", beside: true).contains("charm"))
        XCTAssertTrue(SearchWords.alternates("fruit", beside: true).contains("cherry"))
        XCTAssertTrue(SearchWords.alternates("fruit", beside: false).isEmpty, "fruit alone stays fruit")
    }

    func testTheOwnershipNoticeReadsEverySpelling() {
        for q in ["independent", "independent bag charms", "independent", "independent candles"] {
            XCTAssertTrue(SearchWords.saysOwnership(SearchWords.tokens(q)), q)
        }
        for q in ["black bag", "owned by me", "black"] { XCTAssertFalse(SearchWords.saysOwnership(SearchWords.tokens(q)), q) }
    }

    func testGuessesInsteadOfNoMatches() {
        let counts = ["The Xennial Co": 20, "xennial": 20]
        let guesses = SearchWords.alternatives("xenial", brandNames: ["The Xennial Co", "Telfar"], vocab: { [("xennial", 3)] },
                                               count: { counts[$0] ?? 0 })
        XCTAssertEqual(guesses, ["The Xennial Co"])
        XCTAssertTrue(SearchWords.prefersGuess("xennail", guess: "The Xennial Co", over: "nail"))
        XCTAssertFalse(SearchWords.prefersGuess("hodie", guess: "Hodi", over: "hoodie"), "a tie keeps the respelling")
    }

    func testInterestsSkipTheSearchItselfAndOwnershipWords() {
        let got = SearchWords.interests(query: "fruit", recentSearches: ["fruit salad", "Independent", "the co", "charm"],
                                        viewedAisles: ["Keychains & Charms", "Tote Bags", "Keychains & Charms"])
        XCTAssertEqual(got.map(\.phrase), ["charm", "Keychains & Charms", "Tote Bags"])
        XCTAssertEqual(got.map(\.searched), [true, false, false])
    }

    func testOnlyAFocusedSearchDropsADepartmentThatMerelyMentionsIt() {
        XCTAssertEqual(SearchWords.offDepartments(["bags": 17, "crafts": 2], total: 19, words: 3), ["crafts"])
        XCTAssertEqual(SearchWords.offDepartments(["bags": 17, "crafts": 2], total: 19, words: 1), [], "one word: under 1 in 20")
        XCTAssertEqual(SearchWords.offDepartments(["clothing": 30, "home": 30, "garden": 30, "crafts": 2], total: 92, words: 1), [],
                       "a broad word moves nothing")
        XCTAssertEqual(SearchWords.offDepartments(["bags": 900, "jewelry": 3], total: 903, words: 2), [], "jewelry is a real kind")
        // Exactly 1 in 8 is off topic too: 2 felting kits among 16 "bag charm fruit" matches (2026-11-28).
        XCTAssertEqual(SearchWords.offDepartments(["bags": 10, "accessories": 4, "crafts": 2], total: 16, words: 3), ["crafts"])
        XCTAssertEqual(SearchWords.offDepartments(["bags": 10, "accessories": 3, "crafts": 3], total: 16, words: 3), [], "3 in 16 is a real share")
    }

    /// The real catalog: what the returning shopper of 2026-11-03 searched.
    func testTheShoppersSearchesOnTheRealCatalog() throws {
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        XCTAssertEqual(catalog.search("fraiche").first?.brand, "fraiche-studios")
        XCTAssertTrue(catalog.search("dunk keychain").contains { $0.title.contains("Dunk Charm") })
        let fruitCharms = catalog.search("bag charm fruit")
        XCTAssertTrue(fruitCharms.contains { $0.title.lowercased().contains("cherry") }, "\(fruitCharms.prefix(5).map(\.title))")
        XCTAssertNotEqual(fruitCharms.first?.category, "crafts", "a felting kit is no bag charm")
        XCTAssertNotEqual(catalog.search("bag charms").first?.category, "crafts")
        XCTAssertFalse(catalog.inStockFirst(catalog.search("purses")).prefix(10).contains { $0.category == "grocery" }, "no tea among purses")
        let picks = try XCTUnwrap(catalog.personalPicks("fruit", recentSearches: ["fruit", "bag charm"], recentlyViewed: []))
        XCTAssertEqual(picks.phrase, "bag charm")
        XCTAssertTrue(picks.products.allSatisfy { $0.category != "crafts" }, "\(picks.products.map(\.title))")
        XCTAssertNil(catalog.personalPicks("fruit", recentSearches: ["fruit"], recentlyViewed: []), "nothing looked at, nothing picked")
        XCTAssertEqual(catalog.alternatives("brandon blakwod", excluding: catalog.relaxedSearch("brandon blakwod")?.query).first, "Brandon Blackwood")
    }
}
