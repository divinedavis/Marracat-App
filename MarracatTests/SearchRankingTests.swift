import XCTest
@testable import Marracat

/// A search whose matches all come from one brand still leads with its best
/// match, as the website's search does (owner, 2026-10-31: "make sure both
/// search works the same").
final class SearchRankingTests: XCTestCase {
    private func item(_ id: String, _ title: String) -> Product {
        Product(id: id, brand: "b", title: title, category: "clothing", productType: nil, subs: [],
                price: 20, compareAt: nil, images: [], url: "u", available: true, variants: [],
                tags: [], description: nil, publishedAt: nil, bestRank: nil)
    }

    func testOneBrandsMatchesKeepTheirRanking() {
        let ranked = [(item("classic", "Classic Top"), 7), (item("womens", "Womens Pink Top"), 21), (item("pink", "Pink Top"), 19)]
        XCTAssertEqual(CatalogStore.interleaveBrands(ranked, seed: 1).map(\.id), ["womens", "pink", "classic"])
    }

    func testEqualScoresKeepCatalogOrder() {
        let ranked = [(item("x", "X"), 0), (item("y", "Y"), 0), (item("z", "Z"), 0)]
        XCTAssertEqual(CatalogStore.interleaveBrands(ranked, seed: 1).map(\.id), ["x", "y", "z"])
    }

    private func item(_ id: String, brand: String) -> Product {
        Product(id: id, brand: brand, title: id, category: "clothing", productType: nil, subs: [],
                price: 20, compareAt: nil, images: [], url: "u", available: true, variants: [],
                tags: [], description: nil, publishedAt: nil, bestRank: nil)
    }

    /// Spreading results across brands was rewritten on arrays of numbers
    /// (2026-11-20: "candle", 17,000 matches, spent 2.7 s here in the
    /// simulator, looking brands up by name at every slot). The order must be
    /// the one the name-keyed method made, kept below as it was.
    func testSpreadingBrandsGivesTheOrderItAlwaysDid() {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<60 {
            let brands = Int.random(in: 2...40, using: &rng), count = Int.random(in: 2...400, using: &rng)
            // Few distinct scores, so ties are the rule; a couple of brands hold most of it.
            let ranked: [(Product, Int)] = (0..<count).map { i in
                let brand = Bool.random(using: &rng) ? Int.random(in: 0..<2, using: &rng) : Int.random(in: 0..<brands, using: &rng)
                return (item("p\(Int.random(in: 0..<100_000, using: &rng))-\(i)", brand: "brand\(brand)"), Int.random(in: 0...4, using: &rng))
            }
            XCTAssertEqual(CatalogStore.interleaveBrands(ranked, seed: round).map(\.id), Self.spreadByName(ranked, seed: round).map(\.id),
                           "round \(round): \(count) products, \(brands) brands")
        }
    }

    /// `CatalogStore.interleaveBrands` as it was before 2026-11-20.
    private static func spreadByName(_ ranked: [(Product, Int)], seed s: Int) -> [Product] {
        var brandHash: [String: UInt64] = [:]
        for (p, _) in ranked where brandHash[p.brand] == nil { brandHash[p.brand] = CatalogStore.hash(p.brand, seed: s) }
        var buckets: [String: [(Product, Int)]] = [:]
        for item in ranked.sorted(by: { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            let (ha, hb) = (brandHash[a.0.brand]!, brandHash[b.0.brand]!)
            return ha != hb ? ha < hb : a.0.id < b.0.id
        }) {
            buckets[item.0.brand, default: []].append(item)
        }
        var head: [String: Int] = buckets.mapValues { _ in 0 }
        func pick(skipping recent: [String]) -> String? {
            var best: String?
            var bestScore = Int.min, bestHash = UInt64.max
            for (b, i) in head where !recent.contains(b) {
                let score = buckets[b]![i].1, h = brandHash[b]!
                if best == nil || score > bestScore || (score == bestScore && h < bestHash) {
                    (best, bestScore, bestHash) = (b, score, h)
                }
            }
            return best
        }
        var out: [Product] = []
        var recent: [String] = []
        func nextScore(_ brand: String) -> Int { buckets[brand]![head[brand]!].1 }
        while !head.isEmpty {
            guard let spread = pick(skipping: recent) ?? pick(skipping: []) else { break }
            let best = pick(skipping: []) ?? spread
            let b = nextScore(best) > nextScore(spread) ? best : spread
            let i = head[b]!
            out.append(buckets[b]![i].0)
            if i + 1 == buckets[b]!.count { head[b] = nil } else { head[b] = i + 1 }
            recent.append(b)
            if recent.count > 2 { recent.removeFirst() }
        }
        return out
    }

    /// Home's "Inspired by your likes" row keeps the best 180 scored products
    /// without sorting them all (2026-11-20): the same 180, in the same
    /// order, however the work is split.
    func testTheBestFewMatchSortingThemAll() {
        var rng = SystemRandomNumberGenerator()
        for round in 0..<20 {
            let count = Int.random(in: 1...3000, using: &rng), limit = [1, 7, 180].randomElement(using: &rng)!
            // Scores from a handful of values, some candidates out, some ids repeated.
            let scores: [Double?] = (0..<count).map { _ in Int.random(in: 0..<5, using: &rng) == 0 ? nil : Double(Int.random(in: 1...6, using: &rng)) / 2 }
            let ids = (0..<count).map { _ in "id\(Int.random(in: 0..<(count * 2), using: &rng))" }
            let sorted = (0..<count).filter { scores[$0] != nil }
                .sorted { a, b in scores[a]! == scores[b]! ? ids[a] < ids[b] : scores[a]! > scores[b]! }
                .prefix(limit)
            for slices in [1, 3, 8] {
                let best = CatalogStore.best(limit, of: count, slices: slices, score: { scores[$0] }, id: { ids[$0] })
                XCTAssertEqual(best, Array(sorted), "round \(round): \(count) candidates, best \(limit), \(slices) slices")
            }
        }
        XCTAssertEqual(CatalogStore.best(5, of: 0, slices: 4, score: { _ in 1 }, id: { _ in "" }), [])
    }

    /// Searches run ahead on a background thread answer as `search` does.
    @MainActor
    func testSearchesWarmedOffTheMainThreadAreTheSameResults() async {
        let warmed = ParallelSearchTests.catalog
        let queries = ["candle", "gold necklace"]
        let expected = queries.map { warmed.search($0).map(\.id) }
        XCTAssertFalse(expected[0].isEmpty)
        // Forgotten, so the warm-up has them to run.
        warmed.shed()
        await warmed.warmSearches(queries)
        XCTAssertEqual(queries.map { warmed.search($0).map(\.id) }, expected)
        // Acted-on searches lead, as `forYou` tries them.
        var memory = SearchMemory()
        memory.searched("candle"); memory.searched("shea butter")
        memory.lastQuery = "candle"; memory.lastAt = .now; memory.noteAction()
        XCTAssertEqual(CatalogStore.searchRowQueries(["shea butter", "candle"], memory: memory), ["candle", "shea butter"])
    }
}
