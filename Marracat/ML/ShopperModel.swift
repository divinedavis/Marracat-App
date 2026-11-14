import Foundation

// What the app learns about a shopper beyond the one taste point, all on the
// iPhone and cleared with the taste (owner, 2026-11-08, after the research
// read-out: "1: lets do it ... 3: lets do the price comfort 4: lets remember
// the sizes 5: lets do it 6: lets do it 7: lets do it"):
//
// 1. Several interests instead of one average (TasteMath.interests): a
//    shopper into hair care and sneakers isn't shown the products halfway
//    between them.
// 3. Price comfort per department (PriceComfort).
// 4. The sizes they pick (SizeMemory).
// 6. What pushes away: hidden products, styles marked "Not me", interests
//    muted, and a steady Women or Men choice (GenderLean).
// 5 (the "Your taste" screen) and 7 (the "Something new to try" row) read these.

/// One cluster of what a shopper touches: its direction in the meaning space,
/// its share of the taste's weight, and the products in it, heaviest first.
struct TasteInterest: Equatable {
    var vector: [Float]
    var share: Float
    var products: [String]
}

enum TasteMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    static func normalized(_ x: [Float]) -> [Float] {
        let n = x.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? x.map { $0 / n } : x
    }

    /// Up to `maxK` interests from weighted unit vectors (spherical k-means,
    /// seeded deterministically: the heaviest item, then each time the item
    /// least like the seeds so far). Interests closer than `mergeAbove` merge,
    /// and one holding under `minShare` of the weight folds into its nearest,
    /// so a single stray glance never becomes an interest.
    static func interests(_ items: [(id: String, vector: [Float], weight: Float)], maxK: Int = 3,
                          minShare: Float = 0.15, mergeAbove: Float = 0.82) -> [TasteInterest] {
        let items = items.filter { $0.weight > 0 && !$0.vector.isEmpty }
        guard !items.isEmpty else { return [] }
        let total = items.reduce(0) { $0 + $1.weight }
        var seeds = [items.max { $0.weight < $1.weight }!.vector]
        while seeds.count < min(maxK, items.count) {
            let far = items.min { a, b in
                seeds.map { dot($0, a.vector) }.max()! < seeds.map { dot($0, b.vector) }.max()!
            }!
            if seeds.map({ dot($0, far.vector) }).max()! > mergeAbove { break }
            seeds.append(far.vector)
        }
        var centroids = seeds
        var assign = [Int](repeating: 0, count: items.count)
        func reassign() {
            for (i, item) in items.enumerated() {
                assign[i] = centroids.indices.max { dot(centroids[$0], item.vector) < dot(centroids[$1], item.vector) }!
            }
        }
        func recompute() {
            centroids = centroids.indices.map { c in
                var sum = [Float](repeating: 0, count: items[0].vector.count)
                for (i, item) in items.enumerated() where assign[i] == c {
                    for j in sum.indices { sum[j] += item.weight * item.vector[j] }
                }
                return normalized(sum)
            }
        }
        for _ in 0..<8 { reassign(); recompute() }
        // Fold small or near-duplicate interests into their nearest neighbour.
        while centroids.count > 1 {
            let weights = centroids.indices.map { c in items.indices.filter { assign[$0] == c }.reduce(Float(0)) { $0 + items[$1].weight } }
            var victim: Int?
            if let small = weights.indices.min(by: { weights[$0] < weights[$1] }), weights[small] / total < minShare { victim = small }
            if victim == nil {
                outer: for a in centroids.indices { for b in centroids.indices where b > a && dot(centroids[a], centroids[b]) > mergeAbove {
                    victim = weights[a] < weights[b] ? a : b; break outer
                } }
            }
            guard let v = victim else { break }
            centroids.remove(at: v)
            reassign(); recompute()
        }
        return centroids.indices.map { c in
            let members = items.indices.filter { assign[$0] == c }.sorted { items[$0].weight > items[$1].weight }
            return TasteInterest(vector: centroids[c], share: members.reduce(0) { $0 + items[$1].weight } / total,
                                 products: members.map { items[$0].id })
        }
        .filter { !$0.products.isEmpty }
        .sorted { $0.share > $1.share }
    }

    /// How many of `limit` slots each interest gets: by share, at least two
    /// each, largest first.
    static func slots(_ shares: [Float], limit: Int) -> [Int] {
        guard !shares.isEmpty, limit > 0 else { return [] }
        var out = shares.map { max(2, Int(($0 * Float(limit)).rounded())) }
        while out.reduce(0, +) > limit, let i = out.indices.filter({ out[$0] > 2 }).max(by: { out[$0] < out[$1] }) { out[i] -= 1 }
        return out
    }

    /// Lists taken in turn, each up to its slot count, without repeats.
    static func interleave(_ lists: [[String]], slots: [Int]) -> [String] {
        var out: [String] = [], seen = Set<String>(), next = [Int](repeating: 0, count: lists.count), taken = next
        var progress = true
        while progress {
            progress = false
            for i in lists.indices where taken[i] < (i < slots.count ? slots[i] : 0) {
                while next[i] < lists[i].count, seen.contains(lists[i][next[i]]) { next[i] += 1 }
                guard next[i] < lists[i].count else { continue }
                out.append(lists[i][next[i]]); seen.insert(lists[i][next[i]])
                next[i] += 1; taken[i] += 1; progress = true
            }
        }
        return out
    }
}

