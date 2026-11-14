import XCTest
@testable import Marracat

/// The on-device AI pieces that don't need the 61 MB model: the vector file,
/// nearest-product scoring, averaging, and restock timing.
final class MeaningTests: XCTestCase {
    /// A vector file in catalog/embed_products.py's layout: 3 products, 2 dims
    /// from 2 model dims (identity projection, zero mean).
    private func vectorsFile(scale: Float = 1.0 / 127.0) -> Data {
        var d = Data("MRV1".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        u32(2); u32(2); u32(2); u32(3)
        [0, 0].forEach(f32)                       // mean
        [1, 0, 0, 1].forEach(f32)                 // projection
        [scale, scale, scale].forEach(f32)        // per-product scale
        [0, 0, 0.4].forEach(f32)                  // hub: "purple" sits close to everything
        for id in ["red", "blue", "purple"] { u32(id.utf8.count); d.append(Data(id.utf8)) }
        d.append(contentsOf: [127, 0, 0, 127, 90, 90].map { UInt8(bitPattern: Int8($0)) })
        return d
    }

    /// v5 runs on the Neural Engine only while its probe agrees with v4.
    func testProbeReferenceIsAUnitVectorFromTheModel() {
        let r = MeaningIndex.probeReference
        XCTAssertEqual(r.count, 768, "MobileCLIP2-S4 text embeddings are 768 wide (S0's were 512)")
        XCTAssertTrue(r.allSatisfy(\.isFinite))
        XCTAssertEqual(sqrt(r.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-3)
    }

    func testProbeAcceptsV4AgreementAndRejectsNaNOrDrift() {
        let r = MeaningIndex.probeReference
        XCTAssertTrue(MeaningIndex.probeOK(r))
        // 16-bit rounding (what the Neural Engine adds) still passes.
        XCTAssertTrue(MeaningIndex.probeOK(MeaningIndex.normalized(r.map { Float(Float16($0)) })))
        var nan = r; nan[7] = .nan
        XCTAssertFalse(MeaningIndex.probeOK(nan), "the 10/2 failure mode")
        XCTAssertFalse(MeaningIndex.probeOK(r.map { _ in 0 }), "a dead output")
        XCTAssertFalse(MeaningIndex.probeOK(r.map { -$0 }), "pointing elsewhere")
        XCTAssertFalse(MeaningIndex.probeOK(Array(r.prefix(256))), "wrong width")
        XCTAssertFalse(MeaningIndex.probeOK(nil), "no output at all")
        // Half the dimensions scrambled: a model that's off, not rounded.
        let off = MeaningIndex.normalized(r.enumerated().map { $0.offset % 2 == 0 ? $0.element : r[(($0.offset * 7) % r.count)] })
        XCTAssertFalse(MeaningIndex.probeOK(off))
    }

    func testVectorFileParsesAndRejectsDamage() throws {
        let v = try XCTUnwrap(MeaningIndex.parseVectors(vectorsFile()))
        XCTAssertEqual(v.ids, ["red", "blue", "purple"]); XCTAssertEqual(v.dims, 2)
        XCTAssertEqual(v.indexByID["purple"], 2)
        XCTAssertEqual(v.hub, [0, 0, 0.4], "version 2 carries each product's hub penalty")
        XCTAssertNil(MeaningIndex.parseVectors(vectorsFile().dropLast()), "truncated")
        var bad = vectorsFile(); bad[0] = 0
        XCTAssertNil(MeaningIndex.parseVectors(bad), "wrong magic")
        XCTAssertNil(MeaningIndex.parseVectors(Data()))
    }

    func testProjectionNormalisesAndCentres() throws {
        let v = try XCTUnwrap(MeaningIndex.parseVectors(vectorsFile()))
        let p = MeaningIndex.project([3, 4], v)
        XCTAssertEqual(p[0], 0.6, accuracy: 1e-5); XCTAssertEqual(p[1], 0.8, accuracy: 1e-5)
    }

    func testAffinityIsADotProduct() {
        XCTAssertEqual(TasteProfile.affinity([1, 0], [0.6, 0.8]), 0.6, accuracy: 1e-6)
        XCTAssertEqual(TasteProfile.affinity([0, 1], [0, -1]), -1, accuracy: 1e-6)
    }

    @MainActor
    func testRestockRemindersFollowTheShoppersOwnInterval() throws {
        let catalog = CatalogStore(synchronously: true)
        let hair = try XCTUnwrap(catalog.catalog.products.first { $0.category == "hair" && $0.available })
        let bags = try XCTUnwrap(catalog.catalog.products.first { $0.category == "bags" && $0.available })
        let day: TimeInterval = 86_400
        let now = Date()
        func order(_ ids: [String], daysAgo: Double) -> CheckoutRecord {
            CheckoutRecord(brandID: "b", date: now.addingTimeInterval(-daysAgo * day), itemCount: ids.count, subtotal: 10, productIDs: ids)
        }
        // Hair care runs ~45 days by default: due at 40 days (a week ahead), not at 10.
        XCTAssertEqual(Replenishment.due(checkouts: [order([hair.id], daysAgo: 40)], catalog: catalog, now: now).map(\.id), [hair.id])
        XCTAssertTrue(Replenishment.due(checkouts: [order([hair.id], daysAgo: 10)], catalog: catalog, now: now).isEmpty)
        // Their own rhythm wins: bought 50 days apart, so 40 days on isn't due yet.
        let rhythm = [order([hair.id], daysAgo: 90), order([hair.id], daysAgo: 40)]
        XCTAssertTrue(Replenishment.due(checkouts: rhythm, catalog: catalog, now: now).isEmpty)
        // A bag isn't a consumable.
        XCTAssertTrue(Replenishment.due(checkouts: [order([bags.id], daysAgo: 60)], catalog: catalog, now: now).isEmpty)
    }

    func testNthLargestMatchesASort() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let values = (0..<500).map { _ in Float.random(in: -1...1, using: &rng) } + [0.5, 0.5, 0.5]
            let sorted = values.sorted(by: >)
            for n in [1, 2, 10, 250, 503] { XCTAssertEqual(MeaningIndex.nthLargest(values, n), sorted[n - 1]) }
        }
    }

