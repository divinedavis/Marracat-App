import SwiftUI

/// Narrowing a set of products the way a department store does: pick from
/// several groups at once, OR inside a group and AND across groups, with a
/// live count of what's left.
///
/// Everything here is derived from the catalog we already ship. Colour and
/// size come out of Shopify variant titles ("Black / Large"), which carry no
/// option names, so each part is classified by what it looks like.
struct ProductFilters: Hashable {
    var brands: Set<String> = []
    var categories: Set<String> = []
    /// Aisles, as Subcategory ids ("clothing:pants"): pants, sweatshirts,
    /// dresses inside Clothing (owner, 2026-11-08: "we need better filtering
    /// for clothes, we need pants, sweatshirts, etc.").
    var aisles: Set<String> = []
    var colors: Set<String> = []
    var sizes: Set<String> = []
    var priceBands: Set<String> = []
    var offers: Set<Offer> = []
    /// Brand-said filters by AttrFilter field ("skintype": ["oily"]).
    var attrs: [String: Set<String>] = [:]
    var sort: ProductSort = .featured

    enum Offer: String, CaseIterable, Identifiable, Hashable {
        case inStock = "In stock"
        case onSale = "On sale"
        case clean = "Marracat Clean"
        case trueMetal = "Marracat True Metal"
        case ethicallySourced = "Ethically Sourced"
        case clearScent = "Marracat Clear Scent"
        case saferClean = "Marracat Safer Clean"
        case cleanFood = "Marracat Clean Food"
        case babySafe = "Marracat Baby Safe"
        case naturalFiber = "Marracat Natural Fiber"
        case safeFabric = "Marracat Safe Fabric"
        case labVerified = "Marracat Lab Verified"
        case petSafe = "Marracat Pet Safe"
        case trueMaterial = "Marracat True Material"
        case naturalHome = "Marracat Natural Home"
        case organic = "Certified organic"
        /// rawValue is the stable id (filter state, analytics); this is what
        /// the shopper reads. Marracat badge names stay English everywhere.
        var title: String {
            switch self {
            case .inStock: String(localized: "In stock", comment: "Filter option: only products in stock")
            case .onSale: String(localized: "On sale", comment: "Filter option: only discounted products")
            case .organic: String(localized: "Certified organic", comment: "Filter option: only certified organic products")
            default: rawValue
            }
        }
        var id: String { rawValue }

        /// A quality badge (and Certified organic) rather than stock or sale:
        /// these sit in their own Badges group (owner, 2026-11-11: "instead
        /// of having the badges in offers, have badges section for filtering
        /// with the images of the badge for the tiles").
        var isBadge: Bool { self != .inStock && self != .onSale }

        /// The tile's name under it: "Clean", not "Marracat Clean".
        var shortTitle: String {
            self == .organic ? title : rawValue.replacingOccurrences(of: "Marracat ", with: "")
        }

        /// The Type-led tile (owner, 2026-11-11, picked "4. Type-led" of five
        /// previews): the badge colour, its product-card symbol, and the
        /// words set big. Colours and symbols as BadgeIconRow draws them.
        var tile: (color: Color, symbol: String, kicker: String, word: String)? {
            let word = shortTitle.uppercased()
            switch self {
            case .inStock, .onSale: return nil
            case .organic: return (Theme.organic, "leaf.fill", "CERTIFIED", "ORGANIC")
            case .clean: return (Theme.clean, "checkmark.shield.fill", "MARRACAT", word)
            case .trueMetal: return (Theme.metal, "seal.fill", "MARRACAT", word)
            case .ethicallySourced: return (Theme.metal, "globe.europe.africa.fill", "MARRACAT", word)
            case .clearScent: return (Theme.scent, "drop.fill", "MARRACAT", word)
            case .saferClean: return (Theme.saferClean, "leaf.fill", "MARRACAT", word)
            case .cleanFood: return (Theme.cleanFood, "carrot.fill", "MARRACAT", word)
            case .babySafe: return (Theme.babySafe, "heart.fill", "MARRACAT", word)
            case .naturalFiber: return (Theme.naturalFiber, "tshirt.fill", "MARRACAT", word)
            case .safeFabric: return (Theme.safeFabric, "checkmark.shield.fill", "MARRACAT", word)
            case .labVerified: return (Theme.labVerified, "flask.fill", "MARRACAT", word)
            case .petSafe: return (Theme.petSafe, "pawprint.fill", "MARRACAT", word)
            case .trueMaterial: return (Theme.trueMaterial, "bag.fill", "MARRACAT", word)
            case .naturalHome: return (Theme.naturalHome, "house.fill", "MARRACAT", word)
            }
        }

        func matches(_ p: Product) -> Bool {
            switch self {
            case .inStock: return p.available
            case .onSale: return p.percentOff != nil
            case .clean: return p.isMarracatClean
            case .trueMetal: return p.isMarracatTrueMetal
            case .ethicallySourced: return p.isEthicallySourced
            case .clearScent: return p.isMarracatClearScent
            case .saferClean: return p.isMarracatSaferClean
            case .cleanFood: return p.isMarracatCleanFood
            case .babySafe: return p.isMarracatBabySafe
            case .naturalFiber: return p.isMarracatNaturalFiber
            case .safeFabric: return p.isMarracatSafeFabric
            case .labVerified: return p.isMarracatLabVerified
            case .petSafe: return p.isMarracatPetSafe
            case .trueMaterial: return p.isMarracatTrueMaterial
            case .naturalHome: return p.isMarracatNaturalHome
            case .organic: return p.isCertifiedOrganic
            }
        }
    }

    /// How many groups are narrowing the results. Sort isn't a filter.
    var activeCount: Int {
        brands.count + categories.count + aisles.count + colors.count + sizes.count + priceBands.count + offers.count
            + attrs.values.reduce(0) { $0 + $1.count }
    }
    var isEmpty: Bool { activeCount == 0 }

    mutating func clear() {
        let keptSort = sort
        self = ProductFilters()
        sort = keptSort
    }

    /// Everything except one group, so that group's own counts don't collapse
    /// to the choice already made in it.
    @MainActor func matches(_ p: Product, ignoring group: FilterGroup? = nil) -> Bool {
        if group != .brand, !brands.isEmpty, !brands.contains(p.brand) { return false }
        if group != .category, !categories.isEmpty, !categories.contains(p.category) { return false }
        if group != .aisle, !aisles.isEmpty, !Self.inAisle(p, aisles) { return false }
        if group != .color, !colors.isEmpty, colors.isDisjoint(with: ProductFacets.colors(p)) { return false }
        if group != .size, !sizes.isEmpty, sizes.isDisjoint(with: ProductFacets.sizes(p)) { return false }
        if group != .price, !priceBands.isEmpty, !priceBands.contains(PriceBand.band(for: p.usdPrice).name) { return false }
        if group != .offers, !offers.filter({ !$0.isBadge }).allSatisfy({ $0.matches(p) }) { return false }
        if group != .badges, !offers.filter(\.isBadge).allSatisfy({ $0.matches(p) }) { return false }
        for (field, want) in attrs where !want.isEmpty && group?.attrField != field {
            if want.isDisjoint(with: p.attrs?[field] ?? []) { return false }
        }
        return true
    }

