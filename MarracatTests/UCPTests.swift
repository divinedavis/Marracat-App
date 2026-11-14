import XCTest
@testable import Marracat

final class UCPTests: XCTestCase {
    /// Trimmed from a real reply by Hope for Flowers' store on 2026-09-21:
    /// a checkout that priced shipping but still wants a phone number, which
    /// Shopify flags `isError` even though the checkout is perfectly usable.
    private let hopeForFlowers = """
    {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"…"}],"isError":true,"structuredContent":{
      "ucp":{"version":"2026-08-25","status":"success"},
      "id":"gid://shopify/Checkout/hWNH67StL7FxfbuxjsxovJys?key=0ca6","status":"incomplete","currency":"USD",
      "continue_url":"https://hope-for-flowers-by-tr.myshopify.com/cart/c/hWNH67StL7FxfbuxjsxovJys?key=SFGB9S",
      "expires_at":"2026-10-21T18:51:51Z",
      "totals":[{"type":"subtotal","amount":24800,"display_text":"Subtotal"},{"type":"fulfillment","amount":684,"display_text":"Shipping"},{"type":"total","amount":25484,"display_text":"Total"}],
      "messages":[{"type":"error","content_type":"plain","code":"delivery_phone_number_required","content":"Enter a phone number to use this delivery method","severity":"recoverable"}],
      "buyer":{"email":"test@example.com"},
      "line_items":[{"id":"gid://shopify/CartLine/a6eb?cart=hWNH","item":{"id":"gid://shopify/ProductVariant/51998231003349","title":"Frilled Buttondown - XS / Garden Floral","price":24800,"image_url":"https://cdn.shopify.com/x.jpg"},"quantity":1,"totals":[{"type":"total","amount":24800}]}],
      "fulfillment":{"methods":[{"id":"c2hpcHBpbmc=","type":"shipping","line_item_ids":["gid://shopify/CartLine/a6eb?cart=hWNH"],"selected_destination_id":"033f","destinations":[{"first_name":"Test","last_name":"Buyer","street_address":"1 Main St","address_locality":"Brooklyn","address_region":"NY","postal_code":"11201","address_country":"US","id":"033f"}],
        "groups":[{"id":"gid://shopify/CartDeliveryGroup/269e?cart=hWNH","line_item_ids":["gid://shopify/CartLine/a6eb?cart=hWNH"],"selected_option_id":"f932","options":[{"id":"f932","title":"UPS® Ground","description":{"plain":"2 business days via 03"},"totals":[{"type":"total","amount":684}]}]}]}]},
      "links":[{"type":"refund_policy","title":"Refund Policy","url":"https://checkout.shopify.com/x"}],"discounts":{}}}}
    """

    private let buyer = BuyerDetails(firstName: "Test", lastName: "Buyer", email: "test@example.com", phone: "7185550100",
                                     street: "1 Main St", extended: "", city: "Brooklyn", region: "NY", postalCode: "11201")

    func testParsesAStoreReplyIncludingItsErrorFlaggedCheckout() throws {
        let c = try UCPClient.parse(Data(hopeForFlowers.utf8))
        XCTAssertEqual(c.status, .incomplete)
        XCTAssertEqual(c.total, 25484)
        XCTAssertEqual(c.shipping, 684)
        XCTAssertEqual(c.shippingOption, "UPS® Ground")
        XCTAssertEqual(c.continueURL?.host, "hope-for-flowers-by-tr.myshopify.com")
        XCTAssertEqual(c.blockers.first?.code, "delivery_phone_number_required")
        XCTAssertTrue(c.needsAttention)
        XCTAssertEqual(c.lineItems?.first?.item.title, "Frilled Buttondown - XS / Garden Floral")
    }

    func testParsesAnSSEFramedReply() throws {
        let sse = "event: message\ndata: \(hopeForFlowers.replacingOccurrences(of: "\n", with: ""))\n\n"
        let c = try UCPClient.parse(Data(sse.utf8), contentType: "text/event-stream")
        XCTAssertEqual(c.total, 25484)
    }

