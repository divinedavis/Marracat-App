import XCTest

/// The Home Screen widgets open screens through marracat:// links
/// (Shared/WidgetSnapshot.swift: WidgetLink). XCUITest can't add a widget to
/// the Home Screen reliably, so this drives the links a tapped widget sends:
/// an order row (marracat://order?brand=…&order=…) and the empty states'
/// Deals and Your Orders. WidgetTests checks every link the widgets build
/// parses to the same destinations.
final class WidgetLinkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"   // MarracatUITestCase.setUp
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launch()
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testWidgetLinksOpenOrdersAndDeals() {
        // An order this phone has no record of (the widget was written before
        // a sign-out) lands on Your Orders rather than nowhere.
        app.open(URL(string: "marracat://order?brand=telfar&order=1042")!)
        XCTAssertTrue(text("Your Orders").appears(timeout: 20), "the order row didn't open Your Orders")

        app.open(URL(string: "marracat://deals")!)
        XCTAssertTrue(text("Deals").appears(timeout: 10), "the price-drop empty state didn't open Deals")

        app.open(URL(string: "marracat://orders")!)
        XCTAssertTrue(text("Your Orders").appears(timeout: 10), "the orders empty state didn't open Your Orders")
    }
}
