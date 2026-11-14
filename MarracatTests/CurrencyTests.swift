import XCTest
@testable import Marracat

final class CurrencyTests: XCTestCase {
    func testCurrencyFormattingAndLegacyProducts() throws {
        XCTAssertTrue(Money.string(25, currency: "GBP").contains("£"))
        XCTAssertTrue(Money.string(25, currency: "EUR").contains("€"))
        XCTAssertTrue(Money.string(25).contains("$"))
        let catalog = CatalogStore(synchronously: true)
        let original = try XCTUnwrap(catalog.catalog.products.first)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "currency")
        let legacy = try JSONDecoder().decode(Product.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.currencyCode, "USD")
    }

    func testCartKeepsDifferentCurrenciesSeparateAndPreservesVariantIDs() throws {
        let catalog = CatalogStore(synchronously: true)
        let suite = "CurrencyTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cart = CartStore(defaults: defaults)
        for currency in ["USD", "GBP", "EUR"] {
            // A single-variant product: the catalog carries variants only for
            // those, and anything with choices is chosen on its own page.
            let product = try XCTUnwrap(catalog.catalog.products.first {
                $0.currencyCode == currency && $0.available && $0.firstAvailableVariant != nil
            })
            let variant = try XCTUnwrap(product.firstAvailableVariant)
            cart.add(productID: product.id, variantID: variant.id, quantity: 2,
                     option: nil, unitPrice: variant.price, currency: product.currencyCode)
            let brand = try XCTUnwrap(catalog.brand(product.brand))
            let url = try XCTUnwrap(CartStore.checkoutURL(brand: brand, lines: [CartLine(productID: product.id, variantID: variant.id, quantity: 2)]))
            XCTAssertEqual(url.host, brand.domain)
            XCTAssertEqual(url.path, "/cart/\(variant.id):2")
            if let currency = brand.currency {
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "currency" })?.value, currency)
            }
        }
        let totals = cart.subtotalsByCurrency(cart.lines, catalog: catalog)
        XCTAssertEqual(totals.map(\.currency), ["EUR", "GBP", "USD"])
        for total in totals {
            let product = try XCTUnwrap(catalog.catalog.products.first {
                $0.currencyCode == total.currency && $0.available && $0.firstAvailableVariant != nil
            })
            XCTAssertEqual(total.amount, product.firstAvailableVariant!.price * 2, accuracy: 0.001)
        }
    }
}
