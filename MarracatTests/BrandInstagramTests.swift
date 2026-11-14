import Foundation
import Testing
@testable import Marracat

/// The handle comes from the brand's own site (catalog/instagram_handles.py);
/// anything that isn't a plain account name never becomes a link.
struct BrandInstagramTests {
    private func brand(_ instagram: String?) throws -> Brand {
        var json: [String: Any] = ["id": "b", "name": "B", "domain": "b.example", "category": "bags", "shopify": true]
        json["instagram"] = instagram
        return try JSONDecoder().decode(Brand.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func aHandleBecomesTheAccountsPage() throws {
        #expect(try brand("telfarglobal").instagramURL?.absoluteString == "https://www.instagram.com/telfarglobal/")
        #expect(try brand("ripl.efek").instagramURL?.absoluteString == "https://www.instagram.com/ripl.efek/")
    }

    @Test func noHandleOrABadOneMeansNoButton() throws {
        #expect(try brand(nil).instagramURL == nil)
        for bad in ["", "a", "evil.com/../x", "two words", "x?y=1", String(repeating: "a", count: 31)] {
            #expect(try brand(bad).instagramURL == nil, "\(bad)")
        }
    }
}
