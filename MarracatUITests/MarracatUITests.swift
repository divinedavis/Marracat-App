import XCTest

class MarracatUITestCase: XCTestCase {
    fileprivate var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the cold-launch splash so each test starts on Home immediately;
        // testColdLaunchShowsSplash covers the splash itself.
        // -CHECKOUT_STUB: in-app checkout shows a stand-in sheet, so test runs
        // never open real checkout sessions on brands' Shopify stores.
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB"]
        // XCUITest waits for the app to settle after every tap, and that was
        // 9.7 min of a 35 min run (2026-10-18). In the environment, so tests
        // that replace launchArguments keep it; a fresh XCUIApplication (the
        // splash tests) still animates.
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        let test = name.split(separator: " ").last.map { String($0.dropLast()) } ?? ""
        if !Self.launchesItself.contains(test) { app.launch() }
    }

    /// Tests that start the app their own way first, so setUp doesn't launch
    /// it only for them to quit it (28 did, ~3 s each, 2026-10-18). One
    /// missing from here just launches twice; one wrongly listed fails on its
    /// first step.
    private static let launchesItself: Set<String> = [
        "testRealWooCheckoutLoads", "testSplashShowsOncePerDay", "testANewDayResumeOpensOnTheSplash", "testDeliveryLiveActivityFlipsBetweenOrders",
        "testBuyNowOrderIsTrackedWithoutTheOrderEmail", "testSponsoredProductsAreLabeled",
        "testGuestCartLinkCarriesTheOrderEmail", "testTypedZIPQuotesShipping", "testRealCheckoutSheetLoads",
        "testDefaultSplashRevealsAnInteractiveStorefront", "testRestockAlertNeedsSignIn",
        "testOwnerSeesTheLiveActivityTest", "testTrackPricePromptAndAlertButtons",
        "testRelaunchedHomeOpensOnItsRowsAndHoldsThem", "testHomePlaceholdersFitTheWindow",
        "testContinueCardOpensTheNextBrandFilledIn", "testLaterKeepsTheUnpaidBrandsInTheCart",
        "testOrderEmailShowsOrderNumberTrackingAndAddress", "testHomeRowCardsAreOneSize",
        "testColdLaunchShowsSplash", "testCorruptCachedCatalogFallsBackToTheBundledOne",
        "testScreensOpenedDuringLaunchWaitForTheWholeCatalog", "testRestockAlertFromASoldOutProduct",
        "testLiveStockShowsARestockedItemInStock", "testBritishProductKeepsPoundsThroughCartAndOrderHistory",
        "testBagTotalIncludesStandardShippingThenPaysEachBrand", "testStoresWithoutRatesSayShippingAtCheckout",
        "testBoostedBrandShowsAsSponsored", "testRealBagOpensStoreCheckoutWithoutAForm",
        "testABrandWithHairAndSkinOffersBothKindsOfFilter",
    ]

    fileprivate func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Taps a control on a scrolling page after scrolling it clear of the
    /// floating tab bar, as a shopper would: a tap under the bar lands on the
    /// bar. The product page's layout moves with every change (the 44 pt
    /// store link, 2026-10-03), so no test should assume where the button is.
    fileprivate func tapClearOfTabBar(_ e: XCUIElement) {
        let bar = app.buttons["tab.home"]
        for _ in 0..<4 where bar.exists && e.frame.maxY > bar.frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        e.tap()
    }

    /// Opens the first brand's checkout from the bag's hovering Checkout
    /// (owner, 2026-10-14). No details form first (owner, 2026-11-02): the
    /// store's checkout asks for the address.
    fileprivate func openBrandCheckout() {
        let checkout = any("cartCheckout")
        XCTAssertTrue(checkout.appears(timeout: 5), "no Checkout in the bag")
        checkout.tap()
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 10), "Checkout didn't open the brand's checkout")
        XCTAssertFalse(any("buyerForm").exists, "no Marracat details form before a brand's checkout")
    }

    /// You › Shipping address: the saved details, filled from the first order.
    fileprivate func openShippingDetails() {
        tapTab("You")
        let row = any("shippingDetailsRow")
        XCTAssertTrue(row.appears(timeout: 10), "no Shipping address row under You")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        // The Profile's search field floats over its rows, above the tab
        // bar. The Appearance row (2026-11-22) moved this one down a slot,
        // under the field, where it still counted as hittable and the tap
        // went to the field instead.
        let search = any("youSearch")
        XCTAssertTrue(search.exists, "the Profile's search field should be on screen")
        for _ in 0..<4 where row.frame.maxY > search.frame.minY - 8 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40)))
        }
        row.tap()
        XCTAssertTrue(any("buyerForm").appears(timeout: 5), "Shipping address didn't open the details form")
    }

    /// The floating tab bar is plain buttons (the system bar is hidden).
    fileprivate func tapTab(_ name: String) {
        let tab = app.buttons["tab.\(name.lowercased())"]
        XCTAssertTrue(tab.appears(timeout: 5), "\(name) tab missing")
        tab.tap()
    }

    fileprivate func openSoldOutItem() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        // Sold out in the bundled catalog: Pottery by Osa's handmade mugs are
        // one-offs, 28 listings all sold out across catalogs. The Curves tote
        // used before restocked every colour on 2026-10-19 and failed three tests.
        input.typeText("Earth Tone Mug\n")
        let result = app.descendants(matching: .any).matching(identifier: "resultTitleSoldOut").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
    }

    /// You › Notifications: the Live Activity switch for today's deliveries.
    /// The owner's test row is hidden from everyone else; -LIVE_ACTIVITY_OWNER
    /// stands in for the owner's account (the server decides in real use).
    fileprivate func openNotifications() {
        tapTab("You")
        let row = any("notificationsRow")
        XCTAssertTrue(row.appears(timeout: 10), "no Notifications row under You")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
    }

    /// HomeSlice.premierBrandIDs by name; keep the two in step. On
    /// 2026-10-30 the owner took off Sweet July, The Renae Brand and RIPL
    /// EFEK and added Big Mouth Toothbrush; this list missed it, and the
    /// carousel's first twelve then held two rotating brands (2026-11-01).
    /// RIPL EFEK came back on 2026-11-02. On 2026-11-04 the owner cut it to
    /// seven and the carousel to those seven pages only.
    fileprivate var premierNames: [String] {
        ["Fear of God", "Fenty Beauty", "Cecred", "Sienna Naturals",
         "Telfar", "Curves by Sean Brown", "RIPL EFEK"]
    }

    fileprivate var visibleHero: XCUIElement {
        let heroes = app.buttons.matching(identifier: "heroBrand")
        let screen = app.windows.firstMatch.frame
        // UIKit's pager also exposes off-screen cards. Asking those for a hit
        // point can throw an accessibility error; locate the current page by
        // geometry before performing any gesture on it.
        return heroes.allElementsBoundByIndex.first {
            let frame = $0.frame
            return frame.width > 0 && frame.height > 0
                && screen.contains(CGPoint(x: frame.midX, y: frame.midY))
        } ?? heroes.firstMatch
    }

    fileprivate func heroLineup() -> [(brand: String, product: String)] {
        var pages: [(brand: String, product: String)] = []
        // HomeView's carousel: one page per premier brand, nothing else (2026-11-04).
        let count = premierNames.count
        for page in 0..<count {
            let hero = visibleHero
            XCTAssertTrue(hero.appears(timeout: 5), "missing carousel page \(page + 1)")
            pages.append((brand: hero.label, product: hero.value as? String ?? ""))
            if page < count - 1 { hero.swipeLeft() }
        }
        return pages
    }

    /// The badge is not hair-only: catalog/clean_badge.py runs the same EU ban
    /// list over face washes and body washes. Search an exact title, so the
    /// badged product ranks first, and look for the blue badge on it.
    fileprivate func assertBadged(_ title: String, snapshot: String) {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("\(title)\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
        XCTAssertTrue(any("cleanBadge").appears(timeout: 5),
                      "\(title) clears the clean standard and should carry the blue badge")
        snap(snapshot)
    }

    /// The first three product tiles in a row, by their spoken labels.
    fileprivate func tileLabels(_ row: XCUIElement) -> [String] {
        Array(row.buttons.matching(identifier: "productTile").allElementsBoundByIndex.prefix(3).map(\.label))
    }

    /// `visibleTiles()` once the page has stopped moving — a scroll or a pop
    /// can still be settling, and a tile read mid-glide reads at the wrong spot.
    fileprivate func settledTiles(timeout: TimeInterval = 8) -> [(String, CGFloat)] {
        var last = visibleTiles()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(400_000)
            let now = visibleTiles()
            if !now.isEmpty, now.map(\.0) == last.map(\.0),
               zip(now, last).allSatisfy({ abs($0.1 - $1.1) < 0.5 }) { return now }
            last = now
        }
        return last
    }

    /// The product tiles actually on screen, top to bottom, with where they sit.
    /// Lazy stacks keep off-screen tiles around too, and more of them appear as
    /// the run goes on — only what the shopper can see counts here.
    fileprivate func visibleTiles() -> [(String, CGFloat)] {
        let screen = app.windows.firstMatch.frame
        // One consistent snapshot per sample. Asking each tile separately for
        // its frame rebuilds the entire SwiftUI accessibility tree hundreds
        // of times and can stall the runner on a dense shopping feed.
        guard let root = try? app.snapshot() else {
            XCTFail("Could not read the visible product tiles")
            return []
        }
        var found: [(String, CGRect)] = []
        func visit(_ node: XCUIElementSnapshot) {
            if node.elementType == .button, node.identifier == "productTile",
               node.frame.height > 0, screen.intersects(node.frame) {
                found.append((node.label, node.frame))
            }
            for child in node.children { visit(child) }
        }
        visit(root)
        return found.sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }
            .map { ($0.0, $0.1.minY) }
    }

    // MARK: - Several brands in one sitting (owner, 2026-10-13)

    /// Relaunches with a cart already holding one item from each brand and
    /// saved details full of characters a URL must encode (UITestSeed).
    fileprivate func launchSeeded(_ brands: [String], extra: [String] = []) {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"] + extra +
                              ["-SEED_BUYER", "-SEED_CART", brands.joined(separator: ",")]
        app.launch()
        tapTab("Cart")
        let lines = app.descendants(matching: .any).matching(identifier: "cartLine")
        let seeded = NSPredicate { _, _ in lines.count == brands.count }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: seeded, object: nil)], timeout: 15), .completed,
                       "the cart wasn't seeded with \(brands.count) brands")
    }

    fileprivate func cartLineCount() -> Int { app.descendants(matching: .any).matching(identifier: "cartLine").count }

    /// Checking out the whole bag: details are asked for once, then each
    /// brand is paid on its own checkout, one after another.
    /// Two products from different brands whose stores build a filled-in
    /// checkout (KOBA, Sienna Naturals). Generic words like "parfum" and
    /// "shea butter" land on whichever brand ranks first that day, and a
    /// brand that can't build one doesn't ask for the details (2026-10-10).
    static let checkoutTerms = ["touch me hand cream", "detangle it"]

    /// Saves a screenshot to TEST_RUNNER_MARRACAT_SHOT_DIR when set (review only).
    /// `settle`: seconds to let images load first, spent only when a
    /// screenshot is being taken (a fixed sleep before every snap cost each
    /// ship run its seconds for nothing, 2026-10-18).
    fileprivate func snap(_ name: String, settle: UInt32 = 0) {
        guard let dir = ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] else { return }
        sleep(settle)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

/// One of three shares of the UI tests, balanced by run time, so the ship
/// runs them on three simulators at once (scripts/ship.sh; owner, 2026-10-17).
final class MarracatUITests: MarracatUITestCase {
    /// The header search field is sized by hand (the bar's principal slot
    /// doesn't stretch). Sized to the screen instead of the window, it ran off
    /// the right edge of an iPad window; it must sit inside the window on the
    /// root and on a pushed screen, whatever the device.
    func testSearchFieldFitsWindow() {
        let window = app.windows.firstMatch.frame
        func check(_ where_: String) {
            let field = app.storeSearchField()
            XCTAssertTrue(field.appears(timeout: 5))
            XCTAssertGreaterThanOrEqual(field.frame.minX, window.minX, "search field starts off-window on \(where_)")
            XCTAssertLessThanOrEqual(field.frame.maxX, window.maxX, "search field runs past the window on \(where_)")
        }
        check("Home")
        app.buttons["Bags"].firstMatch.tap()
        check("a pushed screen")
    }

    /// The WooCommerce path: Ten To One runs Woo, not Shopify, so its product
    /// page offers one button and it opens the product on the brand's own
    /// site — a Woo store can't be handed a filled cart, and deep-linking its
    /// checkout dropped the shopper into a JavaScript-rendered form behind an
    /// age gate. Opt in the same way as the Shopify one.
    func testRealWooCheckoutLoads() throws {
        guard ProcessInfo.processInfo.environment["REAL_CHECKOUT"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_REAL_CHECKOUT=1 to open a real checkout")
        }
        app.terminate()
        let real = XCUIApplication()
        real.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH"]
        real.launch()
        let field = real.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = real.descendants(matching: .any).matching(identifier: "searchInput").firstMatch
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("ten to one rum\n")
        let result = real.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
        // A Woo brand shows no Add to Cart — one product at a time is all its
        // storefront can be sent.
        XCTAssertFalse(real.buttons["addToCart"].exists, "a Woo brand shouldn't offer Add to Cart")
        let buy = real.descendants(matching: .any).matching(identifier: "buyNow").firstMatch
        XCTAssertTrue(buy.appears(timeout: 5))
        buy.tap()
        XCTAssertTrue(real.webViews.firstMatch.appears(timeout: 20),
                      "the brand's product page never loaded")
        snap("realWooCheckout", settle: 8)
    }

    /// The splash is the day's first open only (owner, 2026-10-02): a second
    /// cold launch the same day opens on a skeleton of Home that fades into it.
    func testSplashShowsOncePerDay() {
        app.terminate()
        let first = XCUIApplication()
        // Held, as in testColdLaunchShowsSplash: launch() returns after the
        // app goes idle, which a loaded test machine can make after the splash.
        first.launchArguments = ["-UITEST_RESET", "-OFFLINE_CATALOG", "-SPLASH_SECONDS", "6"]
        first.launch()
        XCTAssertTrue(first.descendants(matching: .any).matching(identifier: "splash").firstMatch.appears(timeout: 3),
                      "the day's first launch should show the splash")
        XCTAssertTrue(first.homeReady().appears(timeout: 10))
        first.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-OFFLINE_CATALOG"]   // no reset: same day, same install
        again.launch()
        XCTAssertFalse(again.descendants(matching: .any).matching(identifier: "splash").firstMatch.appears(timeout: 2),
                       "a second cold launch the same day replayed the splash")
        XCTAssertTrue(again.appReady().appears(timeout: 10))
        XCTAssertFalse(again.descendants(matching: .any).matching(identifier: "launchSkeleton").firstMatch.exists,
                       "the skeleton should fade once Home is ready")
        // Back from the background the same day: no splash either. (The day
        // is now marked when the app is on screen, not when iOS starts the
        // process early, which had spent the morning's splash unseen.)
        XCUIDevice.shared.press(.home)
        sleep(2)
        again.activate()
        XCTAssertFalse(again.descendants(matching: .any).matching(identifier: "splash").firstMatch.appears(timeout: 2),
                       "a resume the same day replayed the splash")
        again.terminate()
    }

