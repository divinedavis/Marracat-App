import CryptoKit
import Foundation

/// Catalog updates as a delta (2026-10-18): what changed since the catalog
/// this phone holds, ~0.5 MB gzipped, instead of the whole catalog (13.9 MB
/// gzipped, every 6 hours). Written by catalog/catalog_delta.py, which
/// documents the format; signed with the catalog's key and checked the same
/// way (CatalogSignature).
///
/// A version is named by its fingerprint, the first 16 hex of the SHA-256 of
/// its catalog-v3.json bytes. The phone remembers the fingerprint of the
/// catalog in its cache: hashed when it downloads the whole file, or the
/// `to` of a delta it applied. Anything that doesn't line up (no fingerprint,
/// a delta for another version, a count or id order that doesn't match after
/// applying) falls back to the whole catalog, as before.
enum CatalogDelta {
    static let base = URL(string: "https://marracat.com/catalog-v3")!
    static var manifestsURL: URL { base.appendingPathComponent("manifests.txt") }
    static func url(from fp: String) -> URL { base.appendingPathComponent("delta-\(fp).json") }

    /// Where the background refresh keeps a delta for the charging task.
    static var pendingURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("catalog-v3.delta.json")
    }

    struct File: Decodable {
        let generatedAt: String
        let delta: Int
        let from: String
        let to: String
        let count: Int
        let ids: String
        let order: [Int]
        let categories: [Category]
        let subcategories: [Subcategory]
        let brands: [Brand]
        let products: [Product]
    }

    static func decode(_ data: Data) -> File? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        guard let f = try? d.decode(File.self, from: data), f.delta == 1 else { return nil }
        return f
    }

    static func fingerprint(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func idsDigest(_ products: [Product]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(products.count * 24)
        for (i, p) in products.enumerated() {
            if i > 0 { bytes.append(0x0A) }
            bytes.append(contentsOf: p.id.utf8)
        }
        return hex(SHA256.hash(data: bytes))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The new catalog: `base`'s products where the delta points at them, its
    /// own where they changed, in the new order. Nil unless every run is in
    /// bounds and the result has the count and id order the delta names.
    static func apply(_ d: File, to base: Catalog) -> Catalog? {
        guard d.order.count % 2 == 0 else { return nil }
        var out: [Product] = []
        out.reserveCapacity(d.count)
        var k = 0
        while k < d.order.count {
            let start = d.order[k], n = d.order[k + 1]
            k += 2
            guard n > 0 else { return nil }
            if start >= 0 {
                guard start + n <= base.products.count else { return nil }
                out.append(contentsOf: base.products[start..<(start + n)])
            } else {
                let j = -start - 1
                guard j + n <= d.products.count else { return nil }
                out.append(contentsOf: d.products[j..<(j + n)])
            }
        }
        guard out.count == d.count, idsDigest(out) == d.ids, !out.isEmpty, !d.brands.isEmpty else { return nil }
        return Catalog(generatedAt: d.generatedAt, categories: d.categories, subcategories: d.subcategories,
                       brands: d.brands, products: out)
    }

    /// `c` as the JSON the cache holds, in the shape the launch reads fastest:
    /// generatedAt first (CatalogStore.generatedAt(head:)), products last and
    /// each starting with its id (decodeInParallel's cut). Products encoded
    /// on every core.
    static func cacheJSON(_ c: Catalog) throws -> Data {
        let e = JSONEncoder()
        var out = Data(#"{"generatedAt":"#.utf8)
        out.append(try e.encode(c.generatedAt))
        for (key, part) in [("categories", try e.encode(c.categories)), ("subcategories", try e.encode(c.subcategories)),
                            ("brands", try e.encode(c.brands))] {
            out.append(Data(",\"\(key)\":".utf8)); out.append(part)
        }
        out.append(Data(#","products":["#.utf8))
        let pieces = c.products.count < 2000 ? 1 : min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8)
        var parts = [Data?](repeating: nil, count: pieces)
        parts.withUnsafeMutableBufferPointer { slot in
            DispatchQueue.concurrentPerform(iterations: pieces) { i in
                let lo = c.products.count * i / pieces, hi = c.products.count * (i + 1) / pieces
                guard lo < hi, let d = try? JSONEncoder().encode(Array(c.products[lo..<hi])) else { slot[i] = Data(); return }
                slot[i] = d.dropFirst().dropLast()   // the chunk's [ and ]
            }
        }
        var first = true
        for (i, part) in parts.enumerated() {
            let lo = c.products.count * i / pieces, hi = c.products.count * (i + 1) / pieces
            guard lo < hi else { continue }
            guard let part, !part.isEmpty else { throw CocoaError(.coderInvalidValue) }
            if !first { out.append(UInt8(ascii: ",")) }
            out.append(part); first = false
        }
        out.append(Data("]}".utf8))
        return out
    }

    // MARK: Which version this phone holds

    private static let fingerprintKey = "catalog.v3.fingerprint"   // "<generatedAt>|<fp>"

    static func remember(_ fp: String, for generatedAt: String) {
        UserDefaults.standard.set("\(generatedAt)|\(fp)", forKey: fingerprintKey)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: fingerprintKey) }

    /// The fingerprint of the catalog dated `generatedAt`, if that's the one
    /// in the cache and the cache is what the phone opens (newer than the
    /// bundle: a bundled catalog of the same date can be a different cut).
    static func fingerprint(of generatedAt: String, cached: String?, bundled: String?) -> String? {
        guard let saved = UserDefaults.standard.string(forKey: fingerprintKey) else { return nil }
        let parts = saved.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == generatedAt, cached == generatedAt,
              generatedAt > (bundled ?? ""), parts[1].count == 16 else { return nil }
        return parts[1]
    }
}
