import Foundation

/// The bundled product catalog, built by `catalog/build_catalog.py` from each
/// brand's public Shopify feed. Keys are snake_case on disk.
struct Catalog: Codable {
    var generatedAt: String
    var categories: [Category]
    /// The aisles inside each category — "Face Wash & Cleansers", "Bras &
    /// Bralettes" — from catalog/taxonomy.py. Only ones holding products ship.
    var subcategories: [Subcategory]
    var brands: [Brand]
    var products: [Product]
}

struct Subcategory: Codable, Identifiable, Hashable {
    /// "skincare:cleanser" — the parent category, then the aisle.
    var id: String
    let name: String
    var category: String
}

struct Category: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
}

struct Brand: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let domain: String
    let category: String
    let tagline: String?
    let shopify: Bool
    /// Which storefront the brand runs. Shopify takes a prefilled cart
    /// permalink; WooCommerce 10+ takes a shareable checkout link.
    let platform: String?
    /// A curated product photo, or the website's share image when the brand's
    /// products couldn't be imported.
    let image: String?

    var currency: String? = nil
    var currencyCode: String { currency ?? "USD" }
    /// Dollars per one unit of `currency`, stamped when the catalog is built
    /// (catalog/fx.py); nil for dollar brands.
    var usdRate: Double? = nil
    /// The store's UCP checkout endpoint (catalog/ucp_endpoints.py), when it
    /// has one: where a checkout filled in from the app's saved details is built.
    var ucp: String? = nil
    var ucpEndpoint: URL? { ucp.flatMap(URL.init) }
    /// "ucp" for a store whose cart permalink doesn't reach a checkout (Telfar's
    /// lands on its home page) but whose UCP checkout does: Buy Now and the
    /// cart send it through the review screen instead.
    var checkout: String? = nil
    var checksOutByUCP: Bool { checkout == "ucp" && ucpEndpoint != nil }
    /// Where the brand ships from, when that's outside the US: africa,
    /// europe, canada, caribbean or elsewhere (catalog/ships_from.py).
    var shipsFrom: String? = nil
    /// The account the brand's own website links to (catalog/instagram_handles.py);
    /// nil when the site links none, and then the brand page shows no button.
    var instagram: String? = nil
    var instagramURL: URL? {
        guard let h = instagram, h.range(of: #"^[A-Za-z0-9._]{2,30}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://www.instagram.com/\(h)/")
    }
    /// "Ships from Africa", so a shopper expects an international parcel
    /// (owner, 2026-10-14); nil for US brands.
    var shipsFromLabel: String? {
        switch shipsFrom {
        case "africa": String(localized: "Ships from Africa", comment: "Brand or product: the parcel comes from a brand based in Africa")
        case "europe": String(localized: "Ships from Europe", comment: "Brand or product: the parcel comes from a brand based in Europe")
        case "canada": String(localized: "Ships from Canada", comment: "Brand or product: the parcel comes from a brand based in Canada")
        case "caribbean": String(localized: "Ships from the Caribbean", comment: "Brand or product: the parcel comes from a brand based in the Caribbean")
        case "elsewhere": String(localized: "Ships internationally", comment: "Brand or product: the parcel comes from outside the US")
        default: nil
        }
    }

    var storeURL: URL { URL(string: "https://\(domain)")! }
    var isShopify: Bool { (platform ?? "shopify") == "shopify" }
    /// "link" for a WooCommerce store whose shareable checkout link
    /// (`/checkout-link/?products=ID:QTY,…`, WooCommerce 10.0+) was verified
    /// to land on its own checkout with the items in the cart.
    var checksOutByWooLink: Bool { platform == "woocommerce" && checkout == "link" }
    /// "add" for an older WooCommerce store (before 10.0) whose classic
    /// `?add-to-cart=ID&quantity=N` was verified: it takes one product per
    /// request, so the checkout sheet adds each line in turn, then opens checkout.
    var checksOutByWooAddToCart: Bool { platform == "woocommerce" && checkout == "add" }
    /// A Big Cartel store (owner, 2026-10-04): its cart takes one item per
    /// form post (cart[add][id] = the option's id), so the checkout sheet posts
    /// each line, then opens its checkout.
    var checksOutByBigCartel: Bool { platform == "bigcartel" }
    /// Big Cartel's own host for the store; its cart and checkout live there
    /// even when the shop shows a custom domain.
    var bigcartel: String? = nil
    var bigCartelHost: String { "\(bigcartel ?? String(domain.split(separator: ".").first ?? ""))" + ".bigcartel.com" }
    /// A Swell store (owner, 2026-10-10: Yeezy first): marracat.com/go/swell
    /// builds the cart with Swell's storefront API and redirects to the
    /// brand's own checkout holding it (web/server/swell.js).
    var checksOutBySwell: Bool { platform == "swell" }
    /// Its products go in the Marracat cart and Buy Now opens its checkout
    /// filled in; anything else opens the product on the brand's site.
    var usesMarracatCart: Bool { isShopify || checksOutByWooLink || checksOutByWooAddToCart || checksOutByBigCartel || checksOutBySwell }
}

