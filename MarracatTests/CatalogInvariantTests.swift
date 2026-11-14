import Foundation
import Testing
@testable import Marracat

/// Swift Testing (Apple's framework for new unit tests since Xcode 16), added
/// 2026-10-03 beside the XCTest suites. Each argument is its own case, so a
/// failure names the exact text, currency or brand that broke.

@Suite("Comment filter")
struct ContentFilterCases {
    /// Ordinary talk passes, swearing and words that merely contain a slur included.
    @Test(arguments: ["This shea butter is the shit", "Rapeseed oil base, love it", "Grape scent is nice",
                      "my raccoon hat", "Scunthorpe delivery was quick", "Love it! 5 stars"])
    func allows(_ text: String) {
        #expect(ContentFilter.refusal(text) == nil)
    }

    /// Slurs, their spaced and leetspeak evasions, threats and links do not.
    @Test(arguments: ["you n i g g e r", "n1gg3r", "f4gg0t", "go die", "kill your self",
                      "check www.scam.io", "https://evil.test/x", "visit brand.com"])
    func refuses(_ text: String) {
        #expect(ContentFilter.refusal(text) != nil)
    }
}

@Suite("Money")
struct MoneyCases {
    @Test(arguments: [("USD", "$"), ("GBP", "£"), ("EUR", "€")])
    func symbol(_ currency: String, _ symbol: String) {
        #expect(Money.string(25, currency: currency).contains(symbol))
    }
}

/// Whole-catalog properties: what every product and brand the app ships must
/// satisfy, whichever brands are added or dropped (the bundled catalog is
/// rebuilt on every ship).
@Suite("Catalog")
struct CatalogCases {
    static let catalog = CatalogStore(synchronously: true).catalog

    @Test("every product's brand exists")
    func productsHaveBrands() {
        let brands = Set(Self.catalog.brands.map(\.id))
        let orphans = Self.catalog.products.filter { !brands.contains($0.brand) }.map(\.id)
        #expect(orphans.isEmpty, "products with no brand: \(orphans.prefix(5))")
    }

    @Test("product ids are unique")
    func uniqueIDs() {
        let ids = Self.catalog.products.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("an available product with a variant has a price above zero", arguments: ["USD", "GBP", "EUR"])
    func pricedByCurrency(_ currency: String) {
        let unpriced = Self.catalog.products.filter {
            $0.currencyCode == currency && $0.available && ($0.firstAvailableVariant?.price ?? 1) <= 0
        }.map(\.id)
        #expect(unpriced.isEmpty, "\(currency) products priced at zero: \(unpriced.prefix(5))")
    }

    /// Brands the owner took off stay off: Mielle and Bevel (10/3, sold
    /// outright). The Butter Bar Skincare came off on 10/12 and back on 10/14
    /// (e12dc50: its late order arrived), so it isn't listed here any more.
    @Test("a brand taken off Marracat isn't shipped", arguments: ["Mielle Organics", "Mielle", "Bevel"])
    func removedBrandStaysOff(_ name: String) {
        let back = Self.catalog.brands.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.id)
        #expect(back.isEmpty, "\(name) is back in the catalog: \(back)")
    }

    /// The photo check moved Ruby Love's period underwear out of Wellness
    /// (1f000df): every piece of it is Clothing; only the kits stay Wellness.
    @Test("Ruby Love's period underwear is Clothing")
    func rubyLoveUnderwearIsClothing() {
        let pieces = Self.catalog.products.filter {
            $0.brand == "ruby-love" && $0.title.range(of: "underwear", options: .caseInsensitive) != nil
                && $0.title.range(of: "kit", options: .caseInsensitive) == nil
        }
        #expect(pieces.count > 10, "Ruby Love's underwear left the catalog (\(pieces.count))")
        let misfiled = pieces.filter { $0.category != "clothing" }.map { "\($0.title) → \($0.category)" }
        #expect(misfiled.isEmpty, "\(misfiled.prefix(5))")
    }
}

@Suite("Prices read aloud")
struct SpokenMoneyCases {
    /// What VoiceOver says for a price (Money.spoken, used by PriceView).
    @Test(arguments: [(10.0, "USD", "10 dollars"), (1.0, "USD", "1 dollar"), (12.5, "GBP", "12 pounds 50 pence"),
                      (3.01, "EUR", "3 euros 1 cent"), (0.99, "USD", "0 dollars 99 cents")])
    func spoken(_ value: Double, _ currency: String, _ expected: String) {
        #expect(Money.spoken(value, currency: currency) == expected)
    }
}
