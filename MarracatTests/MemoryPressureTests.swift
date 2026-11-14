import XCTest
@testable import Marracat

/// A memory warning drops what rebuilds on demand, and the decoded-image
/// budget follows the device's RAM (MemoryPressure, 2026-10-18).
@MainActor
final class MemoryPressureTests: XCTestCase {
    func testTheImageBudgetFollowsTheDevicesMemory() {
        let gb: UInt64 = 1 << 30
        XCTAssertEqual(ImageLoader.costLimit(physicalMemory: 3 * gb), 96 << 20, "never under 96 MB")
        XCTAssertEqual(ImageLoader.costLimit(physicalMemory: 6 * gb), Int(6 * gb / 40))
        XCTAssertEqual(ImageLoader.costLimit(physicalMemory: 8 * gb), Int(8 * gb / 40))
        XCTAssertEqual(ImageLoader.costLimit(physicalMemory: 16 * gb), 256 << 20, "never over 256 MB")
    }

    func testSearchStillWorksAfterAMemoryWarning() {
        let catalog = CatalogStore(synchronously: true)
        let before = catalog.search("shea butter").map(\.id)
        XCTAssertFalse(before.isEmpty)
        MemoryPressure.shed(catalog: catalog)
        XCTAssertEqual(catalog.search("shea butter").map(\.id), before, "the caches rebuild to the same results")
    }
}

/// Prefetching nobody waits on stops in Low Power Mode and when the phone is
/// hot (DeviceBudget, 2026-10-18).
final class DeviceBudgetTests: XCTestCase {
    func testOptionalWorkWaitsForACoolChargedPhone() {
        XCTAssertTrue(DeviceBudget.allowsOptionalWork(lowPower: false, thermal: .nominal))
        XCTAssertTrue(DeviceBudget.allowsOptionalWork(lowPower: false, thermal: .fair))
        XCTAssertFalse(DeviceBudget.allowsOptionalWork(lowPower: false, thermal: .serious))
        XCTAssertFalse(DeviceBudget.allowsOptionalWork(lowPower: false, thermal: .critical))
        XCTAssertFalse(DeviceBudget.allowsOptionalWork(lowPower: true, thermal: .nominal))
    }
}

/// The read-ahead hint is only a hint: any Data, mapped or not, is fine.
final class CatalogReadAheadTests: XCTestCase {
    func testTheReadAheadHintTakesAnyData() throws {
        CatalogBinary.willNeed(Data())
        CatalogBinary.willNeed(Data(repeating: 7, count: 100))
        let url = try XCTUnwrap(CatalogBinary.bundledURL(Bundle(for: CatalogStore.self)))
        let mapped = try Data(contentsOf: url, options: .alwaysMapped)
        CatalogBinary.willNeed(mapped)
        XCTAssertNotNil(CatalogBinary.peekGeneratedAt(mapped), "the hint leaves the file readable")
    }
}
