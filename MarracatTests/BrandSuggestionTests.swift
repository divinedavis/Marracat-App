import XCTest
@testable import Marracat

/// Brand suggestions match every typed word in the name, not only the exact
/// typed text, so "skincare koba" still finds KOBA skincare.
final class BrandSuggestionTests: XCTestCase {
    @MainActor func testBrandWordsMatchInAnyOrder() {
        let store = CatalogStore(bundle: Bundle(for: CatalogStore.self), synchronously: true)
        func brands(_ q: String) -> [String] {
            store.suggestions(q).filter { if case .brand = $0.kind { return true }; return false }.map(\.text)
        }
        XCTAssertTrue(brands("koba").contains("KOBA skincare"), "exact prefix still matches")
        XCTAssertTrue(brands("skincare koba").contains("KOBA skincare"), "words in any order")
        XCTAssertTrue(brands("koba skin").contains("KOBA skincare"), "a half-typed last word")
        XCTAssertFalse(brands("koba zzqx").contains("KOBA skincare"), "every word has to match")
        XCTAssertLessThanOrEqual(brands("the co").count, 2, "brand rows stay capped")
    }
}
