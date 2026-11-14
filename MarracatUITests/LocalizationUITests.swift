import XCTest

/// The app in another language and in a right-to-left layout (2026-10-14,
/// when the String Catalog shipped). German is the long-words case: labels
/// must be translated and still fit. Right-to-left uses the system's forced
/// RTL switches rather than Arabic, so it runs whether or not Arabic is
/// translated yet; what's checked is that the layout mirrors.
final class LocalizationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"   // MarracatUITestCase.setUp
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func launchBag(_ extra: [String]) {
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG",
                               "-SEED_BUYER", "-SEED_CART", "octavia-morgan,black-butterfly-bath-and-body"] + extra
        app.launch()
        let cart = app.buttons["tab.cart"]
        XCTAssertTrue(cart.appears(timeout: 15))
        cart.tap()
        XCTAssertTrue(any("cartCheckout").appears(timeout: 15), "the bag didn't open")
    }

    func testGermanBagIsTranslatedAndFits() {
        launchBag(["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"])
        let screen = app.windows.firstMatch.frame
        // Translated: the tab bar, the total and Checkout aren't English.
        XCTAssertNotEqual(app.buttons["tab.cart"].label, "Cart")
        XCTAssertNotEqual(app.buttons["tab.home"].label, "Home")
        let checkout = any("cartCheckout")
        XCTAssertFalse(checkout.label.hasPrefix("Checkout"), checkout.label)
        XCTAssertFalse(any("cartTotal").label.contains("items"), any("cartTotal").label)
        // Fits: the hovering button and every tab stay on screen.
        XCTAssertTrue(screen.contains(checkout.frame), "Checkout runs off screen: \(checkout.frame)")
        for tab in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex {
            XCTAssertTrue(screen.contains(tab.frame), "\(tab.identifier) runs off screen")
        }
        // A brand's shipping line, quoted in German.
        let shipping = app.descendants(matching: .any).matching(identifier: "cartBrandShipping")
        let quoted = NSPredicate { _, _ in shipping.count > 0 && !shipping.firstMatch.label.hasPrefix("Standard shipping") && !shipping.firstMatch.label.isEmpty }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: quoted, object: nil)], timeout: 10), .completed,
                       shipping.firstMatch.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "bag-de"; shot.lifetime = .keepAlways
        add(shot)
    }

    func testRightToLeftLayoutMirrors() {
        launchBag(["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"])
        let screen = app.windows.firstMatch.frame
        // Leading is the right edge now: a brand's shipping line, which
        // starts at the leading edge, sits in the right half.
        let line = any("cartBrandShipping")
        XCTAssertTrue(line.appears(timeout: 10))
        XCTAssertGreaterThan(line.frame.maxX, screen.width * 0.8, "the bag didn't mirror: \(line.frame)")
        XCTAssertTrue(screen.contains(any("cartCheckout").frame))
        // Home renders mirrored too.
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.homeReady().appears(timeout: 10), "Home didn't render right-to-left")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "home-rtl"; shot.lifetime = .keepAlways
        add(shot)
    }
}
