import SwiftUI

/// Browse. Its Explore tiles and category rows carry 3D pictures on the
/// app's plain grey surfaces. They were forest green on pale sage for two
/// days (owner, 2026-11-23); with the pictures in, the owner took the green
/// back out (2026-11-25: "don't forget to remove the green on the search
/// screen"), so the pictures are the only colour here.
struct MenuView: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your shortcuts").brandFont(.title3.bold())
                HStack(spacing: 8) {
                    shortcut(String(localized: "Checkouts", comment: "Menu shortcut"), .checkouts)
                    shortcut(String(localized: "Your List", comment: "Menu shortcut"), .saved)
                    shortcut(String(localized: "Deals", comment: "Menu shortcut"), .deals)
                }

                Text("Explore more for you").brandFont(.title3.bold())
                HStack(spacing: 10) {
                    tile(String(localized: "New", comment: "Menu tile"), "new", "sparkles", .newArrivals)
                    tile(String(localized: "Deals", comment: "Menu tile"), "deals", "tag.fill", .deals)
                    tile(String(localized: "Brands", comment: "Menu tile"), "brands", "storefront.fill", .brands)
                }

                Text("Shop by category").brandFont(.title3.bold())
                VStack(spacing: 8) {
                    ForEach(catalog.categories) { c in categoryRow(c) }
                }

                link(String(localized: "About Marracat", comment: "Menu link"), .about)
            }
            .padding(12)
            .readableWidth()
        }
        .background(Theme.canvas)
        // Store search floats above the tab bar here (owner, 2026-10-20).
        .marracatChrome(storeSearch: true)
    }

    private func shortcut(_ title: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            Text(title).brandFont(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.field))
                .overlay(Capsule().stroke(Theme.hairline))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func tile(_ title: String, _ art: String, _ symbol: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            VStack(spacing: 4) {
                ArtIcon(name: art, symbol: symbol, size: 44).brandFont(.title2)
                Text(title).brandFont(.caption.bold())
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func categoryRow(_ c: Category) -> some View {
        let isOpen = expanded == c.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded = isOpen ? nil : c.id }
            } label: {
                HStack(spacing: 12) {
                    ArtIcon(name: c.id, symbol: c.symbol, size: 40)
                    Text(c.name).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("categoryRow.\(c.id)")
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: Route.category(c.id)) {
                        Text("See all in \(c.name)").brandFont(.subheadline.bold()).padding(.vertical, 10)
                    }
                    // The aisles inside the category, biggest first — the
                    // brands live behind Brands and each product.
                    ForEach(catalog.subcategories(in: c.id)) { s in
                        NavigationLink(value: Route.subcategory(s.id)) {
                            Text(s.name).brandFont(.subheadline).foregroundStyle(.primary).padding(.vertical, 10)
                        }
                        .accessibilityIdentifier("subcategory")
                    }
                }
                .padding(.leading, 66)
                .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func link(_ title: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct AboutView: View {
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        List {
            Section {
                Text("Discover brands, explore categories, and keep your favorite finds together with Marracat.")
                Text("You check out on each brand's own website, so the brand keeps the sale, the customer relationship, and handles shipping and returns.")
            }
            TitledSection("Where the products come from") {
                Text("Listings come from each brand's own public store. Prices and stock can change; the brand's site is always the final word.")
                if let date = ISO8601DateFormatter().date(from: catalog.catalog.generatedAt) {
                    LabeledContent("Catalog updated", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Brands", value: "\(catalog.catalog.brands.count)")
                    .accessibilityIdentifier("aboutBrands")
                LabeledContent("Products", value: "\(catalog.catalog.products.count)")
                    .accessibilityIdentifier("aboutProducts")
            }
        }
        .marracatChrome()
    }
}
