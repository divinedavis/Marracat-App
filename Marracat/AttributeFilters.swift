import Foundation

/// Filters read from what a brand says about a product (catalog/attributes.py
/// writes `attrs`; the website's copy is web/src/attrs.js). Each group is read
/// from its own department's products only (owner, 2026-11-04, from Sephora's
/// Filter & Sort: "only have filters that reflect skincare in the skincare
/// category and the ones for hair in the hair category").
///
/// A page of one department (its own page, a search whose results are all in
/// it, or the department picked under Category) shows all of its groups. A
/// page that spans several, a brand's store or a wide search, shows the ones
/// about who a product is for (`mixedFields`: hair type, hair and scalp
/// concern, skin concern, skin type, ingredient preferences) whenever it holds
/// products that carry them (owner, 2026-11-22, on a brand that sells hair,
/// skin and makeup: "can we get a filter for products that are good for
/// eczema ... skin sensitivity filters for skin products, hair texture or
/// sensitivities for hair products"). They existed, and that page hid them.
enum AttrFilter {
    struct Spec {
        let field: String
        let departments: Set<String>
        let values: [(id: String, label: String)]
        /// Single values narrower still: oil-free is a skin preference only.
        var valueDepartments: [String: Set<String>] = [:]
        /// Shown whenever products carry it, not only on one department's
        /// page: a search for "pants" spans clothing and accessories, and
        /// Women / Men still means something there (catalog/gender.py tags
        /// clothing and shoes only).
        var anyDepartment = false
    }

    /// The fields the app filters on, in the sheet's order. The catalog also
    /// carries scent notes and fabric, which the app doesn't read.
    static let fields = ["gender", "hair", "hairneed", "skin", "skintype", "ingredient", "free", "form", "spf", "pack"]

    /// The groups a page of several departments still shows.
    static let mixedFields: Set<String> = ["hair", "hairneed", "skin", "skintype", "free"]

