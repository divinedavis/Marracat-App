import XCTest
@testable import Marracat

/// The Marracat order email: matching the brand's emails to the right order,
/// the tracker's step, and what a checkout gets as its email.
final class RelayTests: XCTestCase {
    private func brand(_ id: String, _ name: String, _ domain: String) throws -> Brand {
        let json = #"{"id":"\#(id)","name":"\#(name)","domain":"\#(domain)","category":"skincare","tagline":"","shopify":true}"#
        return try JSONDecoder().decode(Brand.self, from: Data(json.utf8))
    }
    private func event(_ id: Int, _ at: Date, _ kind: String, domain: String = "eparaskincare.com", order: String? = nil,
                       tracking: String? = nil, step: String? = nil) -> RelayEvent {
        RelayEvent(id: id, received: at.timeIntervalSince1970 * 1000, kind: kind, brandName: "Epara Skincare", brandDomain: domain,
                   orderName: order, carrier: tracking == nil ? nil : "USPS", trackingNumber: tracking, trackingStatus: nil, trackingStep: step)
    }

    func testEventsMatchTheirOrderByBrandTimeAndOrderNumber() throws {
        let store = RelayStore(defaults: UserDefaults(suiteName: "relay-\(UUID())")!)
        let epara = try brand("epara", "Epara Skincare", "www.eparaskincare.com")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let first = CheckoutRecord(brandID: "epara", date: t0, itemCount: 1, subtotal: 84, productIDs: ["p"])
        let second = CheckoutRecord(brandID: "epara", date: t0.addingTimeInterval(86400 * 2), itemCount: 1, subtotal: 20, productIDs: ["q"])
        store.stubEvents([
            event(1, t0.addingTimeInterval(60), "confirmation", order: "#1042"),
            event(2, t0.addingTimeInterval(86400 * 2 + 60), "confirmation", order: "#1043"),
            // The first order ships after the second was placed: its number keeps it with the first.
            event(3, t0.addingTimeInterval(86400 * 3), "shipped", order: "#1042", tracking: "9400111899223197428490"),
            event(4, t0.addingTimeInterval(86400 * 3), "confirmation", domain: "otherbrand.com", order: "#9"),
        ])
        let all = [first, second]
        XCTAssertEqual(Set(store.events(for: first, brand: epara, allOrders: all).map(\.id)), [1, 3])
        XCTAssertEqual(store.events(for: second, brand: epara, allOrders: all).map(\.id), [2])
        XCTAssertEqual(RelayStore.step(store.events(for: first, brand: epara, allOrders: all)), 1)
        XCTAssertEqual(RelayStore.step(store.events(for: second, brand: epara, allOrders: all)), 0)
    }

    /// 2026-10-08: KOBA confirmed "#11906", shipped "#KOBA-11906", and a second
    /// KOBA order a minute later got a confirmation with no number. The shipped
    /// email belongs to the first order, not the second.
    func testOneOrderNumberWrittenTwoWaysStaysWithItsOwnOrder() throws {
        let store = RelayStore(defaults: UserDefaults(suiteName: "relay-\(UUID())")!)
        let koba = try brand("koba-skincare", "KOBA skincare", "kobaskincare.com")
        let t0 = Date(timeIntervalSince1970: 1_791_430_888)
        let first = CheckoutRecord(brandID: "koba-skincare", date: t0, itemCount: 1, subtotal: 14, productIDs: ["h"])
        let second = CheckoutRecord(brandID: "koba-skincare", date: t0.addingTimeInterval(48), itemCount: 1, subtotal: 14, productIDs: ["h"])
        store.stubEvents([
            event(7, t0.addingTimeInterval(5), "confirmation", domain: "kobaskincare.com", order: "#11906"),
            event(9, t0.addingTimeInterval(90), "confirmation", domain: "kobaskincare.com"),
            event(11, t0.addingTimeInterval(39_000), "shipped", domain: "kobaskincare.com", order: "#KOBA-11906", tracking: "1ZY551D20317451342"),
        ])
        let all = [first, second]
        XCTAssertEqual(Set(store.events(for: first, brand: koba, allOrders: all).map(\.id)), [7, 11])
        XCTAssertEqual(RelayStore.step(store.events(for: first, brand: koba, allOrders: all)), 1, "Shipped is lit")
        XCTAssertEqual(store.events(for: second, brand: koba, allOrders: all).map(\.id), [9])
        XCTAssertEqual(RelayStore.step(store.events(for: second, brand: koba, allOrders: all)), 0)
        // Tapping the Shipped notification opens the first order.
        XCTAssertEqual(store.record(brandDomain: "kobaskincare.com", orderName: "#KOBA-11906", brands: [koba], orders: all)?.id, first.id)
        XCTAssertEqual(store.record(brandDomain: "kobaskincare.com", orderName: nil, brands: [koba], orders: all)?.id, second.id, "no number: the latest")
        XCTAssertNil(store.record(brandDomain: "otherbrand.com", orderName: "#1", brands: [koba], orders: all))
    }

