import XCTest
@testable import Marracat

/// The Swift tokenizer must turn text into exactly the token ids Python's
/// open_clip does, or a query lands somewhere else in the meaning space than
/// the products it should find. Fixtures from open_clip's MobileCLIP2-S0
/// tokenizer (catalog/embed_products.py uses the same).
final class CLIPTokenizerTests: XCTestCase {
    func testMatchesOpenCLIPOnEveryFixture() throws {
        let tokenizer = try XCTUnwrap(CLIPTokenizer(mergesURL: Bundle(for: CatalogStore.self).url(forResource: "clip-merges", withExtension: "txt")))
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "clip-tokens", withExtension: "json"))
        struct Fixture: Decodable { let text: String; let tokens: [Int32] }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 30)
        for f in fixtures {
            XCTAssertEqual(tokenizer.tokens(f.text), f.tokens, "“\(f.text)”")
        }
    }
}
