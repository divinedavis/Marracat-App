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

    /// While an event runs, Home leads with its big tiles (owner, 2026-11-23:
    /// "Target has some promotional tiles that are big, we don't"; of the
    /// previews, "I like #3"): as wide as a Home product card, taller than
    /// wide, one height, and a tile opens its list.
    func testHalloweenTilesLeadHome() {
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-HOLIDAY", "halloween"]
        app.launch()
        let row = any("eventTiles")
        XCTAssertTrue(row.appears(timeout: 20), "no Halloween tiles on Home")
        let tiles = app.descendants(matching: .any).matching(identifier: "eventTile")
        let first = tiles.firstMatch
        XCTAssertTrue(first.exists, "the row is empty")
        XCTAssertFalse(any("eventBanner").exists, "the banner only stands in when there are no tiles")
        let window = app.windows.firstMatch.frame.width
        XCTAssertEqual(first.frame.width, min((window * 0.8).rounded(), 360), accuracy: 1, "a tile is as wide as a Home product card")
        XCTAssertGreaterThan(first.frame.height, first.frame.width, "a tile is tall")
        let frames = tiles.allElementsBoundByIndex.map(\.frame)
        XCTAssertEqual(Set(frames.map { $0.height.rounded() }).count, 1, "tiles in a row are one height: \(frames)")
        XCTAssertEqual(Set(frames.map { $0.minY.rounded() }).count, 1, "and sit side by side: \(frames)")
        XCTAssertTrue(first.label.contains("Halloween Picks"), "the tile names its event: \(first.label)")
        XCTAssertFalse(first.label.contains("$"), "the price is spoken in words: \(first.label)")
        first.tap()
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'Halloween picks'")).firstMatch
        XCTAssertTrue(waitUntil(timeout: 10) { title.exists && !first.isHittable }, "the tile didn't open its list")
    }
}
