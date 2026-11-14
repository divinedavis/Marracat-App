import Foundation
import Testing
@testable import Marracat

/// The continue card between brands, the cart link's shipping prefill,
/// delivery estimates (owner, 2026-10-13) and the bag's standard-shipping
/// quotes (2026-10-14).
struct DeliveryEstimateTests {
    /// New York time, so a day is a day wherever the tests run.
    static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    static func day(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!.addingTimeInterval(10 * 3600)   // 10 am: the hour doesn't matter
    }
    static func estimate(_ title: String?, _ description: String?, from: String = "2026-10-13",
                         earliest: String? = nil, latest: String? = nil) -> DeliveryEstimate? {
        DeliveryEstimate.make(title: title, description: description, earliest: earliest, latest: latest, from: day(from), calendar: cal)
    }

    @Test("Phrases a store writes, projected from Tue Oct 13 2026", arguments: [
        ("3 to 5 business days", "Est. arrives Oct 16–20"),       // Shopify's usual wording
        ("2 Business Days", "Est. arrives Oct 15"),               // single value, capitalised
        ("3–5 business days", "Est. arrives Oct 16–20"),          // en dash
        ("3-5 business days", "Est. arrives Oct 16–20"),          // hyphen
        ("1 business day", "Est. arrives Oct 14"),
        ("2 business days via 03", "Est. arrives Oct 15"),        // Hope for Flowers' reply
    ])
    func projectsBusinessDays(phrase: String, expected: String) {
        #expect(Self.estimate("Standard", phrase)?.text == expected)
    }

    @Test func aRangeAcrossMonthsNamesBothMonths() {
        #expect(Self.estimate("Standard", "2 to 4 business days", from: "2026-10-28")?.text == "Est. arrives Oct 30–Nov 3")
    }

    @Test func weekendsAndFederalHolidaysDontCount() {
        // Fri Oct 9 + 1: past the weekend and Columbus Day (Mon Oct 12).
        #expect(DeliveryEstimate.add(businessDays: 1, to: Self.day("2026-10-09"), calendar: Self.cal) == Self.cal.startOfDay(for: Self.day("2026-10-13")))
        // Wed Nov 25 + 1: Thanksgiving is Thu Nov 26.
        #expect(Self.estimate("Express", "1 business day", from: "2026-11-25")?.text == "Est. arrives Nov 27")
        // July 4 2026 is a Saturday, observed Friday July 3.
        #expect(Self.estimate("Express", "1 business day", from: "2026-07-02")?.text == "Est. arrives Jul 6")
        #expect(USHolidays.isHoliday(Self.day("2026-07-03"), calendar: Self.cal))
        #expect(!USHolidays.isHoliday(Self.day("2026-07-02"), calendar: Self.cal))
        #expect(USHolidays.isHoliday(Self.day("2026-12-25"), calendar: Self.cal))
        #expect(USHolidays.isHoliday(Self.day("2027-05-31"), calendar: Self.cal))   // last Monday of May
    }

    @Test func daysInTheTitleCountWhenTheDescriptionHasNone() {
        let e = Self.estimate("Fedex Ground Economy (7 to 10 business days)", nil)
        #expect(e?.text == "Est. arrives Oct 22–27")
        #expect(e?.excludesHandling == false)
    }

    @Test func countingFromShipmentIsFlagged() {
        let e = Self.estimate("Ground (2-8 business days from date of shipment.)", nil)
        #expect(e?.text == "Est. arrives Oct 15–23")
        #expect(e?.excludesHandling == true)
        #expect(Self.estimate("Standard", "3 to 5 business days after processing")?.excludesHandling == true)
    }

    @Test("Explicit dates and other wording are shown as the store wrote them", arguments: [
        "Monday, October 19–Wednesday, October 21",
        "Thursday, October 15",
        "Ship by: 14-Oct-2026; Delivery by: 15-Oct-2026",
        "Within 3 days anywhere in the contiguous U.S",
    ])
    func showsOtherWordingAsGiven(text: String) {
        #expect(Self.estimate("Standard", text)?.text == text)
    }

    @Test func statedFulfillmentDatesWin() {
        #expect(Self.estimate("Standard", "3 to 5 business days", earliest: "2026-10-17T16:00:00Z", latest: "2026-10-20T16:00:00Z")?.text == "Arrives Oct 17–20")
        #expect(Self.estimate("Standard", nil, earliest: "2026-10-17", latest: "2026-10-17")?.text == "Arrives Oct 17")
    }

