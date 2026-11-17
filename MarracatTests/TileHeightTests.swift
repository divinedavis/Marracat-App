import SwiftUI
import Testing
import UIKit
@testable import Marracat

/// Every product card is the same height under its photo, whatever it carries
/// (owner, 2026-11-16: "I still see too much space between the price and the
/// bottom border of a row"). A sale tag, badge icons or a second currency line
/// made some cards taller, and a sideways row reserves its tallest card, so
/// every other card in the row had a blank band under its price. The sale tag
/// and badges now sit on the photo and the brand's currency beside the price.
@MainActor
struct TileHeightTests {
    private func product(_ id: String, compareAt: Double? = nil, currency: String? = nil, clean: Bool? = nil) -> Product {
        var p = Product(id: id, brand: "b", title: "A product name long enough to wrap onto two lines", category: "hair",
                        productType: nil, subs: [], price: 20, compareAt: compareAt, images: [],
                        url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                        publishedAt: nil, bestRank: nil)
        p.currency = currency
        p.clean = clean
        return p
    }

    private func height(_ p: Product, store: CatalogStore) -> CGFloat {
        let host = UIHostingController(rootView: ProductTile(product: p, imageSide: ProductRow.tileWidth)
            .frame(width: ProductRow.tileWidth)
            .environment(store))
        return host.sizeThatFits(in: CGSize(width: ProductRow.tileWidth, height: 2_000)).height
    }

    @Test func aSaleABadgeAndAnotherCurrencyAddNoHeight() {
        let cards = [product("plain"), product("sale", compareAt: 40), product("euro", currency: "EUR"),
                     product("clean", clean: true), product("all", compareAt: 40, currency: "EUR", clean: true)]
        let store = CatalogStore(catalog: Catalog(generatedAt: "2026-11-16T00:00:00Z", categories: [], subcategories: [],
                                                  brands: [], products: cards))
        let plain = height(cards[0], store: store)
        #expect(plain > ProductRow.tileWidth)
        for card in cards.dropFirst() {
            #expect(abs(height(card, store: store) - plain) < 0.5, "\(card.id) is a different height")
        }
    }
}
