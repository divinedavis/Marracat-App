import XCTest
import UserNotifications
@testable import Marracat

/// Shopping alerts (owner, 2026-11-15): the card the server sends
/// (web/server/alert-cards.js), its buttons, the picks link, and the brand
/// rail's fold into ⋯.
final class ShoppingAlertsTests: XCTestCase {
    /// The shape web/server/alert-cards.js sends for a price drop.
    private let pushed: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "Price drop: $160.65 (was $189)", "body": "x"], "category": "MC_PRICE"],
        "productID": "p1",
        "card": ["k": "price", "t": "Price drop", "s": "Hanifa · you're watching its price", "price": "$160.65", "was": "$189",
                 "pct": "−15%", "items": [["id": "p1", "t": "Clarise Knit Maxi Dress II", "p": "$160.65", "img": "https://cdn.shopify.com/a.jpg?width=400"]],
                 "pid": "p1", "bid": "hanifa", "open": "marracat://product/p1"],
    ]

    func testTheServersCardDecodes() throws {
        let card = try XCTUnwrap(AlertCard(userInfo: pushed))
        XCTAssertEqual(card.k, .price)
        XCTAssertEqual(card.category, "MC_PRICE")
        XCTAssertEqual(card.thumbnail, "https://cdn.shopify.com/a.jpg?width=400")
        XCTAssertEqual(card.buttons.map(\.action), [.add, .open])
    }

    func testANotificationWithoutAGoodCardIsLeftAlone() {
        XCTAssertNil(AlertCard(userInfo: ["productID": "p1"]), "plain pushes keep Apple's banner")
        XCTAssertNil(AlertCard(userInfo: ["card": ["k": "fireworks", "t": "x"]]), "an unknown kind")
        XCTAssertNil(AlertCard(userInfo: ["card": "not a card"]))
    }

    func testALocalCardRoundTripsThroughUserInfo() throws {
        var card = AlertCard(k: .picks, t: "5 new picks for your week")
        card.items = [AlertCard.Item(id: "a", t: "Hoodie", p: "$45", img: nil)]
        let back = try XCTUnwrap(AlertCard(userInfo: ["card": card.userInfoValue]))
        XCTAssertEqual(back, card)
    }

    func testEveryKindHasACategoryTheContentExtensionKnows() {
        XCTAssertEqual(AlertCard.categories, ["MC_DROP", "MC_SALE", "MC_RESTOCK", "MC_INTEREST", "MC_DIGEST",
                                              "MC_PRICE", "MC_SAVED", "MC_BRAND", "MC_LASTSIZE", "MC_PICKS"],
                       "keep in step with MarracatNotificationContent's UNNotificationExtensionCategory in project.yml")
        for kind in AlertCard.Kind.allCases { XCTAssertFalse(AlertCard(k: kind, t: "").buttons.isEmpty, "\(kind) has a button") }
    }

    func testButtonsMapToNotificationActions() {
        XCTAssertEqual(AlertCategories.action(for: AlertCategories.addID), .add)
        XCTAssertEqual(AlertCategories.action(for: AlertCategories.followID), .follow)
        XCTAssertEqual(AlertCategories.action(for: UNNotificationDefaultActionIdentifier), .open, "a plain tap opens")
        var size = AlertCard(k: .lastsize, t: ""); size.size = "M"
        XCTAssertEqual(size.buttons.first?.title, "Grab M")
    }

    func testPicksLinksOpenTheirProducts() throws {
        let url = AppDestination.picks("Your Sunday picks", ["a", "b"]).url
        XCTAssertEqual(AppDestination(url: url), .picks("Your Sunday picks", ["a", "b"]))
        XCTAssertNil(AppDestination(url: URL(string: "marracat://picks?ids=")!), "no products, no screen")
        let many = (0..<40).map { "p\($0)" }.joined(separator: ",")
        guard case .picks(_, let ids)? = AppDestination(url: URL(string: "marracat://picks?ids=\(many)")!) else { return XCTFail() }
        XCTAssertEqual(ids.count, AppDestination.maxPicks, "a link can't open an endless list")
    }

    func testTheRailFoldsOneButtonAfterAnother() {
        XCTAssertEqual(RailFoldMath.progress(scrolled: 0, index: 0), 0)
        XCTAssertEqual(RailFoldMath.progress(scrolled: 400, index: 3), 1, accuracy: 0.001, "all folded well down the page")
        let mid: CGFloat = 120
        XCTAssertGreaterThan(RailFoldMath.progress(scrolled: mid, index: 0), RailFoldMath.progress(scrolled: mid, index: 3),
                             "the top button leads")
        XCTAssertLessThan(RailFoldMath.page(RailFoldMath.start + RailFoldMath.span * 0.9), 0.95, "no bounce before the last lands")
        XCTAssertGreaterThanOrEqual(RailFoldMath.page(RailFoldMath.start + RailFoldMath.span), 0.95, "the ⋯ bounces as it lands")
    }

    func testWeeklyPicksAreRecentAndSpreadAcrossBrands() {
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
        XCTAssertTrue(WeeklyAlerts.isRecent("2026-11-10T09:00:00Z", now: now))
        XCTAssertFalse(WeeklyAlerts.isRecent("2026-10-01T09:00:00Z", now: now))
        XCTAssertFalse(WeeklyAlerts.isRecent(nil, now: now))
        let p = { (id: String, brand: String) in
            Product(id: id, brand: brand, title: id, category: "bags", productType: nil, subs: [], price: 10, compareAt: nil, images: [], url: "",
                    available: true, variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil)
        }
        let spread = WeeklyAlerts.spread([p("a", "x"), p("b", "x"), p("c", "x"), p("d", "y")], perBrand: 2, limit: 5)
        XCTAssertEqual(spread.map(\.id), ["a", "b", "d"], "no more than two from one brand")
    }
}
