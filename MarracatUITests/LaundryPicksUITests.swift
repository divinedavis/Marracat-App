import XCTest

/// A shopper who likes a laundry detergent gets more for their laundry on
/// Home, other brands' and the same brand's (owner, 2026-11-09: "if someone
/// buys, searches or likes a laundry item they should see items that match
/// well with that like different laundry detergent brands, the same
/// detergent brands but different items like dryer sheets"), and Home's
/// personal rows stay in the departments they've touched ("if they never
/// purchase dog food or search for it we should never show it").
final class LaundryPicksUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testLikingADetergentBringsMoreForTheLaundryAndNothingUntouched() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("laundry detergent\n")
        let result = any("resultTitle")
        XCTAssertTrue(result.appears(timeout: 10), "no laundry detergent results")
        result.tap()
        let save = app.buttons["addToList"].firstMatch
        XCTAssertTrue(save.appears(timeout: 10))
        save.tap()
        XCTAssertTrue(app.buttons["addToList"].firstMatch.label.contains("Saved"), "the detergent wasn't saved")

        // A fresh Home from that history.
        app.terminate()
        app.launchArguments = ["-SPLASH_SECONDS", "0"]
        app.launch()
        XCTAssertTrue(app.homeReady().appears(timeout: 60))
        let more = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'More for your'")).firstMatch
        var titles: Set<String> = []
        func readTitles() {
            for t in app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Top picks in'")).allElementsBoundByIndex where t.exists {
                titles.insert(t.label)
            }
        }
        for _ in 0..<12 where !more.isHittable { app.swipeUp(velocity: .slow); readTitles() }
        XCTAssertTrue(more.isHittable, "no More for your laundry row on Home")
        shot("Home: More for your laundry")
        for _ in 0..<20 { app.swipeUp(); readTitles() }
        shot("Home: lower")
        XCTAssertFalse(titles.isEmpty, "no Top picks rows found")
        for untouched in ["Pet Supplies", "Clothing", "Jewelry", "Grocery & Gourmet"] {
            XCTAssertFalse(titles.contains("Top picks in \(untouched)"), "Top picks in \(untouched) for a shopper who only looked at laundry: \(titles)")
        }
        // Discover more, at the foot of Home, too. Only what is under its
        // title: this once read the whole page and met an event row's bikini
        // bottom (2026-11-22). Event rows keep to the shopper's departments
        // too since 2026-11-23 (HolidayThemeTests).
        let discover = app.staticTexts["Discover more"]
        XCTAssertTrue(discover.exists, "not at the foot of Home")
        let strays = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'bikini' OR label CONTAINS[c] 'dog '"))
            .allElementsBoundByIndex.filter { $0.exists && $0.frame.minY > discover.frame.minY }
        XCTAssertTrue(strays.isEmpty, "Discover more showed \(strays.map(\.label)) to a shopper who only looked at laundry")
    }
}
