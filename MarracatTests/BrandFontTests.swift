import XCTest
import SwiftUI
@testable import Marracat

/// The app's type is the logo's (owner, 2026-11-22): Futura Medium for
/// regular text, Futura Bold for semibold and heavier, at the system's own
/// point sizes so Dynamic Type still scales it.
final class BrandFontTests: XCTestCase {
    func testTheFacesShipWithIOS() {
        for name in [BrandFont.medium, BrandFont.bold, BrandFont.mediumItalic] {
            XCTAssertNotNil(UIFont(name: name, size: 17), "\(name) is not on this iOS")
        }
        XCTAssertEqual(BrandFont.ui(17).familyName, "Futura")
        XCTAssertEqual(BrandFont.ui(17, heavy: true).fontName, "Futura-Bold")
    }

    func testWeightPicksTheFace() {
        XCTAssertEqual(BrandFont.body.face, "Futura-Medium")
        XCTAssertEqual(BrandFont.body.weight(.medium).face, "Futura-Medium")
        XCTAssertEqual(BrandFont.body.weight(.light).face, "Futura-Medium")
        XCTAssertEqual(BrandFont.body.weight(.semibold).face, "Futura-Bold")
        XCTAssertEqual(BrandFont.caption2.bold().face, "Futura-Bold")
        XCTAssertEqual(BrandFont.headline.face, "Futura-Bold", "a headline is semibold, as the system's is")
        XCTAssertEqual(BrandFont.body.italic().face, "Futura-MediumItalic")
        XCTAssertEqual(BrandFont.system(size: 21, weight: .heavy).face, "Futura-Bold")
        XCTAssertEqual(BrandFont.system(size: 21).size, .fixed(21))
        XCTAssertTrue(BrandFont.system(size: 11, weight: .bold, design: .monospaced).isMonospaced, "codes keep the monospaced face")
        XCTAssertTrue(BrandFont.caption.monospaced().isMonospaced)
    }

    /// Each style starts from the points the system gives it at the default
    /// text size, so nothing changes size when the face does.
    func testStylesKeepTheSystemsPointSizes() {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let styles: [(Font.TextStyle, UIFont.TextStyle)] = [
            (.largeTitle, .largeTitle), (.title, .title1), (.title2, .title2), (.title3, .title3), (.headline, .headline),
            (.body, .body), (.callout, .callout), (.subheadline, .subheadline), (.footnote, .footnote),
            (.caption, .caption1), (.caption2, .caption2)]
        for (style, ui) in styles {
            XCTAssertEqual(BrandFont.points(style), UIFont.preferredFont(forTextStyle: ui, compatibleWith: large).pointSize, "\(style)")
        }
    }
}
