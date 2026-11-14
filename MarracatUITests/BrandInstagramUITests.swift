import XCTest

/// The brand page's Instagram button shows only for a brand whose own site
/// links its account (owner, 2026-10-17; catalog/instagram_handles.py).
/// Telfar's site links @telfarglobal; Walter Calvin's links none.
final class BrandInstagramUITests: XCTestCase {
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

    func testInstagramButtonOnlyWhereTheBrandsSiteLinksOne() {
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("brandWebsite").appears(timeout: 20), "the brand page didn't open")
        let ig = any("brandInstagram")
        XCTAssertTrue(ig.exists, "Telfar's site links its Instagram")
        XCTAssertEqual(ig.label, "Instagram")

        app.open(URL(string: "marracat://brand/walter-calvin")!)
        XCTAssertTrue(app.staticTexts["Walter Calvin"].appears(timeout: 20), "Walter Calvin's page didn't open")
        XCTAssertTrue(any("brandWebsite").exists)
        XCTAssertFalse(any("brandInstagram").exists, "no Instagram on the site, so no button")
    }
}
