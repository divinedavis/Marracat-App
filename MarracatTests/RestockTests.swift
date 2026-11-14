import XCTest
@testable import Marracat

final class RestockTests: XCTestCase {
    private func profile(_ environment: String?) -> Data {
        let ent = environment.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>Entitlements</key><dict>\(ent)</dict></dict></plist>"
        // The real file wraps the plist in CMS signature bytes.
        return Data([0x30, 0x82, 0x00, 0xff]) + Data(plist.utf8) + Data([0x00, 0xa0, 0x82])
    }

    func testReadsTheEnvironmentFromTheProvisioningProfile() {
        XCTAssertEqual(APNsEnvironment.environment(inProfile: profile("development")), "development")
        XCTAssertEqual(APNsEnvironment.environment(inProfile: profile("production")), "production")
        XCTAssertNil(APNsEnvironment.environment(inProfile: profile(nil)))
        XCTAssertNil(APNsEnvironment.environment(inProfile: Data("not a profile".utf8)))
    }

    func testAlertIdentityIncludesTheOption() {
        let whole = RestockAlert(productID: "p", variantID: nil)
        let option = RestockAlert(productID: "p", variantID: "42")
        XCTAssertNotEqual(whole.id, option.id)
        XCTAssertEqual(option, RestockAlert(productID: "p", variantID: "42"))
    }
}