    /// 2026-10-09: "Arriving today" named "order #KOBA-11906". The app now tells
    /// the server what each order held, by the number its emails use, once.
    func testItemNamesPairEachOrderNumberWithWhatThatOrderHeld() throws {
        let store = RelayStore(defaults: UserDefaults(suiteName: "relay-\(UUID())")!)
        let koba = try brand("koba-skincare", "KOBA skincare", "kobaskincare.com")
        let t0 = Date(timeIntervalSince1970: 1_791_430_888)
        var first = CheckoutRecord(brandID: "koba-skincare", date: t0, itemCount: 1, subtotal: 14, productIDs: ["h"])
        first.items = [PurchasedItem(title: "Keep It Together Headband", quantity: 1)]
        var second = CheckoutRecord(brandID: "koba-skincare", date: t0.addingTimeInterval(48), itemCount: 3, subtotal: 9.99, productIDs: ["s"])
        second.items = [PurchasedItem(title: "Le Discovery Set", quantity: 1)]
        store.stubEvents([
            event(7, t0.addingTimeInterval(5), "confirmation", domain: "kobaskincare.com", order: "#11906"),
            event(11, t0.addingTimeInterval(39_000), "shipped", domain: "kobaskincare.com", order: "#KOBA-11906"),
        ])
        let all = [first, second]
        let names = store.itemNames(orders: all, brand: { $0 == "koba-skincare" ? koba : nil },
                                    titles: { $0.items?.map(\.title) ?? [] }, alreadySent: [])
        XCTAssertEqual(names.count, 1, "the second order has no numbered email yet")
        XCTAssertEqual(names.first?["itemTitle"] as? String, "Keep It Together Headband")
        XCTAssertEqual(names.first?["orderName"] as? String, "#11906")
        let again = store.itemNames(orders: all, brand: { _ in koba }, titles: { $0.items?.map(\.title) ?? [] },
                                    alreadySent: [names.first?["key"] as? String ?? ""])
        XCTAssertTrue(again.isEmpty, "sent once")
    }

    func testOrderKeysIgnoreHashAndBrandPrefix() {
        XCTAssertEqual(RelayStore.orderKey("#KOBA-11906"), "11906")
        XCTAssertEqual(RelayStore.orderKey("#11906"), "11906")
        XCTAssertEqual(RelayStore.orderKey("SP-2231"), "2231")
        XCTAssertEqual(RelayStore.orderKey("#1042-2"), "1042-2", "a split shipment's suffix is kept")
    }

    func testTheTrackerTakesTheFurthestStepFromEmailsOrTheCarrier() {
        let now = Date()
        XCTAssertEqual(RelayStore.step([]), 0)
        XCTAssertEqual(RelayStore.step([event(1, now, "shipped")]), 1)
        XCTAssertEqual(RelayStore.step([event(1, now, "shipped", step: "out_for_delivery")]), 2)
        XCTAssertEqual(RelayStore.step([event(1, now, "shipped", step: "shipped"), event(2, now, "delivered")]), 3)
        XCTAssertEqual(RelayStore.step([event(1, now, "confirmation"), event(2, now, "other")]), 0)
    }

    func testBrandMatchingToleratesWwwAndSubdomains() throws {
        let telfar = try brand("telfar", "Telfar", "shop.telfar.net")
        XCTAssertTrue(RelayStore.sameBrand(event(1, .now, "shipped", domain: "telfar.net"), brand: telfar))
        XCTAssertTrue(RelayStore.sameBrand(event(1, .now, "shipped", domain: "www.shop.telfar.net"), brand: telfar))
        XCTAssertFalse(RelayStore.sameBrand(event(1, .now, "shipped", domain: "notelfar.net"), brand: telfar))
        XCTAssertFalse(RelayStore.sameBrand(event(1, .now, "shipped"), brand: nil))
    }

