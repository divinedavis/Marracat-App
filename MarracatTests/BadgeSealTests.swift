import XCTest
@testable import Marracat

/// The seal on each product-page badge (owner, 2026-10-31) writes the badge's
/// name around its rim.
final class BadgeSealTests: XCTestCase {
    func testRimTextSplitsTheBrandFromTheBadge() {
        XCTAssertEqual(BadgeSealRow.ring(for: "Marracat Clean"), "MARRACAT • CLEAN •")
        XCTAssertEqual(BadgeSealRow.ring(for: "Marracat True Material"), "MARRACAT • TRUE MATERIAL •")
        XCTAssertEqual(BadgeSealRow.ring(for: "Certified organic"), "CERTIFIED • ORGANIC •")
    }

    /// Every quality label has a seal: a name to put on the rim, and a
    /// tier ("· Organic") that stays beside the seal, not on it.
    func testEveryQualityLabelGetsASealName() {
        for label in QualityLabelBadge.Label.allCases {
            let name = label.title.components(separatedBy: " · ")[0]
            XCTAssertTrue(name.hasPrefix("Marracat "), label.title)
            XCTAssertFalse(BadgeSealRow.ring(for: name).contains("·"), label.title)
        }
    }
}
