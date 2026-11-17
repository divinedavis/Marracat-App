import SwiftUI
import GoogleSignIn
import AuthenticationServices
import os
import CoreSpotlight

@main
struct MarracatApp: App {
    /// UI tests pass `-UITEST_RESET` to start from an empty cart and history.
    private static let defaults: UserDefaults = {
        if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET"),
           let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            KeychainBuyerVault().removeAll()
        }
        return .standard
    }()

    /// Set by the UI tests (MarracatUITestCase) so XCUITest isn't waiting out
    /// animations after every tap. Never set in a shipped launch.
    static let noAnimations = ProcessInfo.processInfo.environment["MARRACAT_NO_ANIMATIONS"] == "1"

    /// No catalog from the network: UI tests (-OFFLINE_CATALOG), and the app
    /// hosting the unit tests, whose own launch check raced the tests'
    /// stubbed downloads for the stored ETag (2026-10-18).
    static let offlineCatalog = ProcessInfo.processInfo.arguments.contains("-OFFLINE_CATALOG")
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// UI tests wait on an "app.ready" marker, not on any screen's layout:
    /// moving search off Home broke every test that waited on its bar
    /// (2026-10-20). Only under UI tests, so VoiceOver never meets it.
    static let readyMarker = noAnimations
        || ProcessInfo.processInfo.arguments.contains { $0 == "-UITEST_RESET" || $0 == "-OFFLINE_CATALOG" }

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var account: AccountStore
    /// Comments, profiles, friends and encrypted sharing; it signs in through
    /// the account, so the two are made together.
    @State private var social: SocialStore
    @State private var catalog: CatalogStore
    @State private var details = ProductDetailStore()
    @State private var cart = CartStore(defaults: MarracatApp.defaults)
    @State private var shopper: ShopperStore
    @State private var buyer = BuyerStore(defaults: MarracatApp.defaults)
    @State private var nav = AppNav()
    @State private var restock = RestockStore.shared
    /// The launch splash: the first time the app opens each day (owner,
    /// 2026-10-02), never on resume. UI tests pass -SKIP_SPLASH.
    @State private var showSplash = MarracatApp.splashToday()
    /// The splash played out with nobody looking (iOS started the app in the
    /// background, every 3 h since 2026-10-18): it stays up and plays again,
    /// from the start, when the app is opened (`splashRun` restarts it).
    @State private var splashUnseen = false
    @State private var splashRun = 0
    /// Every other cold launch: a skeleton of Home (LaunchSkeleton), held until
    /// Home has what it opens on, then a quick fade.
    @State private var showCover = !ProcessInfo.processInfo.arguments.contains("-SKIP_SPLASH") && !MarracatApp.splashToday()

    /// Whether the splash is still owed today, by the phone's calendar. Only
    /// read here: the day is marked when the app is actually on screen
    /// (markSplashShown). It used to be marked as the process started, and
    /// iOS starts the process early (prewarming, background refresh), so the
    /// day was spent before anyone looked (owner, 2026-10-06: "i dont think i
    /// see the splash screen on the first boot of the day").
    private static let splashKey = "splash.lastShownDay"
    private static var today: Double { Calendar.current.startOfDay(for: .now).timeIntervalSince1970 }
    private static func splashToday() -> Bool {
        !ProcessInfo.processInfo.arguments.contains("-SKIP_SPLASH") && defaults.double(forKey: splashKey) != today
    }
    /// On screen: true if this is the first time today (and marks the day).
    private static func markSplashShown() -> Bool {
        guard splashToday() else { return false }
        defaults.set(today, forKey: splashKey)
        return true
    }
    /// The images Home opens on are in memory, so it never opens on blank tiles.
    @State private var homeImagesReady = false
    /// Home has waited out its settling (`HomeSettle`) as long as the launch
    /// will wait: `settleCap` after it could first have been shown.
    @State private var settleCapped = false
    /// The longest the cover or splash waits for Home to settle, past the
    /// moment Home first had something to show.
    private static let settleCap: Duration = .seconds(2.5)

    /// Home has something to show: its slice of the catalog and the images it
    /// opens on. The cover used to lift here.
    private var homeDrawable: Bool { catalog.isReady && homeImagesReady }

    /// The cover or splash lifts: Home drawable AND settled — the whole
    /// catalog in, the page built from it, Shop by style worked out — or the
    /// cap. Owner, build 132: a fling ~1.75 s after Home appeared froze for
    /// ~280 ms as the rest of Home finished behind it; "if we have to load the
    /// screen 1 second longer so this glitch doesnt happen ... lets do that".
    private var launchReady: Bool {
        homeDrawable && ((catalog.isComplete && HomeSettle.shared.isSettled) || settleCapped)
    }
    /// The shortest the launch disc stays after landing: 0.52 s (1.05 until
    /// 2026-10-02, then 0.4 for a 40% shorter splash, then 30% slower again the
    /// same day at the owner's ask). The splash UI test passes `-SPLASH_SECONDS 6`
    /// (launch-argument defaults domain) to inspect the logo after XCUITest's
    /// launch idle wait.
    private static let splashHold: Double = {
        let v = UserDefaults.standard.double(forKey: "SPLASH_SECONDS")
        return v > 0 ? v : 0.52
    }()

    init() {
        let account = AccountStore()
        _account = State(initialValue: account)
        _social = State(initialValue: SocialStore(account: account))
        let catalog = CatalogStore(), shopper = ShopperStore(defaults: MarracatApp.defaults)
        _catalog = State(initialValue: catalog)
        _shopper = State(initialValue: shopper)
        // Siri, Shortcuts and Spotlight read the same stores (AppIntents/).
        IntentRouter.shared.catalog = catalog
        IntentRouter.shared.shopper = shopper
        MetricsReporter.shared.start()
        HitchProbe.shared.start()
        Analytics.shared.start(personalization: { [shopper] in shopper.personalizationEnabled },
                               sessionToken: { account.analyticsToken })
        // AsyncImage rides URLSession.shared; give it room so grids don't refetch on scroll.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        MemoryPressure.start(catalog: catalog)
    }

    /// marracat.com/p/<product id> → that product, on Home.
    private func openProductLink(_ url: URL) -> Bool {
        guard url.host == "marracat.com" || url.host == "www.marracat.com" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "p", catalog.product(parts[1]) != nil || !catalog.isComplete else { return false }
        nav.tab = .home
        nav.routers[.home]?.path.append(.product(parts[1]))
        return true
    }

    /// A screen Siri, Shortcuts, a Spotlight result or a marracat:// link
    /// asked for (AppDestination), once the storefront is up under the splash.
    private func openRequested() {
        guard let destination = IntentRouter.shared.openRequest, !showSplash else { return }
        IntentRouter.shared.openRequest = nil
        guard destination.exists(in: catalog) else { return }
        if nav.search != nil { nav.search = nil; nav.setTabBarHidden(false) }
        nav.show(destination.path, in: destination.tab)
    }

    /// A shopping alert waiting (InAppAlerts), and whether the splash is up.
    private struct AlertTrigger: Equatable {
        let request: UUID?
        let splash: Bool
    }

    /// What Spotlight indexes (SpotlightIndexer): it re-indexes when any of it changes.
    private struct SpotlightState: Equatable {
        let saved: [String]
        let recent: [String]
        let personalization: Bool
        let followed: Set<String>
        let catalog: String
    }

    /// What the Home Screen widgets show (WidgetSync): rewritten when any of it changes.
    private struct WidgetState: Equatable {
        let saved: [String]
        let signedIn: Bool
        let trackedAt: [String: Double]
        let checkouts: [UUID]
        let tracked: [TrackedOrder]
        let relay: [RelayEvent]
        let catalog: String
    }

    private var widgetState: WidgetState {
        WidgetState(saved: shopper.saved, signedIn: account.signedIn,
                    trackedAt: DealAlertStore.shared.trackedAt,
                    checkouts: shopper.checkouts.map(\.id),
                    tracked: OrderTrackingStore.shared.orders,
                    relay: RelayStore.shared.events,
                    catalog: catalog.stamp)
    }

    /// A tapped Live Activity (marracat://order?…) opens that order, the same
    /// way a tapped delivery notification does.
    private func openDeliveryLink(_ url: URL) -> Bool {
        guard let link = DeliveryLink(url) else { return false }
        Analytics.shared.track("notification_open", ["kind": .string("live_activity")])
        switch link {
        case .tracked(let brandID, let number):
            OrderTrackingStore.shared.openRequest = TrackedOrderRequest(orderID: number.map { "gid://shopify/Order/\($0)" }, brandID: brandID)
        case .email(let domain, let name):
            Task { await RelayStore.shared.refresh(); RelayStore.shared.openRequest = OrderEventRequest(brandDomain: domain, orderName: name) }
        case .orders:
            open(nil)
        }
        return true
    }

    /// A tapped restock notification opens its product on Home, once the
    /// storefront is up underneath the splash.
    private func openRestockedProduct() {
        guard let id = restock.openRequest, !showSplash, nav.routers[.home] != nil else { return }
        restock.openRequest = nil
        // The push says it's back; ask the store again rather than show a
        // stock answer from before it was.
        details.forgetStock(id)
        if nav.search != nil { nav.search = nil; nav.setTabBarHidden(false) }
        nav.tab = .home
        nav.routers[.home]?.path.append(.product(id))
    }

    /// Opening for the first time today: the splash, even if the process
    /// was started earlier in the background. Called as the scene leaves the
    /// background (.inactive comes before .active), so it's up before Home is
    /// drawn. The day is spent once it's on screen with the app active.
    private func splashIfFirstToday() {
        guard scenePhase != .background else { return }
        if !showSplash {
            guard Self.splashToday() else { return }
            showCover = false
            showSplash = true
        } else if splashUnseen {
            splashUnseen = false
            splashRun += 1
        }
        if scenePhase == .active { _ = Self.markSplashShown() }
    }

    /// A tapped shopping alert, or one of its buttons (owner, 2026-11-15):
    /// add it to the bag, follow the brand, or open what it's about.
    private func carryOutAlert() {
        guard let request = InAppAlerts.shared.request, !showSplash, nav.routers[.home] != nil else { return }
        InAppAlerts.shared.request = nil
        let card = request.card
        switch request.action {
        case .add:
            // Straight into the bag when there's no size to choose: the size the
            // alert named, or the only one in stock. Otherwise the product page.
            if let pid = card.pid ?? card.items?.first?.id, let product = catalog.product(pid) {
                let inStock = product.variants.filter(\.available)
                let named = card.vid.flatMap { vid in product.variants.first { String($0.id) == vid && $0.available } }
                if let v = named ?? (inStock.count == 1 ? inStock.first : nil) {
                    cart.add(productID: pid, variantID: v.id, option: product.variants.count > 1 ? v.title : nil,
                             unitPrice: v.price, currency: product.currency)
                    if nav.search != nil { nav.search = nil; nav.setTabBarHidden(false) }
                    nav.tab = .cart
                    return
                }
            }
        case .follow:
            if let bid = card.bid, !DealAlertStore.shared.brands.contains(bid) {
                Task { await DealAlertStore.shared.toggleBrand(bid, account: account) }
            }
        case .open:
            break
        }
        let fallback = card.pid.map { "marracat://product/\($0)" } ?? card.bid.map { "marracat://brand/\($0)" }
        guard let raw = card.open ?? fallback, let url = URL(string: raw), let destination = AppDestination(url: url) else { return }
        IntentRouter.shared.open(destination)
    }

    /// A tapped brand-sale notification opens that brand.
    private func openSaleBrand() {
        guard let id = DealAlertStore.shared.openBrandRequest, !showSplash, nav.routers[.home] != nil else { return }
        DealAlertStore.shared.openBrandRequest = nil
        if nav.search != nil { nav.search = nil; nav.setTabBarHidden(false) }
        nav.tab = .home
        nav.routers[.home]?.path.append(.brand(id))
    }

    /// A tapped tracking notification ("Shipped", "Delivered") opens that
    /// order's details under You › Orders.
    private func openTrackedOrder() {
        guard let request = OrderTrackingStore.shared.openRequest, !showSplash else { return }
        OrderTrackingStore.shared.openRequest = nil
        let number = request.orderID.flatMap(OrderTrackingStore.number)
        let record = shopper.checkouts.first { number != nil && $0.orderID.flatMap(OrderTrackingStore.number) == number }
            ?? shopper.checkouts.filter { $0.brandID == request.brandID }.max { $0.date < $1.date }
        open(record)
    }

    /// A tapped order-email notification (relay.js) opens the order it's about.
    private func openRelayOrder() {
        guard let request = RelayStore.shared.openRequest, !showSplash else { return }
        RelayStore.shared.openRequest = nil
        open(RelayStore.shared.record(brandDomain: request.brandDomain, orderName: request.orderName,
                                      brands: catalog.brands, orders: shopper.checkouts))
    }

    /// What each order held, so delivery pushes name it instead of "order #…".
    private func syncOrderItemNames() async {
        let titles: (CheckoutRecord) -> [String] = { r in
            if let items = r.items, !items.isEmpty { return items.map(\.title) }
            return r.productIDs.compactMap { catalog.product($0)?.title }
        }
        await RelayStore.shared.syncItemNames(orders: shopper.checkouts, brand: { catalog.brand($0) }, titles: titles)
        await OrderTrackingStore.shared.registerMissing(orders: shopper.checkouts, titles: titles)
        await OrderTrackingStore.shared.syncItemNames(orders: shopper.checkouts, titles: titles)
    }

    /// Tapped delivery notifications waiting to open, from either source.
    private struct OrderTaps: Equatable {
        let tracked: TrackedOrderRequest?
        let relay: OrderEventRequest?
    }

    /// Order details under You › Orders, or Your Orders when the order isn't
    /// on this phone. The You tab's stack only exists once that tab has been
    /// shown, so a tap before then waits in `pendingPaths` for it (owner,
    /// 2026-10-09: a tapped "Arriving today" opened nothing).
    private func open(_ record: CheckoutRecord?) {
        if nav.search != nil { nav.search = nil; nav.setTabBarHidden(false) }
        nav.show(record.map { [.checkouts, .order($0.id.uuidString)] } ?? [.checkouts], in: .you)
    }

    /// The storefront under the launch cover or splash, and what lifts them.
    private var stage: some View {
        stageContent
            // The Home Screen widgets follow saves, prices, orders and sign-in.
            .onChange(of: widgetState, initial: true) {
                WidgetSync.shared.schedule(catalog: catalog, shopper: shopper, signedIn: account.signedIn)
            }
            // A tapped shopping alert, once the splash is out of the way.
            .onChange(of: AlertTrigger(request: InAppAlerts.shared.request?.id, splash: showSplash)) { carryOutAlert() }
    }

    private var stageContent: some View {
        ZStack {
            RootView()
                .environment(catalog)
                .environment(details)
                .environment(cart)
                .environment(shopper)
                .environment(buyer)
                .environment(account)
                .environment(social)
                .environment(nav)
                .environment(restock)
                .tint(Theme.link)
                // Monochrome black-and-grey app (ASOS-style): dark system chrome,
                // dark keyboard, white status bar over the black header.
                .preferredColorScheme(.dark)
                .allowsHitTesting(!showSplash)
                .accessibilityHidden(showSplash)
                // A tap outside any text field closes the keyboard (not
                // while search is open; it handles its own).
                .background(KeyboardDismissInstaller(enabled: nav.search == nil))
            // A shopping alert while the app is open (InAppAlertBanner).
            if !showSplash {
                InAppAlertBanner()
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .zIndex(2)
            }
            if showCover {
                LaunchSkeleton()
                    .zIndex(1)
                    .transition(.opacity)
                    .onChange(of: launchReady, initial: true) { _, ready in
                        guard ready else { return }
                        withAnimation(.easeOut(duration: 0.25)) { showCover = false }
                        HitchProbe.shared.homeShown()
                        HomeSettle.shared.logLift(capped: settleCapped)
                        LaunchTiming.log.notice("launch: cover gone at \(LaunchTiming.sinceStart(), privacy: .public) ms")
                    }
            }
            if showSplash {
                // A shared compositor timeline keeps the opening smooth
                // while the storefront prepares underneath.
                LaunchAnimationView(hold: Self.splashHold, isReady: launchReady) {
                    // Seen: the day's splash is spent. Played out in the
                    // background (iOS starting the app early), it isn't, and
                    // it stays up: dropping it left Home on screen, and the
                    // morning's open showed Home first, then the splash
                    // (owner, 2026-10-20).
                    // The app's live state: this closure is made once, so the
                    // scenePhase it captured is the first render's.
                    guard UIApplication.shared.applicationState == .active else { splashUnseen = true; return }
                    _ = Self.markSplashShown()
                    showSplash = false
                    HitchProbe.shared.homeShown()
                    HomeSettle.shared.logLift(capped: settleCapped)
                    LaunchTiming.log.notice("launch: splash gone at \(LaunchTiming.sinceStart(), privacy: .public) ms")
                }
                    .id(splashRun)
                    .ignoresSafeArea()
                    .zIndex(1)
            }
            if Self.readyMarker, launchReady, !showCover, !showSplash {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel("Ready")
                    .accessibilityIdentifier("app.ready")
                    .allowsHitTesting(false)
            }
        }
        // The launch is white; the dark scheme's white status bar would vanish on it.
        .statusBarHidden(showSplash)
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in Task { await account.foreground() } }
        // A shared product link, marracat.com/p/<id>, opens that product
        // here when the app is installed; anything else is Google sign-in.
        .onOpenURL { url in
            if openDeliveryLink(url) { return }
            if let destination = AppDestination(url: url) { IntentRouter.shared.open(destination); return }
            if !openProductLink(url) { GIDSignIn.sharedInstance.handle(url) }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { _ = openProductLink(url) }
        }
        // A tapped Spotlight result: its identifier is "product:<id>" or "brand:<id>".
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let destination = AppDestination(spotlightID: id) { IntentRouter.shared.open(destination) }
        }
        .task(id: catalog.isReady) {
            guard catalog.isReady, !homeImagesReady else { return }
            LaunchTiming.log.notice("launch: catalog ready at \(LaunchTiming.sinceStart(), privacy: .public) ms")
            HomeSettle.shared.opened("slice")
            let now = HomeImages.urls(catalog, mix: BrandMix())
            // Read from disk when the last launch saved them; a first launch
            // downloads them. The splash waits for this, so it gets a third
            // of a second (it had a full one); what hasn't arrived loads
            // behind the storefront. Part of cutting the splash from ~4.0 s
            // to ~2.6 s on 2026-09-27, with the camel-case bundle, Home's
            // sorts moved off the main thread and the lazy brand row.
            await ImageLoader.shared.warm(now, limit: .milliseconds(350))
            homeImagesReady = true
            HomeSettle.shared.opened("images")
            LaunchTiming.log.notice("launch: home images ready at \(LaunchTiming.sinceStart(), privacy: .public) ms")
            // The first pull-to-refresh, then the next launch.
            var refreshed = BrandMix(); refreshed.next()
            let next = HomeImages.urls(catalog, mix: BrandMix(seed: BrandMix.nextLaunchSeed))
            ImageLoader.shared.prune(keeping: now + next)
            // The first pull-to-refresh's images: optional too (DeviceBudget);
            // a refresh loads its own if they aren't here.
            if DeviceBudget.allowsOptionalWork {
                await ImageLoader.shared.warm(HomeImages.urls(catalog, mix: refreshed), limit: .seconds(30))
            }
            await ImageLoader.shared.keepForLater(next)
        }
        // The cap on waiting for Home to settle, from when it could first show.
        .task(id: homeDrawable) {
            guard homeDrawable, !settleCapped else { return }
            try? await Task.sleep(for: Self.settleCap)
            if !Task.isCancelled, !launchReady { settleCapped = true }
        }
        .onChange(of: catalog.isComplete, initial: true) {
            if catalog.isComplete {
                HomeSettle.shared.opened("catalog")
                UITestSeed.apply(catalog: catalog, cart: cart, buyer: buyer)
                InAppAlerts.shared.uiTestDemo(catalog: catalog)
            }
        }
        // UI tests that skip the launch screens: Home counts as shown once settled.
        .onChange(of: launchReady) { if launchReady, !showCover, !showSplash { HitchProbe.shared.homeShown() } }
    }

    /// A newer catalog after a while away, not only at launch (CatalogStore.refreshIfStale).
    private func checkCatalogAfterAWhile() {
        guard !Self.offlineCatalog else { return }
        Task { await catalog.refreshIfStale() }
    }

    var body: some Scene {
        WindowGroup {
            stage
            .transaction { if MarracatApp.noAnimations { $0.disablesAnimations = true; $0.animation = nil } }
            .task(id: account.user?.id) { await social.refresh() }
            // The Marracat order email: whether it's on, and what brands sent.
            .task(id: account.user?.id) { RelayStore.shared.attach(account); await RelayStore.shared.refresh() }
            .task { await account.attach(shopper, cart: cart, buyer: buyer) }
            .task { await restock.renewToken(); await restock.refresh() }
            // Today's deliveries in the Dynamic Island: tokens to the server.
            .task { LiveActivityStore.shared.start() }
            .task(id: account.user?.id) { await LiveActivityStore.shared.refresh(account: account) }
            // The on-device AI pieces (MeaningIndex): fetched once, then kept.
            .task {
                ShoppingRhythm.shared.catalog = catalog
                TasteProfile.shared.enabled = shopper.personalizationEnabled
                try? await Task.sleep(for: .seconds(3))
                await MeaningIndex.shared.prepare()
            }
            .onChange(of: restock.openRequest) { openRestockedProduct() }
            .onChange(of: showSplash) { openRestockedProduct(); openTrackedOrder(); openRelayOrder() }
            .onChange(of: OrderTaps(tracked: OrderTrackingStore.shared.openRequest, relay: RelayStore.shared.openRequest)) { openTrackedOrder(); openRelayOrder() }
            .onChange(of: DealAlertStore.shared.openBrandRequest) { openSaleBrand() }
            .onChange(of: IntentRouter.shared.openRequest) { openRequested() }
            .onChange(of: showSplash) { openRequested() }
            // Spotlight follows saves, views and follows (and the catalog they're read from).
            .onChange(of: SpotlightState(saved: shopper.saved, recent: shopper.recentlyViewed,
                                         personalization: shopper.personalizationEnabled,
                                         followed: DealAlertStore.shared.brands,
                                         catalog: catalog.stamp), initial: true) { old, new in
                SpotlightSync.shared.schedule(catalog: catalog, shopper: shopper)
                // The brands Siri listens for in "Show … on Marracat".
                if old.followed != new.followed || old.catalog != new.catalog { MarracatShortcuts.updateAppShortcutParameters() }
            }
            .task { await OrderTrackingStore.shared.refresh() }
            // The first time the app is on screen each day gets the splash,
            // whether the process is new or was waiting in the background.
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    BackgroundRefresh.schedule(); Analytics.shared.appBackgrounded()
                    // UI tests: midnight passes while the app is away.
                    if ProcessInfo.processInfo.arguments.contains("-UITEST_NEW_DAY_ON_BACKGROUND") {
                        Self.defaults.removeObject(forKey: Self.splashKey)
                    }
                } else {
                    splashIfFirstToday()
                }
                if scenePhase == .active {
                    Analytics.shared.appOpened(); checkCatalogAfterAWhile(); HolidayIcon.apply()
                    // Brands this shopper keeps coming back to, and restock-alert stock;
                    // then Sunday picks and brand ideas, if turned on (WeeklyAlerts).
                    Task {
                        await FreshCatalog.shared.refreshDue(catalog: catalog)
                        await FreshCatalog.shared.refreshRestock(restock.alerts.map(\.productID), catalog: catalog)
                        await WeeklyAlerts.refresh(catalog: catalog, shopper: shopper)
                    }
                }
                if scenePhase == .active { VisitPing.send(account: account); Task { await account.foreground(); await social.refresh(); await restock.refresh(); await RelayStore.shared.refresh(); await OrderTrackingStore.shared.refresh(); await syncOrderItemNames(); await BoostStore.shared.refresh(account: account); await DealAlertStore.shared.refresh(account: account) } }
            }
            // Pick up a catalog published since this build shipped. It runs
            // after the splash and leaves the bundled
            // catalog in place if anything goes wrong. UI tests pass
            // -OFFLINE_CATALOG so a run never depends on the network.
            .task(id: showSplash) {
                guard !showSplash, !MarracatApp.offlineCatalog else { return }
                await catalog.refreshFromRemote()
            }
        }
    }
}

