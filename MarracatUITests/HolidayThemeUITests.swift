import XCTest

/// Holiday themes (owner, 2026-10-20): `-HOLIDAY <id>` dresses the app for a
/// day whatever the date. The splash names it, and an event's link opens the
/// day's collection.
final class HolidayThemeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testKwanzaaSplashNamesTheDay() {
        app.launchArguments = ["-UITEST_RESET", "-OFFLINE_CATALOG", "-SPLASH_SECONDS", "6", "-HOLIDAY", "kwanzaa"]
        app.launch()
        let splash = any("splash")
        XCTAssertTrue(splash.appears(timeout: 10), "no splash")
        XCTAssertEqual(splash.label, "MARRACAT, Kwanzaa")
    }

    /// MLK Day: a day with no Home rows, so the title found is the opened
    /// collection's, not a row's on Home.
    func testAnEventLinkOpensItsCollection() {
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-HOLIDAY", "mlk"]
        app.launch()
        app.open(URL(string: "marracat://collection/mlk-day")!)
        // The grid's title is a heading in the page, as on Deals.
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'Honoring Dr. King'")).firstMatch
        XCTAssertTrue(title.appears(timeout: 20), "the MLK Day collection didn't open")
        XCTAssertTrue(app.buttons["tab.home"].exists, "the tab bar is there in the day's colours")
    }

    /// While an event runs, Home opens with its banner and rows (owner,
    /// 2026-10-27), and the banner opens the first row's whole list.
    func testHalloweenRowsLeadHome() {
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-HOLIDAY", "halloween"]
        app.launch()
        let banner = any("eventBanner")
        XCTAssertTrue(banner.appears(timeout: 20), "no Halloween banner on Home")
        let row = any("eventRow")
        XCTAssertTrue(row.exists, "no Halloween row on Home")
        XCTAssertTrue(row.descendants(matching: .any).matching(identifier: "productTile").firstMatch.exists, "the row is empty")
        banner.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !banner.exists || !banner.isHittable }, "the banner didn't open its list")
    }
}