// MARK: - Price comfort

/// The price range a shopper actually looks at, saves and buys in each
/// department, in dollars. Products well above it go behind the ones inside it
/// in their picks; nothing is removed. Prices people pay vary by department
/// more than by person, so each department learns on its own.
struct PriceComfort: Equatable {
    var bands: [String: ClosedRange<Double>]

    static let minimumProducts = 4

    /// From (department, dollar price, weight) per product touched.
    static func learn(_ touched: [(category: String, usd: Double, weight: Float)]) -> PriceComfort {
        var bands: [String: ClosedRange<Double>] = [:]
        for (category, rows) in Dictionary(grouping: touched.filter { $0.usd > 0 && $0.weight > 0 }, by: \.category)
        where rows.count >= minimumProducts {
            let sorted = rows.sorted { $0.usd < $1.usd }
            let total = sorted.reduce(0) { $0 + Double($1.weight) }
            func quantile(_ q: Double) -> Double {
                var run = 0.0
                for r in sorted { run += Double(r.weight); if run >= q * total { return r.usd } }
                return sorted.last!.usd
            }
            let low = quantile(0.1), high = quantile(0.9)
            bands[category] = (low * 0.6).rounded(.down)...max((high * 1.5).rounded(.up), low + 1)
        }
        return PriceComfort(bands: bands)
    }

    /// Above the shopper's range for its department.
    func isAbove(_ p: Product) -> Bool {
        guard let band = bands[p.category] else { return false }
        return p.usdPrice > band.upperBound
    }

}

// MARK: - Sizes

/// The sizes a shopper picks, per department and per brand (a brand's own
/// fit wins over the department's), learned from what goes in the bag or is
/// bought now. The product page starts on that size when it's in stock.
struct SizeMemory: Codable, Equatable {
    var byDepartment: [String: String] = [:]
    var byBrand: [String: [String: String]] = [:]

    static let departments: Set<String> = ["clothing", "shoes"]
    private static let key = "sizes.v1"

    private static let letter = #"^(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|[2-6]xl|[2-6]x|one size|os|o/s|small|medium|large|x-small|x-large|xx-large|petite)$"#
    private static let number = #"^(us |uk |eu )?\d{1,2}(\.5)?( us| uk| eu)?$|^\d{2} ?x ?\d{2}$|^\d{2}w( \d{2}l)?$"#

