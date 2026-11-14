import XCTest
@testable import Marracat

@MainActor
final class SavedListsTests: XCTestCase {
    private func store() -> ShopperStore { ShopperStore(defaults: UserDefaults(suiteName: "SavedListsTests.\(UUID())")!) }

    /// 2026-10-13: build 135's unit-test run showed up on marracat.com as one
    /// visitor making 52 lists in a second. Tests must never post analytics,
    /// and only a list the shopper makes counts as list_create: lists arriving
    /// from a sync never do.
    func testOnlyAShopperMadeListLogsAndTestsNeverPost() async throws {
        XCTAssertFalse(Analytics.sendsToServer, "unit tests run in the app; they must not post to marracat.com")
        try XCTSkipUnless(Analytics.shared.isEnabled, "usage analytics switched off on this simulator")
        let creates = { Analytics.shared.queue.filter { $0.name == "list_create" }.count }
        for _ in 0..<5 { await Task.yield() }
        let before = creates()
        let s = store()
        s.activate("acct-1")
        let synced = (0..<3).map { SavedList(id: "l\($0)", name: "Synced \($0)") }
        s.accept(ShopperProfile(lists: synced))
        s.accept(ShopperProfile(lists: synced))
        XCTAssertEqual(s.lists.count, 3)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(creates(), before, "lists loaded from the account aren't new lists")
        _ = try XCTUnwrap(s.createList(named: "Gifts"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(creates(), before + 1)
    }

    func testFoldersHoldSavedItemsAndTheirCover() throws {
        let s = store()
        let id = try XCTUnwrap(s.createList(named: "  Gifts  "))
        XCTAssertEqual(s.list(id)?.name, "Gifts")
        s.add("p1", to: id)
        s.add("p2", to: id)
        XCTAssertTrue(s.isSaved("p1"), "adding to a folder saves the item")
        XCTAssertEqual(s.list(id)?.items, ["p2", "p1"])
        s.setCover("p2", for: id)
        XCTAssertEqual(s.list(id)?.cover, "p2")
        s.setCover("not-there", for: id)
        XCTAssertEqual(s.list(id)?.cover, "p2", "a cover must be in the folder")
        s.remove("p2", from: id)
        XCTAssertEqual(s.list(id)?.items, ["p1"])
        XCTAssertNil(s.list(id)?.cover, "removing the cover item clears the cover")
        XCTAssertTrue(s.isSaved("p2"), "removing from a folder keeps the item saved")
        s.toggleSaved("p1")
        XCTAssertEqual(s.list(id)?.items, [], "unsaving takes the item out of every folder")
        s.renameList(id, to: "Holiday gifts")
        XCTAssertEqual(s.list(id)?.name, "Holiday gifts")
        s.deleteList(id)
        XCTAssertNil(s.list(id))
    }

    func testBlankNamesAndTheLimitAreRefused() {
        let s = store()
        XCTAssertNil(s.createList(named: "   "))
        for i in 0..<ShopperStore.maxLists { _ = s.createList(named: "List \(i)") }
        XCTAssertEqual(s.lists.count, ShopperStore.maxLists)
        XCTAssertNil(s.createList(named: "One too many"))
    }

    func testProfilesFromBeforeFoldersStillDecode() throws {
        let old = #"{"saved":["a"],"recentlyViewed":[],"recentSearches":[],"checkouts":[],"hidden":[],"personalizationEnabled":true}"#
        let p = try JSONDecoder().decode(ShopperProfile.self, from: Data(old.utf8))
        XCTAssertEqual(p.saved, ["a"])
        XCTAssertEqual(p.lists, [])
    }

    func testFoldersSurviveARemoteProfileWithPendingChanges() throws {
        let s = store()
        s.activate("acct:1")
        let id = try XCTUnwrap(s.createList(named: "Gifts"))
        s.add("p1", to: id)
        // The server answers with a profile from before these changes; they replay on top.
        s.accept(ShopperProfile())
        XCTAssertEqual(s.list(id)?.items, ["p1"])
        XCTAssertTrue(s.isSaved("p1"))
    }

    /// 2026-11-12: a folder's id comes back from the synced profile and named
    /// its cover picture's file as it was, so "../../x" left the covers folder.
    func testACoverPictureAlwaysLandsInTheCoversFolder() {
        let uuid = UUID().uuidString.lowercased()
        XCTAssertEqual(CoverPhotos.fileName(uuid), uuid + ".jpg", "the app's own ids are kept")
        XCTAssertEqual(CoverPhotos.fileName("gifts_2026-A"), "gifts_2026-A.jpg")
        let covers = CoverPhotos.url(uuid).deletingLastPathComponent().standardizedFileURL.path
        for id in ["../../Library/Preferences/x", "..", "a/b", "/etc/passwd", "", "naïve", String(repeating: "a", count: 81), "a b", "x.jpg/../y"] {
            let name = CoverPhotos.fileName(id)
            XCTAssertNotNil(name.range(of: "^[0-9a-f]{64}\\.jpg$", options: .regularExpression), "\(id) → \(name)")
            XCTAssertEqual(CoverPhotos.url(id).standardizedFileURL.deletingLastPathComponent().path, covers, id)
        }
        XCTAssertNotEqual(CoverPhotos.fileName("a/b"), CoverPhotos.fileName("a/c"), "different folders, different files")
        let id = "../escape-\(UUID().uuidString)"
        CoverPhotos.save(Data([0xFF, 0xD8, 0xFF]), for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CoverPhotos.url(id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: covers).appendingPathComponent(id + ".jpg").standardizedFileURL.path))
        CoverPhotos.remove(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CoverPhotos.url(id).path))
    }
}
