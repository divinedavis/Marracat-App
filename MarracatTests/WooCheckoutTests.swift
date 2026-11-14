import SwiftUI
import XCTest
@testable import Marracat

/// WooCommerce brands checked out from the app: 10.0+ stores take one
/// shareable checkout link for the whole cart; older ones take one
/// add-to-cart request per line, then their checkout page.
final class WooCheckoutTests: XCTestCase {
    private func brand(_ checkout: String?, platform: String = "woocommerce") -> Brand {
        Brand(id: "b", name: "B", domain: "shop.example", category: "grocery", tagline: nil,
              shopify: true, platform: platform, image: nil, checkout: checkout)
    }

    private let lines = [CartLine(productID: "b-2449", variantID: 2449, quantity: 2),
                         CartLine(productID: "b-189", variantID: 189, quantity: 1)]

    func testCheckoutLinkCarriesEveryLine() throws {
        let b = brand("link")
        XCTAssertTrue(b.usesMarracatCart)
        let url = try XCTUnwrap(CartStore.checkoutURL(brand: b, lines: lines))
        XCTAssertEqual(url.absoluteString, "https://shop.example/checkout-link/?products=2449:2,189:1")
        XCTAssertTrue(CartStore.wooAddToCartSteps(brand: b, lines: lines).isEmpty)
    }

    func testOlderStoresAddEachLineThenCheckOut() throws {
        let b = brand("add")
        XCTAssertTrue(b.usesMarracatCart)
        XCTAssertEqual(CartStore.checkoutURL(brand: b, lines: lines)?.absoluteString, "https://shop.example/checkout/")
        XCTAssertEqual(CartStore.wooAddToCartSteps(brand: b, lines: lines).map(\.absoluteString),
                       ["https://shop.example/?add-to-cart=2449&quantity=2",
                        "https://shop.example/?add-to-cart=189&quantity=1"])
    }

    /// Unverified Woo stores (Ten To One) keep opening the brand's own site.
    func testUnverifiedWooStoresStayOutOfTheCart() {
        let b = brand(nil)
        XCTAssertFalse(b.usesMarracatCart)
        XCTAssertEqual(CartStore.checkoutURL(brand: b, lines: lines)?.absoluteString, "https://shop.example")
    }

    func testShopifyIsUnchanged() {
        XCTAssertTrue(brand(nil, platform: "shopify").usesMarracatCart)
        XCTAssertFalse(brand("link", platform: "shopify").checksOutByWooLink)
    }

    /// The sheet itself renders: UI tests stub checkout (no real sessions on
    /// brands' stores), so this is the one test that draws WooCheckoutSheet.
    /// about:blank keeps it off the network.
    @MainActor
    func testTheSheetRendersWithoutAStore() throws {
        let req = CheckoutRequest(brand: brand("link"), lines: lines, url: try XCTUnwrap(URL(string: "about:blank")))
        let host = UIHostingController(rootView: WooCheckoutSheet(request: req, onCompleted: { _ in }, onClose: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertFalse(host.view.subviews.isEmpty, "the Woo checkout sheet drew nothing")
        window.isHidden = true
    }
}
