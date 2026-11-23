import XCTest
@testable import Marracat

/// Home offers an account only to someone without one (SignUpBanner; owner,
/// 2026-11-22). The session is read from the Keychain a moment after launch,
/// so until it has been looked for nobody counts as a guest: a shopper who is
/// signed in never sees the banner come and go. (That a guest does see it
/// is a UI test, testAGuestIsOfferedAnAccountAtTheTopOfHome: attaching a
/// store here would point the app's shared stores at a test account.)
@MainActor
final class AccountGuestTests: XCTestCase {
    func testNobodyIsAGuestUntilTheSessionHasBeenLookedFor() throws {
        let suite = "AccountGuestTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = AccountStore(defaults: defaults)
        XCTAssertFalse(account.restored)
        XCTAssertFalse(account.isGuest, "a guest before the saved session was looked for")
        XCTAssertNil(defaults.object(forKey: AccountStore.guestKey))
    }
}