enum AppTab: Hashable { case home, browse, cart, saved, you }

struct SearchRequest: Identifiable, Equatable {
    let id = UUID()
    let initial: String
    /// The tab whose stack receives the results.
    let tab: AppTab
    /// Opened from a pushed screen, where the header field sits beside a back button.
    let fromPushed: Bool
}

@Observable
final class AppNav {
    var tab: AppTab = .home
    /// Bumped when the already-selected tab is tapped; that tab pops to its root.
    private(set) var reselected: [AppTab: Int] = [:]
    /// Only requests made while Home is already at its navigation root scroll
    /// the feed. Scrolling a hidden root while popping can replay after a later
    /// interactive back gesture and move the shopper away from their place.
    private(set) var homeScrollRequests = 0
    /// Non-nil while the in-place search overlay is up.
    var search: SearchRequest?
    private(set) var tabBarHidden = false
    /// The bar shrinks while a feed is scrolled down and grows back on the way
    /// up, like Instagram's (owner, 2026-11-05, from a screen recording). Set
    /// only by `.minimizesTabBarOnScroll()`; every tab change grows it back.
    private(set) var tabBarCompact = false
    /// Each tab's navigation stack, so search can push onto the tab it came from.
    @ObservationIgnored var routers: [AppTab: Router] = [:]
    /// A path for a tab whose stack hasn't appeared yet; it takes it on appear.
    @ObservationIgnored var pendingPaths: [AppTab: [Route]] = [:]

