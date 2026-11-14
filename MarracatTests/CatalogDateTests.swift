import XCTest
@testable import Marracat

/// The published catalog, stubbed: same ETag every time, a body we choose.
private final class CatalogOrigin: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var sentTags: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let sent = request.value(forHTTPHeaderField: "If-None-Match")
        Self.sentTags.append(sent)
        let status = sent == "\"v1\"" ? 304 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["ETag": "\"v1\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Launch picks the newer of the bundled and downloaded catalogs by reading
/// each file's `generated_at` from its first bytes, instead of decoding both.
final class CatalogDateTests: XCTestCase {
    private func file(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsTheDateFromTheFirstKey() throws {
        let url = try file(#"{"generated_at":"2026-09-25T22:07:31Z","categories":[{"id":"bags","name":"Bags"}]}"#)
        XCTAssertEqual(CatalogStore.generatedAt(url), "2026-09-25T22:07:31Z")
        XCTAssertEqual(CatalogStore.generatedAt(try file("{ \"generated_at\" : \"2026-01-02T00:00:00Z\" }")), "2026-01-02T00:00:00Z")
        // The bundle is written in the app's own key spelling.
        XCTAssertEqual(CatalogStore.generatedAt(try file(#"{"generatedAt":"2026-09-27T19:43:27Z","categories":[]}"#)), "2026-09-27T19:43:27Z")
    }

    func testAnythingElseFallsBackToAFullDecode() throws {
        XCTAssertNil(CatalogStore.generatedAt(try file(#"{"categories":[],"generated_at":"2026-09-25T22:07:31Z"}"#)))
        XCTAssertNil(CatalogStore.generatedAt(try file("{ not a catalog")))
        XCTAssertNil(CatalogStore.generatedAt(try file(#"{"generated_at":""}"#)))
        XCTAssertNil(CatalogStore.generatedAt(URL(fileURLWithPath: "/nonexistent/catalog.json")))
    }

    /// The catalog's JSON opens with its date (a download is read the same
    /// way), so launch takes the fast path.
    func testTheCatalogJSONOpensWithItsDate() throws {
        XCTAssertNotNil(CatalogStore.generatedAt(CatalogSourceFile.compactJSON))
    }

    /// The app ships the binary alone (2026-10-18) and dates the bundled
    /// catalog from its header, so a cached download is still compared with it.
    func testTheAppShipsTheBinaryAndNoJSON() throws {
        let bundle = Bundle(for: CatalogStore.self)
        XCTAssertNil(bundle.url(forResource: "catalog-compact", withExtension: "json"), "the 105 MB JSON is back in the app")
        XCTAssertNil(bundle.url(forResource: "catalog", withExtension: "json"))
        let bin = try XCTUnwrap(CatalogBinary.bundledURL(bundle))
        let date = try XCTUnwrap(CatalogBinary.peekGeneratedAt(Data(contentsOf: bin, options: .alwaysMapped)))
        XCTAssertGreaterThanOrEqual(CatalogStore.onDiskGeneratedAt(bundle), date)
        XCTAssertEqual(CatalogStore.generatedAt(CatalogSourceFile.compactJSON), date, "catalog.bin is of another catalog than its JSON")
    }

    /// A published catalog no newer than ours is recognised from its first
    /// key and its ETag kept, so the next launch gets a 304 instead of
    /// downloading and decoding 67 MB again. Before 2026-09-28 the ETag was
    /// only kept for a newer catalog, and every launch re-fetched the same one.
    @MainActor
    func testSameCatalogIsNotDownloadedTwice() async throws {
        let key = "catalog.v3.etag"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        // This is the whole-file path: no remembered version, so no delta check
        // (a simulator that downloaded a catalog earlier has one).
        CatalogDelta.forget()

        let store = CatalogStore(synchronously: true)
        // Our own date, then junk: decoding this would fail, so a kept ETag
        // proves the check never decoded it.
        CatalogOrigin.body = Data((#"{"generated_at":"\#(store.catalog.generatedAt)","categories":[ junk"#).utf8)
        CatalogOrigin.sentTags = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogOrigin.self]
        let session = URLSession(configuration: config)

        await store.refreshFromRemote(session: session)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "\"v1\"")
        await store.refreshFromRemote(session: session)
        XCTAssertEqual(CatalogOrigin.sentTags, [nil, "\"v1\""], "the second launch should ask with the ETag")
        XCTAssertFalse(store.catalog.products.isEmpty)
    }

    /// Back in the foreground (2026-10-18): asked again after 30 minutes,
    /// not before, and never ahead of the launch's own check.
    @MainActor
    func testForegroundAsksAgainOnlyAfterThirtyMinutes() async throws {
        let key = "catalog.v3.etag"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        CatalogDelta.forget()

        let store = CatalogStore(synchronously: true)
        CatalogOrigin.body = Data((#"{"generated_at":"\#(store.catalog.generatedAt)","categories":[ junk"#).utf8)
        CatalogOrigin.sentTags = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogOrigin.self]
        let session = URLSession(configuration: config)

        await store.refreshIfStale(now: .now.addingTimeInterval(3600), session: session)
        XCTAssertEqual(CatalogOrigin.sentTags.count, 0, "the launch's check comes first")
        await store.refreshFromRemote(session: session)
        XCTAssertEqual(CatalogOrigin.sentTags.count, 1)
        await store.refreshIfStale(now: .now.addingTimeInterval(10 * 60), session: session)
        XCTAssertEqual(CatalogOrigin.sentTags.count, 1, "not again within 30 minutes")
        await store.refreshIfStale(now: .now.addingTimeInterval(31 * 60), session: session)
        XCTAssertEqual(CatalogOrigin.sentTags.count, 2, "again after 30 minutes")
    }
}
