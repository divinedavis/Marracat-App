import XCTest

/// The app's look (owner, 2026-11-22: "all white theme as default and allow
/// the current theme to be set as dark mode in the settings"): white on a
/// first launch, Profile > Appearance switches to the black look at once,
/// and the choice is still there on the next launch.
final class AppearanceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
    }

    private func any(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// How light the page is, 0 (black) to 1 (white): the middle of a strip
    /// just under the status bar on the Profile, which is bare page.
    private func pageLightness() -> CGFloat {
        let image = app.screenshot().image
        guard let cg = image.cgImage else { return -1 }
        let spot = CGRect(x: cg.width / 2, y: Int(CGFloat(cg.height) * 0.075), width: 1, height: 1)
        guard let pixel = cg.cropping(to: spot) else { return -1 }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (CGFloat(px[0]) + CGFloat(px[1]) + CGFloat(px[2])) / (3 * 255)
    }

    private func openProfile() {
        XCTAssertTrue(app.appReady().appears(timeout: 60))
        app.buttons["tab.you"].tap()
        XCTAssertTrue(any("appearanceRow").appears(timeout: 10), "no Appearance row on the Profile")
    }

    func testTheAppOpensWhiteAndDarkIsASettingThatSticks() {
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB"]
        app.launch()
        openProfile()
        let picker = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(picker.buttons["Light"].isSelected, "a new shopper starts on Light")
        XCTAssertGreaterThan(pageLightness(), 0.9, "the page should be white by default")
        snap("appearance-light")

        picker.buttons["Dark"].tap()
        XCTAssertTrue(picker.buttons["Dark"].isSelected)
        sleep(1)
        XCTAssertLessThan(pageLightness(), 0.1, "choosing Dark should turn the page black at once")
        snap("appearance-dark")

        // The next launch (nothing reset) is still dark.
        app.terminate()
        app.launchArguments = ["-SKIP_SPLASH", "-CHECKOUT_STUB"]
        app.launch()
        openProfile()
        XCTAssertTrue(app.segmentedControls["appearancePicker"].buttons["Dark"].isSelected, "the choice wasn't kept")
        XCTAssertLessThan(pageLightness(), 0.1, "the next launch should still be dark")

        app.segmentedControls["appearancePicker"].buttons["Light"].tap()
        sleep(1)
        XCTAssertGreaterThan(pageLightness(), 0.9, "back to Light")
    }

    private func snap(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] else { return }
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
