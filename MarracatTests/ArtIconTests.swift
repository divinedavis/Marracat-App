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
                           "notifications", "taste", "forbrands", "about", "logout"]
    /// The departments pictured so far, by catalog id.
    private let departments = ["skincare", "makeup", "hair", "bags", "fragrance", "clothing", "jewelry", "accessories",
                               "home", "household", "wellness", "grocery", "baby", "pets", "toys", "sports", "crafts"]

    func testEveryPictureTheScreensAskForIsInTheApp() {
        for name in screens + departments {
            XCTAssertTrue(ArtIcon.has(name), "Art/\(name) is missing: its row would fall back to a line icon")
        }
    }

    func testANameWithNoPictureFallsBackToItsSymbol() {
        XCTAssertFalse(ArtIcon.has("a-department-added-tomorrow"))
        XCTAssertFalse(ArtIcon.has(""), "a row that names no picture keeps its symbol")
    }

    /// Every department either has a picture or a symbol the system can draw:
    /// no row on Browse is ever blank.
    @MainActor func testEveryDepartmentShowsSomething() {
        let departments = CatalogStore(synchronously: true).categories
        XCTAssertGreaterThanOrEqual(departments.count, 20)
        for c in departments {
            XCTAssertTrue(ArtIcon.has(c.id) || UIImage(systemName: c.symbol) != nil, "\(c.name) has no picture and \(c.symbol) isn't an SF Symbol")
        }
    }

    /// The biggest a picture is drawn is 48 pt (144 px at 3x): 192 px is
    /// plenty, and keeps 35 pictures to about 1.5 MB of the download.
    func testPicturesAreSizedForAnIconNotAPoster() throws {
        for name in screens + departments {
            let image = try XCTUnwrap(UIImage(named: "Art/\(name)"))
            XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, 192, name)
        }
    }
}
