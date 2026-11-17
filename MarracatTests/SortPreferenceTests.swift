import XCTest
@testable import Marracat

/// A shopper who sorts by price keeps that sort (owner, 2026-11-16), and a
/// cart line stepped down to zero is logged as a removal (owner, 2026-11-16).
@MainActor
final class SortPreferenceTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() {
        saved = SortPreference.defaults
        SortPreference.defaults = UserDefaults(suiteName: "SortPreferenceTests-\(UUID())")!
    }

    override func tearDown() {
        SortPreference.defaults = saved
    }

    func testAPriceSortIsKeptForTheNextListAndOtherSortsForgetIt() {
        XCTAssertEqual(SortPreference.current, .featured, "nobody starts sorted")
        XCTAssertEqual(ProductFilters.starting, ProductFilters())

        FilterBar.track(from: ProductFilters(), to: { var f = ProductFilters(); f.sort = .priceLow; return f }())
        XCTAssertEqual(SortPreference.current, .priceLow)
        XCTAssertEqual(ProductFilters.starting.sort, .priceLow, "the next search, department or brand page opens low to high")
        XCTAssertTrue(ProductFilters.starting.isEmpty, "only the sort carries over, never a filter")

        SortPreference.record(.priceHigh)
        XCTAssertEqual(ProductFilters.starting.sort, .priceHigh, "the last price sort wins")

        SortPreference.record(.newest)
        XCTAssertEqual(SortPreference.current, .featured, "picking another order forgets the price sort")
        SortPreference.record(.priceLow)
        SortPreference.record(.featured)
        XCTAssertEqual(SortPreference.current, .featured)
    }

    func testClearingFiltersKeepsTheSort() {
        var f = ProductFilters.starting
        f.sort = .priceLow
        f.categories = ["shoes"]
        f.clear()
        XCTAssertEqual(f.sort, .priceLow)
        XCTAssertTrue(f.isEmpty)
    }

    func testAnUnknownStoredSortStartsFeatured() {
        SortPreference.defaults.set("Cheapest first", forKey: SortPreference.key)
        XCTAssertEqual(SortPreference.current, .featured)
        SortPreference.defaults.set(ProductSort.newest.rawValue, forKey: SortPreference.key)
        XCTAssertEqual(SortPreference.current, .featured, "only a price sort is ever kept")
    }

    func testSteppingALineDownToZeroIsLoggedAsARemoval() async throws {
        let cart = CartStore(defaults: UserDefaults(suiteName: "SortPreferenceTests-cart-\(UUID())")!)
        cart.add(productID: "afroyla-bag", variantID: 7)
        let line = try XCTUnwrap(cart.lines.first)
        try XCTSkipUnless(Analytics.shared.isEnabled, "usage analytics switched off on this simulator")
        let removals = { Analytics.shared.queue.filter { $0.name == "remove_from_cart" }.count }
        for _ in 0..<5 { await Task.yield() }
        let before = removals()
        cart.setQuantity(0, for: line)
        XCTAssertTrue(cart.lines.isEmpty)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(removals(), before + 1, "a line stepped to zero counts as removed")
    }
}
