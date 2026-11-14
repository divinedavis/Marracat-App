import Foundation
import Testing
@testable import Marracat

/// The bundled binary catalog keeps each colour's own photo (2026-10-17: the
/// ship's read-back check failed once the catalog carried variant images).
struct CatalogBinaryVariantTests {
    @Test func variantPhotoSurvivesTheBinaryCatalog() throws {
        let variants = [Variant(id: 1, title: "Deep Wine", price: 1475, compareAt: 1600, available: true, image: 1),
                        Variant(id: 2, title: "Cream", price: 1475, compareAt: nil, available: false)]
        let product = Product(id: "wc-1", brand: "walter-calvin", title: "The Legacy Satchel", category: "bags", productType: nil,
                              subs: [], price: 1475, compareAt: nil, images: ["a.jpg"], url: "https://b.example/p",
                              available: true, variants: variants, tags: [], description: nil, publishedAt: nil,
                              bestRank: nil, currency: nil)
        let catalog = Catalog(generatedAt: "2026-10-17T00:00:00Z", categories: [], subcategories: [], brands: [], products: [product])
        let back = try #require(CatalogBinary.decode(try CatalogBinary.encode(catalog)))
        #expect(back.products == catalog.products)
        #expect(back.products.first?.variants.map(\.image) == [1, nil])
    }
}
