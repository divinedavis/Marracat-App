import Foundation
import Testing
@testable import Marracat

/// Where a sign-in stopped (owner, 2026-11-08: 6 started, 2 finished).
/// AccountStore.stopEvent; the names match web/server/events.js.
@MainActor
struct SignInStepTests {
    struct Boom: Error {}

    @Test func closingTheProvidersSheetIsACancel() {
        let e = AccountStore.stopEvent(step: .provider, error: Boom(), cancelled: true)
        #expect(e.name == "sign_in_cancel" && e.reason == nil)
    }

    @Test func failuresSayWhy() {
        #expect(AccountStore.stopEvent(step: .exchange, error: URLError(.notConnectedToInternet), cancelled: false) == ("sign_in_fail", "network"))
        #expect(AccountStore.stopEvent(step: .exchange, error: Boom(), cancelled: false) == ("sign_in_fail", "server"))
        #expect(AccountStore.stopEvent(step: .challenge, error: Boom(), cancelled: false) == ("sign_in_fail", "server"))
        #expect(AccountStore.stopEvent(step: .provider, error: Boom(), cancelled: false) == ("sign_in_fail", "error"))
    }

    @Test func stepNamesMatchTheServer() {
        #expect([AccountStore.SignInStep.challenge, .provider, .exchange].map(\.rawValue) == ["challenge", "provider", "exchange"])
    }
}
