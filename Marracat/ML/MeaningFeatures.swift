import SwiftUI

/// What the app does with the meaning space (MeaningIndex) and the shopper's
/// taste (TasteProfile), all on the iPhone (owner, 2026-10-02):
/// search by meaning, "Similar look", "Pairs well with", "Picked for you right
/// now", Shop by Style boards and restock reminders. Each returns nothing
/// until the meaning vectors have arrived, and the view simply doesn't show.
enum MeaningPicks {
    /// Nearest products to `vector` that are in the catalog, in stock and kept.
    /// In-stock ids, built once per catalog (rebuilding 120k on every call
    /// was a main-thread pause on each product page).
    @MainActor private static var inStock: (stamp: String, ids: Set<String>)?

    @MainActor
    static func products(near vector: [Float], catalog: CatalogStore, limit: Int,
                         keep: @escaping @Sendable (String) -> Bool = { _ in true }) async -> [Product] {
        let stamp = catalog.stamp
        if inStock?.stamp != stamp {
            let products = catalog.catalog.products
            inStock = (stamp, await Task.detached(priority: .userInitiated) {
                Set(products.lazy.filter(\.available).map(\.id))
            }.value)
        }
        let available = inStock!.ids
        let ids = await Task.detached(priority: .userInitiated) {
            MeaningIndex.shared.nearest(to: vector, limit: limit * 3) { available.contains($0) && keep($0) }.map(\.id)
        }.value
        return Array(ids.compactMap(catalog.product).prefix(limit))
    }

    /// Search by meaning: what a phrase is about, not only its words.
    @MainActor
    static func meaning(of query: String, catalog: CatalogStore, excluding: Set<String>, limit: Int = 20) async -> [Product] {
        guard await MeaningIndex.shared.prepare(),
              let v = await Task.detached(priority: .userInitiated, operation: { MeaningIndex.shared.embed(query) }).value else { return [] }
        return await products(near: v, catalog: catalog, limit: limit) { !excluding.contains($0) }
    }

    /// The same look in other brands' and the same brand's other products.
    /// `excluding`: products a row above already shows on the page (owner,
    /// 2026-11-17: two rows shouldn't show the same products). Kept per
    /// product page, so "Goes well with" can skip exactly what this row shows.
    @MainActor private static var similarCache: [String: [Product]] = [:]

    @MainActor
    static func similar(to p: Product, catalog: CatalogStore, limit: Int = 12, excluding: Set<String> = []) async -> [Product] {
        let key = "\(catalog.stamp)|\(p.id)|\(limit)|\(excluding.sorted().joined(separator: ","))"
        if let hit = similarCache[key] { return hit }
        guard let v = MeaningIndex.shared.vector(for: p.id) else { return [] }
        let id = p.id, title = p.title.lowercased()
        // The same brand first; other brands only fill what it can't (owner,
        // 2026-11-17).
        let ownIDs = Set(catalog.products(for: p.brand).map(\.id))
        let notSameItem = { (ps: [Product]) in ps.filter { $0.title.lowercased() != title } }  // not another colour or size
        var picked = notSameItem(await products(near: v, catalog: catalog, limit: limit * 2) {
            $0 != id && !excluding.contains($0) && ownIDs.contains($0)
        })
        if picked.count < limit {
            picked += notSameItem(await products(near: v, catalog: catalog, limit: limit * 2) {
                $0 != id && !excluding.contains($0) && !ownIDs.contains($0)
            })
        }
        picked = Array(picked.prefix(limit))
        if similarCache.count > 40 { similarCache = [:] }
        similarCache[key] = picked
        return picked
    }

    /// From other departments, close in style: the earrings for the dress.
    /// Stands in for "Frequently bought together" until there are enough
    /// orders to learn real pairings from (Pairings.swift).
    @MainActor private static var categories: (stamp: String, byID: [String: String])?

