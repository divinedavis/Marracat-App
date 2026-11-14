import Foundation
import Testing
@testable import Marracat

/// The shopper profiles beyond the one taste point (owner, 2026-11-08): several
/// interests, price comfort, sizes, what pushes away, the Women / Men lean.
@MainActor
struct ShopperModelTests {
    private func defaults() -> UserDefaults {
        let name = "shopper-model-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func product(_ id: String, _ category: String = "clothing", price: Double = 50, brand: String = "b",
                         gender: [String]? = nil) -> Product {
        Product(id: id, brand: brand, title: id, category: category, productType: nil, subs: [], price: price, compareAt: nil,
                images: [], url: "https://b.example/\(id)", available: true, variants: [], tags: [], description: nil,
                publishedAt: nil, bestRank: nil, attrs: gender.map { ["gender": $0] })
    }

    /// A unit vector near axis `axis` of 4, nudged by `wobble`.
    private func near(_ axis: Int, _ wobble: Float = 0) -> [Float] {
        var v: [Float] = [0, 0, 0, 0]; v[axis] = 1; v[(axis + 1) % 4] = wobble
        return TasteMath.normalized(v)
    }

    // MARK: 1. Several interests

    @Test func twoClearInterestsStayApart() {
        let items = [("hair1", near(0), Float(3)), ("hair2", near(0, 0.1), 2), ("hair3", near(0, 0.05), 2),
                     ("shoe1", near(2), 3), ("shoe2", near(2, 0.1), 2)].map { (id: $0.0, vector: $0.1, weight: $0.2) }
        let found = TasteMath.interests(items)
        #expect(found.count == 2)
        #expect(Set(found[0].products) == ["hair1", "hair2", "hair3"], "the bigger interest first")
        #expect(Set(found[1].products) == ["shoe1", "shoe2"])
        #expect(abs(found.map(\.share).reduce(0, +) - 1) < 0.001)
    }

    @Test func aStrayGlanceIsNotAnInterest() {
        let items = [("a", near(0), Float(5)), ("b", near(0, 0.1), 4), ("c", near(0, 0.2), 4),
                     ("stray", near(3), 0.5)].map { (id: $0.0, vector: $0.1, weight: $0.2) }
        let found = TasteMath.interests(items)
        #expect(found.count == 1, "under 15% of the weight folds into the nearest interest")
        #expect(found[0].products.count == 4)
    }

    @Test func interestsTakeTurnsInTheRowBySize() {
        #expect(TasteMath.slots([0.7, 0.3], limit: 10) == [7, 3])
        #expect(TasteMath.slots([0.9, 0.05, 0.05], limit: 6) == [2, 2, 2], "two each at least")
        let row = TasteMath.interleave([["a1", "a2", "a3", "shared"], ["b1", "shared", "b2"]], slots: [3, 2])
        #expect(row == ["a1", "b1", "a2", "shared", "a3"], "in turn, no repeats")
    }

    // MARK: 3. Price comfort

    @Test func priceComfortIsPerDepartmentAndDemotesOnlyAbove() throws {
        let touched = [20.0, 25, 30, 35, 40].map { (category: "skincare", usd: $0, weight: Float(1)) }
            + [200.0, 250, 300].map { (category: "clothing", usd: $0, weight: Float(1)) }
        let comfort = PriceComfort.learn(touched)
        #expect(comfort.bands["clothing"] == nil, "fewer than four products: nothing learned")
        let band = try #require(comfort.bands["skincare"])
        #expect(band.lowerBound == 12 && band.upperBound == 60)
        #expect(comfort.isAbove(product("serum", "skincare", price: 75)))
        #expect(!comfort.isAbove(product("cheap", "skincare", price: 5)), "cheaper is never pushed back")
        #expect(!comfort.isAbove(product("coat", "clothing", price: 900)), "a department with no range is left alone")
    }

    // MARK: 4. Sizes

