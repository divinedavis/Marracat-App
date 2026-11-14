import XCTest

/// Drives the App Store preview: a paced walk across several departments
/// (body wash, hair, home, jewelry, fragrance), not just clothes, while the simulator
/// is recorded with `simctl io recordVideo`. It also saves stills for the
/// screenshot gallery. Opt-in with TEST_RUNNER_MARRACAT_TOUR=1 so the
/// release suite never pays its minute of sleeps.
final class AppStoreTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MARRACAT_TOUR"] == "1" || env["MARRACAT_CPP_TOUR"] == "1",
                          "App Store tour is opt-in (TEST_RUNNER_MARRACAT_TOUR=1)")
        continueAfterFailure = false
        app = XCUIApplication()
        // Splash kept on purpose: the video opens on the wordmark.
        app.launchArguments = ["-UITEST_RESET", "-CHECKOUT_STUB"]
    }

    func testAppStoreTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARRACAT_TOUR"] == "1", "opt-in")
        // Alerts stubbed so the brand page's bell works signed out.
        app.launchArguments += ["-DEAL_ALERTS_STUB"]
        app.launch()
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 30), "Home never populated")
        pause(3)
        snap("home")
        app.swipeUp(velocity: .slow)
        pause(1.5)
        app.swipeDown(velocity: .slow)
        pause(1)

        // Browse: every department at a glance.
        tapTab("Browse")
        XCTAssertTrue(app.staticTexts["Shop by category"].waitForExistence(timeout: 5))
        pause(2)
        snap("browse")

        // Hair → an aisle → a product → cart.
        let hair = any("categoryRow.hair")
        XCTAssertTrue(hair.waitForExistence(timeout: 5))
        hair.tap()
        let aisle = app.buttons.matching(identifier: "subcategory").firstMatch
        XCTAssertTrue(aisle.waitForExistence(timeout: 5))
        pause(1.5)
        snap("hair-aisles")
        aisle.tap()
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 5))
        pause(2.5)
        snap("hair-grid")

        // The $3,275 pendant is shown, not bagged: in the cart it made the
        // total read $3,383 (owner's listing review, 2026-11-01).
        for (term, name, pick, bag) in [("body wash", "bodywash", 0, true), ("candle", "home", 0, true),
                                         ("gold necklace", "jewelry", 2, false), ("parfum", "fragrance", 0, true)] {
            search(term)
            pause(2.5)
            snap("\(name)-results")
            let result = app.descendants(matching: .any).matching(identifier: "resultTitle").element(boundBy: pick)
            XCTAssertTrue(result.waitForExistence(timeout: 5), "no result for \(term)")
            result.tap()
            let add = any("addToCart")
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            pause(2.5)
            snap("\(name)-detail")
            // Scrolled: the bar carries the product's name and the actions
            // sit in one bar of symbols (owner, 2026-11-01).
            app.swipeUp(velocity: .slow)
            pause(2)
            snap("\(name)-detail-scrolled")
            app.swipeDown(velocity: .slow)
            pause(1)
            if bag && add.isEnabled { add.tap() }
            pause(1)
        }

        // The store card → the brand's page, its bell, and its name centred
        // in the bar once the photo scrolls away (2026-11-01).
        let store = any("visitStore")
        if store.waitForExistence(timeout: 5) {
            store.tap()
            let sale = any("saleAlerts")
            XCTAssertTrue(sale.waitForExistence(timeout: 10), "the store card should open the brand page")
            pause(2.5)
            snap("brand")
            sale.tap()
            pause(1)
            snap("brand-sale-alert")
            pause(1.5)
            app.swipeUp(velocity: .slow)
            pause(2)
            snap("brand-scrolled")
        }

        tapTab("Cart")
        XCTAssertTrue(any("cartCheckout").waitForExistence(timeout: 5))
        pause(2.5)
        snap("cart")
    }

    /// Stills for the custom product pages (owner, 2026-10-11): beauty, gifts,
    /// and deals with price and sale alerts. Opt-in with
    /// TEST_RUNNER_MARRACAT_CPP_TOUR=1 (it replaces the TOUR switch for this
    /// test) and TEST_RUNNER_MARRACAT_SHOT_DIR.
    func testCustomPageTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARRACAT_CPP_TOUR"] == "1", "opt-in")
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-DEAL_ALERTS_STUB"]
        app.launch()
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 30), "Home never populated")
        pause(4)
        snap("cpp-home")

        // Deals: the department chip, a deal, Track price, the brand's sale alerts.
        app.buttons["Deals"].firstMatch.tap()
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 10))
        pause(3)
        snap("cpp-deals")
        app.buttons.matching(identifier: "productTile").element(boundBy: 0).tap()
        let track = any("trackPrice")
        XCTAssertTrue(track.waitForExistence(timeout: 10))
        pause(2.5)
        snap("cpp-deal-detail")
        // The action chips sit below the fold (testTrackPricePromptAndAlertButtons).
        app.swipeUp()
        pause(1)
        track.tap()
        pause(1.2)
        snap("cpp-deal-tracked")
        let store = any("visitStore")
        if store.waitForExistence(timeout: 5) {
            store.tap()
            let sale = any("saleAlerts")
            if sale.waitForExistence(timeout: 10) {
                sale.tap()
                pause(2)
                snap("cpp-brand-sale-alerts")
            }
        }
        tapTab("You")
        let row = any("priceAlertsRow")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        _ = any("priceAlert").waitForExistence(timeout: 5)
        pause(1.5)
        snap("cpp-price-alerts")

        // Skincare: the department's aisles and one aisle.
        tapTab("Browse")
        let skin = any("categoryRow.skincare")
        XCTAssertTrue(skin.waitForExistence(timeout: 5))
        skin.tap()
        let aisle = app.buttons.matching(identifier: "subcategory").firstMatch
        XCTAssertTrue(aisle.waitForExistence(timeout: 5))
        pause(2)
        snap("cpp-skincare-aisles")
        aisle.tap()
        XCTAssertTrue(any("productTile").waitForExistence(timeout: 5))
        pause(2.5)
        snap("cpp-skincare-grid")

        for (term, name, pick) in [("body butter", "bodybutter", 0), ("shampoo", "shampoo", 0), ("gold necklace", "necklace", 2),
                                   ("candle", "candle", 0), ("gift set", "giftset", 0)] {
            search(term)
            pause(2.5)
            snap("cpp-\(name)-results")
            let result = app.descendants(matching: .any).matching(identifier: "resultTitle").element(boundBy: pick)
            guard result.waitForExistence(timeout: 5) else { continue }
            result.tap()
            let add = any("addToCart")
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            pause(2.5)
            snap("cpp-\(name)-detail")
            if add.isEnabled { add.tap() }
            pause(1)
        }
        tapTab("Cart")
        _ = any("cartCheckout").waitForExistence(timeout: 5)
        pause(2.5)
        snap("cpp-cart")
    }

    private func search(_ term: String) {
        tapTab("Home")
        tapTab("Home")   // second tap pops to the top of Home
        let field = app.storeSearchField()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        for ch in term { input.typeText(String(ch)); usleep(90_000) }   // visible typing
        input.typeText("\n")
        XCTAssertTrue(any("resultsHeader").waitForExistence(timeout: 5))
    }

    private func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapTab(_ name: String) {
        let tab = app.buttons["tab.\(name.lowercased())"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(name) tab missing")
        tab.tap()
    }

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] else { return }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
