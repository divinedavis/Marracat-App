import XCTest

/// Search placement (owner, 2026-10-20, after IMDb): no search on Home;
/// store search floats above the tab bar on Browse and opens full screen with
/// Recent and Advanced Search and the field at the bottom; You searches its
/// own rows and settings.
final class SearchPlacementUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func testStoreSearchLivesOnBrowseNotHome() {
        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.appears(timeout: 15))
        XCTAssertTrue(any("heroBrand").appears(timeout: 15), "Home didn't load")
        XCTAssertFalse(any("searchField").exists, "Home has no search bar")

        app.buttons["tab.browse"].tap()
        let field = any("searchField")
        XCTAssertTrue(field.appears(timeout: 5), "Browse has the search bar")
        XCTAssertFalse(app.navigationBars["Browse"].exists, "no Browse header (owner, 2026-10-21)")
        XCTAssertGreaterThan(field.frame.minY, app.frame.height * 0.7, "it floats at the bottom, above the tab bar")
        XCTAssertLessThan(field.frame.maxY, home.frame.minY, "above the tab bar, not over it")

        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        XCTAssertTrue(any("searchMode").exists, "Recent / Advanced Search at the top")
        XCTAssertGreaterThan(input.frame.minY, app.frame.height * 0.4, "the field sits down on the keyboard")

        // Advanced Search narrows before it runs.
        app.buttons["Advanced Search"].tap()
        app.buttons["Under $25"].tap()
        input.typeText("candle")
        any("advancedSearchGo").tap()
        XCTAssertTrue(any("editSearch").appears(timeout: 10), "the results didn't open")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'candle'")).firstMatch.exists)

        // The ✕ beside the field closes search.
        any("editSearch").tap()
        XCTAssertTrue(input.appears(timeout: 5))
        any("searchBack").tap()
        XCTAssertTrue(input.disappears(timeout: 5), "✕ didn't close search")
    }

    func testCartHasNoHeader() {
        app.buttons["tab.cart"].tap()
        XCTAssertFalse(app.navigationBars["Cart"].exists, "no Cart header (owner, 2026-10-21)")
    }

    func testYouSearchesItsOwnSettings() {
        app.buttons["tab.you"].tap()
        let field = app.textFields["youSearch"]
        XCTAssertTrue(field.appears(timeout: 10), "You has its own search bar")
        XCTAssertFalse(any("searchField").exists, "not the store search")
        field.tap()
        field.typeText("icon")
        let result = app.buttons.matching(NSPredicate(format: "identifier == 'youResult' AND label CONTAINS 'Holiday app icons'")).firstMatch
        XCTAssertTrue(result.appears(timeout: 5), "settings one screen in are found too")
        XCTAssertFalse(any("profileCard").exists, "the page narrows to the matches")
        result.tap()
        let toggle = any("holidayIconsToggle")
        XCTAssertTrue(toggle.appears(timeout: 10), "it opens where the setting lives")
        XCTAssertEqual(toggle.value as? String, "1", "holiday icons are on by default (owner, 2026-10-20)")
    }

    /// Typing, the bar takes iMessage's measurements (owner, 2026-10-22): a
    /// 48pt ✕ circle 8pt from the screen's right edge.
    func testSearchCloseButtonSitsLikeIMessage() {
        app.buttons["tab.you"].tap()
        let field = app.textFields["youSearch"]
        XCTAssertTrue(field.appears(timeout: 10))
        field.tap()
        let close = app.buttons["youSearchClose"]
        XCTAssertTrue(close.appears(timeout: 5), "the ✕ slides in while typing")
        let window = app.windows.firstMatch.frame
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "search-typing"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(close.frame.width, 48, accuracy: 1)
        XCTAssertEqual(close.frame.height, 48, accuracy: 1)
        XCTAssertEqual(window.maxX - close.frame.maxX, 8, accuracy: 2, "8pt from the right edge")
        close.tap()
        XCTAssertTrue(close.disappears(timeout: 5), "the ✕ leaves with the keyboard")
    }
}
