import XCTest
@testable import Marracat

/// The seal on each product-page badge (owner, 2026-10-31) writes the badge's
/// name around its rim.
final class BadgeSealTests: XCTestCase {
    func testRimTextSplitsTheBrandFromTheBadge() {
        XCTAssertEqual(BadgeSealMark.ring(for: "Marracat Clean"), "MARRACAT • CLEAN •")
        XCTAssertEqual(BadgeSealMark.ring(for: "Marracat True Material"), "MARRACAT • TRUE MATERIAL •")
        XCTAssertEqual(BadgeSealMark.ring(for: "Certified organic"), "CERTIFIED • ORGANIC •")
    }

    /// Every quality label has a seal: a name to put on the rim, and a
    /// tier ("· Organic") that VoiceOver reads and the rim leaves out.
    func testEveryQualityLabelGetsASealName() {
        for label in QualityLabelBadge.Label.allCases {
            let name = label.title.components(separatedBy: " · ")[0]
            XCTAssertTrue(name.hasPrefix("Marracat "), label.title)
            XCTAssertFalse(BadgeSealMark.ring(for: name).contains("·"), label.title)
        }
    }
}
