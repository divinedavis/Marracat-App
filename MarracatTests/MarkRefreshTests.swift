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

    /// Letting go: the M the pull drew is whole at that moment, then wipes away
    /// smoothly into the first trip (owner, 2026-11-28: it popped off).
    func testLettingGoWipesTheDrawnMAwaySmoothly() {
        let start = MarkRefresh.segment(at: 0)
        XCTAssertEqual(start.from, 0); XCTAssertEqual(start.to, 1, "the whole M, as the pull left it")
        var last = MarkRefresh.segment(at: 0)
        for k in 1...90 {
            let s = MarkRefresh.segment(at: Double(k) / 60)
            // How much of the M is lit never jumps by more than a fifth of
            // the letter in a 60 fps frame.
            XCTAssertLessThan(abs((s.to - s.from) - (last.to - last.from)), 0.2, "frame \(k)")
            last = s
        }
        // The hand-off: the wipe ends with nothing lit, and the first trip
        // starts with nothing lit, so the ends may move without a jump.
        let end = MarkRefresh.segment(at: MarkRefresh.wipe - 0.0001)
        XCTAssertLessThan(end.to - end.from, 0.01, "wiped away just before the first trip")
        let first = MarkRefresh.segment(at: MarkRefresh.wipe)
        XCTAssertLessThan(first.to - first.from, 0.01, "the first trip enters from nothing")
        XCTAssertGreaterThanOrEqual(MarkRefresh.minimumShow, MarkRefresh.wipe + 1.33, "the wipe and one full trip")
    }

    /// The M follows the pull until the refresh's gap is open, then holds
    /// still: a deeper pull, and the gap closing back to 60 pt, moved it.
    func testTheMHoldsItsPlaceOnceTheGapIsOpen() {
        XCTAssertEqual(MarkRefresh.centre(gap: 30), 15)
        XCTAssertEqual(MarkRefresh.centre(gap: MarkRefresh.heldGap), MarkRefresh.heldGap / 2)
        XCTAssertEqual(MarkRefresh.centre(gap: 140), MarkRefresh.centre(gap: MarkRefresh.heldGap))
    }
}
