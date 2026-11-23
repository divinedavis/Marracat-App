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

    /// The card in Home's rows (owner, 2026-11-22: "this size and style
    /// cards"): 195 pt wide, its photo set in, and one height for all.
    @Test func everyRowCardIsOneSize() {
        let cards = cards, store = store(cards)
        func measured(_ p: Product) -> CGSize { size(ProductCard(product: p).environment(store), width: 400) }
        let plain = measured(cards[0])
        #expect(plain.width == ProductCard.width)
        #expect(plain.height > ProductCard.width, "a photo and two lines under it")
        for card in cards.dropFirst() {
            let s = measured(card)
            #expect(abs(s.height - plain.height) < 0.5, "\(card.id) is a different height")
            #expect(s.width == ProductCard.width, "\(card.id) is a different width")
        }
    }

    /// Home's rows are two cards high, filled a column at a time so the first
    /// products are the ones on screen; a short row stays on one line.
    @Test func rowsStackTwoHighOnceTheyAreLongEnough() {
        #expect(ProductRow.columns(12, lines: 2) == [0..<2, 2..<4, 4..<6, 6..<8, 8..<10, 10..<12])
        #expect(ProductRow.columns(5, lines: 2) == [0..<2, 2..<4, 4..<5])
        #expect(ProductRow.columns(4, lines: 2) == [0..<2, 2..<4])
        #expect(ProductRow.columns(3, lines: 2) == [0..<1, 1..<2, 2..<3])
        #expect(ProductRow.columns(6, lines: 1) == [0..<1, 1..<2, 2..<3, 3..<4, 4..<5, 5..<6])
        #expect(ProductRow.columns(8) == ProductRow.columns(8, lines: 2), "two high unless asked otherwise")
        #expect(ProductRow.columns(0, lines: 2).isEmpty)
    }
}
