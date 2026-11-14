import XCTest
import AppIntents
import CoreSpotlight
@testable import Marracat

/// Siri, Shortcuts and Spotlight (owner, 2026-10-14): where each one opens,
/// what the entity queries find, and what goes into Spotlight — only what the
/// shopper made on this phone plus the premier brands, never the catalog.
@MainActor
final class SiriSpotlightTests: XCTestCase {
    private func product(_ id: String, brand: String, title: String, price: Double = 38) -> Product {
        Product(id: id, brand: brand, title: title, category: "skincare", productType: "Serum", subs: [],
                price: price, compareAt: nil, images: ["https://cdn.example/\(id).jpg"], url: "https://b.example/\(id)",
                available: true, variants: [Variant(id: 1, title: "Default Title", price: price, compareAt: nil, available: true)],
                tags: [], description: nil, publishedAt: "2026-10-01", bestRank: nil, currency: "USD")
    }
    private func brand(_ id: String, _ name: String) -> Brand {
        Brand(id: id, name: name, domain: "\(id).example", category: "skincare", tagline: "\(name) tagline",
              shopify: true, platform: "shopify", image: nil)
    }

    private var fixture: Catalog {
        Catalog(generatedAt: "2026-10-14T00:00:00Z",
                categories: [Category(id: "skincare", name: "Skincare", symbol: "face.smiling"),
                             Category(id: "hair", name: "Hair Care", symbol: "scissors")],
                subcategories: [],
                brands: [brand("telfar", "Telfar"), brand("fenty-beauty", "Fenty Beauty"), brand("koba-skincare", "KOBA Skincare"),
                         brand("tefi", "Téfi Studio"), brand("other", "Other Brand")],
                products: [product("p1", brand: "telfar", title: "Medium Shopping Bag"),
                           product("p2", brand: "fenty-beauty", title: "Gloss Bomb Lip Luminizer"),
                           product("p3", brand: "koba-skincare", title: "Shea Butter Body Cream"),
                           product("p4", brand: "other", title: "Shopping Tote")])
    }

    // MARK: Where things open

    func testEachDestinationOpensItsScreenOnTheRightTab() {
        XCTAssertEqual(AppDestination.product("p1").tab, .home)
        XCTAssertEqual(AppDestination.product("p1").path, [.product("p1")])
        XCTAssertEqual(AppDestination.brand("telfar").path, [.brand("telfar")])
        XCTAssertEqual(AppDestination.brand("telfar").tab, .home)
        XCTAssertEqual(AppDestination.category("hair").tab, .browse)
        XCTAssertEqual(AppDestination.category("hair").path, [.category("hair")])
        XCTAssertEqual(AppDestination.search("shea butter").path, [.search("shea butter")])
        XCTAssertEqual(AppDestination.deals.path, [.deals])
        XCTAssertEqual(AppDestination.orders.tab, .you)
        XCTAssertEqual(AppDestination.orders.path, [.checkouts])
    }

    func testSpotlightIdentifiersRoundTrip() {
        for d in [AppDestination.product("px-studio-150"), .brand("telfar"), .category("hair")] {
            XCTAssertEqual(AppDestination(spotlightID: d.spotlightID!), d)
        }
        XCTAssertNil(AppDestination.deals.spotlightID)
        XCTAssertNil(AppDestination(spotlightID: "product:"))
        XCTAssertNil(AppDestination(spotlightID: "order:123"))
        XCTAssertNil(AppDestination(spotlightID: "telfar"))
    }

    func testLinksRoundTripAndLeaveTheLiveActivityLinkAlone() {
        for d in [AppDestination.product("p1"), .brand("telfar"), .category("hair"), .search("shea & butter"), .deals, .orders] {
            XCTAssertEqual(AppDestination(url: d.url), d, d.url.absoluteString)
        }
        XCTAssertEqual(AppDestination.product("p1").url.absoluteString, "marracat://product/p1")
        XCTAssertNil(AppDestination(url: URL(string: "marracat://order?brand=telfar&order=1001")!), "DeliveryLink's")
        XCTAssertNil(AppDestination(url: URL(string: "https://marracat.com/p/p1")!), "universal links are openProductLink's")
        XCTAssertNil(AppDestination(url: URL(string: "marracat://search?q=%20%20")!))
        XCTAssertNil(AppDestination(url: URL(string: "marracat://product")!))
        XCTAssertNil(AppDestination(url: URL(string: "marracat://settings")!))
        let long = String(repeating: "a", count: 500)
        XCTAssertEqual(AppDestination(url: URL(string: "marracat://search?q=\(long)")!), .search(String(repeating: "a", count: AppDestination.maxQuery)))
    }

