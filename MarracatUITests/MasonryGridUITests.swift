import XCTest

/// Products in a masonry grid (owner, 2026-11-15, "Marracat Brand Grid
/// Alternatives" #3): two columns of tiles with photos of different heights,
/// on a brand's page and on a category's, and a tile still opens its product.
final class MasonryGridUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = "1"
        app.launchArguments = ["-UITEST_RESET", "-SKIP_SPLASH", "-OFFLINE_CATALOG"]
        app.launch()
    }

    private func any(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The tiles on screen: two columns (two left edges), and not all one height.
    private func assertMasonry(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(any("masonryGrid").appears(timeout: 20), "\(what): no masonry grid", file: file, line: line)
        let tiles = any("masonryGrid").descendants(matching: .any).matching(identifier: "productTile").allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 0 }.prefix(8)
        XCTAssertGreaterThanOrEqual(tiles.count, 4, "\(what): too few tiles", file: file, line: line)
        let lefts = Set(tiles.map { Int($0.frame.minX.rounded()) })
        XCTAssertEqual(lefts.count, 2, "\(what): two columns on a phone, got x = \(lefts.sorted())", file: file, line: line)
        let heights = Set(tiles.map { Int($0.frame.height.rounded()) })
        XCTAssertGreaterThan(heights.count, 1, "\(what): every tile the same height is a grid, not masonry", file: file, line: line)
    }

    func testABrandAndACategoryShowProductsAsMasonryAndATileOpensItsProduct() {
        app.open(URL(string: "marracat://brand/telfar")!)
        assertMasonry("brand page")
        app.open(URL(string: "marracat://category/bags")!)
        assertMasonry("category page")
        let first = any("masonryGrid").descendants(matching: .any).matching(identifier: "productTile").firstMatch
        first.tap()
        XCTAssertTrue(app.buttons["addToCart"].appears(timeout: 15) || any("productDetail").appears(timeout: 5),
                      "the tile didn't open its product")
    }

    /// A product zooms out of its tile (owner, 2026-11-15) and both ways back
    /// work: a swipe down from the top of the page, and a swipe in from the
    /// left edge. Animations on, since the zoom's dismiss gesture is the test.
    func testAProductClosesWithASwipeDownOrFromTheLeftEdge() {
        app.terminate()
        app.launchEnvironment["MARRACAT_NO_ANIMATIONS"] = nil
        app.launch()
        app.open(URL(string: "marracat://brand/telfar")!)
        XCTAssertTrue(any("masonryGrid").appears(timeout: 20))
        let tile = { self.any("masonryGrid").descendants(matching: .any).matching(identifier: "productTile").firstMatch }
        let open = app.buttons["addToCart"]
        tile().tap()
        XCTAssertTrue(open.appears(timeout: 15), "the product didn't open")
        // Swipe down from the top of the page.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(open.disappears(timeout: 8), "a swipe down from the top should close the product")
        XCTAssertTrue(tile().appears(timeout: 5))
        // And from the left edge.
        tile().tap()
        XCTAssertTrue(open.appears(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(open.disappears(timeout: 8), "a swipe from the left edge should go back")
        XCTAssertTrue(any("masonryGrid").exists, "back on the brand page")
    }
}
