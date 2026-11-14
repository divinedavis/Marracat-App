import XCTest
@testable import Marracat

@MainActor
final class DuplicateListingTests: XCTestCase {
    /// No subcategory grid shows one brand's product twice: same title and same
    /// photo file means the store listed it more than once, and
    /// catalog/dedupe_products.py should have folded it into one tile.
    func testNoSubcategoryShowsTheSameListingTwice() throws {
        let catalog = CatalogStore(synchronously: true)
        var seen: [String: String] = [:]
        var repeats: [String] = []
        for p in catalog.catalog.products {
            let title = p.title.lowercased().filter { $0.isLetter || $0.isNumber }
            let photo = (p.images.first ?? "").components(separatedBy: "?")[0]
            guard !title.isEmpty, !photo.isEmpty else { continue }
            for sub in p.subs {
                let key = "\(sub)|\(p.brand)|\(title)|\(photo)"
                if let other = seen[key], other != p.id { repeats.append("\(sub): \(p.title) (\(other), \(p.id))") }
                seen[key] = p.id
            }
        }
        XCTAssertTrue(repeats.isEmpty, "\(repeats.count) repeats, e.g. \(repeats.prefix(5))")
    }

    /// Glo Melanin listed its face wash three times; it shows once, with its sizes.
    func testGloMelaninFaceWashShowsOnce() {
        let catalog = CatalogStore(synchronously: true)
        let washes = catalog.products(for: "glo-melanin").filter { $0.title == "Turmeric and Kojic Foaming Face Wash" }
        XCTAssertEqual(washes.count, 1)
    }

    /// A paperback and hardcover listed separately become one book with both formats.
    func testFormatsMergeIntoOneProduct() throws {
        let catalog = CatalogStore(synchronously: true)
        let books = catalog.products(for: "jacaranda-books").filter { $0.title == "Queen Charlotte Sophia" }
        XCTAssertEqual(books.count, 1)
        // The catalog ships option words rather than variants for a product
        // with choices; the formats still have to be there.
        XCTAssertEqual(Set(try XCTUnwrap(books.first).opts ?? []), ["paperback", "hardcover"])
    }
}
