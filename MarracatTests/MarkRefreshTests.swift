import XCTest
import SwiftUI
@testable import Marracat

/// Pull to refresh draws the Marracat M (owner, 2026-11-18).
final class MarkRefreshTests: XCTestCase {
    func testAPullDrawsTheMInAsItGoes() {
        XCTAssertEqual(MarkRefresh.drawn(overscroll: 0), 0)
        XCTAssertEqual(MarkRefresh.drawn(overscroll: MarkRefresh.fullPull / 2), 0.5, accuracy: 0.001)
        XCTAssertEqual(MarkRefresh.drawn(overscroll: MarkRefresh.fullPull), 1)
        XCTAssertEqual(MarkRefresh.drawn(overscroll: 400), 1, "a long pull never draws past the end")
        XCTAssertEqual(MarkRefresh.drawn(overscroll: -20), 0)
    }

    func testWhileRefreshingASegmentTravelsAlongTheM() {
        var heads: [CGFloat] = []
        for k in 0..<40 {
            let s = MarkRefresh.segment(at: 1000 + Double(k) * 0.033)
            XCTAssertGreaterThanOrEqual(s.from, 0); XCTAssertLessThanOrEqual(s.to, 1)
            XCTAssertLessThanOrEqual(s.from, s.to)
            XCTAssertLessThanOrEqual(s.to - s.from, 0.35 + 0.0001, "a segment, never the whole letter")
            heads.append(s.to)
        }
        XCTAssertGreaterThan(Set(heads.map { ($0 * 100).rounded() }).count, 10, "the segment moves")
    }
}
