import XCTest

/// Siri, Shortcuts and Spotlight open screens through the same marracat://
/// links (AppDestination, owner 2026-10-14). Siri itself can't be driven in
/// the simulator; the links are what its intents and Spotlight's results
/// land on, so each one must open its screen — from a cold app and from
/// another tab.
final class SiriSpotlightUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"   // MarracatUITestCase.setUp
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func text(_ label: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testLinksOpenTheScreensSiriAndSpotlightAskFor() {
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("brandWebsite").appears(timeout: 20), "the brand page didn't open")
        XCTAssertTrue(any("brandWebsite").exists)

        app.open(URL(string: "marracat://deals")!)
        XCTAssertTrue(text("Deals").appears(timeout: 10), "Deals didn't open")

        app.open(URL(string: "marracat://category/hair")!)
        XCTAssertTrue(text("Hair Care").appears(timeout: 10), "the department didn't open")
        XCTAssertTrue(app.buttons["tab.browse"].isSelected, "departments open under Browse")

        app.open(URL(string: "marracat://orders")!)
        XCTAssertTrue(text("Your Orders").appears(timeout: 10), "Your Orders didn't open")

        app.open(URL(string: "marracat://search?q=shea%20butter")!)
        // The results page is titled with the search, and its magnifier
        // reopens search to change it (the bar left the header 2026-10-20).
        XCTAssertTrue(app.buttons["editSearch"].appears(timeout: 10), "the results page didn't open")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'shea butter'")).firstMatch.appears(timeout: 10),
                      "the search didn't run")
    }
}
