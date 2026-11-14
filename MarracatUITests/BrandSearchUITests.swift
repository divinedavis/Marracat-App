import XCTest

/// A brand page narrows by Filters, not search: its Filters sheet has a Type
/// group for pants, sweatshirts and the like (owner, 2026-11-08: "we need
/// better filtering for clothes"), and it has no search bar (owner,
/// 2026-11-09: "remove the brand search").
final class BrandSearchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITEST_RESET", "-SPLASH_SECONDS", "0"]
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Fear of God's page, reached through search and the product page's
    /// store card (Home's brand circles move around).
    private func openFearOfGod() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        app.storeSearchField().tap()
        let input = app.descendants(matching: .any)["searchInput"]
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("Fear of God pants\n")
        let result = app.descendants(matching: .any)["resultTitle"].firstMatch
        XCTAssertTrue(result.appears(timeout: 10), "no Fear of God results")
        result.tap()
        let store = app.descendants(matching: .any)["visitStore"]
        XCTAssertTrue(store.appears(timeout: 5), "product page has no link to the store")
        store.tap()
    }

    private var itemCount: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' items'")).firstMatch
    }

    func testClothingFiltersOfferTypes() {
        openFearOfGod()
        let filters = app.descendants(matching: .any)["filtersButton"].firstMatch
        XCTAssertTrue(filters.appears(timeout: 10))
        let search = app.textFields.matching(NSPredicate(format: "identifier == 'brandSearch' OR placeholderValue BEGINSWITH 'Search Fear of God'")).firstMatch
        XCTAssertFalse(search.exists, "the brand page has no search bar")
        shot("Brand page, no search bar")
        filters.tap()
        let type = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Type'")).firstMatch
        XCTAssertTrue(type.appears(timeout: 5), "no Type group in the brand's filters")
        // The shorter sheet (owner, 2026-11-10): it stops short of the top, and
        // Clear all, Show and ✕ sit together at the bottom, by the thumb.
        let height = app.windows.firstMatch.frame.height
        let groups = app.descendants(matching: .any).matching(identifier: "filterGroup").firstMatch
        XCTAssertGreaterThan(groups.frame.minY, height * 0.3, "the sheet rises about two-thirds of the way: \(groups.frame)")
        for id in ["filtersClear", "filtersApply", "filtersClose"] {
            XCTAssertGreaterThan(app.descendants(matching: .any)[id].frame.minY, height * 0.8, "\(id) at the bottom of the sheet")
        }
        type.tap()
        let pants = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'Pants'")).firstMatch
        XCTAssertTrue(pants.appears(timeout: 5), "Type has no pants option")
        shot("Filters: Type")
        pants.tap()
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show '")).firstMatch
        XCTAssertTrue(show.appears(timeout: 5))
        show.tap()
        XCTAssertTrue(itemCount.appears(timeout: 5))
    }

    /// Category shows photos like Type (owner, 2026-11-09: "just how we have
    /// box images for types, can we do the same for category?"). A photo tile
    /// reads "Makeup, 875"; a chip would read "Makeup 875".
    func testCategoryFilterShowsPhotoTiles() {
        app.launch()
        XCTAssertTrue(app.storeSearchField().appears(timeout: 60))
        app.storeSearchField().tap()
        let input = app.descendants(matching: .any)["searchInput"]
        XCTAssertTrue(input.appears(timeout: 5))
        input.typeText("fenty\n")
        XCTAssertTrue(app.descendants(matching: .any)["resultsHeader"].appears(timeout: 10))
        let filters = app.descendants(matching: .any)["filtersButton"].firstMatch
        XCTAssertTrue(filters.appears(timeout: 10))
        filters.tap()
        let category = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Category'")).firstMatch
        XCTAssertTrue(category.appears(timeout: 5), "fenty spans departments, so Category should be offered")
        category.tap()
        let makeup = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH 'Makeup, '")).firstMatch
        XCTAssertTrue(makeup.appears(timeout: 5), "Category should show Makeup as a photo tile")
        shot("Filters: Category")
        makeup.tap()
        XCTAssertTrue(makeup.isSelected, "tapping the tile picks Makeup")
        // Every other group is photo tiles too (owner, 2026-11-11): a tile
        // reads "<name>, <count>", where a text pill read "<name> <count>".
        let price = app.buttons.matching(NSPredicate(format: "identifier == 'filterGroup' AND label BEGINSWITH 'Price'")).firstMatch
        XCTAssertTrue(price.appears(timeout: 5), "fenty has more than one price band")
        price.tap()
        let band = app.buttons.matching(NSPredicate(format: "identifier == 'filterOption' AND label BEGINSWITH '$' AND label CONTAINS ', '")).firstMatch
        XCTAssertTrue(band.appears(timeout: 5), "Price should show its bands as photo tiles")
        shot("Filters: Price")
    }
}