    /// A product sits in every aisle it was linked to (Product.subs).
    static func aisleIDs(_ p: Product) -> [String] { p.subs.map { "\(p.category):\($0)" } }
    static func inAisle(_ p: Product, _ aisles: Set<String>) -> Bool {
        p.subs.contains { aisles.contains("\(p.category):\($0)") }
    }

    @MainActor func apply(_ products: [Product]) -> [Product] {
        let kept = isEmpty ? products : products.filter { matches($0) }
        // Featured keeps whatever order the caller ranked them in, so a search
        // stays sorted by relevance once it's been narrowed.
        return sort == .featured ? kept : sort.apply(kept)
    }
}

/// Sort is deliberately not here. It reorders rather than narrows, so it sits
/// beside the Filters button instead of inside the sheet.
enum FilterGroup: String, CaseIterable, Identifiable {
    case category = "Category"
    case aisle = "Type"
    case gender = "Gender"
    case brand = "Brand"
    case price = "Price"
    // What the brand says (AttrFilter), each in its own department only.
    case hairType = "Hair type"
    case skinConcern = "Skin concern"
    case skinType = "Skin type"
    case ingredient = "Key ingredient"
    case preferences = "Ingredient preferences"
    case formulation = "Formulation"
    case sunProtection = "Sun protection"
    case pack = "Minis & sets"
    case color = "Colour"
    case size = "Size"
    case badges = "Badges"
    case offers = "Offers"
    var id: String { rawValue }
    /// rawValue is the stable id; this is the heading the shopper reads.
    var title: String {
        switch self {
        case .category: String(localized: "Category", comment: "Filter group heading")
        case .aisle: String(localized: "Type", comment: "Filter group heading: the kind of product inside a category, e.g. Pants, Sweatshirts, Dresses")
        case .gender: String(localized: "Gender", comment: "Filter group heading: Women / Men")
        case .brand: String(localized: "Brand", comment: "Filter group heading")
        case .price: String(localized: "Price", comment: "Filter group heading")
        case .color: String(localized: "Colour", comment: "Filter group heading")
        case .size: String(localized: "Size", comment: "Filter group heading")
        case .badges: String(localized: "Badges", comment: "Filter group heading: Marracat's quality badges (Marracat Clean, True Metal and the like) and Certified organic")
        case .offers: String(localized: "Offers", comment: "Filter group heading: in stock and on sale")
        case .hairType: String(localized: "Hair type", comment: "Filter group heading")
        case .skinConcern: String(localized: "Skin concern", comment: "Filter group heading")
        case .skinType: String(localized: "Skin type", comment: "Filter group heading")
        case .ingredient: String(localized: "Key ingredient", comment: "Filter group heading")
        case .preferences: String(localized: "Ingredient preferences", comment: "Filter group heading: fragrance-free, vegan and the like")
        case .formulation: String(localized: "Formulation", comment: "Filter group heading: serum, cream, oil and the like")
        case .sunProtection: String(localized: "Sun protection", comment: "Filter group heading: SPF")
        case .pack: String(localized: "Minis & sets", comment: "Filter group heading: travel sizes, gift sets, refills")
        }
    }

    /// The AttrFilter field a brand-said group filters on.
    var attrField: String? {
        switch self {
        case .gender: "gender"
        case .hairType: "hair"
        case .skinConcern: "skin"
        case .skinType: "skintype"
        case .ingredient: "ingredient"
        case .preferences: "free"
        case .formulation: "form"
        case .sunProtection: "spf"
        case .pack: "pack"
        default: nil
        }
    }
}

/// A price band. Fixed edges rather than quantiles, so the same product sits in
/// the same band on every screen.
enum PriceBand {
    static let all: [(name: String, range: Range<Double>)] = [
        ("Under $25", 0..<25),
        ("$25 to $50", 25..<50),
        ("$50 to $100", 50..<100),
        ("$100 to $250", 100..<250),
        ("$250 and up", 250..<Double.greatestFiniteMagnitude),
    ]
    static func band(for price: Double) -> (name: String, range: Range<Double>) {
        all.first { $0.range.contains(price) } ?? all[all.count - 1]
    }
    /// The band's name is its stable id (filter state); this is the label.
    static func title(_ name: String) -> String {
        switch name {
        case "Under $25": String(localized: "Under $25", comment: "Price filter band (US dollars)")
        case "$25 to $50": String(localized: "$25 to $50", comment: "Price filter band (US dollars)")
        case "$50 to $100": String(localized: "$50 to $100", comment: "Price filter band (US dollars)")
        case "$100 to $250": String(localized: "$100 to $250", comment: "Price filter band (US dollars)")
        case "$250 and up": String(localized: "$250 and up", comment: "Price filter band (US dollars)")
        default: name
        }
    }
}

/// Reading colour and size off variant titles.
enum ProductFacets {
    /// Colour families, the way a shopper thinks of them: "navy", "royal blue"
    /// and "baby blue" are all Blues.
    private static let colorFamilies: [(family: String, words: [String])] = [
        ("Black", ["black", "jet", "onyx", "noir"]),
        ("White", ["white", "ivory", "cream", "off white", "ecru"]),
        ("Greys", ["grey", "gray", "charcoal", "slate", "graphite", "ash"]),
        ("Blues", ["blue", "navy", "denim", "teal", "turquoise", "indigo", "cobalt", "aqua"]),
        ("Greens", ["green", "olive", "sage", "mint", "emerald", "lime", "forest", "khaki"]),
        ("Reds", ["red", "burgundy", "maroon", "wine", "crimson", "scarlet", "rust"]),
        ("Pinks", ["pink", "rose", "blush", "fuchsia", "magenta", "coral"]),
        ("Purples", ["purple", "lavender", "lilac", "violet", "plum", "mauve"]),
        ("Oranges", ["orange", "peach", "apricot", "terracotta", "copper"]),
        ("Yellows", ["yellow", "mustard", "lemon", "butter"]),
        ("Browns", ["brown", "chocolate", "coffee", "mocha", "espresso", "caramel", "tan", "taupe", "camel"]),
        ("Beige", ["beige", "nude", "sand", "oat", "bone", "natural"]),
        ("Golds", ["gold", "brass", "bronze"]),
        ("Silvers", ["silver", "platinum", "chrome", "steel"]),
        ("Multi", ["multi", "rainbow", "assorted", "print", "floral", "tie dye", "animal"]),
    ]

