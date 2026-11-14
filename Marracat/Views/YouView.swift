import SwiftUI

/// The You tab, laid out like a travel app's profile: who you are and your
/// numbers up top, the places you go most as tiles, then the settings list.
/// Account controls live one tap away in Account settings.
struct YouView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @Environment(AccountStore.self) private var account
    @Environment(SocialStore.self) private var social
    @Environment(RestockStore.self) private var restock
    @State private var privacy = false
    /// The saved shipping details, now filled from the first order's address
    /// rather than a form before checkout (owner, 2026-11-02): here they can
    /// be seen, changed or forgotten.
    @State private var shippingDetails = false
    /// The floating bar's search: rows here and the settings behind them.
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Profile").font(.largeTitle.bold()).padding(.horizontal, 16).padding(.top, 8)
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    identityCard
                    tiles
                    if account.user == nil { signInCard }
                    rows
                    recentlyViewed
                } else {
                    results
                }
            }
            .padding(.bottom, 24)
            .readableWidth()
        }
        .background(Theme.canvas)
        .sheet(isPresented: $privacy) { AccountPrivacyView() }
        .sheet(isPresented: $shippingDetails) { BuyerDetailsForm() }
        .marracatChrome(localSearch: LocalSearch(text: $query,
                                                 prompt: String(localized: "Search settings and more", comment: "Search field placeholder on the You tab"),
                                                 identifier: "youSearch"), hidesBar: true)
    }

    /// Matching rows and settings, each opening where it lives.
    @ViewBuilder
    private var results: some View {
        let found = YouSearch.matches(query, signedIn: account.user != nil, social: social.signedIn)
        if found.isEmpty {
            Text("Nothing matches “\(query)”.", comment: "You-tab search found nothing; the argument is what the shopper typed")
                .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 16)
                .accessibilityIdentifier("youSearchEmpty")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(found.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Divider().padding(.leading, 52) }
                    resultRow(e)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 0.5))
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func resultRow(_ e: YouSearch.Entry) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: e.icon).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline)
                if let place = e.place { Text(place).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: e.target == .help ? "arrow.up.right" : "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        Group {
            switch e.target {
            case .route(let r): NavigationLink(value: r) { label }
            case .privacy: Button { privacy = true } label: { label }
            case .help: Link(destination: URL(string: "https://marracat.com/#/support")!) { label }
            case .logOut: Button { Task { await account.signOut() } } label: { label }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityIdentifier("youResult")
    }

    private var displayName: String {
        if let me = social.me?.profile.name, !me.isEmpty { return me }
        if let n = account.user?.name, !n.isEmpty { return n }
        return String(localized: "Guest", comment: "Name shown on the You tab when not signed in")
    }
    private var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    // MARK: Identity

    private var identityCard: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Circle().fill(Theme.field).frame(width: 84, height: 84)
                        .overlay { Text(initials).font(.title.bold()) }
                    if account.user != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3).foregroundStyle(.black, Theme.gold)
                            .offset(x: 2, y: 2)
                    }
                }
                Text(displayName).font(.headline).lineLimit(1)
                Text(account.user == nil ? "Shopping as a guest" : (social.me.map { "@\($0.profile.handle)" } ?? "Member"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                stat(shopper.checkouts.count, String(localized: "Orders", comment: "Count label under a number on the You tab"))
                Divider()
                stat(shopper.saved.count, String(localized: "Saved", comment: "Count label under a number on the You tab"))
                Divider()
                stat(shopper.lists.count, shopper.lists.count == 1 ? String(localized: "List", comment: "Count label under a number on the You tab") : String(localized: "Lists", comment: "Count label under a number on the You tab"))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("profileCard")
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 12) {
            tile(String(localized: "Orders", comment: "Tile on the You tab"), systemImage: "bag", route: .checkouts, id: "tileOrders")
            tile(String(localized: "Lists", comment: "Tile on the You tab"), systemImage: "heart", route: .saved, id: "tileLists")
            if social.signedIn { tile(String(localized: "Connect", comment: "Tile on the You tab"), systemImage: "person.2", route: .connections, id: "tileConnections") }
        }
        .padding(.horizontal, 16)
    }

    private func tile(_ title: String, systemImage: String, route: Route, id: String) -> some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage).font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.field))
                Text(title).font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var signInCard: some View {
        NavigationLink(value: Route.accountSettings) {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.title)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Make Marracat yours").font(.subheadline.bold())
                    Text("Sign in to keep your lists, orders and history across devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("signInCard")
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            NavigationLink(value: Route.accountSettings) { row(String(localized: "Account settings", comment: "Row in the You tab menu"), "gearshape") }
                .buttonStyle(.plain).accessibilityIdentifier("accountSettings")
            Divider().padding(.leading, 52)
            Link(destination: URL(string: "https://marracat.com/#/support")!) { row(String(localized: "Get help", comment: "Row in the You tab menu"), "questionmark.circle", external: true) }
                .buttonStyle(.plain).foregroundStyle(.primary)
            Divider().padding(.leading, 52)
            Button { privacy = true } label: { row(String(localized: "Privacy", comment: "Row in the You tab menu"), "hand.raised") }
                .buttonStyle(.plain).accessibilityIdentifier("privacyRow")
            Divider().padding(.leading, 52)
            Button { shippingDetails = true } label: { row(String(localized: "Shipping address", comment: "Row in the You tab menu"), "shippingbox") }
                .buttonStyle(.plain).accessibilityIdentifier("shippingDetailsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.restockAlerts) {
                row(restock.alerts.isEmpty ? String(localized: "Restock alerts", comment: "Row in the You tab menu") : String(localized: "Restock alerts (\(restock.alerts.count))", comment: "Row in the You tab menu"), "bell")
            }
                .buttonStyle(.plain).accessibilityIdentifier("restockAlertsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.priceAlerts) {
                let n = DealAlertStore.shared.prices.count + DealAlertStore.shared.brands.count + DealAlertStore.shared.drops.count
                row(n == 0 ? String(localized: "Price & sale alerts", comment: "Row in the You tab menu") : String(localized: "Price & sale alerts (\(n))", comment: "Row in the You tab menu"), "tag")
            }
                .buttonStyle(.plain).accessibilityIdentifier("priceAlertsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.notifications) { row(String(localized: "Notifications", comment: "Row in the You tab menu"), "bell.badge") }
                .buttonStyle(.plain).accessibilityIdentifier("notificationsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.yourTaste) { row(String(localized: "Your taste", comment: "Row in the You tab menu: what the app has learned the shopper likes"), "person.crop.circle.badge.checkmark") }
                .buttonStyle(.plain).accessibilityIdentifier("yourTasteRow")
            NavigationLink(value: Route.interests) { row(String(localized: "Interests", comment: "Row in the You tab menu"), "sparkles") }
                .buttonStyle(.plain).accessibilityIdentifier("interestsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.forBrands) { row(String(localized: "For brands", comment: "Row in the You tab menu"), "megaphone") }
                .buttonStyle(.plain).accessibilityIdentifier("forBrandsRow")
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.brands) { row(String(localized: "Brands", comment: "Row in the You tab menu"), "storefront") }
                .buttonStyle(.plain)
            Divider().padding(.leading, 52)
            NavigationLink(value: Route.about) { row(String(localized: "About Marracat", comment: "Row in the You tab menu"), "info.circle") }
                .buttonStyle(.plain)
            if account.user != nil {
                Divider().padding(.leading, 52)
                Button { Task { await account.signOut() } } label: { row(String(localized: "Log out", comment: "Row in the You tab menu"), "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.plain).accessibilityIdentifier("logOutRow")
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 0.5))
        .padding(.horizontal, 16)
    }

    private func row(_ title: String, _ systemImage: String, external: Bool = false) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage).frame(width: 24)
            Text(title).font(.subheadline)
            Spacer()
            Image(systemName: external ? "arrow.up.right" : "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var recentlyViewed: some View {
        let recent = shopper.recentlyViewed.compactMap(catalog.product)
        if !recent.isEmpty {
            ProductRow(title: String(localized: "Keep shopping for", comment: "Product row title: recently viewed products"), products: Array(recent.prefix(12)))
        }
    }
}

/// Sign-in, sync, personalization and the account's data controls.
struct AccountSettingsScreen: View {
    var body: some View {
        ScrollView {
            AccountPanel().padding(.bottom, 24).readableWidth()
        }
        .background(Theme.canvas)
        .navigationTitle("Account settings")
        .navigationBarTitleDisplayMode(.inline)
        .marracatChrome()
    }
}

/// Friends, shares and the public profile.
struct ConnectionsScreen: View {
    var body: some View {
        ScrollView {
            SocialPanel().padding(.top, 12).padding(.bottom, 24).readableWidth()
        }
        .background(Theme.canvas)
        .navigationTitle("Connect")
        .navigationBarTitleDisplayMode(.inline)
        .marracatChrome()
    }
}

struct CheckoutCard: View {
    let record: CheckoutRecord
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(catalog.brand(record.brandID)?.name ?? String(localized: "Brand", comment: "Fallback when a brand name is unknown")).font(.subheadline.bold())
            Text(record.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            ProductImageWell(url: record.productIDs.first.flatMap(catalog.product)?.images.first, width: 240).frame(width: 110)
                .accessibilityLabel("Purchased item image")
            if let item = record.items?.first {
                Label(item.title, systemImage: "bag").font(.caption).lineLimit(3)
            }
            Text("\(record.itemCount) items · \(record.subtotal.formatted(.currency(code: record.subtotalCurrency ?? record.currency ?? "USD")))", comment: "Order summary: item count (plural variations in the catalog) and subtotal")
                .font(.caption)
        }
        .padding(10)
        .frame(width: 140, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

/// Every "notify me when it's back" this account is waiting on. Sent ones drop
/// off when the list is opened (the server marks them fulfilled).
/// You › Price & sale alerts (owner, 2026-10-05: "the list of products price
/// youre tracking should be in this list too"): tracked products with the
/// price they were tracked at and the price now, then brands whose sales are
/// followed. Swipe to stop one.
struct PriceAlertsView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(AccountStore.self) private var account
    private var store: DealAlertStore { .shared }

    var body: some View {
        List {
            if !store.prices.isEmpty {
                Section("Tracking the price") {
                    ForEach(store.prices.sorted(), id: \.self) { id in
                        let p = catalog.product(id)
                        NavigationLink(value: Route.product(id)) {
                            HStack(spacing: 12) {
                                ProductImageWell(url: p?.images.first, width: 240).frame(width: 64, height: 64)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(p?.title ?? String(localized: "Item no longer listed", comment: "Shown when an ordered product left the catalog")).font(.subheadline).lineLimit(2)
                                    if let brand = p.flatMap({ catalog.brand($0.brand) }) {
                                        Text(brand.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let p {
                                        let code = catalog.brand(p.brand)?.currencyCode ?? "USD"
                                        HStack(spacing: 6) {
                                            Text(p.price, format: .currency(code: code)).font(.caption.bold())
                                            if let was = store.trackedAt[id], abs(was - p.price) > 0.009 {
                                                Text("tracked at \(was.formatted(.currency(code: code)))")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await store.togglePrice(id, account: account) } } label: { Label("Stop", systemImage: "tag.slash") }
                        }
                        .accessibilityIdentifier("priceAlert")
                    }
                }
            }
            if !store.brands.isEmpty {
                Section("Brand sales") {
                    ForEach(store.brands.sorted(), id: \.self) { id in
                        NavigationLink(value: Route.brand(id)) {
                            Label(catalog.brand(id)?.name ?? id, systemImage: "bell.fill").font(.subheadline)
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await store.toggleBrand(id, account: account) } } label: { Label("Stop", systemImage: "bell.slash") }
                        }
                        .accessibilityIdentifier("saleAlert")
                    }
                }
            }
            if !store.drops.isEmpty {
                Section("New drops") {
                    ForEach(store.drops.keys.sorted(), id: \.self) { id in
                        NavigationLink(value: Route.brand(id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(catalog.brand(id)?.name ?? id, systemImage: "sparkles").font(.subheadline)
                                let cats = (store.drops[id] ?? []).compactMap { catalog.category($0)?.name }
                                Text(cats.isEmpty ? String(localized: "Everything new", comment: "Watch drops: every department") : cats.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 30)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { Task { await store.stopDrops(id, account: account) } } label: { Label("Stop", systemImage: "bell.slash") }
                        }
                        .accessibilityIdentifier("dropAlert")
                    }
                }
            }
            if !store.prices.isEmpty || !store.brands.isEmpty || !store.drops.isEmpty {
                Section {} footer: {
                    Text("We check prices every 15 minutes and new products every 3 hours. A drop of 5% or more, a brand marking down 3 or more items, or a watched brand's new drop gets you an email and a notification on each iPhone you're signed in on. Swipe left to stop one.")
                }
            }
        }
        .overlay {
            if !account.signedIn && !store.stubbed {
                ContentUnavailableView {
                    Label("Sign in for price alerts", systemImage: "tag")
                } description: {
                    Text("Price and sale alerts are for Marracat accounts.")
                } actions: {
                    NavigationLink("Sign in", value: Route.accountSettings)
                        .buttonStyle(PillButtonStyle(color: Theme.gold, text: .black))
                }
            } else if store.prices.isEmpty && store.brands.isEmpty && store.drops.isEmpty {
                ContentUnavailableView("No price or sale alerts", systemImage: "tag",
                                       description: Text("Tap “Track price” on an item, or “Sale alerts” or “Watch drops” on a brand's page."))
            }
        }
        .task { await store.refresh(account: account) }
        .alert("Price alerts", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.message ?? "") }
        .navigationTitle("Price & sale alerts")
        .marracatChrome()
    }
}

struct RestockAlertsView: View {
    @Environment(RestockStore.self) private var restock
    @Environment(CatalogStore.self) private var catalog
    @Environment(AccountStore.self) private var account

    var body: some View {
        List {
            Section {
                ForEach(restock.alerts) { alert in
                    let p = catalog.product(alert.productID)
                    NavigationLink(value: Route.product(alert.productID)) {
                        HStack(spacing: 12) {
                            ProductImageWell(url: p?.images.first, width: 240).frame(width: 64, height: 64)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p?.title ?? String(localized: "Item no longer listed", comment: "Shown when an ordered product left the catalog")).font(.subheadline).lineLimit(2)
                                if let v = alert.variantID, let option = p?.variants.first(where: { String($0.id) == v })?.title {
                                    Text(option).font(.caption).foregroundStyle(.secondary)
                                }
                                if let brand = p.flatMap({ catalog.brand($0.brand) }) {
                                    Text(brand.name).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await restock.remove(alert) } } label: { Label("Remove", systemImage: "bell.slash") }
                    }
                    .accessibilityIdentifier("restockAlert")
                }
            } footer: {
                if !restock.alerts.isEmpty {
                    Text("We check each brand's store every few minutes. When an item is back we email you once and notify each iPhone you're signed in on. Swipe left to stop an alert.")
                }
            }
        }
        .overlay {
            if !account.signedIn && !restock.stubSignedIn {
                ContentUnavailableView {
                    Label("Sign in for restock alerts", systemImage: "bell")
                } description: {
                    Text("Restock alerts are for Marracat accounts. Sign in, then tap “Notify me when it's back” on a sold-out item.")
                } actions: {
                    NavigationLink("Sign in", value: Route.accountSettings)
                        .buttonStyle(PillButtonStyle(color: Theme.gold, text: .black))
                        .accessibilityIdentifier("restockAlertsSignIn")
                }
            } else if restock.alerts.isEmpty {
                ContentUnavailableView("No restock alerts", systemImage: "bell",
                                       description: Text("On a sold-out item, tap “Notify me when it's back” and we'll email you, and notify this iPhone, when the brand restocks it."))
            }
        }
        .task { await restock.refresh() }
        .refreshable { await restock.refresh() }
        .alert("Restock alert", isPresented: Binding(get: { restock.message != nil }, set: { if !$0 { restock.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(restock.message ?? "") }
        .navigationTitle("Restock alerts")
        .marracatChrome()
    }
}

/// What the You tab's search finds (owner, 2026-10-20: "search through
/// settings, etc that is on the profile"): its rows and tiles, and the
/// settings one screen in, each with the words people use for it.
enum YouSearch {
    enum Target: Hashable { case route(Route), privacy, help, logOut }

    struct Entry: Identifiable, Hashable {
        let title: String
        /// Where it lives, when that's a screen further in.
        let place: String?
        let icon: String
        let target: Target
        let words: String
        var id: String { title + (place ?? "") }
    }

    static func entries(signedIn: Bool, social: Bool) -> [Entry] {
        let settings = String(localized: "Account settings", comment: "Row in the You tab menu")
        var all: [Entry] = [
            Entry(title: String(localized: "Orders", comment: "Tile on the You tab"), place: nil, icon: "bag", target: .route(.checkouts), words: "orders purchases bought checkouts receipts tracking delivery"),
            Entry(title: String(localized: "Lists", comment: "Tile on the You tab"), place: nil, icon: "heart", target: .route(.saved), words: "lists saved favorites wishlist"),
            Entry(title: settings, place: nil, icon: "gearshape", target: .route(.accountSettings), words: "account settings sign in google apple email profile"),
            Entry(title: String(localized: "Personalized recommendations", comment: "Account setting"), place: settings, icon: "sparkles", target: .route(.accountSettings), words: "personalized recommendations personalization for you"),
            Entry(title: String(localized: "Share usage analytics", comment: "Account setting"), place: settings, icon: "chart.bar", target: .route(.accountSettings), words: "analytics usage tracking data sharing"),
            Entry(title: String(localized: "Holiday app icons", comment: "Account setting"), place: settings, icon: "app.badge", target: .route(.accountSettings), words: "holiday app icon icons home screen theme"),
            Entry(title: String(localized: "Clear search and viewing history", comment: "Account setting"), place: settings, icon: "clock.arrow.circlepath", target: .route(.accountSettings), words: "clear history search viewing recent"),
            Entry(title: String(localized: "Get help", comment: "Row in the You tab menu"), place: nil, icon: "questionmark.circle", target: .help, words: "help support contact customer service returns"),
            Entry(title: String(localized: "Privacy", comment: "Row in the You tab menu"), place: nil, icon: "hand.raised", target: .privacy, words: "privacy data policy"),
            Entry(title: String(localized: "Restock alerts", comment: "Row in the You tab menu"), place: nil, icon: "bell", target: .route(.restockAlerts), words: "restock back in stock alerts notify sold out"),
            Entry(title: String(localized: "Price & sale alerts", comment: "Row in the You tab menu"), place: nil, icon: "tag", target: .route(.priceAlerts), words: "price sale alerts drops deals tracking new drop watch watching brands"),
            Entry(title: String(localized: "Notifications", comment: "Row in the You tab menu"), place: nil, icon: "bell.badge", target: .route(.notifications), words: "notifications live activities delivery push"),
            Entry(title: String(localized: "Your taste", comment: "Row in the You tab menu: what the app has learned the shopper likes"), place: nil, icon: "person.crop.circle.badge.checkmark", target: .route(.yourTaste), words: "taste styles sizes price range personalization recommendations"),
            Entry(title: String(localized: "Interests", comment: "Row in the You tab menu"), place: nil, icon: "sparkles", target: .route(.interests), words: "interests preferences likes"),
            Entry(title: String(localized: "For brands", comment: "Row in the You tab menu"), place: nil, icon: "megaphone", target: .route(.forBrands), words: "for brands boost ads sponsor verify sell"),
            Entry(title: String(localized: "Brands", comment: "Row in the You tab menu"), place: nil, icon: "storefront", target: .route(.brands), words: "brands stores shops"),
            Entry(title: String(localized: "About Marracat", comment: "Row in the You tab menu"), place: nil, icon: "info.circle", target: .route(.about), words: "about marracat version catalog"),
        ]
        if social {
            all.append(Entry(title: String(localized: "Connect", comment: "Tile on the You tab"), place: nil, icon: "person.2", target: .route(.connections), words: "connect friends social profile shares"))
        }
        if signedIn {
            all.append(Entry(title: String(localized: "Delete account", comment: "Account setting"), place: settings, icon: "trash", target: .route(.accountSettings), words: "delete account remove close"))
            all.append(Entry(title: String(localized: "Log out", comment: "Row in the You tab menu"), place: nil, icon: "rectangle.portrait.and.arrow.right", target: .logOut, words: "log out sign out logout"))
        }
        return all
    }

    /// Every word typed has to start a word of the entry's title or its
    /// search words ("notif" finds Notifications, "icon" Holiday app icons).
    static func matches(_ query: String, signedIn: Bool, social: Bool) -> [Entry] {
        let typed = SearchWords.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !typed.isEmpty else { return [] }
        return entries(signedIn: signedIn, social: social).filter { e in
            let words = SearchWords.fold(e.title + " " + e.words).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return typed.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
    }
}