    /// Back from the background on a new day, the app opens on the splash,
    /// not on Home with the splash arriving after (owner, 2026-10-20).
    /// -UITEST_NEW_DAY_ON_BACKGROUND forgets the day's splash as the app
    /// leaves, as midnight passing would.
    func testANewDayResumeOpensOnTheSplash() {
        app.terminate()
        let a = XCUIApplication()
        a.launchArguments = ["-UITEST_RESET", "-OFFLINE_CATALOG", "-SPLASH_SECONDS", "6", "-UITEST_NEW_DAY_ON_BACKGROUND"]
        a.launch()
        let splash = a.descendants(matching: .any).matching(identifier: "splash").firstMatch
        let search = a.homeReady()
        // Held 6 s, as in testSplashShowsOncePerDay: activate() returns after
        // the app goes idle, which can be after a short splash.
        XCTAssertTrue(splash.disappears(timeout: 15))
        XCTAssertTrue(search.appears(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(2)
        a.activate()
        XCTAssertTrue(splash.appears(timeout: 3), "a new day's first open should show the splash")
        XCTAssertTrue(splash.disappears(timeout: 15))
        XCTAssertTrue(search.appears(timeout: 5), "Home should follow the splash")
        a.terminate()
    }

    /// The published catalog is fetched on one launch and used on the next —
    /// swapping it into a running session would reshuffle the page underneath
    /// the shopper. EXPECT_BRANDS asserts the count it ends up with.
    func testPublishedCatalogLoads() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        sleep(8)            // let this launch fetch and cache it
        app.terminate()
        app.launchArguments = ["-SKIP_SPLASH"]   // keep the cache; no reset
        app.launch()
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        let about = app.buttons["About Marracat"].firstMatch
        XCTAssertTrue(about.appears(timeout: 5), "Browse has no About link")
        about.tap()
        let brands = any("aboutBrands")
        XCTAssertTrue(brands.appears(timeout: 10), "About never showed the catalog summary")
        // The row reads "Brands, 230" — the number is in the label, not the value.
        XCTAssertGreaterThan(Int(brands.label.filter(\.isNumber)) ?? 0, 100,
                             "catalog looks wrong: \(brands.label)")
        if let expected = ProcessInfo.processInfo.environment["EXPECT_BRANDS"].flatMap(Int.init) {
            XCTAssertEqual(Int(brands.label.filter(\.isNumber)), expected,
                           "the second launch didn't use the published catalog: \(brands.label)")
        }
        snap("aboutCatalog")
    }

    func testLiveActivitySwitchAndNoOwnerTestForShoppers() {
        openNotifications()
        let toggle = app.switches["liveActivitiesToggle"].firstMatch
        XCTAssertTrue(toggle.appears(timeout: 5), "no Live Activities switch")
        XCTAssertEqual(toggle.value as? String, "1", "on by default")
        // The switch itself sits at the row's trailing edge; the label doesn't toggle it.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let off = NSPredicate(format: "value == '0'")
        expectation(for: off, evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(any("liveActivityDemo").exists, "the owner's test must not show for shoppers")
        snap("notificationsShopper")
    }

    /// The delivery Live Activity itself, in the Dynamic Island: three orders
    /// started locally (-LIVE_ACTIVITY_PREVIEW, the owner's test's first
    /// step), the compact island's count, then the expanded island and its
    /// › button, which runs FlipDeliveryIntent in the app. SpringBoard is
    /// queried for text only the card has (the Home Screen behind shows the
    /// app's name). Simulators without a Dynamic Island skip it.
    func testDeliveryLiveActivityFlipsBetweenOrders() throws {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-LIVE_ACTIVITY_PREVIEW"]
        app.launch()
        XCTAssertTrue(any("productTile").appears(timeout: 15))
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let count = board.descendants(matching: .any).matching(NSPredicate(format: "label == '3 deliveries today' OR label == '3 today'")).firstMatch
        guard count.appears(timeout: 15) else {
            throw XCTSkip("no Dynamic Island on this simulator, or Live Activities are off")
        }
        snap("liveActivityCompact")
        // Long-press the island to expand it.
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.037)).press(forDuration: 1.2)
        let first = board.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Ripl Efek'")).firstMatch
        XCTAssertTrue(first.appears(timeout: 8), "the expanded island should show the first order")
        XCTAssertTrue(board.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 of 3'")).firstMatch.exists)
        // Brand and item on their own lines (owner, 2026-10-26), not "Ripl Efek · Laundry Detergent".
        XCTAssertTrue(board.staticTexts["Laundry Detergent"].firstMatch.exists, "the item should be its own line under the brand")
        snap("liveActivityExpanded")
        XCTAssertFalse(board.buttons["Previous order"].firstMatch.exists, "no ‹ on the first order (owner, 2026-10-26)")
        let next = board.buttons["Next order"].firstMatch
        XCTAssertTrue(next.appears(timeout: 5), "no › button")
        next.tap()
        let second = board.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'KOBA'")).firstMatch
        XCTAssertTrue(second.appears(timeout: 10), "› should show the second order")
        snap("liveActivityNext")
        let previous = board.buttons["Previous order"].firstMatch
        if previous.exists {
            previous.tap()
            XCTAssertTrue(first.appears(timeout: 10), "‹ should go back to the first order")
        }
    }

    /// Relaunches with the tracking stub's `arguments` and buys one product
    /// with Buy Now, as far as "Order placed".
    private func placeABuyNowOrder(_ arguments: [String]) {
        app.terminate()
        app.launchArguments += arguments
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("cacao nectar eau de parfum\n")
        // A Scent & Fire bottle: a brand with a UCP endpoint, so the order is
        // built over UCP and tracked. The first "parfum" result moved to a
        // cart-link brand when the meaning vectors were rebuilt (2026-10-05).
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no in-stock result")
        result.tap()
        let buy = any("buyNow")
        XCTAssertTrue(buy.appears(timeout: 5))
        for _ in 0..<3 where buy.frame.maxY > app.buttons["tab.home"].frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        buy.tap()
        // Straight to the store's checkout: no Marracat details form first
        // (owner, 2026-11-02); the store asks for the address.
        XCTAssertFalse(any("buyerForm").appears(timeout: 2), "Buy Now shouldn't ask for details")
        // Then straight to the store's checkout for that item, no review page.
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 10), "Buy Now should open the brand's checkout")
        any("stubCompleteOrder").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Order placed'")).firstMatch.appears(timeout: 5))
    }

    /// A second review screenshot with the page nudged up, so the actions'
    /// words clear the Buy it again bar; put back after. Nothing happens
    /// (no scroll, no time) unless screenshots are being taken.
    private func snapActions(_ name: String) {
        guard ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] != nil else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        from.press(forDuration: 0.1, thenDragTo: to)
        snap(name, settle: 1)
        to.press(forDuration: 0.1, thenDragTo: from)
    }

    /// Once it's delivered the actions are Track, Product and Store, still on
    /// one line; Late shipment has moved down under Help (owner, 2026-11-13).
    /// And Buy it again hides on the way down the page (owner, 2026-11-14).
    func testADeliveredOrderKeepsThreeRoundActionsOnOneLine() {
        placeABuyNowOrder(["-TRACKING_SHIPPED", "-TRACKING_DELIVERED"])
        tapTab("You")
        any("tileOrders").tap()
        XCTAssertTrue(any("orderRow").appears(timeout: 5))
        any("orderRow").tap()
        XCTAssertTrue(any("orderTracker").appears(timeout: 5))
        XCTAssertTrue(any("orderStatus").label.localizedCaseInsensitiveContains("delivered"), any("orderStatus").label)
        let actions = ["orderTrackPackage", "orderViewProduct", "orderViewStore"].map { any($0) }
        XCTAssertTrue(actions.allSatisfy(\.exists), "a delivered order offers Track, Product and Store")
        for action in actions.dropFirst() {
            XCTAssertEqual(action.frame.midY, actions[0].frame.midY, accuracy: 2, "the actions share one line")
            XCTAssertEqual(action.frame.width, actions[0].frame.width, accuracy: 2, "each action takes an equal share")
        }
        XCTAssertFalse(any("orderEnableUpdates").exists, "nothing left to be notified about")
        let late = any("orderLateShipment")
        if late.exists { XCTAssertGreaterThan(late.frame.minY, actions[0].frame.maxY + 40, "Late shipment belongs under Help now") }
        snap("order-delivered")
        snapActions("order-delivered-actions")
        // Buy it again steps aside on the way down the page and is back after
        // a short scroll up (owner, 2026-11-14), like the Filters and Sort pill.
        let buyAgain = any("orderBuyAgain")
        XCTAssertTrue(buyAgain.appears(timeout: 3), "Buy it again shows at the top of the page")
        app.swipeUp()
        XCTAssertTrue(buyAgain.disappears(timeout: 3), "Buy it again should step aside while scrolling down")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        XCTAssertTrue(buyAgain.appears(timeout: 3), "a short scroll up should bring Buy it again back")
        snap("order-buy-again-back")
    }

    /// Buy Now builds the store's checkout over UCP and opens it directly
    /// (owner, 2026-10-05; through a review page from 10-01), so the paid
    /// checkout is tracked whatever email the wallet gives the brand. The stub
    /// stands in for the server reporting the brand shipped it.
    /// A "Delivery problem" (owner, 2026-10-21): the order opens with the
    /// explanation already open, the carrier's own words in it, and Track
    /// package right under it.
    func testADeliveryProblemOpensWithItsExplanation() {
        placeABuyNowOrder(["-TRACKING_SHIPPED", "-TRACKING_PROBLEM"])
        tapTab("You")
        any("tileOrders").tap()
        XCTAssertTrue(any("orderRow").appears(timeout: 5))
        any("orderRow").tap()
        let panel = any("deliveryProblem")
        XCTAssertTrue(panel.appears(timeout: 5), "the problem should be explained on the order")
        let said = any("deliveryProblemCarrier")
        XCTAssertTrue(said.exists, "it should already be open, with the carrier's words")
        XCTAssertTrue(said.label.contains("no access to delivery location"), said.label)
        let track = any("orderTrackPackage")
        XCTAssertTrue(track.exists)
        XCTAssertLessThan(panel.frame.minY, track.frame.minY, "the explanation sits above Track package")
    }

    func testBuyNowOrderIsTrackedWithoutTheOrderEmail() {
        placeABuyNowOrder(["-TRACKING_SHIPPED"])
        tapTab("You")
        any("tileOrders").tap()
        XCTAssertTrue(any("orderRow").appears(timeout: 5))
        // The bar searches your orders on this screen, not the store (owner, 2026-10-02).
        let orderSearch = app.textFields["ordersSearch"]
        XCTAssertTrue(orderSearch.exists, "the bar should be the orders search")
        XCTAssertEqual(orderSearch.placeholderValue, "Search orders")
        XCTAssertFalse(any("searchField").exists, "no store-wide search on Your Orders")
        orderSearch.tap()
        orderSearch.typeText("zzzz-no-such-order")
        XCTAssertTrue(any("orderRow").disappears(timeout: 5), "a search with no match hides every order")
        app.buttons["Clear search"].tap()
        XCTAssertTrue(any("orderRow").appears(timeout: 5))
        any("orderRow").tap()
        XCTAssertTrue(any("orderTracker").appears(timeout: 5))
        XCTAssertTrue(any("orderStatus").label.localizedCaseInsensitiveContains("shipped"), any("orderStatus").label)
        XCTAssertTrue(any("orderTracking").exists, "the tracking number should show")
        XCTAssertTrue(any("orderTrackPackage").exists, "Track package should open the brand's status page")
        // Manage your order leads Help: the brand's page for this order (owner, 2026-11-19).
        let manage = any("orderManage")
        XCTAssertTrue(manage.exists, "Order details should offer Manage your order")
        XCTAssertTrue(manage.label.contains("Manage your order"), manage.label)
        // The big photo opens the product too (owner, 2026-11-19).
        let photo = any("orderHeroProduct")
        XCTAssertTrue(photo.exists, "the order's photo should open the product")
        XCTAssertTrue(photo.label.hasPrefix("View "), photo.label)
        // The actions are round buttons on one line (owner, 2026-11-13), not
        // pills that wrap; VoiceOver still hears each one's full name.
        let actions = ["orderTrackPackage", "orderViewProduct", "orderViewStore", "orderLateShipment"].map { any($0) }
        XCTAssertTrue(actions.allSatisfy(\.exists), "an order on its way offers Track, Product, Store and Late")
        for action in actions.dropFirst() {
            XCTAssertEqual(action.frame.midY, actions[0].frame.midY, accuracy: 2, "the actions share one line")
            XCTAssertEqual(action.frame.width, actions[0].frame.width, accuracy: 2, "each action takes an equal share")
        }
        XCTAssertEqual(actions[0].label, "Track package")
        XCTAssertEqual(actions[3].label, "Late shipment")
        snap("order-tracked")
        snapActions("order-tracked-actions")
        // "Late shipment" reports the brand; a second tap takes it back (owner, 2026-10-01).
        let late = any("orderLateShipment")
        XCTAssertTrue(late.appears(timeout: 5), "every order should offer Late shipment")
        XCTAssertEqual(late.value as? String, "Not reported")
        late.tap()
        XCTAssertTrue(any("orderLateShipmentNote").appears(timeout: 5))
        XCTAssertEqual(late.value as? String, "Reported")
        snap("order-late-reported")
        late.tap()
        XCTAssertTrue(any("orderLateShipmentNote").disappears(timeout: 5))
        XCTAssertEqual(late.value as? String, "Not reported")
        // A finger on the photo itself lands on the product page (owner,
        // 2026-11-20: the link was there in build 194 and the tap did nothing).
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(any("buyNow").appears(timeout: 5), "tapping the order's photo should open the product")
    }

    /// A brand's store narrows to Marracat Clean like every other list. Since
    /// the Filters pill by the thumb (owner, 2026-11-10) the switch is in
    /// Filters › Offers, not a toggle on the page.
    func testBrandStoreFiltersToMarracatClean() {
        // Reach KOBA's store through search and its product page. Home's brand
        // circles reorder with the mix, so KOBA's circle was often off screen
        // and the test failed for reasons unrelated to the toggle.
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("KOBA skincare\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no KOBA results")
        result.tap()
        // The store card (owner, 2026-11-01): VoiceOver still hears the old words.
        let store = any("visitStore")
        XCTAssertTrue(store.appears(timeout: 5), "product page has no link to the KOBA store")
        XCTAssertEqual(store.label, "Visit the KOBA skincare Store")
        store.tap()
        XCTAssertTrue(any("filtersButton").appears(timeout: 5))
        XCTAssertTrue(any("sortButton").exists)
        XCTAssertFalse(any("cleanToggle").exists, "the page carries only Filters and Sort")
        let count = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' items'")).firstMatch
        XCTAssertTrue(count.appears(timeout: 3))
        let before = count.label
        any("filtersButton").tap()
        // Badges have their own group since 2026-11-11 (they were in Offers).
        let badges = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Badges'")).firstMatch
        XCTAssertTrue(badges.appears(timeout: 5), "no Badges group in the brand's filters")
        badges.tap()
        let clean = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'Marracat Clean'")).firstMatch
        XCTAssertTrue(clean.appears(timeout: 5), "Badges has no Marracat Clean")
        clean.tap()
        any("filtersApply").tap()
        XCTAssertTrue(any("filterSheet").disappears(timeout: 5))
        XCTAssertTrue(count.appears(timeout: 3))
        XCTAssertNotEqual(count.label, before, "turning Clean on should narrow the brand's items")
        // A tile says which badges its product carries, on a tab hanging from
        // the photo's top right corner (owner, 2026-11-20, picked from five
        // previews; the grid showed no badge before).
        let tab = any("badgeCornerTab")
        XCTAssertTrue(tab.appears(timeout: 5), "a Clean product's tile should show its badge")
        XCTAssertEqual(any("cleanBadge").label, "Marracat Clean ingredients")
        let tiles = any("masonryGrid").descendants(matching: .any).matching(identifier: "productTile").allElementsBoundByIndex.map(\.frame)
        XCTAssertTrue(tiles.contains { abs($0.minY - tab.frame.minY) < 2 && tab.frame.minX > $0.midX && tab.frame.maxX < $0.maxX },
                      "the tab hangs from a photo's top right corner: \(tab.frame) in \(tiles)")
        snap("grid-badge-tab")
    }

    /// A brand that sells hair care and skincare (owner, 2026-11-22: "can we
    /// get a filter for products that are good for eczema ... skin sensitivity
    /// filters for skin products, hair texture or sensitivities for hair
    /// products"): its Filters sheet offers Hair type and Skin concern without
    /// picking a Category first, and a skin concern narrows the store.
    func testABrandWithHairAndSkinOffersBothKindsOfFilter() {
        // The bundled catalog: what this build ships with, and no network.
        app.launchArguments += ["-OFFLINE_CATALOG"]
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 15))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("Adiva Naturals\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no Adiva Naturals results")
        result.tap()
        let store = any("visitStore")
        XCTAssertTrue(store.appears(timeout: 5), "product page has no link to the store")
        XCTAssertEqual(store.label, "Visit the Adiva Naturals Store")
        store.tap()
        XCTAssertTrue(any("filtersButton").appears(timeout: 5))
        let count = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' items'")).firstMatch
        XCTAssertTrue(count.appears(timeout: 3))
        let before = count.label
        any("filtersButton").tap()
        func group(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH %@", name)).firstMatch
        }
        XCTAssertTrue(group("Badges").appears(timeout: 5), "the sheet didn't open")
        let hair = group("Hair type"), skin = group("Skin concern")
        XCTAssertTrue(hair.exists, "a brand with hair products should offer Hair type")
        XCTAssertTrue(skin.exists, "a brand with skincare should offer Skin concern")
        XCTAssertFalse(group("Formulation").exists, "Formulation waits for a single department")
        // Hair & scalp concern (sensitive scalp, dandruff, breakage): shown
        // once the catalog carries it. Not required here, because a ship
        // bundles whatever catalog the refresh droplet last built.
        let scalp = group("Hair & scalp concern")
        if scalp.exists {
            scalp.tap()
            XCTAssertTrue(app.buttons.matching(identifier: "filterOption").firstMatch.appears(timeout: 5), "Hair & scalp concern has no options")
            snap("brand-hair-concern-filters", settle: 1)
        }
        skin.tap()
        let option = app.buttons.matching(identifier: "filterOption").firstMatch
        XCTAssertTrue(option.appears(timeout: 5), "Skin concern has no options")
        snap("brand-skin-concern-filters", settle: 1)
        option.tap()
        any("filtersApply").tap()
        XCTAssertTrue(any("filterSheet").disappears(timeout: 5))
        XCTAssertTrue(count.appears(timeout: 3))
        XCTAssertNotEqual(count.label, before, "a skin concern should narrow the brand's items")
    }

    func testHomeTabScrollsHomeToTop() {
        let chips = any("homeChips")
        XCTAssertTrue(chips.appears(timeout: 10))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(waitUntil(timeout: 3) { !chips.isHittable }, "setup: home should have scrolled past the chips")
        tapTab("Home")
        XCTAssertTrue(waitUntil(timeout: 3) { chips.isHittable }, "tapping Home on Home should scroll back to the top")
    }

    func testPremierBrandsLeadHome() {
        let circles = app.descendants(matching: .any).matching(identifier: "brandCircle")
        XCTAssertTrue(circles.firstMatch.appears(timeout: 10))
        // The order is shuffled every refresh, so only who leads is fixed. The
        // row only builds circles near the screen, and ten premier brands run
        // past it, so scroll and collect them in order.
        var seen: [String] = []
        for _ in 0..<4 {
            for label in circles.allElementsBoundByIndex.map(\.label) where !seen.contains(label) { seen.append(label) }
            if seen.count >= premierNames.count { break }
            circles.allElementsBoundByIndex.first(where: \.isHittable)?.swipeLeft()
        }
        // Whatever loaded leads with premier brands only (all ten shown is
        // what testPullToRefreshSwapsHomeBrands checks on the carousel); the
        // row's scroll is unreliable off screen in a full-suite run.
        let lead = Array(seen.prefix(premierNames.count))
        // XCUITest reads about nine circles however far it swipes (2026-10-10,
        // with twelve premier brands), so ask for eight; that all twelve show
        // is testPullToRefreshSwapsHomeBrands' job, on the carousel.
        XCTAssertGreaterThanOrEqual(lead.count, min(premierNames.count - 1, 8), "the row should show the premier brands")
        XCTAssertTrue(Set(lead).isSubset(of: Set(premierNames)), "the owner's premier brands should lead Home: \(lead)")
    }

    func testPullToRefreshSwapsHomeBrands() {
        let before = heroLineup()
        let premierCount = premierNames.count
        XCTAssertEqual(Set(before.prefix(premierCount).map(\.brand)), Set(premierNames))
        XCTAssertEqual(before.count, premierNames.count, "the carousel should be the premier brands only")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 450)))
        // The carousel was on its last page; a refresh sends it back to page
        // one, which is a premier brand like every page.
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.premierNames.contains(self.visibleHero.label)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 6), .completed,
                       "refresh should start at a premier brand")
        let after = heroLineup()
        XCTAssertEqual(Set(after.prefix(premierCount).map(\.brand)), Set(premierNames),
                       "refresh changed which brands are premier")
        // Each premier brand moves one product along its catalog per refresh.
        let productBefore = Dictionary(uniqueKeysWithValues: before.prefix(premierCount).map { ($0.brand, $0.product) })
        for item in after.prefix(premierCount) {
            XCTAssertNotEqual(item.product, productBefore[item.brand],
                              "\(item.brand) should show a different product after a refresh")
        }
    }

    func testMarracatCleanCoversBodyWashes() {
        assertBadged("activated charcoal organic body wash", snapshot: "clean-body-wash")
    }

    func testFiltersNarrowResultsAndTheChipUndoesIt() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("durag\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        let before = Int(header.label.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(before, 5, "durag should return a real result set to narrow")

        any("filtersButton").tap()
        XCTAssertTrue(any("filterSheet").appears(timeout: 10))
        // Colour is read off variant titles, so it only appears when the
        // results actually carry colours.
        let groups = app.descendants(matching: .any).matching(identifier: "filterGroup")
        XCTAssertTrue(groups.element(boundBy: 0).appears(timeout: 5))
        var opened = false
        for i in 0..<groups.count where groups.element(boundBy: i).label.contains("Colour") {
            groups.element(boundBy: i).tap()
            opened = true
            break
        }
        XCTAssertTrue(opened, "durags come in colours, so the sheet should offer a Colour group")

        let chips = app.descendants(matching: .any).matching(identifier: "filterOption")
        XCTAssertTrue(chips.element(boundBy: 0).appears(timeout: 5))
        chips.element(boundBy: 0).tap()
        let apply = any("filtersApply")
        // The button counts what is left before the shopper commits to it.
        XCTAssertTrue(apply.label.contains("Show"), "apply button should count the results")
        snap("filters-sheet")
        apply.tap()

        XCTAssertTrue(header.appears(timeout: 10))
        let after = Int(header.label.filter(\.isNumber)) ?? 0
        XCTAssertLessThan(after, before, "picking a colour should narrow the results")
        XCTAssertGreaterThan(after, 0, "the chosen colour should still have items")

        let chip = any("activeFilterChip")
        XCTAssertTrue(chip.appears(timeout: 5), "the choice should show as a chip above the results")
        snap("filters-narrowed")
        chip.tap()
        XCTAssertTrue(header.appears(timeout: 10))
        XCTAssertEqual(Int(header.label.filter(\.isNumber)), before,
                       "removing the chip should put every result back")
    }

    /// Sponsored products are labeled where they show: the top of a search
    /// and a row on product pages (stubbed: the server picks them for real).
    func testSponsoredProductsAreLabeled() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-SPONSORED_STUB", "scent-fire-6811766423619"]
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("body butter\n")
        XCTAssertTrue(any("sponsoredTag").appears(timeout: 10), "the sponsored result is labeled")
        snap("sponsored-search")
        any("resultTitle").tap()
        let row = any("sponsoredRow")
        for _ in 0..<6 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.appears(timeout: 5), "product pages carry a Sponsored products row")
    }

    /// A product with sizes carries no variants in the catalog; its page
    /// fetches them. Before that fetch was read, every such product said
    /// "Currently unavailable" with Add to Cart disabled.
    func testProductWithOptionsLoadsItsVariantsAndCanBeAdded() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("Girl With the Bamboo Earring Print\n")
        let result = app.buttons.matching(identifier: "resultTitle")
            .matching(NSPredicate(format: "label CONTAINS 'Bamboo Earring' AND label CONTAINS 'Print' AND label CONTAINS 'DomoINK'")).firstMatch
        XCTAssertTrue(result.appears(timeout: 10), "the DomoINK print (a product with sizes) should be found")
        result.tap()
        let status = any("stockStatus")
        XCTAssertTrue(status.appears(timeout: 5))
        let inStock = NSPredicate(format: "label == 'In Stock'")
        expectation(for: inStock, evaluatedWith: status)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(any("addToCart").isEnabled, "an in-stock product with options must be addable")
    }

    func testFloatingTabBarSwitchesAndPopsToRoot() {
        XCTAssertTrue(app.homeReady().appears(timeout: 10))
        // (Was testHomeShowsCatalog.) Home has products, and only our bar shows.
        XCTAssertTrue(any("productTile").appears(timeout: 10), "home has no products — catalog.json missing from the bundle?")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "system tab bar should be hidden behind the floating bar")

        tapTab("Saved")
        XCTAssertTrue(any("savedEmpty").appears(timeout: 5), "Saved tab didn't show its empty state")
        XCTAssertTrue(app.buttons["tab.saved"].isSelected)

        // The search icon: the first tap lands on Browse (no keyboard); a second
        // tap there opens search with the keyboard up; Back returns to Browse.
        tapTab("Browse")
        XCTAssertTrue(app.staticTexts["Shop by category"].appears(timeout: 5),
                      "the search icon should land on the Browse page first")
        XCTAssertFalse(any("searchInput").exists, "search shouldn't open on the first tap")
        snap("browse")
        tapTab("Browse")
        XCTAssertTrue(any("searchInput").appears(timeout: 5), "second tap didn't open search")
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5), "keyboard didn't come up")
        snap("searchFromTab", settle: 1)
        any("searchBack").tap()
        XCTAssertTrue(app.staticTexts["Shop by category"].appears(timeout: 5),
                      "back from search should land on the Browse page")
        XCTAssertTrue(any("searchInput").disappears(timeout: 3))

        // Scrolled to the bottom, the last row must clear the floating tab bar.
        for _ in 0..<4 { app.swipeUp() }
        sleep(1)
        let about = app.staticTexts["About Marracat"]
        XCTAssertTrue(about.appears(timeout: 3))
        // A wide window has the sidebar instead (AdaptiveLayout); nothing floats over the list then.
        if !any("sidebar").exists {
            let bar = app.buttons["tab.home"].frame
            XCTAssertLessThan(about.frame.maxY, bar.minY,
                              "“About Marracat” is hidden behind the tab bar at full scroll")
        }
        snap("browseBottom")

        // Push a product on Home, then tap Home again: it should pop to the root.
        tapTab("Home")
        let tile = any("productTile")
        XCTAssertTrue(tile.appears(timeout: 10))
        tile.tap()
        XCTAssertTrue(any("addToCart").appears(timeout: 5))
        tapTab("Home")
        XCTAssertTrue(any("addToCart").disappears(timeout: 5), "re-tapping Home didn't pop to root")
    }

    /// Opening a product and coming back must leave Home exactly as it was.
    /// The personalized rows read the shopper's history, and viewing a product
    /// writes to it — rebuilding them mid-browse reshuffles the page and the
    /// shopper loses their place.
    /// Owner, 2026-11-08: "lets refresh and do a new since your last visit".
    /// A return after a while opens Home on what the brands added since.
    /// 720 h (30 days, the New arrivals window) so a bundled catalog a few
    /// days old still has plenty after it.
    func testHomeShowsWhatsNewSinceTheLastVisit() {
        app.terminate()
        app.launchArguments += ["-LAST_VISIT_HOURS_AGO", "720"]
        app.launch()
        XCTAssertTrue(app.homeReady().appears(timeout: 15))
        let row = any("newSinceLastVisit")
        for _ in 0..<3 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.appears(timeout: 20), "the row should be on Home")
        XCTAssertTrue(app.staticTexts["New since your last visit"].exists)
        snap("home-new-since")
    }

    func testHomeKeepsItsPlaceAfterViewingAProduct() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("tote\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))
        tapTab("Home")
        XCTAssertTrue(app.staticTexts["Inspired by your search for “tote”"].appears(timeout: 5))

        // Down into the personalized rows.
        for _ in 0..<2 { app.swipeUp() }
        let before = settledTiles()
        XCTAssertGreaterThan(before.count, 2, "setup: expected product tiles on screen")

        // A tile that's already on screen — tapping an off-screen one would make
        // XCUITest scroll to it, moving the page this test is watching.
        let opened = before[before.count / 2].0
        let tile = app.buttons.matching(identifier: "productTile")
            .matching(NSPredicate(format: "label == %@", opened)).firstMatch
        tile.tap()
        XCTAssertTrue(app.buttons["addToCart"].appears(timeout: 10), "product \(opened) didn't open")
        // Swipe back from the edge, the way the shopper does: the content's
        // edge, right of the sidebar in a wide window.
        let sidebar = any("sidebar")
        let edge = sidebar.exists
            ? app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: sidebar.frame.maxX + 4, dy: app.windows.firstMatch.frame.midY))
            : app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(app.buttons["addToCart"].disappears(timeout: 5), "didn't land back on Home")

        let after = settledTiles()
        XCTAssertEqual(before.map(\.0), after.map(\.0), "Home reshuffled while the shopper was on a product")
        for (b, a) in zip(before, after) {
            XCTAssertEqual(b.1, a.1, accuracy: 2, "\(b.0) moved — Home lost the shopper's scroll position")
        }

        // Re-tapping Home must only scroll. Rebuilding from the history written
        // above would insert a new "Keep shopping for" row into this feed.
        XCTAssertFalse(app.staticTexts["Keep shopping for"].exists)
        tapTab("Home")
        let atTop = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"),
                                              object: any("homeChips"))
        XCTAssertEqual(XCTWaiter.wait(for: [atTop], timeout: 3), .completed,
                       "Home didn't return to the top after the animation")
        XCTAssertFalse(app.staticTexts["Keep shopping for"].exists,
                       "re-tapping Home refreshed the feed from recently viewed products")
    }

    /// The floating bar is aligned to the bottom of the TabView, so anything
    /// that shrinks the TabView — the keyboard, above all — moves the bar up
    /// over the content. This walks every exit from the keyboard and watches
    /// where the bar lands, sampling through the animation rather than after it.
    func testTabBarStaysAtTheBottomOnEveryExitFromSearch() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.appears(timeout: 5))
        let resting = home.frame.midY
        var drift: [String] = []

        /// Samples the bar right away and keeps sampling for a second — the
        /// complaint is a bar that appears in the wrong place, not one that
        /// stays there.
        func check(_ label: String) {
            var highest = resting
            for _ in 0..<12 {
                let y = home.frame.midY
                if y < highest { highest = y }   // the bar sliding DOWN is the deliberate hide
                usleep(80_000)
            }
            if highest < resting - 4 { drift.append("\(label): bar rose to \(highest), resting \(resting)") }
        }
        func openSearch() {
            app.storeSearchField().tap()
            XCTAssertTrue(any("searchInput").appears(timeout: 5))
            XCTAssertTrue(app.keyboards.element.appears(timeout: 5),
                          "no software keyboard — this test can't see keyboard-driven layout")
        }

        // A — submit a search, then swipe back from the results.
        openSearch()
        any("searchInput").typeText("shea\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))
        check("on results")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        check("after swiping back from results")

        // B — open search and leave by the back chevron.
        openSearch()
        any("searchInput").typeText("bag")
        any("searchBack").tap()
        check("after closing search with the chevron")

        // C — open search and leave by tapping a suggestion.
        openSearch()
        any("searchInput").typeText("bag")
        let suggestion = app.buttons.matching(identifier: "suggestion").firstMatch
        if suggestion.appears(timeout: 5) {
            suggestion.tap()
            check("after tapping a suggestion")
            tapTab("Home")
            check("back on Home from a suggestion")
        }
        if !drift.isEmpty { snap("tabBarDrift") }
        XCTAssertTrue(drift.isEmpty, drift.joined(separator: "; "))
    }

    func testTabBarStaysAtTheBottomAfterTypingASearch() throws {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        if any("sidebar").exists { throw XCTSkip("a wide window has the sidebar, not the floating bar") }
        let screen = app.windows.firstMatch.frame
        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.appears(timeout: 5))
        let resting = home.frame.midY
        XCTAssertGreaterThan(resting, screen.height * 0.8, "setup: the bar should start near the bottom")

        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("shea")
        app.buttons["Clear search"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()   // close the overlay
        XCTAssertTrue(input.disappears(timeout: 5), "search stayed open")
        waitUntil(timeout: 3) { abs(home.frame.midY - resting) < 4 }
        XCTAssertEqual(home.frame.midY, resting, accuracy: 4,
                       "the tab bar floated to \(home.frame.midY) on a \(screen.height)pt screen")
    }

    /// A thumb drag up the suggestion list scrolls it and drops the keyboard.
    /// The overlay's swipe-back gesture once sat on the whole overlay at high
    /// priority and swallowed every drag, so the list wouldn't move.
    func testSearchSuggestionsScrollAndDropKeyboard() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("brush")
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))
        let rows = app.buttons.matching(identifier: "suggestion")
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(app.keyboards.firstMatch.disappears(timeout: 3), "scrolling the suggestions should drop the keyboard")
        XCTAssertTrue(input.exists, "scrolling shouldn't close search")
        // The rows the keyboard was covering can now be reached.
        let last = rows.element(boundBy: rows.count - 1)
        for _ in 0..<3 where !last.isHittable { app.swipeUp() }
        XCTAssertTrue(last.isHittable, "the last suggestion can't be reached")
    }

    /// A swipe moves the banner by hand, back as well as on (the timer only
    /// ever goes on), and doesn't open anything. A fresh launch opens on the
    /// first brand, which a paging scroll can't go back from: swipe on, then back.
    func testFeaturedBannerSwipesByHand() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let banner = any("featuredBanner")
        XCTAssertTrue(banner.appears(timeout: 5))
        func position() -> (Int, Int) {
            let n = (banner.value as? String ?? "").split(separator: " ").compactMap { Int($0) }
            return n.count == 2 ? (n[0], n[1]) : (0, 0)
        }
        func waitFor(_ at: Int, _ why: String) {
            let there = NSPredicate { _, _ in position().0 == at }
            XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: there, evaluatedWith: banner)], timeout: 3), .completed,
                           "\(why): at \(position().0), wanted \(at)")
        }
        let (at, count) = position()
        XCTAssertGreaterThan(count, 2, "need three featured brands to tell a swipe from the timer: \(banner.value ?? "nil")")
        banner.swipeLeft()
        waitFor(at % count + 1, "a left swipe should move on one brand")
        banner.swipeRight()
        waitFor(at, "a right swipe should come back")
        XCTAssertTrue(any("searchInput").exists, "a swipe opened something")
        XCTAssertFalse(any("brandWebsite").exists, "a swipe opened a brand store")
    }

    /// An order placed with a brand that has since left the catalog still
    /// lists, under a generic "Brand", and opens. (It used The Butter Bar
    /// Skincare, removed 10/12; the owner restored it on 10/14, so the brand
    /// here is one the catalog has never had.)
    func testAnOrderFromARemovedBrandStillShows() throws {
        struct Item: Encodable { let title: String; let quantity: Int }
        struct Record: Encodable {
            let id = UUID(), brandID = "a-brand-no-longer-listed", date = Date(timeIntervalSinceNow: -7 * 86_400)
            let itemCount = 1, subtotal = 14.0, productIDs = ["a-brand-no-longer-listed-gone"]
            let items = [Item(title: "Promised Land Juicy Soap Bar", quantity: 1)]
        }
        let data = try JSONEncoder().encode([Record()])
        // The argument domain takes a plist value: <hex> is Data, which is
        // what the guest history is read from on a fresh install.
        let hex = "<" + data.map { String(format: "%02x", $0) }.joined() + ">"
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-shopper.checkouts", hex]
        app.launch()
        tapTab("You")
        let tile = any("tileOrders")
        XCTAssertTrue(tile.appears(timeout: 10))
        tile.tap()
        let row = any("orderRow")
        XCTAssertTrue(row.appears(timeout: 5), "the removed brand's order vanished")
        let soap = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Promised Land Juicy Soap Bar")).firstMatch
        XCTAssertTrue(soap.exists, "the order lost its item")
        let generic = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Brand' OR label ENDSWITH ', Brand'")).firstMatch
        XCTAssertTrue(generic.exists, "no generic brand name on the order")
        row.tap()
        let fallback = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "the brand")).firstMatch
        XCTAssertTrue(fallback.appears(timeout: 5), "the order's details didn't open for a brand that's gone")
    }

    /// Typing an ingredient or kind of thing that no brand uses as a product
    /// type ("shea butter") still suggests it, and opens every brand's version.
    func testTypingSuggestsKindsMinedFromTitles() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("shea")
        let shea = app.buttons.matching(NSPredicate(format: "label ==[c] 'shea butter'")).firstMatch
        // The kinds are mined from titles in the background after launch; a
        // loaded machine running the whole suite took over 5 s (2026-10-11).
        XCTAssertTrue(shea.appears(timeout: 15), "no 'shea butter' suggestion for 'shea'")
        snap("kindSuggestions")
        shea.tap()
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 5))
        XCTAssertFalse(header.label.hasPrefix("0 results"), header.label)
        let brands = Set(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'by '"))
            .allElementsBoundByIndex.map(\.label))
        XCTAssertGreaterThan(brands.count, 1, "shea butter should show more than one brand: \(brands)")
    }

    /// No brand gets row after row: a search one brand could flood ("shea
    /// butter", where a few brands sell dozens) comes back mixed.
    func testSearchResultsMixBrands() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("shea butter\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))
        let byLines = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'by '"))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.label)
        XCTAssertGreaterThan(byLines.count, 2, "too few results to judge the mix")
        snap("searchResultsMixed")
        for (a, b) in zip(byLines, byLines.dropFirst()) {
            XCTAssertNotEqual(a, b, "the same brand twice in a row: \(byLines)")
        }
    }

    /// Pinch to zoom the product photo where it sits: the fabric is the reason
    /// to buy. Double-tap toggles it, and at life size a swipe still pages the
    /// gallery rather than dragging the picture.
    func testPinchToZoomTheProductPhoto() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("corset\n")
        let result = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()

        let photo = any("productImage")
        XCTAssertTrue(photo.appears(timeout: 10))
        XCTAssertEqual(photo.value as? String, "zoom 100", "the photo should start at life size")

        photo.pinch(withScale: 2.2, velocity: 2)
        waitUntil(timeout: 3) { (Int((photo.value as? String ?? "").filter(\.isNumber)) ?? 0) > 130 }
        let zoomed = Int((photo.value as? String ?? "").filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(zoomed, 130, "pinching didn't zoom the photo (value \(zoomed))")
        snap("zoomedPhoto")

        photo.doubleTap()
        waitUntil(timeout: 3) { photo.value as? String == "zoom 100" }
        XCTAssertEqual(photo.value as? String, "zoom 100", "double-tap should return the photo to life size")

        // Back at life size the gallery still pages.
        XCTAssertTrue(any("addToCart").exists, "the page should still be usable after zooming")
    }

    /// In the gallery, a double-tap zooms in and a second zooms out; a hard
    /// swipe down sends the gallery away to the product page (owner, 2026-10-10).
    func testGalleryDoubleTapZoomsAndSwipeDownCloses() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("corset\n")
        let result = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
        let photo = any("productImage")
        XCTAssertTrue(photo.appears(timeout: 10))
        photo.tap()
        XCTAssertTrue(any("productGallery").appears(timeout: 5), "the gallery didn't open")

        let first = app.descendants(matching: .any).matching(identifier: "productImage").firstMatch
        XCTAssertEqual(first.value as? String, "zoom 100")
        first.doubleTap()
        waitUntil(timeout: 3) { (Int((first.value as? String ?? "").filter(\.isNumber)) ?? 0) > 150 }
        let zoomed = Int((first.value as? String ?? "").filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(zoomed, 150, "double-tap should zoom in (value \(zoomed))")
        first.doubleTap()
        waitUntil(timeout: 3) { first.value as? String == "zoom 100" }
        XCTAssertEqual(first.value as? String, "zoom 100", "a second double-tap should zoom back out")

        first.swipeDown(velocity: .fast)
        XCTAssertTrue(any("productGallery").disappears(timeout: 5), "a hard swipe down should close the gallery")
        XCTAssertTrue(any("addToCart").appears(timeout: 5), "the product page should be back")
    }

    /// Signed out (the simulator always is), a cart link still goes out with
    /// the Marracat order email (-RELAY_STUB stands in for the guest address
    /// the server hands this install), exactly as a signed-in shopper's does.
    func testGuestCartLinkCarriesTheOrderEmail() {
        launchSeeded(["black-butterfly-bath-and-body", "noir-lux-candle-co"], extra: ["-RELAY_STUB"])
        let checkout = any("cartCheckout")
        XCTAssertTrue(checkout.appears(timeout: 15), "no Checkout in the bag")
        checkout.tap()
        XCTAssertTrue(any("checkoutPrefill").appears(timeout: 5))
        let label = any("checkoutPrefill").label
        XCTAssertTrue(label.contains("O'Brien"), label)
        XCTAssertTrue(label.hasSuffix("· order email u-test2k7m9q@orders.marracat.com"), "the cart link lost the order email: \(label)")
    }

    /// No saved details: shipping waits for a ZIP typed in the bag (no
    /// pop-up), then quotes; the ZIP is kept for next time.
    func testTypedZIPQuotesShipping() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-SEED_CART", "octavia-morgan"]
        app.launch()
        tapTab("Cart")
        XCTAssertTrue(any("cartShipping").appears(timeout: 15))
        XCTAssertTrue(any("cartShipping").label.contains("Add a ZIP"), any("cartShipping").label)
        let zip = app.textFields["cartZIP"]
        XCTAssertTrue(zip.exists)
        zip.tap()
        zip.typeText("11201")
        let quoted = NSPredicate { _, _ in self.any("cartShipping").label.contains("5 dollars") }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: quoted, object: nil)], timeout: 10), .completed,
                       any("cartShipping").label)
        XCTAssertTrue(any("cartBrandShipping").label.hasPrefix("Standard shipping $5.00"), any("cartBrandShipping").label)
    }
}

