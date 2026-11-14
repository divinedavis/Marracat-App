import XCTest
@testable import Marracat

/// The same cases as the website's filter tests: a note on a shared product is
/// encrypted, so this phone-side check is the only one it gets.
final class ContentFilterTests: XCTestCase {
    func testAllowsOrdinaryTalkIncludingSwearing() {
        for text in ["This shea butter is the shit", "Rapeseed oil base, love it", "Grape scent is nice",
                     "my raccoon hat", "Scunthorpe delivery was quick", "Love it! 5 stars"] {
            XCTAssertNil(ContentFilter.refusal(text), text)
        }
    }
    func testRefusesSlursEvasionsThreatsAndLinks() {
        for text in ["you n i g g e r", "n1gg3r", "f4gg0t", "go die", "kill your self",
                     "check www.scam.io", "https://evil.test/x", "visit brand.com"] {
            XCTAssertNotNil(ContentFilter.refusal(text), text)
        }
    }
}
