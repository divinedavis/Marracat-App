import XCTest

/// Pull to refresh shows the Marracat M, not the system spinner (owner,
/// 2026-11-18). XCUITest can't look during a refresh: it waits for the app to
/// go idle after a drag, and the (hidden) system spinner keeps it busy until
/// the refresh is over. So the M is pinned on (`-PIN_MARK_REFRESH`), still, as
/// it looks while Home refreshes; MarkRefreshTests covers the drawing.
final class PullToRefreshUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG", "-PIN_MARK_REFRESH"]
    }

    func testHomeRefreshesWithTheMarracatMAtTheTop() {
        app.launch()
        XCTAssertTrue(app.homeReady().appears(timeout: 60))
        let mark = app.descendants(matching: .any)["markRefresh"].firstMatch
        XCTAssertTrue(mark.appears(timeout: 5), "no Marracat M on Home's refresh")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "home-refresh-M"; shot.lifetime = .keepAlways
        add(shot)
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(mark.frame.midX, window.midX, accuracy: 2, "centred")
        XCTAssertLessThan(mark.frame.minY, window.height * 0.2, "at the top, in the gap a pull opens")
        XCTAssertEqual(mark.label, "Refreshing")
    }

    func testAPullStillRefreshesHome() {
        app.launchArguments.removeAll { $0 == "-PIN_MARK_REFRESH" }
        app.launch()
        let hero = app.homeReady()
        XCTAssertTrue(hero.appears(timeout: 60))
        let window = app.windows.firstMatch
        // From the row under the hero (the carousel pages sideways).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(hero.appears(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["markRefresh"].firstMatch.exists, "the M goes once the refresh is done")
    }
}
