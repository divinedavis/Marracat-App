import SwiftUI
import Testing
import UIKit
@testable import Marracat

/// Every product card is the same height, whatever it carries (owner,
/// 2026-11-16: "I still see too much space between the price and the bottom
/// border of a row"). A sale tag, badge icons or a second currency line made
/// some cards taller, and a sideways row reserves its tallest card, so every
/// other card in the row had a blank band under its price. Badges sit on the
/// photo, a sale and another currency share the price's own line.
@MainActor
struct TileHeightTests {
    private func product(_ id: String, compareAt: Double? = nil, currency: String? = nil, clean: Bool? = nil, available: Bool = true) -> Product {
        var p = Product(id: id, brand: "b", title: "A product name long enough to wrap onto two lines", category: "hair",
                        productType: nil, subs: [], price: 20, compareAt: compareAt, images: [],
                        url: "https://b.example/\(id)", available: available, variants: [], tags: [], description: nil,
                        publishedAt: nil, bestRank: nil)
        p.currency = currency
        p.clean = clean
        return p
    }

    private var cards: [Product] {
        [product("plain"), product("sale", compareAt: 40), product("euro", currency: "EUR"),
         product("clean", clean: true), product("all", compareAt: 40, currency: "EUR", clean: true),
         product("gone", compareAt: 40, available: false),
         product("long", compareAt: 1_234_567.89)]
    }

    private func store(_ cards: [Product]) -> CatalogStore {
        CatalogStore(catalog: Catalog(generatedAt: "2026-11-16T00:00:00Z", categories: [], subcategories: [],
                                      brands: [], products: cards))
    }

    private func size(_ view: some View, width: CGFloat) -> CGSize {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 2_000))
    }

    /// The tile in a sideways row anywhere but Home.
    @Test func aSaleABadgeAndAnotherCurrencyAddNoHeightToATile() {
        let cards = Array(cards.prefix(5)), store = store(cards), side = ProductRow.tileWidth
        func height(_ p: Product) -> CGFloat {
            size(ProductTile(product: p, imageSide: side).frame(width: side).environment(store), width: side).height
        }
        let plain = height(cards[0])
        #expect(plain > side)
        for card in cards.dropFirst() {
            #expect(abs(height(card) - plain) < 0.5, "\(card.id) is a different height")
        }
    }

    /// The card in Home's rows (owner, 2026-11-23: "Let's do product
    /// tiles"): as wide as its row gives it, a square photo and two lines,
    /// and one height for all.
    @Test func everyRowCardIsOneSize() {
        let cards = cards, store = store(cards), width = ProductCard.width(in: 402)
        func measured(_ p: Product) -> CGSize { size(ProductCard(product: p).frame(width: width).environment(store), width: 402) }
        let plain = measured(cards[0])
        #expect(plain.width == width)
        #expect(plain.height > width, "a photo and two lines under it")
        #expect(plain.height < width + 90, "a square photo, a price and one line: nothing more")
        for card in cards.dropFirst() {
            let s = measured(card)
            #expect(abs(s.height - plain.height) < 0.5, "\(card.id) is a different height")
            #expect(s.width == width, "\(card.id) is a different width")
        }
    }

    /// A card takes four fifths of its row, so the next one shows at the
    /// edge, and stops growing where an iPad's column would make it a poster.
    @Test func aCardIsFourFifthsOfItsRow() {
        #expect(ProductCard.width(in: 402) == 322)   // iPhone 17 Pro
        #expect(ProductCard.width(in: 375) == 300)   // iPhone SE
        #expect(ProductCard.width(in: 440) == 352)   // iPhone 17 Pro Max
        #expect(ProductCard.width(in: 506) == 360)   // half an iPad
        #expect(ProductCard.width(in: 1024) == 360)
    }
}
