import SwiftUI

enum Route: Hashable {
    case product(String)
    case brand(String)
    case category(String)
    case subcategory(String)
    case search(String)
    case deals
    case newArrivals
    case brands
    case saved
    /// One of the shopper's own folders of saved items, by `SavedList.id`.
    case savedFolder(String)
    case recentlyViewed
    case accountSettings
    case connections
    case checkouts
    /// One order's details, by `CheckoutRecord.id`.
    case order(String)
    /// The shopper's "notify me when it's back" alerts.
    case restockAlerts
    /// Products whose price the shopper tracks, and brands whose sales they follow.
    case priceAlerts
    /// You › Notifications: Live Activities for today's deliveries.
    case notifications
    case about
    /// Someone's profile, by @handle.
    case profile(String)
    case friends
    case inbox
    case blocked
    /// A "Shop by style" board (MeaningFeatures.swift).
    case style(String)
    /// The shopper's written interests (Interests.swift).
    case interests
    case yourTaste
    /// You › For brands: verify a brand, see and pause its ads.
    case forBrands
    /// A holiday event's collection, by `HolidayCollection.id` (holidays.json).
    case collection(String)
    /// A search from Advanced search: the words and the filters picked there.
    case advancedSearch(String, ProductFilters)
    /// A shopping alert's products (weekly picks, several price drops), by id.
    case picks(String, [String])
}

@Observable
final class Router {
    var path: [Route] = []
}

/// One NavigationStack per tab, each with its own path. The system tab bar is
/// hidden in favour of FloatingTabBar; content keeps clear of it with a bottom
/// inset, and tapping the selected tab again pops back to the root.
struct TabRoot<Content: View>: View {
    let tab: AppTab
    @Environment(AppNav.self) private var nav
    @State private var router = Router()
    @Environment(CatalogStore.self) private var catalog
    @ViewBuilder var content: Content
    /// A tapped product photo grows into its page (ProductZoom.swift).
    @Namespace private var productZoom

    private var waiting: Bool { tab != .home && !catalog.isComplete }

    var body: some View {
        NavigationStack(path: $router.path) {
            // Home draws from its slice of the catalog; every other tab waits
            // for the whole of it under a spinner. An overlay, not a swap: a
            // conditional view at the stack's root cost Home its scroll
            // position on the way back from a product
            // (testHomeKeepsItsPlaceAfterViewingAProduct).
            // Under the search overlay the page (and anything pushed on it)
            // is out of VoiceOver's reach. Hidden from outside the stack (the
            // TabView, the stack itself) it all stayed reachable: the search
            // screen's audit read Home's hero and chips through the overlay
            // (2026-10-12). Each page has to be hidden from inside.
            content
                .accessibilityHidden(waiting || nav.search != nil)
                .overlay { if waiting { CatalogLoading() } }
                .navigationDestination(for: Route.self) { route in
                    FullCatalogGate { RouteView(route: route) }.accessibilityHidden(nav.search != nil)
                        .modifier(ProductZoomDestination(id: route.productID))
                }
        }
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: nav.reselected[tab]) {
            if !router.path.isEmpty { router.path.removeAll() }
        }
        .onAppear {
            nav.routers[tab] = router
            if let path = nav.pendingPaths.removeValue(forKey: tab) { router.path = path }
        }
        .environment(router)
        .environment(\.currentTab, tab)
        .environment(\.productZoom, productZoom)
    }
}

extension EnvironmentValues {
    /// The tab a view lives in — search pushes its results onto that tab's stack.
    @Entry var currentTab: AppTab = .home
}

/// A screen that needs the whole catalog — every brand's products, a
/// department, search — shows a spinner for the moment between Home drawing
/// from its slice (HomeSlice) and the rest of the catalog landing behind it.
/// Before 2026-10-11 the whole app waited for it under the launch cover.
struct FullCatalogGate<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        if catalog.isComplete {
            content
        } else {
            CatalogLoading()
        }
    }
}

/// The spinner a screen shows while the whole catalog is still loading.
struct CatalogLoading: View {
    var body: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .accessibilityLabel("Loading the catalog")
            .accessibilityIdentifier("catalogLoading")
    }
}

struct RouteView: View {
    let route: Route
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper

    var body: some View {
        screen.analyticsScreen(Self.screenName(route))
    }