/// One of three shares of the UI tests, balanced by run time, so the ship
/// runs them on three simulators at once (scripts/ship.sh; owner, 2026-10-17).
final class MarracatUITests2: MarracatUITestCase {
    func testGuestAccountControlsAndPrivacy() {
        app.buttons["tab.you"].tap()
        // The profile page: identity card, tiles, then the settings rows.
        // 15 s: the card missed a 5 s wait twice in a full suite at load average ~20 (2026-10-16).
        XCTAssertTrue(any("profileCard").appears(timeout: 15), "no profile card")
        XCTAssertTrue(any("tileOrders").exists && any("tileLists").exists)
        XCTAssertTrue(any("signInCard").exists, "a guest should be invited to sign in")
        snap("profile")
        app.buttons["accountSettings"].tap()
        XCTAssertTrue(app.buttons["googleSignIn"].appears(timeout: 5))
        XCTAssertTrue(app.buttons["appleSignIn"].exists, "Apple login must be offered alongside Google")
        XCTAssertFalse(app.buttons["deleteAccount"].exists)
        snap("google-account")
        let toggle = app.switches["personalizationToggle"]
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.exists)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        // Usage analytics is its own switch in the menu, on by default (owner, 2026-10-10).
        let usage = app.switches["analyticsToggle"]
        XCTAssertTrue(usage.exists, "no Share usage analytics switch")
        XCTAssertEqual(usage.value as? String, "1")
        let policy = app.buttons["privacyPolicy"]
        for _ in 0..<3 where !policy.isHittable { app.swipeUp() }
        policy.tap()
        XCTAssertTrue(app.staticTexts["Your data in Marracat"].appears(timeout: 5))
        // The social features (comments, profiles, friends, shares) must stay disclosed here.
        XCTAssertTrue(app.staticTexts["Comments, profiles and friends"].exists, "privacy sheet lost its social section")
        app.buttons["Done"].tap()
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.storeSearchField().exists)
    }

    /// Opt-in: loads the REAL Shopify checkout (opens one checkout session on a
    /// brand's store), so it only runs with TEST_RUNNER_REAL_CHECKOUT=1 — never in
    /// the ship gate. Use it to confirm Checkout Kit still loads permalinks.
    func testRealCheckoutSheetLoads() throws {
        guard ProcessInfo.processInfo.environment["REAL_CHECKOUT"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_REAL_CHECKOUT=1 to open a real checkout")
        }
        app.terminate()
        let real = XCUIApplication()
        real.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH"]   // no -CHECKOUT_STUB
        real.launch()
        let field = real.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = real.descendants(matching: .any).matching(identifier: "searchInput").firstMatch
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("parfum\n")
        let result = real.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
        let buy = real.descendants(matching: .any).matching(identifier: "buyNow").firstMatch
        XCTAssertTrue(buy.appears(timeout: 5))
        buy.tap()
        // Buy Now opens the store's own checkout for this item, built over
        // UCP; with nothing saved, the store asks for the address (owner,
        // 2026-11-02: no Marracat form first).
        XCTAssertTrue(real.webViews.firstMatch.appears(timeout: 20), "the store's checkout never loaded")
        snap("realCheckout", settle: 8)   // let the store's checkout render for the screenshot
    }

    func testDefaultSplashRevealsAnInteractiveStorefront() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-OFFLINE_CATALOG", "-CHECKOUT_STUB"]
        app.launch()
        let splash = any("splash")
        // Eight seconds, not five: the splash covers decoding a catalog that
        // carries every product every brand sells, which is 101,000 of them.
        XCTAssertTrue(splash.disappears(timeout: 8), "the normal launch got stuck on the splash")
        XCTAssertTrue(any("productTile").appears(timeout: 10), "Home never populated after launch")
        tapTab("Browse")
        XCTAssertTrue(app.buttons["About Marracat"].firstMatch.appears(timeout: 5),
                      "the splash still intercepts touches after it disappears")
    }

    /// Restock alerts are for signed-in shoppers (owner, 2026-10-02): signed
    /// out, a sold-out product asks you to sign in and the button opens the
    /// sign-in screen, with Apple's and Google's buttons the same size.
    func testRestockAlertNeedsSignIn() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-RESTOCK_STUB"]
        app.launch()
        openSoldOutItem()
        let signIn = app.buttons["notifyRestockSignIn"].firstMatch
        XCTAssertTrue(signIn.appears(timeout: 10), "signed out should be asked to sign in")
        XCTAssertFalse(app.buttons["notifyRestock"].exists)
        signIn.tap()
        let apple = any("appleSignIn"), google = any("googleSignIn")
        XCTAssertTrue(apple.appears(timeout: 5))
        XCTAssertTrue(google.exists)
        XCTAssertEqual(apple.frame.width, google.frame.width, accuracy: 1, "sign-in buttons should be the same width")
        XCTAssertEqual(apple.frame.height, google.frame.height, accuracy: 1, "sign-in buttons should be the same height")
        XCTAssertEqual(apple.frame.minX, google.frame.minX, accuracy: 1, "sign-in buttons should line up")
        snap("signInButtons")
    }

    func testOwnerSeesTheLiveActivityTest() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-LIVE_ACTIVITY_OWNER"]
        app.launch()
        openNotifications()
        let demo = any("liveActivityDemo")
        XCTAssertTrue(demo.appears(timeout: 5), "the owner should see the Live Activity test")
        demo.tap()
        XCTAssertTrue(any("liveActivityDemoMessage").appears(timeout: 5))
        snap("notificationsOwner")
    }

    func testTappingEmptySpaceClosesSearch() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        XCTAssertTrue(app.staticTexts["Shop by category"].appears(timeout: 5))
        tapTab("Browse")   // second tap opens search with the keyboard
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5))

        // Empty space under the Featured banner, above the field on the
        // keyboard (no recents on a reset launch).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42)).tap()
        XCTAssertTrue(any("searchInput").disappears(timeout: 3), "tapping empty space didn't close search")
        XCTAssertTrue(app.keyboards.firstMatch.disappears(timeout: 3), "keyboard stayed up")
        XCTAssertTrue(app.staticTexts["Shop by category"].appears(timeout: 3),
                      "should be back on the Browse page")
    }

    func testBrandsListOpensFromBrowse() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        let brands = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Brands'")).firstMatch
        XCTAssertTrue(brands.appears(timeout: 5))
        brands.tap()
        // Any row will do: with 100+ brands a specific one (it used to be Telfar)
        // can sit below the fold, and List only builds the rows on screen.
        XCTAssertTrue(any("brandRow").appears(timeout: 5), "Brands list didn't open")
        snap("brands", settle: 3)
    }

    /// Swiping a cart item left removes it, as in Mail (owner, 2026-09-30).
    func testSwipeRemovesCartItem() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("candle\n")
        let add = app.buttons["Add to cart"].firstMatch
        XCTAssertTrue(add.appears(timeout: 5), "no in-stock candle")
        // The first candles can all need an option picked, which leaves the
        // first "Add to cart" under the tab bar (2026-11-20: the tap landed on
        // the Cart tab and nothing was added).
        tapClearOfTabBar(add)
        XCTAssertTrue(app.buttons["Added"].firstMatch.appears(timeout: 5), "the tap on Add to cart added nothing")
        tapTab("Cart")
        let line = any("cartLine")
        XCTAssertTrue(line.appears(timeout: 5), "the item isn't in the cart")
        // A vertical drag over the row is a scroll: nothing removed, nothing opened.
        line.swipeUp(velocity: .slow)
        XCTAssertTrue(line.appears(timeout: 2), "a vertical swipe removed the item")
        XCTAssertFalse(any("addToCart").exists, "a vertical swipe opened the product")
        // A short swipe leaves the row open on its red Remove button.
        let start = line.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)))
        XCTAssertFalse(any("addToCart").appears(timeout: 1), "the swipe opened the product")
        XCTAssertTrue(any("swipeRemove").appears(timeout: 2), "a short swipe should open Remove")
        snap("cart-swipe-open")
        any("swipeRemove").tap()
        XCTAssertTrue(line.disappears(timeout: 5), "swiping left didn't remove the item")
        XCTAssertTrue(app.staticTexts["Your Marracat Cart is empty"].appears(timeout: 5))
    }

    func testCertifiedOrganicItemsShowGreenBadge() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        // The brand, not "organic cotton": that phrase matches dozens of period
        // products whose cotton is organic but which carry no certification, and
        // which of them lands on the first screen shifts as the catalog grows.
        // Hope for Flowers is the GOTS-certified label; "shrunken shirt" is
        // one of its styles where every listing is certified (2026-10-17: the
        // brand alone stopped putting a certified item on the first screens).
        input.typeText("shrunken shirt\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
        let badge = any("organicBadge")
        for _ in 0..<4 where !badge.exists { app.swipeUp() }
        XCTAssertTrue(badge.exists,
                      "GOTS-certified items should carry the green organic badge")
        snap("organic")
    }

    func testMarracatCleanHairItemsShowBlueBadgeAndExplainIt() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        // An exact title, so the badged product ranks first: Pattern Beauty
        // publishes a full list with no fragrance token for this mask, and the
        // scanner (catalog/clean_badge.py) awards it the badge.
        input.typeText("breakage barrier hair mask\n")
        let title = any("resultTitle")
        XCTAssertTrue(title.appears(timeout: 5))
        XCTAssertTrue(any("cleanBadge").appears(timeout: 5),
                      "a product that clears the clean standard should carry the blue badge in results")
        snap("clean-results")

        title.tap()
        let button = any("cleanBadgeButton")
        XCTAssertTrue(button.appears(timeout: 5), "the product page should show the badge")
        // One seal per badge (owner, 2026-10-31), and only the seal (owner,
        // 2026-11-20: "we only need to have the badges we don't need the
        // text"), on the price's row and across from it ("put the badge on
        // the same row as the price but on the opposite side").
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "the seal is big enough to tap: \(button.frame)")
        XCTAssertLessThan(button.frame.width, 80, "a seal alone, no text beside it: \(button.frame)")
        XCTAssertTrue(button.label.hasPrefix("Marracat Clean"), "VoiceOver still hears the badge's name: \(button.label)")
        XCTAssertFalse(app.staticTexts["What this means"].exists, "the words beside the seal are gone")
        let badges = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH 'BadgeButton'"))
            .allElementsBoundByIndex.map(\.frame).sorted { $0.minX < $1.minX }
        for (a, b) in zip(badges, badges.dropFirst()) {
            XCTAssertEqual(a.midY, b.midY, accuracy: 2, "badges on the product page sit on one line")
        }
        let page = app.windows.firstMatch.frame, price = any("productPrice").frame
        XCTAssertTrue(any("productPrice").exists, "the price should be on the page")
        XCTAssertEqual(button.frame.midY, price.midY, accuracy: 6, "the badge sits on the price's row: \(button.frame) vs \(price)")
        XCTAssertLessThan(price.maxX, badges.first!.minX, "the price on one side, the badges on the other")
        XCTAssertLessThan(price.minX, page.width * 0.1, "the price keeps the leading edge")
        XCTAssertGreaterThan(badges.last!.maxX, page.width * 0.9, "the badges reach the trailing edge: \(badges)")
        snap("product-badge-seals")
        button.tap()
        XCTAssertTrue(any("cleanStandardSheet").appears(timeout: 5),
                      "tapping the badge should explain the standard")
        XCTAssertTrue(app.staticTexts["Fragrance named"].exists)
        // The full wording is one tap away.
        any("cleanStandardDetails").tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'European standard'")).firstMatch.appears(timeout: 5))
        if let dir = ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("clean-standard.png"))
        }
        snap("clean-standard")
        any("cleanStandardDone").tap()
        XCTAssertTrue(button.appears(timeout: 5))
    }

    func testVitaminDFindsVitaminDAndNotVitaminC() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        // "vitamin d" used to return 75 products, 73 of which weren't vitamin D:
        // the lone "d" matched the start of "Dark", "Day" and "Detangling", so
        // Vitamin C serums cleared the bar. The whole phrase now has to be in
        // the title, and a one-letter word can no longer match as a prefix.
        input.typeText("vitamin d\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))

        let titles = app.descendants(matching: .any).matching(identifier: "resultTitle")
        let shown = (0..<min(titles.count, 6)).map { titles.element(boundBy: $0).label.lowercased() }
        XCTAssertFalse(shown.isEmpty, "no results for 'vitamin d'")
        for title in shown {
            XCTAssertTrue(title.contains("vitamin d"),
                          "'\(title)' isn't a vitamin D product")
            XCTAssertFalse(title.contains("vitamin c"),
                           "'\(title)' is vitamin C, not vitamin D")
        }
        snap("vitamin-d")
    }

    /// Price-drop alerts (owner, 2026-10-04): Track price toggles, and a brand page has Share and Sale
    /// alerts. -DEAL_ALERTS_STUB keeps alerts on the phone, signed in.
    func testTrackPricePromptAndAlertButtons() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-DEAL_ALERTS_STUB"]
        app.launch()
        func openDurag() {
            XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
            app.storeSearchField().tap()
            let input = any("searchInput")
            XCTAssertTrue(input.appears(timeout: 5))
            input.typeText("durag\n")
            let result = any("resultTitle")
            XCTAssertTrue(result.appears(timeout: 10))
            result.tap()
            XCTAssertTrue(any("trackPrice").appears(timeout: 10))
        }
        // The "Track this price?" prompt is gone (owner, 2026-10-05): it
        // never shows, however often the page is opened.
        for _ in 1...4 {
            openDurag()
            XCTAssertFalse(app.alerts["Track this price?"].appears(timeout: 1))
            tapTab("Home"); tapTab("Home")
        }
        openDurag()
        // The actions are symbols in one bar of equal parts (owner,
        // 2026-11-01); a tap highlights the part and says so in a short note
        // at the top. The names stay for VoiceOver.
        let track = any("trackPrice")
        // Scrolled past its name, the product names itself in the top bar,
        // centred (owner, 2026-11-01).
        XCTAssertFalse(any("productBarTitle").exists, "the bar title waits until the name scrolls away")
        app.swipeUp()
        let barTitle = any("productBarTitle")
        XCTAssertTrue(barTitle.appears(timeout: 5), "scrolled down, the product's name should be in the top bar")
        XCTAssertEqual(barTitle.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "bar title at \(barTitle.frame)")
        let parts = ["trackPrice", "addToList", "notInterested", "shareProduct"].map(any)
        XCTAssertTrue(parts.allSatisfy(\.exists))
        let widths = parts.map(\.frame.width), rows = Set(parts.map { Int($0.frame.midY.rounded()) })
        XCTAssertEqual(rows.count, 1, "the actions share one row: \(parts.map(\.frame))")
        XCTAssertLessThan(widths.max()! - widths.min()!, 2, "the parts are equal: \(widths)")
        XCTAssertEqual(track.label, "Track price")
        snap("product-action-bar")
        track.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tracking the price'")).firstMatch.appears(timeout: 3), "a tap should say it took")
        snap("product-action-bar-on")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tracking price'")).firstMatch.appears(timeout: 5))
        any("addToList").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Added to Your List'")).firstMatch.appears(timeout: 3))
        XCTAssertTrue(any("addToList").isSelected, "a saved item's chip stays highlighted")

        let store = any("visitStore")
        XCTAssertTrue(store.appears(timeout: 5))
        store.tap()
        XCTAssertTrue(any("brandWebsite").appears(timeout: 10), "the brand page opened")
        XCTAssertEqual(any("brandWebsite").label, "Website", "the store link reads Website, not the domain")
        let sale = any("saleAlerts")
        XCTAssertTrue(sale.exists)
        sale.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Sale alerts on'")).firstMatch.appears(timeout: 5))
        // and says so (owner, 2026-11-01: "it should bring up a prompt that they turned it on").
        XCTAssertTrue(any("actionToast").appears(timeout: 3), "turning sale alerts on should say so")
        XCTAssertTrue(any("actionToast").label.contains("Sale alerts on for"), "toast reads \(any("actionToast").label)")

        // Both show under You › Price & sale alerts (owner, 2026-10-05).
        tapTab("You")
        let row = any("priceAlertsRow")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.label.contains("(2)"), "the row counts the tracked product and the followed brand: \(row.label)")
        row.tap()
        XCTAssertTrue(any("priceAlert").appears(timeout: 5), "the tracked product is listed")
        XCTAssertTrue(any("saleAlert").exists, "the followed brand is listed")
        snap("price-alerts-list")
    }

    /// The Clean filter shows only where something listed could be Clean
    /// (owner, 2026-10-04: "we shouldnt show that filter for products or
    /// categories that dont even have a marracat clean product"). Durags
    /// have no formula, so it isn't offered there.
    func testCleanToggleHidesWhereNothingIsClean() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("durag\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 10))
        XCTAssertTrue(any("filtersButton").appears(timeout: 5))
        XCTAssertFalse(any("cleanToggle").exists, "nothing here can be Marracat Clean")
    }

    func testFilterSheetOffersSizesOnAClothingSearch() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("dress\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 15))
        any("filtersButton").tap()
        XCTAssertTrue(any("filterSheet").appears(timeout: 15))

        let groups = app.descendants(matching: .any).matching(identifier: "filterGroup")
        XCTAssertTrue(groups.element(boundBy: 0).appears(timeout: 5))
        let labels = (0..<groups.count).map { groups.element(boundBy: $0).label }
        XCTAssertTrue(labels.contains { $0.contains("Size") },
                      "clothing carries sizes in its variant titles, so Size should be a group: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Brand") }, "Brand should always be offered")
        XCTAssertTrue(labels.contains { $0.contains("Price") }, "Price should always be offered")
    }

    /// "butter" is a kind of product; "Buttercream" is a colour. Results lead
    /// with the butter.
    /// "bulk t shirts" has no exact match; the page shows the t-shirts and
    /// says which words it searched instead of a dead end.
    func testUnmatchedWordFallsBackInsteadOfEmptyPage() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("bulk t shirts\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        XCTAssertTrue(header.label.contains("Showing results for") && header.label.contains("t shirts"), header.label)
        XCTAssertTrue(any("resultTitle").appears(timeout: 5), "fallback results should be listed")
    }

    /// Owner, 2026-11-03, after a returning shopper's searches: "independent"
    /// says every item is from a independent brand; a brand's name leads with
    /// that brand; "dunk keychain" finds a Dunk charm; a misspelt brand shows
    /// that brand with other guesses; and after "bag charm", "fruit" opens
    /// with a charm or two picked for you. MARRACAT_SHOT_DIR keeps screenshots.
    func testSearchNoticeBrandLeadGuessesAndPicks() {
        func search(_ q: String) {
            let field = app.storeSearchField()
            XCTAssertTrue(field.appears(timeout: 15))
            field.tap()
            let input = any("searchInput")
            XCTAssertTrue(input.appears(timeout: 5))
            input.typeText(q + "\n")
            XCTAssertTrue(any("resultsHeader").appears(timeout: 15), q)
        }
        search("independent")
        XCTAssertTrue(any("ownershipNotice").appears(timeout: 5))
        XCTAssertTrue(any("ownershipNotice").label.contains("is independent"), any("ownershipNotice").label)
        snap("1-independent", settle: 2)

        search("fraiche")
        let byline = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'by '")).firstMatch
        XCTAssertTrue(byline.appears(timeout: 5))
        XCTAssertEqual(byline.label, "by Fraîche Studios")
        snap("2-brand-leads", settle: 2)

        search("dunk keychain")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Dunk Charm'")).firstMatch.appears(timeout: 5))
        snap("3-synonyms", settle: 2)

        search("brandon blakwod")
        XCTAssertTrue(any("resultsHeader").label.contains("Showing results for") && any("resultsHeader").label.contains("Brandon Blackwood"),
                      any("resultsHeader").label)
        XCTAssertTrue(any("didYouMean").appears(timeout: 5))
        snap("4-did-you-mean", settle: 2)

        // (Its own picks may show: "fraiche" was searched above.)
        search("bag charm")
        search("fruit")
        XCTAssertTrue(any("personalPicksHeader").appears(timeout: 5))
        XCTAssertTrue(any("personalPicksHeader").label.contains("bag charm"), any("personalPicksHeader").label)
        snap("5-picked-for-you", settle: 2)

        // A felting kit is no bag charm: craft supplies drop below real charms.
        search("bag charm fruit")
        let first = any("resultTitle")
        XCTAssertTrue(first.appears(timeout: 5))
        XCTAssertFalse(first.label.lowercased().contains("felting"), first.label)
        snap("6-departments", settle: 2)
    }

    func testSearchRanksWholeWordsFirst() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("butter\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 5))
        let titles = app.descendants(matching: .any).matching(identifier: "resultTitle").allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }.map(\.label)
        XCTAssertGreaterThan(titles.count, 2, "expected results for butter")
        // A whole word, plural included: "Body Butters" sells butter (search
        // reads plurals as their singular), "Buttercream" doesn't.
        for title in titles.prefix(4) {
            let words = title.lowercased().split(whereSeparator: { !$0.isLetter })
            XCTAssertTrue(words.contains("butter") || words.contains("butters"),
                          "‘\(title)’ leads a butter search without selling butter")
        }
    }

    /// Owner, 2026-10-11: "Picked for you right now" showed three products,
    /// swapped them a second later, then "Inspired by your search…" popped in
    /// under it mid-scroll; and one row showed "The Rich One Moisture
    /// Repair…" twice. On a relaunch both rows must be on Home as it appears
    /// (saved from the last session, HomeRowsCache), hold the same products
    /// and the same place while the rest of the catalog loads, and show each
    /// product once.
    func testRelaunchedHomeOpensOnItsRowsAndHoldsThem() throws {
        app.terminate()
        // -ALLOW_MEANING: the taste row needs the on-device AI files, which a
        // reset run otherwise never reads.
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-ALLOW_MEANING"]
        app.launch()

        // Last session: a search, and a product looked at (the taste).
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("body wash\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 10))
        let result = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 10))
        result.tap()
        XCTAssertTrue(app.buttons["addToCart"].appears(timeout: 10))
        sleep(2)
        tapTab("Home")   // pops back to the feed; the product page's dwell is the taste
        XCTAssertTrue(app.buttons["addToCart"].disappears(timeout: 5))
        // Leaving Home reads the taste for its next visit.
        tapTab("Saved")
        tapTab("Home")
        let picked = any("pickedForYou")
        guard picked.appears(timeout: 20) else {
            throw XCTSkip("the on-device AI files aren't on this simulator, so there's no taste row to check")
        }
        let searchRow = app.descendants(matching: .any).matching(identifier: "forYouRow")
            .containing(NSPredicate(format: "label == %@", "Inspired by your search for “body wash”")).firstMatch
        XCTAssertTrue(searchRow.appears(timeout: 10), "setup: no search row")
        let lastPicked = tileLabels(picked), lastSearch = tileLabels(searchRow)
        XCTAssertEqual(lastPicked.count, 3, "setup: the picked row's tiles aren't readable")
        XCTAssertEqual(lastSearch.count, 3, "setup: the search row's tiles aren't readable")
        // Shop by style's boards are saved the same way (StyleBoardsCache).
        let hadStyles = any("styleBoard").appears(timeout: 10)
        sleep(1)   // the rows are written off the main thread

        // This session: no reset.
        app.terminate()
        app.launchArguments = ["-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-ALLOW_MEANING"]
        app.launch()
        XCTAssertTrue(any("heroBrand").appears(timeout: 15), "Home didn't draw")
        XCTAssertTrue(picked.appears(timeout: 1), "“Picked for you right now” wasn't on Home as it appeared")
        XCTAssertTrue(searchRow.appears(timeout: 1), "“Inspired by your search” wasn't on Home as it appeared")
        if hadStyles {
            XCTAssertTrue(any("styleBoard").appears(timeout: 1), "Shop by style wasn't on Home as it appeared (build 132: it grew in mid-fling)")
        }
        let firstPicked = tileLabels(picked), firstSearch = tileLabels(searchRow)
        let pickedTop = picked.frame.minY, searchTop = searchRow.frame.minY
        XCTAssertEqual(firstPicked, lastPicked, "Home didn't open on the row the last session showed")
        XCTAssertEqual(firstSearch, lastSearch)

        // The whole catalog lands behind Home ("Discover more" waits for it):
        // nothing in or above these rows may change.
        XCTAssertTrue(app.staticTexts["Discover more"].appears(timeout: 30), "the whole catalog never landed")
        sleep(2)
        XCTAssertEqual(tileLabels(picked), firstPicked, "“Picked for you right now” swapped its products during the launch")
        XCTAssertEqual(tileLabels(searchRow), firstSearch, "the search row changed during the launch")
        XCTAssertEqual(picked.frame.minY, pickedTop, accuracy: 1, "“Picked for you right now” moved during the launch")
        XCTAssertEqual(searchRow.frame.minY, searchTop, accuracy: 1, "the search row moved during the launch")

        // One tile per product as the shopper sees it: the name a tile shows.
        for (name, row) in [("picked", picked), ("search", searchRow)] {
            let titles = row.buttons.matching(identifier: "productTile").allElementsBoundByIndex
                .map { $0.label.components(separatedBy: ",").first ?? $0.label }
            XCTAssertEqual(Set(titles).count, titles.count, "\(name) row shows a product twice: \(titles)")
        }
    }

    /// Owner, build 131's first open: tiles showed past the iPhone's edges,
    /// then the page snapped back. The row placeholders (a launch with history
    /// but no saved rows: the first launch of a new build) were a bare HStack
    /// of three 150-pt tiles, 498 pt wide, and widened all of Home. While they
    /// show, nothing on Home may reach past the window.
    func testHomePlaceholdersFitTheWindow() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launch()
        // History: a search and a product looked at.
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("body wash\n")
        let result = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 10))
        result.tap()
        XCTAssertTrue(app.buttons["addToCart"].appears(timeout: 10))
        sleep(1)

        // A new build's first launch: the history, no saved rows.
        app.terminate()
        app.launchArguments = ["-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-NO_SAVED_HOME_ROWS", "-HOLD_HOME_PLACEHOLDERS"]
        app.launch()
        let placeholder = app.descendants(matching: .any).matching(identifier: "rowPlaceholder").firstMatch
        XCTAssertTrue(placeholder.appears(timeout: 15), "Home didn't hold the personal rows' places")
        let window = app.windows.firstMatch.frame
        func inside(_ e: XCUIElement, _ name: String) {
            guard e.exists else { return }
            let f = e.frame
            XCTAssertGreaterThanOrEqual(f.minX, window.minX - 0.5, "\(name) starts left of the window: \(f) in \(window)")
            XCTAssertLessThanOrEqual(f.maxX, window.maxX + 0.5, "\(name) runs past the window: \(f) in \(window)")
        }
        inside(placeholder, "a row placeholder")
        inside(any("homeChips"), "the department chips")
        inside(any("heroBrand"), "the hero")
        // Product rows scroll sideways, so later tiles sit off the right edge
        // by design; the first one must start inside the window.
        let tile = app.buttons.matching(identifier: "productTile").firstMatch
        if tile.exists {
            XCTAssertGreaterThanOrEqual(tile.frame.minX, window.minX - 0.5, "a product tile starts left of the window: \(tile.frame)")
        }
    }

    /// Search opens as an overlay, so iOS gives it no back gesture of its own —
    /// swiping in from the left edge has to dismiss it and leave the screen
    /// underneath exactly as it was.
    func testSwipingFromTheEdgeClosesSearch() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        let bags = any("categoryRow.bags")
        XCTAssertTrue(bags.appears(timeout: 5))

        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("shea")

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.45))
        let swipe = { edge.press(forDuration: 0.05, thenDragTo: self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))) }
        swipe()
        // Late in the full suite the simulator sometimes drops the first
        // synthesized drag (failed twice on 2026-10-09, passes alone); one
        // more swipe is still a swipe that has to close search.
        if !input.disappears(timeout: 3) { swipe() }
        XCTAssertTrue(input.disappears(timeout: 5), "the edge swipe didn't close search")
        if !bags.appears(timeout: 5) { snap("afterEdgeSwipe") }
        XCTAssertTrue(bags.exists, "Browse didn't come back underneath")
        XCTAssertTrue(app.storeSearchField().appears(timeout: 5), "Browse's search bar didn't come back")

        // A short drag is a change of mind, not a dismissal.
        app.storeSearchField().tap()
        XCTAssertTrue(input.appears(timeout: 5))
        let short = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
        short.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45)))
        sleep(1)
        XCTAssertTrue(input.exists, "a short drag should spring back, not close search")
    }

    /// The Search tab, ASOS-style: the first tap lands on Browse, a second
    /// tap there opens search with the keyboard up, ready to type.
    func testSecondTapOnSearchTabOpensSearch() {
        let browse = app.buttons["tab.browse"]
        XCTAssertTrue(browse.appears(timeout: 10))
        browse.tap()
        XCTAssertTrue(any("categoryRow.bags").appears(timeout: 5), "the first tap should land on Browse")
        XCTAssertFalse(any("searchInput").exists, "the first tap shouldn't open search")
        browse.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5), "the second tap should open search")
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5), "search should open ready to type")
        // The first letter builds the suggestion index; typing on before it
        // lands drops XCUITest's keystrokes (a person's aren't lost).
        input.typeText("t")
        XCTAssertTrue(app.buttons["searchAllSuggestion"].appears(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard should stay up while typing")
        input.typeText("ote")
        XCTAssertEqual(input.value as? String, "tote")
    }

    /// The Featured banner moves on by itself, and a tap opens the brand
    /// it's showing (owner, 2026-10-12).
    func testFeaturedBannerCyclesAndOpensTheBrand() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let banner = any("featuredBanner")
        XCTAssertTrue(banner.appears(timeout: 5))
        let first = banner.label
        XCTAssertTrue(first.hasPrefix("Featured: "), first)
        let moved = NSPredicate(format: "label != %@", first)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: moved, evaluatedWith: banner)], timeout: 10), .completed,
                       "the banner stayed on \(first)")
        // Let the slide settle, then open whichever brand is showing.
        sleep(1)
        let brand = String(banner.label.dropFirst("Featured: ".count))
        banner.tap()
        XCTAssertTrue(any("brandWebsite").appears(timeout: 10), "the tap didn't open a brand store")
        XCTAssertTrue(app.staticTexts[brand].appears(timeout: 3), "opened a different brand than \(brand)")
        XCTAssertFalse(any("searchInput").exists, "search should close behind the brand")
    }

    /// Tapping a photo opens every photo of the product, stacked in one
    /// scrollable column, starting on the one that was tapped.
    func testTappingAPhotoOpensTheStackedGallery() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("corset\n")
        let result = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()

        let photo = any("productImage")
        XCTAssertTrue(photo.appears(timeout: 10))
        photo.tap()

        XCTAssertTrue(any("productGallery").appears(timeout: 5), "the gallery didn't open")
        XCTAssertTrue(app.staticTexts["Product gallery"].exists)
        let photos = app.descendants(matching: .any).matching(identifier: "productImage")
        XCTAssertGreaterThan(photos.count, 1, "the gallery should stack every photo")
        // Stacked, not side by side.
        let frames = photos.allElementsBoundByIndex.prefix(2).map(\.frame)
        if frames.count == 2 {
            XCTAssertNotEqual(frames[0].minY, frames[1].minY, accuracy: 0.5,
                              "the photos should be stacked vertically")
        }
        snap("productGallery")
        // Scrolling the column must not take the gallery down with it.
        let top = photos.firstMatch.frame.minY
        app.scrollViews.firstMatch.swipeUp()
        sleep(1)
        XCTAssertTrue(any("productGallery").appears(timeout: 3),
                      "scrolling closed the gallery")
        if photos.firstMatch.frame.minY < top - 1 {
            // Swiping back up the column from further down scrolls it; only a
            // swipe that starts at the top closes the gallery (owner, 2026-10-11).
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
            sleep(1)
            XCTAssertTrue(any("productGallery").appears(timeout: 3),
                          "a swipe down from below the top closed the gallery")
            any("closeGallery").tap()
        } else {
            // The photos fit on screen (the catalog's first corset had two on
            // 2026-11-16), so the column is always at its top and a swipe
            // down closes the gallery.
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
            XCTAssertTrue(any("productGallery").disappears(timeout: 3), "a swipe down at the top should close the gallery")
        }
        XCTAssertTrue(any("addToCart").appears(timeout: 5), "closing the gallery should return to the product")
    }

    /// Paying the first brand leaves its items out of the cart at once and
    /// shows the card with the order number; Continue opens the next brand's
    /// checkout filled in from the saved details; closing that sheet without
    /// paying changes nothing.
    func testContinueCardOpensTheNextBrandFilledIn() {
        // Brands without a UCP endpoint first: their checkout is the cart
        // link, filled in from the saved details.
        launchSeeded(["black-butterfly-bath-and-body", "noir-lux-candle-co", "brown-girl-jane"])
        let checkout = any("cartCheckout")
        XCTAssertTrue(checkout.appears(timeout: 5), "no Checkout in the bag")
        XCTAssertTrue(checkout.label.contains("then 2 more"), checkout.label)
        checkout.tap()
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 5))
        XCTAssertTrue(any("checkoutPrefill").label.contains("O'Brien"), "the first brand's cart link wasn't filled in")
        any("stubCompleteOrder").tap()

        XCTAssertTrue(any("continueCard").appears(timeout: 5), "no continue card after the order")
        let title = any("continueTitle").label
        XCTAssertTrue(title.contains("Order placed with") && title.contains(" · #"), title)
        XCTAssertTrue(any("continueNext").label.hasSuffix("(2 of 3)"), any("continueNext").label)
        XCTAssertEqual(cartLineCount(), 2, "the paid brand's items should leave the cart at once")
        snap("continue-card")

        any("continueNext").tap()
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 5), "Continue didn't open the next brand")
        XCTAssertFalse(any("checkoutSheet").label.contains("Black Butterfly"), "Continue reopened the brand just paid")
        XCTAssertEqual(any("checkoutPrefill").label,
                       "Ships to Zoë O'Brien, 12 Rue & Co #4, Apt 4B, Brooklyn NY 11201, +1 718 555 0100",
                       "the saved details didn't survive the cart link")
        // Closed without paying: back to the cart, nothing advanced or removed.
        // Pulled down from the sheet's top edge, as a shopper closes it.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(any("checkoutSheet").disappears(timeout: 5), "the checkout sheet didn't close")
        XCTAssertFalse(any("continueCard").exists, "a canceled checkout shouldn't bring the card back")
        XCTAssertEqual(cartLineCount(), 2, "a canceled checkout removed items")
        XCTAssertTrue(any("cartCheckout").appears(timeout: 5), "Checkout should hover again once the card is gone")
    }

    /// Later puts the card away and leaves only the unpaid brand in the cart.
    func testLaterKeepsTheUnpaidBrandsInTheCart() {
        launchSeeded(["black-butterfly-bath-and-body", "noir-lux-candle-co"])
        let checkout = any("cartCheckout")
        XCTAssertTrue(checkout.appears(timeout: 5))
        checkout.tap()
        XCTAssertTrue(any("stubCompleteOrder").appears(timeout: 5))
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("continueNext").appears(timeout: 5))
        XCTAssertTrue(any("continueNext").label.hasSuffix("(2 of 2)"), any("continueNext").label)
        any("continueLater").tap()
        XCTAssertTrue(any("continueCard").disappears(timeout: 5), "Later didn't put the card away")
        XCTAssertFalse(any("checkoutSheet").exists, "Later opened a checkout")
        XCTAssertEqual(cartLineCount(), 1, "Later should keep exactly the unpaid brand")
    }

    /// The Marracat order email (-RELAY_STUB): the checkout goes out with the
    /// u-…@orders.marracat.com address, and the brand's emails, read on the
    /// server, fill in the real order number, the tracking number and the
    /// tracker. Stubbed here: a confirmation for #1042, then a USPS shipment.
    func testOrderEmailShowsOrderNumberTrackingAndAddress() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-RELAY_STUB"]
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("parfum\n")
        // A Scent & Fire bottle: a brand with a UCP endpoint, so the order is
        // built over UCP and tracked. The first "parfum" result moved to a
        // cart-link brand when the meaning vectors were rebuilt (2026-10-05).
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no in-stock result")
        result.tap()
        let add = any("addToCart")
        XCTAssertTrue(add.appears(timeout: 5))
        tapClearOfTabBar(add)
        tapTab("Cart")
        openBrandCheckout()
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("orderPlaced").appears(timeout: 5))
        tapTab("You")
        any("tileOrders").tap()
        let row = any("orderRow")
        XCTAssertTrue(row.appears(timeout: 5))
        XCTAssertTrue(row.label.contains("Shipped"), "the list row should say Shipped: \(row.label)")
        row.tap()
        XCTAssertTrue(any("orderTracker").appears(timeout: 5))
        XCTAssertTrue(any("orderStatus").label.hasPrefix("Shipped"), any("orderStatus").label)
        XCTAssertEqual(any("orderTracker").value as? String, "1", "the tracker should fill Ordered and Shipped")
        XCTAssertTrue(any("orderTracking").label.contains("9400111899223197428490"), any("orderTracking").label)
        XCTAssertEqual(any("orderName").label, "Order #1042")
        XCTAssertTrue(any("orderEmail").label.contains("@orders.marracat.com"), any("orderEmail").label)
        // "The product, big" (owner, 2026-11-10): the status rides on the
        // product photo above the name, the tracker fills, and Buy it again
        // is a bar kept above the tab bar.
        let status = any("orderStatus"), buyAgain = any("orderBuyAgain")
        XCTAssertLessThan(status.frame.minY, any("orderShippingNote").frame.minY, "the status sits on the photo, above the details")
        XCTAssertTrue(buyAgain.exists && buyAgain.isHittable, "Buy it again should be kept at the bottom")
        XCTAssertLessThanOrEqual(buyAgain.frame.maxY, app.buttons["tab.home"].frame.minY + 2, "above the tab bar, not under it")
        XCTAssertGreaterThan(buyAgain.frame.minY, app.buttons["tab.home"].frame.minY - 120, "right above the tab bar, not up the screen over the actions: \(buyAgain.frame)")
        XCTAssertFalse(any("orderSeeDetails").exists, "no See details fold any more")
        snap("order-email-details")
        let copyDetails = any("orderCopyDetails")
        for _ in 0..<4 where !copyDetails.isHittable { app.swipeUp() }
        snap("order-email-summary")
        copyDetails.tap()
        XCTAssertTrue(any("orderAddedToast").appears(timeout: 3), "copying should confirm")
    }

    /// Tapping outside a text field closes the keyboard, and the tap doesn't
    /// dismiss the sheet or trigger anything else (user, 2026-09-28, the
    /// product page's comment field; comments need a real sign-in, so this
    /// uses the new-list sheet, which opens with its field focused).
    func testTapOutsideTextFieldClosesKeyboard() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("parfum\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
        // Lists live behind a hold on Add to List (owner, 2026-10-05).
        let folder = any("addToList")
        XCTAssertTrue(folder.appears(timeout: 5))
        for _ in 0..<3 where folder.frame.maxY > app.buttons["tab.home"].frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        // Let the scroll stop first: a hold that lands on a page still
        // gliding stops the scroll and counts as a tap, which saved the item
        // instead of fanning out the lists (2026-11-01, once the store card
        // put the heart lower and the swipe above ran more often).
        var resting = folder.frame
        for _ in 0..<12 {
            usleep(150_000)
            if folder.frame == resting { break }
            resting = folder.frame
        }
        folder.press(forDuration: 1.2)
        XCTAssertTrue(any("quickListFan").appears(timeout: 5), "holding Add to List should fan out the lists")
        XCTAssertTrue(app.buttons["All lists…"].appears(timeout: 5))
        // Every bubble lands fully on screen (the chip sits at the left edge;
        // its first bubble was half off screen until 2026-10-06).
        let screen = app.windows.firstMatch.frame
        waitUntil(timeout: 3) {
            app.buttons.matching(identifier: "quickList").allElementsBoundByIndex.allSatisfy { screen.contains($0.frame) }
        }
        for bubble in app.buttons.matching(identifier: "quickList").allElementsBoundByIndex {
            XCTAssertTrue(screen.contains(bubble.frame), "\(bubble.label) is off screen: \(bubble.frame) in \(screen)")
        }
        app.buttons["All lists…"].tap()
        XCTAssertTrue(any("saveToListSheet").appears(timeout: 5))
        app.buttons["newListFromProduct"].tap()
        let name = app.textFields["listNameField"]
        XCTAssertTrue(name.appears(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.appears(timeout: 5), "setup: the field should open with the keyboard up")
        // Moving the cursor within the field keeps it open.
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists, "tapping the field itself must not close the keyboard")
        // Blank space under the field.
        app.staticTexts["Up to 40 characters."].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed, "tapping outside the field should close the keyboard")
        XCTAssertTrue(name.exists, "the sheet should stay open")
    }

    /// Saved items live in folders with a cover photo: make a list from a
    /// product page, find it on the Saved tab, open it, change its cover to
    /// one of its items, and see it counted on the profile.
    func testSavedFoldersWithCovers() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("parfum\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5))
        result.tap()
        // Lists live behind a hold on Add to List (owner, 2026-10-05).
        let folder = any("addToList")
        XCTAssertTrue(folder.appears(timeout: 5))
        for _ in 0..<3 where folder.frame.maxY > app.buttons["tab.home"].frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        // Let the scroll stop first: a hold that lands on a page still
        // gliding stops the scroll and counts as a tap, which saved the item
        // instead of fanning out the lists (2026-11-01, once the store card
        // put the heart lower and the swipe above ran more often).
        var resting = folder.frame
        for _ in 0..<12 {
            usleep(150_000)
            if folder.frame == resting { break }
            resting = folder.frame
        }
        folder.press(forDuration: 1.2)
        XCTAssertTrue(any("quickListFan").appears(timeout: 5), "holding Add to List should fan out the lists")
        XCTAssertTrue(app.buttons["All lists…"].appears(timeout: 5))
        app.buttons["All lists…"].tap()
        XCTAssertTrue(any("saveToListSheet").appears(timeout: 5), "save-to-list sheet didn't open")
        app.buttons["newListFromProduct"].tap()
        let name = app.textFields["listNameField"]
        XCTAssertTrue(name.appears(timeout: 5))
        name.typeText("Gifts")
        app.buttons["listNameSave"].tap()
        let row = app.buttons.matching(identifier: "listRow").firstMatch
        XCTAssertTrue(row.appears(timeout: 5), "the new list should appear in the sheet")
        XCTAssertEqual(row.value as? String, "in list", "the product should be in the list it was created for")
        app.buttons["saveToListDone"].tap()
        XCTAssertTrue(folder.isSelected, "in a list means saved")
        // Holding again: Gifts is a recent list, and the product's department
        // is offered as a new list since no other list holds that kind of item.
        folder.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Gifts"].appears(timeout: 5), "the recent list should be offered")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'New list:'")).firstMatch.exists, "a list for the product's department")
        snap("quick-lists")
        app.buttons["Gifts"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Removed from Gifts'")).firstMatch.appears(timeout: 3))
        folder.press(forDuration: 1.2)
        app.buttons["Gifts"].tap()
        // The fan is modal while it animates shut (180 ms); a tab tapped
        // before then reads it as an alert (nightly 10/24 and 10/25).
        XCTAssertTrue(any("quickListFan").disappears(timeout: 3), "picking a list should close the fan")

        tapTab("Saved")
        let card = app.buttons.matching(identifier: "savedFolder").firstMatch
        XCTAssertTrue(card.appears(timeout: 5), "the folder should be on the Saved tab")
        XCTAssertTrue(card.label.contains("Gifts") && card.label.contains("1 saved"), card.label)
        XCTAssertTrue(any("savedFolderAll").exists, "All saved should be offered too")
        snap("saved-folders")
        card.tap()
        XCTAssertTrue(any("productTile").appears(timeout: 5), "the folder should list its item")
        app.buttons["changeCover"].tap()
        XCTAssertTrue(any("coverPicker").appears(timeout: 5))
        let option = app.buttons.matching(identifier: "coverOption").firstMatch
        XCTAssertTrue(option.appears(timeout: 5))
        option.tap()
        XCTAssertTrue(any("coverPicker").disappears(timeout: 5), "picking a cover should close the picker")
        snap("saved-folder")

        tapTab("You")
        XCTAssertTrue(any("profileCard").appears(timeout: 5))
        XCTAssertTrue(app.staticTexts["1"].exists && app.staticTexts["List"].exists, "the profile should count the list")
    }

    /// Every card in Home's rows is the same size. "Inspired by your likes"
    /// and "Keep shopping for" mixed 150pt and 130pt photos, because the well
    /// only took the width the layout happened to propose.
    func testHomeRowCardsAreOneSize() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(any("productTile").appears(timeout: 20), "Home never populated")
        // Each frame is read once: reading it again re-resolves the element,
        // and a Home still settling had swapped some tiles out in between, so
        // the check failed while its message listed only 150s (2026-10-14).
        let frames = app.descendants(matching: .any).matching(identifier: "productTile")
            .allElementsBoundByIndex.prefix(14).map(\.frame).filter { $0.width > 0 }
        XCTAssertGreaterThan(frames.count, 5, "expected several cards on Home")
        // The size the owner pointed to (2026-11-22, "this size and style cards").
        XCTAssertTrue(frames.allSatisfy { $0.width == 195 }, "cards should all be 195pt wide, got \(frames.map(\.width))")
        XCTAssertEqual(Set(frames.map { $0.height.rounded() }).count, 1, "cards should all be one height, got \(frames.map(\.height))")
        // And Home's rows are two cards high: some card sits right under another.
        let stacked = frames.contains { a in frames.contains { b in b.minX == a.minX && b.minY > a.maxY && b.minY - a.maxY < 20 } }
        XCTAssertTrue(stacked, "no card under another: Home's rows should be two high, got \(frames)")
    }

    /// Owner, 2026-11-22: "if someone isn't signed up put a sign up banner at
    /// the top of the app", then "I like #5 member card". Above everything on
    /// Home, and a tap away from the sign-in buttons. (Tests run signed out;
    /// someone with an account never sees it: AccountGuestTests.)
    func testAGuestIsOfferedAnAccountAtTheTopOfHome() {
        let banner = any("signUpBanner")
        XCTAssertTrue(banner.appears(timeout: 20), "no sign-up card on a guest's Home")
        XCTAssertTrue(any("homeChips").exists)
        XCTAssertLessThan(banner.frame.maxY, any("homeChips").frame.minY + 1, "the card should sit above the department chips")
        XCTAssertLessThan(banner.frame.minY, 140, "the card should be at the top of the screen")
        for words in ["Make Marracat yours", "Likes", "Orders", "Price drops", "Sign up"] {
            XCTAssertTrue(banner.label.contains(words), "the card should say \(words): \(banner.label)")
        }
        snap("signUpBanner")
        banner.tap()
        XCTAssertTrue(app.buttons["appleSignIn"].appears(timeout: 5), "the card should open the sign-in buttons")
        XCTAssertTrue(app.buttons["googleSignIn"].exists)
    }

    /// The card has a close. Closed, it stays away while the shopper moves
    /// about the app (and for a week of launches: SignUpBannerTests).
    func testTheSignUpCardCanBeClosed() {
        XCTAssertTrue(any("signUpBanner").appears(timeout: 20), "no sign-up card on a guest's Home")
        let chipsBefore = any("homeChips").frame.minY
        app.buttons["signUpBannerClose"].tap()
        XCTAssertTrue(any("signUpBanner").disappears(timeout: 5), "the close left the card up")
        XCTAssertLessThan(any("homeChips").frame.minY, chipsBefore - 50, "Home should move up into the card's place")
        XCTAssertFalse(app.buttons["appleSignIn"].exists, "the close opened the sign-in buttons")

        app.buttons["tab.you"].tap()
        XCTAssertTrue(any("profileCard").appears(timeout: 15))
        tapTab("Home")
        XCTAssertTrue(any("homeChips").appears(timeout: 5))
        XCTAssertFalse(any("signUpBanner").exists, "the card came back")
    }
}

