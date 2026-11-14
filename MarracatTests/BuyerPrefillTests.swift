import Testing
@testable import Marracat

/// A signed-in shopper's checkout details start with their account's name and
/// email, so only phone and address are left to type (owner, 2026-10-03).
struct BuyerPrefillTests {
    @Test func fillsNameAndEmailFromTheAccount() {
        let d = BuyerDetails().filling(name: "Divine J Davis", email: "d@example.com")
        #expect(d.firstName == "Divine")
        #expect(d.lastName == "J Davis")
        #expect(d.email == "d@example.com")
        #expect(!d.isComplete, "phone and address are still the shopper's to type")
    }

    @Test func whatWasTypedWins() {
        var typed = BuyerDetails()
        typed.firstName = "Dee"; typed.email = "dee@example.com"
        let d = typed.filling(name: "Divine Davis", email: "d@example.com")
        #expect(d.firstName == "Dee")
        #expect(d.lastName == "Davis", "a blank is still filled")
        #expect(d.email == "dee@example.com")
    }

    @Test func noAccountOrAnUnusableEmailLeavesBlanks() {
        #expect(BuyerDetails().filling(name: nil, email: nil) == BuyerDetails())
        let d = BuyerDetails().filling(name: "  ", email: "not-an-email")
        #expect(d.firstName.isEmpty && d.lastName.isEmpty && d.email.isEmpty)
    }
}
