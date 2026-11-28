import XCTest
import UIKit
@testable import Marracat

/// Event tiles show the product lifted onto the event's colours, not in a
/// white box (owner, 2026-11-28).
final class LiftedProductImageTests: XCTestCase {
    func testOnlyAClearSubjectIsLifted() {
        XCTAssertFalse(SubjectLift.usable(coverage: 0), "nothing found: the white box stays")
        XCTAssertFalse(SubjectLift.usable(coverage: 0.02), "a speck isn't the product")
        XCTAssertTrue(SubjectLift.usable(coverage: 0.3))
        XCTAssertTrue(SubjectLift.usable(coverage: 0.85))
        XCTAssertFalse(SubjectLift.usable(coverage: 0.97), "nothing taken away: the photo is all subject or all scene")
    }

    func testEachPhotoKeepsItsOwnFile() {
        let a = SubjectLift.file(for: URL(string: "https://cdn.shopify.com/a.png?width=800")!)
        let b = SubjectLift.file(for: URL(string: "https://cdn.shopify.com/b.png?width=800")!)
        XCTAssertEqual(a, SubjectLift.file(for: URL(string: "https://cdn.shopify.com/a.png?width=800")!), "the same photo finds its lift again")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "png")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "LiftedPhotos")
    }

    /// A product shot on white: the lift is the product alone, cropped to it.
    /// Vision's subject model doesn't run in every simulator; there the tile
    /// keeps the white box, and this test has nothing to check.
    func testAProductOnWhiteIsCutOutAndCropped() throws {
        let size = CGSize(width: 600, height: 600)
        let photo = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }()).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 180, y: 120, width: 240, height: 360), cornerRadius: 40).fill()
        }
        guard let cut = SubjectLift.cutOut(try XCTUnwrap(photo.cgImage)) else {
            throw XCTSkip("Vision found no subject here (the simulator may not run the model)")
        }
        XCTAssertLessThan(cut.width, 600, "cropped to the product")
        XCTAssertLessThan(cut.height, 600)
        XCTAssertNotEqual(cut.alphaInfo, .none, "the background is clear")
    }
}
