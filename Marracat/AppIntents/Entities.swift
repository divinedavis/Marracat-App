import AppIntents
import CoreSpotlight
import Foundation

// Products, brands and departments as App Intents entities: what Siri,
// Shortcuts and Apple Intelligence can name, find and open. They are read
// from the catalog the app already holds in memory; nothing here goes to the
// network. Spotlight indexing is SpotlightIndexer's.

struct ProductEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Product")
    static let defaultQuery = ProductQuery()

    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Brand") var brandName: String
    /// "$48.00", in the brand's currency.
    var price: String
    var imageURL: URL?

    init(id: String, name: String, brandName: String, price: String, imageURL: URL?) {
        self.id = id
        self.price = price
        self.imageURL = imageURL
        self.name = name
        self.brandName = brandName
    }

    init(_ product: Product, brandName: String) {
        self.init(id: product.id, name: product.title, brandName: brandName,
                  price: product.price.formatted(.currency(code: product.currencyCode)),
                  imageURL: product.images.first.flatMap(URL.init(string:)))
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(brandName) · \(price)",
                              image: imageURL.map { DisplayRepresentation.Image(url: $0) })
    }
}

struct BrandEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Brand")
    static let defaultQuery = BrandQuery()

    let id: String
    @Property(title: "Name") var name: String
    var tagline: String?

    init(id: String, name: String, tagline: String?) {
        self.id = id
        self.tagline = tagline
        self.name = name
    }

    init(_ brand: Brand) { self.init(id: brand.id, name: brand.name, tagline: brand.tagline) }

    var displayRepresentation: DisplayRepresentation {
        if let tagline, !tagline.isEmpty { return DisplayRepresentation(title: "\(name)", subtitle: "\(tagline)") }
        return DisplayRepresentation(title: "\(name)")
    }
}

/// A department: Skincare, Hair Care, Menswear…
struct CategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Department")
    static let defaultQuery = CategoryQuery()

    let id: String
    @Property(title: "Name") var name: String
    var symbol: String

    init(id: String, name: String, symbol: String) {
        self.id = id
        self.symbol = symbol
        self.name = name
    }

    init(_ category: Category) { self.init(id: category.id, name: category.name, symbol: category.symbol) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbol))
    }
}

// Spotlight (iOS 18+): saved products, followed and premier brands are indexed
// with their entity attached (SpotlightIndexer), so Apple Intelligence knows
// them and a tapped result runs the matching Open… intent.
@available(iOS 18.0, *)
extension ProductEntity: IndexedEntity {}
@available(iOS 18.0, *)
extension BrandEntity: IndexedEntity {}

// MARK: Queries

struct ProductQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ProductEntity.ID]) async throws -> [ProductEntity] {
        guard let catalog = await IntentRouter.shared.completeCatalog() else { return [] }
        return identifiers.compactMap { id in
            catalog.product(id).map { ProductEntity($0, brandName: catalog.brand($0.brand)?.name ?? "") }
        }
    }

    /// The catalog's own search, on a background thread: a search that
    /// visits most of 147k products would otherwise hold the main thread.
    @MainActor
    func entities(matching string: String) async throws -> [ProductEntity] {
        guard let catalog = await IntentRouter.shared.completeCatalog() else { return [] }
        let snapshot = catalog.searchSnapshot
        return await Task.detached(priority: .userInitiated) {
            IntentMatching.products(matching: string, in: snapshot)
        }.value
    }

    /// What the shopper saved, then what they looked at last.
    @MainActor
    func suggestedEntities() async throws -> [ProductEntity] {
        guard let catalog = IntentRouter.shared.catalog, let shopper = IntentRouter.shared.shopper else { return [] }
        let ids = IntentMatching.suggestedProductIDs(saved: shopper.saved, recentlyViewed: shopper.recentlyViewed,
                                                     personalization: shopper.personalizationEnabled)
        return ids.compactMap { id in catalog.product(id).map { ProductEntity($0, brandName: catalog.brand($0.brand)?.name ?? "") } }
    }
}

