import XCTest
@testable import Marracat

final class OrderDetailsTests: XCTestCase {
    func testOrderNumberComesOutOfTheGid() {
        XCTAssertEqual(ShopifyIDs.number("gid://shopify/OrderIdentity/8622093435066"), "8622093435066")
        XCTAssertEqual(ShopifyIDs.number("7609639960769"), "7609639960769")
        XCTAssertEqual(ShopifyIDs.number("gid://shopify/Order/123?key=abc"), "123")
        XCTAssertNil(ShopifyIDs.number(nil))
        XCTAssertNil(ShopifyIDs.number(""))
        XCTAssertNil(ShopifyIDs.number("gid://shopify/OrderIdentity/abc"))
        XCTAssertNil(ShopifyIDs.number("woo-order"))
        XCTAssertEqual(ShopifyIDs.variant("gid://shopify/ProductVariant/47248505634985"), 47248505634985)
        XCTAssertNil(ShopifyIDs.variant(nil))
    }

    /// Order details shows the catalog's full-size photo, not Checkout Kit's
    /// thumbnail (owner, 2026-11-11: "the images are pixelated").
    func testOrderPhotoPrefersTheFullSizeCatalogPhoto() {
        let record = CheckoutRecord(brandID: "b", date: .now, itemCount: 1, subtotal: 28, productIDs: ["p"])
        func item(_ p: Product?, _ variantID: Int64? = nil, line image: String? = "https://cdn.shopify.com/thumb_128x128.jpg") -> OrderItem {
            OrderItem(id: "1", record: record, title: "Ase", quantity: 1, product: p,
                      line: OrderExtras.Line(title: "Ase", quantity: 1, variantID: variantID, image: image))
        }
        var p = Product(id: "p", brand: "b", title: "Ase", category: "household", productType: nil, subs: [], price: 28,
                        compareAt: nil, images: ["https://cdn.shopify.com/full.jpg", "https://cdn.shopify.com/blue.jpg"],
                        url: "https://b.example/p", available: true, variants: [], tags: [], description: nil,
                        publishedAt: nil, bestRank: nil, attrs: nil)
        XCTAssertEqual(item(p).image, "https://cdn.shopify.com/full.jpg")
        p.variants = [Variant(id: 7, title: "Blue", price: 28, available: true, image: 1),
                      Variant(id: 8, title: "Red", price: 28, available: true, image: 5)]
        XCTAssertEqual(item(p, 7).image, "https://cdn.shopify.com/blue.jpg", "the colour bought, from the catalog")
        XCTAssertEqual(item(p, 8).image, "https://cdn.shopify.com/thumb_128x128.jpg",
                       "a colour the bundled catalog has no photo of keeps the line's own")
        XCTAssertEqual(item(nil).image, "https://cdn.shopify.com/thumb_128x128.jpg", "a product gone from the catalog")
        XCTAssertEqual(item(p, line: nil).image, "https://cdn.shopify.com/full.jpg")
    }

    func testShopifyPhotoSizeDropsHeightAndCrop() {
        let u = sizedImageURL("https://cdn.shopify.com/s/files/a.jpg?v=1&width=128&height=128&crop=center", width: 900)
        let items = URLComponents(url: u!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "width" }?.value, "900")
        XCTAssertNil(items.first { $0.name == "height" })
        XCTAssertNil(items.first { $0.name == "crop" })
    }

    func testExtrasStayOnThisPhoneAndSummarize() {
        let defaults = UserDefaults(suiteName: "OrderExtrasTests-\(UUID())")!
        let store = OrderExtrasStore(defaults: defaults)
        let ship = OrderExtras.summarize(address: ("Divine Davis", nil, nil, "251 Dekalb Ave", "Apt 1", "Brooklyn", "NY", "11205", "US"))
        XCTAssertEqual(ship?.lines, ["251 Dekalb Ave", "Apt 1", "Brooklyn, NY 11205"])
        store.save(OrderExtras(subtotal: 6, shipping: 5, discounts: 1, taxes: 0.31, total: 10.31, currency: "USD", shipTo: ship,
                               deliveryMethod: "SHIPPING · Standard",
                               payment: OrderExtras.paymentLabel(type: "creditCard", details: ["brand": "Visa", "last4": "4242"]),
                               email: "shopper@example.com"),
                   brandID: "scotch-porter", orderID: "gid://shopify/OrderIdentity/1")
        let again = OrderExtrasStore(defaults: defaults).extras(brandID: "scotch-porter", orderID: "gid://shopify/OrderIdentity/1")
        XCTAssertEqual(again?.payment, "Visa •••• 4242")
        XCTAssertEqual(again?.total, 10.31)
        XCTAssertEqual(again?.discounts, 1)
        XCTAssertEqual(again?.email, "shopper@example.com")
        XCTAssertNil(store.extras(brandID: "scotch-porter", orderID: nil))
        XCTAssertEqual(OrderExtras.paymentLabel(type: "shopPay", details: [:]), "Shop Pay")
        XCTAssertEqual(OrderExtras.paymentLabel(type: "creditCard", details: ["last4": "12345"]), "Card")
        // The synced record has no room for these fields.
        let record = CheckoutRecord(brandID: "b", date: .now, itemCount: 1, subtotal: 6, productIDs: ["p"])
        let json = String(data: try! JSONEncoder().encode(record), encoding: .utf8)!
        XCTAssertFalse(json.contains("shipTo") || json.contains("payment") || json.contains("email"))
    }

    /// The receipt (ReceiptSheet; owner, 2026-10-23) prints only what the
    /// brand reported, and Copy carries the same.
    func testReceiptLeavesOutUnreportedRowsAndCopiesTheSame() {
        let r = OrderReceipt(brand: "Brandon Blackwood", orderName: "#1042", shopifyNumber: "8622093435066",
                             date: Date(timeIntervalSince1970: 1_792_800_000), payment: "Apple Pay",
                             lines: [.init(title: "Slim Trunk", option: "Black", quantity: 1, amount: 290)],
                             subtotal: 290, shipping: 0, taxes: 25.74, total: 315.74, currency: "USD")
        XCTAssertEqual(r.rows.map(\.0), ["Item(s) subtotal", "Shipping & handling", "Tax"], "no Discounts row: none reported")
        XCTAssertEqual(r.rows[1].1, "Free")
        XCTAssertEqual(r.code, "1042", "the barcode carries the brand's order number")
        XCTAssertTrue(r.text.contains("1 × Slim Trunk (Black)  $290.00"), r.text)
        XCTAssertTrue(r.text.contains("Total: $315.74") && r.text.contains("Paid with Apple Pay"), r.text)

        let bare = OrderReceipt(brand: "B", orderName: nil, shopifyNumber: "77", date: .now, payment: nil,
                                lines: [.init(title: "Tee", option: nil, quantity: 2, amount: nil)],
                                subtotal: nil, shipping: nil, taxes: nil, total: nil, currency: "GBP")
        XCTAssertTrue(bare.rows.isEmpty)
        XCTAssertEqual(bare.code, "77", "Shopify's number when the brand's hasn't arrived")
        XCTAssertFalse(bare.text.contains("Total") || bare.text.contains("Paid with"), bare.text)
    }
}
