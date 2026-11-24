import XCTest
@testable import Marracat

/// Holiday themes (owner, 2026-10-20): the dates each holiday falls on, which
/// one the app wears when they overlap, the icons and collections its events
/// link to, all read from Resources/holidays.json.
@MainActor
final class HolidayThemeTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func holiday(_ id: String) throws -> Holiday {
        try XCTUnwrap(HolidayCalendar.holidays.first { $0.id == id }, id)
    }

    func testTheFileLoadsEveryHoliday() {
        XCTAssertEqual(HolidayCalendar.holidays.count, 21)
        XCTAssertFalse(HolidayCalendar.collections.isEmpty)
    }

    func testMovingHolidaysLandOnTheirDays() throws {
        let expect: [(String, Int, Int, Int)] = [
            ("thanksgiving", 2026, 11, 26), ("black-friday", 2026, 11, 27), ("cyber-monday", 2026, 11, 30),
            ("mlk", 2027, 1, 18), ("presidents", 2027, 2, 15), ("memorial", 2027, 5, 31),
            ("memorial", 2026, 5, 25),   // the last Monday, when May ends on a Sunday
            ("labor", 2027, 9, 6), ("indigenous", 2027, 10, 11), ("juneteenth", 2027, 6, 19),
        ]
        for (id, y, m, d) in expect {
            let got = try XCTUnwrap(holiday(id).day(in: y, calendar: cal))
            XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: got), DateComponents(year: y, month: m, day: d), id)
        }
    }

    func testTheShortestThemeWinsOnOverlappingDays() {
        let expect: [((Int, Int, Int), String?)] = [
            ((2026, 10, 20), nil),
            ((2026, 10, 25), "halloween"),   // Halloween's week
            ((2026, 10, 31), "halloween"),
            ((2026, 11, 1), nil),
            ((2026, 11, 11), "veterans"),
            ((2026, 11, 21), "gift-guide"),
            ((2026, 11, 26), "thanksgiving"),
            ((2026, 11, 28), "black-friday"),
            ((2026, 11, 30), "cyber-monday"),
            ((2026, 12, 20), "christmas"),
            ((2026, 12, 27), "kwanzaa"),
            ((2026, 12, 31), "watch-night"),
            ((2027, 1, 1), "new-year"),
            ((2027, 2, 15), "presidents"),   // its own day inside Black History Month
            ((2027, 2, 16), "bhm"),
            ((2027, 6, 19), "juneteenth"),
        ]
        for ((y, m, d), want) in expect {
            XCTAssertEqual(HolidayCalendar.current(on: date(y, m, d), calendar: cal)?.id, want, "\(y)-\(m)-\(d)")
        }
        // A holiday starts at the shopper's midnight.
        XCTAssertNil(HolidayCalendar.current(on: date(2026, 11, 10, hour: 23), calendar: cal))
        XCTAssertEqual(HolidayCalendar.current(on: date(2026, 11, 11, hour: 0), calendar: cal)?.id, "veterans")
    }

    func testEveryHolidayIconIsInTheApp() {
        let icons = (Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        for h in HolidayCalendar.holidays {
            XCTAssertNotNil(icons[h.icon], "\(h.icon) is not an alternate icon")
        }
    }

    func testIconsAreOnByDefaultAndCanBeTurnedOff() {
        let key = HolidayIcon.settingKey
        let was = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(was, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(HolidayIcon.wanted(on: date(2026, 12, 27)), "AppIcon-kwanzaa", "on by default")
        XCTAssertNil(HolidayIcon.wanted(on: date(2026, 10, 20)), "the everyday icon on an ordinary day")
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertNil(HolidayIcon.wanted(on: date(2026, 12, 27)), "turned off: the everyday icon")
    }

    func testCollectionLinksOpenAndFill() throws {
        XCTAssertEqual(AppDestination(url: URL(string: "marracat://collection/kwanzaa")!), .collection("kwanzaa"))
        XCTAssertEqual(AppDestination.collection("kwanzaa").url.absoluteString, "marracat://collection/kwanzaa")
        XCTAssertEqual(AppDestination.collection("kwanzaa").path, [.collection("kwanzaa")])
        let catalog = CatalogStore(synchronously: true)
        catalog.buildSearchIndexNow()
        XCTAssertFalse(AppDestination.collection("no-such-thing").exists(in: catalog))
        for c in HolidayCalendar.collections {
            let products = catalog.products(inCollection: c.id)
            XCTAssertGreaterThanOrEqual(products.count, 20, c.id)
            XCTAssertEqual(Set(products.map(\.id)).count, products.count, "\(c.id) repeats a product")
        }
    }

    // MARK: Home event rows (owner, 2026-10-27)

    func testEventRowsRunOnTheirEventDays() {
        let expect: [((Int, Int, Int), [String])] = [
            ((2026, 10, 20), []),
            ((2026, 10, 27), ["halloween"]),
            ((2026, 11, 1), []),
            ((2026, 11, 9), ["veterans"]),
            ((2026, 11, 22), ["thanksgiving", "black-friday"]),   // soonest-ending first, two at most
            ((2026, 11, 30), ["cyber-monday", "gift-guide"]),
            ((2026, 12, 20), ["gift-guide", "christmas"]),
            ((2026, 12, 31), ["watch-night", "kwanzaa"]),
            ((2027, 2, 2), []),   // no rows for Black History Month yet
        ]
        for ((y, m, d), want) in expect {
            XCTAssertEqual(HolidayCalendar.events(on: date(y, m, d), calendar: cal).map(\.id), want, "\(y)-\(m)-\(d)")
        }
    }

    func testEveryEventRowIsAWorkingCollection() throws {
        for h in HolidayCalendar.holidays where h.rows != nil {
            XCTAssertEqual(h.banner?.count, 2, "\(h.id) needs two banner colours")
            for id in h.rows ?? [] {
                let c = try XCTUnwrap(HolidayCalendar.collection(id), "\(h.id) row \(id)")
                XCTAssertTrue(c.isFiltered, id)
                for pattern in [c.match, c.exclude, c.lead].compactMap({ $0 }) {
                    XCTAssertNoThrow(try NSRegularExpression(pattern: pattern), "\(id): \(pattern)")
                }
            }
        }
    }

    private func item(_ id: String, _ title: String, brand: String = "b", category: String = "party", price: Double = 20,
                      compareAt: Double? = nil, available: Bool = true, tags: [String] = [], at: String = "2026-10-01") -> Product {
        Product(id: id, brand: brand, title: title, category: category, productType: nil, subs: [], price: price,
                compareAt: compareAt, images: ["a.jpg"], url: "https://b.example/\(id)", available: available,
                variants: [], tags: tags, description: nil, publishedAt: at, bestRank: nil, currency: "USD")
    }

    func testHalloweenPicksKeepTheHolidayAndDropLookalikes() throws {
        let c = try XCTUnwrap(HolidayCalendar.collection("halloween"))
        let got = c.picks(from: [
            item("costume", "Witch Costume"),
            item("hazel", "Witch Hazel Toner", category: "skincare"),
            item("tagged", "Orange Tote", tags: ["Halloween"]),
            item("gone", "Pumpkin Candle", available: false),
            item("record", "Ghost - Live [LP]", category: "music"),
            item("dtf", "Spooky Season DTF Transfer"),
            item("tee", "Plain Tee"),
        ]).map(\.id)
        XCTAssertEqual(Set(got), ["costume", "tagged"])
    }

    /// Home's event rows show a shopper their own departments (owner,
    /// 2026-11-23: "only departments they touched"); the banner stays and
    /// someone with no history sees the whole event.
    func testEventRowsKeepToTheShoppersDepartments() throws {
        let friday = try XCTUnwrap(HolidayCalendar.holidays.first { $0.id == "black-friday" })
        // Ten markdowns in laundry, ten in skincare; only skincare's are under $25.
        let products = (0..<10).map { item("h\($0)", "Detergent \($0)", brand: "h\($0)", category: "household", price: 30, compareAt: 60) }
            + (0..<10).map { item("s\($0)", "Serum \($0)", brand: "s\($0)", category: "skincare", price: 12, compareAt: 24) }

        let everyone = try XCTUnwrap(HolidayEventRows.build([friday], products: products, touched: []).first)
        XCTAssertEqual(everyone.rows.map(\.collection.id), ["black-friday-deals", "black-friday-under-25"])
        XCTAssertEqual(Set(everyone.rows[0].products.map(\.category)), ["household", "skincare"], "no history: the whole store")

        let laundry = try XCTUnwrap(HolidayEventRows.build([friday], products: products, touched: ["household"]).first)
        XCTAssertEqual(laundry.rows.map(\.collection.id), ["black-friday-deals"], "nothing of theirs is under $25, so that row goes")
        XCTAssertEqual(Set(laundry.rows[0].products.map(\.category)), ["household"])
        XCTAssertEqual(laundry.opens.id, "black-friday-deals")

        let pets = try XCTUnwrap(HolidayEventRows.build([friday], products: products, touched: ["pets"]).first,
                                 "the banner stays when none of the event is in their departments")
        XCTAssertTrue(pets.rows.isEmpty)
        XCTAssertEqual(pets.opens.id, "black-friday-deals", "and opens the event's whole list")

        XCTAssertTrue(HolidayEventRows.build([friday], products: [], touched: []).isEmpty, "an event with nothing to show has no banner")
    }

    func testDealRowsSkipPlaceholderMarkdownsAndTakeTurnsByBrand() throws {
        let c = try XCTUnwrap(HolidayCalendar.collection("black-friday-deals"))
        let got = c.picks(from: [
            item("a1", "Dress", brand: "a", price: 40, compareAt: 100),   // 60% off
            item("a2", "Top", brand: "a", price: 50, compareAt: 100),     // 50%
            item("b1", "Bag", brand: "b", price: 60, compareAt: 100),     // 40%
            item("fake", "Seeds", brand: "c", price: 1, compareAt: 100),  // 99%: a placeholder price
            item("small", "Mug", brand: "d", price: 90, compareAt: 100),  // 10%: under 30
        ]).map(\.id)
        XCTAssertEqual(got, ["a1", "b1", "a2"])
    }
}
