import XCTest
@testable import Marracat

/// A tapped delivery notification opens the order even when the You tab's
/// stack hasn't been built yet (owner, 2026-10-09: the tap opened nothing).
@MainActor
final class NavigationTests: XCTestCase {
    func testAPathForATabNotYetShownWaitsForIt() {
        let nav = AppNav()
        nav.show([.checkouts], in: .you)
        XCTAssertEqual(nav.tab, .you)
        XCTAssertEqual(nav.pendingPaths[.you], [.checkouts], "held until the You stack appears")
    }

    func testAPathForAShownTabGoesStraightToItsStack() {
        let nav = AppNav()
        let router = Router()
        nav.routers[.you] = router
        nav.show([.checkouts], in: .you)
        XCTAssertEqual(router.path, [.checkouts])
        XCTAssertNil(nav.pendingPaths[.you])
    }
}
