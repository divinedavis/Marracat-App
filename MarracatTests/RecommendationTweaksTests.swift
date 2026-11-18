import XCTest
@testable import Marracat

/// Owner's ML tweaks, 2026-10-10: smarter search rows, other-department slots,
/// recommendation view/tap counting, and the "Goes well with" source order.
@MainActor
final class RecommendationTweaksTests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: #2 search rows

    func testOccasionSearchesExpire() {
        var m = SearchMemory()
        m.searched("fathers day gifts", at: day(2026, 6, 10))
        XCTAssertFalse(m.isExpired("fathers day gifts", now: day(2026, 6, 15)), "five days before Father's Day")
        XCTAssertTrue(m.isExpired("fathers day gifts", now: day(2026, 6, 23)), "Father's Day (6/21) has passed")
        XCTAssertTrue(m.isExpired("fathers day gifts", now: day(2026, 6, 25)), "over ten days old")
        // Synced with no date: only alive in the run-up to the holiday.
        let none = SearchMemory()
        XCTAssertTrue(none.isExpired("mothers day gifts", now: day(2026, 10, 10)))
        XCTAssertFalse(none.isExpired("mothers day gifts", now: day(2026, 4, 20)))
        XCTAssertFalse(none.isExpired("organic body wash", now: day(2026, 10, 10)), "not an occasion")
        // A birthday has no calendar day: ten days after it was searched.
        var b = SearchMemory(); b.searched("birthday card for dad", at: day(2026, 10, 1))
        XCTAssertFalse(b.isExpired("birthday card for dad", now: day(2026, 10, 5)))
        XCTAssertTrue(b.isExpired("birthday card for dad", now: day(2026, 10, 12)))
    }

    func testAnActionWithinHalfAnHourCreditsTheSearch() {
        var m = SearchMemory()
        let t = day(2026, 10, 10)
        m.searched("Shea Butter", at: t)
        m.noteAction(at: t.addingTimeInterval(10 * 60))
        XCTAssertTrue(m.actedOn("shea butter"))
        m.searched("socks", at: t.addingTimeInterval(20 * 60))
        m.noteAction(at: t.addingTimeInterval(20 * 60 + 31 * 60))
        XCTAssertFalse(m.actedOn("socks"), "too long after the search")
    }

    func testActedOnSearchLeadsHome() {
        let c = CatalogStore(synchronously: true)
        var m = SearchMemory()
        m.searched("candle"); m.searched("shea butter")
        m.lastQuery = "candle"; m.lastAt = .now; m.noteAction()
        let rows = c.forYou(searches: ["shea butter", "candle"], viewed: [], saved: [], memory: m)
        XCTAssertEqual(rows.first?.id, "search:candle", "the search acted on comes first, though older")
    }

    func testAProductNameSearchBecomesABrandOrKindRow() throws {
        let c = CatalogStore(synchronously: true)
        let candidates = c.catalog.products.lazy.filter { $0.available && $0.title.split(separator: " ").count >= 4
            && c.products(for: $0.brand).filter(\.available).count >= 8 }.prefix(300)
        let p = try XCTUnwrap(candidates.first { CatalogStore.lookedUpProduct($0.title, in: c.search($0.title)) != nil })
        XCTAssertNil(CatalogStore.lookedUpProduct("shea butter", in: c.search("shea butter")), "two words is a browse")
        let rows = c.forYou(searches: [p.title], viewed: [], saved: [])
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.title.hasPrefix("More from") || row.title.hasSuffix("like this"), row.title)
        XCTAssertFalse(row.title.contains("Inspired by your search"))
        XCTAssertFalse(row.products.contains { $0.id == p.id }, "not the product they already found")
        XCTAssertEqual(row.track, "search")
    }

    // MARK: #3 other departments

    func testTasteRowsKeepFourSlotsForOtherDepartments() throws {
        let c = CatalogStore(synchronously: true)
        let skincare = Array(c.products(in: "skincare").filter(\.available).prefix(40))
        try XCTSkipIf(skincare.count < 20)
        let row = Array(skincare.prefix(12))
        let lean: [(category: String, weight: Double)] = [("skincare", 40), ("jewelry", 4), ("hair", 3), ("household", 2), ("grocery", 1)]
        let bought = c.products(in: "jewelry").filter(\.available).prefix(3).map(\.id)
        let mixed = c.reservingOtherDepartments(row, pool: skincare, lean: lean, excluded: Set(bought))
        XCTAssertEqual(mixed.products.count, 12)
        XCTAssertEqual(mixed.reserved.count, 4)
        let others = mixed.products.enumerated().filter { $0.element.category != "skincare" }
        XCTAssertEqual(others.map(\.offset), [2, 5, 8, 11], "spread through the row, not at the end")
        XCTAssertEqual(others.map(\.element.category), ["jewelry", "hair", "household", "grocery"], "their own departments, in order")
        XCTAssertTrue(Set(bought).isDisjoint(with: mixed.products.map(\.id)), "bought items never fill a slot")
        // A short row keeps three.
        XCTAssertEqual(c.reservingOtherDepartments(Array(row.prefix(8)), pool: skincare, lean: lean, excluded: []).reserved.count, 3)
        // A row already mixed needs nothing added.
        let already = c.reservingOtherDepartments(mixed.products, pool: skincare, lean: lean, excluded: [])
        XCTAssertTrue(already.reserved.isEmpty)
    }

    /// The kept slots come only from departments the shopper bought from,
    /// liked, looked at or searched, one per kind (owner, 2026-11-09: "if
    /// they never purchase dog food or search for it we should never show
    /// it"). Jewelry and bags are fashion beside clothes, so a clothes
    /// shopper's slots are their laundry and the pet search, and nothing
    /// they never touched.
    func testKeptSlotsComeOnlyFromTheShoppersOwnDepartments() throws {
        let c = CatalogStore(synchronously: true)
        let clothes = Array(c.products(in: "clothing").filter(\.available).prefix(40))
        let laundry = c.products(in: "household").filter { $0.available && $0.subs.contains("laundry") }
        try XCTSkipIf(clothes.count < 20 || laundry.count < 2)
        let lean: [(category: String, weight: Double)] = [("clothing", 40), ("jewelry", 12), ("bags", 6), ("household", 2)]
        let mixed = c.reservingOtherDepartments(Array(clothes.prefix(12)), pool: clothes, lean: lean, searched: ["pets"],
                                                seeds: [laundry[0]], excluded: [laundry[0].id])
        let kept = mixed.products.filter { mixed.reserved.contains($0.id) }
        XCTAssertEqual(kept.map(\.category), ["household", "pets"])
        XCTAssertFalse(Set(kept[0].subs).isDisjoint(with: laundry[0].subs), "the household slot comes from their laundry aisle: \(kept[0].title)")
        // Nothing else of theirs: the row stays as it is.
        let alone = c.reservingOtherDepartments(Array(clothes.prefix(12)), pool: clothes, lean: [("clothing", 40), ("shoes", 5)], excluded: [])
        XCTAssertTrue(alone.reserved.isEmpty)
        XCTAssertEqual(alone.products.map(\.id), Array(clothes.prefix(12)).map(\.id))
    }

    /// Departments a shopper has shown interest in: bought, liked, viewed,
    /// or a quarter of a search's top results.
    func testTouchedDepartmentsComeFromBuysLikesViewsAndSearches() throws {
        let c = CatalogStore(synchronously: true)
        let laundry = c.products(in: "household").filter { $0.subs.contains("laundry") }
        let candle = c.products(in: "home").first
        try XCTSkipIf(laundry.isEmpty || candle == nil)
        XCTAssertEqual(c.touchedDepartments(viewed: [], saved: [], purchased: [], searches: []), [], "a new shopper: nothing held back")
        let touched = c.touchedDepartments(viewed: [candle!.id], saved: [], purchased: [laundry[0].id], searches: ["dog treats"])
        XCTAssertTrue(touched.isSuperset(of: ["household", "home", "pets"]), "\(touched)")
        XCTAssertFalse(touched.contains("grocery"))
        XCTAssertFalse(touched.contains("clothing"))
    }

    /// Bought laundry detergent: other brands' laundry and the same brand's
    /// other items (owner, 2026-11-09: "different laundry detergent brands,
    /// the same detergent brands but different items like dryer sheets").
    /// Every row on Home stays in the departments they've touched.
    func testLaundryBuyersSeeOtherBrandsAndTheBrandsOtherItems() throws {
        let c = CatalogStore(synchronously: true)
        let laundry = c.products(in: "household").filter { $0.available && $0.subs.contains("laundry") }
        let byBrand = Dictionary(grouping: laundry, by: \.brand)
        let seed = try XCTUnwrap(laundry.first { byBrand[$0.brand, default: []].count >= 3 })
        try XCTSkipIf(byBrand.count < 3)
        let rows = c.aisleRows(seeds: [seed.id], shown: [], excluded: [seed.id])
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.title.hasPrefix("More for your "), row.title)
        XCTAssertEqual(row.track, "aisle")
        XCTAssertGreaterThanOrEqual(row.products.count, 4)
        XCTAssertTrue(row.products.allSatisfy { $0.category == "household" }, "the laundry's own department only")
        let others = row.products.filter { $0.brand != seed.brand }
        let same = row.products.filter { $0.brand == seed.brand }
        XCTAssertFalse(others.isEmpty, "other brands' laundry")
        XCTAssertTrue(others.allSatisfy { !Set($0.subs).isDisjoint(with: seed.subs) }, "other brands from the same aisle")
        XCTAssertFalse(same.isEmpty, "the same brand's other items")
        XCTAssertFalse(row.products.contains { $0.id == seed.id || $0.title.lowercased() == seed.title.lowercased() })
        XCTAssertNotEqual(row.products[0].brand, row.products[1].brand, "taking turns")

        let home = c.forYou(searches: [], viewed: [], saved: [], purchased: [seed.id])
        XCTAssertTrue(home.contains { $0.track == "aisle" })
        XCTAssertTrue(home.flatMap(\.products).allSatisfy { $0.category == "household" },
                      "nothing from a department they never touched: \(Set(home.flatMap(\.products).map(\.category)))")
    }

    /// Discover more keeps to the shopper's departments once they have any.
    func testDiscoverMoreKeepsToTheShoppersDepartments() throws {
        let c = CatalogStore(synchronously: true)
        try XCTSkipIf(c.products(in: "household").filter(\.available).count < 40)
        let theirs = c.discoverRow(mix: BrandMix(seed: 1), hidden: [], limit: 40, departments: ["household"])
        XCTAssertGreaterThanOrEqual(theirs.count, 20)
        XCTAssertTrue(theirs.allSatisfy { $0.category == "household" }, "\(Set(theirs.map(\.category)))")
        let everyone = c.discoverRow(mix: BrandMix(seed: 1), hidden: [], limit: 40)
        XCTAssertGreaterThan(Set(everyone.map(\.category)).count, 3, "a new shopper sees the whole store")
    }

    // MARK: #1 + analytics client

    /// A client on its own UserDefaults with a stub transport.
    private func client() -> (Analytics, () -> [[Analytics.Event]], UserDefaults) {
        let suite = "analytics-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let a = Analytics(defaults: d)
        var sent: [[Analytics.Event]] = []
        a.transport = { sent.append($0) }
        return (a, { sent }, d)
    }

    func testRecRowsCountOnceAndBatchAtFifty() throws {
        let c = CatalogStore(synchronously: true)
        let p = try XCTUnwrap(c.catalog.products.first(where: \.available))
        let (a, sent, _) = client()
        a.appOpened()
        a.rowViewed("taste", first: p)
        a.rowViewed("taste", first: p)
        XCTAssertEqual(a.queue.filter { $0.name == "rec_view" }.count, 1, "a row counts as seen once per session")
        a.appBackgrounded(); a.appOpened(); a.rowViewed("taste", first: p)
        XCTAssertEqual(a.queue.filter { $0.name == "rec_view" }.count, 1, "seen again in a new session")
        for i in 0..<115 { a.tapped(row: "search", product: p, position: i % 12) }
        a.flush()
        XCTAssertEqual(sent().map(\.count), [3, 50, 50, 17], "session 1 flushed on background; then at most 50 per request")
        XCTAssertTrue(a.queue.isEmpty)
        let tap = try XCTUnwrap(sent()[1].first { $0.name == "rec_tap" })
        XCTAssertEqual(tap["row"], .string("search"))
        XCTAssertEqual(tap["product"], .string(p.id))
        XCTAssertEqual(tap["platform"], .string("ios"))
        XCTAssertNotNil(tap["position"])
    }

    func testPersonalizationOffStopsOnlyRecommendationEvents() throws {
        let c = CatalogStore(synchronously: true)
        let p = try XCTUnwrap(c.catalog.products.first(where: \.available))
        let (a, _, _) = client()
        a.personalizationEnabled = { false }
        a.rowViewed("restock", first: p)
        a.tapped(row: "search", product: p, position: 1)
        a.track("save", ["product": .string(p.id)])
        XCTAssertEqual(a.queue.map(\.name), ["save"])
    }

    func testShareUsageOffSendsNothingAndClearsTheQueue() {
        let (a, sent, d) = client()
        a.track("app_open"); a.track("screen_view", ["screen": .string("home")])
        a.persist()
        XCTAssertNotNil(d.data(forKey: "analytics.queue.v1"))
        a.isEnabled = false
        XCTAssertTrue(a.queue.isEmpty, "turning it off drops what was waiting")
        XCTAssertNil(d.data(forKey: "analytics.queue.v1"))
        a.track("search", ["q": .string("candle")])
        a.requeue([Analytics.Event(name: "save", props: [:])])
        a.flush()
        XCTAssertTrue(a.queue.isEmpty)
        XCTAssertTrue(sent().isEmpty)
        a.isEnabled = true
        XCTAssertTrue(Analytics(defaults: d).isEnabled, "the switch is remembered")
    }

    func testOfflineQueueIsCappedAndSurvivesARelaunch() {
        let (a, _, d) = client()
        for i in 0..<(Analytics.maxQueue + 37) { a.track("search", ["q": .string("q\(i)")]) }
        XCTAssertEqual(a.queue.count, Analytics.maxQueue)
        XCTAssertEqual(a.queue.first?["q"], .string("q37"), "oldest dropped first")
        a.persist()
        let relaunched = Analytics(defaults: d)
        XCTAssertEqual(relaunched.queue.count, Analytics.maxQueue)
        XCTAssertEqual(relaunched.queue.last, a.queue.last)
        // A failed send goes back on the queue, still capped: the newest are
        // kept, so a full queue drops the older, failed batch first.
        relaunched.requeue((0..<20).map { Analytics.Event(name: "save", props: ["product": .string("p\($0)")]) })
        XCTAssertEqual(relaunched.queue.count, Analytics.maxQueue)
        XCTAssertEqual(relaunched.queue.last, a.queue.last)
        // With room, the failed batch goes back in front of newer events.
        let (b, _, _) = client()
        b.track("search", ["q": .string("newer")])
        b.requeue([Analytics.Event(name: "save", props: ["product": .string("p1")])])
        XCTAssertEqual(b.queue.map(\.name), ["save", "search"])
    }

    /// iOS launches the app in the background for the catalog refresh and
    /// SwiftUI still lays out Home; those launches must not read as a visit.
    func testBackgroundLaunchSendsNoScreenOrRowViews() throws {
        let c = CatalogStore(synchronously: true)
        let p = try XCTUnwrap(c.catalog.products.first(where: \.available))
        let (a, sent, _) = client()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        a.now = { clock }
        // Background launch at 2 AM: Home appears, a row lays out, no app_open.
        a.screen("home"); a.rowViewed("taste", first: p)
        a.flush()
        XCTAssertTrue(sent().isEmpty, "nothing leaves the phone before the app comes to the foreground")
        XCTAssertTrue(a.queue.isEmpty)
        // Opened by hand hours later: the old views are stale and dropped.
        clock += 4 * 3600
        a.appOpened()
        XCTAssertEqual(a.queue.map(\.name), ["app_open"])
        a.appBackgrounded()
        // Another background launch that ends with the scene backgrounded.
        a.screen("home"); a.appBackgrounded()
        XCTAssertFalse(sent().flatMap { $0 }.contains { $0.name == "screen_view" })
    }

    /// A real cold launch lays Home out a moment before the scene goes
    /// active; that Home view and its rows still count, once.
    func testColdLaunchKeepsTheViewsJustBeforeAppOpen() throws {
        let c = CatalogStore(synchronously: true)
        let p = try XCTUnwrap(c.catalog.products.first(where: \.available))
        let (a, _, _) = client()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        a.now = { clock }
        a.screen("home"); a.rowViewed("taste", first: p)
        clock += 1
        a.appOpened()
        XCTAssertEqual(a.queue.map(\.name), ["app_open", "screen_view", "rec_view"])
        a.rowViewed("taste", first: p)
        XCTAssertEqual(a.queue.filter { $0.name == "rec_view" }.count, 1, "the held row still counts once per session")
    }

    func testEventsEncodeFlatWithTheServerSchema() throws {
        let c = CatalogStore(synchronously: true)
        let p = try XCTUnwrap(c.catalog.products.first(where: \.available))
        let (a, sent, _) = client()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        a.now = { clock }
        a.appOpened()
        a.screen("home")
        a.tapped(row: "taste", product: p, position: 3)
        a.productViewed(p)
        clock += 7
        a.galleryZoomed(product: p.id, photo: "1.jpg"); a.galleryZoomed(product: p.id, photo: "1.jpg")
        a.productLeft(p)
        a.search("  Shea Butter  ", results: 12, source: "suggestion")
        a.search("   ", results: 0, source: "typed")
        clock += 60
        a.appBackgrounded()
        let events = sent().flatMap { $0 }
        XCTAssertEqual(events.map(\.name), ["app_open", "screen_view", "rec_tap", "gallery_zoom", "product_view", "search", "session_end"])
        XCTAssertEqual(events[0]["cold"], .bool(true))
        XCTAssertEqual(events[1]["screen"], .string("home"))
        let view = events[4]
        XCTAssertEqual(view["source"], .string("taste"), "the row the product was opened from")
        XCTAssertEqual(view["dwell_s"], .int(7))
        XCTAssertEqual(view["brand"], .string(p.brand))
        XCTAssertEqual(events[5]["q"], .string("Shea Butter"))
        XCTAssertEqual(events[5]["n"], .int(12))
        XCTAssertEqual(events[5]["source"], .string("suggestion"))
        XCTAssertEqual(events[6]["duration_s"], .int(67))
        // Wire format: {"name": …, props at the top level}.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(events[5])) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "search")
        XCTAssertEqual(json["n"] as? Int, 12)
        XCTAssertNil(json["props"])
        a.appOpened()
        XCTAssertEqual(a.queue.last?["cold"], .bool(false), "a return from the background is warm")
    }

    func testServerVocabularyHelpers() {
        XCTAssertEqual(Analytics.subtotalBucket(12.5), 0)
        XCTAssertEqual(Analytics.subtotalBucket(49.99), 25)
        XCTAssertEqual(Analytics.subtotalBucket(250), 250)
        XCTAssertEqual(Analytics.subtotalBucket(1200), 500)
        XCTAssertEqual(Analytics.rowID("trueMetal"), "true_metal")
        XCTAssertEqual(Analytics.rowID("clean"), "clean")
        var a = ProductFilters(), b = ProductFilters()
        b.offers = [.inStock, .trueMetal, .organic]
        b.brands = ["telfar"]
        b.colors = ["Black"]
        b.priceBands = [PriceBand.all[0].name]
        b.sort = .priceLow
        let changes = FilterBar.changes(from: a, to: b)
        XCTAssertEqual(changes.map(\.filter), ["brand", "in_stock", "metal", "under_25", "sort"], "colors and organic have no server name")
        XCTAssertEqual(changes.map(\.value), ["telfar", "on", "on", "on", "low"])
        a = b; b.offers = []
        XCTAssertEqual(FilterBar.changes(from: a, to: b).map(\.value), ["off", "off"])
    }

    // MARK: #4 Goes well with

    func testComplementsComeBeforePairsAndTheFallback() throws {
        let c = CatalogStore(synchronously: true)
        let ps = Array(c.catalog.products.filter(\.available).prefix(10))
        XCTAssertEqual(Pairings.choose(complements: Array(ps.prefix(5)), learned: Array(ps.suffix(5)))?.source, .complements)
        XCTAssertEqual(Pairings.choose(complements: Array(ps.prefix(2)), learned: Array(ps.suffix(5)))?.source, .boughtTogether)
        XCTAssertNil(Pairings.choose(complements: Array(ps.prefix(2)), learned: Array(ps.prefix(3))), "fewer than four: style fallback")
    }

    func testGoesWellWithSkipsWhatTheRowsAboveShow() throws {
        let c = CatalogStore(synchronously: true)
        let ps = Array(c.catalog.products.filter(\.available).prefix(8))
        let shown = Set(ps.prefix(3).map(\.id))
        let left = Pairings.unseen(ps, shown: shown)
        XCTAssertEqual(left.map(\.id), ps.dropFirst(3).map(\.id), "a product in Similar look or More from never repeats in Goes well with")
        // Too few left after the repeats go: the row falls through to the next source.
        XCTAssertNil(Pairings.choose(complements: Pairings.unseen(Array(ps.prefix(5)), shown: shown), learned: []))
    }

    func testRowsLeadWithTheSameBrandAndOtherBrandsOnlyFill() throws {
        let c = CatalogStore(synchronously: true)
        let ps = Array(c.catalog.products.filter(\.available).prefix(400))
        guard let brand = ps.first?.brand, ps.contains(where: { $0.brand != brand }) else { throw XCTSkip("one brand") }
        let mixed = ps.reversed().map { $0 }
        let out = Pairings.brandFirst(mixed, brand: brand)
        let own = out.prefix { $0.brand == brand }
        XCTAssertEqual(own.count, mixed.filter { $0.brand == brand }.count, "every same-brand product comes before any other brand")
        XCTAssertEqual(out.count, mixed.count, "other brands still fill the row")
    }

    func testComplementsAreFetchedOncePerProduct() async {
        Pairings.clearCaches()
        var calls = 0
        let original = Pairings.fetchComplements
        Pairings.fetchComplements = { _ in calls += 1; return ["a", "b"] }
        defer { Pairings.fetchComplements = original; Pairings.clearCaches() }
        _ = await Pairings.complements(for: "x")
        let again = await Pairings.complements(for: "x")
        XCTAssertEqual(again, ["a", "b"])
        XCTAssertEqual(calls, 1)
    }

    // MARK: searched departments never search on the slow path at launch

    private func item(_ id: String, _ category: String) -> Product {
        Product(id: id, brand: "b", title: id, category: category, productType: nil, subs: [], price: 20, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: nil)
    }

    /// 8f917a7 ran the shopper's recent searches on the main thread the moment
    /// the catalog landed, before the word index was built: launch went from
    /// 1.97 s to 6.9 s (perf gate, 2026-11-09). A query is searched for its
    /// departments only when that is free (memoized) or there is no saved
    /// answer and the index isn't mid-build.
    func testNoSearchForDepartmentsAtLaunch() {
        let now = CatalogStore.searchesNow
        XCTAssertFalse(now(true, false, false), "index warming, nothing memoized: this was the launch stall")
        XCTAssertFalse(now(true, false, true))
        XCTAssertFalse(now(false, false, true), "a saved answer is used; no search on the main thread for it")
        XCTAssertTrue(now(false, false, false), "first time for this query, index ready (or never started, as in tests)")
        XCTAssertTrue(now(true, true, false), "memoized results cost nothing")
        XCTAssertTrue(now(false, true, true), "memoized results refresh the saved answer")
    }

    func testASearchsDepartmentsAreThoseWithAQuarterOfItsTopTwenty() {
        let results = (0..<12).map { item("h\($0)", "home") } + (0..<5).map { item("p\($0)", "pets") }
            + (0..<3).map { item("g\($0)", "grocery") } + (0..<30).map { item("c\($0)", "clothing") }
        // Top 20: 12 home, 5 pets, 3 grocery; clothing is past the top 20.
        XCTAssertEqual(CatalogStore.departments(of: results), ["home", "pets"])
        XCTAssertEqual(CatalogStore.departments(of: []), [])
    }

    func testSavedSearchDepartmentsKeepOnlyCurrentSearches() throws {
        let suite = "searched-departments-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SearchedDepartments.load(defaults), [:])
        SearchedDepartments.save(["candle": ["home"], "dog treats": ["pets"], "old search": ["grocery"]],
                                 keeping: ["Candle", "dog treats"], defaults: defaults)
        XCTAssertEqual(SearchedDepartments.load(defaults), ["candle": ["home"], "dog treats": ["pets"]],
                       "a search the shopper cleared takes its saved departments with it")
    }

    /// With the index in (here: never started), the answer is searched and
    /// saved, so the next launch has it without searching.
    func testSearchedDepartmentsAreSavedForTheNextLaunch() throws {
        let c = CatalogStore(synchronously: true)
        try XCTSkipIf(c.search("dog treats").isEmpty)
        UserDefaults.standard.removeObject(forKey: SearchedDepartments.key)
        defer { UserDefaults.standard.removeObject(forKey: SearchedDepartments.key) }
        let now = c.searchedDepartments(["Dog Treats"])
        XCTAssertTrue(now.contains("pets"), "\(now)")
        XCTAssertEqual(SearchedDepartments.load()["dog treats"], now)
        // A fresh store (the next launch) answers from the saved copy.
        UserDefaults.standard.set(["dog treats": ["grocery"]], forKey: SearchedDepartments.key)
        XCTAssertEqual(CatalogStore(synchronously: true).searchedDepartments(["dog treats"]), ["grocery"], "read back, not searched again")
    }
}
