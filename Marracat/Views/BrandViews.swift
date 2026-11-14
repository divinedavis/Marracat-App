import SwiftUI

/// The fifth tab (Amazon's Rufus slot): every brand, grouped by category.
struct BrandsView: View {
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        List {
            ForEach(catalog.catalog.categories) { c in
                let brands = catalog.brands.filter { $0.category == c.id }
                if !brands.isEmpty {
                    Section(c.name) {
                        ForEach(brands) { BrandRow(brand: $0) }
                    }
                }
            }
        }
        .marracatChrome()
    }
}

private struct BrandRow: View {
    let brand: Brand
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        let products = catalog.products(for: brand.id)
        NavigationLink(value: Route.brand(brand.id)) {
            HStack(spacing: 12) {
                if let image = products.first?.images.first {
                    ProductImageWell(url: image, width: 160, padding: 4).frame(width: 56)
                } else {
                    BrandArtwork(brand: brand, size: 56)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(brand.name).font(.body.weight(.semibold))
                    if let t = brand.tagline { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Text(products.isEmpty ? "Shop on \(brand.domain)" : "\(products.count) items")
                        .font(.caption2).foregroundStyle(Theme.link)
                }
            }
        }
        .accessibilityIdentifier("brandRow")
    }
}

/// Art for brands with no imported products (no public feed): the brand's own
/// share image (og:image, fetched by catalog/build_catalog.py), cropped to
/// fill — or, if the site has none, a readable light-grey monogram.
struct BrandArtwork: View {
    let brand: Brand
    var size: CGFloat