    func testALinkToSomethingTheCatalogDoesntHaveOpensNothing() {
        let store = CatalogStore(catalog: fixture)
        XCTAssertTrue(AppDestination.product("p1").exists(in: store))
        XCTAssertFalse(AppDestination.product("gone").exists(in: store))
        XCTAssertFalse(AppDestination.brand("gone").exists(in: store))
        XCTAssertTrue(AppDestination.category("hair").exists(in: store))
        XCTAssertFalse(AppDestination.category("gone").exists(in: store))
        XCTAssertTrue(AppDestination.search("anything").exists(in: store))
        XCTAssertTrue(AppDestination.product("gone").exists(in: CatalogStore(catalog: fixture, complete: false)),
                      "until the whole catalog is in, it may be there")
    }

    func testIntentsOpenTheirScreen() async throws {
        let router = IntentRouter.shared
        defer { router.openRequest = nil }
        _ = try await ShowDealsIntent().perform()
        XCTAssertEqual(router.openRequest, .deals)
        _ = try await TrackOrderIntent().perform()
        XCTAssertEqual(router.openRequest, .orders)
        let search = SearchMarracatIntent()
        search.query = "  shea butter  "
        _ = try await search.perform()
        XCTAssertEqual(router.openRequest, .search("shea butter"))
        let open = OpenBrandIntent()
        open.target = BrandEntity(brand("telfar", "Telfar"))
        _ = try await open.perform()
        XCTAssertEqual(router.openRequest, .brand("telfar"))
        XCTAssertNil(AppDestination.searchFor("   "), "a blank search opens nothing")
    }

    func testTheAppOpensARequestedScreenOnItsTab() {
        let nav = AppNav(), router = Router()
        nav.routers[.browse] = router
        let d = AppDestination.category("hair")
        nav.show(d.path, in: d.tab)
        XCTAssertEqual(nav.tab, .browse)
        XCTAssertEqual(router.path, [.category("hair")])
    }

    func testEveryShortcutPhraseIsRegistered() {
        XCTAssertEqual(MarracatShortcuts.appShortcuts.count, 5)
    }

    // MARK: Entity queries

    func testBrandsMatchByNameWhateverTheCaseAccentsOrSpacing() {
        let brands = fixture.brands, premier = ["fenty-beauty", "telfar", "koba-skincare"]
        XCTAssertEqual(IntentMatching.brands(matching: "telfar", in: brands, premier: premier).first?.id, "telfar")
        XCTAssertEqual(IntentMatching.brands(matching: "TELFAR", in: brands, premier: premier).first?.id, "telfar")
        XCTAssertEqual(IntentMatching.brands(matching: "fenty", in: brands, premier: premier).map(\.id), ["fenty-beauty"])
        XCTAssertEqual(IntentMatching.brands(matching: "fentybeauty", in: brands, premier: premier).first?.id, "fenty-beauty")
        XCTAssertEqual(IntentMatching.brands(matching: "tefi", in: brands, premier: premier).first?.id, "tefi", "accents fold")
        XCTAssertEqual(IntentMatching.brands(matching: "skincare", in: brands, premier: premier).map(\.id), ["koba-skincare"])
        XCTAssertEqual(IntentMatching.brands(matching: "  ", in: brands, premier: premier), [])
        // "te" starts Telfar and Téfi: the premier one leads.
        XCTAssertEqual(IntentMatching.brands(matching: "te", in: brands, premier: premier).map(\.id), ["telfar", "tefi"])
    }

    func testDepartmentsMatchByName() {
        XCTAssertEqual(IntentMatching.categories(matching: "hair", in: fixture.categories).map(\.id), ["hair"])
        XCTAssertEqual(IntentMatching.categories(matching: "Skincare products", in: fixture.categories).map(\.id), ["skincare"])
        XCTAssertEqual(IntentMatching.categories(matching: "", in: fixture.categories), [])
    }

    func testProductSearchMatchesTheAppsSearchAndRunsOffTheMainThread() async {
        let store = CatalogStore(catalog: fixture)
        store.buildSearchIndexNow()
        let snapshot = store.searchSnapshot
        let found = await Task.detached { () -> ([ProductEntity], Bool) in
            (IntentMatching.products(matching: "shopping", in: snapshot), pthread_main_np() != 0)
        }.value
        XCTAssertFalse(found.1, "searched off the main thread")
        XCTAssertEqual(found.0.map(\.id), store.search("shopping").map(\.id))
        XCTAssertEqual(Set(found.0.map(\.id)), ["p1", "p4"])
        XCTAssertEqual(found.0.first { $0.id == "p1" }?.brandName, "Telfar")
        XCTAssertEqual(IntentMatching.products(matching: "shopping", in: snapshot, limit: 1).count, 1)
    }