    /// The name a screen view is counted under (Analytics).
    static func screenName(_ route: Route) -> String {
        switch route {
        case .product: "product"
        case .brand: "brand"
        case .category, .deals, .newArrivals, .style, .collection, .picks: "browse"
        case .subcategory: "aisle"
        case .search, .advancedSearch: "search"
        case .brands: "brand"
        case .saved, .recentlyViewed: "saved"
        case .savedFolder: "lists"
        case .accountSettings, .connections, .about, .forBrands: "account"
        case .checkouts: "orders"
        case .order: "order_detail"
        case .restockAlerts, .priceAlerts, .interests, .notifications: "alerts"
        case .yourTaste: "taste"
        case .profile, .friends, .inbox, .blocked: "social"
        }
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .product(let id): ProductDetailView(productID: id)
        case .brand(let id): BrandStoreView(brandID: id)
        case .category(let id):
            ProductGridScreen(title: catalog.category(id)?.name ?? String(localized: "Category", comment: "Fallback screen title"),
                              products: catalog.inStockFirst(catalog.interleaveBrands(Array(catalog.products(in: id)))),
                              sponsoredCategory: id)
        case .subcategory(let id):
            ProductGridScreen(title: catalog.subcategory(id)?.name ?? String(localized: "Shop", comment: "Fallback screen title"),
                              products: catalog.inStockFirst(catalog.interleaveBrands(catalog.products(inSub: id))))
        case .search(let q): SearchResultsView(query: q)
        case .advancedSearch(let q, let filters): SearchResultsView(query: q, filters: filters)
        case .deals: ProductGridScreen(title: String(localized: "Deals", comment: "Screen title"), products: Array(catalog.deals))
        case .picks(let title, let ids):
            ProductGridScreen(title: title.isEmpty ? String(localized: "For you", comment: "Screen title for a shopping alert's products") : title,
                              products: ids.compactMap(catalog.product))
        case .collection(let id):
            ProductGridScreen(title: HolidayCalendar.collection(id)?.title ?? String(localized: "Shop", comment: "Fallback screen title"),
                              products: catalog.products(inCollection: id))
        // Newest first, one brand at a time: a shop that put up hundreds
        // of products in a day takes a turn, not the whole screen.
        case .newArrivals: ProductGridScreen(title: String(localized: "New arrivals", comment: "Screen title"),
                                             products: CatalogStore.spread(Array(catalog.newArrivals), limit: catalog.newArrivals.count))
        case .brands: BrandsView()
        case .saved:
            ProductGridScreen(title: String(localized: "All saved", comment: "Saved screen title or empty state"), products: shopper.saved.compactMap(catalog.product),
                              emptyText: String(localized: "Tap “Add to List” on any item to save it here.", comment: "Saved screen title or empty state"))
        case .savedFolder(let id): FolderView(listID: id)
        case .recentlyViewed:
            ProductGridScreen(title: String(localized: "Recently viewed", comment: "Recently viewed screen title or empty state"), products: shopper.recentlyViewed.compactMap(catalog.product),
                              emptyText: String(localized: "Products you open show up here.", comment: "Recently viewed screen title or empty state"))
        case .accountSettings: AccountSettingsScreen()
        case .connections: ConnectionsScreen()
        case .checkouts: CheckoutsView()
        case .order(let id): OrderDetailView(recordID: id)
        case .restockAlerts: RestockAlertsView()
        case .priceAlerts: PriceAlertsView()
        case .notifications: NotificationsView()
        case .style(let id): StyleScreen(styleID: id)
        case .interests: InterestsScreen()
        case .yourTaste: YourTasteScreen()
        case .forBrands: ForBrandsScreen()
        case .about: AboutView()
        case .profile(let handle): ProfileScreen(handle: handle)
        case .friends: FriendsScreen().marracatChrome()
        case .inbox: InboxScreen().marracatChrome()
        case .blocked: BlockedScreen().marracatChrome()
        }
    }
}

/// iPadOS 26 puts a windowed app's close/minimize/resize buttons at the
/// top-left, in the navigation bar's row. The bar lays its items out after
/// them, so the search field has to give up that width or it runs off the
/// window's right edge; the search overlay has to start after them too. A
/// full-screen app keeps them up in the status bar, out of the way.
enum WindowControls {
    /// Where the search field starts, past the buttons. The bar centres the
    /// field in the space right of the buttons (which ends at 72pt), so with a
    /// 16pt right margin it starts at 88 (measured on iPadOS 26.5).
    static let clearance: CGFloat = 88