struct Variant: Codable, Identifiable, Hashable {
    let id: Int64
    var title: String
    var price: Double
    var compareAt: Double?
    var available: Bool
    /// Which of the product's full photo list (the product page's fetch, not
    /// the bundled first photo) shows this colour: the store's own pick
    /// (Shopify's variant image). Nil when the store didn't set one.
    var image: Int? = nil

    /// Shopify names the only variant of a single-option product "Default Title".
    var isDefault: Bool { title == "Default Title" }
}

struct Product: Codable, Identifiable, Hashable {
    let id: String
    var brand: String
    let title: String
    // var: FreshCatalog lays a store's live copy over the catalog's (and
    // places a new arrival in its brand's department).
    var category: String
    var productType: String?
    /// Aisles this product was linked to, strongest first, unqualified by
    /// category ("cleanser"); `Subcategory.id` prefixes them with the category.
    var subs: [String]
    var price: Double
    var compareAt: Double?
    var images: [String]
    var url: String
    var available: Bool
    var variants: [Variant]
    var tags: [String]
    var description: String?
    var publishedAt: String?
    /// Position in the brand's own best-selling order (0 = its top seller);
    /// nil when the store didn't expose one or the product isn't near the top.
    var bestRank: Int?

    var currency: String? = nil
    var currencyCode: String { currency ?? "USD" }
    /// The price in dollars: exact for dollar brands, approximate for the rest
    /// (FX). Price filters use it so ₦32,000 isn't read as $32,000.
    var usdPrice: Double { FX.usd(price, currencyCode) ?? price }

    /// Only real markdowns: the brand's own compare-at price must be higher.
    var percentOff: Int? {
        guard let c = compareAt, c > price, c > 0 else { return nil }
        return Int(((c - price) / c * 100).rounded())
    }

    /// Set by catalog/publish_snapshots.py, which reads the description the
    /// published catalog then drops. Absent, not false, on everything else.
    var organic: Bool? = nil

    /// What the brand says the product is for or made with, by AttrFilter
    /// field ("skintype": ["oily"], "ingredient": ["niacinamide"]); written
    /// by catalog/attributes.py. Only the fields the app filters on are kept.
    var attrs: [String: [String]]? = nil

    /// The brand's own listing says the product itself is certified organic —
    /// GOTS for textiles, USDA for food and body care. "Organic cotton" or
    /// "contains certified organic oils" isn't a certification of the product.
    ///
    /// Worked out at build time when the catalog carries no descriptions, and
    /// from the text when it does — a product page that has fetched its
    /// description reads the same either way.
    var isCertifiedOrganic: Bool {
        if let organic { return organic }
        let text = ([title, description ?? ""] + tags).joined(separator: " ").lowercased()
        return Self.organicClaims.contains { text.contains($0) }
    }
    private static let organicClaims = ["gots certified organic", "usda organic", "usda certified organic", "certified usda organic"]

    /// Set by catalog/clean_badge.py when the brand publishes a full ingredient
    /// list that meets the Marracat Clean standard (catalog/clean_standard.md).
    /// Absent, not false, on everything else, to keep the catalog small.
    var clean: Bool? = nil
    var isMarracatClean: Bool { clean ?? false }

    /// Set by catalog/metal_badge.py on jewelry whose every named metal is a
    /// real, solid, skin-safe metal (catalog/metal_standard.md): "true", or
    /// "ethical" when the listing also names a sourcing scheme. Absent otherwise.
    var metal: String? = nil
    var isMarracatTrueMetal: Bool { metal == "true" || metal == "ethical" }
    var isEthicallySourced: Bool { metal == "ethical" }

    /// Set by catalog/scent_badge.py on worn fragrance whose published list has
    /// nothing banned anywhere, no phthalates and a disclosed scent
    /// (catalog/scent_standard.md). Absent otherwise.
    var scent: Bool? = nil
    var isMarracatClearScent: Bool { scent ?? false }

