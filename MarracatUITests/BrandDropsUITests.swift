import XCTest

/// Watch a brand's new drops (owner, 2026-10-20): a button on the brand page
/// opens a choice of everything new or some of its departments; the watch
/// shows on the button and in You › Price & sale alerts. -DEAL_ALERTS_STUB
/// keeps alerts on the phone, signed in.
final class BrandDropsUITests: XCTestCase {
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

    func testWatchingABrandsDropsByDepartment() {
        app.open(URL(string: "marracat://brand/telfar")!)
        let watch = any("watchDrops")
        XCTAssertTrue(watch.appears(timeout: 20), "no Watch drops on the brand page")
        XCTAssertEqual(watch.value as? String, "Off")
        watch.tap()

        XCTAssertTrue(any("dropAll").appears(timeout: 5), "the sheet offers everything new")
        XCTAssertTrue(any("dropAll").isSelected, "everything new until departments are picked")
        let department = app.buttons.matching(identifier: "dropCategory").firstMatch
        XCTAssertTrue(department.appears(timeout: 5), "the brand's departments are offered")
        let name = department.label
        department.tap()
        XCTAssertTrue(department.isSelected)
        XCTAssertFalse(any("dropAll").isSelected, "picking a department narrows it")
        any("dropWatchSave").tap()
        XCTAssertTrue(any("dropAll").disappears(timeout: 5), "Watch closes the sheet")
        XCTAssertEqual(watch.value as? String, "On")

        // It's listed with the alerts, by department.
        app.buttons["tab.you"].tap()
        any("priceAlertsRow").tap()
        let row = any("dropAlert")
        XCTAssertTrue(row.appears(timeout: 5), "the watch isn't in Price & sale alerts")
        let department0 = name.components(separatedBy: " (").first ?? name
        XCTAssertTrue(app.staticTexts[department0].exists, "it says which department: \(department0)")

        // And stops from the sheet.
        row.tap()
        XCTAssertTrue(watch.appears(timeout: 10))
        watch.tap()
        // The sheet opens half height; Stop sits at the foot of its list.
        let stop = any("dropWatchStop")
        for _ in 0..<3 where !stop.isHittable { app.collectionViews.firstMatch.swipeUp() }
        stop.tap()
        XCTAssertEqual(watch.value as? String, "Off")
    }
}