    func testQueriesReadTheAppsCatalog() async throws {
        let router = IntentRouter.shared
        let (savedCatalog, savedShopper) = (router.catalog, router.shopper)
        defer { router.catalog = savedCatalog; router.shopper = savedShopper }
        let defaults = UserDefaults(suiteName: "siri-\(UUID().uuidString)")!
        router.catalog = CatalogStore(catalog: fixture)
        router.shopper = ShopperStore(defaults: defaults)
        router.shopper?.toggleSaved("p3")

        let products = try await ProductQuery().entities(for: ["p2", "missing"])
        XCTAssertEqual(products.map(\.id), ["p2"])
        XCTAssertEqual(products.first?.brandName, "Fenty Beauty")
        let gloss = try await ProductQuery().entities(matching: "gloss bomb").map(\.id)
        XCTAssertEqual(gloss, ["p2"])
        let suggestedProducts = try await ProductQuery().suggestedEntities().map(\.id)
        XCTAssertEqual(suggestedProducts, ["p3"], "saved items are suggested")
        let telfar = try await BrandQuery().entities(matching: "telfar").map(\.id)
        XCTAssertEqual(telfar, ["telfar"])
        let koba = try await BrandQuery().entities(for: ["koba-skincare"]).map(\.name)
        XCTAssertEqual(koba, ["KOBA Skincare"])
        let suggested = try await BrandQuery().suggestedEntities().map(\.id)
        XCTAssertTrue(suggested.contains("telfar"), "Siri listens for the premier brands: \(suggested)")
        let hair = try await CategoryQuery().entities(matching: "hair").map(\.id)
        XCTAssertEqual(hair, ["hair"])
    }

    func testSuggestionsAreSavedThenRecentWithoutRepeats() {
        XCTAssertEqual(IntentMatching.suggestedProductIDs(saved: ["a", "b"], recentlyViewed: ["b", "c"], personalization: true), ["a", "b", "c"])
        XCTAssertEqual(IntentMatching.suggestedProductIDs(saved: ["a"], recentlyViewed: ["c"], personalization: false), ["a"])
        XCTAssertEqual(IntentMatching.suggestedBrandIDs(premier: ["x", "y"], followed: ["z", "x"]), ["x", "y", "z"])
    }

    // MARK: What Spotlight indexes

    private func entries(saved: [String] = [], recent: [String] = [], personalization: Bool = true,
                         followed: Set<String> = [], premier: [String] = ["telfar"]) -> [SpotlightEntry] {
        let store = CatalogStore(catalog: fixture)
        return SpotlightIndexer.entries(saved: saved, recentlyViewed: recent, personalization: personalization,
                                        followedBrands: followed, premierBrandIDs: premier,
                                        product: store.product, brand: store.brand)
    }

    func testSpotlightHoldsSavesFollowsPremierAndRecentOnly() {
        let e = entries(saved: ["p2"], recent: ["p3", "p2"], followed: ["koba-skincare"])
        XCTAssertEqual(e.map(\.id), ["product:p2", "brand:koba-skincare", "brand:telfar", "product:p3"])
        XCTAssertEqual(e.first?.priority, SpotlightIndexer.Priority.saved, "a saved item seen again keeps its saved rank")
        XCTAssertEqual(e.first?.subtitle, "Fenty Beauty · $38.00")
        XCTAssertFalse(e.map(\.id).contains("product:p1"), "nothing the shopper didn't save or view")
        XCTAssertFalse(e.map(\.id).contains("product:p4"))
    }

    func testRecentlyViewedStaysOutWithPersonalizationOff() {
        XCTAssertEqual(entries(saved: ["p2"], recent: ["p3"], personalization: false).map(\.id), ["product:p2", "brand:telfar"])
    }

    func testUnknownIdsAreSkippedAndListsAreCapped() {
        XCTAssertEqual(entries(saved: ["gone"], followed: ["gone-brand"]).map(\.id), ["brand:telfar"])
        let store = CatalogStore(catalog: fixture)
        let many = (0..<1000).map { "s\($0)" }
        let capped = SpotlightIndexer.entries(saved: many, recentlyViewed: many.map { "r" + $0 }, personalization: true,
                                              followedBrands: [], premierBrandIDs: [],
                                              product: { id in self.product(id, brand: "telfar", title: id) }, brand: store.brand)
        XCTAssertEqual(capped.count, SpotlightIndexer.maxSaved + SpotlightIndexer.maxRecent)
    }

