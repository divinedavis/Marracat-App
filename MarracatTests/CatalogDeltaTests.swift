import XCTest
@testable import Marracat

/// CatalogDelta (2026-10-18): a delta from catalog/catalog_delta.py applied to
/// the catalog it was made from gives the new catalog, and anything that
/// doesn't line up falls back to the whole download.
final class CatalogDeltaTests: XCTestCase {
    /// Made by catalog/catalog_delta.py (see catalog/test_catalog_delta.py):
    /// p-3 removed, p-5 repriced, p-10 added, p-1 moved to the end, brand C renamed.
    private enum Fixture {
        static let base = #"{"generated_at":"2026-10-18T00:00:00Z","categories":[{"id":"bags","name":"Bags","symbol":"handbag"}],"subcategories":[],"brands":[{"id":"b","name":"B","domain":"b.example","category":"bags","shopify":true},{"id":"c","name":"C","domain":"c.example","category":"bags","shopify":true}],"products":[{"id":"p-1","brand":"b","title":"Item p-1","category":"bags","url":"https://b.example/p-1","price":10,"available":true},{"id":"p-2","brand":"c","title":"Item p-2","category":"bags","url":"https://b.example/p-2","price":10,"available":true},{"id":"p-3","brand":"b","title":"Item p-3","category":"bags","url":"https://b.example/p-3","price":10,"available":true},{"id":"p-4","brand":"c","title":"Item p-4","category":"bags","url":"https://b.example/p-4","price":10,"available":true},{"id":"p-5","brand":"b","title":"Item p-5","category":"bags","url":"https://b.example/p-5","price":10,"available":true},{"id":"p-6","brand":"c","title":"Item p-6","category":"bags","url":"https://b.example/p-6","price":10,"available":true},{"id":"p-7","brand":"b","title":"Item p-7","category":"bags","url":"https://b.example/p-7","price":10,"available":true},{"id":"p-8","brand":"c","title":"Item p-8","category":"bags","url":"https://b.example/p-8","price":10,"available":true}]}"#
        static let delta = #"{"generated_at":"2026-10-18T06:00:00Z","delta":1,"from":"aaaaaaaaaaaaaaaa","to":"bbbbbbbbbbbbbbbb","count":8,"ids":"c064d642ce711d76","order":[1,1,3,1,-1,1,5,1,-2,1,6,2,0,1],"categories":[{"id":"bags","name":"Bags","symbol":"handbag"}],"subcategories":[],"brands":[{"id":"b","name":"B","domain":"b.example","category":"bags","shopify":true},{"id":"c","name":"C2","domain":"c.example","category":"bags","shopify":true}],"products":[{"id":"p-5","brand":"b","title":"Item p-5","category":"bags","url":"https://b.example/p-5","price":99,"available":true,"compare_at":120},{"id":"p-10","brand":"c","title":"Item p-10","category":"bags","url":"https://b.example/p-10","price":10,"available":true,"best_rank":1}]}"#
        static let expected = #"{"generated_at":"2026-10-18T06:00:00Z","categories":[{"id":"bags","name":"Bags","symbol":"handbag"}],"subcategories":[],"brands":[{"id":"b","name":"B","domain":"b.example","category":"bags","shopify":true},{"id":"c","name":"C2","domain":"c.example","category":"bags","shopify":true}],"products":[{"id":"p-2","brand":"c","title":"Item p-2","category":"bags","url":"https://b.example/p-2","price":10,"available":true},{"id":"p-4","brand":"c","title":"Item p-4","category":"bags","url":"https://b.example/p-4","price":10,"available":true},{"id":"p-5","brand":"b","title":"Item p-5","category":"bags","url":"https://b.example/p-5","price":99,"available":true,"compare_at":120},{"id":"p-6","brand":"c","title":"Item p-6","category":"bags","url":"https://b.example/p-6","price":10,"available":true},{"id":"p-10","brand":"c","title":"Item p-10","category":"bags","url":"https://b.example/p-10","price":10,"available":true,"best_rank":1},{"id":"p-7","brand":"b","title":"Item p-7","category":"bags","url":"https://b.example/p-7","price":10,"available":true},{"id":"p-8","brand":"c","title":"Item p-8","category":"bags","url":"https://b.example/p-8","price":10,"available":true},{"id":"p-1","brand":"b","title":"Item p-1","category":"bags","url":"https://b.example/p-1","price":10,"available":true}]}"#
    }

    private func catalog(_ json: String) throws -> Catalog {
        try CatalogStore.decodeInParallel(Data(json.utf8), snakeCase: true)
    }