struct BrandQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [BrandEntity.ID]) async throws -> [BrandEntity] {
        // Brands are in Home's slice too; no need to wait for every product.
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        if catalog.brands.isEmpty { _ = await IntentRouter.shared.completeCatalog(limit: .seconds(5)) }
        return identifiers.compactMap { catalog.brand($0).map(BrandEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [BrandEntity] {
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        if catalog.brands.isEmpty { _ = await IntentRouter.shared.completeCatalog(limit: .seconds(5)) }
        let brands = catalog.brands
        return await Task.detached(priority: .userInitiated) {
            IntentMatching.brands(matching: string, in: brands, premier: CatalogStore.premierBrandIDs).map(BrandEntity.init)
        }.value
    }

    /// The names Siri listens for in "Show … on Marracat": the premier brands
    /// and the ones the shopper follows.
    @MainActor
    func suggestedEntities() async throws -> [BrandEntity] {
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        let ids = IntentMatching.suggestedBrandIDs(premier: CatalogStore.premierBrandIDs,
                                                   followed: DealAlertStore.shared.brands)
        return ids.compactMap { catalog.brand($0).map(BrandEntity.init) }
    }
}

struct CategoryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        return identifiers.compactMap { catalog.category($0).map(CategoryEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [CategoryEntity] {
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        return IntentMatching.categories(matching: string, in: catalog.catalog.categories).map(CategoryEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        guard let catalog = IntentRouter.shared.catalog else { return [] }
        return catalog.catalog.categories.map(CategoryEntity.init)
    }
}

/// The matching behind the queries, kept free of the stores so it can be
/// tested and run off the main thread.
enum IntentMatching {
    /// The most results a query hands Siri or Shortcuts.
    static let limit = 10

    static func products(matching string: String, in snapshot: CatalogStore.SearchSnapshot, limit: Int = limit) -> [ProductEntity] {
        let query = String(string.prefix(AppDestination.maxQuery))
        return snapshot.search(query).prefix(limit).map { ProductEntity($0, brandName: snapshot.brands[$0.brand]?.name ?? "") }
    }

    /// Lower-cased, accents and punctuation gone: "Fenty", "fenty beauty",
    /// "FENTY-BEAUTY" all read "fenty beauty".
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// Brands by name: the exact name first, then names that start with it,
    /// then a word that starts with it, then anywhere in the name. Premier
    /// brands lead within each.
    static func brands(matching string: String, in brands: [Brand], premier: [String], limit: Int = limit) -> [Brand] {
        let q = normalize(string)
        guard !q.isEmpty else { return [] }
        let squashed = q.replacingOccurrences(of: " ", with: "")
        func rank(_ b: Brand) -> Int? {
            let name = normalize(b.name)
            if name == q || name.replacingOccurrences(of: " ", with: "") == squashed { return 0 }
            if name.hasPrefix(q) { return 1 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(q) }) || name.contains(" " + q) { return 2 }
            if name.contains(q) || name.replacingOccurrences(of: " ", with: "").contains(squashed) { return 3 }
            return nil
        }
        let order = Dictionary(premier.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return brands.compactMap { b in rank(b).map { (b, $0) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                let pa = order[a.0.id] ?? Int.max, pb = order[b.0.id] ?? Int.max
                if pa != pb { return pa < pb }
                return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
            }
            .prefix(limit).map(\.0)
    }

    static func categories(matching string: String, in categories: [Category]) -> [Category] {
        let q = normalize(string)
        guard !q.isEmpty else { return [] }
        return categories.filter { c in
            let name = normalize(c.name)
            return name.contains(q) || q.contains(name) || normalize(c.id) == q
        }
    }

    /// Saved first, then recently viewed (only while personalization is on),
    /// without repeats.
    static func suggestedProductIDs(saved: [String], recentlyViewed: [String], personalization: Bool, limit: Int = 20) -> [String] {
        var seen = Set<String>()
        let recent = personalization ? recentlyViewed : []
        return Array((saved + recent).filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// Premier brands in their Home order, then followed brands by id.
    static func suggestedBrandIDs(premier: [String], followed: Set<String>) -> [String] {
        premier + followed.subtracting(premier).sorted()
    }
}