    var body: some View {
        Group {
            if let image = brand.image {
                // Share images are wide (~1.9:1) and often a wordmark: fit, don't
                // crop, or "Curves" reads "Curv es" in a small square.
                Theme.tile.overlay { RemoteImage(url: image, width: 400, contentMode: .fit).padding(3) }
            } else {
                Theme.field.overlay {
                    Text(String(brand.name.prefix(1)))
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct BrandStoreView: View {
    let brandID: String
    @Environment(CatalogStore.self) private var catalog
    /// Filters and Sort, in the pill above the tab bar; the departments are
    /// Filters' Category (owner, 2026-11-10: "the top of the screen is too far
    /// from a user's thumb").
    @State private var filters = ProductFilters()
    @State private var browser: IdentifiedURL?
    /// The photo has scrolled up under the bar: the bar gets its background
    /// back and carries the brand's name.
    @State private var heroGone = false
    /// "Sale alerts on for …": the rail's bell says what it did (owner,
    /// 2026-11-01: "when a user touches this it should bring up a prompt").
    @State private var toast: ActionToastMessage?
    /// The pull-down space ("The name, huge") and the Filters pill that steps
    /// aside on the way down (owner, 2026-11-10; BrandMotion.swift). Not page state: it changes
    /// every scroll frame.
    @State private var scroll = BrandScroll()
    /// The hero photo's two colours, for the name in that space.
    @State private var palette = PhotoPalette.fallback

    var body: some View {
        Group {
            if let brand = catalog.brand(brandID) { content(brand) }
            else { ContentUnavailableView("Brand not found", systemImage: "storefront") }
        }
        .actionToast($toast)
        .sheet(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
        // A brand this shopper keeps visiting refreshes faster (FreshCatalog).
        .task(id: brandID) {
            FreshCatalog.shared.brandVisited(brandID)
            await FreshCatalog.shared.refreshIfDue(brandID, catalog: catalog)
        }
        // No search bar on a brand page (owner, 2026-11-09: "remove the brand
        // search"); Filters and Sort narrow the page.
        .marracatChrome(barShown: heroGone || catalog.brand(brandID) == nil)
    }

    /// The hero's photo: the brand's own, else its best-selling in-stock
    /// product's, else any product's.
    static func heroPhoto(_ brand: Brand, _ products: [Product]) -> String? {
        if let image = brand.image { return image }
        let inStock = products.filter { $0.available && !$0.images.isEmpty }
        let best = inStock.min { ($0.bestRank ?? .max) < ($1.bestRank ?? .max) }
        return (best ?? products.first { !$0.images.isEmpty })?.images.first
    }

    private func content(_ brand: Brand) -> some View {
        // New since the last publish first (FreshCatalog), then the catalog's.
        let all = FreshCatalog.shared.arrivals[brand.id, default: []] + Array(catalog.products(for: brand.id))
        // Sold-out items go last whatever the sort, so a brand page leads with
        // what can be bought.
        let shown = catalog.inStockFirst(filters.apply(all))
        let photo = Self.heroPhoto(brand, all)

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BrandHero(brand: brand, photo: photo, browser: $browser) { toast = $0 }
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 110 } action: { gone in
                        withAnimation(.easeInOut(duration: 0.2)) { heroGone = gone }
                    }
                    // Where the page's top is: above 0 it is being pulled down,
                    // below it the page has scrolled.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { scroll.top(at: $0) }

                if all.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(brand.name) sells on its own site")
                            .font(.headline)
                        Text("Their catalog isn't in Marracat yet. Tap “Website” to shop it directly.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(16)
                } else {
                    Text("\(shown.count) items").font(.subheadline).foregroundStyle(.secondary)
                        .padding(12)
                    if shown.isEmpty {
                        if filters.offers.contains(.clean) && !all.isEmpty {
                            CleanEmptyState(filters: $filters)
                        } else {
                            Text("No items match those filters.")
                                .font(.subheadline).foregroundStyle(.secondary).padding(12)
                        }
                    }
                    ProductGrid(products: shown)
                        // The last row clears the pill.
                        .padding(.bottom, 64)
                }
            }
        }
        // The photo runs up under the status bar and the clear bar.
        .ignoresSafeArea(edges: .top)
        // Pulled down past the top: the brand's name, huge, in the photo's
        // colours, rides just above the photo (it used to be a flat grey).
        .background(alignment: .top) { BrandPullSpace(scroll: scroll, name: brand.name, colors: palette) }
        // Filters and Sort by the thumb, just above the tab bar: away while
        // scrolling down, back on a short scroll up.
        .overlay(alignment: .bottom) {
            if !all.isEmpty { BottomFilters(scroll: scroll, products: all, filters: $filters) }
        }
        .task(id: photo) { palette = await PhotoPalette.load(photo, width: 1200) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if heroGone {
                    CenteredBarTitle { MarqueeText(text: brand.name) }
                        .transition(.opacity)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("brandBarTitle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { BrandMoreMenu(brand: brand) }
        }
    }
}


/// The top of a brand page (owner, 2026-10-31, picked from previews: "H2 ·
/// Side rail"): a tall photo under the status bar, the name over its foot,
/// and the brand's four actions down the right edge as icons: Website,
/// Instagram, Sale alerts, Watch drops. Share and Boost are in the ⋯ menu.
private struct BrandHero: View {
    let brand: Brand
    let photo: String?
    @Binding var browser: IdentifiedURL?
    var done: (ActionToastMessage) -> Void = { _ in }
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Everything is laid over a frame of the screen's width: a filling
        // photo in a ZStack widened the header past the screen and pushed
        // the rail off its right edge (caught by the UI tests, 2026-10-31).
        Theme.tile
            .frame(maxWidth: .infinity)
            .frame(height: 580)
            .overlay {
                // Decorative, and sized to the header: a filling photo's own
                // frame overflows it, which VoiceOver would read as the header.
                if let photo {
                    RemoteImage(url: photo, width: 1200, contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
            .overlay {
                // Dark at the top for the status bar and back button, clear in
                // the middle for the photo, dark at the foot for the name.
                LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                       .init(color: .clear, location: 0.22),
                                       .init(color: .clear, location: 0.45),
                                       .init(color: .black.opacity(0.88), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottom) { foot }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("brandHero")
    }

    /// The name over the photo's foot, and the rail beside it.
    private var foot: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let origin = brand.shipsFromLabel {
                    Text(origin.uppercased())
                        .font(.caption.weight(.semibold)).tracking(1.5)
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityLabel(origin)
                        .accessibilityIdentifier("brandShipsFrom")
                }
                Text(brand.name)
                    .font(.largeTitle.bold()).foregroundStyle(.white)
                    .lineLimit(2).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let t = brand.tagline {
                    Text(t).font(.subheadline).foregroundStyle(.white.opacity(0.9))
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                Button { browser = IdentifiedURL(url: brand.storeURL) } label: { RailIcon(symbol: "safari") }
                    // "Website", not "Visit <domain>" (owner, 2026-10-05).
                    .accessibilityLabel("Website")
                    .accessibilityHint("Opens \(brand.domain)")
                    .accessibilityIdentifier("brandWebsite")
                // Only when the brand's own site links its account
                // (owner, 2026-10-17). Opens the Instagram app when it's
                // installed, else instagram.com.
                if let ig = brand.instagramURL {
                    Button {
                        Analytics.shared.track("brand_instagram", ["brand": .string(brand.id)])
                        openURL(ig)
                    } label: { RailIcon(symbol: "camera") }
                        .accessibilityLabel("Instagram")
                        .accessibilityHint("Opens @\(brand.instagram ?? "") on Instagram")
                        .accessibilityIdentifier("brandInstagram")
                }
                SaleAlertButton(brand: brand, done: done)
                DropWatchButton(brand: brand)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
    }
}

/// One of the hero's round buttons: frosted over the photo, solid white
/// while it's on (an alert being kept).
private struct RailIcon: View {
    let symbol: String
    var on = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(on ? Color.black : Color.white)
            .frame(width: 48, height: 48)
            .background { Circle().fill(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)) }
            .overlay { Circle().strokeBorder(.white.opacity(on ? 0 : 0.35), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            .contentShape(Circle())
    }
}

/// Share and Boost, off the page (owner, 2026-10-31: "remove the button for
/// share"), in the bar's ⋯ menu.
private struct BrandMoreMenu: View {
    let brand: Brand
    @State private var sharing = false
    @State private var boosting = false

    var body: some View {
        Menu {
            Button {
                Analytics.shared.track("share", ["kind": .string("brand"), "target": .string(brand.id)])
                sharing = true
            } label: { Label("Share", systemImage: "square.and.arrow.up") }
            if BoostStore.shared.enabled {
                Button { boosting = true } label: { Label("Boost", systemImage: "flame") }
            }
        } label: {
            if #available(iOS 26, *) {
                Image(systemName: "ellipsis")
            } else {
                // Before the glass bar, a frosted disc keeps it readable on the photo.
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34).background(.ultraThinMaterial, in: Circle())
            }
        }
        .accessibilityIdentifier("brandMore")
        // The brand's page on marracat.com, with its own link preview.
        .sheet(isPresented: $sharing) {
            ActivitySheet(items: [URL(string: "https://marracat.com/b/\(brand.id)")!])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $boosting) { BoostSheet(target: .brand(brand)) }
    }
}

/// The system share sheet, for a share started from a menu (a ShareLink
/// can't be opened from code).
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ProductGrid: View {
    let products: [Product]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Widths.gridTile), spacing: 12, alignment: .top)], spacing: 18) {
            ForEach(Array(products.enumerated()), id: \.element.id) { i, p in
                ProductTile(product: p)
                    .onAppear { ImageLoader.shared.prefetch(after: i, in: products, width: 400) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }
}

/// Category, deals, new arrivals, saved list: a filterable, sortable grid.
struct ProductGridScreen: View {
    let title: String
    let products: [Product]
    var emptyText = String(localized: "Nothing here yet.", comment: "Empty list message")
    /// A department's id: one sponsored product fitting it goes on top.
    var sponsoredCategory: String? = nil
    @Environment(CatalogStore.self) private var catalog
    @State private var filters = ProductFilters()
    @State private var sponsored: [SponsoredStore.Item] = []
    /// The big title has scrolled up under the bar, so the bar carries it
    /// (owner, 2026-10-31: "the category name should show in the header").
    @State private var titleInBar = false
    /// Filters and Sort in the pill above the tab bar, away on the way down,
    /// as on a brand page (owner, 2026-11-10: "we should have the same lock
    /// filter on categories as well"). The sheet offers only the groups that
    /// narrow this list, so it fits the category.
    @State private var scroll = BrandScroll()

    var body: some View {
        let shown = catalog.inStockFirst(filters.apply(products))

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title2.bold())
                    Spacer()
                    Text("\(shown.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(12)
                .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 8 } action: { gone in
                    withAnimation(.easeInOut(duration: 0.2)) { titleInBar = gone }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { scroll.top(at: $0) }
                if shown.isEmpty {
                    if filters.offers.contains(.clean) && !products.isEmpty {
                        CleanEmptyState(filters: $filters)
                    } else {
                        Text(filters.isEmpty ? emptyText : String(localized: "No items match those filters.", comment: "Empty list message when filters exclude everything"))
                            .font(.subheadline).foregroundStyle(.secondary).padding(12)
                    }
                }
                if !sponsored.isEmpty && filters.isEmpty {
                    SponsoredProductRow(items: sponsored, placement: "category")
                }
                ProductGrid(products: shown)
                    // The last row clears the pill.
                    .padding(.bottom, products.isEmpty ? 0 : 64)
            }
        }
        .overlay(alignment: .bottom) {
            if !products.isEmpty { BottomFilters(scroll: scroll, products: products, filters: $filters) }
        }
        .background(Theme.surface)
        .marracatChrome()
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Only there once the big title has gone, so VoiceOver and the
                // UI tests don't find a second, invisible title.
                if titleInBar {
                    CenteredBarTitle {
                        VStack(spacing: 1) {
                            MarqueeText(text: title)
                            Text("\(shown.count) items", comment: "Under a category name in the top bar; the argument is how many products it shows")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .transition(.opacity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("gridBarTitle")
                }
            }
        }
        .task(id: sponsoredCategory) {
            if let id = sponsoredCategory { sponsored = await SponsoredStore.items("category", category: id, catalog: catalog) }
        }
    }
}

/// "Watch drops" (owner, 2026-10-20): a notification and an email when the
/// brand adds new products, in every department or only the ones picked
/// (web/server/deal-alerts.js, checked with each catalog publish).
private struct DropWatchButton: View {
    let brand: Brand
    @State private var choosing = false
    private var store: DealAlertStore { .shared }

    var body: some View {
        let on = store.drops[brand.id] != nil
        Button { choosing = true } label: {
            RailIcon(symbol: on ? "sparkles" : "sparkle", on: on)
        }
        .accessibilityLabel(on ? "Watching drops" : "Watch drops")
        .disabled(store.busy.contains(brand.id))
        .accessibilityIdentifier("watchDrops")
        .accessibilityValue(on ? "On" : "Off")
        .sheet(isPresented: $choosing) { DropWatchSheet(brand: brand) }
    }
}

/// What to hear about: everything new, or only some of the brand's
/// departments (the ones it sells, with how many products in each).
struct DropWatchSheet: View {
    let brand: Brand
    @Environment(CatalogStore.self) private var catalog
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var loaded = false
    private var store: DealAlertStore { .shared }

    /// The brand's departments, biggest first.
    private var departments: [(id: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for p in catalog.products(for: brand.id) where !p.category.isEmpty { counts[p.category, default: 0] += 1 }
        return counts.map { (id: $0.key, name: catalog.category($0.key)?.name ?? $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    var body: some View {
        let watching = store.drops[brand.id] != nil
        NavigationStack {
            List {
                Section {
                    Text("Get a notification and an email when \(brand.name) adds new products.",
                         comment: "Watch drops sheet; the argument is a brand name")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    row(String(localized: "Everything new", comment: "Watch drops: every department"), on: picked.isEmpty, id: "dropAll") { picked = [] }
                    if departments.count > 1 {
                        ForEach(departments, id: \.id) { d in
                            row("\(d.name) (\(d.count))", on: picked.contains(d.id), id: "dropCategory") {
                                picked.formSymmetricDifference([d.id])
                            }
                        }
                    }
                } header: {
                    Text("Notify me about", comment: "Watch drops sheet heading")
                }
                if watching {
                    Section {
                        Button(role: .destructive) {
                            Task { if await store.stopDrops(brand.id, account: account) { dismiss() } }
                        } label: { Text("Stop watching", comment: "Watch drops: turn off") }
                        .accessibilityIdentifier("dropWatchStop")
                    }
                }
            }
            .navigationTitle(Text("New from \(brand.name)", comment: "Watch drops sheet title; the argument is a brand name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(watching ? String(localized: "Save", comment: "Watch drops: save changes") : String(localized: "Watch", comment: "Watch drops: turn on")) {
                        Task {
                            let order = departments.map(\.id).filter(picked.contains)
                            if await store.watchDrops(brand.id, categories: order, account: account) { dismiss() }
                        }
                    }
                    .bold()
                    .disabled(store.busy.contains(brand.id))
                    .accessibilityIdentifier("dropWatchSave")
                }
            }
            .alert("New drops", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.message ?? "") }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            picked = Set(store.drops[brand.id] ?? [])
        }
    }

    private func row(_ title: String, on: Bool, id: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.gold).fontWeight(.semibold) }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// "Sale alerts": an email, and a push to this iPhone, when the brand marks
/// down three or more products (web/server/deal-alerts.js).
private struct SaleAlertButton: View {
    let brand: Brand
    var done: (ActionToastMessage) -> Void = { _ in }
    @Environment(AccountStore.self) private var account
    private var store: DealAlertStore { .shared }
    private var brandID: String { brand.id }

    var body: some View {
        let on = store.brands.contains(brandID)
        Button {
            Task {
                await store.toggleBrand(brandID, account: account)
                // A failure (signed out, offline) is the alert below instead.
                guard store.message == nil else { return }
                done(store.brands.contains(brandID)
                     ? .init(text: String(localized: "Sale alerts on for \(brand.name)", comment: "Toast after turning on a brand's sale alerts; the argument is the brand"), symbol: "bell.fill")
                     : .init(text: String(localized: "Sale alerts off", comment: "Toast after turning off a brand's sale alerts"), symbol: "bell.slash"))
            }
        } label: {
            RailIcon(symbol: on ? "bell.fill" : "bell", on: on)
        }
        .accessibilityLabel(on ? "Sale alerts on" : "Sale alerts")
        .disabled(store.busy.contains(brandID))
        .accessibilityIdentifier("saleAlerts")
        .alert("Sale alerts", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.message ?? "") }
    }
}