    @Test func nothingToGoOnMeansNoEstimate() {
        #expect(Self.estimate("Standard", nil) == nil)
        #expect(Self.estimate("USPS Priority Mail (2-5 Days)", nil) == nil)   // not "business days": the title says it already
        #expect(Self.estimate(nil, "   ") == nil)
        #expect(DeliveryEstimate.days(in: "Free over $100") == nil)
    }
}

struct CheckoutRunTests {
    private func brand(_ id: String) -> Brand {
        Brand(id: id, name: id.capitalized, domain: "\(id).example", category: "bags", tagline: nil, shopify: true, platform: nil, image: nil)
    }

    @Test func threeBrandsCountTwoOfThreeThenThreeOfThree() {
        var run = CheckoutRun()
        let first = run.placed(brand: "A", orderID: "gid://shopify/OrderIdentity/8622093435066", remaining: [brand("b"), brand("c")])
        #expect(first.title == "Order placed with A · #8622093435066")
        #expect(first.next == .init(brandID: "b", brandName: "B", position: 2, total: 3))
        let second = run.placed(brand: "B", orderID: nil, remaining: [brand("c")])
        #expect(second.title == "Order placed with B")   // no order id in the event: no number, no "#"
        #expect(second.next?.position == 3 && second.next?.total == 3)
        let last = run.placed(brand: "C", orderID: "123", remaining: [])
        #expect(last.next == nil)
        #expect(run == CheckoutRun(), "the run ends with the cart")
    }

    @Test func laterStartsTheCountAgain() {
        var run = CheckoutRun()
        _ = run.placed(brand: "A", orderID: nil, remaining: [brand("b"), brand("c")])
        run.reset()
        #expect(run.placed(brand: "B", orderID: nil, remaining: [brand("c")]).next?.position == 2)
    }

    @Test func anOrderIdThatIsntANumberShowsNoNumber() {
        var run = CheckoutRun()
        #expect(run.placed(brand: "A", orderID: "", remaining: []).orderNumber == nil)
        #expect(run.placed(brand: "A", orderID: "gid://shopify/OrderIdentity/", remaining: []).title == "Order placed with A")
    }
}

struct PermalinkPrefillTests {
    private let brand = Brand(id: "px", name: "PX", domain: "parallelxstore.com", category: "bags", tagline: nil, shopify: true, platform: nil, image: nil)
    private let line = CartLine(productID: "p", variantID: 48013083771196, quantity: 1)

    @Test func everyFieldSurvivesTheURL() throws {
        RelayStore.shared.clear()
        let url = try #require(CartStore.checkoutURL(brand: brand, lines: [line], buyer: UITestSeed.buyer))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ k: String) -> String? { items.first { $0.name == "checkout[shipping_address][\(k)]" }?.value }
        #expect(value("first_name") == "Zoë")
        #expect(value("last_name") == "O'Brien")
        #expect(value("address1") == "12 Rue & Co #4")
        #expect(value("address2") == "Apt 4B")
        #expect(value("city") == "Brooklyn")
        #expect(value("province") == "NY")
        #expect(value("zip") == "11201")
        #expect(value("country") == "US")
        #expect(value("phone") == "+1 718 555 0100")
        #expect(items.first { $0.name == "checkout[email]" }?.value == "zoe+test@example.com")
        // On the wire: "+" is %2B (a bare one reads as a space), "&" and "#"
        // can't end the field or the URL.
        let query = try #require(url.query(percentEncoded: true))
        #expect(!query.contains("+"))
        #expect(query.contains("%2B1%20718%20555%200100"))
        #expect(query.contains("12%20Rue%20%26%20Co%20%234"))
        #expect(url.fragment == nil)
        #expect(BrandCheckout.prefillSummary(url) == "Ships to Zoë O'Brien, 12 Rue & Co #4, Apt 4B, Brooklyn NY 11201, +1 718 555 0100")
    }

