import XCTest
@testable import Marracat

/// The launch decodes the catalog's products in parallel pieces (2026-10-02,
/// part of a 44% shorter splash). It must come out exactly as one decoder
/// would read it, and fall back whole when the file isn't shaped for it.
final class CatalogDecodeTests: XCTestCase {
    private func bundled() throws -> Data {
        try Data(contentsOf: CatalogSourceFile.compactJSON)
    }

    func testParallelDecodeMatchesOneDecoderOnTheBundledCatalog() throws {
        let data = try bundled()
        let snake = !data.starts(with: Data(#"{"generatedAt""#.utf8))
        let one = JSONDecoder()
        if snake { one.keyDecodingStrategy = .convertFromSnakeCase }
        let whole = try one.decode(Catalog.self, from: data)
        let parallel = try CatalogStore.decodeInParallel(data, snakeCase: snake)
        XCTAssertEqual(parallel.generatedAt, whole.generatedAt)
        XCTAssertEqual(parallel.brands.map(\.id), whole.brands.map(\.id))
        XCTAssertEqual(parallel.categories.map(\.id), whole.categories.map(\.id))
        XCTAssertEqual(parallel.subcategories.map(\.id), whole.subcategories.map(\.id))
        XCTAssertEqual(parallel.products.count, whole.products.count)
        XCTAssertEqual(parallel.products.map(\.id), whole.products.map(\.id), "same products in the same order")
        for (a, b) in zip(parallel.products, whole.products) where a.id.hashValue % 97 == 0 {
            XCTAssertEqual(a.title, b.title); XCTAssertEqual(a.price, b.price)
            XCTAssertEqual(a.variants.map(\.id), b.variants.map(\.id)); XCTAssertEqual(a.available, b.available)
        }
    }

    func testAFileNotShapedForPiecesStillDecodesWhole() throws {
        // Products not last, small: the whole-file path.
        let json = #"{"generatedAt":"2026-10-02","products":[],"categories":[],"subcategories":[],"brands":[]}"#
        let c = try CatalogStore.decodeInParallel(Data(json.utf8), snakeCase: false)
        XCTAssertEqual(c.generatedAt, "2026-10-02"); XCTAssertTrue(c.products.isEmpty)
    }

    func testFastWordMatchingKeepsItsRules() {
        XCTAssertTrue(CatalogStore.matchesWord("vitamin d3 gummies", "vitamin"))
        XCTAssertTrue(CatalogStore.matchesTerm("vitamin d3 gummies", "d"), "a short term can carry digits")
        XCTAssertFalse(CatalogStore.matchesWord("dark chocolate", "d"))
        XCTAssertTrue(CatalogStore.startsWord("buttercream frosting", "butter"))
        XCTAssertFalse(CatalogStore.startsWord("peanutbutter", "butter"))
        XCTAssertTrue(CatalogStore.matchesWord("café crème", "café"), "non-ASCII still matches")
        XCTAssertFalse(CatalogStore.containsBytes("abc", ""))
    }

    // The binary copy the app writes for its next launch (CatalogBinary).
    func testBinaryCatalogRoundTripsTheBundledCatalogExactly() throws {
        let data = try bundled()
        let json = try CatalogStore.decodeInParallel(data, snakeCase: !data.starts(with: Data(#"{"generatedAt""#.utf8)))
        let start = Date()
        let binary = try CatalogBinary.encode(json)
        let encoded = Date().timeIntervalSince(start)
        let readStart = Date()
        let back = try XCTUnwrap(CatalogBinary.decode(binary))
        print("binary: \(binary.count / 1_000_000) MB, encode \(Int(encoded * 1000)) ms, read \(Int(Date().timeIntervalSince(readStart) * 1000)) ms")
        XCTAssertEqual(back.generatedAt, json.generatedAt)
        XCTAssertEqual(back.brands, json.brands)
        XCTAssertEqual(back.categories, json.categories)
        XCTAssertEqual(back.subcategories, json.subcategories)
        XCTAssertEqual(back.products.count, json.products.count)
        XCTAssertTrue(back.products == json.products, "every field of every product survives")
        XCTAssertEqual(CatalogBinary.peekGeneratedAt(binary), json.generatedAt)
    }

    func testADamagedBinaryIsIgnored() throws {
        let small = Catalog(generatedAt: "2026-10-02", categories: [], subcategories: [], brands: [], products: [
            Product(id: "p", brand: "b", title: "Tee", category: "clothing", productType: nil, subs: [], price: 10,
                    compareAt: 12, images: ["a.jpg"], url: "https://b.example/p", available: true,
                    variants: [Variant(id: 1, title: "Default Title", price: 10, compareAt: nil, available: true)],
                    tags: ["x"], description: nil, publishedAt: "2026-01-01", bestRank: 2, currency: "USD"),
        ])
        let good = try CatalogBinary.encode(small)
        XCTAssertEqual(CatalogBinary.decode(good)?.products, small.products)
        XCTAssertNil(CatalogBinary.decode(good.prefix(good.count - 3)), "truncated")
        var bad = good; bad[0] ^= 0xFF
        XCTAssertNil(CatalogBinary.decode(bad), "wrong magic")
        XCTAssertNil(CatalogBinary.decode(Data("{}".utf8)))
    }

    /// The background refresh reads only each product's stock from the binary
    /// (Interests' "new since"), not the whole previous catalog.
    func testStockReadsStraightFromTheBinary() throws {
        func item(_ id: String, _ available: Bool, subs: [String] = [], compareAt: Double? = nil) -> Product {
            Product(id: id, brand: "b", title: id, category: "c", productType: available ? "t" : nil, subs: subs,
                    price: 5, compareAt: compareAt, images: [], url: "u", available: available, variants: [],
                    tags: [], description: nil, publishedAt: nil, bestRank: nil)
        }
        let small = Catalog(generatedAt: "2026-10-11", categories: [], subcategories: [], brands: [], products: [
            item("in", true, subs: ["a", "b"], compareAt: 9), item("out", false), item("in", false), item("again", true, subs: ["x"]),
        ])
        let binary = try CatalogBinary.encode(small)
        XCTAssertEqual(CatalogBinary.availability(binary), ["in": true, "out": false, "again": true],
                       "the first of a repeated id wins, as InterestsStore.availability does")
        XCTAssertEqual(CatalogBinary.availability(binary), InterestsStore.availability(small))
        XCTAssertNil(CatalogBinary.availability(binary.prefix(binary.count - 30)), "truncated")
        XCTAssertNil(CatalogBinary.availability(Data("{}".utf8)))
    }

    // The Marracat True Metal badge (catalog/metal_badge.py): decoded from the
    // JSON, kept through the binary copy, and filterable.
    func testTrueMetalDecodesRoundTripsAndFilters() throws {
        func ring(_ id: String, metal: String?) -> Product {
            Product(id: id, brand: "b", title: "Ring \(id)", category: "jewelry", productType: nil, subs: ["rings"],
                    price: 120, compareAt: nil, images: [], url: "https://b.example/\(id)", available: true,
                    variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil, clean: true, metal: metal)
        }
        let json = #"{"id":"r","brand":"b","title":"14k ring","category":"jewelry","url":"u","price":1,"available":true,"metal":"ethical"}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isMarracatTrueMetal); XCTAssertTrue(decoded.isEthicallySourced)

        let products = [ring("a", metal: "true"), ring("b", metal: "ethical"), ring("c", metal: nil)]
        let small = Catalog(generatedAt: "2026-10-08", categories: [], subcategories: [], brands: [], products: products)
        let back = try XCTUnwrap(CatalogBinary.decode(try CatalogBinary.encode(small)))
        XCTAssertEqual(back.products.map(\.metal), ["true", "ethical", nil])
        XCTAssertEqual(back.products.map(\.clean), [true, true, true], "the clean bits are untouched")

        XCTAssertEqual(products.filter(ProductFilters.Offer.trueMetal.matches).map(\.id), ["a", "b"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.ethicallySourced.matches).map(\.id), ["b"])
    }

    // Marracat Clear Scent and Safer Clean (catalog/scent_badge.py,
    // catalog/safer_clean_badge.py): decoded, kept in the binary copy beside
    // True Metal and Clean, and filterable.
    func testClearScentAndSaferCleanDecodeRoundTripAndFilter() throws {
        func item(_ id: String, _ category: String, scent: Bool? = nil, safer: Bool? = nil, metal: String? = nil) -> Product {
            Product(id: id, brand: "b", title: "Item \(id)", category: category, productType: nil, subs: [],
                    price: 20, compareAt: nil, images: [], url: "https://b.example/\(id)", available: true,
                    variants: [], tags: [], description: nil, publishedAt: nil, bestRank: nil, clean: false,
                    metal: metal, scent: scent, safer: safer)
        }
        let json = #"{"id":"p","brand":"b","title":"Oud","category":"fragrance","url":"u","price":1,"available":true,"scent":true}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isMarracatClearScent); XCTAssertFalse(decoded.isMarracatSaferClean)

        let products = [item("a", "fragrance", scent: true), item("b", "household", safer: true),
                        item("c", "jewelry", metal: "ethical"), item("d", "household")]
        let small = Catalog(generatedAt: "2026-10-09", categories: [], subcategories: [], brands: [], products: products)
        let back = try XCTUnwrap(CatalogBinary.decode(try CatalogBinary.encode(small)))
        XCTAssertEqual(back.products.map(\.scent), [true, nil, nil, nil])
        XCTAssertEqual(back.products.map(\.safer), [nil, true, nil, nil])
        XCTAssertEqual(back.products.map(\.metal), [nil, nil, "ethical", nil], "the True Metal bits are untouched")
        XCTAssertEqual(back.products.map(\.clean), [false, false, false, false], "and so are Clean's")

        XCTAssertEqual(products.filter(ProductFilters.Offer.clearScent.matches).map(\.id), ["a"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.saferClean.matches).map(\.id), ["b"])
    }

    // Marracat Clean Food and Baby Safe (catalog/food_badge.py,
    // catalog/baby_badge.py): decoded, carried in the binary copy's third flag
    // byte without shifting the fields after it, filterable, and badged.
    func testCleanFoodAndBabySafeDecodeRoundTripAndFilter() throws {
        func item(_ id: String, _ category: String, food: Bool? = nil, baby: Bool? = nil, scent: Bool? = nil,
                  safer: Bool? = nil) -> Product {
            Product(id: id, brand: "b", title: "Item \(id)", category: category, productType: nil, subs: [],
                    price: 20, compareAt: nil, images: [], url: "https://b.example/\(id)", available: true,
                    variants: [], tags: ["t\(id)"], description: "About \(id)", publishedAt: "2026-10-09",
                    bestRank: 3, clean: true, scent: scent, safer: safer, food: food, baby: baby)
        }
        let json = #"{"id":"p","brand":"b","title":"Rooibos","category":"grocery","url":"u","price":1,"available":true,"food":true}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isMarracatCleanFood); XCTAssertFalse(decoded.isMarracatBabySafe)

        let products = [item("a", "grocery", food: true), item("b", "baby", baby: true),
                        item("c", "household", safer: true), item("d", "baby", food: true, baby: true, scent: true)]
        let small = Catalog(generatedAt: "2026-10-09", categories: [], subcategories: [], brands: [], products: products)
        let back = try XCTUnwrap(CatalogBinary.decode(try CatalogBinary.encode(small)))
        XCTAssertEqual(back.products.map(\.food), [true, nil, nil, true])
        XCTAssertEqual(back.products.map(\.baby), [nil, true, nil, true])
        XCTAssertEqual(back.products.map(\.safer), [nil, nil, true, nil], "the Safer Clean bit is untouched")
        XCTAssertEqual(back.products.map(\.scent), [nil, nil, nil, true])
        XCTAssertEqual(back.products.map(\.description), ["About a", "About b", "About c", "About d"],
                       "the extra byte doesn't shift what follows")
        XCTAssertEqual(back.products.map(\.bestRank), [3, 3, 3, 3])
        XCTAssertEqual(back.products.map(\.tags), [["ta"], ["tb"], ["tc"], ["td"]])

        XCTAssertEqual(products.filter(ProductFilters.Offer.cleanFood.matches).map(\.id), ["a", "d"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.babySafe.matches).map(\.id), ["b", "d"])
        XCTAssertEqual(QualityLabelBadge.Label.all(for: products[3]), [.clearScent, .cleanFood, .babySafe])
        XCTAssertEqual(QualityLabelBadge.Label.cleanFood.title, "Marracat Clean Food")
        XCTAssertEqual(QualityLabelBadge.Label.babySafe.title, "Marracat Baby Safe")
    }

    // Marracat Natural Fiber and Safe Fabric (catalog/fiber_badge.py,
    // catalog/fabric_badge.py): decoded, carried in the third flag byte beside
    // Clean Food and Baby Safe without shifting later fields, filterable, badged.
    func testNaturalFiberAndSafeFabricDecodeRoundTripAndFilter() throws {
        func item(_ id: String, fiber: String? = nil, fabric: Bool? = nil, food: Bool? = nil) -> Product {
            Product(id: id, brand: "b", title: "Tee \(id)", category: "clothing", productType: nil, subs: [],
                    price: 30, compareAt: nil, images: [], url: "https://b.example/\(id)", available: true,
                    variants: [], tags: ["t\(id)"], description: "About \(id)", publishedAt: "2026-10-09",
                    bestRank: 2, food: food, fiber: fiber, fabric: fabric)
        }
        let json = #"{"id":"p","brand":"b","title":"Linen Shirt","category":"clothing","url":"u","price":1,"available":true,"fiber":"organic","fabric":true}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isMarracatNaturalFiber && decoded.isOrganicNaturalFiber && decoded.isMarracatSafeFabric)

        let products = [item("a", fiber: "natural"), item("b", fiber: "organic", fabric: true), item("c", fabric: true),
                        item("d", food: true)]
        let small = Catalog(generatedAt: "2026-10-09", categories: [], subcategories: [], brands: [], products: products)
        let back = try XCTUnwrap(CatalogBinary.decode(try CatalogBinary.encode(small)))
        XCTAssertEqual(back.products.map(\.fiber), ["natural", "organic", nil, nil])
        XCTAssertEqual(back.products.map(\.fabric), [nil, true, true, nil])
        XCTAssertEqual(back.products.map(\.food), [nil, nil, nil, true], "the Clean Food bit is untouched")
        XCTAssertEqual(back.products.map(\.description), ["About a", "About b", "About c", "About d"])
        XCTAssertEqual(back.products.map(\.bestRank), [2, 2, 2, 2])

        XCTAssertEqual(products.filter(ProductFilters.Offer.naturalFiber.matches).map(\.id), ["a", "b"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.safeFabric.matches).map(\.id), ["b", "c"])
        XCTAssertEqual(QualityLabelBadge.Label.all(for: products[1]), [.naturalFiberOrganic, .safeFabric])
        XCTAssertEqual(QualityLabelBadge.Label.all(for: products[0]), [.naturalFiber])
        XCTAssertEqual(QualityLabelBadge.Label.naturalFiberOrganic.title, "Marracat Natural Fiber · Organic")
        XCTAssertEqual(QualityLabelBadge.Label.safeFabric.title, "Marracat Safe Fabric")
    }

    // Marracat Lab Verified, Pet Safe, True Material and Natural Home
    // (catalog/lab_badge.py, pet_badge.py, material_badge.py, home_badge.py):
    // decoded, carried in the third flag byte's top bits and a fourth byte,
    // without shifting later fields, filterable, badged.
    func testLabPetMaterialAndHomeDecodeRoundTripAndFilter() throws {
        func item(_ id: String, lab: Bool? = nil, pet: Bool? = nil, material: String? = nil, home: String? = nil,
                  fabric: Bool? = nil) -> Product {
            Product(id: id, brand: "b", title: "Item \(id)", category: "home", productType: nil, subs: [],
                    price: 30, compareAt: nil, images: [], url: "https://b.example/\(id)", available: true,
                    variants: [], tags: ["t\(id)"], description: "About \(id)", publishedAt: "2026-10-09",
                    bestRank: 3, fabric: fabric, lab: lab, pet: pet, material: material, home: home)
        }
        let json = #"{"id":"p","brand":"b","title":"Oak Board","category":"home","url":"u","price":1,"available":true,"lab":true,"pet":true,"material":"veg","home":"certified"}"#
        let decoded = try JSONDecoder().decode(Product.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isMarracatLabVerified && decoded.isMarracatPetSafe)
        XCTAssertTrue(decoded.isVegetableTanned && decoded.isCertifiedNaturalHome)

        let products = [item("a", lab: true), item("b", pet: true, fabric: true), item("c", material: "true"),
                        item("d", material: "veg", home: "natural"), item("e", home: "certified"), item("f")]
        let small = Catalog(generatedAt: "2026-10-09", categories: [], subcategories: [], brands: [], products: products)
        let back = try XCTUnwrap(CatalogBinary.decode(try CatalogBinary.encode(small)))
        XCTAssertEqual(back.products.map(\.lab), [true, nil, nil, nil, nil, nil])
        XCTAssertEqual(back.products.map(\.pet), [nil, true, nil, nil, nil, nil])
        XCTAssertEqual(back.products.map(\.material), [nil, nil, "true", "veg", nil, nil])
        XCTAssertEqual(back.products.map(\.home), [nil, nil, nil, "natural", "certified", nil])
        XCTAssertEqual(back.products.map(\.fabric), [nil, true, nil, nil, nil, nil], "the Safe Fabric bit is untouched")
        XCTAssertEqual(back.products.map(\.description), ["About a", "About b", "About c", "About d", "About e", "About f"])
        XCTAssertEqual(back.products.map(\.bestRank), [3, 3, 3, 3, 3, 3])

        XCTAssertEqual(products.filter(ProductFilters.Offer.labVerified.matches).map(\.id), ["a"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.petSafe.matches).map(\.id), ["b"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.trueMaterial.matches).map(\.id), ["c", "d"])
        XCTAssertEqual(products.filter(ProductFilters.Offer.naturalHome.matches).map(\.id), ["d", "e"])
        XCTAssertEqual(QualityLabelBadge.Label.all(for: products[3]), [.trueMaterialVeg, .naturalHome])
        XCTAssertEqual(QualityLabelBadge.Label.all(for: products[4]), [.naturalHomeCertified])
        XCTAssertEqual(QualityLabelBadge.Label.labVerified.title, "Marracat Lab Verified")
        XCTAssertEqual(QualityLabelBadge.Label.petSafe.title, "Marracat Pet Safe")
        XCTAssertEqual(QualityLabelBadge.Label.trueMaterial.title, "Marracat True Material")
        XCTAssertEqual(QualityLabelBadge.Label.naturalHome.title, "Marracat Natural Home")
    }
}
