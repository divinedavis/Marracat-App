import XCTest

/// Wide windows (iPhone Duo opened, iPad): Home's rows go side by side, the
/// sidebar stands in for the floating bar where it fits, and a change of
/// width (a fold, an unfold, a rotation) keeps the shopper where they were.
///
/// The rules are the app's (AdaptiveLayout; AdaptiveLayoutTests pins them per
/// width), so this runs on whatever simulator the suite is given and checks
/// what that window should show: on an iPhone or Duo's outer display, the
/// phone layout; on Duo's inner display or an iPad, the wide one. XCUITest
/// has no fold control (Xcode 27.1's XCUIDevice has none), so the width
/// change is driven by rotating an iPad, the same runtime size-class and
/// width change a fold makes.
final class AdaptiveLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"   // MarracatUITestCase.setUp
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait   // simulators are shared
        super.tearDown()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The pushed screen's back button (the bar's only other button is search).
    private var back: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier == 'BackButton' OR label == 'Back'")).firstMatch
    }

    private var tabs: [XCUIElement] {
        let q = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'"))
        return (0..<q.count).map { q.element(boundBy: $0) }
    }

    /// The app's own rules (AdaptiveLayout), for this window.
    private var window: CGRect { app.windows.firstMatch.frame }
    private var regular: Bool { UIDevice.current.userInterfaceIdiom == .pad || window.width >= 600 }
    private var expectsSidebar: Bool { regular && window.width >= 800 }
    private func expectedColumns(feed: CGFloat) -> Int { feed >= 1080 ? 3 : feed >= 600 ? 2 : 1 }

    /// The trailing edges of Home's "Top picks in …" rows: one per column.
    private func feedColumnEdges() -> Set<Int> {
        let arrows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'See all Top picks in'"))
        XCTAssertTrue(arrows.firstMatch.appears(timeout: 20), "Home's department rows never appeared")
        return Set((0..<min(arrows.count, 6)).map { Int(arrows.element(boundBy: $0).frame.maxX.rounded()) })
    }

    func testTheLayoutFollowsTheWindow() {
        XCTAssertTrue(any("productTile").appears(timeout: 20), "Home never populated")
        let bar = tabs
        XCTAssertEqual(bar.count, 5, "five tabs, wherever they are")
        if expectsSidebar {
            XCTAssertTrue(any("sidebar").exists, "a \(Int(window.width))pt regular window gets the sidebar")
            XCTAssertEqual(Set(bar.map { Int($0.frame.midX) }).count, 1, "the sidebar's tabs stand in a column")
            XCTAssertTrue(bar.allSatisfy { $0.frame.maxX <= window.minX + 88 + 1 }, "along the leading edge")
        } else {
            XCTAssertFalse(any("sidebar").exists, "no sidebar in a \(Int(window.width))pt window")
            XCTAssertEqual(Set(bar.map { Int($0.frame.midY) }).count, 1, "the floating bar's tabs sit in a row")
            XCTAssertTrue(bar.allSatisfy { $0.frame.minY > window.midY }, "at the bottom")
        }
        let feed = window.width - (expectsSidebar ? 88 : 0)
        XCTAssertEqual(feedColumnEdges().count, expectedColumns(feed: feed),
                       "Home's rows in \(expectedColumns(feed: feed)) column(s) at \(Int(feed))pt")
        // Every tab still works from wherever its button is.
        app.buttons["tab.cart"].tap()
        XCTAssertTrue(app.buttons["tab.cart"].isSelected)
        app.buttons["tab.home"].tap()
        XCTAssertTrue(app.buttons["tab.home"].isSelected)
    }

    /// A fold or unfold changes the window's width and size class while the
    /// app runs. The tab, the screen pushed on it and the cart must survive.
    func testAWidthChangeKeepsTheTabAndTheScreen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("iPhone apps are portrait-only; the width change is driven on an iPad")
        }
        XCTAssertTrue(any("productTile").appears(timeout: 20), "Home never populated")
        let before = window.width
        app.buttons["Bags"].firstMatch.tap()
        XCTAssertTrue(back.appears(timeout: 10), "Bags didn't open")
        XCUIDevice.shared.orientation = .landscapeLeft
        let wider = NSPredicate { _, _ in self.window.width > before }
        wait(for: [expectation(for: wider, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(app.buttons["tab.home"].isSelected, "still on Home")
        XCTAssertTrue(back.exists, "still on the pushed Bags screen, not back at Home's root")
        XCTAssertEqual(any("sidebar").exists, expectsSidebar)
        XCUIDevice.shared.orientation = .portrait
        let narrower = NSPredicate { _, _ in self.window.width == before }
        wait(for: [expectation(for: narrower, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(app.buttons["tab.home"].isSelected)
        XCTAssertTrue(back.exists, "the pushed screen is still there")
        XCTAssertEqual(any("sidebar").exists, expectsSidebar)
    }
}
