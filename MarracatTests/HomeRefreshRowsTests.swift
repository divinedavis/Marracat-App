import XCTest
@testable import Marracat

/// Pull to refresh brings every row on Home back with other products (owner,
/// 2026-11-28: "the refresh should refresh all products on the home page").
/// "Shop by style" stayed as it was.
final class HomeRefreshRowsTests: XCTestCase {
    private let boards: [(style: ShopStyle, products: [Int])] = Array(ShopStyle.all.prefix(3)).map { (style: $0, products: Array(0..<48)) }

    func testFirstLookIsUnchanged() {
        let shown = ShopByStyleRow.arrange(boards, round: 0)
        XCTAssertEqual(shown.map(\.style.id), boards.map(\.style.id))
        XCTAssertEqual(shown[0].products.prefix(6), [0, 1, 2, 3, 4, 5])
    }

    func testEachRefreshLeadsWithTheNextBoardAndNewPhotos() {
        let shown = ShopByStyleRow.arrange(boards, round: 1)
        XCTAssertEqual(shown.first?.style.id, boards[1].style.id, "the next board leads")
        XCTAssertEqual(Set(shown.map(\.style.id)), Set(boards.map(\.style.id)), "no board lost")
        XCTAssertEqual(shown[0].products.prefix(6), [6, 7, 8, 9, 10, 11], "the collage's six photos are new")
        XCTAssertEqual(shown[0].products.count, 48)
    }

    /// A board saved last session keeps only its six: a refresh can't empty it.
    func testASavedSixPhotoBoardStillShowsSix() {
        let saved: [(style: ShopStyle, products: [Int])] = [(style: ShopStyle.all[0], products: Array(0..<6))]
        XCTAssertEqual(ShopByStyleRow.arrange(saved, round: 3)[0].products.count, 6)
    }
}