    /// Set by catalog/safer_clean_badge.py on household cleaners whose published
    /// list has nothing banned anywhere and a disclosed fragrance
    /// (catalog/safer_clean_standard.md). Absent otherwise.
    var safer: Bool? = nil
    var isMarracatSaferClean: Bool { safer ?? false }

    /// Set by catalog/food_badge.py on groceries whose published list has no
    /// additive banned in any country and no high-fructose corn syrup
    /// (catalog/food_standard.md). Absent otherwise.
    var food: Bool? = nil
    var isMarracatCleanFood: Bool { food ?? false }

    /// Set by catalog/baby_badge.py on baby products that state their
    /// ingredients or materials, with nothing banned for children anywhere
    /// (catalog/baby_standard.md). Absent otherwise.
    var baby: Bool? = nil
    var isMarracatBabySafe: Bool { baby ?? false }

    /// Set by catalog/fiber_badge.py on garments whose stated composition is
    /// at least 90% natural fibre: "natural", or "organic" when the fibre is
    /// organic or GOTS certified (catalog/fiber_standard.md). Absent otherwise.
    var fiber: String? = nil
    var isMarracatNaturalFiber: Bool { fiber != nil }
    var isOrganicNaturalFiber: Bool { fiber == "organic" }

    /// Set by catalog/fabric_badge.py on garments that state their
    /// composition, name no treatment banned anywhere and are under half
    /// synthetic unless certified (catalog/fabric_standard.md). Absent otherwise.
    var fabric: Bool? = nil
    var isMarracatSafeFabric: Bool { fabric ?? false }

    /// Set by catalog/lab_badge.py on wellness products whose listing names a
    /// third-party certification or publishes an independent COA, with nothing
    /// banned anywhere (catalog/lab_standard.md). Absent otherwise.
    var lab: Bool? = nil
    var isMarracatLabVerified: Bool { lab ?? false }

    /// Set by catalog/pet_badge.py on pet products that say what they are with
    /// nothing toxic to pets or banned (catalog/pet_standard.md). Absent otherwise.
    var pet: Bool? = nil
    var isMarracatPetSafe: Bool { pet ?? false }

    /// Set by catalog/material_badge.py on bags that name their material
    /// honestly: "true", or "veg" for vegetable-tanned / chrome-free leather
    /// (catalog/material_standard.md). Absent otherwise.
    var material: String? = nil
    var isMarracatTrueMaterial: Bool { material != nil }
    var isVegetableTanned: Bool { material == "veg" }

    /// Set by catalog/home_badge.py on home products whose main material is
    /// named and natural: "natural", or "certified" for organic / GOTS textiles
    /// and FSC wood (catalog/home_standard.md). Absent otherwise.
    var home: String? = nil
    var isMarracatNaturalHome: Bool { home != nil }
    var isCertifiedNaturalHome: Bool { home == "certified" }

    /// Every part of every variant title, once ("Black / Large" -> black,
    /// large), from catalog/publish_snapshots.py. The catalog carries these
    /// instead of variant lists for anything with choices — they were 56% of
    /// it — and a product page fetches the variants themselves.
    var opts: [String]? = nil

    var hasOptions: Bool {
        if let opts, !opts.isEmpty { return true }
        return variants.count > 1 || !(variants.first?.isDefault ?? true)
    }
    var firstAvailableVariant: Variant? { variants.first(where: \.available) ?? variants.first }
    var productURL: URL? { URL(string: url) }

    /// Every field, for the app's binary catalog (CatalogBinary) and tests.
    init(id: String, brand: String, title: String, category: String, productType: String?, subs: [String],
         price: Double, compareAt: Double?, images: [String], url: String, available: Bool, variants: [Variant],
         tags: [String], description: String?, publishedAt: String?, bestRank: Int?, currency: String? = nil,
         organic: Bool? = nil, clean: Bool? = nil, opts: [String]? = nil, metal: String? = nil,
         scent: Bool? = nil, safer: Bool? = nil, food: Bool? = nil, baby: Bool? = nil, fiber: String? = nil,
         fabric: Bool? = nil, lab: Bool? = nil, pet: Bool? = nil, material: String? = nil, home: String? = nil,
         attrs: [String: [String]]? = nil) {
        self.id = id; self.brand = brand; self.title = title; self.category = category
        self.productType = productType; self.subs = subs; self.price = price; self.compareAt = compareAt
        self.images = images; self.url = url; self.available = available; self.variants = variants
        self.tags = tags; self.description = description; self.publishedAt = publishedAt
        self.bestRank = bestRank; self.currency = currency; self.organic = organic; self.clean = clean
        self.opts = opts; self.metal = metal; self.scent = scent; self.safer = safer
        self.food = food; self.baby = baby
        self.fiber = fiber; self.fabric = fabric
        self.lab = lab; self.pet = pet; self.material = material; self.home = home
        self.attrs = attrs
    }