    @Test func blankFieldsAreLeftOutAndNoBuyerMeansNoAddress() throws {
        RelayStore.shared.clear()
        var b = UITestSeed.buyer; b.extended = "  "
        let url = try #require(CartStore.checkoutURL(brand: brand, lines: [line], buyer: b))
        #expect(!url.absoluteString.contains("address2"))
        let bare = try #require(CartStore.checkoutURL(brand: brand, lines: [line]))
        #expect(!bare.absoluteString.contains("shipping_address"))
        #expect(BrandCheckout.prefillSummary(bare) == nil)
    }
}

struct UCPShippingChoiceTests {
    /// Samir Grey's store, 2026-10-13 (trimmed): three speeds, Standard chosen.
    static let reply = """
    {"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"id":"gid://shopify/Checkout/abc?key=k","status":"incomplete","currency":"USD",
     "continue_url":"https://msf0vt-pk.myshopify.com/cart/c/abc?key=1",
     "totals":[{"type":"subtotal","amount":13800},{"type":"fulfillment","amount":0},{"type":"total","amount":15025}],
     "buyer":{"email":"t@example.com"},
     "line_items":[{"id":"gid://shopify/CartLine/l1?cart=abc","item":{"id":"gid://shopify/ProductVariant/55734882271601","price":13800},"quantity":1}],
     "fulfillment":{"methods":[{"id":"c2hpcHBpbmc=","type":"shipping","line_item_ids":["gid://shopify/CartLine/l1?cart=abc"],"selected_destination_id":"d1",
       "destinations":[{"first_name":"Test","street_address":"350 5th Ave","address_locality":"New York","address_region":"NY","postal_code":"10118","address_country":"US","id":"d1"}],
       "groups":[{"id":"gid://shopify/CartDeliveryGroup/g1?cart=abc","line_item_ids":["gid://shopify/CartLine/l1?cart=abc"],"selected_option_id":"879f",
         "options":[{"id":"879f","title":"Standard Shipping","description":{"plain":"5 to 8 business days"},"totals":[{"type":"total","amount":0}]},
                    {"id":"5310","title":"Priority Shipping","description":{"plain":"3 to 5 business days"},"totals":[{"type":"total","amount":1500}]},
                    {"id":"550a","title":"Expedited Shipping","description":{"plain":"1 to 2 business days"},"totals":[{"type":"total","amount":3000}]}]}]}]}}}}
    """
    static let buyer = BuyerDetails(firstName: "Test", lastName: "Buyer", email: "t@example.com", phone: "7185550100",
                                    street: "350 5th Ave", extended: "", city: "New York", region: "NY", postalCode: "10118")

    @Test func readsEveryOptionWithItsDescriptionAndPrice() throws {
        let c = try UCPClient.parse(Data(Self.reply.utf8))
        let choice = try #require(c.shippingChoices.first)
        #expect(choice.options.map(\.title) == ["Standard Shipping", "Priority Shipping", "Expedited Shipping"])
        #expect(choice.options.map(\.price) == [0, 1500, 3000])
        #expect(choice.options[1].description?.plain == "3 to 5 business days")
        #expect(choice.selected?.id == "879f")
        #expect(c.shippingOption == "Standard Shipping")
    }

    // MARK: The bag's standard shipping (owner, 2026-10-14)

