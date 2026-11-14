import Foundation
import Testing
@testable import Marracat

/// The product page names its options as the store does (owner, 2026-10-16:
/// "Option: Black" on YEEZY's SK 01 read as a missing size).
struct OptionLabelTests {
    @Test func namesFollowTheVariantTitle() {
        #expect(ProductDetailView.optionLabel(["Color"]) == "Color: ")
        #expect(ProductDetailView.optionLabel(["Color", "Size"]) == "Color / Size: ")
    }

    @Test func noNamesKeepsOption() {
        #expect(ProductDetailView.optionLabel(nil) == "Option: ")
        #expect(ProductDetailView.optionLabel([" "]) == "Option: ")
    }

    @Test func detailsDecodeTheStoresNames() throws {
        let json = #"{"description":"x","images":[],"variants":[],"option_names":["Color","Size"]}"#
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try d.decode(ProductDetail.self, from: Data(json.utf8)).optionNames == ["Color", "Size"])
        #expect(try d.decode(ProductDetail.self, from: Data(#"{"variants":[]}"#.utf8)).optionNames == nil)
    }
}
