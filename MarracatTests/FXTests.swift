import XCTest
@testable import Marracat

/// Dollar estimates for brands that charge in another currency (FX, catalog/fx.py;
/// owner, 2026-10-08: the Nigerian, Kenyan, South African, Ghanaian and Swedish brands).
final class FXTests: XCTestCase {
    override func tearDown() { FX.usdPerUnit = FX.fallback }

    func testBrandRatesFromTheCatalogReplaceTheFallback() throws {
        let json = #"{"id":"nuban","name":"Nuban Beauty","domain":"nubanbeauty.com","category":"makeup","tagline":null,"shopify":true,"platform":"shopify","image":null,"currency":"NGN","usd_rate":0.0008}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        let brand = try d.decode(Brand.self, from: Data(json.utf8))
        XCTAssertEqual(brand.usdRate, 0.0008)
        FX.update(from: [brand])
        XCTAssertEqual(FX.usd(32_000, "NGN") ?? 0, 25.6, accuracy: 0.001)
        XCTAssertEqual(FX.usd(10, "GBP"), 10 * FX.fallback["GBP"]!, "currencies no brand rated keep the fallback")
    }

    func testDollarsAreExactAndUnknownCurrenciesAreNotGuessed() {
        XCTAssertEqual(FX.usd(12.5, "USD"), 12.5)
        XCTAssertNil(FX.usd(100, "XYZ"))
    }

    func testANairaPriceFallsInItsDollarBandNotAsThousandsOfDollars() throws {
        let json = #"{"id":"p","brand":"nuban","title":"Lip Gloss","category":"makeup","price":32000,"currency":"NGN","url":"https://nubanbeauty.com/products/x","available":true,"images":[],"variants":[],"tags":[]}"#
        let p = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertLessThan(p.usdPrice, 50)
        XCTAssertEqual(PriceBand.band(for: p.usdPrice).name, PriceBand.band(for: 24).name)
    }

    /// A price in another currency leads with dollars, its own amount beneath
    /// (owner, 2026-11-08: "the app should lead with dollars"); a dollar price
    /// and a currency with no rate stay as they are.
    func testNonDollarPricesLeadWithDollars() {
        XCTAssertEqual(PriceView.approxUSD(14_000, currency: "NGN") ?? 0, 14_000 * FX.fallback["NGN"]!, accuracy: 0.001)
        XCTAssertNotNil(PriceView.approxUSD(18, currency: "GBP"))
        XCTAssertNil(PriceView.approxUSD(38, currency: "USD"))
        XCTAssertNil(PriceView.approxUSD(10, currency: "XYZ"))
        // The struck-through list price follows: dollars when the rate is known.
        XCTAssertEqual(Money.leading(100, currency: "GBP"), Money.string(100 * FX.usdPerUnit["GBP"]!))
        XCTAssertEqual(Money.leading(40, currency: "USD"), Money.string(40))
        XCTAssertEqual(Money.leading(10, currency: "XYZ"), Money.string(10, currency: "XYZ"))
    }

    func testEachCurrencyShowsItsOwnSign() {
        XCTAssertEqual(FX.symbol("USD"), "$")
        XCTAssertEqual(FX.symbol("NGN"), "₦")
        XCTAssertEqual(FX.symbol("GHS"), "GH₵")
        XCTAssertEqual(FX.symbol("ZAR"), "R")
        XCTAssertEqual(Money.spoken(2, currency: "KES"), "2 shillings")
        XCTAssertEqual(FX.symbol("XOF"), "CFA ")
        XCTAssertEqual(Money.spoken(1, currency: "BWP"), "1 pula")
    }

    /// The held brands' currencies (2026-10-15) have a dollar rate before
    /// the catalog stamps one, so they never drop out of price filters.
    func testHeldBrandCurrenciesHaveAFallbackRate() {
        for c in ["CAD", "XOF", "RWF", "BWP"] { XCTAssertNotNil(FX.usd(100, c), c) }
        XCTAssertEqual(FX.usd(10_000, "XOF") ?? 0, 17.04, accuracy: 0.01)
    }

    /// The Canada and Caribbean scan's currencies (owner, 2026-10-22).
    func testCaribbeanCurrencies() {
        XCTAssertEqual(FX.usd(100, "BBD") ?? 0, 50, accuracy: 0.001, "pegged at 2 to the dollar")
        XCTAssertEqual(FX.usd(100, "BSD") ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(FX.usd(5_000, "JMD") ?? 0, 31.5, accuracy: 0.1)
        XCTAssertEqual(FX.symbol("JMD"), "J$")
        XCTAssertEqual(FX.symbol("XCD"), "EC$")
        XCTAssertEqual(Money.spoken(3, currency: "BBD"), "3 Barbados dollars")
    }

    /// Sahara Accessories, Switzerland (owner, 2026-11-11).
    func testSwissFranc() {
        XCTAssertEqual(FX.usd(100, "CHF") ?? 0, 120.5, accuracy: 0.1)
        XCTAssertEqual(FX.symbol("CHF"), "CHF ")
        XCTAssertEqual(Money.spoken(3, currency: "CHF"), "3 Swiss francs")
    }

    /// A Dubai-based brand from the 2026-10-23 import.
    func testDirham() {
        XCTAssertEqual(FX.usd(367.25, "AED") ?? 0, 100, accuracy: 0.01, "pegged at 3.6725")
        XCTAssertEqual(Money.spoken(3, currency: "AED"), "3 dirhams")
    }

    /// "Ships from Africa" from the catalog's ships_from (owner, 2026-10-14);
    /// a US brand, or an unknown region, shows nothing.
    func testShipsFromLabel() throws {
        func brand(_ origin: String?) throws -> Brand {
            let field = origin.map { #","ships_from":"\#($0)""# } ?? ""
            let json = #"{"id":"b","name":"B","domain":"b.com","category":"clothing","tagline":null,"shopify":true,"platform":"shopify","image":null\#(field)}"#
            let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
            return try d.decode(Brand.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try brand("africa").shipsFromLabel, "Ships from Africa")
        XCTAssertEqual(try brand("europe").shipsFromLabel, "Ships from Europe")
        XCTAssertEqual(try brand("canada").shipsFromLabel, "Ships from Canada")
        XCTAssertNil(try brand(nil).shipsFromLabel)
        XCTAssertNil(try brand("mars").shipsFromLabel)
    }
}
