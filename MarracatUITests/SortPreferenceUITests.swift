import XCTest

/// A shopper who sorts a search by price low to high gets the next search
/// sorted the same way (owner, 2026-11-16: "lets auto sort for users who do
/// that because price seems to be an important feature").
final class SortPreferenceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB"]
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func search(_ text: String) {
        let field = app.storeSearchField()
        XCTAssertTrue(field.appears(timeout: 15))
        field.tap()
        let input = any("searchInput")
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText(text + "\n")
        XCTAssertTrue(any("resultsHeader").appears(timeout: 10), "no results for \(text)")
    }

    func testSortingByLowPriceCarriesToTheNextSearch() {
        search("heels")
        XCTAssertFalse(any("sortButton").label.contains("low to high"), "nobody starts sorted")
        any("sortButton").tap()
        let option = app.buttons["Price: low to high"]
        XCTAssertTrue(option.appears(timeout: 5))
        option.tap()
        XCTAssertTrue(any("sortButton").label.contains("low to high"))

        search("necklace")
        XCTAssertTrue(any("sortButton").appears(timeout: 5))
        XCTAssertTrue(any("sortButton").label.contains("low to high"),
                      "the next search should open sorted low to high: \(any("sortButton").label)")
    }
}