    /// Switches to `tab` showing `path`, now or as soon as its stack exists.
    func show(_ path: [Route], in tab: AppTab) {
        self.tab = tab
        if let router = routers[tab] { router.path = path } else { pendingPaths[tab] = path }
    }

    /// Home back at its top for a new visit (VisitClock), only at its root.
    func scrollHomeToTop() {
        if routers[.home]?.path.isEmpty ?? true { homeScrollRequests += 1 }
    }

    func reselect(_ tab: AppTab) {
        if tab == .home, routers[.home]?.path.isEmpty == true {
            homeScrollRequests += 1
        }
        reselected[tab, default: 0] += 1
    }

    func openSearch(initial: String = "", from tab: AppTab, pushed: Bool = false) {
        guard search == nil else { return }
        search = SearchRequest(initial: initial, tab: tab, fromPushed: pushed)
        // Search closes onto full-size bars, not the shrunk ones it opened from.
        setTabBarCompact(false)
        setTabBarHidden(true)
    }

    /// A tap on a tab, from the floating bar or the sidebar.
    func tap(_ tab: AppTab) {
        LaunchTiming.log.notice("tab: tapped \(String(describing: tab), privacy: .public) at \(LaunchTiming.sinceStart(), privacy: .public) ms")
        if tab == .browse {
            // The search icon, ASOS-style: the first tap lands on the Browse page;
            // tapping it again there opens search with the cursor and keyboard up.
            // From a screen pushed on Browse, the re-tap first returns to Browse.
            setTabBarCompact(false)
            if self.tab != .browse {
                self.tab = .browse
            } else if let router = routers[.browse], !router.path.isEmpty {
                reselect(.browse)
            } else {
                openSearch(from: .browse)
            }
            return
        }
        // Set without withAnimation: an animated selection makes TabView
        // cross-fade the two pages (the old page ghosts over the new one).
        // Only the bar's pill animates — see FloatingTabBar's .animation(value:).
        if self.tab == tab {
            reselect(tab)
        } else {
            self.tab = tab
        }
        setTabBarCompact(false)
    }

