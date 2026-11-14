import XCTest
@testable import Marracat

/// The background refresh keeps a download and the charging task decodes it
/// (BackgroundRefresh, 2026-10-18).
final class BackgroundCatalogTests: XCTestCase {
    func testNothingPendingDoesNothing() {
        UserDefaults.standard.removeObject(forKey: "catalog.v3.pendingFrom")
        XCTAssertNil(CatalogStore.finishPendingDownload())
    }

    /// A kept file that doesn't decode is removed, with its ETag, so the next
    /// launch opens the catalog it had and the next refresh fetches again.
    func testABrokenPendingDownloadIsRemoved() throws {
        let url = try XCTUnwrap(CatalogStore.cacheURL)
        let saved = try? Data(contentsOf: url)
        let savedTag = UserDefaults.standard.string(forKey: "catalog.v3.etag")
        defer {
            if let saved { try? saved.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
            UserDefaults.standard.set(savedTag, forKey: "catalog.v3.etag")
        }
        try Data(#"{"generatedAt":"9999-01-01T00:00:00Z","categories":[ broken"#.utf8).write(to: url)
        UserDefaults.standard.set("\"tag\"", forKey: "catalog.v3.etag")
        UserDefaults.standard.set("2026-10-18T00:00:00Z", forKey: "catalog.v3.pendingFrom")
        XCTAssertNil(CatalogStore.finishPendingDownload())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(UserDefaults.standard.string(forKey: "catalog.v3.etag"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "catalog.v3.pendingFrom"))
    }

    func testBothTasksArePermittedInTheInfoPlist() throws {
        let ids = try XCTUnwrap(Bundle(for: CatalogStore.self).object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertEqual(Set(ids), [BackgroundRefresh.identifier, BackgroundRefresh.processingIdentifier])
        let modes = try XCTUnwrap(Bundle(for: CatalogStore.self).object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(modes.contains("processing"))
    }
}
