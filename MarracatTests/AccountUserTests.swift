import XCTest
@testable import Marracat

/// One account, opened by Apple or Google (web/server/identities.js, 2026-10-02).
final class AccountUserTests: XCTestCase {
    private func decode(_ json: String) throws -> AccountUser {
        try JSONDecoder().decode(AccountUser.self, from: Data(json.utf8))
    }

    func testASessionSavedBeforeLinkingStillReadsItsProviderFromTheID() throws {
        let apple = try decode(#"{"id":"apple:001.abc","name":null,"email":null,"generation":"g"}"#)
        XCTAssertTrue(apple.usesApple); XCTAssertEqual(apple.appleUserID, "001.abc"); XCTAssertTrue(apple.deletesWithApple)
        let google = try decode(#"{"id":"google:123","name":"A","email":"a@x.com","generation":"g"}"#)
        XCTAssertFalse(google.usesApple); XCTAssertNil(google.appleUserID); XCTAssertFalse(google.deletesWithApple)
    }

    func testAGoogleAccountOpenedWithAppleChecksAppleAndDeletesWithApple() throws {
        let user = try decode(#"{"id":"google:123","name":"A","email":"a@x.com","generation":"g","signedInWith":"apple:001.abc","confirmWith":"apple"}"#)
        XCTAssertTrue(user.usesApple)
        XCTAssertEqual(user.appleUserID, "001.abc", "the credential check needs the Apple user, not the account id")
        XCTAssertEqual(user.storageID, "google:123:g", "orders and saves stay under the account")
        XCTAssertTrue(user.deletesWithApple); XCTAssertEqual(user.deletionProviderName, "Apple")
    }

    func testSignedInWithGoogleOnAnAccountWithAppleStillDeletesWithApple() throws {
        let user = try decode(#"{"id":"google:123","name":"A","email":"a@x.com","generation":"g","signedInWith":"google:123","confirmWith":"apple"}"#)
        XCTAssertFalse(user.usesApple); XCTAssertEqual(user.providerName, "Google")
        XCTAssertTrue(user.deletesWithApple)
    }
}
