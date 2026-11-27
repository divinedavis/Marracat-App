import XCTest

/// The Filters sheet has a Country group: the country each brand is based in
/// (owner, 2026-11-26: "Let's put a filter for the country the company is
/// founded"). Picking one keeps that country's brands and shows as a chip.
final class CountryFilterUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-CHECKOUT_STUB", "-OFFLINE_CATALOG"]
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func shot(_ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: screen)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["MARRACAT_SHOT_DIR"] {
            try? screen.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    func testCountryNarrowsASearchToOneCountrysBrands() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        app.storeSearchField().tap()
        XCTAssertTrue(any("searchInput").appears(timeout: 5))
        any("searchInput").typeText("dress\n")
        let header = any("resultsHeader")
        XCTAssertTrue(header.appears(timeout: 10))
        let before = Int(header.label.filter(\.isNumber)) ?? 0
        XCTAssertGreaterThan(before, 50, "dresses come from many brands in several countries")

        any("filtersButton").tap()
        XCTAssertTrue(any("filterSheet").appears(timeout: 10))
        let country = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Country'")).firstMatch
        XCTAssertTrue(country.appears(timeout: 5), "a search across many brands offers the Country group")
        country.tap()
        // A tile reads "<country>, <count>": full names, not codes.
        let nigeria = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'Nigeria, '")).firstMatch
        XCTAssertTrue(nigeria.appears(timeout: 5), "Nigerian brands sell dresses, so Nigeria is offered by name")
        let us = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'United States, '")).firstMatch
        XCTAssertTrue(us.exists, "the United States is offered by name")
        shot("country-filter-sheet")
        nigeria.tap()
        XCTAssertTrue(nigeria.isSelected)
        shot("country-filter-picked")
        let apply = any("filtersApply")
        XCTAssertTrue(apply.label.contains("Show"), "the button counts what is left")
        apply.tap()

        XCTAssertTrue(header.appears(timeout: 10))
        let after = Int(header.label.filter(\.isNumber)) ?? 0
        XCTAssertLessThan(after, before, "one country is fewer dresses than all of them")
        XCTAssertGreaterThan(after, 0)
        let chip = any("activeFilterChip")
        XCTAssertTrue(chip.appears(timeout: 5), "the choice shows as a chip above the results")
        XCTAssertTrue(chip.label.contains("Nigeria"), "the chip names the country: \(chip.label)")
        shot("country-filter-results")
        chip.tap()
        XCTAssertTrue(header.appears(timeout: 10))
        XCTAssertEqual(Int(header.label.filter(\.isNumber)), before, "removing the chip puts every result back")
    }
}
