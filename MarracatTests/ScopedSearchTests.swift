import XCTest
@testable import Marracat

/// The searches that stay on their own page (owner, 2026-10-20, after IMDb):
/// You searches its rows and the settings behind them, Your Orders searches
/// by product, brand, order number and date, and Saved searches only what's
/// saved and the lists' names.
@MainActor
final class ScopedSearchTests: XCTestCase {
    private func titles(_ q: String, signedIn: Bool = false) -> [String] {
        YouSearch.matches(q, signedIn: signedIn, social: false).map(\.title)
    }

    func testYouSearchFindsRowsAndSettingsByTheirWords() {
        XCTAssertTrue(titles("notif").contains("Notifications"))
        XCTAssertEqual(titles("icon"), ["Holiday app icons"])
        XCTAssertTrue(titles("analytics").contains("Share usage analytics"))
        XCTAssertTrue(titles("back in stock").contains("Restock alerts"), "words people use, not just the row's name")
        XCTAssertTrue(titles("").isEmpty)
        XCTAssertTrue(titles("zzzz").isEmpty)
        XCTAssertFalse(titles("delete").contains("Delete account"), "nothing to delete when signed out")
        XCTAssertTrue(titles("delete", signedIn: true).contains("Delete account"))
        XCTAssertEqual(YouSearch.matches("icon", signedIn: false, social: false).first?.place, "Account settings")
    }

    func testOrderSearchMatchesNumbersAndDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))!
        let en = Locale(identifier: "en_US")
        func hit(_ q: String) -> Bool {
            OrderSearch.matches(q, title: "Vitamin C Glow Serum", brand: "KOBA", numbers: ["#11907"], date: date, calendar: cal, locale: en)
        }
        XCTAssertTrue(hit("glow serum"))
        XCTAssertTrue(hit("koba"))
        XCTAssertTrue(hit("#11907"))
        XCTAssertTrue(hit("11907"))
        XCTAssertTrue(hit("oct 3"))
        XCTAssertTrue(hit("October 2026"))
        XCTAssertTrue(hit("10/3"))
        XCTAssertTrue(hit("koba october"), "words can mix fields")
        XCTAssertFalse(hit("november"))
        XCTAssertFalse(hit("#12000"))
        XCTAssertTrue(hit(""), "an empty search keeps every order")
    }

    func testSavedSearchLooksOnlyAtWhatsSaved() throws {
        let catalog = CatalogStore(synchronously: true)
        let products = catalog.catalog.products
        let tote = try XCTUnwrap(products.first { $0.title.localizedCaseInsensitiveContains("tote") })
        let other = try XCTUnwrap(products.first { !$0.title.localizedCaseInsensitiveContains("tote") && $0.brand != tote.brand })
        let gifts = SavedList(id: "l1", name: "Birthday gifts", items: [other.id])
        let found = SavedSearch.matches("tote", lists: [gifts], saved: [tote.id], catalog: catalog)
        XCTAssertEqual(found.products.map(\.id), [tote.id])
        XCTAssertTrue(found.lists.isEmpty)
        let byList = SavedSearch.matches("birthday", lists: [gifts], saved: [tote.id], catalog: catalog)
        XCTAssertEqual(byList.lists.map(\.id), ["l1"])
        let byBrand = SavedSearch.matches(try XCTUnwrap(catalog.brand(other.brand)?.name), lists: [gifts], saved: [], catalog: catalog)
        XCTAssertTrue(byBrand.products.contains { $0.id == other.id }, "items inside lists count, found by brand")
        XCTAssertTrue(SavedSearch.matches("zzzzqq", lists: [gifts], saved: [tote.id], catalog: catalog).products.isEmpty)
    }
}
