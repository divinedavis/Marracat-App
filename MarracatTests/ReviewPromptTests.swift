import XCTest
@testable import Marracat

/// The App Store rating prompt comes once, after the first purchase (owner, 2026-10-06).
final class ReviewPromptTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "ReviewPromptTests")
        defaults.removePersistentDomain(forName: "ReviewPromptTests")
    }

    func testTheFirstPurchaseAsksAndLaterOnesDont() {
        XCTAssertTrue(ReviewPrompt.shouldAsk(defaults: defaults, arguments: []))
        ReviewPrompt.markAsked(defaults: defaults)
        XCTAssertFalse(ReviewPrompt.shouldAsk(defaults: defaults, arguments: []), "the second purchase must not ask again")
    }

    func testUITestsNeverSeeThePrompt() {
        XCTAssertFalse(ReviewPrompt.shouldAsk(defaults: defaults, arguments: ["-UITEST_RESET"]))
    }
}