    /// Each product's department, built once per catalog off the main thread.
    @MainActor
    static func departments(_ catalog: CatalogStore) async -> [String: String] {
        if categories?.stamp != catalog.stamp {
            let products = catalog.catalog.products
            categories = (catalog.stamp, await Task.detached(priority: .userInitiated) {
                Dictionary(products.map { ($0.id, $0.category) }, uniquingKeysWith: { a, _ in a })
            }.value)
        }
        return categories!.byID
    }

    /// `allowed`: the departments the shopper has shown interest in, plus
    /// this product's own; empty allows all (a shopper with no history).
    @MainActor
    static func pairsWell(with p: Product, catalog: CatalogStore, limit: Int = 12, allowed: Set<String> = [], excluding: Set<String> = []) async -> [Product] {
        guard let v = MeaningIndex.shared.vector(for: p.id) else { return [] }
        let category = p.category
        let byID = await departments(catalog)
        let ownIDs = Set(catalog.products(for: p.brand).map(\.id))
        let fits: @Sendable (String) -> Bool = { id in
            guard !excluding.contains(id), let c = byID[id], c != category else { return false }
            return allowed.isEmpty || allowed.contains(c)
        }
        // The brand's own products from other departments first; other
        // brands, spread out, only fill the rest (owner, 2026-11-17).
        let own = await products(near: v, catalog: catalog, limit: limit) { fits($0) && ownIDs.contains($0) }
        guard own.count < limit else { return own }
        let others = await products(near: v, catalog: catalog, limit: limit * 3) { fits($0) && !ownIDs.contains($0) }
        return own + catalog.spread(others, limit: limit - own.count)
    }

    /// Live: what this session's looks, saves and cart point at. Each of the
    /// shopper's interests fills its share of the row in turn, so two
    /// interests aren't averaged into neither (owner, 2026-11-08). The query
    /// leans away from what was hidden, muted or marked "Not me" (negative
    /// feedback, as in Rocchio's), clothing and shoes follow a steady Women or
    /// Men choice, and products above the shopper's price range for their
    /// department go behind the rest.
    /// Only from `allowed` departments, the ones the shopper has shown
    /// interest in (owner, 2026-11-09); empty allows all.
    @MainActor
    static func forTaste(catalog: CatalogStore, hidden: Set<String>, limit: Int = 12, allowed: Set<String> = []) async -> [Product] {
        let taste = TasteProfile.shared
        var interests = taste.interests()
        if interests.isEmpty, let v = taste.vector() { interests = [TasteInterest(vector: v, share: 1, products: [])] }
        guard !interests.isEmpty else { return [] }
        let skip = Set(taste.recentProducts.prefix(60)).union(hidden).union(taste.muted)
        let byID = allowed.isEmpty ? [:] : await departments(catalog)
        let keep: @Sendable (String) -> Bool = { id in !skip.contains(id) && (allowed.isEmpty || byID[id].map(allowed.contains) == true) }
        let avoid = await avoidVector(hidden: hidden)
        let side = GenderLean.side()
        let slots = TasteMath.slots(interests.map(\.share), limit: limit * 3)
        var lists: [[String]] = []
        for (k, interest) in interests.enumerated() {
            let query = avoid.map { a in TasteMath.normalized(zip(interest.vector, a).map { $0 - avoidWeight * $1 }) } ?? interest.vector
            let found = await products(near: query, catalog: catalog, limit: slots[k] * 2, keep: keep)
            lists.append(found.filter { GenderLean.fits($0, side: side) }.map(\.id))
        }
        let picked = TasteMath.interleave(lists, slots: slots).compactMap(catalog.product)
        // Spread across brands within each price group, so the spread doesn't
        // bring an out-of-range product forward.
        let comfort = priceComfort(catalog: catalog)
        let inRange = catalog.spread(picked.filter { !comfort.isAbove($0) }, limit: limit)
        return inRange + catalog.spread(picked.filter(comfort.isAbove), limit: limit - inRange.count)
    }

    /// How far a query leans away from what pushes away.
    static let avoidWeight: Float = 0.35

