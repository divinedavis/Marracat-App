import XCTest

/// "Ships from Africa" on a brand based outside the US (owner, 2026-10-14;
/// catalog/ships_from.py), and nothing on a US brand.
final class ShipsFromUITests: XCTestCase {
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

    func testBrandPageSaysWhereItShipsFrom() {
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("brandWebsite").appears(timeout: 20), "the brand page didn't open")
        XCTAssertFalse(any("brandShipsFrom").exists, "a US brand shows no origin")

        // Christie Brown, Accra (added 2026-10-15).
        app.open(URL(string: "marracat://brand/christie-brown")!)
        let origin = any("brandShipsFrom")
        XCTAssertTrue(origin.appears(timeout: 20), "Christie Brown's page shows no origin")
        XCTAssertEqual(origin.label, "Ships from Africa")
    }
}
