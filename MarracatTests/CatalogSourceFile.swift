import Foundation

/// The JSON the build makes catalog.bin from (catalog/make_compact.py). It is
/// no longer in the app (2026-10-18: the binary alone ships), so tests read
/// it from the checkout; the Simulator sees the Mac's files.
enum CatalogSourceFile {
    static var compactJSON: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Marracat/Resources/catalog-compact.json")
    }
}