    /// Letter sizes in the order a rail hangs them, then numbers by value.
    private static let sizeOrder: [String] = ["One size", "XXS", "XS", "S", "M", "L", "XL", "2XL", "3XL", "4XL", "5XL"]
    private static let letterSizes: [String: String] = [
        "one size": "One size", "os": "One size", "onesize": "One size", "o/s": "One size",
        "free size": "One size", "universal": "One size",
        "xxs": "XXS", "xxsmall": "XXS",
        "xs": "XS", "x small": "XS", "xsmall": "XS", "extra small": "XS",
        "s": "S", "small": "S",
        "m": "M", "medium": "M",
        "l": "L", "large": "L",
        "xl": "XL", "x large": "XL", "xlarge": "XL", "extra large": "XL",
        "xxl": "2XL", "2x": "2XL", "2xl": "2XL", "xx large": "2XL",
        "xxxl": "3XL", "3x": "3XL", "3xl": "3XL",
        "xxxxl": "4XL", "4x": "4XL", "4xl": "4XL",
        "5x": "5XL", "5xl": "5XL",
    ]

    /// One word to its family, built once from the table above. A department of
    /// four thousand garments carries tens of thousands of variant words, and
    /// searching each one for all sixty-odd colour names took seconds; a
    /// dictionary lookup per word takes none.
    private static let colorByWord: [String: String] = {
        var out: [String: String] = [:]
        for (family, words) in colorFamilies {
            for w in words where !w.contains(" ") { out[w] = family }
        }
        return out
    }()
    private static let colorByPhrase: [(phrase: String, family: String)] = colorFamilies
        .flatMap { family, words in words.filter { $0.contains(" ") }.map { (phrase: $0, family: family) } }

    static func rank(_ size: String) -> Int {
        if let i = sizeOrder.firstIndex(of: size) { return i }
        // Numeric sizes sort after letters, by value.
        return 100 + Int(Double(size.filter { $0.isNumber || $0 == "." }) ?? 0)
    }

    /// Each product's variant titles are read at most once and remembered.
    ///
    /// Indexing the whole catalog up front was the obvious alternative and the
    /// wrong one: it added half a second to the background pass that every
    /// launch waits on, to answer a question most sessions never ask. Filters
    /// open long after launch, so the work belongs there. SwiftUI bodies run on
    /// the main actor, which is what keeps these dictionaries safe without a
    /// lock.
    @MainActor private static var colorCache: [String: Set<String>] = [:]
    @MainActor private static var sizeCache: [String: Set<String>] = [:]

    /// A replacement catalog can reuse a product id for something else.
    @MainActor static func reset() {
        colorCache = [:]
        sizeCache = [:]
    }

    /// Each part of every variant title, lowercased. "Black / Large" -> black, large.
    /// The catalog ships these ready-made for products with choices, whose
    /// variants it no longer carries.
    private static func parts(_ p: Product) -> [String] {
        if let opts = p.opts, !opts.isEmpty { return opts }
        return p.variants.flatMap { v -> [String] in
            guard !v.isDefault else { return [] }
            return v.title.split(separator: "/").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
    }

    @MainActor static func colors(_ p: Product) -> Set<String> {
        if let hit = colorCache[p.id] { return hit }
        let out = computeColors(p)
        colorCache[p.id] = out
        return out
    }

    /// The family a colour word belongs to ("blush" -> Pinks; "blues" too),
    /// for a colour word in a search.
    static func family(ofWord w: String) -> String? {
        if let family = colorByWord[w] { return family }
        return w.count > 3 && w.hasSuffix("s") ? colorByWord[String(w.dropLast())] : nil
    }

    /// `colors(_:)` without the cache, for search, which can run off the main
    /// actor (Siri, Shortcuts).
    static func colorFamilies(_ p: Product) -> Set<String> { computeColors(p) }

    // A title says a colour only with words that mean nothing else: "Shea
    // Butter", "Natural Hair" and "Coffee Mug" aren't colours, though those
    // words are when a brand names a variant ("Butter / M"). Same list as
    // web/src/colors.js.
    private static let titleColorWords: Set<String> = [
        "black", "white", "ivory", "cream", "grey", "gray", "charcoal", "blue", "navy", "teal", "turquoise", "indigo",
        "cobalt", "green", "olive", "emerald", "red", "burgundy", "maroon", "crimson", "scarlet", "pink", "blush",
        "fuchsia", "magenta", "purple", "lavender", "lilac", "violet", "mauve", "orange", "yellow", "mustard", "brown",
        "taupe", "camel", "beige", "gold", "silver", "bronze", "rainbow",
    ]
    // "Black TV Moms Sweatshirt", "Brown Skin Girl": who it's for, not its colour.
    private static let identityWords: Set<String> = [
        "owned", "girl", "girls", "boy", "boys", "woman", "women", "man", "men", "mom", "moms", "mother", "mothers",
        "dad", "dads", "father", "fathers", "tv", "history", "excellence", "love", "joy", "lives", "culture", "power",
        "queen", "queens", "king", "kings", "magic", "business", "kid", "kids", "family", "educator", "educators",
        "teacher", "teachers", "nurse", "nurses", "doctor", "doctors", "art", "artist", "artists", "beauty", "hair",
        "skin", "brilliance", "pride", "is", "sugar", "people", "folk", "folks", "mama", "papa", "sister", "sisters",
        "brother", "brothers", "bride", "cowboy", "cowboys", "santa", "jesus", "barbie",
    ]
    // Departments where a "colour" is a shade, a scent or a flavour, or a
    // book's title.
    private static let noColorDepartments: Set<String> = [
        "books", "music", "grocery", "alcohol", "fragrance", "wellness", "skincare", "household",
    ]

    private static func titleColors(_ title: String) -> Set<String> {
        let words = title.lowercased().replacingOccurrences(of: "rose gold", with: "gold")
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
        var out: Set<String> = []
        for (i, w) in words.enumerated() where titleColorWords.contains(w) {
            if w == "black" || w == "brown", i + 1 < words.count, identityWords.contains(words[i + 1]) { continue }
            if let family = colorByWord[w] { out.insert(family) }
        }
        return out
    }

    private static func computeColors(_ p: Product) -> Set<String> {
        guard !noColorDepartments.contains(p.category) else { return [] }
        // The title too (owner, 2026-10-15): "Exotic Bloom | Metallic Pink
        // Earrings" has no variants, so it was in no colour at all.
        var out = titleColors(p.title)
        for raw in parts(p) where raw.count < 24 {
            // "Rose Gold" is gold, not pink.
            let part = raw.replacingOccurrences(of: "rose gold", with: "gold")
            for (phrase, family) in colorByPhrase where part.contains(phrase) { out.insert(family) }
            for word in part.split(whereSeparator: { !$0.isLetter }) {
                let w = String(word)
                if let family = colorByWord[w] { out.insert(family); continue }
                // "blues" and "greens" are how brands often write them.
                if w.count > 3, w.hasSuffix("s"), let family = colorByWord[String(w.dropLast())] {
                    out.insert(family)
                }
            }
        }
        return out
    }

    @MainActor static func sizes(_ p: Product) -> Set<String> {
        if let hit = sizeCache[p.id] { return hit }
        let out = computeSizes(p)
        sizeCache[p.id] = out
        return out
    }

    private static func computeSizes(_ p: Product) -> Set<String> {
        var out: Set<String> = []
        for part in parts(p) {
            if let letter = letterSizes[part] { out.insert(letter); continue }
            // A bare number is a shoe or ring size; anything longer is a name.
            if part.count <= 4, Double(part) != nil { out.insert(part.uppercased()) }
        }
        return out
    }

}

/// One choice inside a group, with how many products it would leave.
struct FilterOption: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    /// A photo for the option's tile: every group shows its choices as pictures.
    var image: String? = nil
}

