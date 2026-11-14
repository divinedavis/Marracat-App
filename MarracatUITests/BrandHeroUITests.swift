import XCTest

/// The brand page's top (owner, 2026-10-31, picked from previews: "H2 · Side
/// rail"): a photo with the name over it, Website, Instagram, Sale alerts and
/// Watch drops as round icons down its right edge, Share and Boost in ⋯, and
/// the name in the bar once the photo scrolls away.
final class BrandHeroUITests: XCTestCase {
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

    func testBrandPageLeadsWithAPhotoAndARailOfIcons() {
        app.open(URL(string: "marracat://brand/telfar")!)
        let hero = any("brandHero")
        XCTAssertTrue(hero.appears(timeout: 20), "the brand page has no photo header")
        let rail = ["brandWebsite", "saleAlerts", "watchDrops"].map(any)
        for button in rail { XCTAssertTrue(button.exists, "\(button) missing from the rail") }
        // Down the right edge, one above another, inside the photo.
        let xs = rail.map(\.frame.midX), ys = rail.map(\.frame.midY)
        XCTAssertLessThan(xs.max()! - xs.min()!, 2, "the rail's buttons should line up: \(xs)")
        XCTAssertEqual(ys, ys.sorted(), "Website, then Sale alerts, then Watch drops")
        XCTAssertGreaterThan(xs[0], hero.frame.midX, "the rail sits on the right")
        XCTAssertLessThanOrEqual(rail.last!.frame.maxY, hero.frame.maxY)
        // On the screen and tappable: a filling photo once pushed the rail
        // past the right edge, where nothing can be tapped.
        let screen = app.windows.firstMatch.frame
        for button in rail {
            XCTAssertLessThanOrEqual(button.frame.maxX, screen.maxX, "\(button.identifier) is off the right edge")
            XCTAssertTrue(button.isHittable, "\(button.identifier) can't be tapped")
        }
        let name = app.staticTexts["Telfar"].firstMatch
        XCTAssertTrue(name.exists, "the brand's name over the photo")
        XCTAssertLessThan(name.frame.maxX, xs[0], "the name sits left of the rail, on the screen")
        XCTAssertEqual(any("brandWebsite").label, "Website")
        XCTAssertFalse(any("shareBrand").exists, "Share left the page for ⋯ (owner: \"remove the button for share\")")

        // Share is in ⋯.
        any("brandMore").tap()
        let share = app.buttons["Share"]
        XCTAssertTrue(share.appears(timeout: 5), "Share in the ⋯ menu")
        hero.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()   // close the menu
        XCTAssertTrue(share.disappears(timeout: 5))

        // Scrolled past the photo, the bar names the brand.
        XCTAssertFalse(any("brandBarTitle").exists, "no bar title over the photo")
        app.swipeUp()
        XCTAssertTrue(any("brandBarTitle").appears(timeout: 5), "the bar should name the brand once the photo has gone")
        // Centred on the screen (owner, 2026-11-01: "center the brand name on the header").
        XCTAssertEqual(any("brandBarTitle").frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2,
                       "brand name at \(any("brandBarTitle").frame)")
    }

    /// Filters by the thumb (owner, 2026-11-10, picked "Two pills by your
    /// thumb"): Filters and Sort float as one pill just above the tab bar, step
    /// aside while scrolling down and come back on a short scroll up. Nothing
    /// is pinned at the top any more, and the departments are in Filters.
    func testFiltersFloatAboveTheTabBarAndStepAsideOnTheWayDown() {
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("brandHero").appears(timeout: 20))
        let filters = any("filtersButton"), sort = any("sortButton"), home = app.buttons["tab.home"]
        XCTAssertTrue(filters.appears(timeout: 5), "Filters is there from the start")
        XCTAssertTrue(sort.exists)
        XCTAssertLessThanOrEqual(filters.frame.maxY, home.frame.minY + 2, "above the tab bar, not under it: \(filters.frame)")
        XCTAssertGreaterThan(filters.frame.minY, home.frame.minY - 120, "right above the tab bar, by the thumb: \(filters.frame)")
        XCTAssertEqual(filters.frame.midY, sort.frame.midY, accuracy: 2, "Filters and Sort side by side in one pill")
        XCTAssertFalse(any("pinnedFilterShelf").exists, "nothing pinned at the top any more")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(waitUntil(timeout: 3) { !filters.exists || !filters.isHittable }, "scrolling down leaves the room to the products")
        // A short drag back up.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        XCTAssertTrue(waitUntil(timeout: 5) { filters.exists && filters.isHittable }, "a scroll up should bring Filters back")
        XCTAssertLessThanOrEqual(filters.frame.maxY, home.frame.minY + 2, "still above the tab bar: \(filters.frame)")
        filters.tap()
        XCTAssertTrue(any("filterSheet").appears(timeout: 5), "and it opens the filters")
    }
}