    func testCheckoutEmailIsTheShoppersOwnWhileTheFlagIsOff() {
        let store = RelayStore(defaults: UserDefaults(suiteName: "relay-\(UUID())")!)
        store.clear()
        XCTAssertEqual(store.checkoutEmail(realEmail: "me@example.com"), "me@example.com")
        XCTAssertTrue(RelayStore.isRelay("u-abcdefghjk@orders.marracat.com"))
        XCTAssertTrue(RelayStore.isRelay("U-ABCDEFGHJK@Orders.Marracat.com"))
        XCTAssertFalse(RelayStore.isRelay("me@example.com"))
        XCTAssertFalse(RelayStore.isRelay(nil))
    }

    func testPermalinkPrefillsTheOrderEmailOnlyWhenGiven() throws {
        RelayStore.shared.clear()
        let epara = try brand("epara", "Epara Skincare", "eparaskincare.com")
        let line = CartLine(productID: "p", variantID: 123, quantity: 1)
        let plain = CartStore.checkoutURL(brand: epara, lines: [line])?.absoluteString ?? ""
        XCTAssertFalse(plain.contains("checkout%5Bemail%5D") || plain.contains("checkout[email]"), plain)
        let relayed = CartStore.checkoutURL(brand: epara, lines: [line], checkoutEmail: "u-abcdefghjk@orders.marracat.com")
        let item = URLComponents(url: relayed!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "checkout[email]" }
        XCTAssertEqual(item?.value, "u-abcdefghjk@orders.marracat.com")
    }

    /// A cart link's prefill line shows the order email only when the link
    /// carries one (guests too, 2026-10-13).
    func testPrefillSummaryNamesTheOrderEmailOnlyWhenItIsOne() throws {
        let buyer = "checkout[shipping_address][first_name]=Zo&checkout[shipping_address][address1]=12-Main&checkout[shipping_address][city]=Brooklyn"
        let relayed = try XCTUnwrap(URL(string: "https://koba.com/cart/1:1?\(buyer)&checkout[email]=u-test2k7m9q@orders.marracat.com"))
        XCTAssertEqual(BrandCheckout.prefillSummary(relayed), "Ships to Zo, 12-Main, Brooklyn · order email u-test2k7m9q@orders.marracat.com")
        let own = try XCTUnwrap(URL(string: "https://koba.com/cart/1:1?\(buyer)&checkout[email]=me@example.com"))
        XCTAssertEqual(BrandCheckout.prefillSummary(own), "Ships to Zo, 12-Main, Brooklyn")
    }

    /// 2026-10-13: the unit-test host app on simulator install c8ebe62c
    /// registered made-up orders on marracat.com. Under XCTest no order call
    /// leaves the phone: tracking, late reports and the order email.
    @MainActor
    func testTestsNeverReachTheOrderEndpoints() async throws {
        XCTAssertFalse(AppChannel.reachesOrderServer)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        RecordingProtocol.seen = []
        let tracking = OrderTrackingStore(defaults: UserDefaults(suiteName: "guard-\(UUID())")!, session: URLSession(configuration: config))
        await tracking.register(brandID: "koba-skincare", checkoutID: nil, orderID: "gid://shopify/OrderIdentity/123", items: ["Comb"])
        tracking.stubOrders([TrackedOrder(brandID: "koba-skincare", checkoutID: "x", orderID: nil, permalink: nil, state: "confirmed",
                                          carrier: nil, trackingNumber: nil, trackingURL: nil, created: 0, updated: nil)])
        await tracking.refresh()
        XCTAssertEqual(RecordingProtocol.seen, [], "an order call left the test")
        let relay = RelayStore(defaults: UserDefaults(suiteName: "guard-\(UUID())")!)
        relay.attach(AccountStore(defaults: UserDefaults(suiteName: "guard-acct-\(UUID())")!))
        await relay.refresh()
        let prepared = await relay.prepare(forwardTo: "me@example.com", deviceKey: nil)
        XCTAssertNil(prepared)
        XCTAssertFalse(relay.guest)
    }
}

/// Records any request that reaches it, and answers none.
final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var seen: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { seen.append(request.url?.path ?? "?"); return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