/// One of three shares of the UI tests, balanced by run time, so the ship
/// runs them on three simulators at once (scripts/ship.sh; owner, 2026-10-17).
final class MarracatUITests3: MarracatUITestCase {
    func testClearHistoryCanBeCancelled() {
        app.buttons["tab.you"].tap()
        XCTAssertTrue(app.buttons["accountSettings"].appears(timeout: 5))
        app.buttons["accountSettings"].tap()
        let clear = app.buttons["clearPersonalHistory"]
        for _ in 0..<4 where !clear.isHittable { app.swipeUp() }
        clear.tap()
        XCTAssertTrue(app.buttons["Clear history"].appears(timeout: 3))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(clear.exists)
    }

    func testColdLaunchShowsSplash() {
        app.terminate()
        let fresh = XCUIApplication()
        // Hold the splash so XCUITest can inspect it after its launch idle wait.
        fresh.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "6", "-OFFLINE_CATALOG"]
        fresh.launch()
        let splash = fresh.descendants(matching: .any).matching(identifier: "splash").firstMatch
        XCTAssertTrue(splash.appears(timeout: 3), "no splash on a cold launch")
        XCTAssertEqual(splash.label, "MARRACAT")
        XCTAssertFalse(fresh.staticTexts["THE HOME OF INDEPENDENT BRANDS"].exists, "the splash tagline was removed")
        snap("splash")
        XCTAssertTrue(splash.disappears(timeout: 8), "splash never gave way to the app")
        XCTAssertTrue(fresh.storeSearchField()
            .appears(timeout: 5))
        XCUIDevice.shared.press(.home)
        fresh.activate()
        XCTAssertFalse(splash.exists, "returning from the background replayed the cold-launch splash")
    }

    /// The catalog is fetched on launch so brands can change without a build.
    /// Whatever happens out there, the storefront has to come up: this runs with
    /// a deliberately corrupt download sitting in the cache.
    func testCorruptCachedCatalogFallsBackToTheBundledOne() {
        app.terminate()
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-BAD_CATALOG_CACHE"]
        fresh.launch()
        let tile = fresh.descendants(matching: .any).matching(identifier: "productTile").firstMatch
        XCTAssertTrue(tile.appears(timeout: 15), "a bad cached catalog took the storefront down")
    }

    /// Home draws from its slice of the catalog while the rest loads behind it
    /// (HomeSlice, 2026-10-11). A tab or department opened in that moment
    /// waits for the whole catalog, then opens: it never shows the slice's
    /// handful of products as if they were all of them.
    func testScreensOpenedDuringLaunchWaitForTheWholeCatalog() {
        app.terminate()
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG"]
        fresh.launch()
        let tile = fresh.descendants(matching: .any).matching(identifier: "productTile").firstMatch
        XCTAssertTrue(tile.appears(timeout: 15), "Home never drew")
        fresh.buttons["tab.browse"].tap()
        let about = fresh.buttons["About Marracat"].firstMatch
        XCTAssertTrue(about.appears(timeout: 10), "Browse never opened")
        XCTAssertFalse(fresh.descendants(matching: .any).matching(identifier: "catalogLoading").firstMatch.exists,
                       "still waiting on the catalog")
        about.tap()
        let brands = fresh.descendants(matching: .any).matching(identifier: "aboutBrands").firstMatch
        XCTAssertTrue(brands.appears(timeout: 10))
        let products = fresh.descendants(matching: .any).matching(identifier: "aboutProducts").firstMatch
        XCTAssertTrue(products.exists)
        XCTAssertGreaterThan(Int(products.label.filter(\.isNumber)) ?? 0, 50_000, "Browse showed Home's slice: \(products.label)")
    }

    /// Nothing on the feed that can't be bought. Home is the shop window;
    /// a sold-out row is a dead end.
    func testFeedShowsOnlyBuyableProducts() {
        XCTAssertTrue(app.homeReady().appears(timeout: 10))
        // Give Home some history to work with, so "Keep shopping for" and the
        // personalised rows are populated.
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("rum\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))
        let firstResult = app.descendants(matching: .any).matching(identifier: "resultTitle").firstMatch
        XCTAssertTrue(firstResult.appears(timeout: 5))
        firstResult.tap()
        XCTAssertTrue(any("buyNow").appears(timeout: 10))
        tapTab("Home")
        sleep(2)

        for _ in 0..<6 {
            let soldOut = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Sold out'"))
            let unavailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Currently unavailable'"))
            XCTAssertEqual(soldOut.count, 0, "Home is showing a sold-out product")
            XCTAssertEqual(unavailable.count, 0, "Home is showing an unavailable product")
            app.swipeUp()
        }
    }

    /// A sold-out product offers "Notify me when it's back"; the alert then
    /// shows under You → Restock alerts and can be removed there.
    /// -RESTOCK_STUB keeps it local: no permission prompt, no network;
    /// -RESTOCK_SIGNED_IN stands in for a signed-in account.
    func testRestockAlertFromASoldOutProduct() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-RESTOCK_STUB", "-RESTOCK_SIGNED_IN"]
        app.launch()
        openSoldOutItem()
        let notify = app.buttons["notifyRestock"].firstMatch
        XCTAssertTrue(notify.appears(timeout: 10), "no restock button on a sold-out product")
        XCTAssertTrue(notify.label.contains("Notify me"))
        snap("restockOffer")
        notify.tap()
        XCTAssertTrue(app.buttons["notifyRestock"].firstMatch.label.contains("We'll notify you"))
        snap("restockWatching")

        tapTab("You")
        let row = any("restockAlertsRow")
        // Clear of the floating tab bar too: a row behind it is "hittable"
        // but the tap lands on the bar (the Share Marracat row moved it down).
        let clear = app.windows.firstMatch.frame.maxY - 140
        for _ in 0..<4 where !row.isHittable || row.frame.maxY > clear { app.swipeUp() }
        row.tap()
        let alert = any("restockAlert")
        XCTAssertTrue(alert.appears(timeout: 5))
        snap("restockList")
        alert.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No restock alerts"].appears(timeout: 5))
    }

    /// The catalog can be a day old; the page lays the brand's live stock
    /// over it (2026-10-11: a "Back in stock" push opened a page that still
    /// said "Currently unavailable"). -LIVE_STOCK_IN stands in a store that
    /// has the catalog's sold-out tote back, with no network.
    func testLiveStockShowsARestockedItemInStock() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG", "-RESTOCK_STUB", "-LIVE_STOCK_IN"]
        app.launch()
        openSoldOutItem()
        let status = any("stockStatus")
        XCTAssertTrue(status.appears(timeout: 10))
        let inStock = NSPredicate(format: "label == %@", "In Stock")
        expectation(for: inStock, evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["notifyRestock"].exists, "no restock offer on an item the store has")
        XCTAssertFalse(app.buttons["notifyRestockSignIn"].exists)
    }

    /// Every in-stock result carries three chips: See options OR Add to
    /// cart (never both), Track price and Add to List (owner, 2026-10-17).
    func testSearchResultsHaveThreeActionChips() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("handbag\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
        let options = app.buttons.matching(identifier: "resultSeeOptions").count
        let carts = app.buttons.matching(identifier: "resultAddToCart").count
        let tracks = app.buttons.matching(identifier: "resultTrackPrice").count
        let lists = app.buttons.matching(identifier: "resultAddToList").count
        XCTAssertGreaterThan(tracks, 0, "no Track price chip")
        XCTAssertEqual(lists, tracks, "every result with Track price also has Add to List")
        XCTAssertEqual(options + carts, tracks, "each result has exactly one of See options / Add to cart")
        snap("search-chips")
        let heart = app.buttons.matching(identifier: "resultAddToList").firstMatch
        XCTAssertEqual(heart.label, "Add to List")
        heart.tap()
        XCTAssertTrue(any("actionToast").appears(timeout: 3), "saving shows the toast")
        XCTAssertTrue(app.buttons["Saved"].firstMatch.appears(timeout: 3))
        app.buttons["Saved"].firstMatch.tap()   // leave Your List as it was
    }

    func testMarracatCleanCoversFaceWashes() {
        assertBadged("chamomile cucumber face wash", snapshot: "clean-face-wash")
    }

    func testSortIsItsOwnButtonBesideFilters() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("durag\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 10))

        // Sorting reorders rather than narrows, so it sits beside Filters
        // instead of inside the sheet.
        let sort = any("sortButton")
        XCTAssertTrue(sort.appears(timeout: 5), "sort should have its own button")
        sort.tap()
        let option = app.buttons["Price: low to high"]
        XCTAssertTrue(option.appears(timeout: 5), "the sort button should offer the orders")
        option.tap()
        XCTAssertTrue(any("sortButton").appears(timeout: 5))
        XCTAssertTrue(any("sortButton").label.contains("low to high"),
                      "the button should name the order in force: \(any("sortButton").label)")
        snap("sort-button")

        // And the sheet no longer carries it.
        any("filtersButton").tap()
        XCTAssertTrue(any("filterSheet").appears(timeout: 10))
        let groups = app.descendants(matching: .any).matching(identifier: "filterGroup")
        XCTAssertTrue(groups.element(boundBy: 0).appears(timeout: 5))
        let labels = (0..<groups.count).map { groups.element(boundBy: $0).label }
        XCTAssertFalse(labels.contains { $0.contains("Sort") },
                       "sort should have left the sheet: \(labels)")
    }

    /// Owner, 2026-11-08: the "You're in the right place." card shows for
    /// "independent" with any words around it, over the typing suggestions
    /// and above the results.
    func testIndependentCardShowsWhileTypingAndOnResults() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("bracelets independent")
        let notice = any("ownershipNotice")
        XCTAssertTrue(notice.appears(timeout: 10), "the compact card should sit over the suggestions")
        XCTAssertTrue(notice.label.contains("right place"), notice.label)
        snap("independent-typing")
        input.typeText("\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 10))
        let card = any("ownershipNotice")
        XCTAssertTrue(card.appears(timeout: 10), "the card should head the results")
        XCTAssertTrue(card.label.contains("is independent"), card.label)
        snap("independent-results")
    }

    func testTypedWordsAreOfferedAsASearchOfTheirOwn() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        // "durag" never earned a suggestion of its own: the rule that promotes
        // a word wants most of its brands in one department, and durags are
        // split between Hair Care and Accessories. The first row is the typed
        // words regardless, so there is always a way to see all of them.
        input.typeText("durag")
        let searchAll = any("searchAllSuggestion")
        // 10 s: under the full suite the suggestions took over 5 (build 112).
        XCTAssertTrue(searchAll.appears(timeout: 10))
        XCTAssertEqual(searchAll.label, "durag", "the row should echo what was typed")
        XCTAssertLessThan(searchAll.frame.minY,
                          app.descendants(matching: .any).matching(identifier: "suggestion")
                              .element(boundBy: 0).frame.minY,
                          "it should sit above the ranked suggestions")
        snap("suggest-search-all")
        searchAll.tap()

        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        XCTAssertTrue(header.label.contains("durag"), "it should run that search: \(header.label)")
        XCTAssertGreaterThan(Int(header.label.filter(\.isNumber)) ?? 0, 5,
                             "tapping it should open every durag, not one product")
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
    }

    func testCleanToggleFiltersToBadgedProductsWhereThereAreAny() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("body wash\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        let before = Int(header.label.filter(\.isNumber)) ?? 0

        let toggle = any("cleanToggle")
        XCTAssertTrue(toggle.appears(timeout: 5), "body washes include badged products, so the toggle should show")
        toggle.tap()
        XCTAssertEqual(any("cleanToggle").value as? String, "On")
        let after = Int(header.label.filter(\.isNumber)) ?? 0
        XCTAssertLessThan(after, before, "the toggle should narrow to badged products")
        XCTAssertGreaterThan(after, 0)
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
        XCTAssertTrue(any("cleanBadge").exists, "what's left should carry the badge")
        snap("clean-toggle")
        any("cleanToggle").tap()
        XCTAssertEqual(Int(header.label.filter(\.isNumber)), before, "turning it off should put everything back")
    }

    /// You › For brands (owner, 2026-10-06): pick your brand, then a link
    /// goes only to an address at that brand's own domain.
    func testForBrandsVerifiesByDomainEmail() {
        tapTab("You")
        let row = any("forBrandsRow")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        let field = app.textFields["claimBrandField"]
        XCTAssertTrue(field.appears(timeout: 5))
        field.tap(); field.typeText("Scent")
        let option = app.buttons.matching(identifier: "claimBrandOption").matching(NSPredicate(format: "label CONTAINS 'Scent & Fire'")).firstMatch
        XCTAssertTrue(option.appears(timeout: 5))
        option.tap()
        let email = app.textFields["claimEmailField"]
        XCTAssertTrue(email.appears(timeout: 5))
        email.tap(); email.typeText("me@gmail.com")
        XCTAssertFalse(any("claimSendLink").isEnabled, "only an address at the brand's own domain")
        snap("for-brands")
    }

    func testProductPageHasCommentsAndSharing() {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("durag\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 10))
        result.tap()
        XCTAssertTrue(any("shareProduct").appears(timeout: 10), "the product page should offer Share")
        // Signed out: comments can be read, and posting asks you to sign in.
        let header = any("commentsHeader")
        for _ in 0..<8 where !header.isHittable { app.swipeUp() }
        XCTAssertTrue(header.exists, "the product page should have a comments section")
        XCTAssertTrue(any("commentSignIn").exists, "signed out, commenting should ask you to sign in")
        XCTAssertFalse(any("sendToFriends").exists, "Send to friends was removed (owner, 2026-10-06)")
        snap("product-comments")
    }

    func testCategoryOpensToSubcategories() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        let bags = any("categoryRow.bags")
        XCTAssertTrue(bags.appears(timeout: 5))
        bags.tap()
        let rows = app.descendants(matching: .any).matching(identifier: "subcategory")
        XCTAssertTrue(rows.firstMatch.appears(timeout: 5))
        let names = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(names.contains("Tote Bags"), "Bags should break down into kinds of bag: \(names)")
        XCTAssertFalse(names.contains("Brandon Blackwood"), "brands shouldn't be listed under a category: \(names)")
        snap("bagsSubcategories")
        rows.element(boundBy: names.firstIndex(of: "Tote Bags") ?? 0).tap()
        XCTAssertTrue(any("productTile").appears(timeout: 5), "an aisle should open its own grid")
        // Scrolled past its big title, the aisle names itself in the top bar
        // (owner, 2026-10-31).
        let barTitle = any("gridBarTitle")
        XCTAssertFalse(barTitle.exists, "the bar title should wait until the big title scrolls away")
        app.swipeUp()
        XCTAssertTrue(barTitle.appears(timeout: 5), "scrolled down, the aisle's name should be in the top bar")
        XCTAssertTrue(barTitle.label.contains("Tote Bags"), "bar title reads \(barTitle.label)")
        // Centred on the screen, not set against the back button (owner, 2026-11-01).
        XCTAssertEqual(barTitle.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "bar title at \(barTitle.frame)")
        snap("aisleBarTitle")
        // Filters by the thumb, as on a brand page (owner, 2026-11-10): the
        // pill steps aside on the way down and is back on a short scroll up,
        // just above the tab bar.
        let filters = any("filtersButton"), home = app.buttons["tab.home"]
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { !filters.exists || !filters.isHittable }, "scrolling down leaves the room to the products")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(waitUntil(timeout: 5) { filters.exists && filters.isHittable }, "a scroll up brings Filters back")
        XCTAssertLessThanOrEqual(filters.frame.maxY, home.frame.minY + 2, "above the tab bar: \(filters.frame)")
        XCTAssertGreaterThan(filters.frame.minY, home.frame.minY - 120, "right above the tab bar: \(filters.frame)")
        XCTAssertTrue(any("sortButton").exists)
        snap("aislePillBack", settle: 1)
        // The sheet fits the aisle: every tote is a bag, so no Category group.
        filters.tap()
        let groups = app.descendants(matching: .any).matching(identifier: "filterGroup")
        XCTAssertTrue(groups.firstMatch.appears(timeout: 5))
        let labels = groups.allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(labels.contains { $0.hasPrefix("Category") }, "one department narrows nothing: \(labels)")
        XCTAssertGreaterThan(any("filtersApply").frame.minY, window.frame.height * 0.8, "Show results at the bottom of the sheet")
        snap("aisleFilters", settle: 1)
    }

    /// Aisles are curated in catalog/taxonomy.py and linked to products at
    /// build time, so ones nobody would mine out of a title — face wash, bras —
    /// are real places a shopper can open.
    func testAislesCoverFaceWashAndBras() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        tapTab("Browse")
        for (category, aisle) in [("skincare", "Face Wash & Cleansers"), ("clothing", "Bras & Bralettes")] {
            let row = any("categoryRow.\(category)")
            XCTAssertTrue(row.appears(timeout: 5))
            row.tap()
            // The aisle row itself: the same name can also be a button elsewhere
            // on Browse (a larger catalog put "Bras & Bralettes" in two places).
            let aisleRow = app.buttons.matching(identifier: "subcategory")
                .matching(NSPredicate(format: "label == %@", aisle)).firstMatch
            XCTAssertTrue(aisleRow.appears(timeout: 5), "\(category) has no \(aisle) aisle")
            // Keep the row clear of the floating tab bar, which XCUITest still
            // calls hittable: a tap there lands on the Home tab instead.
            let screen = app.windows.firstMatch.frame
            for _ in 0..<4 where aisleRow.frame.maxY > screen.maxY - 160 { app.swipeUp(velocity: .slow) }
            aisleRow.tap()
            XCTAssertTrue(any("productTile").appears(timeout: 5), "\(aisle) opened empty")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(row.appears(timeout: 5))
            row.tap()   // collapse before the next one
        }
    }

    func testSearchPersonalizesHome() {
        XCTAssertTrue(app.homeReady().appears(timeout: 10))
        let inspired = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Inspired by your search'"))
        XCTAssertFalse(inspired.firstMatch.exists, "a fresh shopper has no personalized rows")
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("tote\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))
        tapTab("Home")   // pops the results back to the Home feed
        XCTAssertTrue(app.staticTexts["Inspired by your search for “tote”"].appears(timeout: 5),
                      "Home didn't pick up the search")
        snap("forYou")
    }

    func testSearchScreenShowsFeaturedBannerAndLastThreeSearches() {
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        for q in ["tote", "parfum", "hoodie", "candle"] {
            app.storeSearchField().tap()
            let input = any("searchInput")
            XCTAssertTrue(input.appears(timeout: 5))
            input.typeText(q + "\n")
            let header = any("resultsHeader")
            XCTAssertTrue(header.appears(timeout: 5))
            // (Was testSearchFindsBags.) Each of these finds something.
            XCTAssertFalse(header.label.hasPrefix("0 results"), "\(q): \(header.label)")
            tapTab("Home")   // re-tap pops back to the root search bar
            XCTAssertTrue(any("resultsHeader").disappears(timeout: 5))
        }

        app.storeSearchField().tap()
        // One Featured banner where "Deals for you" was (owner, 2026-10-12).
        let banner = any("featuredBanner")
        XCTAssertTrue(banner.appears(timeout: 5), "no Featured banner on the search screen")
        XCTAssertTrue(banner.label.hasPrefix("Featured: "), banner.label)
        XCTAssertFalse(app.staticTexts["DEALS FOR YOU"].exists, "the old deals row is back")
        XCTAssertFalse(any("searchDeal").exists, "the old deal cards are back")
        // VoiceOver stays on search: Home underneath is out of reach.
        XCTAssertFalse(any("homeChips").exists, "Home's chips are reachable behind search")
        XCTAssertFalse(any("heroBrand").exists, "Home's hero is reachable behind search")
        let recents = app.buttons.matching(identifier: "recentSearch")
        XCTAssertEqual(recents.count, 3, "should show exactly the last 3 searches")
        // It fits: centred, full width, and above the keyboard with the
        // recent searches (the 798f955 overflow lesson).
        let window = app.windows.firstMatch.frame
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.appears(timeout: 5))
        XCTAssertEqual(banner.frame.midX, window.midX, accuracy: 2, "the banner isn't centred")
        XCTAssertGreaterThanOrEqual(banner.frame.minX, window.minX - 0.5)
        XCTAssertLessThanOrEqual(banner.frame.maxX, window.maxX + 0.5)
        XCTAssertLessThanOrEqual(banner.frame.maxY, keyboard.frame.minY, "the banner runs under the keyboard")
        XCTAssertLessThan(recents.element(boundBy: 0).frame.maxY, keyboard.frame.minY, "the latest search is under the keyboard")
        XCTAssertEqual(recents.element(boundBy: 0).label, "candle")
        snap("searchIdle", settle: 1)

        app.buttons.matching(identifier: "removeSearch").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["candle"].disappears(timeout: 3))
        XCTAssertEqual(recents.element(boundBy: 0).label, "hoodie")
        XCTAssertEqual(recents.count, 3, "the 4th search should move up after a removal")

        any("searchBack").tap()
        XCTAssertTrue(any("categoryRow.bags").appears(timeout: 5), "the ✕ should land back on Browse")
    }

    func testTypingSuggestsTrendingThenMatchingCategories() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))

        // Which kinds are trending is live data: it is the ten hottest by the
        // brands' own best-seller order, so it moves every time the catalog is
        // rebuilt. This test used to name one ("crossbody bag") and started
        // failing the day it slipped out of the ten. Try a few deep, popular
        // kinds instead and assert the ordering on whichever is hot today.
        let trending = app.buttons.matching(identifier: "trendingSuggestion")
        let plain = app.buttons.matching(identifier: "suggestion")
        var term = ""
        // Widened 2026-10-17, when none of the first four was in the ten.
        for candidate in ["candle", "earring", "dress", "bag", "shirt", "necklace", "hoodie", "serum", "soap", "ring", "hat", "oil"] {
            input.typeText(candidate)
            if trending.firstMatch.appears(timeout: 3) { term = candidate; break }
            app.buttons["Clear search"].tap()
        }
        XCTAssertFalse(term.isEmpty, "none of the deepest product kinds was trending")
        XCTAssertTrue(plain.firstMatch.exists, "no other matching suggestions for '\(term)'")
        XCTAssertLessThan(trending.element(boundBy: trending.count - 1).frame.minY,
                          plain.element(boundBy: 0).frame.minY, "trending picks should come first")
        for row in trending.allElementsBoundByIndex + plain.allElementsBoundByIndex {
            XCTAssertTrue(row.label.lowercased().contains(term), "'\(row.label)' doesn't match '\(term)'")
        }
        snap("searchSuggestions", settle: 2)

        // "+" puts the phrase in the field to keep typing.
        let first = trending.element(boundBy: 0).label
        app.buttons.matching(identifier: "suggestionFill").element(boundBy: 0).tap()
        XCTAssertEqual(input.value as? String, first + " ")

        // A category suggestion opens that category.
        app.buttons["Clear search"].tap()
        input.typeText("bag")
        let bags = app.buttons["bags"]
        XCTAssertTrue(bags.appears(timeout: 5), "no 'bags' category suggestion")
        bags.tap()
        XCTAssertTrue(input.disappears(timeout: 3), "search stayed open")
        XCTAssertTrue(any("productTile").appears(timeout: 5), "the Bags category didn't open")
    }

    func testBritishProductKeepsPoundsThroughCartAndOrderHistory() {
        app.terminate()
        app.launchArguments += ["-OFFLINE_CATALOG"]
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("Maya Njie\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 5))
        any("resultTitle").tap()
        XCTAssertTrue(any("addToCart").appears(timeout: 5))
        // The price element reads in words for VoiceOver ("12 pounds"); the
        // printed text still carries "£".
        let pounds = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "£", "pound")).firstMatch
        XCTAssertTrue(pounds.exists, "British product price lost its currency")
        // On a 6.3" screen the button sits under the floating tab bar, where a
        // tap lands on the bar instead. Scroll it clear first, as a shopper would.
        let add = any("addToCart")
        for _ in 0..<3 where add.frame.maxY > app.buttons["tab.home"].frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        tapClearOfTabBar(add)
        tapTab("Cart")
        XCTAssertTrue(any("cartCheckout").appears(timeout: 5))
        XCTAssertTrue(pounds.exists, "Cart relabeled pounds as dollars")
        // Checkout hovers just above the tab bar, not a tab bar's height over
        // it, where it covered the items (owner screenshot, 2026-10-15).
        let gap = app.buttons["tab.home"].frame.minY - any("cartCheckout").frame.maxY
        XCTAssertTrue((0...40).contains(gap), "Checkout sits \(gap) pt above the tab bar")
        openBrandCheckout()
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("orderPlaced").appears(timeout: 5))
        tapTab("You")
        any("tileOrders").tap()
        // The price lives on the order's details, as on Amazon.
        XCTAssertTrue(any("orderRow").appears(timeout: 5))
        any("orderRow").tap()
        XCTAssertTrue(pounds.appears(timeout: 5), "Order details lost the purchase currency")
        // The tracking number comes from the order (the brand's emails),
        // never from the shopper (owner, 2026-10-05).
        XCTAssertFalse(any("orderAddTracking").exists, "the shopper is never asked for a tracking number")
    }

    func testAddToCartThenCheckoutAtBrand() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("cacao nectar eau de parfum\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 5))

        // Open the first in-stock result and add it.
        // A Scent & Fire bottle: a brand with a UCP endpoint, so the order is
        // built over UCP and tracked. The first "parfum" result moved to a
        // cart-link brand when the meaning vectors were rebuilt (2026-10-05).
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no in-stock result")
        result.tap()
        let add = any("addToCart")
        XCTAssertTrue(add.appears(timeout: 5))
        XCTAssertTrue(add.isEnabled, "in-stock result opened with Add to Cart disabled")
        snap("detail", settle: 2)
        tapClearOfTabBar(add)

        tapTab("Cart")
        // One hovering Checkout carrying the total, no button per brand
        // (owner, 2026-10-14).
        XCTAssertTrue(any("cartCheckout").appears(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "cartCheckout").count, 1, "a checkout button per brand is back")
        XCTAssertTrue(any("cartCheckout").label.hasPrefix("Checkout · "), any("cartCheckout").label)
        XCTAssertTrue(any("cartTotal").exists, "no total at the top of the bag")
        snap("cart", settle: 2)

        // Checkout opens inside the app; a placed order clears that brand from the cart.
        openBrandCheckout()
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("orderPlaced").appears(timeout: 5), "no order confirmation")
        tapTab("You")
        any("tileOrders").tap()
        XCTAssertTrue(any("orderProductImage").appears(timeout: 5), "completed order should show its purchased product image")
        XCTAssertTrue(any("ordersBuyAgain").exists, "Your Orders should offer Buy again")
        snap("order-products")

        // Amazon-style details: status, tracker, the order number (never the
        // raw gid), a summary, and the actions.
        any("orderRow").tap()
        XCTAssertTrue(any("orderTracker").appears(timeout: 5), "order details didn't open")
        // One back button and one title, the navigation bar's (owner, 2026-10-26).
        // The bar's title element holds a view in the app's typeface
        // (`barTitle`), so the words are in the bar twice over for XCUITest;
        // VoiceOver reads the outer one. None may be in the page under it.
        let said = NSPredicate(format: "label == 'Order details'")
        XCTAssertEqual(app.staticTexts.matching(said).count, app.navigationBars.staticTexts.matching(said).count, "Order details said again under the bar")
        XCTAssertFalse(any("orderBackToOrders").exists, "a second back button under the bar")
        XCTAssertTrue(any("orderStatus").label.hasPrefix("Ordered"), any("orderStatus").label)
        XCTAssertTrue(any("orderTrackPackage").exists, "a review-built order should link to the brand's status page")
        let number = any("orderNumber")
        XCTAssertTrue(number.exists)
        XCTAssertTrue(number.label.hasPrefix("Shopify order ID "), number.label)
        XCTAssertFalse(number.label.contains("gid://"), number.label)
        XCTAssertTrue(any("orderCopyDetails").exists, "Order details should offer Copy order details")
        XCTAssertTrue(any("orderSummary").exists)
        // Everything stays in the app: store and product links, plus the
        // stubbed payment and delivery lines; only "Contact <brand>" leaves.
        XCTAssertTrue(any("orderViewStore").exists)
        XCTAssertTrue(any("orderPayment").exists && any("orderDelivery").exists)
        XCTAssertTrue(any("orderShippingNote").exists)
        snap("order-details")
        app.swipeUp()
        snap("order-summary")
        // Receipt prints in a sheet with a PAID stamp, then tears off and
        // prints again (owner, 2026-10-23).
        let receipt = any("orderReceipt")
        for _ in 0..<3 where !receipt.isHittable { app.swipeUp() }
        receipt.tap()
        XCTAssertTrue(any("receiptReprint").appears(timeout: 5), "the receipt didn't finish printing")
        XCTAssertTrue(any("receiptPaper").exists && any("receiptStamp").exists)
        snap("order-receipt")
        any("receiptTear").tap()
        XCTAssertTrue(any("receiptPrint").appears(timeout: 3), "tearing should offer a fresh print")
        any("receiptPrint").tap()
        XCTAssertTrue(any("receiptReprint").appears(timeout: 5))
        any("receiptCopy").tap()
        XCTAssertTrue(app.buttons["receiptCopy"].label.contains("Copied"), app.buttons["receiptCopy"].label)
        any("receiptClose").tap()
        XCTAssertTrue(any("receiptPaper").disappears(timeout: 5))
        app.swipeDown()
        if any("orderBuyAgain").exists {
            any("orderBuyAgain").tap()
            XCTAssertTrue(any("orderAddedToast").appears(timeout: 3) || any("addToCart").appears(timeout: 3),
                          "Buy it again should add to the cart or open the product to pick options")
        }
    }

    /// The bag's total includes each brand's standard shipping, quoted by
    /// its store for the saved address: $5 Standard over UCP, $7 from a
    /// Shopify storefront without UCP (both stubbed). Checkout
    /// then pays the brands one at a time (owner, 2026-10-14).
    func testBagTotalIncludesStandardShippingThenPaysEachBrand() {
        launchSeeded(["octavia-morgan", "black-butterfly-bath-and-body"])
        let shipping = app.descendants(matching: .any).matching(identifier: "cartBrandShipping")
        let quoted = NSPredicate { _, _ in shipping.allElementsBoundByIndex.contains { $0.label.hasPrefix("Standard shipping $5.00 · Est. arrives ") } }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: quoted, object: nil)], timeout: 10), .completed,
                       "no $5 standard quote: \(shipping.allElementsBoundByIndex.map(\.label))")
        // A Shopify brand without UCP is priced from its storefront cart ($7 stub).
        let storefront = NSPredicate { _, _ in shipping.allElementsBoundByIndex.contains { $0.label == "Standard shipping $7.00" } }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: storefront, object: nil)], timeout: 10), .completed,
                       "no storefront quote: \(shipping.allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(any("cartShipping").label.contains("12 dollars"), any("cartShipping").label)
        XCTAssertTrue(any("cartTotal").label.hasPrefix("2 items: Total"), any("cartTotal").label)
        // The saved address itself, not just its ZIP; no subtotal row and no
        // tax or "added at checkout" notes (owner, 2026-10-16).
        XCTAssertEqual(any("cartShipTo").label, "Shipping to 12 Rue & Co #4, Apt 4B, Brooklyn, NY 11201")
        XCTAssertFalse(app.staticTexts["Subtotal"].exists, "the subtotal row came back")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Before sales tax'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'is added at checkout'")).firstMatch.exists)
        snap("bag-totals")

        any("cartCheckout").tap()
        XCTAssertTrue(any("checkoutPrefill").appears(timeout: 5))
        XCTAssertEqual(any("checkoutPrefill").label, "Filled in by the store", "a UCP brand should open the checkout its store built")
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("continueNext").appears(timeout: 5), "no continue card")
        XCTAssertTrue(any("continueNext").label.hasSuffix("(2 of 2)"), any("continueNext").label)
        any("continueNext").tap()
        XCTAssertTrue(any("checkoutPrefill").appears(timeout: 5), "Continue didn't open the second brand")
        XCTAssertTrue(any("checkoutPrefill").label.contains("O'Brien"), "the cart link wasn't filled in")
        any("stubCompleteOrder").tap()
        XCTAssertTrue(any("orderPlaced").appears(timeout: 5), "the last brand should end on the passing note")
        XCTAssertEqual(cartLineCount(), 0)
        XCTAssertFalse(any("cartCheckout").exists, "an empty bag has nothing to check out")
    }

    /// A store with nothing to price shipping before its checkout (Big
    /// Cartel) says so, and YEEZY's Swell store is quoted ($16.99 stub).
    func testStoresWithoutRatesSayShippingAtCheckout() {
        launchSeeded(["therenaebrand", "yeezy"])
        let shipping = app.descendants(matching: .any).matching(identifier: "cartBrandShipping")
        let settled = NSPredicate { _, _ in
            let labels = shipping.allElementsBoundByIndex.map(\.label)
            return labels.contains("Shipping at checkout") && labels.contains("Standard shipping $16.99")
        }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 10), .completed,
                       "\(shipping.allElementsBoundByIndex.map(\.label))")
    }

    /// Typing the street suggests addresses from Apple Maps; picking one fills
    /// city, state and ZIP (owner, 2026-10-04). Needs Apple's search service,
    /// so it's skipped, not failed, when no suggestion arrives (offline Mac).
    func testAddressSuggestionFillsCityStateAndZip() throws {
        // The form lives under You › Shipping address since checkout stopped
        // asking for it first (2026-11-02).
        XCTAssertTrue(app.appReady().appears(timeout: 10))
        openShippingDetails()
        let street = app.textFields["buyerStreet"]
        XCTAssertTrue(street.appears(timeout: 5))
        street.tap()
        street.typeText("1600 Pennsylvania Ave NW Washington")
        // The DC one by name: Apple's order varies (2026-10-19 the first was in NY).
        let suggestion = app.buttons.matching(NSPredicate(format: "identifier == 'addressSuggestion' AND label CONTAINS 'Washington, DC'")).firstMatch
        guard suggestion.appears(timeout: 15) else {
            throw XCTSkip("Apple Maps returned no suggestion (no network?)")
        }
        suggestion.tap()
        let postal = app.textFields["buyerPostal"]
        let filled = NSPredicate(format: "value != '' AND value != 'ZIP'")
        expectation(for: filled, evaluatedWith: postal)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.textFields["buyerRegion"].value as? String, "DC")
        XCTAssertFalse((app.textFields["buyerCity"].value as? String ?? "").isEmpty)
    }

    /// A Spotlight boost takes a carousel page labeled Sponsored, $20+ boosts
    /// fill "Boosted picks", and Boost shows on a brand page when boosts are
    /// open (owner, 2026-10-04). -BOOST_STUB stands in for the server.
    func testBoostedBrandShowsAsSponsored() {
        app.terminate()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-BOOST_STUB", "diarrablu"]
        app.launch()
        XCTAssertTrue(any("heroBrand").appears(timeout: 15))
        let sponsored = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Sponsored: '")).firstMatch
        XCTAssertTrue(sponsored.appears(timeout: 10), "the boosted brand should lead the carousel, labeled")
        XCTAssertTrue(any("sponsoredLabel").exists)
        XCTAssertTrue(any("boostedPicks").appears(timeout: 10), "Boosted picks row")
        sponsored.tap()
        // Boost lives in the brand page's ⋯ menu (owner, 2026-10-31).
        let more = any("brandMore")
        XCTAssertTrue(more.appears(timeout: 10), "the brand page's ⋯ menu")
        more.tap()
        let boost = app.buttons["Boost"]
        XCTAssertTrue(boost.appears(timeout: 5), "Boost in the ⋯ menu")
        // Boost opens the in-app choices: four tiers saying what each gives.
        boost.tap()
        XCTAssertTrue(any("boostSheet").appears(timeout: 5), "the Boost screen")
        let spotlight = any("boostTier100")
        XCTAssertTrue(spotlight.appears(timeout: 5))
        XCTAssertTrue(spotlight.label.contains("premier spot"), "the $100 tier says what it gives")
        spotlight.tap()
        XCTAssertTrue(app.buttons["boostContinue"].label.contains("$100"), "the button follows the choice")
    }

    /// Checkout goes straight to each brand's store (no Marracat form, owner
    /// 2026-11-02), and the address the first order shipped to is saved
    /// under You › Shipping address for the brands after it.
    func testCheckoutSavesTheFirstOrdersAddressThenPaysEachBrand() {
        for term in Self.checkoutTerms {
            XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
            app.storeSearchField().tap()
            let input = any("searchInput")
            XCTAssertTrue(input.appears(timeout: 5))
            input.typeText(term + "\n")
            // Results carry their own Add to cart; no need to open the product.
            let add = app.buttons["Add to cart"].firstMatch
            XCTAssertTrue(add.appears(timeout: 5), "no in-stock result for '\(term)'")
            add.tap()
            XCTAssertTrue(app.buttons["Added"].firstMatch.appears(timeout: 5))
            tapTab("Home")
        }
        tapTab("Cart")
        // First time: straight to the first brand's checkout, no form.
        openBrandCheckout()
        snap("bag-first-brand", settle: 1)
        // Every brand, one after another: the continue card between them,
        // the passing note after the last.
        for _ in 0..<Self.checkoutTerms.count {
            XCTAssertTrue(any("stubCompleteOrder").appears(timeout: 5), "brand checkout didn't open")
            any("stubCompleteOrder").tap()
            let next = any("continueNext"), note = any("orderPlaced")
            let shown = NSPredicate { _, _ in next.exists || note.exists }   // the note leaves after 4 s
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 5), .completed,
                           "no order confirmation")
            if next.exists { next.tap() } else { break }
        }
        XCTAssertEqual(cartLineCount(), 0, "every brand paid should empty the bag")

        // The first order's address was saved (the stub store "ships" to
        // 1 Main St, Brooklyn), and can be changed or forgotten under You.
        openShippingDetails()
        XCTAssertEqual(app.textFields["buyerStreet"].value as? String, "1 Main St")
        XCTAssertEqual(app.textFields["buyerPostal"].value as? String, "11201")
        // The form is a list: its last row exists only once scrolled to.
        for _ in 0..<4 where !any("buyerForget").exists { app.swipeUp() }
        XCTAssertTrue(any("buyerForget").exists, "saved details can be forgotten")
        app.buttons["Cancel"].tap()

        // The next checkout still goes straight to the brand's store, now
        // built with the saved address.
        for term in Self.checkoutTerms {
            tapTab("Home")
            XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
            app.storeSearchField().tap()
            XCTAssertTrue(any("searchInput").appears(timeout: 5))
            any("searchInput").typeText(term + "\n")
            let add = app.buttons["Add to cart"].firstMatch
            XCTAssertTrue(add.appears(timeout: 8), "no in-stock result for '\(term)'")
            add.tap()
            XCTAssertTrue(app.buttons["Added"].firstMatch.appears(timeout: 5))
        }
        tapTab("Cart")
        XCTAssertTrue(any("cartCheckout").appears(timeout: 5))
        any("cartCheckout").tap()
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 10), "saved details should go straight to the brand's checkout")
        XCTAssertFalse(any("buyerForm").exists)
    }

    /// Opt-in, like testRealCheckoutSheetLoads: builds a real checkout on a
    /// brand's store with nothing saved and confirms Checkout Kit renders the
    /// store's checkout page (the `continue_url`), which asks for the address
    /// itself (owner, 2026-11-02: no Marracat form first). No order is placed.
    func testRealBagOpensStoreCheckoutWithoutAForm() throws {
        guard ProcessInfo.processInfo.environment["REAL_CHECKOUT"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_REAL_CHECKOUT=1 to open a real checkout")
        }
        app.terminate()
        let real = XCUIApplication()
        real.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH"]   // no -CHECKOUT_STUB: real store, real Checkout Kit
        real.launch()
        func el(_ id: String) -> XCUIElement { real.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(el("searchInput").appears(timeout: 5))
        el("searchInput").typeText("parfum\n")
        XCTAssertTrue(el("resultTitle").appears(timeout: 5))
        el("resultTitle").tap()
        let add = el("addToCart")
        XCTAssertTrue(add.appears(timeout: 5))
        for _ in 0..<3 where add.frame.maxY > real.buttons["tab.home"].frame.minY - 4 {
            real.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        add.tap()
        real.buttons["tab.cart"].tap()
        XCTAssertTrue(el("cartCheckout").appears(timeout: 5))
        snap("realBag", settle: 4)   // the store's standard-shipping quote
        el("cartCheckout").tap()
        XCTAssertFalse(el("buyerForm").appears(timeout: 3), "no Marracat details form before the store's checkout")
        XCTAssertTrue(real.webViews.firstMatch.appears(timeout: 20), "Checkout Kit never showed the store's checkout")
        snap("realCheckoutNoForm", settle: 8)
        // The store's own page asks for the address (Shop Pay / Apple Pay fill it).
        let asks = real.webViews.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", "Address", "Address")).firstMatch
        XCTAssertTrue(asks.appears(timeout: 15), "the store's checkout didn't ask for the address")
    }

    /// Telfar can't take a cart link: Buy Now asks for details once, then
    /// opens the store's own checkout for that item.
    func testUCPOnlyBrandBuyNowGoesThroughReview() {
        XCTAssertTrue(app.storeSearchField().appears(timeout: 10))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("telfar laundry bag\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 5), "no in-stock Telfar result")
        result.tap()
        let buy = any("buyNow")
        XCTAssertTrue(buy.appears(timeout: 5))
        for _ in 0..<3 where buy.frame.maxY > app.buttons["tab.home"].frame.minY - 4 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        buy.tap()
        // Straight to the store's checkout: no Marracat details form first
        // (owner, 2026-11-02); the store asks for the address.
        XCTAssertFalse(any("buyerForm").appears(timeout: 2), "Buy Now shouldn't ask for details")
        XCTAssertTrue(any("checkoutSheet").appears(timeout: 10), "Telfar's checkout didn't open")
    }
}
