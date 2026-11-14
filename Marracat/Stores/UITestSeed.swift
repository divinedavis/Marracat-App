import Foundation

/// UI tests start with a cart across several brands and saved details
/// instead of searching and typing for each: `-SEED_CART brand-a,brand-b`
/// puts one in-stock item from each brand in the cart, in that order, and
/// `-SEED_BUYER` saves details full of characters a URL has to encode.
/// Only with -UITEST_RESET, so nothing a shopper does can reach it.
enum UITestSeed {
    private static var done = false
    /// The variant id of a seeded line whose product's variants aren't bundled.
    static let seedVariantID: Int64 = 1

    /// Saved details that test the cart link's encoding: an accent, an
    /// apostrophe, "&" and "#" in the street, a unit number, "+" in the phone.
    static let buyer = BuyerDetails(firstName: "Zoë", lastName: "O'Brien", email: "zoe+test@example.com", phone: "+1 718 555 0100",
                                    street: "12 Rue & Co #4", extended: "Apt 4B", city: "Brooklyn", region: "NY", postalCode: "11201")

    @MainActor
    static func apply(catalog: CatalogStore, cart: CartStore, buyer store: BuyerStore,
                      arguments: [String] = ProcessInfo.processInfo.arguments, defaults: UserDefaults = .standard) {
        guard !done, arguments.contains("-UITEST_RESET") else { return }
        done = true
        if arguments.contains("-SEED_BUYER") { store.save(buyer) }
        for id in (defaults.string(forKey: "SEED_CART") ?? "").split(separator: ",").map(String.init) {
            let products = catalog.products(for: id)
            if let p = products.first(where: { $0.available && $0.variants.contains { $0.available } }),
               let v = p.variants.first(where: { $0.available }) {
                cart.add(productID: p.id, variantID: v.id, option: v.isDefault ? nil : v.title, unitPrice: v.price, currency: p.currencyCode)
            } else if let p = products.first(where: \.available) {
                // The bundle carries variants only for one-variant products
                // (publish_snapshots.compact_product); a brand whose stock is
                // all sized that day (YEEZY, 2026-11-08) still gets a line, as
                // a shopper's pick from the product page would make.
                cart.add(productID: p.id, variantID: seedVariantID, option: "Seeded", unitPrice: p.price, currency: p.currencyCode)
            }
        }
    }
}