    @Test func sizeIsReadFromTheVariantTitle() {
        #expect(SizeMemory.size(in: "Black / M") == "M")
        #expect(SizeMemory.size(in: "XL / Sand") == "XL")
        #expect(SizeMemory.size(in: "8.5") == "8.5")
        #expect(SizeMemory.size(in: "32 x 30 / Indigo") == "32 x 30")
        #expect(SizeMemory.size(in: "Red / Large", optionNames: ["Color", "Size"]) == "Large")
        #expect(SizeMemory.size(in: "Lavender / Mini") == nil, "a scent or colour isn't a size")
        #expect(SizeMemory.size(in: "Default Title") == nil)
    }

    @Test func aBrandsOwnSizeWinsAndOnlyInStockIsPicked() {
        var memory = SizeMemory()
        memory.remember("M", department: "clothing", brand: "a")
        memory.remember("L", department: "clothing", brand: "b")
        memory.remember("10", department: "beauty", brand: "a")
        #expect(memory.byDepartment["beauty"] == nil, "only clothing and shoes")
        #expect(memory.usual(department: "clothing", brand: "a") == "M")
        #expect(memory.usual(department: "clothing", brand: "new") == "L", "the latest size for a new brand")
        let variants = [Variant(id: 1, title: "Black / S", price: 1, available: true),
                        Variant(id: 2, title: "Black / M", price: 1, available: false),
                        Variant(id: 3, title: "White / M", price: 1, available: true)]
        #expect(memory.variant(in: variants, department: "clothing", brand: "a")?.id == 3)
        memory.forget(department: "clothing")
        #expect(memory.usual(department: "clothing", brand: "a") == nil)
        let d = defaults()
        memory.remember("S", department: "shoes", brand: "c")
        memory.save(d)
        #expect(SizeMemory.load(d) == memory)
    }

    // MARK: 6. What pushes away

    @Test func aSteadyWomenOrMenChoiceLeans() {
        let d = defaults()
        GenderLean.record(["women"], defaults: d)
        #expect(GenderLean.side(defaults: d) == nil, "one pick may be for someone else")
        GenderLean.record(["women", "men"], defaults: d)
        GenderLean.record(["women"], defaults: d)
        #expect(GenderLean.side(defaults: d) == "women")
        GenderLean.record(["men"], defaults: d)
        #expect(GenderLean.side(defaults: d) == nil, "mixed picks: no lean")
        let old = defaults()
        GenderLean.record(["men"], at: .now.addingTimeInterval(-90 * 86_400), defaults: old)
        GenderLean.record(["men"], defaults: old)
        #expect(GenderLean.side(defaults: old) == nil, "a pick older than 60 days doesn't count")
    }

    @Test func theLeanLeavesOutOnlyTheOtherSidesClothing() {
        #expect(!GenderLean.fits(product("dress", gender: ["women"]), side: "men"))
        #expect(GenderLean.fits(product("tee", gender: ["men", "women"]), side: "men"), "unisex fits")
        #expect(GenderLean.fits(product("plain"), side: "men"), "unlabelled fits")
        #expect(GenderLean.fits(product("serum", "skincare", gender: ["women"]), side: "men"), "outside clothing and shoes")
        #expect(GenderLean.fits(product("dress", gender: ["women"]), side: nil))
    }

    @Test func mutingAndNotMeAreRememberedAndStartOverClearsAll() {
        let d = defaults()
        let taste = TasteProfile(defaults: d)
        taste.record("a", .save); taste.record("b", .view); taste.record("a", .cart)
        #expect(taste.weightedProducts().map(\.id) == ["a", "b"], "summed per product, heaviest first")
        taste.mute(["a"])
        #expect(taste.weightedProducts().map(\.id) == ["b"])
        taste.setNotMe("glam-night", true)
        var memory = SizeMemory(); memory.remember("M", department: "clothing", brand: "x"); memory.save(d)
        let again = TasteProfile(defaults: d)
        #expect(again.muted == ["a"] && again.notMeStyles == ["glam-night"], "kept across launches")
        again.clear()
        #expect(again.muted.isEmpty && again.notMeStyles.isEmpty && again.weightedProducts().isEmpty)
        #expect(SizeMemory.load(d) == SizeMemory(), "sizes go with Start over")
    }
}