/// A few photos per choice, so each tile can show a product that has it and,
/// where the products allow, no two tiles in a group show the same one (Size
/// S, M and L would otherwise all show the first shirt).
struct PhotoPicks {
    private var picks: [String: [(image: String, inStock: Bool)]] = [:]
    /// Enough to step past the photos earlier tiles took; few enough that a
    /// four-thousand-product department costs nothing to tally.
    static let depth = 6

    mutating func offer(_ p: Product, _ key: String) {
        guard let image = p.images.first else { return }
        if (picks[key]?.count ?? 0) < Self.depth {
            picks[key, default: []].append((image, p.available))
        } else if p.available, let i = picks[key]!.firstIndex(where: { !$0.inStock }) {
            // Full of sold-out photos: an in-stock one takes a slot.
            picks[key]![i] = (image, true)
        }
    }

    /// Hands out photos down the list in the order shown: the first in-stock
    /// photo no earlier tile used, else any unused one, else a repeat.
    func assign(_ options: [FilterOption]) -> [FilterOption] {
        var used = Set<String>()
        return options.map { o in
            var o = o
            let list = picks[o.id] ?? []
            o.image = list.first { $0.inStock && !used.contains($0.image) }?.image
                ?? list.first { !used.contains($0.image) }?.image
                ?? list.first { $0.inStock }?.image
                ?? list.first?.image
            if let image = o.image { used.insert(image) }
            return o
        }
    }
}

/// Every group's options, counted against the other groups' current choices.
struct FilterFacets {
    var options: [FilterGroup: [FilterOption]] = [:]
    var groups: [FilterGroup] = []

    /// Before the first count finishes there is nothing to list yet.
    init() {}

    /// How many products survive every choice, counted in the same pass.
    var remaining = 0