    @Test func theStandardQuoteIsTheCheapestOption() throws {
        let c = try UCPClient.parse(Data(Self.reply.utf8))
        let q = try #require(ShippingQuote.standard(from: c, currency: "USD"))
        #expect(q.amountMinor == 0 && q.isFree)
        #expect(q.title == "Standard Shipping")
        #expect(q.estimate?.hasPrefix("Est. arrives ") == true)
        // The cheapest wins even when the store selected a dearer one.
        let dearerSelected = Self.reply.replacingOccurrences(of: #""amount":0}]},"#, with: #""amount":900}]},"#)
            .replacingOccurrences(of: #""amount":1500}]"#, with: #""amount":700}]"#)
        let q2 = try #require(ShippingQuote.standard(from: try UCPClient.parse(Data(dearerSelected.utf8)), currency: "USD"))
        #expect(q2.amountMinor == 700 && q2.title == "Priority Shipping")
    }

    /// A ZIP with no rate (or a country alone): no options, so no quote.
    @Test func noPricedOptionMeansNoQuote() throws {
        let none = #"{"jsonrpc":"2.0","id":1,"result":{"structuredContent":{"id":"gid://shopify/Checkout/x","status":"incomplete","currency":"USD","totals":[{"type":"subtotal","amount":3000}]}}}"#
        #expect(ShippingQuote.standard(from: try UCPClient.parse(Data(none.utf8)), currency: "USD") == nil)
    }

    /// A quote sends the items, the ZIP and the country — no name, street,
    /// email or phone.
    @Test func aQuoteSendsOnlyItemsAndZIP() throws {
        let body = UCPClient.quoteBody(currency: "USD", lines: [UCPLineRequest(variantID: 44781838827813, quantity: 2, unitPriceMinor: 3000)],
                                       postalCode: "11201", country: "US")
        let checkout = try #require(body["checkout"] as? [String: Any])
        #expect(Set(checkout.keys) == ["currency", "line_items", "fulfillment"])
        let method = try #require(((checkout["fulfillment"] as? [String: Any])?["methods"] as? [[String: Any]])?.first)
        let destination = try #require((method["destinations"] as? [[String: Any]])?.first)
        #expect(destination as NSDictionary == ["postal_code": "11201", "address_country": "US"] as NSDictionary)
        let line = try #require((checkout["line_items"] as? [[String: Any]])?.first)
        #expect(line["quantity"] as? Int == 2)
        #expect((line["item"] as? [String: Any])?["id"] as? String == "gid://shopify/ProductVariant/44781838827813")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func theStubQuotesStandardFiveDollars() async throws {
        let endpoint = URL(string: "https://x.myshopify.com/api/ucp/mcp")!
        let c = UCPClient.stubCheckout(endpoint: endpoint, currency: "USD", lines: [UCPLineRequest(variantID: 7, quantity: 2, unitPriceMinor: 1000)])
        let q = try #require(ShippingQuote.standard(from: c, currency: "USD"))
        #expect(q.amountMinor == 500 && q.title == "Standard")
    }

    @Test("US ZIPs", arguments: [("11201", true), ("11201-1234", true), ("1120", false), ("ABCDE", false), ("", false), ("112011", false)])
    func zipCodes(_ zip: String, _ ok: Bool) {
        #expect(ShippingQuoteStore.isZIP(zip) == ok)
    }

    /// The cache key ignores line order and changes with quantity and ZIP.
    @Test func quoteKeyFollowsItemsAndZIP() {
        let a = CartLine(productID: "p", variantID: 1, quantity: 1), b = CartLine(productID: "q", variantID: 2, quantity: 1)
        let key = ShippingQuoteStore.key(brand: "x", lines: [a, b], zip: "11201")
        #expect(key == ShippingQuoteStore.key(brand: "x", lines: [b, a], zip: "11201"))
        #expect(key != ShippingQuoteStore.key(brand: "x", lines: [a, b], zip: "94110"))
        var more = a; more.quantity = 2
        #expect(key != ShippingQuoteStore.key(brand: "x", lines: [more, b], zip: "11201"))
    }
}

/// Shipping estimated outside UCP (owner, 2026-10-16): a Shopify
/// storefront's /cart/shipping_rates.json, and which stores can quote at all.
struct StoreRatesTests {
    @Test func theCheapestStorefrontRateWins() throws {
        let json = #"{"shipping_rates":[{"name":"Express","price":"24.00","currency":"USD"},{"name":"Free Standard Delivery","price":"0.00","currency":"USD"}]}"#
        let q = try #require(StoreRates.shopifyRates(Data(json.utf8)))
        #expect(q.amountMinor == 0 && q.isFree)
        #expect(q.title == "Free Standard Delivery")
    }

    @Test func centsAndCurrencyAreKept() throws {
        let json = #"{"shipping_rates":[{"name":"Standard","price":"8.95","currency":"GBP"}]}"#
        let q = try #require(StoreRates.shopifyRates(Data(json.utf8)))
        #expect(q.amountMinor == 895 && q.currency == "GBP")
    }

    @Test func aRefusalOrNoRatesIsNoQuote() {
        #expect(StoreRates.shopifyRates(Data(#"{"province":["Select a state"]}"#.utf8)) == nil)
        #expect(StoreRates.shopifyRates(Data(#"{"shipping_rates":[]}"#.utf8)) == nil)
        #expect(StoreRates.shopifyRates(Data("not json".utf8)) == nil)
    }
}
