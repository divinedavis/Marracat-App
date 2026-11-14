import XCTest

/// You › Your taste (owner, 2026-11-08): what's been learned, in words, with a
/// way to correct it; and the size a shopper picks is remembered for the next
/// product page ("4: lets remember the sizes").
final class YourTasteUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func openYourTaste() {
        app.buttons["tab.you"].tap()
        // The second time, You is still showing the screen.
        guard !app.navigationBars["Your taste"].exists else { return }
        let row = any("yourTasteRow")
        XCTAssertTrue(row.appears(timeout: 10), "no Your taste row in You")
        row.tap()
    }

    func testYourTasteStartsEmptyThenShowsTheSizeAddedToTheBag() {
        app.launch()
        XCTAssertTrue(app.appReady().appears(timeout: 60))
        openYourTaste()
        XCTAssertTrue(any("tasteEmpty").appears(timeout: 5), "a new shopper is told how it fills in")

        // A sized product into the bag: its size is remembered.
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 30))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("Fear of God hoodie\n")
        XCTAssertTrue(any("resultTitle").appears(timeout: 10))
        any("resultTitle").tap()
        let add = app.buttons["addToCart"]
        XCTAssertTrue(add.appears(timeout: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: add)], timeout: 20), .completed,
                       "the hoodie's sizes didn't load")
        add.tap()

        openYourTaste()
        let size = any("tasteSize")
        XCTAssertTrue(size.appears(timeout: 10), "the size added to the bag shows under Your sizes")
        XCTAssertTrue(size.label.contains("Clothing") || app.staticTexts["Clothing"].exists, size.label)
        any("forgetSize").tap()
        XCTAssertTrue(size.disappears(timeout: 5), "Forget removes it")
    }
}
