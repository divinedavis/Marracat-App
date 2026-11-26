import XCTest
import UIKit
@testable import Marracat

/// Your List and the lists are pictured by a list, not a heart (owner,
/// 2026-11-25: "Instead of a heart can we have a list for the lists icon?
/// Change it everywhere"). A symbol name the system doesn't have draws
/// nothing at all, so both names are checked against the system's set.
final class ListsIconTests: XCTestCase {
    func testTheListsIconIsARealSymbolAndNotAHeart() {
        for name in [ListsIcon.name, ListsIcon.filled] {
            XCTAssertNotNil(UIImage(systemName: name), "\(name) isn't an SF Symbol: the tab and Add to List would be blank")
            XCTAssertFalse(name.contains("heart"))
        }
        XCTAssertNotEqual(ListsIcon.name, ListsIcon.filled, "a saved product's chip has to look different from an unsaved one")
    }
}