    /// `brandName` resolves a brand id; the sheet shows names, the filter holds ids.
    ///
    /// Counting each group separately meant nine passes over the products, and
    /// a department holds four thousand of them. Each product is looked at once
    /// instead: its six group verdicts are worked out, and a group's tally
    /// takes the product when the *other* five agree, which is what "ignoring
    /// this group" means.
    @MainActor init(products: [Product], filters: ProductFilters,
                    brandName: (String) -> String?, categoryName: (String) -> String? = { _ in nil },
                    aisleName: (String) -> String? = { _ in nil }) {
        var categories: [String: Int] = [:]
        var aisles: [String: Int] = [:]
        // Photos for every group's tiles (owner, 2026-11-11: "lets have
        // images for all categories for the filters wherever we have a
        // filter pill"): products that pass the group's tally, in-stock first.
        var photos: [FilterGroup: PhotoPicks] = [:]
        var attrPhotos: [String: PhotoPicks] = [:]
        var brands: [String: Int] = [:]
        var prices: [String: Int] = [:]
        var colors: [String: Int] = [:]
        var sizes: [String: Int] = [:]
        var offers: [ProductFilters.Offer: Int] = [:]
        // Brand-said groups: only the ones for this department (AttrFilter).
        let department = AttrFilter.department(of: products, picked: filters.categories)
        let liveFields = AttrFilter.fields.filter {
            guard let spec = AttrFilter.specs[$0] else { return false }
            return spec.anyDepartment || spec.departments.contains(department ?? "")
        }
        let wanted = AttrFilter.fields.compactMap { f in filters.attrs[f].flatMap { $0.isEmpty ? nil : (f, $0) } }
        var attrCounts: [String: [String: Int]] = [:]

        for p in products {
            // Which chosen brand-said groups this product passes; a group's
            // own tally ignores its own choice, as with every other group.
            var failed: String? = nil, failures = 0
            for (f, want) in wanted where want.isDisjoint(with: p.attrs?[f] ?? []) {
                failed = f; failures += 1
            }
            let okAttrs = failures == 0
            let pColors = filters.colors.isEmpty ? [] : ProductFacets.colors(p)
            let pSizes = filters.sizes.isEmpty ? [] : ProductFacets.sizes(p)
            let okBrand = filters.brands.isEmpty || filters.brands.contains(p.brand)
            let okCategory = filters.categories.isEmpty || filters.categories.contains(p.category)
            let okAisle = filters.aisles.isEmpty || ProductFilters.inAisle(p, filters.aisles)
            let okColor = filters.colors.isEmpty || !filters.colors.isDisjoint(with: pColors)
            let okSize = filters.sizes.isEmpty || !filters.sizes.isDisjoint(with: pSizes)
            let okPrice = filters.priceBands.isEmpty || filters.priceBands.contains(PriceBand.band(for: p.usdPrice).name)
            // Stock and sale (Offers) and the quality badges (Badges) are one
            // set of choices shown as two groups; each tallies ignoring its own.
            let okStock = filters.offers.allSatisfy { $0.isBadge || $0.matches(p) }
            let okBadges = filters.offers.allSatisfy { !$0.isBadge || $0.matches(p) }
            let okOffers = okStock && okBadges

            if okAisle && okBrand && okColor && okSize && okPrice && okOffers && okAttrs {
                categories[p.category, default: 0] += 1
                photos[.category, default: PhotoPicks()].offer(p, p.category)
            }
            if okBrand && okCategory && okColor && okSize && okPrice && okOffers && okAttrs {
                for a in Set(ProductFilters.aisleIDs(p)) {
                    aisles[a, default: 0] += 1
                    photos[.aisle, default: PhotoPicks()].offer(p, a)
                }
            }
            if okAisle && okCategory && okColor && okSize && okPrice && okOffers && okAttrs {
                brands[p.brand, default: 0] += 1
                photos[.brand, default: PhotoPicks()].offer(p, p.brand)
            }
            if okAisle && okBrand && okCategory && okColor && okSize && okOffers && okAttrs {
                let band = PriceBand.band(for: p.usdPrice).name
                prices[band, default: 0] += 1
                photos[.price, default: PhotoPicks()].offer(p, band)
            }
            if okAisle && okBrand && okCategory && okSize && okPrice && okOffers && okAttrs {
                for c in ProductFacets.colors(p) {
                    colors[c, default: 0] += 1
                    photos[.color, default: PhotoPicks()].offer(p, c)
                }
            }
            if okAisle && okBrand && okCategory && okColor && okPrice && okOffers && okAttrs {
                for z in ProductFacets.sizes(p) {
                    sizes[z, default: 0] += 1
                    photos[.size, default: PhotoPicks()].offer(p, z)
                }
            }
            if okAisle && okBrand && okCategory && okColor && okSize && okPrice && okAttrs {
                for offer in ProductFilters.Offer.allCases where (offer.isBadge ? okStock : okBadges) && offer.matches(p) {
                    offers[offer, default: 0] += 1
                    // A badge tile is the badge itself, not a product photo.
                    if !offer.isBadge { photos[.offers, default: PhotoPicks()].offer(p, offer.rawValue) }
                }
            }
            if okAisle && okBrand && okCategory && okColor && okSize && okPrice && okOffers, let a = p.attrs {
                for f in liveFields where failures == 0 || (failures == 1 && failed == f) {
                    for v in a[f] ?? [] where AttrFilter.applies(f, v, department: department) {
                        attrCounts[f, default: [:]][v, default: 0] += 1
                        attrPhotos[f, default: PhotoPicks()].offer(p, v)
                    }
                }
            }
            if okAisle && okBrand && okCategory && okColor && okSize && okPrice && okOffers && okAttrs { remaining += 1 }
        }

        options[.category] = categories
            .map { FilterOption(id: $0.key, name: categoryName($0.key) ?? $0.key.capitalized, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        options[.aisle] = aisles
            .compactMap { a in aisleName(a.key).map { FilterOption(id: a.key, name: $0, count: a.value) } }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        options[.brand] = brands
            .map { FilterOption(id: $0.key, name: brandName($0.key) ?? $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        options[.price] = PriceBand.all
            .compactMap { band in prices[band.name].map { FilterOption(id: band.name, name: PriceBand.title(band.name), count: $0) } }
        options[.color] = colors
            .map { FilterOption(id: $0.key, name: FacetLabel.color($0.key), count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        options[.size] = sizes
            .map { FilterOption(id: $0.key, name: FacetLabel.size($0.key), count: $0.value) }
            .sorted { ProductFacets.rank($0.id) < ProductFacets.rank($1.id) }
        options[.offers] = ProductFilters.Offer.allCases.filter { !$0.isBadge }
            .compactMap { o in (offers[o] ?? 0) > 0 ? FilterOption(id: o.rawValue, name: o.title, count: offers[o]!) : nil }
        // Badges by how many products carry them.
        options[.badges] = ProductFilters.Offer.allCases.filter(\.isBadge)
            .compactMap { o in (offers[o] ?? 0) > 0 ? FilterOption(id: o.rawValue, name: o.title, count: offers[o]!) : nil }
            .sorted { $0.count > $1.count }

        for g in FilterGroup.allCases {
            guard let f = g.attrField, let counts = attrCounts[f] else { continue }
            options[g] = (attrPhotos[f] ?? PhotoPicks()).assign(counts
                .map { FilterOption(id: $0.key, name: AttrFilter.label(f, $0.key), count: $0.value) }
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) })
        }
        for (g, picks) in photos { options[g] = options[g].map(picks.assign) }

        // A group with one choice narrows nothing, so it doesn't earn a row;
        // a brand-said group does with one, since most products don't carry it.
        // Badges too: most products carry none, so even one narrows the list.
        groups = FilterGroup.allCases.filter { (options[$0]?.count ?? 0) > ($0.attrField == nil && $0 != .badges ? 1 : 0) }
    }
}

/// What a colour or size facet reads as. The English name stays the id (it is
/// matched against variant titles); only the label is localized.
enum FacetLabel {
    static func color(_ name: String) -> String {
        switch name {
        case "Black": String(localized: "Black", comment: "Colour filter option (a colour, not a person)")
        case "White": String(localized: "White", comment: "Colour filter option (a colour, not a person)")
        case "Greys": String(localized: "Greys", comment: "Colour filter option: grey shades")
        case "Blues": String(localized: "Blues", comment: "Colour filter option: blue shades")
        case "Greens": String(localized: "Greens", comment: "Colour filter option: green shades")
        case "Reds": String(localized: "Reds", comment: "Colour filter option: red shades")
        case "Pinks": String(localized: "Pinks", comment: "Colour filter option: pink shades")
        case "Purples": String(localized: "Purples", comment: "Colour filter option: purple shades")
        case "Oranges": String(localized: "Oranges", comment: "Colour filter option: orange shades (the colour)")
        case "Yellows": String(localized: "Yellows", comment: "Colour filter option: yellow shades")
        case "Browns": String(localized: "Browns", comment: "Colour filter option: brown shades")
        case "Beige": String(localized: "Beige", comment: "Colour filter option")
        case "Golds": String(localized: "Golds", comment: "Colour filter option: gold shades")
        case "Silvers": String(localized: "Silvers", comment: "Colour filter option: silver shades")
        case "Multi": String(localized: "Multi", comment: "Colour filter option: multicoloured")
        default: name
        }
    }
    static func size(_ name: String) -> String {
        name == "One size" ? String(localized: "One size", comment: "Size filter option: a single size fits all") : name
    }
}

/// The colour dot Amazon puts on its colour chips.
private let swatches: [String: Color] = [
    "Black": .black, "White": Color(white: 0.96), "Greys": Color(white: 0.55),
    "Blues": Color(red: 0.16, green: 0.38, blue: 0.79), "Greens": Color(red: 0.24, green: 0.6, blue: 0.31),
    "Reds": Color(red: 0.79, green: 0.18, blue: 0.20), "Pinks": Color(red: 0.90, green: 0.40, blue: 0.62),
    "Purples": Color(red: 0.51, green: 0.31, blue: 0.75), "Oranges": Color(red: 0.90, green: 0.49, blue: 0.16),
    "Yellows": Color(red: 0.93, green: 0.79, blue: 0.20), "Browns": Color(red: 0.42, green: 0.28, blue: 0.18),
    "Beige": Color(red: 0.87, green: 0.79, blue: 0.66), "Golds": Color(red: 0.83, green: 0.68, blue: 0.22),
    "Silvers": Color(white: 0.75), "Multi": Color(red: 0.55, green: 0.55, blue: 0.85),
]

// MARK: - The sheet

/// Groups down the left, their choices on the right, and every button at the
/// bottom by the thumb: Clear all, Show N results, ✕ (owner, 2026-11-10,
/// picked "A shorter sheet": it rises two-thirds of the way; pull it up for
/// the rest).
struct FilterSheet: View {
    let products: [Product]
    @Binding var filters: ProductFilters
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var group: FilterGroup?
    /// Edited in the sheet, handed back only when the shopper says so, so a
    /// half-made choice never reshuffles the grid behind them.
    @State private var draft = ProductFilters()
    /// Counting every group against every product is the expensive part, so it
    /// runs once per choice rather than once per redraw.
    @State private var facets = FilterFacets()
    @State private var remaining = 0
    /// The pixel width the tiles ask for, shared with the prefetch so it hits.
    private static let tileWidth = 240

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                rail(facets)
                Divider()
                pane(facets)
            }
            .task(id: draft) {
                facets = FilterFacets(products: products, filters: draft,
                                      brandName: { catalog.brand($0)?.name },
                                      categoryName: { catalog.category($0)?.name },
                                      aisleName: { catalog.subcategory($0)?.name })
                remaining = facets.remaining
                // Every group's tile photos start as the sheet opens, so
                // moving from Category to Size finds them loaded, not blank.
                ImageLoader.shared.prefetch(facets.groups.flatMap { facets.options[$0] ?? [] }
                    .compactMap { sizedImageURL($0.image, width: Self.tileWidth) })
                if let g = group, facets.groups.contains(g) { return }
                group = facets.groups.first
            }
            .background(Theme.canvas)
            .safeAreaInset(edge: .bottom) { footer(remaining) }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.fraction(0.7), .large])
        .presentationDragIndicator(.visible)
        .onAppear { draft = filters }
        .accessibilityIdentifier("filterSheet")
    }

