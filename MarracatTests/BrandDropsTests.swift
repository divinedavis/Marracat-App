import XCTest
@testable import Marracat

/// New-drop watches (owner, 2026-10-20) need an account: the server keeps
/// them and sends the notifications. The watch flow itself is
/// BrandDropsUITests.
@MainActor
final class BrandDropsTests: XCTestCase {
    func testSignedOutShoppersAreAskedToSignIn() async {
        let store = DealAlertStore.shared
        store.signedOut()
        let ok = await store.watchDrops("telfar", categories: ["bags"], account: AccountStore(defaults: UserDefaults(suiteName: "brand-drops-test")!))
        XCTAssertFalse(ok)
        XCTAssertEqual(store.message, "Sign in to hear about new drops.")
        XCTAssertNil(store.drops["telfar"])
        store.message = nil
    }
}
