import XCTest
@testable import Marracat

/// Hold Add to List fans the lists out over the chip; every bubble and its
/// caption has to land on screen wherever the chip sits (owner, 2026-10-06:
/// with the chip at the left edge the first bubble was half off screen).
final class QuickListFanTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    /// Half the widest caption, which is wider than the bubble.
    private let halfCaption: CGFloat = 48

    private func assertOnScreen(chipX: CGFloat, count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let chip = CGRect(x: chipX - 58, y: 680, width: 116, height: 37)
        let spots = QuickListFan.layout(anchor: chip, in: phone, count: count).bubbles
        XCTAssertEqual(spots.count, count, file: file, line: line)
        for p in spots {
            XCTAssertGreaterThanOrEqual(p.x - halfCaption, 0, "bubble at \(p) is off the left edge", file: file, line: line)
            XCTAssertLessThanOrEqual(p.x + halfCaption, phone.width, "bubble at \(p) is off the right edge", file: file, line: line)
            XCTAssertGreaterThanOrEqual(p.y - 30, 0, "bubble at \(p) is off the top", file: file, line: line)
        }
    }

    func testChipAtTheLeftEdgeKeepsEveryBubbleOnScreen() {
        // The owner's screenshot: Add to List first in its row, two choices.
        for n in 1...6 { assertOnScreen(chipX: 80, count: n) }
    }

    func testChipAtTheRightEdgeKeepsEveryBubbleOnScreen() {
        for n in 1...6 { assertOnScreen(chipX: 340, count: n) }
    }

    func testChipMidScreenStaysCentredOnTheChip() {
        let chip = CGRect(x: 143, y: 680, width: 116, height: 37)
        XCTAssertEqual(QuickListFan.layout(anchor: chip, in: phone, count: 3).center.x, chip.midX)
    }
}