    /// Hidden and muted products and "Not me" styles, as one direction.
    @MainActor
    static func avoidVector(hidden: Set<String>) async -> [Float]? {
        var parts: [[Float]] = []
        let pushed = Array(hidden.prefix(100)) + TasteProfile.shared.muted.prefix(100)
        if let c = MeaningIndex.shared.centroid(of: pushed) { parts.append(c) }
        for id in TasteProfile.shared.notMeStyles {
            if let style = ShopStyle.all.first(where: { $0.id == id }), let v = await style.vector() { parts.append(v) }
        }
        guard let first = parts.first else { return nil }
        return TasteMath.normalized(parts.dropFirst().reduce(first) { zip($0, $1).map(+) })
    }

    /// The shopper's price range per department, from what they touched.
    @MainActor
    static func priceComfort(catalog: CatalogStore) -> PriceComfort {
        PriceComfort.learn(TasteProfile.shared.weightedProducts().compactMap { t in
            catalog.product(t.id).map { (category: $0.category, usd: $0.usdPrice, weight: t.weight) }
        })
    }

    /// "Something new to try" (owner, 2026-11-08: "7: lets do it"): a style
    /// next to the shopper's own, not their closest, rotating daily among the
    /// 2nd to 4th closest, minus what they've seen or pushed away. Shown items
    /// that get opened pull the taste toward that style like any other.
    @MainActor
    static func exploration(catalog: CatalogStore, hidden: Set<String>, limit: Int = 12, allowed: Set<String> = [], now: Date = .now) async -> (style: ShopStyle, products: [Product])? {
        guard TasteProfile.shared.hasHistory else { return nil }
        let notMe = Set(TasteProfile.shared.notMeStyles)
        let styles = await ShopStyle.ordered().filter { !notMe.contains($0.id) }
        guard styles.count >= 2 else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
        let skip = Set(TasteProfile.shared.recentProducts.prefix(60)).union(hidden).union(TasteProfile.shared.muted)
        let side = GenderLean.side()
        // The next three styles with enough from departments the shopper has
        // shown interest in (owner, 2026-11-09: "if they never purchase dog
        // food or search for it we should never show it").
        var neighbours: [(ShopStyle, [Product])] = []
        for style in styles.dropFirst() where neighbours.count < 3 {
            let products = await style.products(catalog: catalog).filter {
                !skip.contains($0.id) && GenderLean.fits($0, side: side) && (allowed.isEmpty || allowed.contains($0.category))
            }
            if products.count >= 4 { neighbours.append((style, products)) }
        }
        guard !neighbours.isEmpty else { return nil }
        let (style, products) = neighbours[day % neighbours.count]
        return (style, Array(products.prefix(limit)))
    }

    /// The same, with the vector math off the main thread: Home's launch
    /// reads it as the whole catalog lands, while the shopper may be scrolling.
    @MainActor
    static func categoryAffinityInBackground(catalog: CatalogStore) async -> [String: Float] {
        guard let taste = TasteProfile.shared.vector() else { return [:] }
        let samples = catalog.categories.map { c in
            (c.id, Array(catalog.products(in: c.id).lazy.filter(\.available).prefix(40).map(\.id)))
        }
        return await Task.detached(priority: .userInitiated) {
            var out: [String: Float] = [:]
            for (id, sample) in samples {
                if let centroid = MeaningIndex.shared.centroid(of: sample) { out[id] = TasteProfile.affinity(taste, centroid) }
            }
            return out
        }.value
    }

    /// How close each department is to the taste, for ordering Home's rows.
    @MainActor
    static func categoryAffinity(catalog: CatalogStore) -> [String: Float] {
        guard let taste = TasteProfile.shared.vector() else { return [:] }
        var out: [String: Float] = [:]
        for c in catalog.categories {
            let sample = catalog.products(in: c.id).lazy.filter(\.available).prefix(40).map(\.id)
            if let centroid = MeaningIndex.shared.centroid(of: Array(sample)) {
                out[c.id] = TasteProfile.affinity(taste, centroid)
            }
        }
        return out
    }
}

// MARK: - Shop by Style

