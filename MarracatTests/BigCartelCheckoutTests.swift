import Foundation
import Testing
@testable import Marracat

/// Big Cartel brands check out from the app (owner, 2026-10-04): the sheet
/// posts each line to the store's cart (one item a post), then opens checkout.
struct BigCartelCheckoutTests {
    private func brand(_ domain: String = "therenaebrandd.bigcartel.com", sub: String? = nil) -> Brand {
        var b = Brand(id: "r", name: "R", domain: domain, category: "jewelry", tagline: nil,
                      shopify: true, platform: "bigcartel", image: nil, checkout: "bigcartel")
        b.bigcartel = sub
        return b
    }
    private let lines = [CartLine(productID: "r-1", variantID: 301038729, quantity: 2),
                         CartLine(productID: "r-2", variantID: 301038726, quantity: 1)]

    @Test func postsEachLineThenOpensCheckout() throws {
        let b = brand()
        #expect(b.usesMarracatCart && !b.isShopify)
        let steps = CartStore.cartSteps(brand: b, lines: lines)
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.httpMethod == "POST" && $0.url?.absoluteString == "https://therenaebrandd.bigcartel.com/cart" })
        #expect(String(decoding: try #require(steps[0].httpBody), as: UTF8.self) == "cart%5Badd%5D%5Bid%5D=301038729&cart%5Badd%5D%5Bquantity%5D=2")
        #expect(CartStore.checkoutURL(brand: b, lines: lines)?.absoluteString == "https://therenaebrandd.bigcartel.com/checkout")
    }

    @Test func aCustomDomainStillUsesItsBigCartelHost() {
        let b = brand("shoprenae.com", sub: "therenaebrandd")
        #expect(b.bigCartelHost == "therenaebrandd.bigcartel.com")
        #expect(CartStore.cartSteps(brand: b, lines: lines).first?.url?.host == "therenaebrandd.bigcartel.com")
    }
}
