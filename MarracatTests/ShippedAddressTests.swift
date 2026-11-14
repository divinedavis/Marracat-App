import Testing
@testable import Marracat

/// The address a store's checkout shipped to is saved for the next brand,
/// so it's entered once, at the first checkout, where Shop Pay or Apple Pay
/// fill it (owner, 2026-11-02, from a creator who typed it twice).
struct ShippedAddressTests {
    private let shipped = OrderAddress(firstName: "Kaila", lastName: "Price", address1: "350 5th Ave", address2: "Apt 4",
                                       city: "New York", zoneCode: "NY", postalCode: "10118", countryCode: "US", phone: "+17185550100")

    @Test func firstOrderSavesWhereItShipped() {
        let d = BuyerDetails().filling(shippedTo: shipped, orderEmail: "kaila@example.com", orderPhone: nil)
        #expect(d.street == "350 5th Ave" && d.extended == "Apt 4" && d.city == "New York")
        #expect(d.region == "NY" && d.postalCode == "10118" && d.country == "US")
        #expect(d.firstName == "Kaila" && d.lastName == "Price")
        #expect(d.phone == "+17185550100")
        #expect(d.email == "kaila@example.com")
        #expect(d.isComplete && d.hasAddress)
    }

    @Test func savedCompleteDetailsStayPut() {
        let mine = BuyerDetails(firstName: "A", lastName: "B", email: "a@b.co", phone: "7185550100",
                                street: "1 Main St", city: "Brooklyn", region: "NY", postalCode: "11201")
        #expect(mine.filling(shippedTo: shipped, orderEmail: "x@y.co", orderPhone: nil) == mine, "a gift sent elsewhere doesn't move it")
    }

    @Test func accountDetailsWinAndTheOrderAddressIsNeverSaved() {
        let account = BuyerDetails().filling(name: "Divine Davis", email: "d@example.com")
        let d = account.filling(shippedTo: shipped, orderEmail: "u-abc@orders.marracat.com", orderPhone: nil)
        #expect(d.firstName == "Divine" && d.email == "d@example.com")
        #expect(d.street == "350 5th Ave")
        let guest = BuyerDetails().filling(shippedTo: shipped, orderEmail: "U-ABC@orders.marracat.com", orderPhone: nil)
        #expect(guest.email.isEmpty, "Marracat's own order address isn't the shopper's email")
    }

    @Test func outsideTheUSOrNoAddressSavesNoAddress() {
        var abroad = shipped; abroad.countryCode = "CA"
        #expect(!BuyerDetails().filling(shippedTo: abroad, orderEmail: nil, orderPhone: nil).hasAddress)
        #expect(!BuyerDetails().filling(shippedTo: nil, orderEmail: nil, orderPhone: "7185550100").hasAddress)
        var noStreet = shipped; noStreet.address1 = nil
        #expect(!BuyerDetails().filling(shippedTo: noStreet, orderEmail: nil, orderPhone: nil).hasAddress)
    }

    @Test func aFullNameSplitsWhenTheFirstAndLastArentGiven() {
        var named = shipped; named.firstName = nil; named.lastName = nil; named.name = "Kaila Greatness Price"
        let d = BuyerDetails().filling(shippedTo: named, orderEmail: nil, orderPhone: nil)
        #expect(d.firstName == "Kaila" && d.lastName == "Greatness Price")
    }
}