/// Aesthetic boards, each described in words the model reads, filled with the
/// catalog's products that sit closest to that description. Real products,
/// arranged as a collage, ordered by how close each style is to the shopper.
struct ShopStyle: Identifiable, Hashable {
    let id: String
    let name: String
    let prompt: String

    static let all: [ShopStyle] = [
        .init(id: "urban-luxe", name: String(localized: "Urban Luxe", comment: "Shopping style name"), prompt: "luxury streetwear, designer sneakers, gold chains, black leather, city night out"),
        .init(id: "soft-elegance", name: String(localized: "Soft Elegance", comment: "Shopping style name"), prompt: "soft pastel satin, delicate pearl jewelry, feminine elegant dress, blush pink"),
        .init(id: "heritage-prints", name: String(localized: "Heritage Prints", comment: "Shopping style name"), prompt: "bold african print, kente, ankara, mudcloth, vibrant patterned fabric"),
        .init(id: "clean-minimal", name: String(localized: "Clean Minimal", comment: "Shopping style name"), prompt: "minimalist neutral tones, simple clean design, cream beige black and white"),
        .init(id: "glam-night", name: String(localized: "Glam Night Out", comment: "Shopping style name"), prompt: "sparkly glamorous party look, sequins, bold lipstick, statement earrings"),
        .init(id: "cozy-home", name: String(localized: "Cozy Homebody", comment: "Shopping style name"), prompt: "cozy loungewear, soft knit, scented candles, warm blanket, relaxing at home"),
        .init(id: "natural-glow", name: String(localized: "Natural Glow", comment: "Shopping style name"), prompt: "natural skincare, shea butter, botanical oils, clean beauty, glowing skin"),
        .init(id: "street-sport", name: String(localized: "Street Sport", comment: "Shopping style name"), prompt: "athleisure, hoodie, joggers, sneakers, sporty streetwear"),
        .init(id: "boho-earth", name: String(localized: "Boho Earth", comment: "Shopping style name"), prompt: "bohemian earthy tones, woven bag, natural textures, flowy dress"),
        .init(id: "vintage-soul", name: String(localized: "Vintage Soul", comment: "Shopping style name"), prompt: "vintage retro style, seventies and nineties inspired, vinyl records, classic"),
        // Beyond fashion (owner, 2026-11-09: "this app has other things than
        // clothing like laundry detergent, household items").
        .init(id: "fresh-clean", name: String(localized: "Fresh & Clean", comment: "Shopping style name: laundry and cleaning"), prompt: "laundry detergent, dish soap, all-purpose cleaning spray, fresh clean household essentials"),
        .init(id: "home-cook", name: String(localized: "Home Cook", comment: "Shopping style name: food and kitchen"), prompt: "gourmet hot sauce, spices and seasonings, coffee beans, tea, pantry staples, home cooking"),
        .init(id: "wellness-ritual", name: String(localized: "Wellness Ritual", comment: "Shopping style name: health and self-care"), prompt: "vitamins and supplements, herbal tea, sea moss, bath soak, self-care wellness routine"),
        .init(id: "crown-care", name: String(localized: "Crown Care", comment: "Shopping style name: hair care"), prompt: "natural hair care, curl cream, hair oil, satin bonnet, edge control, wash day"),
        .init(id: "little-ones", name: String(localized: "Little Ones", comment: "Shopping style name: baby and kids"), prompt: "baby onesie, gentle baby lotion and wash, baby bottle, teething toy, nursery essentials"),
        .init(id: "pet-pals", name: String(localized: "Pet Pals", comment: "Shopping style name: pets"), prompt: "dog treats, pet toys, cat bed, pet grooming, dog collar and leash"),
    ]

    /// The styles that are outfits and what goes with them. A list of styles
    /// puts no more than two of these in a row while another kind is left,
    /// so a shopper who looked at clothes still sees the rest of the store
    /// (owner, 2026-11-09: "the app favors showing the user clothes").
    static let fashion: Set<String> = ["urban-luxe", "soft-elegance", "heritage-prints", "clean-minimal",
                                       "glam-night", "street-sport", "boho-earth", "vintage-soul"]
    var isFashion: Bool { Self.fashion.contains(id) }