    private func delta(_ edit: (inout [String: Any]) -> Void = { _ in }) throws -> CatalogDelta.File {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixture.delta.utf8)) as? [String: Any])
        edit(&obj)
        return try XCTUnwrap(CatalogDelta.decode(JSONSerialization.data(withJSONObject: obj)))
    }

    func testPythonDeltaAppliesToExactlyTheNewCatalog() throws {
        let got = try XCTUnwrap(CatalogDelta.apply(try delta(), to: try catalog(Fixture.base)))
        let want = try catalog(Fixture.expected)
        XCTAssertEqual(got.products, want.products)
        XCTAssertEqual(got.brands, want.brands)
        XCTAssertEqual(got.generatedAt, want.generatedAt)
        XCTAssertEqual(got.products.first { $0.id == "p-5" }?.compareAt, 120)
    }

    func testIdsDigestMatchesPython() throws {
        XCTAssertEqual(CatalogDelta.idsDigest(try catalog(Fixture.expected).products), try delta().ids)
    }

    func testADeltaThatDoesNotLineUpIsRefused() throws {
        let base = try catalog(Fixture.base)
        XCTAssertNil(CatalogDelta.apply(try delta { $0["count"] = 9 }, to: base), "count")
        XCTAssertNil(CatalogDelta.apply(try delta { $0["ids"] = "0000000000000000" }, to: base), "id order")
        XCTAssertNil(CatalogDelta.apply(try delta { $0["order"] = [7, 5] }, to: base), "run past the base")
        XCTAssertNil(CatalogDelta.apply(try delta { $0["order"] = [-2, 2] }, to: base), "run past its products")
        XCTAssertNil(CatalogDelta.apply(try delta { $0["order"] = [0, 1, 2] }, to: base), "odd order")
        var other = base
        other.products.removeFirst()
        XCTAssertNil(CatalogDelta.apply(try delta(), to: other), "another base")
        XCTAssertNil(CatalogDelta.decode(Data(Fixture.delta.replacingOccurrences(of: #""delta":1"#, with: #""delta":2"#).utf8)),
                     "a format this build doesn't know")
    }

    /// What the cache holds after a delta: the whole bundled catalog written
    /// back reads the same, opens with its date, and still splits for the
    /// parallel decode.
    @MainActor
    func testCacheJSONReadsBackTheSameCatalog() throws {
        let c = CatalogStore(synchronously: true).catalog
        let data = try CatalogDelta.cacheJSON(c)
        XCTAssertEqual(CatalogStore.generatedAt(head: data), c.generatedAt)
        XCTAssertNotNil(data.range(of: Data(#"},{"id":""#.utf8)))
        let back = try CatalogStore.decodeInParallel(data, snakeCase: false)
        XCTAssertEqual(back.products, c.products)
        XCTAssertEqual(back.brands, c.brands)
        XCTAssertEqual(back.categories.map(\.id), c.categories.map(\.id))
        XCTAssertEqual(back.subcategories.map(\.id), c.subcategories.map(\.id))
    }

    func testFingerprintOnlyForTheCachedCatalogNewerThanTheBundle() {
        defer { CatalogDelta.forget() }
        CatalogDelta.remember("0123456789abcdef", for: "2026-10-18T06:00:00Z")
        XCTAssertEqual(CatalogDelta.fingerprint(of: "2026-10-18T06:00:00Z", cached: "2026-10-18T06:00:00Z", bundled: "2026-10-17"),
                       "0123456789abcdef")
        XCTAssertNil(CatalogDelta.fingerprint(of: "2026-10-18T07:00:00Z", cached: "2026-10-18T07:00:00Z", bundled: "2026-10-17"),
                     "another catalog")
        XCTAssertNil(CatalogDelta.fingerprint(of: "2026-10-18T06:00:00Z", cached: nil, bundled: "2026-10-17"), "cache gone")
        XCTAssertNil(CatalogDelta.fingerprint(of: "2026-10-18T06:00:00Z", cached: "2026-10-18T06:00:00Z",
                                              bundled: "2026-10-18T06:00:00Z"), "the bundle opens instead")
        CatalogDelta.forget()
        XCTAssertNil(CatalogDelta.fingerprint(of: "2026-10-18T06:00:00Z", cached: "2026-10-18T06:00:00Z", bundled: "2026-10-17"))
    }

    func testFingerprintIsSixteenHexOfTheBytes() {
        XCTAssertEqual(CatalogDelta.fingerprint(Data("x".utf8)), "2d711642b726b044")   // sha256("x")
    }
}