    /// Extra leading room the bar needs beyond its usual 16pt margin; zero on
    /// iPhone and on a full-screen iPad app.
    static var extraInset: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.keyWindow,
              window.bounds.size != scene.screen.bounds.size else { return 0 }
        return clearance - 16
    }
}

/// The chrome every screen shares: a dark bar with the screen's title, kept
/// visible (never hidden) so interactive swipe-back keeps working on pushed
/// screens. Search isn't up here any more (owner, 2026-10-20, after IMDb):
/// Browse, Saved, You and Your Orders float a search bar just above the tab
/// bar instead, and Home has none.
struct MarracatChrome: ViewModifier {
    var query: String?
    /// What the floating search bar does on this screen, if it has one.
    var bottomSearch: BottomSearch?
    /// Home: no bar at all; the page starts under the status bar.
    var hidesBar = false
    /// The bar's own background: a brand page clears it over its photo, then
    /// brings it back once the photo scrolls away.
    var barShown = true
    @Environment(\.tabBarClearance) private var tabBarClearance
    @Environment(AppNav.self) private var nav
    @State private var typing = false

    func body(content: Content) -> some View {
        content
            // Every screen's feed shrinks the tab bar on the way down and grows
            // it on the way up (owner, 2026-11-05: Instagram's bar).
            .minimizesTabBarOnScroll()
            // Keep scroll content clear of the floating tab bar (and the search
            // bar above it). This has to sit on each screen: an inset on the
            // NavigationStack never reached the scroll views, so the last row
            // ("About Marracat") hid under the bar. While typing, the keyboard
            // covers the tab bar, so the search bar sits right on the keyboard.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let bottomSearch {
                        // Typing, the field moves out to iMessage's 8pt margins
                        // to make room for the ✕ (owner, 2026-10-22).
                        FloatingSearchBar(search: bottomSearch, typing: $typing)
                            .padding(.horizontal, typing ? 8 : 16)
                            .animation(.snappy(duration: 0.25), value: typing)
                            .padding(.bottom, 8)
                            // Follows the shrunk tab bar down so the gap between
                            // them stays the same; a visual move only, so the
                            // feed's inset (and scroll position) doesn't jump.
                            // And shrinks a little with it (owner, 2026-11-05: "our
                            // search bar should minimize a little too"); a tap on
                            // it while small still opens search or starts typing,
                            // and brings both bars back to full size.
                            .scaleEffect(nav.tabBarCompact && !typing ? FloatingSearchBar.compactScale : 1, anchor: .bottom)
                            .offset(y: nav.tabBarCompact && !typing && tabBarClearance > 0 ? FloatingTabBar.compactDrop : 0)
                    }
                    Color.clear.frame(height: typing ? 0 : tabBarClearance)
                }
            }
            .navigationTitle(query ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbarBackground(Theme.header, for: .navigationBar)
            .toolbarBackground(barShown ? .visible : .hidden, for: .navigationBar)
            .toolbar(hidesBar ? .hidden : .automatic, for: .navigationBar)
    }
}

/// A title for the middle of the top bar, centred on the screen (owner,
/// 2026-11-01: "center the brand name on the header"). The bar's editor
/// role, which keeps "Back" off the back button, also lays the middle item
/// out from the back button, so a short name sat left of centre. A hidden
/// copy takes the place the bar gives it; the visible one is moved to the
/// screen's centre, as wide as fits with the back button's margin on both
/// sides, so it never runs under a trailing button (⋯) either.
struct CenteredBarTitle<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var placed: CGRect = .zero

    var body: some View {
        let width = Self.windowWidth
        let usable = width > 0 && !placed.isEmpty && placed.minX < width / 2
        content()
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { placed = $0 }
            .overlay {
                if usable {
                    content()
                        .frame(width: width - 2 * placed.minX)
                        .offset(x: width / 2 - placed.midX)
                } else {
                    content()
                }
            }
    }

    @MainActor static var windowWidth: CGFloat {
        UIApplication.shared.connectedScenes.lazy
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }.first ?? 0
    }
}

extension View {
    func marracatChrome(query: String? = nil) -> some View { modifier(MarracatChrome(query: query)) }
    /// A screen whose top is a photo: no bar background until `barShown`.
    func marracatChrome(barShown: Bool) -> some View { modifier(MarracatChrome(barShown: barShown)) }
    /// A screen that searches its own list (Saved, You, Your Orders). Saved
    /// and You title themselves in the page, so they hide the bar.
    func marracatChrome(localSearch: LocalSearch, hidesBar: Bool = false) -> some View {
        modifier(MarracatChrome(bottomSearch: .local(localSearch), hidesBar: hidesBar))
    }
    /// Browse: the floating bar opens store-wide search, and no top bar
    /// (owner, 2026-10-21: "remove this browse header").
    func marracatChrome(storeSearch: Bool) -> some View {
        modifier(MarracatChrome(bottomSearch: storeSearch ? .store : nil, hidesBar: true))
    }
    /// Home: no bar.
    func marracatChromeHidden() -> some View { modifier(MarracatChrome(hidesBar: true)) }
}

