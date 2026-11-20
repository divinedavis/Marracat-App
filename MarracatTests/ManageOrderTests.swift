import Foundation
import Testing
@testable import Marracat

/// "Manage your order" on Order details (owner, 2026-11-19): the brand's own
/// page for the order when we have its link, else a Shopify brand's account
/// page; nothing for a brand whose site has neither.
@MainActor
struct ManageOrderTests {
    private func brand(platform: String?) throws -> Brand {
        var json: [String: Any] = ["id": "goodee", "name": "Goodee", "domain": "goodeeworld.com", "category": "home", "shopify": platform == "shopify"]
        json["platform"] = platform
        return try JSONDecoder().decode(Brand.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func tracked(_ permalink: String?) -> TrackedOrder {
        TrackedOrder(brandID: "goodee", checkoutID: "c", orderID: nil, permalink: permalink, state: "confirmed",
                     carrier: nil, trackingNumber: nil, trackingURL: nil, created: 1_790_000_000_000, updated: nil)
    }

    @Test func theOrdersOwnPageComesFirst() throws {
        let page = "https://www.goodeeworld.com/7116849252/orders/abc"
        #expect(OrderDetailView.managePage(tracked: tracked(page), brand: try brand(platform: "shopify"))?.absoluteString == page)
    }

    @Test func elseAShopifyBrandsAccountPage() throws {
        let shopify = try brand(platform: "shopify")
        #expect(OrderDetailView.managePage(tracked: nil, brand: shopify)?.absoluteString == "https://goodeeworld.com/account")
        #expect(OrderDetailView.managePage(tracked: tracked("http://insecure.example/x"), brand: shopify)?.absoluteString
                == "https://goodeeworld.com/account", "a link that isn't https is never opened")
    }

    @Test func nothingForOtherShopsWithoutALink() throws {
        #expect(OrderDetailView.managePage(tracked: nil, brand: try brand(platform: "woocommerce")) == nil)
        #expect(OrderDetailView.managePage(tracked: nil, brand: nil) == nil)
    }
}
