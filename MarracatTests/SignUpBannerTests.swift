import XCTest
@testable import Marracat

/// Home's sign-up card (owner, 2026-11-22) has a close. Closing it puts it
/// away for a week, not for good: the owner asked for it wherever someone
/// isn't signed up. The launch outline leaves the card's room only when the
/// card will be there.
final class SignUpBannerTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    func testAClosePutsTheCardAwayForAWeek() {
        let closed = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(SignUpBanner.isSnoozed(closedAt: 0, now: closed), "never closed")
        XCTAssertTrue(SignUpBanner.isSnoozed(closedAt: closed.timeIntervalSince1970, now: closed))
        XCTAssertTrue(SignUpBanner.isSnoozed(closedAt: closed.timeIntervalSince1970, now: closed + 6.9 * day))
        XCTAssertFalse(SignUpBanner.isSnoozed(closedAt: closed.timeIntervalSince1970, now: closed + 7 * day), "back after a week")
    }

    func testTheLaunchOutlineLeavesRoomOnlyForACardThatWillShow() throws {
        let suite = "SignUpBannerTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(SignUpBanner.expected(defaults, now: now), "nothing known yet: someone updating may be signed in")
        defaults.set(true, forKey: AccountStore.guestKey)
        XCTAssertTrue(SignUpBanner.expected(defaults, now: now), "a guest's Home opens with the card")
        defaults.set(now.timeIntervalSince1970 - day, forKey: SignUpBanner.closedKey)
        XCTAssertFalse(SignUpBanner.expected(defaults, now: now), "closed yesterday")
        defaults.set(false, forKey: AccountStore.guestKey)
        defaults.removeObject(forKey: SignUpBanner.closedKey)
        XCTAssertFalse(SignUpBanner.expected(defaults, now: now), "signed in")
    }
}