    func testRPCErrorsSurfaceTheStoresReason() {
        let reply = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32001,"message":"UCP discovery failed","data":{"code":"profile_unreachable","content":"Unable to fetch agent profile: Http error"}}}"#
        XCTAssertThrowsError(try UCPClient.parse(Data(reply.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Unable to fetch agent profile: Http error")
        }
    }

    /// The request names Marracat's hosted profile, the variant as a Shopify
    /// GID, the buyer with a phone (stores refuse delivery without one), one
    /// shipping destination, and the same attribution the permalinks carry.
    func testCreateBodyShape() throws {
        let body = UCPClient.createBody(currency: "USD", lines: [UCPLineRequest(variantID: 51998231003349, quantity: 2, unitPriceMinor: 24800)], buyer: buyer)
        let checkout = try XCTUnwrap(body["checkout"] as? [String: Any])
        let lines = try XCTUnwrap(checkout["line_items"] as? [[String: Any]])
        XCTAssertEqual((lines[0]["item"] as? [String: Any])?["id"] as? String, "gid://shopify/ProductVariant/51998231003349")
        XCTAssertEqual(lines[0]["quantity"] as? Int, 2)
        let b = try XCTUnwrap(checkout["buyer"] as? [String: Any])
        XCTAssertEqual(b["phone_number"] as? String, "7185550100")
        let methods = try XCTUnwrap((checkout["fulfillment"] as? [String: Any])?["methods"] as? [[String: Any]])
        let dest = try XCTUnwrap((methods[0]["destinations"] as? [[String: Any]])?.first)
        XCTAssertEqual(dest["address_locality"] as? String, "Brooklyn")
        XCTAssertEqual(dest["address_country"] as? String, "US")
        XCTAssertNil(dest["extended_address"], "an empty apartment line is left out")
        XCTAssertEqual((checkout["attribution"] as? [String: Any])?["utm_source"] as? String, CartStore.referral)
        XCTAssertEqual(UCPClient.profileURL, "https://marracat.com/.well-known/ucp")
    }

    /// No details saved (owner, 2026-11-02: no Marracat form before
    /// checkout): no destination and no blank buyer fields go to the store,
    /// whose own checkout asks for the address. A signed-in shopper's name
    /// and email still go.
    func testCreateBodyWithoutAnAddressLeavesItToTheStore() throws {
        let line = [UCPLineRequest(variantID: 51281760944413, quantity: 1, unitPriceMinor: 4500)]
        let bare = try XCTUnwrap(UCPClient.createBody(currency: "USD", lines: line, buyer: BuyerDetails())["checkout"] as? [String: Any])
        XCTAssertNil(bare["fulfillment"], "no address, no destination")
        XCTAssertNil(bare["buyer"], "nothing given, no buyer")
        XCTAssertNotNil(bare["line_items"]); XCTAssertNotNil(bare["attribution"])

        let account = BuyerDetails().filling(name: "Kaila Price", email: "k@example.com")
        let named = try XCTUnwrap(UCPClient.createBody(currency: "USD", lines: line, buyer: account)["checkout"] as? [String: Any])
        let b = try XCTUnwrap(named["buyer"] as? [String: Any])
        XCTAssertEqual(b["email"] as? String, "k@example.com")
        XCTAssertEqual(b["first_name"] as? String, "Kaila")
        XCTAssertNil(b["phone_number"], "a blank phone is left out, not sent empty")
        XCTAssertNil(named["fulfillment"])
    }

    func testStubCheckoutPricesTheLinesAndIsReadyToPay() {
        let c = UCPClient.stubCheckout(endpoint: URL(string: "https://x.myshopify.com/api/ucp/mcp")!, currency: "USD",
                                       lines: [UCPLineRequest(variantID: 1, quantity: 2, unitPriceMinor: 1000), UCPLineRequest(variantID: 2, quantity: 1, unitPriceMinor: 550)])
        XCTAssertEqual(c.status, .readyForComplete)
        XCTAssertEqual(c.total, 2550 + 500)
        XCTAssertFalse(c.needsAttention)
        XCTAssertNotNil(c.continueURL)
    }

    func testBuyerDetailsCompleteness() {
        XCTAssertTrue(buyer.isComplete)
        var b = buyer; b.email = "nope"
        XCTAssertFalse(b.isComplete)
        var c = buyer; c.phone = " "
        XCTAssertFalse(c.isComplete)
    }

    func testBuyerStorePersistsPerAccount() {
        let defaults = UserDefaults(suiteName: "UCPTests.\(UUID())")!
        let vault = MemoryBuyerVault()
        let store = BuyerStore(defaults: defaults, vault: vault)
        XCTAssertNil(store.details)
        store.save(buyer)
        XCTAssertEqual(BuyerStore(defaults: defaults, vault: vault).details, buyer)
        XCTAssertNil(defaults.data(forKey: "buyer.details.v1"), "never in UserDefaults") // gitleaks:allow (a UserDefaults key name)
        store.activate("acct")
        XCTAssertNil(store.details, "another account starts empty")
        store.activate(nil)
        XCTAssertEqual(store.details, buyer)
        store.eraseAccountCache()
        XCTAssertNil(store.details)
    }

    /// Opt-in: builds a real checkout on a brand's store (no order is placed;
    /// the checkout expires on its own). TEST_RUNNER_REAL_UCP=1 to run.
    func testRealStoreBuildsACheckoutFromSavedDetails() async throws {
        guard ProcessInfo.processInfo.environment["REAL_UCP"] == "1" else { throw XCTSkip("set TEST_RUNNER_REAL_UCP=1") }
        let c = try await UCPClient().createCheckout(endpoint: URL(string: "https://karbon-footprint.myshopify.com/api/ucp/mcp")!,
                                                     currency: "USD", lines: [UCPLineRequest(variantID: 47248505634985, quantity: 1, unitPriceMinor: 11000)], buyer: buyer)
        print("REAL UCP:", c.status, c.total ?? -1, c.shippingOption ?? "-", c.continueUrl ?? "-", c.blockers.map { $0.code ?? "" })
        XCTAssertNotNil(c.continueURL)
        XCTAssertNotNil(c.total)
        XCTAssertTrue(c.status == .readyForComplete || c.status == .incomplete)
    }
}

