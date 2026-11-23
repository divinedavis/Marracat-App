import XCTest
import SwiftUI
@testable import Marracat

/// The app's type is the system's, and never bold (owner, 2026-11-22: "I
/// don't want bold and switch our font back", after a build in Futura).
/// Whatever weight a view asks for, the heaviest drawn is medium.
final class BrandFontTests: XCTestCase {
    func testNothingIsDrawnHeavierThanMedium() {
        XCTAssertEqual(BrandFont.heaviest, .medium)
        for asked in [Font.Weight.semibold, .bold, .heavy, .black] {
            XCTAssertEqual(BrandFont.body.weight(asked).shownWeight, .medium, "\(asked)")
        }
        XCTAssertEqual(BrandFont.caption2.bold().shownWeight, .medium)
        XCTAssertEqual(BrandFont.headline.shownWeight, .medium, "a headline is semibold to the system")
        XCTAssertEqual(BrandFont.system(size: 21, weight: .heavy).shownWeight, .medium)
    }

    func testLighterWeightsAreKept() {
        XCTAssertEqual(BrandFont.body.shownWeight, .regular)
        XCTAssertEqual(BrandFont.body.weight(.light).shownWeight, .light)
        XCTAssertEqual(BrandFont.body.weight(.medium).shownWeight, .medium)
    }

    /// The face is the system's: the same font `Font` itself would give.
    func testTheFaceIsTheSystems() {
        XCTAssertEqual(BrandFont.subheadline.font, Font.system(.subheadline, design: .default, weight: .regular))
        XCTAssertEqual(BrandFont.title3.bold().font, Font.system(.title3, design: .default, weight: .medium))
        XCTAssertEqual(BrandFont.system(size: 21, weight: .bold).font, Font.system(size: 21, weight: .medium, design: .default))
        XCTAssertEqual(BrandFont.caption.monospaced().font, Font.system(.caption, design: .monospaced, weight: .regular))
        XCTAssertEqual(BrandFont.body.italic().font, Font.system(.body, design: .default, weight: .regular).italic())
        XCTAssertEqual(BrandFont.system(size: 21).size, .fixed(21))
        XCTAssertTrue(BrandFont.system(size: 11, weight: .bold, design: .monospaced).isMonospaced, "codes keep the monospaced face")
    }

    func testBarsAndControlsFollowTheSameRule() {
        let system = UIFont.systemFont(ofSize: 17).familyName
        XCTAssertEqual(BrandFont.ui(17).familyName, system)
        XCTAssertEqual(BrandFont.ui(17, heavy: true), UIFont.systemFont(ofSize: 17, weight: .medium))
        XCTAssertEqual(BrandFont.ui(13), UIFont.systemFont(ofSize: 13, weight: .regular))
    }
}
