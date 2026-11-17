import XCTest
import SwiftUI
import CoreImage
@testable import Marracat

/// You › Share Marracat (owner, 2026-11-16, alternative #1): the dotted QR
/// code has to scan to the App Store page, brand mark in the middle and all.
@MainActor
final class ShareAppQRTests: XCTestCase {
    private func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    func testTheCodeIsAQRCodeForTheAppStorePage() throws {
        XCTAssertEqual(AppQR.url.absoluteString, "https://apps.apple.com/us/app/marracat/id6810905687")
        let m = try XCTUnwrap(AppQR.modules())
        let n = m.count
        XCTAssertTrue(m.allSatisfy { $0.count == n }, "square")
        XCTAssertEqual((n - 17) % 4, 0, "a QR side is 4 × version + 17 modules, got \(n)")
        // The top-left finder: a dark 7×7 ring, a light ring, a dark 3×3 centre.
        for i in 0..<7 {
            XCTAssertTrue(m[0][i] && m[6][i] && m[i][0] && m[i][6], "outer ring at \(i)")
        }
        XCTAssertFalse(m[1][1] || m[5][5], "light ring")
        XCTAssertTrue(m[2][2] && m[3][3] && m[4][4], "dark centre")
    }

    func testTheDottedCodeWithTheBrandMarkScansToTheAppStore() throws {
        let renderer = ImageRenderer(content: AppQRCode().frame(width: 400, height: 400).padding(20).background(Color.white))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(decode(image), [AppQR.url.absoluteString])
    }

    func testTheMarkLeavesMostOfTheCodeForErrorCorrection() throws {
        let n = try XCTUnwrap(AppQR.modules()).count
        let hole = AppQR.holeSide(n) * AppQR.holeSide(n)
        // Level H recovers about 30% of the code; the mark covers far less.
        XCTAssertLessThan(Double(hole) / Double(n * n), 0.08)
    }

    func testYouSearchFindsShareMarracat() {
        let titles = { (q: String) in YouSearch.matches(q, signedIn: false, social: false).map(\.title) }
        XCTAssertTrue(titles("qr").contains("Share Marracat"))
        XCTAssertTrue(titles("invite").contains("Share Marracat"))
        XCTAssertEqual(YouSearch.matches("qr code", signedIn: false, social: false).first?.target, .shareApp)
    }
}