@MainActor
final class UCPCheckoutBrandTests: XCTestCase {
    /// Telfar's cart permalink lands on its home page, so it gets none: the
    /// review screen builds its checkout over UCP instead.
    func testUCPOnlyBrandHasNoPermalinkButOthersDo() throws {
        let catalog = CatalogStore(synchronously: true)
        let telfar = try XCTUnwrap(catalog.brand("telfar"))
        XCTAssertTrue(telfar.checksOutByUCP)
        // The bundled catalog drops variants on many products (a product page
        // fetches them), so take the first one that still carries one in stock.
        let p = try XCTUnwrap(catalog.products(for: "telfar").first { $0.available && $0.variants.contains { $0.available } })
        let v = try XCTUnwrap(p.variants.first { $0.available })
        XCTAssertNil(CartStore.checkoutURL(brand: telfar, lines: [CartLine(productID: p.id, variantID: v.id, quantity: 1)]))
        // Any Shopify brand that takes a cart link and has something in stock:
        // the one this named (Karbon Footprint) left the catalog on 2026-11-01
        // and took the test with it.
        let (other, op) = try XCTUnwrap(catalog.brands.lazy
            .filter { $0.isShopify && !$0.checksOutByUCP }
            .compactMap { b in catalog.products(for: b.id).first { $0.available && $0.variants.contains { $0.available } }.map { (b, $0) } }
            .first)
        let ov = try XCTUnwrap(op.variants.first { $0.available })
        XCTAssertNotNil(CartStore.checkoutURL(brand: other, lines: [CartLine(productID: op.id, variantID: ov.id, quantity: 1)]))
    }
}
