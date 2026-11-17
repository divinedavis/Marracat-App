import XCTest

/// Shopping alerts (owner, 2026-11-15): our own banner while the app is open,
/// with working buttons; and the brand page's rail folding into ⋯ on the way
/// down, with the same four in the ⋯ menu ("Brand header 1 - Converge").
final class ShoppingAlertsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-DEAL_ALERTS_STUB"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testAnAlertWhileTheAppIsOpenIsOurBannerAndItsButtonOpensTheProduct() {
        app.terminate()
        app.launchArguments.append("-UITEST_ALERT")   // a back-in-stock card once the catalog is in
        app.launch()
        let banner = any("inAppAlert")
        XCTAssertTrue(banner.appears(timeout: 25), "the alert's card should slide in over the app")
        XCTAssertLessThan(banner.frame.minY, app.windows.firstMatch.frame.midY, "at the top of the screen")
        let view = any("alertButton_open")
        XCTAssertTrue(view.exists, "View, next to Add to bag")
        XCTAssertTrue(any("alertButton_add").exists)
        view.tap()
        XCTAssertTrue(banner.disappears(timeout: 5), "a tapped banner goes away")
        XCTAssertTrue(any("visitStore").appears(timeout: 10), "View opens the product page")
    }

    func testTheBrandRailFoldsIntoMoreAndTheMenuHasItsButtons() {
        app.open(URL(string: "marracat://brand/telfar")!)
        let website = any("brandWebsite")
        XCTAssertTrue(website.appears(timeout: 20))
        XCTAssertTrue(website.isHittable)
        // The menu has the rail's buttons above Share, wherever the page is.
        any("brandMore").tap()
        for id in ["brandMenuWebsite", "brandMenuSaleAlerts", "brandMenuWatchDrops"] {
            XCTAssertTrue(any(id).appears(timeout: 5), "\(id) in the ⋯ menu")
        }
        XCTAssertTrue(app.buttons["Share"].exists, "Share still in the ⋯ menu")
        any("brandMenuSaleAlerts").tap()
        XCTAssertTrue(any("saleAlerts").appears(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { self.any("saleAlerts").label == "Sale alerts on" }, "the menu turned sale alerts on")
        // Scrolled down, the rail has gone into ⋯ and can't be tapped.
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 5) { !website.exists || !website.isHittable }, "the rail should fold away on the way down")
        XCTAssertTrue(any("brandMore").isHittable, "the ⋯ is still there")
        // And back on the way up.
        app.swipeDown(); app.swipeDown()
        XCTAssertTrue(waitUntil(timeout: 5) { website.exists && website.isHittable }, "the rail comes back at the top")
    }
}