    /// `list` in its order, except that after two fashion styles in a row the
    /// next other kind comes forward.
    static func mixed<T>(_ list: [T], style: (T) -> ShopStyle) -> [T] {
        var rest = list, out: [T] = []
        while !rest.isEmpty {
            let run = out.suffix(2).allSatisfy { style($0).isFashion } && out.count >= 2
            let i = run ? (rest.firstIndex { !style($0).isFashion } ?? 0) : 0
            out.append(rest.remove(at: i))
        }
        return out
    }

    @MainActor private static var vectors: [String: [Float]] = [:]
    @MainActor private static var boards: [String: (stamp: String, products: [Product])] = [:]

    /// Each prompt as the Mac's MobileCLIP2 read it (catalog/embed_style_prompts.py,
    /// 2026-10-18): the boards need only the product vectors, so Home no longer
    /// waits on loading the 61 MB text model to read ten fixed sentences. Kept
    /// only while the prompt text still matches.
    static let precomputed: [String: [Float]] = {
        struct File: Decodable { struct Style: Decodable { let id, prompt, embedding: String }; let styles: [Style] }
        guard let url = Bundle.main.url(forResource: "style-prompts", withExtension: "json"),
              let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [:] }
        let prompts = Dictionary(all.map { ($0.id, $0.prompt) }, uniquingKeysWith: { a, _ in a })
        var out: [String: [Float]] = [:]
        for s in file.styles where prompts[s.id] == s.prompt {
            guard let raw = Data(base64Encoded: s.embedding) else { continue }
            out[s.id] = raw.withUnsafeBytes { b in (0..<(b.count / 4)).map { Float(bitPattern: b.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian) } }
        }
        return out
    }()

    @MainActor
    func vector() async -> [Float]? {
        if let raw = Self.precomputed[id] {
            // On disk, or (a first install) downloaded as before.
            var ready = await MeaningIndex.shared.loadVectors()
            if !ready { ready = await MeaningIndex.shared.prepare() }
            guard ready, let space = MeaningIndex.shared.space else { return nil }
            let key = space + "|" + id
            if let v = Self.vectors[key] { return v }
            let v = MeaningIndex.shared.place(raw: raw)
            if let v { Self.vectors[key] = v }
            return v
        }
        guard await MeaningIndex.shared.prepare(), let space = MeaningIndex.shared.space else { return nil }
        let key = space + "|" + id   // remade if the vectors' space changes
        if let v = Self.vectors[key] { return v }
        let prompt = prompt
        let v = await Task.detached(priority: .utility) { MeaningIndex.shared.embed(prompt) }.value
        if let v { Self.vectors[key] = v }
        return v
    }

    /// The board: up to 48 in-stock products, spread across brands.
    @MainActor
    func products(catalog: CatalogStore) async -> [Product] {
        let stamp = catalog.stamp
        if let b = Self.boards[id], b.stamp == stamp { return b.products }
        guard let v = await vector() else { return [] }
        let found = await MeaningPicks.products(near: v, catalog: catalog, limit: 120)
        let board = catalog.spread(found, limit: 48)
        Self.boards[id] = (stamp, board)
        return board
    }

    /// Styles closest to the shopper first, mixed so fashion doesn't fill
    /// the front (`mixed`); without a taste, the list order mixed the same
    /// way. Styles marked "Not me" go last.
    @MainActor
    static func ordered() async -> [ShopStyle] {
        let notMe = Set(TasteProfile.shared.notMeStyles)
        guard let taste = TasteProfile.shared.vector() else {
            return mixed(all.filter { !notMe.contains($0.id) }, style: { $0 }) + all.filter { notMe.contains($0.id) }
        }
        var scored: [(ShopStyle, Float)] = []
        for s in all where !notMe.contains(s.id) { scored.append((s, await s.vector().map { TasteProfile.affinity(taste, $0) } ?? -1)) }
        return mixed(scored.sorted { $0.1 > $1.1 }.map(\.0), style: { $0 }) + all.filter { notMe.contains($0.id) }
    }

    /// How close each style is to the taste, for the Your taste screen.
    @MainActor
    static func affinities() async -> [(style: ShopStyle, affinity: Float)] {
        guard let taste = TasteProfile.shared.vector() else { return [] }
        var out: [(ShopStyle, Float)] = []
        for s in all { if let v = await s.vector() { out.append((s, TasteProfile.affinity(taste, v))) } }
        return mixed(out.sorted { $0.1 > $1.1 }, style: { $0.0 })
    }
}