enum BottomSearch {
    /// Opens the full-screen store search (SearchOverlay).
    case store
    /// Filters the screen's own list as you type.
    case local(LocalSearch)
}

/// What a screen's own search field filters, and what it says.
struct LocalSearch {
    var text: Binding<String>
    var prompt: String
    var identifier: String
}

/// The search bar floating just above the tab bar, IMDb-style (owner,
/// 2026-10-20). On Browse it opens store search; on Saved, You and Your
/// Orders you type straight into it and the page narrows as you go, and an
/// ✕ beside it ends the search. While typing it rides on the keyboard.
/// Sized and frosted like iMessage's search bar (owner, 2026-10-22): a 48pt
/// field of clear Liquid Glass, and a 48pt glass ✕ circle 12pt to its right.
struct FloatingSearchBar: View {
    static let height: CGFloat = 48
    /// While the tab bar is shrunk: 48 pt becomes 44 pt, Apple's minimum target.
    static let compactScale: CGFloat = 0.92
    let search: BottomSearch
    @Binding var typing: Bool
    @Environment(AppNav.self) private var nav
    @Environment(\.currentTab) private var currentTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    /// On a holiday the bar wears its colours: a border that slowly turns
    /// and a soft glow (owner, 2026-10-21: "search bar highlighted/animated
    /// and with a glow for the events"). Still with Reduce Motion on.
    @State private var holiday = HolidayCalendar.current()
    @State private var spin = 0.0

    var body: some View {
        HStack(spacing: 12) {
            switch search {
            case .store:
                Button { nav.openSearch(from: currentTab) } label: {
                    capsule {
                        Text("Search Marracat", comment: "Search field placeholder").foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 0)
                    }
                }
                // No pressed-state dimming: search opens over it at once.
                .buttonStyle(NoHighlightButtonStyle())
                .accessibilityIdentifier("searchField")
            case .local(let s):
                capsule {
                    TextField(s.prompt, text: s.text, prompt: Text(s.prompt).foregroundStyle(Theme.textSecondary))
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { focused = false }
                        .accessibilityIdentifier(s.identifier)
                    if !s.text.wrappedValue.isEmpty {
                        Button { s.text.wrappedValue = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("Clear search")
                    }
                }
                if focused {
                    Button {
                        s.text.wrappedValue = ""
                        focused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: Self.height, height: Self.height)
                            .glass(in: Circle())
                            // The whole circle is the button, not just the glyph.
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityLabel("Close search")
                    .accessibilityIdentifier(s.identifier + "Close")
                }
            }
        }
        .onChange(of: focused) {
            typing = focused
            if focused { nav.setTabBarCompact(false) }
        }
        .animation(.snappy(duration: 0.25), value: focused)
        .onAppear {
            holiday = HolidayCalendar.current()
            guard holiday != nil, !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = 360 }
        }
    }

    /// The day's colours turning round the pill's edge: a square of angular
    /// gradient, rotated, seen only through the border.
    @ViewBuilder
    private var holidayRim: some View {
        if let holiday {
            let colors = holiday.tabColors
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height) * 1.2
                AngularGradient(colors: colors + [colors.first ?? .white], center: .center)
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(spin))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .mask(Capsule().strokeBorder(lineWidth: 2))
            .allowsHitTesting(false)
        }
    }

    /// The pill: clear glass over whatever scrolls behind it. On a holiday it
    /// also glows in the day's first colour.
    private func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            content()
        }
        .font(.body)
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .glass(in: Capsule())
        .overlay(holidayRim)
        .shadow(color: holiday.map { ($0.tabColors.first ?? .black).opacity(0.6) } ?? .clear, radius: 14)
        .contentShape(Capsule())
    }
}

extension View {
    /// Clear Liquid Glass on iOS 26: what scrolls behind stays readable, with
    /// the system's light rim. Earlier iOS gets the frosted material and a
    /// hairline instead.
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(Theme.hairline))
        }
    }
}

struct NoHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
