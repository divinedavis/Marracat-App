import CryptoKit
import Foundation

/// Search's two slow indexes, kept on disk for the catalog they were built
/// from (2026-10-18). Suggestion terms took ~5 s on one core and the word
/// index ~1 s across all of them (Debug, 154k products), after every launch,
/// to produce the same 9.7k terms and 55k words as the launch before. Now a
/// launch reads them back in milliseconds and builds only when the catalog or
/// the app build changed; the charging task builds them for a downloaded
/// catalog before the shopper opens it (BackgroundRefresh).
///
/// One file, replaced as a whole:
///   "MRS1" u32 version | u32 key length, key | u32 terms length, terms (JSON)
///   | u32 words, u32 blob length, the words joined by "\n"
///   | u32 per word: its postings count | i32 postings, all words in order
/// A file whose key isn't this catalog's, or that doesn't check out, is
/// ignored and the indexes are built as before.
enum SearchCache {
    private static let magic: UInt32 = 0x4D52_5331   // "MRS1"
    private static let version: UInt32 = 1

    struct Indexes {
        let terms: [SuggestionTerm]
        let words: CatalogStore.SearchWordIndex
    }

    static var url: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("search-v1.bin")
    }

    /// Which catalog, and which build of the code that indexes it: two
    /// catalogs can share a generatedAt (the bundled one and a download of the
    /// same feed), so the products' ids are hashed in too, and a new build
    /// rebuilds once in case the indexing itself changed.
    static func key(_ c: Catalog, build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") -> String {
        // One buffer, hashed once: an update per id cost more than the hashing.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(c.products.count * 24)
        for p in c.products { bytes.append(contentsOf: p.id.utf8); bytes.append(0) }
        let ids = SHA256.hash(data: bytes).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(c.generatedAt)|\(c.products.count)|\(c.brands.count)|\(c.categories.count)|\(c.subcategories.count)|\(ids)|\(build)"
    }

    /// Both indexes for `c`, the way the launch builds them.
    static func build(_ c: Catalog) -> Indexes {
        var byCategory: [String: [Int32]] = [:]
        for (i, p) in c.products.enumerated() { byCategory[p.category, default: []].append(Int32(i)) }
        var terms: [SuggestionTerm] = [], words: CatalogStore.SearchWordIndex?
        DispatchQueue.concurrentPerform(iterations: 2) { job in
            if job == 0 { terms = CatalogStore.buildSuggestionTerms(c, byCategory: byCategory) }
            else { words = CatalogStore.SearchWordIndex.build(c) }
        }
        return Indexes(terms: terms, words: words!)
    }

    static func save(_ ix: Indexes, key: String, to url: URL? = url) {
        guard let url, let terms = try? JSONEncoder().encode(ix.terms) else { return }
        var out = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func blob(_ d: Data) { u32(UInt32(d.count)); out.append(d) }
        u32(magic); u32(version)
        blob(Data(key.utf8))
        blob(terms)
        u32(UInt32(ix.words.words.count))
        blob(Data(ix.words.words.joined(separator: "\n").utf8))
        let total = ix.words.postings.reduce(0) { $0 + $1.count }
        out.reserveCapacity(out.count + ix.words.postings.count * 4 + total * 4)
        for p in ix.words.postings { u32(UInt32(p.count)) }
        for p in ix.words.postings { p.withUnsafeBufferPointer { out.append(Data(buffer: $0)) } }   // little-endian on every iPhone
        try? out.write(to: url, options: .atomic)
    }

    /// The indexes for the catalog `key` names, or nil. `products` bounds
    /// every posting, so a file that somehow names the wrong catalog can't
    /// point search past the end of this one.
    static func load(key: String, generatedAt: String, products: Int, from url: URL? = url) -> Indexes? {
        guard let url, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> Indexes? in
            var at = 0
            func u32() -> UInt32? {
                guard at + 4 <= raw.count else { return nil }
                defer { at += 4 }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            }
            func blob() -> Data? {
                guard let n = u32().map(Int.init), at + n <= raw.count else { return nil }
                defer { at += n }
                return Data(raw[at..<(at + n)])
            }
            guard u32() == magic, u32() == version,
                  let k = blob(), String(decoding: k, as: UTF8.self) == key,
                  let termData = blob(), let terms = try? JSONDecoder().decode([SuggestionTerm].self, from: termData),
                  let count = u32().map(Int.init), let wordData = blob() else { return nil }
            let words = wordData.isEmpty ? [] : String(decoding: wordData, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard words.count == count, at + count * 4 <= raw.count else { return nil }
            var counts: [Int] = []
            counts.reserveCapacity(count)
            for _ in 0..<count { counts.append(Int(u32()!)) }
            guard at + counts.reduce(0, +) * 4 == raw.count else { return nil }
            var postings: [[Int32]] = []
            postings.reserveCapacity(count)
            let limit = Int32(clamping: products)
            for n in counts {
                // Written little-endian, which every iPhone is: a plain copy.
                let list = [Int32](unsafeUninitializedCapacity: n) { buf, made in
                    UnsafeMutableRawBufferPointer(buf).copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[at..<(at + n * 4)]))
                    made = n
                }
                at += n * 4
                guard list.allSatisfy({ $0 >= 0 && $0 < limit }) else { return nil }
                postings.append(list)
            }
            return Indexes(terms: terms, words: .init(generatedAt: generatedAt, words: words, postings: postings))
        }
    }
}