    static let specs: [String: Spec] = [
        // Owner, 2026-11-08: "for clothes do some brands have a women and men
        // filter? if so lets use it". Unisex products carry both.
        "gender": Spec(field: "gender", departments: ["clothing", "shoes"], values: [
            ("women", String(localized: "Women", comment: "Gender filter option: women's clothing")),
            ("men", String(localized: "Men", comment: "Gender filter option: men's clothing")),
        ], anyDepartment: true),
        "hair": Spec(field: "hair", departments: ["hair"], values: [
            ("4c", String(localized: "For 4C hair", comment: "Hair filter option")),
            ("4b", String(localized: "For 4B hair", comment: "Hair filter option")),
            ("4a", String(localized: "For 4A hair", comment: "Hair filter option")),
            ("3c", String(localized: "For 3C hair", comment: "Hair filter option")),
            ("coils", String(localized: "Coily hair", comment: "Hair filter option")),
            ("curls", String(localized: "Curly hair", comment: "Hair filter option")),
            ("locs", String(localized: "Locs", comment: "Hair filter option (dreadlocks)")),
            ("waves", String(localized: "Waves", comment: "Hair filter option (360 waves)")),
            ("straight", String(localized: "Straight or relaxed", comment: "Hair filter option")),
            ("fine", String(localized: "Fine or thin hair", comment: "Hair filter option: hair texture")),
            ("thick", String(localized: "Thick or coarse hair", comment: "Hair filter option: hair texture")),
            ("low_porosity", String(localized: "Low porosity", comment: "Hair filter option: hair that resists moisture")),
            ("high_porosity", String(localized: "High porosity", comment: "Hair filter option: hair that loses moisture fast")),
        ]),
        // What the brand says the hair or scalp needs help with (owner, 2026-11-22).
        "hairneed": Spec(field: "hairneed", departments: ["hair"], values: [
            ("sensitive_scalp", String(localized: "Sensitive scalp", comment: "Hair and scalp concern filter option")),
            ("dry_scalp", String(localized: "Dry or itchy scalp", comment: "Hair and scalp concern filter option")),
            ("dandruff", String(localized: "Dandruff & flakes", comment: "Hair and scalp concern filter option")),
            ("damage", String(localized: "Damage & breakage", comment: "Hair and scalp concern filter option")),
            ("thinning", String(localized: "Thinning & growth", comment: "Hair and scalp concern filter option")),
            ("dry_hair", String(localized: "Dry or brittle hair", comment: "Hair and scalp concern filter option")),
            ("frizz", String(localized: "Frizz", comment: "Hair and scalp concern filter option")),
            ("color_treated", String(localized: "Colour-treated", comment: "Hair and scalp concern filter option")),
        ]),
        // Baby carries eczema, sensitivity and dryness only (catalog/attributes.py).
        "skin": Spec(field: "skin", departments: ["skincare", "baby"], values: [
            ("acne", String(localized: "Acne & breakouts", comment: "Skin concern filter option")),
            ("dark_spots", String(localized: "Dark spots", comment: "Skin concern filter option")),
            ("aging", String(localized: "Fine lines & wrinkles", comment: "Skin concern filter option")),
            ("dryness", String(localized: "Dryness", comment: "Skin concern filter option")),
            ("dullness", String(localized: "Dullness", comment: "Skin concern filter option")),
            ("oily", String(localized: "Oiliness", comment: "Skin concern filter option")),
            ("pores", String(localized: "Pores", comment: "Skin concern filter option")),
            ("redness", String(localized: "Redness", comment: "Skin concern filter option")),
            ("sensitive", String(localized: "Sensitivity", comment: "Skin concern filter option")),
            ("eczema", String(localized: "Eczema", comment: "Skin concern filter option")),
            ("razor_bumps", String(localized: "Razor bumps & ingrowns", comment: "Skin concern filter option")),
            ("texture", String(localized: "Uneven texture", comment: "Skin concern filter option")),
            ("firmness", String(localized: "Loss of firmness", comment: "Skin concern filter option")),
            ("dark_circles", String(localized: "Dark circles & puffiness", comment: "Skin concern filter option")),
        ]),
        "skintype": Spec(field: "skintype", departments: ["skincare"], values: [
            ("normal", String(localized: "Normal", comment: "Skin type filter option")),
            ("dry", String(localized: "Dry", comment: "Skin type filter option")),
            ("oily", String(localized: "Oily", comment: "Skin type filter option")),
            ("combination", String(localized: "Combination", comment: "Skin type filter option")),
            ("sensitive", String(localized: "Sensitive", comment: "Skin type filter option")),
            ("mature", String(localized: "Mature", comment: "Skin type filter option")),
            ("all", String(localized: "All skin types", comment: "Skin type filter option")),
        ]),
        "ingredient": Spec(field: "ingredient", departments: ["skincare"], values: [
            ("vitamin_c", String(localized: "Vitamin C", comment: "Key ingredient filter option")),
            ("hyaluronic", String(localized: "Hyaluronic acid", comment: "Key ingredient filter option")),
            ("niacinamide", String(localized: "Niacinamide", comment: "Key ingredient filter option")),
            ("retinoid", String(localized: "Retinol & retinoids", comment: "Key ingredient filter option")),
            ("bakuchiol", String(localized: "Bakuchiol", comment: "Key ingredient filter option")),
            ("salicylic", String(localized: "Salicylic acid (BHA)", comment: "Key ingredient filter option")),
            ("aha", String(localized: "AHAs (glycolic, lactic)", comment: "Key ingredient filter option")),
            ("peptides", String(localized: "Peptides", comment: "Key ingredient filter option")),
            ("ceramides", String(localized: "Ceramides", comment: "Key ingredient filter option")),
            ("squalane", String(localized: "Squalane", comment: "Key ingredient filter option")),
            ("shea", String(localized: "Shea butter", comment: "Key ingredient filter option")),
            ("collagen", String(localized: "Collagen", comment: "Key ingredient filter option")),
            ("centella", String(localized: "Centella (cica)", comment: "Key ingredient filter option")),
            ("azelaic", String(localized: "Azelaic acid", comment: "Key ingredient filter option")),
            ("tranexamic", String(localized: "Tranexamic acid", comment: "Key ingredient filter option")),
            ("kojic", String(localized: "Kojic acid", comment: "Key ingredient filter option")),
            ("sulfur", String(localized: "Sulfur", comment: "Key ingredient filter option")),
            ("benzoyl", String(localized: "Benzoyl peroxide", comment: "Key ingredient filter option")),
            ("turmeric", String(localized: "Turmeric", comment: "Key ingredient filter option")),
        ]),
        "free": Spec(field: "free", departments: ["hair", "skincare", "baby"], values: [
            ("fragrance", String(localized: "Fragrance-free", comment: "Ingredient preference filter option")),
            ("sulfate", String(localized: "Sulfate-free", comment: "Ingredient preference filter option")),
            ("paraben", String(localized: "Paraben-free", comment: "Ingredient preference filter option")),
            ("silicone", String(localized: "Silicone-free", comment: "Ingredient preference filter option")),
            ("alcohol", String(localized: "Alcohol-free", comment: "Ingredient preference filter option")),
            ("oil", String(localized: "Oil-free", comment: "Ingredient preference filter option")),
            ("noncomedogenic", String(localized: "Non-comedogenic", comment: "Ingredient preference filter option: won't clog pores")),
            ("vegan", String(localized: "Vegan", comment: "Ingredient preference filter option")),
            ("cruelty_free", String(localized: "Cruelty-free", comment: "Ingredient preference filter option")),
        ], valueDepartments: ["oil": ["skincare"], "noncomedogenic": ["skincare"]]),
        "form": Spec(field: "form", departments: ["skincare"], values: [
            ("serum", String(localized: "Serum", comment: "Formulation filter option")),
            ("cream", String(localized: "Cream", comment: "Formulation filter option")),
            ("lotion", String(localized: "Lotion", comment: "Formulation filter option")),
            ("oil", String(localized: "Oil", comment: "Formulation filter option")),
            ("balm", String(localized: "Balm", comment: "Formulation filter option")),
            ("butter", String(localized: "Butter", comment: "Formulation filter option (body butter)")),
            ("gel", String(localized: "Gel", comment: "Formulation filter option")),
            ("foam", String(localized: "Foam", comment: "Formulation filter option")),
            ("mist", String(localized: "Mist & spray", comment: "Formulation filter option")),
            ("toner", String(localized: "Toner", comment: "Formulation filter option")),
            ("mask", String(localized: "Mask", comment: "Formulation filter option")),
            ("scrub", String(localized: "Scrub", comment: "Formulation filter option")),
            ("bar", String(localized: "Bar", comment: "Formulation filter option (bar soap)")),
            ("stick", String(localized: "Stick", comment: "Formulation filter option")),
            ("wipes", String(localized: "Wipes & pads", comment: "Formulation filter option")),
            ("powder", String(localized: "Powder", comment: "Formulation filter option")),
        ]),
        "spf": Spec(field: "spf", departments: ["skincare"], values: [
            ("high", String(localized: "SPF over 30", comment: "Sun protection filter option")),
            ("low", String(localized: "SPF 30 and under", comment: "Sun protection filter option")),
        ]),
        "pack": Spec(field: "pack", departments: ["skincare"], values: [
            ("mini", String(localized: "Mini & travel", comment: "Size filter option: travel sizes")),
            ("value", String(localized: "Value size", comment: "Size filter option: jumbo sizes")),
            ("set", String(localized: "Gift set", comment: "Size filter option: sets and kits")),
            ("refill", String(localized: "Refill", comment: "Size filter option: refills")),
        ]),
    ]

    /// Whether `value` of `field` belongs in `department`.
    static func applies(_ field: String, _ value: String, department: String?) -> Bool {
        if specs[field]?.anyDepartment == true { return true }
        guard let department, let spec = specs[field], spec.departments.contains(department) else { return false }
        return spec.valueDepartments[value]?.contains(department) ?? true
    }

    static func label(_ field: String, _ value: String) -> String {
        specs[field]?.values.first { $0.id == value }?.label ?? value
    }

    /// The departments a page's filters are read for: the ones the shopper
    /// picked under Category, else every one its products are in.
    static func departments(of products: [Product], picked: Set<String>) -> Set<String> {
        picked.isEmpty ? Set(products.map(\.category)) : picked
    }

    /// Whether `field`'s group belongs on a page of these departments: one of
    /// them is the field's own, and across several only the `mixedFields`.
    static func shows(_ field: String, in departments: Set<String>) -> Bool {
        guard let spec = specs[field] else { return false }
        if spec.anyDepartment { return true }
        guard !spec.departments.isDisjoint(with: departments) else { return false }
        return departments.count == 1 || mixedFields.contains(field)
    }
}
