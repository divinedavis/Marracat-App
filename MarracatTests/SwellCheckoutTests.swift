import Foundation
import Testing
@testable import Marracat

/// Swell brands check out from the app (owner, 2026-10-10: Yeezy first):
/// marracat.com/go/swell builds the Swell cart and redirects to the brand's
/// own checkout, so the sheet opens that one URL with no cart steps.
struct SwellCheckoutTests {
    private let brand = Brand(id: "yeezy", name: "YEEZY", domain: "yeezy.com", category: "clothing", tagline: nil,
                              shopify: true, platform: "swell", image: nil)
    private let lines = [CartLine(productID: "yeezy-6a91f2d30942e900131a077b", variantID: 358757638017136, quantity: 2),
                         CartLine(productID: "yeezy-6949eee64149030012a91e55", variantID: 42, quantity: 1)]

    @Test func checksOutThroughMarracatsSwellHandOff() throws {
        #expect(brand.usesMarracatCart && brand.checksOutBySwell && !brand.isShopify)
        let url = try #require(CartStore.checkoutURL(brand: brand, lines: lines))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "marracat.com" && comps.path == "/go/swell")
        #expect(comps.queryItems?.first { $0.name == "brand" }?.value == "yeezy")
        #expect(comps.queryItems?.first { $0.name == "items" }?.value
                == "yeezy-6a91f2d30942e900131a077b:358757638017136:2,yeezy-6949eee64149030012a91e55:42:1")
        #expect(CartStore.cartSteps(brand: brand, lines: lines).isEmpty)
    }

    @Test func theSheetMayFollowTheRedirectToTheBrandsCheckout() throws {
        let start = try #require(CartStore.checkoutURL(brand: brand, lines: lines))
        let policy = CheckoutNavigationPolicy(brand: brand, start: [start])
        #expect(policy.decision(for: start) == .allow)
        #expect(policy.decision(for: URL(string: "https://yeezy.com/checkout/d07a9d8da1c14aef7d5454a844c7ad26")!) == .allow)
        #expect(policy.decision(for: URL(string: "https://elsewhere.example/")!) == .openOutside)
    }
}