    func setTabBarCompact(_ compact: Bool) {
        guard compact != tabBarCompact else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { tabBarCompact = compact }
    }

    func setTabBarHidden(_ hidden: Bool) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { tabBarHidden = hidden }
    }
}

/// Five tabs, like ASOS: Home, Browse, Cart, Saved, You. The system tab bar
/// is hidden (see TabRoot) and the floating pill bar is drawn over the content.
struct RootView: View {
    @Environment(AppNav.self) private var nav
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The window's width, measured (never the screen's: Split View, Duo's two
    /// displays and a resized iPad window all differ from it).
    @State private var width: CGFloat = 0
    private var sidebar: Bool { AdaptiveLayout.showsSidebar(width: width, sizeClass: sizeClass) }

    var body: some View {
        @Bindable var nav = nav
        // The sidebar comes and goes beside the TabView, never around it: the
        // TabView keeps its place in the tree, so folding or unfolding keeps
        // every tab's navigation stack and scroll position (AdaptiveLayout).
        HStack(spacing: 0) {
            if sidebar {
                SidebarRail().accessibilityHidden(nav.search != nil)
            }
            TabView(selection: $nav.tab) {
                TabRoot(tab: .home) { HomeView().analyticsScreen("home") }.tag(AppTab.home)
                TabRoot(tab: .browse) { MenuView().analyticsScreen("browse") }.tag(AppTab.browse)
                TabRoot(tab: .cart) { CartView().analyticsScreen("cart") }.tag(AppTab.cart)
                TabRoot(tab: .saved) { SavedView().analyticsScreen("saved") }.tag(AppTab.saved)
                TabRoot(tab: .you) { YouView().analyticsScreen("account") }.tag(AppTab.you)
            }
            .environment(\.tabBarClearance, sidebar ? 0 : FloatingTabBar.clearance)
            .accessibilityHidden(nav.search != nil)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The bar is aligned to the BOTTOM OF THIS TABVIEW, so the TabView must
        // not shrink for the keyboard — otherwise the bar sits a keyboard's
        // height up the screen, over the content, until the inset goes away.
        // Nothing inside a tab takes typed input (search is its own overlay),
        // so there is nothing here that needs keyboard avoidance.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay {
            // A full-height container that ignores the keyboard. On the bar
            // alone, ignoresSafeArea didn't hold while the search overlay's
            // keyboard was going away: tapping a suggestion pushed a page
            // before the keyboard finished hiding, and the bar came back a
            // keyboard's height up the screen.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !sidebar {
                    FloatingTabBar()
                        .offset(y: nav.tabBarHidden ? 140 : 0)
                        .opacity(nav.tabBarHidden ? 0 : 1)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .overlay {
            if let request = nav.search {
                SearchOverlay(request: request).id(request.id)
            }
        }
    }
}

/// What Home finishes after it can first draw, which the launch cover or
/// splash waits for (MarracatApp.launchReady): the page rebuilt from the whole
/// catalog, and Shop by style's boards. Each gate's opening is logged, and at
/// the lift the one that held it longest (category "launch").
@MainActor @Observable
final class HomeSettle {
    static let shared = HomeSettle()
    /// HomeView: the page is built from the whole catalog (`HomePage.complete`).
    private(set) var pageComplete = false
    /// ShopByStyleRow: its boards are worked out, or there are none to show
    /// without a download.
    private(set) var styleBoards = false
    var isSettled: Bool { pageComplete && styleBoards }