    func testAnUnsaveRemovesTheItemAndOnlyChangesAreSent() {
        let before = entries(saved: ["p2", "p3"])
        let indexed = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.fingerprint) })
        let after = entries(saved: ["p3"])
        let diff = SpotlightIndexer.diff(indexed: indexed, wanted: after)
        XCTAssertEqual(diff.delete, ["product:p2"])
        XCTAssertEqual(diff.send, [], "nothing else changed")
        XCTAssertEqual(SpotlightIndexer.diff(indexed: [:], wanted: after).send.count, after.count)
    }

    func testSignedOutOnlyThePremierBrandsAndTheGuestsOwnItemsRemain() {
        let alerts = DealAlertStore.shared
        alerts.signedOut()
        XCTAssertTrue(alerts.brands.isEmpty, "the account's follows are gone from the phone")
        XCTAssertEqual(entries(followed: alerts.brands).map(\.id), ["brand:telfar"])
    }

    func testSignOutClearsTheRecordOfWhatWasIndexed() async {
        // Its own sync on its own defaults: the shared one belongs to the host
        // app, whose launch syncs used to land between the clear and the check.
        let defaults = UserDefaults(suiteName: "spotlight-\(UUID().uuidString)")!
        defaults.set(["product:p2": "x"], forKey: "spotlight.indexed")
        // Syncing off: a reindex request from Spotlight mid-test must not
        // write the host's entries back into the record (removeAll ignores it).
        let sync = SpotlightSync(defaults: defaults, enabled: false)
        sync.removeAll()
        await sync.flush()
        // Empty or gone both mean "nothing indexed". Gone happens when
        // Spotlight asks for a full reindex (the delegate forgets the record),
        // which the daemon does on its own schedule (seen in a full run on a
        // freshly booted simulator, 2026-10-14: the record read nil, and the
        // delegate is the only code that removes it). The old check
        // (count == 0) failed whenever that landed before it.
        XCTAssertTrue((sync.indexed ?? [:]).isEmpty,
                      "record \(String(describing: sync.indexed)), reindex-all asks \(sync.reindexAllRequests)")
    }

    func testASpotlightReindexRequestForgetsTheRecord() async {
        let defaults = UserDefaults(suiteName: "spotlight-\(UUID().uuidString)")!
        defaults.set(["product:p2": "x"], forKey: "spotlight.indexed")
        let sync = SpotlightSync(defaults: defaults, enabled: true)
        // No stores to re-sync from, so nothing writes the record back before the check.
        let router = IntentRouter.shared
        let (savedCatalog, savedShopper) = (router.catalog, router.shopper)
        defer { router.catalog = savedCatalog; router.shopper = savedShopper }
        router.catalog = nil
        let acknowledged = expectation(description: "acknowledged")
        sync.searchableIndex(CSSearchableIndex(name: SpotlightSync.indexName),
                             reindexAllSearchableItemsWithAcknowledgementHandler: { acknowledged.fulfill() })
        await fulfillment(of: [acknowledged], timeout: 5)
        XCTAssertNil(sync.indexed, "the next sync starts clean and sends everything")
        XCTAssertEqual(sync.reindexAllRequests, 1)
    }

    func testTheUnitTestHostNeverSyncsSpotlightItself() {
        // The flake's cause (2026-10-14): the host app's own scheduled syncs
        // wrote the record the tests read. In the test host they're off.
        XCTAssertFalse(SpotlightSync.enabledInThisProcess)
        let store = CatalogStore(catalog: fixture)
        let shopper = ShopperStore(defaults: UserDefaults(suiteName: "spotlight-\(UUID().uuidString)")!)
        let before = SpotlightSync.shared.scheduled
        SpotlightSync.shared.schedule(catalog: store, shopper: shopper, delay: .zero)
        XCTAssertEqual(SpotlightSync.shared.scheduled, before)
        XCTAssertEqual(SpotlightSync.shared.scheduled, 0, "the host app scheduled none either")
    }

    func testSpotlightItemsCarryTheirIdentifierAndLink() {
        let e = entries(saved: ["p2"]).first!
        let item = SpotlightItems.item(e)
        XCTAssertEqual(item.uniqueIdentifier, "product:p2")
        XCTAssertEqual(item.domainIdentifier, "product")
        XCTAssertEqual(item.attributeSet.title, "Gloss Bomb Lip Luminizer")
        XCTAssertEqual(item.attributeSet.contentURL, URL(string: "marracat://product/p2"))
    }
}
