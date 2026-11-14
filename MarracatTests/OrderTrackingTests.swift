import XCTest
@testable import Marracat

/// Tracking that works when Apple Pay gave the brand the wallet's email:
/// finding an order's tracked state and turning it into tracker steps.
@MainActor
final class OrderTrackingTests: XCTestCase {
    private func store(_ orders: [TrackedOrder]) -> OrderTrackingStore {
        let s = OrderTrackingStore(defaults: UserDefaults(suiteName: "tracking-\(UUID())")!)
        s.stubOrders(orders)
        return s
    }
    private func order(_ brand: String, _ id: String?, state: String?, tracking: String? = nil, permalink: String? = nil) -> TrackedOrder {
        TrackedOrder(brandID: brand, checkoutID: "gid://shopify/Checkout/abc", orderID: id, permalink: permalink, state: state,
                     carrier: tracking == nil ? nil : "USPS", trackingNumber: tracking, trackingURL: nil, created: 1_790_000_000_000, updated: 1_790_100_000_000)
    }

    func testOrderNumberMatchesAcrossOrderAndOrderIdentity() {
        XCTAssertEqual(OrderTrackingStore.number("gid://shopify/OrderIdentity/18920612135005"), "18920612135005")
        XCTAssertEqual(OrderTrackingStore.number("gid://shopify/Order/18920612135005"), "18920612135005")
        XCTAssertEqual(OrderTrackingStore.number("gid://shopify/Checkout/abc?key=123"), "abc")
        let s = store([order("honey", "gid://shopify/Order/18920612135005", state: "shipped", tracking: "9400111899223197428490")])
        let record = CheckoutRecord(brandID: "honey", date: .now, itemCount: 1, subtotal: 13.99, productIDs: ["p"],
                                    orderID: "gid://shopify/OrderIdentity/18920612135005")
        XCTAssertNotNil(s.tracked(for: record))
        let other = CheckoutRecord(brandID: "other", date: .now, itemCount: 1, subtotal: 1, productIDs: ["p"],
                                   orderID: "gid://shopify/OrderIdentity/18920612135005")
        XCTAssertNil(s.tracked(for: other), "another brand's order with the same number is not this one")
    }

    func testStatesBecomeTrackerSteps() {
        let record = CheckoutRecord(brandID: "honey", date: .now, itemCount: 1, subtotal: 1, productIDs: ["p"], orderID: "gid://shopify/OrderIdentity/1")
        XCTAssertEqual(RelayStore.step(store([order("honey", "gid://shopify/Order/1", state: "confirmed")]).events(for: record)), 0)
        let shipped = store([order("honey", "gid://shopify/Order/1", state: "shipped", tracking: "9400111899223197428490")]).events(for: record)
        XCTAssertEqual(RelayStore.step(shipped), 1)
        XCTAssertEqual(shipped.first?.trackingNumber, "9400111899223197428490")
        XCTAssertEqual(RelayStore.step(store([order("honey", "gid://shopify/Order/1", state: "out_for_delivery")]).events(for: record)), 2)
        XCTAssertEqual(RelayStore.step(store([order("honey", "gid://shopify/Order/1", state: "delivered")]).events(for: record)), 3)
    }

    func testOnlyHttpsStatusPagesOpen() {
        XCTAssertNotNil(order("h", nil, state: nil, permalink: "https://thehoneypot.co/1/orders/abc").statusPage)
        XCTAssertNil(order("h", nil, state: nil, permalink: "http://thehoneypot.co/1/orders/abc").statusPage)
        XCTAssertNil(order("h", nil, state: nil, permalink: "javascript:alert(1)").statusPage)
    }

    /// Owner, 2026-10-13: an order at a brand with no status page opens the
    /// carrier's page for its number; only https links open.
    func testTrackPackageFallsBackToTheCarrierPage() {
        var o = order("ripl", "gid://shopify/OrderIdentity/7461559533591", state: "shipped", tracking: "1LSD0VW001F9GHU")
        XCTAssertNil(o.trackPage)
        o.trackingURL = "https://www.ontrac.com/tracking/?number=1LSD0VW001F9GHU"
        XCTAssertEqual(o.trackPage?.host, "www.ontrac.com")
        o.permalink = "https://riplefek.com/1/orders/abc"
        XCTAssertEqual(o.trackPage?.host, "riplefek.com", "the brand's status page comes first")
        o.permalink = nil; o.trackingURL = "http://www.ontrac.com/x"
        XCTAssertNil(o.trackPage)
    }

    /// Every recent Shopify order on the phone the server doesn't follow gets
    /// registered (RIPL EFEK #1417 never was); older, non-Shopify and already
    /// followed orders don't.
    func testUnregisteredFindsRecentShopifyOrdersTheServerDoesNotFollow() {
        let now = Date()
        func rec(_ brand: String, _ id: String?, daysAgo: Double = 1) -> CheckoutRecord {
            CheckoutRecord(brandID: brand, date: now.addingTimeInterval(-daysAgo * 86_400), itemCount: 1, subtotal: 1, productIDs: ["p"], orderID: id)
        }
        let records = [rec("ripl", "gid://shopify/OrderIdentity/7461559533591"),
                       rec("koba", "gid://shopify/OrderIdentity/17374756274563"),
                       rec("old", "gid://shopify/OrderIdentity/1", daysAgo: 31),
                       rec("woo", "1234"),
                       rec("none", nil)]
        let followed = [order("koba", "gid://shopify/OrderIdentity/17374756274563", state: "delivered")]
        XCTAssertEqual(OrderTrackingStore.unregistered(records, tracked: followed, now: now).map(\.brandID), ["ripl"])
    }
}