    /// Accelerate's block scoring gives what the one-product score gives, past
    /// a block boundary (2048) and on a partial last block.
    func testScoresMatchTheOneProductScoreAcrossBlocks() throws {
        var rng = SystemRandomNumberGenerator()
        let count = 5_000, dims = 16
        let ids = (0..<count).map { "p\($0)" }
        let v = MeaningIndex.Vectors(
            dims: dims, modelDims: dims, mean: [Float](repeating: 0, count: dims),
            projection: (0..<dims * dims).map { $0 % (dims + 1) == 0 ? 1 : 0 },
            scale: (0..<count).map { _ in Float.random(in: 0.001...0.02, using: &rng) },
            hub: (0..<count).map { _ in Float.random(in: 0...0.5, using: &rng) },
            ids: ids, rows: (0..<count * dims).map { _ in Int8.random(in: -127...127, using: &rng) },
            indexByID: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) }))
        let index = MeaningIndex()
        index.installForTesting(v)
        let query = MeaningIndex.normalized((0..<dims).map { _ in Float.random(in: -1...1, using: &rng) })
        let scores = MeaningIndex.scores(query, v)
        XCTAssertEqual(scores.count, count)
        for i in [0, 1, 2047, 2048, 4095, 4096, 4999] {
            XCTAssertEqual(scores[i], try XCTUnwrap(index.score(query, productID: ids[i])), accuracy: 1e-4, "product \(i)")
        }
        let top = index.nearest(to: query, limit: 10)
        let expected = scores.enumerated().sorted { $0.element > $1.element }.prefix(10).map { ids[$0.offset] }
        XCTAssertEqual(top.map(\.id), expected)
        XCTAssertEqual(index.nearest(to: query, limit: 5) { $0.hasSuffix("7") }.count, 5, "the filter still applies")
    }

    /// Every Shop by style prompt ships with the Mac's embedding of it
    /// (catalog/embed_style_prompts.py), so the boards never load the model.
    /// A prompt edited without rerunning the script drops out of this and
    /// fails here.
    func testEveryStylePromptHasItsPrecomputedVector() {
        XCTAssertEqual(Set(ShopStyle.precomputed.keys), Set(ShopStyle.all.map(\.id)),
                       "rerun catalog/embed_style_prompts.py after changing a prompt")
        for (id, raw) in ShopStyle.precomputed {
            XCTAssertEqual(raw.count, MeaningIndex.probeReference.count, "\(id): made by the app's model (S4, 768 wide)")
            XCTAssertEqual(sqrt(raw.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-3, "\(id) should be unit length")
        }
        // Distinct sentences, distinct points.
        let urban = ShopStyle.precomputed["urban-luxe"]!, cozy = ShopStyle.precomputed["cozy-home"]!
        XCTAssertLessThan(TasteProfile.affinity(urban, cozy), 0.95)
    }

    /// Styles reach past fashion (laundry, food, wellness, hair, kids, pets),
    /// and a list of them never puts more than two fashion styles in a row
    /// while another kind is left (owner, 2026-11-09).
    func testStyleListsMixInStylesBeyondFashion() {
        let others = ShopStyle.all.filter { !$0.isFashion }.map(\.id)
        XCTAssertTrue(Set(["fresh-clean", "home-cook", "wellness-ritual", "crown-care", "little-ones", "pet-pals"]).isSubset(of: Set(others)))
        XCTAssertTrue(ShopStyle.fashion.isSubset(of: Set(ShopStyle.all.map(\.id))), "a fashion id that isn't a style")
        // All fashion first in, mixed out.
        let byTaste = ShopStyle.all.filter(\.isFashion) + ShopStyle.all.filter { !$0.isFashion }
        let out = ShopStyle.mixed(byTaste, style: { $0 })
        XCTAssertEqual(Set(out.map(\.id)), Set(byTaste.map(\.id)), "nothing dropped")
        XCTAssertEqual(out.prefix(3).map(\.isFashion), [true, true, false])
        for i in 2..<out.count where out[i - 2].isFashion && out[i - 1].isFashion {
            if out[i...].contains(where: { !$0.isFashion }) { XCTAssertFalse(out[i].isFashion, "three fashion in a row at \(i)") }
        }
        // Each kind keeps its own order.
        XCTAssertEqual(out.filter(\.isFashion).map(\.id), byTaste.filter(\.isFashion).map(\.id))
        XCTAssertEqual(out.filter { !$0.isFashion }.map(\.id), byTaste.filter { !$0.isFashion }.map(\.id))
    }

    /// S4 (2026-10-24) lives in its own files, so builds still running S0
    /// keep v1-v3 and this build never reads a vector from S0's space.
    func testS4UsesItsOwnFiles() {
        XCTAssertEqual(MeaningIndex.vectorsURL.lastPathComponent, "product-vectors-v2.bin")
        XCTAssertEqual(MeaningIndex.modelURL.lastPathComponent, "mobileclip-text-v5.aar")
        XCTAssertEqual(MeaningIndex.fallbackModelURL.lastPathComponent, "mobileclip-text-v4.aar")
        XCTAssertEqual(InterestsStore.matchThreshold, 0.33, accuracy: 1e-6, "re-tuned for S4's scores")
    }

    /// `place` puts a stored model output where `embed` puts the model's own:
    /// centred, projected, unit length.
    func testPlacingARawEmbeddingMatchesTheProjection() throws {
        let v = try XCTUnwrap(MeaningIndex.parseVectors(vectorsFile()))
        let index = MeaningIndex()
        index.installForTesting(v)
        let placed = try XCTUnwrap(index.place(raw: [3, 4]))
        XCTAssertEqual(placed, MeaningIndex.project([3, 4], v))
        XCTAssertNil(index.place(raw: [1]), "wrong width")
        XCTAssertNil(index.place(raw: [.nan, 1]))
    }

    func testSpaceFingerprintFollowsTheProjection() throws {
        let a = try XCTUnwrap(MeaningIndex.parseVectors(vectorsFile()))
        var moved = vectorsFile()
        // Change one projection float (after magic, 4 u32s and the 2-float mean).
        moved[4 + 16 + 8] ^= 0x01
        let b = try XCTUnwrap(MeaningIndex.parseVectors(moved))
        XCTAssertEqual(a.space, try XCTUnwrap(MeaningIndex.parseVectors(vectorsFile())).space, "stable for the same file")
        XCTAssertNotEqual(a.space, b.space, "a new projection is a new space")
    }
}
