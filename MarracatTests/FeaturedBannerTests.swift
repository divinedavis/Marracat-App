import XCTest
@testable import Marracat

/// Search's Featured banner (owner, 2026-10-12): premier brands only, in
/// Home's premier order, each with something in stock; Curves leads with a
/// tote; each search opens on the brand after the last one shown.
@MainActor
final class FeaturedBannerTests: XCTestCase {
    func testSlidesArePremierBrandsWithStockInHomesOrder() {
        let catalog = CatalogStore(synchronously: true)
        let mix = BrandMix(seed: 7)
        let slides = FeaturedBanner.slides(catalog, mix: mix)
        XCTAssertFalse(slides.isEmpty, "no premier brand in the bundled catalog has stock")
        XCTAssertEqual(Set(slides.map(\.id)).count, slides.count, "a brand appears twice")
        for s in slides {
            XCTAssertTrue(CatalogStore.premierBrandIDs.contains(s.id), "\(s.id) isn't a premier brand")
            XCTAssertTrue(catalog.products(for: s.id).contains(where: \.available), "\(s.id) has nothing in stock")
        }
        // Same order as Home's hero for this launch's mix, minus brands left out.
        let order = mix.premierOrder(catalog.premierBrands, id: \.id).map(\.id)
        XCTAssertEqual(slides.map(\.id), order.filter { id in slides.contains { $0.id == id } })
        // Every premier brand with stock is in it.
        let stocked = catalog.premierBrands.filter { catalog.products(for: $0.id).contains(where: \.available) }
        XCTAssertEqual(Set(slides.map(\.id)), Set(stocked.map(\.id)))
    }

    func testCurvesLeadsWithATote() throws {
        let catalog = CatalogStore(synchronously: true)
        let slide = try XCTUnwrap(FeaturedBanner.slides(catalog).first { $0.id == "curves" },
                                  "Curves isn't in the banner (nothing in stock?)")
        let totes = catalog.products(for: "curves").filter { $0.title.lowercased().contains("tote") }
        guard !totes.isEmpty else { return }   // no tote listed today: brand art is the fallback
        XCTAssertTrue(totes.contains { $0.images.first == slide.image }, "Curves' banner isn't a tote")
    }

    func testEachOpenStartsOnTheNextBrand() {
        let catalog = CatalogStore(synchronously: true)
        let slides = FeaturedBanner.slides(catalog)
        guard slides.count > 1 else { return XCTFail("need two premier brands with stock") }
        XCTAssertEqual(FeaturedBanner.start(in: slides, after: nil), slides[0].id)
        XCTAssertEqual(FeaturedBanner.start(in: slides, after: "not-a-brand"), slides[0].id)
        XCTAssertEqual(FeaturedBanner.start(in: slides, after: slides[0].id), slides[1].id)
        XCTAssertEqual(FeaturedBanner.start(in: slides, after: slides.last!.id), slides[0].id, "wraps around")
        XCTAssertNil(FeaturedBanner.start(in: [], after: nil))
    }

    /// Reduce Motion or VoiceOver stops the cycling for good (swipes still
    /// move it); one brand alone has nowhere to go.
    func testOnlyMovesByItselfWithoutReduceMotionOrVoiceOver() {
        XCTAssertTrue(FeaturedBanner.autoAdvances(reduceMotion: false, voiceOver: false, slides: 3))
        XCTAssertFalse(FeaturedBanner.autoAdvances(reduceMotion: true, voiceOver: false, slides: 3), "Reduce Motion")
        XCTAssertFalse(FeaturedBanner.autoAdvances(reduceMotion: false, voiceOver: true, slides: 3), "VoiceOver")
        XCTAssertFalse(FeaturedBanner.autoAdvances(reduceMotion: false, voiceOver: false, slides: 1), "one brand")
        XCTAssertFalse(FeaturedBanner.autoAdvances(reduceMotion: false, voiceOver: false, slides: 0))
    }
}