    /// Written by hand because the catalog leaves out what a row doesn't need:
    /// no variants for a product with choices, no tags, no images, no
    /// description. The synthesized decoder wants every key of a non-optional
    /// property and refused the whole catalog over one missing "variants".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        brand = try c.decode(String.self, forKey: .brand)
        title = try c.decode(String.self, forKey: .title)
        category = try c.decode(String.self, forKey: .category)
        url = try c.decode(String.self, forKey: .url)
        price = try c.decode(Double.self, forKey: .price)
        available = try c.decode(Bool.self, forKey: .available)
        productType = try c.decodeIfPresent(String.self, forKey: .productType)
        compareAt = try c.decodeIfPresent(Double.self, forKey: .compareAt)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
        bestRank = try c.decodeIfPresent(Int.self, forKey: .bestRank)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        clean = try c.decodeIfPresent(Bool.self, forKey: .clean)
        metal = try c.decodeIfPresent(String.self, forKey: .metal)
        scent = try c.decodeIfPresent(Bool.self, forKey: .scent)
        safer = try c.decodeIfPresent(Bool.self, forKey: .safer)
        food = try c.decodeIfPresent(Bool.self, forKey: .food)
        baby = try c.decodeIfPresent(Bool.self, forKey: .baby)
        fiber = try c.decodeIfPresent(String.self, forKey: .fiber)
        fabric = try c.decodeIfPresent(Bool.self, forKey: .fabric)
        lab = try c.decodeIfPresent(Bool.self, forKey: .lab)
        pet = try c.decodeIfPresent(Bool.self, forKey: .pet)
        material = try c.decodeIfPresent(String.self, forKey: .material)
        home = try c.decodeIfPresent(String.self, forKey: .home)
        organic = try c.decodeIfPresent(Bool.self, forKey: .organic)
        opts = try c.decodeIfPresent([String].self, forKey: .opts)
        subs = try c.decodeIfPresent([String].self, forKey: .subs) ?? []
        images = try c.decodeIfPresent([String].self, forKey: .images) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        variants = try c.decodeIfPresent([Variant].self, forKey: .variants) ?? []
        // The catalog's attrs also hold scent notes and a fabric name (a
        // string); read only the list fields the filters use.
        if c.contains(.attrs), let a = try? c.nestedContainer(keyedBy: AttrKey.self, forKey: .attrs) {
            var out: [String: [String]] = [:]
            for f in AttrFilter.fields {
                if let v = try? a.decodeIfPresent([String].self, forKey: AttrKey(stringValue: f)), !v.isEmpty { out[f] = v }
            }
            attrs = out.isEmpty ? nil : out
        }
    }
}

/// A key of a product's `attrs` object.
struct AttrKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

/// Shopify's CDN resizes on the fly with a `width` query item — ask for what
/// the cell needs instead of pulling 2000px originals into a grid.
func sizedImageURL(_ raw: String?, width: Int) -> URL? {
    guard let raw, var comps = URLComponents(string: raw) else { return nil }
    let host = comps.host ?? ""
    let isShopify = host.contains("cdn.shopify.com") || comps.path.contains("/cdn/shop/")
    // Other stores serve one size. The width rides in the fragment, which
    // never reaches their server, so ImageLoader decodes the photo at the size
    // it's shown (ImageIO) instead of a 4,000-pixel original, and the tile and
    // the product page each cache their own size (2026-10-02).
    guard isShopify else {
        comps.fragment = "w=\(width)"
        return comps.url
    }
    // Height and crop would cap the photo whatever width is asked for.
    var items = (comps.queryItems ?? []).filter { !["width", "height", "crop"].contains($0.name) }
    items.append(URLQueryItem(name: "width", value: String(width)))
    comps.queryItems = items
    return comps.url
}

