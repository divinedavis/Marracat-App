import XCTest
import UIKit
@testable import Marracat

/// The 3D pictures on Browse and Profile (owner, 2026-11-25: "replace with
/// images that are similar to what we use in Crease"). A picture that goes
/// missing, or is asked for by a name with a typo, quietly turns back into a
/// line icon, so the names the screens use are checked here.
final class ArtIconTests: XCTestCase {
    /// Browse's three tiles, then Profile's tiles and rows.
    private let screens = ["new", "deals", "brands",
                           "orders", "lists", "connect",
                           "share", "settings", "appearance", "help", "privacy", "shipping", "restock",
                           "notifications", "taste", "forbrands", "about", "logout", "signin",
                           "cart"]   // the empty cart
    /// Every department the catalog has today, by catalog id.
    private let departments = ["skincare", "makeup", "hair", "bags", "fragrance", "clothing", "jewelry", "accessories",
                               "home", "household", "wellness", "grocery", "baby", "pets", "toys", "sports", "books",
                               "crafts", "office", "tools", "electronics", "shoes", "luggage", "garden", "auto", "music",
                               "party", "alcohol"]

    func testEveryPictureTheScreensAskForIsInTheApp() {
        for name in screens + departments {
            XCTAssertTrue(ArtIcon.has(name), "Art/\(name) is missing: its row would fall back to a line icon")
        }
    }

    func testANameWithNoPictureFallsBackToItsSymbol() {
        XCTAssertFalse(ArtIcon.has("a-department-added-tomorrow"))
        XCTAssertFalse(ArtIcon.has(""), "a row that names no picture keeps its symbol")
    }

    /// All 28 departments are pictured (owner, 2026-11-26: "We are missing
    /// some new icons tho for the categories"); that is the first test. A
    /// department the catalog adds later has no picture until one is made,
    /// so its row must still have a symbol the system can draw.
    @MainActor func testADepartmentWithoutAPictureStillShowsItsSymbol() {
        let listed = CatalogStore(synchronously: true).categories
        XCTAssertGreaterThanOrEqual(listed.count, 20)
        for c in listed {
            XCTAssertTrue(ArtIcon.has(c.id) || UIImage(systemName: c.symbol) != nil, "\(c.name) has no picture and \(c.symbol) isn't an SF Symbol")
        }
        XCTAssertEqual(Set(listed.map(\.id)).subtracting(departments), [], "a new department needs its picture rendered (scripts in the 2026-11-25 preview folder)")
    }

    /// The biggest a picture is drawn is 48 pt (144 px at 3x): 192 px is
    /// plenty, and keeps 48 pictures to about 2 MB of the download.
    func testPicturesAreSizedForAnIconNotAPoster() throws {
        for name in screens + departments {
            let image = try XCTUnwrap(UIImage(named: "Art/\(name)"))
            XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, 192, name)
        }
    }
}