/// Home's "Shop by style" row: a collage per style.
struct ShopByStyleRow: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @State private var boards: [(style: ShopStyle, products: [Product])] = []
    /// The boards are still being worked out and the on-device AI is on this
    /// phone, so they're coming: the row's place is held at its full height.
    /// It used to grow from nothing to ~180 pt as they arrived, moving
    /// everything below it (owner, build 132: "Shop by style" came in from the
    /// bottom just as Home froze mid-fling).
    @State private var holding = MeaningIndex.onDisk
    /// On screen are the boards saved last session: this session's first
    /// working-out is saved for the next launch instead of swapped in under
    /// the shopper.
    @State private var showingSaved = false
    static let title = String(localized: "Shop by style", comment: "Section title: shop by visual style")

    var body: some View {
        Group {
            if !boards.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.title).brandFont(.title3.bold()).padding(.horizontal, 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(boards, id: \.style.id) { b in
                                NavigationLink(value: Route.style(b.style.id)) { StyleCollage(style: b.style, products: b.products) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("styleBoard")
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            } else if holding {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.title).brandFont(.title3.bold()).padding(.horizontal, 12)
                    HStack(spacing: 12) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12).fill(Theme.field)
                                .frame(width: StyleCollage.width, height: StyleCollage.height)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .accessibilityIdentifier("stylePlaceholder")
            } else {
                Color.clear.frame(height: 0)   // so .task below starts (see AsyncProductRow)
            }
        }
        // The saved boards, as Home's slice lands (they're read beside it).
        .onChange(of: catalog.isReady, initial: true) {
            guard boards.isEmpty, let saved = catalog.launchStyleBoards else { return }
            catalog.launchStyleBoards = nil
            let resolved = saved.boards.compactMap { b in
                ShopStyle.all.first { $0.id == b.id }.flatMap { s in b.products.count >= 6 ? (style: s, products: b.products) : nil }
            }
            guard !resolved.isEmpty else { return }
            boards = resolved
            showingSaved = true
            holding = false
            HomeSettle.shared.styleBoardsReady()
        }
        .task(id: TasteProfile.shared.revision / 5) {
            // Nothing to work out without a download: Home doesn't wait for it.
            if !MeaningIndex.onDisk { HomeSettle.shared.styleBoardsReady() }
            var out: [(ShopStyle, [Product])] = []
            // Boards from the departments this shopper has shown interest in
            // only (owner, 2026-11-09): no Pet Pals for someone who never
            // looked at pets. A new shopper sees them all.
            let allowed = catalog.touchedDepartments(of: shopper)
            for s in await ShopStyle.ordered() {
                let ps = await s.products(catalog: catalog).filter { allowed.isEmpty || allowed.contains($0.category) }
                if ps.count >= 6 { out.append((s, ps)) }
            }
            guard !Task.isCancelled else { return }
            if !out.isEmpty {
                StyleBoardsCache.save(StyleBoards(boards: out.map { .init(id: $0.0.id, products: Array($0.1.prefix(6))) }))
                if showingSaved { showingSaved = false } else { boards = out.map { (style: $0.0, products: $0.1) } }
            }
            holding = false
            HomeSettle.shared.styleBoardsReady()
        }
    }
}

/// Six photos in a 3 x 2 moodboard with the style's name across the bottom.
struct StyleCollage: View {
    let style: ShopStyle
    let products: [Product]