/// Dollar rates for brands that charge in another currency. The catalog stamps
/// each such brand with `usd_rate` (catalog/fx.py); `update` reads them when a
/// catalog lands, and the fallback covers the moments before that.
enum FX {
    /// Dollars per one unit, 2026-10-08 (ECB; ExchangeRate-API for NGN/KES/GHS).
    /// CAD, XOF, RWF and BWP 2026-10-15; the Caribbean's JMD, BBD, BSD and XCD and the UAE's AED 2026-10-23;
    /// the Swiss franc 2026-11-11 (ECB).
    static let fallback: [String: Double] = ["GBP": 1.321, "EUR": 1.119, "SEK": 0.1, "ZAR": 0.06006, "CAD": 0.7032,
                                              "NGN": 0.000751, "KES": 0.007716, "GHS": 0.08584,
                                              "XOF": 0.001704, "RWF": 0.000677, "BWP": 0.07168,
                                              "JMD": 0.006297, "BBD": 0.5, "BSD": 1.0, "XCD": 0.37037,
                                              "AED": 0.272294, "CHF": 1.205008]
    nonisolated(unsafe) static var usdPerUnit = fallback

    static func update(from brands: some Collection<Brand>) {
        var rates = fallback
        for b in brands { if let r = b.usdRate, r > 0 { rates[b.currencyCode] = r } }
        usdPerUnit = rates
    }

    /// The amount in dollars, or nil for a currency with no known rate.
    static func usd(_ amount: Double, _ currency: String) -> Double? {
        currency == "USD" ? amount : usdPerUnit[currency].map { amount * $0 }
    }

    /// The sign shown before a price.
    static func symbol(_ currency: String) -> String {
        ["USD": "$", "GBP": "£", "EUR": "€", "NGN": "₦", "GHS": "GH₵", "KES": "KSh ", "ZAR": "R", "SEK": "kr ",
         "CAD": "CA$", "XOF": "CFA ", "RWF": "RF ", "BWP": "P",
         "JMD": "J$", "BBD": "Bds$", "BSD": "B$", "XCD": "EC$", "AED": "AED ", "CHF": "CHF "][currency] ?? "\(currency) "
    }
}

enum Money {
    static func string(_ value: Double, currency: String = "USD") -> String {
        value.formatted(.currency(code: currency))
    }

    /// The price in words for VoiceOver: "10 dollars", "12 pounds 50 pence".
    /// A bare "$10.00" failed the accessibility audit's human-readable check.
    static func spoken(_ value: Double, currency: String = "USD") -> String {
        let cents = Int((value * 100).rounded()), major = cents / 100, minor = cents % 100
        let names: [String: (String, String, String, String)] = [
            "USD": ("dollar", "dollars", "cent", "cents"), "GBP": ("pound", "pounds", "penny", "pence"),
            "EUR": ("euro", "euros", "cent", "cents"), "NGN": ("naira", "naira", "kobo", "kobo"),
            "GHS": ("cedi", "cedis", "pesewa", "pesewas"), "KES": ("shilling", "shillings", "cent", "cents"),
            "ZAR": ("rand", "rand", "cent", "cents"), "SEK": ("krona", "kronor", "öre", "öre"),
            "CAD": ("Canadian dollar", "Canadian dollars", "cent", "cents"), "XOF": ("CFA franc", "CFA francs", "centime", "centimes"),
            "RWF": ("Rwandan franc", "Rwandan francs", "centime", "centimes"), "BWP": ("pula", "pula", "thebe", "thebe"),
            "JMD": ("Jamaican dollar", "Jamaican dollars", "cent", "cents"), "BBD": ("Barbados dollar", "Barbados dollars", "cent", "cents"),
            "BSD": ("Bahamian dollar", "Bahamian dollars", "cent", "cents"),
            "XCD": ("East Caribbean dollar", "East Caribbean dollars", "cent", "cents"),
            "AED": ("dirham", "dirhams", "fils", "fils"),
            "CHF": ("Swiss franc", "Swiss francs", "centime", "centimes")]
        // Other languages: Foundation's own words for the amount ("12,50 US-Dollar").
        guard Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? true else {
            return value.formatted(.currency(code: currency).presentation(.fullName))
        }
        guard let n = names[currency] else { return string(value, currency: currency) }
        let big = "\(major) \(major == 1 ? n.0 : n.1)"
        return minor == 0 ? big : "\(big) \(minor) \(minor == 1 ? n.2 : n.3)"
    }

    /// A price on its own, in dollars when the rate is known (a struck-through
    /// "List" price beside a dollar PriceView), else in the brand's currency.
    static func leading(_ value: Double, currency: String) -> String {
        FX.usd(value, currency).map { string($0) } ?? string(value, currency: currency)
    }

    /// Amazon-style price parts: "$", "129", "99".
    static func parts(_ value: Double) -> (dollars: String, cents: String) {
        let cents = Int((value * 100).rounded())
        return ((cents / 100).formatted(.number.grouping(.automatic)), String(format: "%02d", cents % 100))
    }
}
