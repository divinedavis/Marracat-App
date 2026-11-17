import XCTest

/// You › Share Marracat (owner, 2026-11-16): a row on the Profile opens a
/// sheet with a big QR code for the App Store and Copy link, Share and Save
/// under it; a swipe down closes it.
final class ShareAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testTheProfileOpensABigQRCodeForTheAppStore() {
        app.launch()
        XCTAssertTrue(app.appReady().appears(timeout: 60))
        app.buttons["tab.you"].tap()
        let row = any("shareAppRow")
        XCTAssertTrue(row.appears(timeout: 10), "no Share Marracat row on the Profile")
        row.tap()

        let code = any("appQRCode")
        XCTAssertTrue(code.appears(timeout: 5), "the sheet didn't open")
        XCTAssertGreaterThan(code.frame.width, app.windows.firstMatch.frame.width * 0.75, "the code should be about as wide as the sheet")
        XCTAssertTrue(any("shareAppLink").exists)
        XCTAssertTrue(any("saveAppQR").exists)

        let copy = app.buttons["copyAppLink"]
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].appears(timeout: 3), "Copy link says it copied")

        app.swipeDown(velocity: .fast)
        XCTAssertTrue(code.disappears(timeout: 5), "a swipe down closes the sheet")
        XCTAssertTrue(row.exists, "back on the Profile")
    }
}
