import Contacts
import Testing
@testable import Marracat

/// Picking an address suggestion fills the street, city, state and ZIP and
/// leaves everything else as the shopper typed it (owner, 2026-10-04).
struct AddressFillTests {
    @Test func aPickedAddressFillsTheRest() {
        var typed = BuyerDetails()
        typed.firstName = "Dee"; typed.street = "228 Gran"; typed.extended = "Apt 4"
        let d = typed.applying(FoundAddress(street: "228 Grant St", city: "Brooklyn", region: "NY", postalCode: "11205", country: "US"))
        #expect(d.street == "228 Grant St")
        #expect(d.city == "Brooklyn" && d.region == "NY" && d.postalCode == "11205")
        #expect(d.extended == "Apt 4", "Apple's suggestions carry no apartment")
        #expect(d.firstName == "Dee")
    }

    @Test func blankPartsDoNotEraseWhatWasTyped() {
        var typed = BuyerDetails()
        typed.city = "Newark"; typed.postalCode = "07102"
        let d = typed.applying(FoundAddress(street: "1 Main St", city: "", region: "NJ", postalCode: "", country: "US"))
        #expect(d.city == "Newark" && d.postalCode == "07102" && d.region == "NJ")
    }

    /// Fill from Contacts (owner, 2026-10-19): a picked card fills name,
    /// email, phone and its US home address; blanks keep what was typed.
    @Test func aContactCardFillsEverything() {
        let c = CNMutableContact()
        c.givenName = "Dee"; c.familyName = "Davis"
        c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "dee@example.com" as NSString)]
        c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(718) 555-0100"))]
        let work = CNMutablePostalAddress(); work.street = "1 Work Pl"; work.city = "Newark"; work.state = "NJ"; work.postalCode = "07102"; work.isoCountryCode = "us"
        let home = CNMutablePostalAddress(); home.street = "228 Grant St\nApt 4"; home.city = "Brooklyn"; home.state = "NY"; home.postalCode = "11205"; home.isoCountryCode = "us"
        c.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: work), CNLabeledValue(label: CNLabelHome, value: home)]
        let d = BuyerDetails().filling(contact: c)
        #expect(d.firstName == "Dee" && d.lastName == "Davis" && d.email == "dee@example.com" && d.phone == "(718) 555-0100")
        #expect(d.street == "228 Grant St" && d.extended == "Apt 4", "home address first, second line is the apartment")
        #expect(d.city == "Brooklyn" && d.region == "NY" && d.postalCode == "11205")
        #expect(d.isComplete)
    }

    @Test func aContactWithoutAUSAddressKeepsTheTypedOne() {
        var typed = BuyerDetails()
        typed.street = "1 Main St"; typed.city = "Newark"; typed.phone = "2015550100"
        let c = CNMutableContact()
        c.givenName = "Ana"
        let paris = CNMutablePostalAddress(); paris.street = "1 Rue X"; paris.city = "Paris"; paris.isoCountryCode = "fr"
        c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: paris)]
        let d = typed.filling(contact: c)
        #expect(d.firstName == "Ana")
        #expect(d.street == "1 Main St" && d.city == "Newark" && d.phone == "2015550100")
    }
}