    /// The size in a variant's title ("Black / M" -> "M"), using the store's
    /// option names when it gave them ("Color / Size").
    static func size(in title: String, optionNames: [String]? = nil) -> String? {
        let parts = title.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, title != "Default Title" else { return nil }
        if let names = optionNames, names.count == parts.count,
           let i = names.firstIndex(where: { $0.lowercased().contains("size") }) { return parts[i] }
        return parts.first { looksLikeSize($0) }
    }

    static func looksLikeSize(_ s: String) -> Bool {
        let t = s.lowercased()
        return t.range(of: letter, options: .regularExpression) != nil || t.range(of: number, options: .regularExpression) != nil
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    mutating func remember(_ size: String, department: String, brand: String) {
        guard Self.departments.contains(department) else { return }
        byDepartment[department] = size
        byBrand[brand, default: [:]][department] = size
    }

    func usual(department: String, brand: String) -> String? {
        byBrand[brand]?[department] ?? byDepartment[department]
    }

    /// The in-stock variant in the shopper's usual size, when there is one.
    func variant(in variants: [Variant], department: String, brand: String, optionNames: [String]? = nil) -> Variant? {
        guard let want = usual(department: department, brand: brand) else { return nil }
        return variants.first { $0.available && Self.size(in: $0.title, optionNames: optionNames).map { Self.same($0, want) } == true }
    }

    mutating func forget(department: String) {
        byDepartment[department] = nil
        for b in byBrand.keys { byBrand[b]?[department] = nil; if byBrand[b]?.isEmpty == true { byBrand[b] = nil } }
    }

    static func load(_ defaults: UserDefaults = .standard) -> SizeMemory {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SizeMemory.self, from: $0) } ?? SizeMemory()
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// A chosen variant of a clothing or shoe product: remember its size.
    @MainActor static func record(_ variant: Variant, of product: Product, optionNames: [String]?, defaults: UserDefaults = .standard) {
        guard TasteProfile.shared.enabled, departments.contains(product.category), !variant.isDefault,
              let size = size(in: variant.title, optionNames: optionNames) else { return }
        var memory = load(defaults)
        memory.remember(size, department: product.category, brand: product.brand)
        memory.save(defaults)
    }
}

// MARK: - Women / Men

/// A steady Women or Men choice in the filters: two or more picks in the last
/// 60 days, all the same side. Picks for the shopper then leave out clothing
/// and shoes made only for the other side. One pick for someone else doesn't
/// turn it.
enum GenderLean {
    private static let key = "gender.lean.v1"
    static let window: TimeInterval = 60 * 24 * 60 * 60
    private struct Pick: Codable { let side: String; let at: Date }

    /// A filter choice; the caller checks personalization is on.
    static func record(_ sides: Set<String>, at date: Date = .now, defaults: UserDefaults = .standard) {
        guard sides.count == 1, let side = sides.first else { return }
        var picks = load(defaults)
        picks.append(Pick(side: side, at: date))
        defaults.set(try? JSONEncoder().encode(Array(picks.suffix(10))), forKey: key)
    }

    static func side(now: Date = .now, defaults: UserDefaults = .standard) -> String? {
        let recent = load(defaults).filter { now.timeIntervalSince($0.at) < window }
        guard recent.count >= 2, let first = recent.first?.side, recent.allSatisfy({ $0.side == first }) else { return nil }
        return first
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    private static func load(_ defaults: UserDefaults) -> [Pick] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Pick].self, from: $0) } ?? []
    }

    /// A product a shopper leaning `side` would want suggested: anything not
    /// clothing or shoes, unlabelled, or labelled for that side (unisex too).
    static func fits(_ p: Product, side: String?) -> Bool {
        guard let side, SizeMemory.departments.contains(p.category), let g = p.attrs?["gender"], !g.isEmpty else { return true }
        return g.contains(side)
    }
}
