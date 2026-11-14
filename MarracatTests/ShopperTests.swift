import XCTest
@testable import Marracat

final class ShopperTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() { suite = "MarracatTests." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)! }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testAccountsAreIsolatedAndGuestImportIsExplicit() {
        let s = ShopperStore(defaults: defaults)
        s.toggleSaved("guest-item")
        s.activate("google:alice")
        XCTAssertEqual(s.saved, [])
        s.importGuestActivity()
        XCTAssertEqual(s.saved, ["guest-item"])
        XCTAssertEqual(s.pending.count, 1)
        s.activate("google:bob")
        XCTAssertTrue(s.saved.isEmpty)
        s.activate(nil)
        XCTAssertTrue(s.saved.isEmpty, "Imported guest history must not leak after signout")
        s.activate("google:alice")
        XCTAssertEqual(s.saved, ["guest-item"])
    }
    func testSyncReplaysUnacknowledgedChangesWithoutResurrectingLikes() {
        let s = ShopperStore(defaults: defaults)
        s.activate("google:alice"); s.toggleSaved("a")
        let ack = s.pending[0].id
        s.toggleSaved("a") // This happened while the network request was running.
        s.accept(ShopperProfile(saved: ["a"]), acknowledged: [ack])
        XCTAssertTrue(s.saved.isEmpty)
        XCTAssertEqual(s.pending.count, 1)
        let restored = ShopperStore(defaults: defaults); restored.activate("google:alice")
        XCTAssertTrue(restored.saved.isEmpty); XCTAssertEqual(restored.pending.count, 1)
    }
    func testOptOutClearsAndStopsHistoryButKeepsExplicitLikes() {
        let s = ShopperStore(defaults: defaults)
        s.viewed("a"); s.searched("bags"); s.toggleSaved("a")
        s.setPersonalization(false); s.viewed("b"); s.searched("hair")
        XCTAssertTrue(s.recentlyViewed.isEmpty); XCTAssertTrue(s.recentSearches.isEmpty)
        XCTAssertEqual(s.saved, ["a"])
    }
    func testCheckoutDeduplicationAndLegacyDecoding() throws {
        let s = ShopperStore(defaults: defaults)
        let lines = [CartLine(productID: "item", variantID: 1, quantity: 1)]
        for _ in 0..<2 { s.recordCheckout(brandID: "brand", lines: lines, subtotal: 10, orderID: "order1", total: 12, currency: "USD", items: [PurchasedItem(title: "Final item", quantity: 2)]) }
        XCTAssertEqual(s.checkouts.count, 1)
        XCTAssertEqual(s.checkouts[0].itemCount, 2)
        XCTAssertEqual(s.checkouts[0].items?.first?.title, "Final item")
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","brandID":"brand","date":1,"itemCount":1,"subtotal":10,"productIDs":["item"]}"#
        XCTAssertNil(try JSONDecoder().decode(CheckoutRecord.self, from: Data(legacy.utf8)).orderID)
    }
    func testRecommendationsRespectHiddenPurchasedAndAvailability() {
        let c = CatalogStore(synchronously: true)
        let seeds = Array(c.catalog.products.filter(\.available).prefix(8).map(\.id))
        let initial = c.forYou(searches: ["shea butter"], viewed: [], saved: seeds)
        let hidden = Array(initial.flatMap(\.products).prefix(6).map(\.id))
        let purchased = Array(initial.flatMap(\.products).suffix(6).map(\.id))
        let rows = c.forYou(searches: ["shea butter"], viewed: [], saved: seeds, hidden: hidden, purchased: purchased)
        XCTAssertFalse(rows.isEmpty)
        for p in rows.flatMap(\.products) { XCTAssertTrue(p.available); XCTAssertFalse((hidden + purchased).contains(p.id)) }
        // Telfar is listed (2026-09-22, checking out over UCP) and premier since 2026-10-10.
        XCTAssertEqual(c.brand("telfar")?.checksOutByUCP, true)
        XCTAssertTrue(CatalogStore.premierBrandIDs.contains("telfar"))
    }
    func testCurvesIsPremierAndAlwaysFeaturesATote() {
        let c = CatalogStore(synchronously: true)
        XCTAssertTrue(c.isPremier("curves"))
        XCTAssertTrue(c.isPremier("ripl-efek"), "owner put RIPL EFEK back on the premier list on 2026-11-02")
        // The owner's seven (2026-11-04), in the order they named them.
        XCTAssertEqual(CatalogStore.premierBrandIDs,
                       ["fear-of-god", "fenty-beauty", "cecred", "sienna-naturals", "telfar", "curves", "ripl-efek"])
        for gone in ["koba-skincare", "the-honey-pot", "frederick-benjamin", "big-mouth-toothbrush"] {
            XCTAssertFalse(c.isPremier(gone), "owner took \(gone) off the premier list on 2026-11-04")
        }
        for gone in ["sweet-july", "therenaebrand"] {
            XCTAssertFalse(c.isPremier(gone), "owner took \(gone) off the premier list on 2026-10-30")
        }
        let products = c.products(for: "curves")
        // Every round, every launch: a tote, even when the drop has sold out.
        for seed in 0..<5 {
            var mix = BrandMix(seed: seed)
            for _ in 0..<12 {
                let p = mix.featured(products, brand: "curves")
                XCTAssertTrue(p?.title.lowercased().contains("tote") == true, "Curves featured \(p?.title ?? "nothing")")
                mix.next()
            }
        }
    }
}