    static let cell: CGFloat = 78
    static let width = cell * 3 + 4
    static let height = cell * 2 + 2

    var body: some View {
        let cell = Self.cell
        VStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { col in
                        let i = row * 3 + col
                        RemoteImage(url: i < products.count ? products[i].images.first : nil, width: 240, contentMode: .fill)
                            .frame(width: cell, height: cell).clipped().background(Theme.field)
                    }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text(style.name).brandFont(.headline).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .bottom, endPoint: .top))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shop by style: \(style.name)")
    }
}

struct StyleScreen: View {
    let styleID: String
    @Environment(CatalogStore.self) private var catalog
    @State private var products: [Product] = []

    var body: some View {
        let style = ShopStyle.all.first { $0.id == styleID }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let style {
                    Text(style.name).brandFont(.title.bold()).padding(.horizontal, 12).padding(.top, 12)
                    if products.count >= 6 {
                        StyleCollage(style: style, products: products).frame(maxWidth: .infinity).padding(.horizontal, 12)
                    }
                }
                ProductGrid(products: products)
            }
        }
        .background(Theme.canvas)
        .task { if let style { products = await style.products(catalog: catalog) } }
        .barTitle(style?.name ?? String(localized: "Style", comment: "Fallback title for a style screen"))
        .marracatChrome()
    }
}

// MARK: - Restock reminders

/// "Time to restock?": consumables bought before, coming up on when they
/// usually run out. The interval is this shopper's own between repeat buys of
/// the same product when there are any, else a typical one for the kind of
/// product. A statistical model on purpose: Marracat has a handful of orders,
/// far too few to train anything deeper; it sharpens as orders come in.
enum Replenishment {
    static let typicalDays: [String: Double] = [
        "skincare": 60, "hair": 45, "makeup": 75, "wellness": 30, "grocery": 21, "household": 45,
        "home": 45, "fragrance": 120, "baby": 21, "pets": 30, "alcohol": 30,
    ]

    @MainActor
    static func due(checkouts: [CheckoutRecord], catalog: CatalogStore, now: Date = .now) -> [Product] {
        var dates: [String: [Date]] = [:]
        for c in checkouts { for id in c.productIDs { dates[id, default: []].append(c.date) } }
        var due: [(Product, Double)] = []
        for (id, bought) in dates {
            guard let p = catalog.product(id), p.available, let typical = typicalDays[p.category] else { continue }
            let sorted = bought.sorted()
            let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.filter { $0 > 3 }
            let interval = gaps.isEmpty ? typical : gaps.sorted()[gaps.count / 2]
            let daysSince = now.timeIntervalSince(sorted.last!) / 86_400
            // From a week before the projected run-out until well after it.
            let progress = daysSince / interval
            if daysSince >= interval - 7, progress < 3 { due.append((p, progress)) }
        }
        return due.sorted { abs($0.1 - 1) < abs($1.1 - 1) }.map(\.0)
    }
}

/// A product row filled in the background; it isn't drawn until there are at
/// least four products to show, so a feature waiting on the meaning vectors
/// (or with nothing to say) leaves no gap.
struct AsyncProductRow<Key: Equatable>: View {
    let title: String
    let key: Key
    var route: Route? = nil
    var identifier: String
    /// See ProductRow.track.
    var track: String? = nil
    var reserved: @MainActor ([Product]) -> Set<String> = { _ in [] }
    let load: @MainActor () async -> [Product]
    @State private var products: [Product] = []

    var body: some View {
        Group {
            if products.count >= 4 {
                ProductRow(title: title, products: products, route: route, track: track, reserved: reserved(products))
                    .accessibilityIdentifier(identifier)
            } else {
                // Something has to appear for .task to start: an empty Group
                // never appears, so the row never loaded (found on device).
                Color.clear.frame(height: 0)
            }
        }
        .task(id: key) {
            let found = await load()
            if !Task.isCancelled { products = found }
        }
    }
}