    @ObservationIgnored private var openedAt: [String: Int] = [:]
    @ObservationIgnored private var lifted = false

    func pageBuiltFromWholeCatalog() { if !pageComplete { pageComplete = true; opened("page") } }
    func styleBoardsReady() { if !styleBoards { styleBoards = true; opened("style") } }

    func opened(_ gate: String) {
        guard openedAt[gate] == nil else { return }
        openedAt[gate] = LaunchTiming.sinceStart()
        LaunchTiming.log.notice("launch: gate \(gate, privacy: .public) open at \(self.openedAt[gate]!, privacy: .public) ms")
    }

    func logLift(capped: Bool) {
        guard !lifted else { return }
        lifted = true
        let last = openedAt.max { $0.value < $1.value }
        let drawable = max(openedAt["slice"] ?? 0, openedAt["images"] ?? 0)
        let waiting = ["catalog", "page", "style"].filter { openedAt[$0] == nil }
        LaunchTiming.log.notice("launch: held by \(capped ? "the cap, waiting on " + waiting.joined(separator: ", ") : last?.key ?? "nothing", privacy: .public) (\(LaunchTiming.sinceStart() - drawable, privacy: .public) ms past drawable) gates \(self.openedAt.sorted { $0.value < $1.value }.map { "\($0.key)=\($0.value)" }.joined(separator: " "), privacy: .public)")
    }
}

/// Launch timing, in Console under category "launch": when the catalog, Home's
/// images and the end of the splash land, from process start. Not tied to the
/// main actor, so the background catalog read can log too.
enum LaunchTiming {
    static let log = Logger(subsystem: "com.divinedavis.marracat", category: "launch")
    static func sinceStart() -> Int {
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return Int((Date().timeIntervalSince1970 - started) * 1000)
    }
}