    private func rail(_ facets: FilterFacets) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(facets.groups) { g in
                    Button { group = g } label: {
                        HStack(spacing: 4) {
                            Text(g.title)
                                .font(.subheadline.weight(group == g ? .semibold : .regular))
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(group == g ? Theme.link : Color.primary)
                            if count(of: g) > 0 {
                                Text("\(count(of: g))")
                                    .font(.caption2.bold()).foregroundStyle(Color.black)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.gold))
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(group == g ? Theme.field : Color.clear)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(group == g ? Theme.link : Color.clear).frame(width: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filterGroup")
                }
            }
        }
        .frame(width: 128)
        .background(Theme.surface)
    }

    private func count(of g: FilterGroup) -> Int {
        if let f = g.attrField { return draft.attrs[f]?.count ?? 0 }
        switch g {
        case .category: return draft.categories.count
        case .aisle: return draft.aisles.count
        case .brand: return draft.brands.count
        case .price: return draft.priceBands.count
        case .color: return draft.colors.count
        case .size: return draft.sizes.count
        case .offers: return draft.offers.filter { !$0.isBadge }.count
        case .badges: return draft.offers.filter(\.isBadge).count
        default: return 0
        }
    }

    @ViewBuilder
    private func pane(_ facets: FilterFacets) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let group {
                    // Every group as photos, three across: Type first (owner,
                    // 2026-11-08, picked "Filter 5" from previews), Category
                    // (2026-11-09), then the rest (2026-11-11: "lets have
                    // images for all categories for the filters wherever we
                    // have a filter pill").
                    Text(group.title).font(.title3.bold())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 14) {
                        ForEach(facets.options[group] ?? []) { option in
                            typeTile(option)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One choice in a group's grid: its photo, then its name and count.
    /// Aisles drop the tail of "Pants & Trousers"; everything else keeps its
    /// whole name ("Candles & Home", "$50 to $100"). A colour wears its
    /// swatch on the photo; a choice with no photo shows the swatch, or the
    /// plain tile.
    private func typeTile(_ option: FilterOption) -> some View {
        let on = selected(option)
        let badge = group == .badges ? ProductFilters.Offer(rawValue: option.id) : nil
        let short = group == .aisle ? (option.name.components(separatedBy: " & ").first ?? option.name)
            : (badge?.shortTitle ?? option.name)
        let swatch = group == .color ? swatches[option.id] : nil
        return Button { toggle(option) } label: {
            VStack(spacing: 5) {
                Group {
                    if let look = badge?.tile {
                        BadgeTypeTile(color: look.color, symbol: look.symbol, kicker: look.kicker, word: look.word)
                    } else if option.image == nil, let swatch {
                        RoundedRectangle(cornerRadius: 6).fill(swatch).aspectRatio(1, contentMode: .fit)
                    } else {
                        ProductImageWell(url: option.image, width: Self.tileWidth, padding: 0)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let swatch, option.image != nil {
                        Circle().fill(swatch).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .padding(5)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(on ? Color.white : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if on {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.body).foregroundStyle(.black, .white)
                            .padding(4)
                    }
                }
                Text(short).font(.caption.weight(on ? .semibold : .regular)).lineLimit(3)
                    .multilineTextAlignment(.center)
                Text("\(option.count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(option.name), \(option.count)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("filterOption")
    }

    private func selected(_ o: FilterOption) -> Bool {
        guard let group else { return false }
        if let f = group.attrField { return draft.attrs[f]?.contains(o.id) ?? false }
        switch group {
        case .category: return draft.categories.contains(o.id)
        case .aisle: return draft.aisles.contains(o.id)
        case .brand: return draft.brands.contains(o.id)
        case .price: return draft.priceBands.contains(o.id)
        case .color: return draft.colors.contains(o.id)
        case .size: return draft.sizes.contains(o.id)
        case .offers, .badges: return ProductFilters.Offer(rawValue: o.id).map { draft.offers.contains($0) } ?? false
        default: return false
        }
    }

    private func toggle(_ o: FilterOption) {
        guard let group else { return }
        func flip<T: Hashable>(_ set: inout Set<T>, _ value: T) {
            if set.contains(value) { set.remove(value) } else { set.insert(value) }
        }
        if let f = group.attrField {
            var set = draft.attrs[f] ?? []
            flip(&set, o.id)
            draft.attrs[f] = set.isEmpty ? nil : set
            return
        }
        switch group {
        case .category: flip(&draft.categories, o.id)
        case .aisle: flip(&draft.aisles, o.id)
        case .brand: flip(&draft.brands, o.id)
        case .price: flip(&draft.priceBands, o.id)
        case .color: flip(&draft.colors, o.id)
        case .size: flip(&draft.sizes, o.id)
        case .offers, .badges: if let offer = ProductFilters.Offer(rawValue: o.id) { flip(&draft.offers, offer) }
        default: break
        }
    }

    private func footer(_ remaining: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button("Clear all") { draft.clear() }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .background(Capsule().fill(Theme.field))
                    .foregroundStyle(draft.isEmpty ? Theme.textSecondary : Color.primary)
                    .buttonStyle(.plain)
                    .disabled(draft.isEmpty)
                    .accessibilityIdentifier("filtersClear")
                Button {
                    // A steady Women or Men choice steers the shopper's picks (GenderLean).
                    if TasteProfile.shared.enabled, let g = draft.attrs["gender"], g != filters.attrs["gender"] { GenderLean.record(g) }
                    filters = draft
                    dismiss()
                } label: {
                    Text(remaining == 1 ? "Show 1 result" : "Show \(remaining) results")
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(color: Theme.gold))
                .disabled(remaining == 0)
                .accessibilityIdentifier("filtersApply")
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Theme.field))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("filtersClose")
            }
            .padding(12)
        }
        .background(Theme.surface)
    }
}

/// Chips wrap onto as many rows as they need, each keeping its own width.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let rows = layout(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in layout(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                                           proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row { var y: CGFloat; var height: CGFloat; var items: [(index: Int, x: CGFloat, size: CGSize)] }

    private func layout(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(y: 0, height: 0, items: [])
        var x: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(current)
                x = 0
                current = Row(y: current.y + current.height + spacing, height: 0, items: [])
            }
            current.items.append((i, x, size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Nothing badged here

/// What an aisle shows when Marracat Clean is on and nothing there carries the
/// badge: why, and a way back.
struct CleanEmptyState: View {
    @Binding var filters: ProductFilters

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.shield").font(.largeTitle).foregroundStyle(Theme.clean)
            Text("No Marracat Clean products here yet").font(.headline)
            Text("The badge covers hair care, skincare, makeup, face and body washes, and candles whose brands publish what's in them.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Show everything") { filters.offers.remove(.clean) }
                .buttonStyle(PillButtonStyle(color: Theme.gold))
                .accessibilityIdentifier("cleanEmptyShowAll")
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cleanEmptyState")
    }
}

// MARK: - The pill by the thumb

/// Filters and Sort as one light pill (owner, 2026-11-10, picked "Two pills by
/// your thumb" for brand pages): floats above the tab bar, where the thumb
/// is. Everything else, departments and the quality labels included, is in
/// Filters.
struct FilterPill: View {
    @Binding var filters: ProductFilters
    /// Opens the Filters sheet (BottomFilters presents it).
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filters").font(.subheadline.weight(.semibold))
                    if filters.activeCount > 0 {
                        Text("\(filters.activeCount)")
                            .font(.caption2.bold()).foregroundStyle(Color.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.black))
                    }
                }
                .padding(.leading, 18).padding(.trailing, 16).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("filtersButton")

            Rectangle().fill(Color.black.opacity(0.14)).frame(width: 1, height: 26)

            Menu {
                Picker("Sort by", selection: $filters.sort) {
                    ForEach(ProductSort.allCases) { Text($0.shortName).tag($0) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(filters.sort != .featured ? filters.sort.shortName : String(localized: "Sort", comment: "Button that opens the sort order menu"))
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.leading, 16).padding(.trailing, 18).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("sortButton")
        }
        .foregroundStyle(Color.black)
        .background(Capsule().fill(Color(white: 0.95)))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }
}

// MARK: - The bar above the results

/// The Filters button, plus a chip for each choice already made so it can be
/// undone without opening the sheet again.
struct FilterBar: View {
    let products: [Product]
    @Binding var filters: ProductFilters
    @Environment(CatalogStore.self) private var catalog
    @State private var showSheet = false

    /// The server's name for each switch (EVENTS.md, filter_apply).
    static let offerFilterNames: [ProductFilters.Offer: String] = [
        .inStock: "in_stock", .onSale: "sale", .clean: "clean", .trueMetal: "metal", .clearScent: "scent",
        .saferClean: "safer", .cleanFood: "food", .babySafe: "baby", .naturalFiber: "fiber", .safeFabric: "fabric",
        .labVerified: "lab", .petSafe: "pet", .trueMaterial: "material", .naturalHome: "home",
    ]

    /// What changed, as (filter, value) pairs in the server's vocabulary for
    /// filter_apply: switches go "on"/"off", brands and categories send the id
    /// they added, sort sends featured/low/high/new. Colors, sizes and the
    /// other price bands have no server name and aren't sent.
    static func changes(from old: ProductFilters, to new: ProductFilters) -> [(filter: String, value: String)] {
        var out: [(String, String)] = []
        for (name, a, b) in [("brand", old.brands, new.brands), ("category", old.categories, new.categories)] {
            for v in b.subtracting(a).sorted() { out.append((name, v.lowercased())) }
        }
        for offer in ProductFilters.Offer.allCases {
            guard let name = offerFilterNames[offer], old.offers.contains(offer) != new.offers.contains(offer) else { continue }
            out.append((name, new.offers.contains(offer) ? "on" : "off"))
        }
        let under25 = PriceBand.all[0].name
        if old.priceBands.contains(under25) != new.priceBands.contains(under25) {
            out.append(("under_25", new.priceBands.contains(under25) ? "on" : "off"))
        }
        if old.sort != new.sort {
            let sort = switch new.sort { case .featured: "featured"; case .newest: "new"; case .priceLow: "low"; case .priceHigh: "high" }
            out.append(("sort", sort))
        }
        return out
    }

    /// Every list's filter changes pass through here, so it also keeps a
    /// price sort for the next list (SortPreference).
    static func track(from old: ProductFilters, to new: ProductFilters) {
        if old.sort != new.sort { SortPreference.record(new.sort) }
        for c in changes(from: old, to: new).prefix(10) {
            Analytics.shared.track("filter_apply", ["filter": .string(c.filter), "value": .string(String(c.value.prefix(80)))])
        }
    }

    var body: some View {
        bar.onChange(of: filters) { old, new in Self.track(from: old, to: new) }
    }

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                Button { showSheet = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Filters").font(.subheadline.weight(.semibold))
                        if filters.activeCount > 0 {
                            Text("\(filters.activeCount)")
                                .font(.caption2.bold()).foregroundStyle(Color.black)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.gold))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.field))
                    .overlay(Capsule().stroke(Theme.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filtersButton")

                sortButton
                // Choices already made come first, on screen where they can be
                // undone; the Clean toggle after them would push them off the edge.
                ForEach(activeChips, id: \.label) { chip in
                    activeChip(chip.label, remove: chip.remove)
                }
                // Only where something listed is Marracat Clean (owner,
                // 2026-10-04), and while it's on, so it can be turned off.
                if filters.offers.contains(.clean) || products.contains(where: \.isMarracatClean) {
                    cleanToggle
                }
                // The same for jewelry: only where something listed is True Metal.
                if filters.offers.contains(.trueMetal) || products.contains(where: \.isMarracatTrueMetal) {
                    labelToggle(.trueMetal, icon: "seal.fill", color: Theme.metal, id: "trueMetalToggle")
                }
                // …for fragrance (Clear Scent) and household cleaners (Safer Clean).
                if filters.offers.contains(.clearScent) || products.contains(where: \.isMarracatClearScent) {
                    labelToggle(.clearScent, icon: "drop.fill", color: Theme.scent, id: "clearScentToggle")
                }
                if filters.offers.contains(.saferClean) || products.contains(where: \.isMarracatSaferClean) {
                    labelToggle(.saferClean, icon: "leaf.fill", color: Theme.saferClean, id: "saferCleanToggle")
                }
                // …for groceries (Clean Food) and baby products (Baby Safe).
                if filters.offers.contains(.cleanFood) || products.contains(where: \.isMarracatCleanFood) {
                    labelToggle(.cleanFood, icon: "carrot.fill", color: Theme.cleanFood, id: "cleanFoodToggle")
                }
                if filters.offers.contains(.babySafe) || products.contains(where: \.isMarracatBabySafe) {
                    labelToggle(.babySafe, icon: "heart.fill", color: Theme.babySafe, id: "babySafeToggle")
                }
                // …and for clothing (Natural Fiber, Safe Fabric).
                if filters.offers.contains(.naturalFiber) || products.contains(where: \.isMarracatNaturalFiber) {
                    labelToggle(.naturalFiber, icon: "tshirt.fill", color: Theme.naturalFiber, id: "naturalFiberToggle")
                }
                if filters.offers.contains(.safeFabric) || products.contains(where: \.isMarracatSafeFabric) {
                    labelToggle(.safeFabric, icon: "checkmark.shield.fill", color: Theme.safeFabric, id: "safeFabricToggle")
                }
                // …and for wellness, pets, bags and home.
                if filters.offers.contains(.labVerified) || products.contains(where: \.isMarracatLabVerified) {
                    labelToggle(.labVerified, icon: "flask.fill", color: Theme.labVerified, id: "labVerifiedToggle")
                }
                if filters.offers.contains(.petSafe) || products.contains(where: \.isMarracatPetSafe) {
                    labelToggle(.petSafe, icon: "pawprint.fill", color: Theme.petSafe, id: "petSafeToggle")
                }
                if filters.offers.contains(.trueMaterial) || products.contains(where: \.isMarracatTrueMaterial) {
                    labelToggle(.trueMaterial, icon: "bag.fill", color: Theme.trueMaterial, id: "trueMaterialToggle")
                }
                if filters.offers.contains(.naturalHome) || products.contains(where: \.isMarracatNaturalHome) {
                    labelToggle(.naturalHome, icon: "house.fill", color: Theme.naturalHome, id: "naturalHomeToggle")
                }
            }
            .padding(.horizontal, 12)
        }
        .sheet(isPresented: $showSheet) {
            FilterSheet(products: products, filters: $filters)
        }
    }

    /// Sorting reorders what is already there, so it gets its own control
    /// rather than a row buried in the sheet.
    private var sortButton: some View {
        let on = filters.sort != .featured
        return Menu {
            Picker("Sort by", selection: $filters.sort) {
                ForEach(ProductSort.allCases) { Text($0.shortName).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text(on ? filters.sort.shortName : String(localized: "Sort", comment: "Button that opens the sort order menu")).font(.subheadline.weight(on ? .semibold : .regular))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(on ? Color.white : Theme.field))
            .foregroundStyle(on ? Color.black : Color.primary)
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: on ? 0 : 1))
        }
        .accessibilityIdentifier("sortButton")
    }

    /// One tap to see only Marracat Clean products. It is the same choice as
    /// Offers › Marracat Clean in the sheet, surfaced where shoppers look.
    private var cleanToggle: some View {
        let on = filters.offers.contains(.clean)
        return Button {
            if on { filters.offers.remove(.clean) } else { filters.offers.insert(.clean) }
        } label: {
            // Just the shield, the same mark the badge carries; VoiceOver
            // still hears "Marracat Clean only".
            Image(systemName: "checkmark.shield.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.white : Theme.clean)
                .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(on ? Theme.clean : Theme.field))
            .foregroundStyle(on ? Color.white : Color.primary)
            .overlay(Capsule().stroke(on ? Theme.clean : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Marracat Clean only")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("cleanToggle")
    }

    /// One tap to see only products carrying one of the quality labels (True
    /// Metal, Clear Scent, Safer Clean, Clean Food, Baby Safe, Natural Fiber, Safe Fabric, Lab Verified,
    /// Pet Safe, True Material, Natural Home), beside the Clean shield: the badge's
    /// own mark, filled when on.
    private func labelToggle(_ offer: ProductFilters.Offer, icon: String, color: Color, id: String) -> some View {
        let on = filters.offers.contains(offer)
        return Button {
            if on { filters.offers.remove(offer) } else { filters.offers.insert(offer) }
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.black : color)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(on ? color : Theme.field))
                .overlay(Capsule().stroke(on ? color : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(offer.title) only")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var activeChips: [(label: String, remove: () -> Void)] {
        var out: [(String, () -> Void)] = []
        for id in filters.categories.sorted() {
            out.append((catalog.category(id)?.name ?? id.capitalized, { filters.categories.remove(id) }))
        }
        for id in filters.aisles.sorted() {
            out.append((catalog.subcategory(id)?.name ?? id, { filters.aisles.remove(id) }))
        }
        for id in filters.brands.sorted() {
            out.append((catalog.brand(id)?.name ?? id, { filters.brands.remove(id) }))
        }
        for band in filters.priceBands.sorted() { out.append((PriceBand.title(band), { filters.priceBands.remove(band) })) }
        for f in AttrFilter.fields {
            for v in (filters.attrs[f] ?? []).sorted() {
                out.append((AttrFilter.label(f, v), {
                    filters.attrs[f]?.remove(v)
                    if filters.attrs[f]?.isEmpty == true { filters.attrs[f] = nil }
                }))
            }
        }
        for c in filters.colors.sorted() { out.append((FacetLabel.color(c), { filters.colors.remove(c) })) }
        for s in filters.sizes.sorted(by: { ProductFacets.rank($0) < ProductFacets.rank($1) }) {
            out.append((FacetLabel.size(s), { filters.sizes.remove(s) }))
        }
        for o in filters.offers.sorted(by: { $0.rawValue < $1.rawValue }) where ![.clean, .trueMetal, .clearScent, .saferClean, .cleanFood, .babySafe, .naturalFiber, .safeFabric, .labVerified, .petSafe,
                                                                                .trueMaterial, .naturalHome].contains(o) {
            out.append((o.title, { filters.offers.remove(o) }))
        }
        return out.map { (label: $0.0, remove: $0.1) }
    }

    private func activeChip(_ label: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Text(label).font(.subheadline.weight(.semibold))
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Capsule().fill(Color.white))
            .foregroundStyle(Color.black)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activeFilterChip")
    }
}

/// A badge as a filter tile, the "Type-led" look (owner, 2026-11-11, picked
/// from five previews): a soft block of the badge colour, "MARRACAT" and the
/// badge's symbol along the top, and its name set big and heavy beneath, in
/// a deep shade of the same colour.
struct BadgeTypeTile: View {
    let color: Color
    let symbol: String
    let kicker: String
    let word: String

    var body: some View {
        let ground = Self.mix(color, toward: .white, 0.72)
        let ink = Self.mix(color, toward: .black, 0.55)
        let lines = word.split(separator: " ").map(String.init)
        let longest = lines.map(\.count).max() ?? 0
        GeometryReader { box in
            let w = box.size.width
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Text(verbatim: kicker)
                        .font(.system(size: w * 0.085, weight: .bold))
                        .tracking(w * 0.016)
                        .foregroundStyle(ink.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Image(systemName: symbol)
                        .font(.system(size: w * 0.15, weight: .semibold))
                        .foregroundStyle(ink)
                }
                Spacer(minLength: 0)
                Text(verbatim: lines.joined(separator: "\n"))
                    .font(.system(size: w * (longest <= 7 ? 0.19 : longest <= 9 ? 0.155 : 0.135), weight: .black))
                    .foregroundStyle(ink)
                    .lineSpacing(-w * 0.02)
                    .lineLimit(lines.count)
                    .minimumScaleFactor(0.5)
            }
            .padding(w * 0.1)
            .frame(width: w, height: w, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(ground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }

    /// `color` moved `amount` of the way to `target` (0 = unchanged).
    static func mix(_ color: Color, toward target: UIColor, _ amount: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        return Color(red: r + (tr - r) * amount, green: g + (tg - g) * amount, blue: b + (tb - b) * amount)
    }
}
