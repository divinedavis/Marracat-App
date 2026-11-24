import XCTest
@testable import Marracat

/// Home's sign-up card (owner, 2026-11-22) has a close, and closing it puts
/// it away for good (owner, 2026-11-23: "i want forever"). The launch outline
/// leaves the card's room only when the card will be there.
final class SignUpBannerTests: XCTestCase {
    private let day: TimeInterval = 24 * 3600

    func testAClosePutsTheCardAwayForGood() {
        XCTAssertFalse(SignUpBanner.isClosed(closedAt: 0), "never closed")
        XCTAssertTrue(SignUpBanner.isClosed(closedAt: Date.now.timeIntervalSince1970))
        XCTAssertTrue(SignUpBanner.isClosed(closedAt: Date.now.timeIntervalSince1970 - 400 * day), "still away a year on")
    }

    func testTheLaunchOutlineLeavesRoomOnlyForACardThatWillShow() throws {
        let suite = "SignUpBannerTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertFalse(SignUpBanner.expected(defaults), "nothing known yet: someone updating may be signed in")
        defaults.set(true, forKey: AccountStore.guestKey)
        XCTAssertTrue(SignUpBanner.expected(defaults), "a guest's Home opens with the card")
        defaults.set(now.timeIntervalSince1970 - 30 * day, forKey: SignUpBanner.closedKey)
        XCTAssertFalse(SignUpBanner.expected(defaults), "closed a month ago")
        defaults.set(false, forKey: AccountStore.guestKey)
        defaults.removeObject(forKey: SignUpBanner.closedKey)
        XCTAssertFalse(SignUpBanner.expected(defaults), "signed in")
    }
}
