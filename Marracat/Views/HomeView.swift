import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppNav.self) private var nav
    @Environment(\.scenePhase) private var scenePhase

    /// Products for the $20+ boosts: the product itself, or a boosted brand's
    /// featured product; sold out or missing ones drop out.
    private var boostedPicks: [Product] {
        BoostStore.shared.picks.compactMap { target -> Product? in
            if target.hasPrefix("product:") { return catalog.product(String(target.dropFirst(8))).flatMap { $0.available ? $0 : nil } }
            let brand = String(target.dropFirst(6))
            return mix.featured(catalog.products(for: brand), brand: brand)
        }
    }
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pull to refresh brings every brand-led section back with different brands.
    @State private var mix = BrandMix()
    /// The personalized half of the page, pinned. Opening a product writes to
    /// the shopper's history, so recomputing these on every change would
    /// reshuffle Home under someone who only went to look at an item and swipe
    /// back — they'd lose their place. Its personal rows are redone only where
    /// nobody sees them change: off screen, under pull-to-refresh's spinner,
    /// or behind a new search (see `historyChanged`, `leftHome`).
    @State private var page = HomePage()

    /// "Picked for you right now" (on-device AI): follows what was just looked
    /// at, saved or carted. Re-read when the shopper leaves Home, on
    /// pull-to-refresh and on a new search, and put on the page only then
    /// (owner, 2026-10-11: it showed three products, then swapped them a
    /// second later as the catalog finished loading). A cold launch opens on
    /// the row as last saved (HomeRowsCache).
    @State private var picked: [Product] = []
    @State private var pickedReserved: Set<String> = []
    /// The row's first read, or the saved row, is in. Until then, with a taste
    /// to read, its place is held at full height so nothing below it moves.
    @State private var pickedSettled = false
    @State private var pickedStarted = false
    /// The personal rows on the page came from an earlier session, or the
    /// history changed while they were on screen: redone at the next fresh visit.
    @State private var personalStale = false
    /// `leftHome` is working the personal rows out, off the tab tap.
    @State private var rebuildingOffHome = false
    /// The history Home last built from. Search now runs on Browse
    /// (2026-10-20), where Home isn't on screen and its onChange hooks
    /// don't reliably fire, so Home also compares on coming back.
    @State private var builtFrom: [String]?
    static let pickedTitle = String(localized: "Picked for you right now", comment: "Home row title")
    /// "New since your last visit" (VisitClock): worked out when a visit
    /// starts, so it stays put while the shopper is here.
    @State private var newSince: [Product] = []
    @State private var newSinceBuiltFor: Date?
    /// The feed's width, measured: how many columns of rows it gets.
    @State private var feedWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // Someone with no account is offered one, above everything.
                    VStack(spacing: 0) {
                        SignUpBanner()
                        CategoryChips()
                    }
                    .id("homeTop")
                    HeroCarousel(mix: mix)
                    // A holiday's banner and rows while its event runs.
                    HolidayEventRows()
                    // Rows side by side once the window is wide enough (Duo
                    // opened, iPad); a VStack at phone widths. One Layout for
                    // every width, so a fold re-places these rows rather than
                    // building new ones.
                    FeedColumnsLayout(columns: AdaptiveLayout.feedColumns(width: feedWidth)) {
                        // An aisle this shopper usually shops about now
                        // (ShoppingRhythm) puts "Time to restock?" first.
                        if page.restockFirst { restockRow }
                        // $20+ boosts (BoostStore), labeled Sponsored.
                        if !boostedPicks.isEmpty {
                            ProductRow(title: String(localized: "Boosted picks · Sponsored", comment: "Home row title: paid placements"), products: boostedPicks, track: "boosted")
                                .accessibilityIdentifier("boostedPicks")
                                .onAppear { BoostStore.shared.picks.forEach { BoostStore.shared.record($0) } }
                        }
                        pickedRow
                        if newSince.count >= 4 {
                            ProductRow(title: String(localized: "New since your last visit", comment: "Home row title: products the brands added since the shopper was last in the app"), products: newSince, route: .newArrivals, track: "new_since")
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("newSinceLastVisit")
                        }
                        if !page.restockFirst { restockRow }
                        // Shaped by this shopper's searches, views and saves.
                        ForEach(page.rows) { row in
                            ProductRow(title: row.title, products: row.products, track: row.track, reserved: row.reserved)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("forYouRow")
                        }
                        if !page.keepShopping.isEmpty {
                            ProductRow(title: String(localized: "Keep shopping for", comment: "Home row title: recently viewed products"), products: page.keepShopping, track: "keep")
                        }
                        // Their places, until the whole catalog they're built
                        // from lands (only when no rows were saved: the first
                        // launch of this version).
                        ForEach(0..<expectedPersonalRows, id: \.self) { _ in RowPlaceholder() }
                        quadRow.feedFullWidth()
                        ShopByStyleRow().feedFullWidth()
                        ExploreRow()
                        BrandCircles(mix: mix).feedFullWidth()
                        if page.deals.count >= 4 {
                            ProductRow(title: String(localized: "Recommended deals for you", comment: "Home row title"), products: page.deals, route: .deals, track: "deals")
                        }
                        // The ones this shopper leans toward, not all 27 —
                        // Browse is where the whole list lives.
                        ForEach(page.topPickCategories) { c in
                            ProductRow(title: String(localized: "Top picks in \(c.name)", comment: "Home row title; the argument is a department name"), products: page.topPicks[c.id] ?? [],
                                       route: .category(c.id), track: "top")
                        }
                        if catalog.isComplete { discoverMore.feedFullWidth() }
                    }
                    .padding(.vertical, 12)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { feedWidth = $0 }
            // Home's rows of products are cards, two high (ProductRow); the
            // holiday rows too. Screens pushed from Home keep their tiles.
            .environment(\.productRowCards, true)
            .task { if page.categories.isEmpty { rebuild(why: "first") } }
            // The launch cover waits for this (HomeSettle).
            .onChange(of: page.complete, initial: true) { if page.complete { HomeSettle.shared.pageBuiltFromWholeCatalog() } }
            // The catalog is read just after launch, and a page built before it
            // landed would be empty. Only that case: a rebuild mid-browse is
            // what this page is pinned to avoid.
            .onChange(of: catalog.catalog.generatedAt) {
                if page.categories.isEmpty { rebuild(why: "catalog arrived") }
            }
            // Drawn from Home's slice at launch (HomeSlice): once, when the
            // whole catalog lands behind it. The rows every shopper sees come
            // out the same, and this shopper's rows are the ones saved last
            // session, so nothing above the fold moves. The taste's department
            // affinities are worked out off the main thread first.
            .onChange(of: catalog.isComplete) {
                guard catalog.isComplete, !page.complete else { return }
                // UI tests: keep the placeholders up long enough to measure
                // (XCUITest waits for the launch to go idle, by when they're gone).
                if ProcessInfo.processInfo.arguments.contains("-HOLD_HOME_PLACEHOLDERS") { return }
                Task {
                    let affinity = await MeaningPicks.categoryAffinityInBackground(catalog: catalog)
                    if !page.complete, catalog.isComplete { rebuild(completing: true, affinity: affinity, why: "whole catalog") }
                }
            }
            .onChange(of: shopper.recentSearches) { historyChanged() }
            .onChange(of: shopper.feedRevision) { historyChanged() }
            // Leaving the app: fresh rows for the next launch to open on.
            // Initial too: a cold launch is an arrival, often before this view
            // sees a phase change.
            .onChange(of: scenePhase, initial: true) {
                if scenePhase == .background { VisitClock.left(); saveFreshRows() }
                // Back after half an hour or more: a new visit, so Home comes
                // up fresh, as after pull-to-refresh, with what's new since. At
                // launch the page is still being built; only the row is.
                if scenePhase == .active, VisitClock.arrived() {
                    if page.categories.isEmpty { buildNewSince() } else { newVisit() }
                }
            }
            .onChange(of: catalog.isComplete, initial: true) { buildNewSince() }
            // Leaving Home: its next visit is a fresh one.
            .onChange(of: nav.tab) { old, new in
                if old == .home && new != .home { leftHome() }
                // Coming back to the tab. TabView doesn't update a hidden
                // page, so a search made on Browse reaches Home only here
                // (2026-10-20). Not on appear: that also fires as the launch
                // cover lifts, and rebuilt the page mid-fling (perf gate,
                // longest stall 163 -> 300 ms).
                if new == .home { catchUp() }
            }
            .markRefreshable {
                // Hold the M a beat so the swap reads as a refresh.
                try? await Task.sleep(for: .seconds(0.5))
                mix.next()
                rebuild(why: "pull to refresh")
                await refreshPicked(force: true)
            }
            // A root re-tap scrolls. Returning from a pushed screen is handled
            // by TabRoot without animating the hidden feed at the same time.
            .onChange(of: nav.homeScrollRequests) {
                // Keep the feed pinned during the scroll. Rebuilding here also
                // changes row heights and interrupts the trip back to the top.
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.65)) {
                    proxy.scrollTo("homeTop", anchor: .top)
                }
            }
        }
        .background(Theme.canvas)
        // No bar and no search on Home (owner, 2026-10-20, after IMDb):
        // search lives on Browse, above the tab bar.
        .marracatChromeHidden()
    }

    @ViewBuilder private var restockRow: some View {
        if !page.restock.isEmpty {
            ProductRow(title: String(localized: "Time to restock?", comment: "Home row title: products bought before that may need restocking"), products: page.restock, track: "restock")
                .accessibilityIdentifier("restockSoon")
        }
    }

    @ViewBuilder private var pickedRow: some View {
        if picked.count >= 4 {
            ProductRow(title: Self.pickedTitle, products: picked, track: "taste", reserved: pickedReserved)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pickedForYou")
        } else if !pickedSettled, shopper.personalizationEnabled, TasteProfile.shared.hasHistory {
            RowPlaceholder(title: Self.pickedTitle)
        }
    }

    /// How many personal rows the whole catalog is likely to bring, while
    /// there are none to show yet.
    private var expectedPersonalRows: Int {
        guard !page.personal, shopper.personalizationEnabled else { return 0 }
        let searches = min(2, shopper.recentSearches.count)
        let related = shopper.saved.isEmpty && shopper.recentlyViewed.isEmpty ? 0 : 1
        let keep = shopper.recentlyViewed.isEmpty ? 0 : 1
        return searches + related + keep
    }

    /// Home is what the shopper is looking at: no search over it, no product
    /// pushed on it, its tab showing, the app in front.
    private var homeOnScreen: Bool {
        scenePhase == .active && nav.tab == .home && nav.search == nil && (nav.routers[.home]?.path.isEmpty ?? true)
    }

    /// The on-device taste row, with 3-4 slots kept for departments other
    /// than the shopper's main one (owner, 2026-10-10), one tile per product
    /// as a shopper sees it (`distinctLooking`).
    private func tastePicks() async -> (products: [Product], reserved: Set<String>) {
        let hidden = Set(shopper.hidden)
        let purchased = shopper.checkouts.flatMap(\.productIDs)
        // Only departments this shopper has shown interest in (owner, 2026-11-09).
        let allowed = catalog.touchedDepartments(of: shopper)
        let found = await MeaningPicks.forTaste(catalog: catalog, hidden: hidden, limit: 24, allowed: allowed).distinctLooking()
        let row = Array(found.prefix(12))
        guard row.count >= 4 else { return (row, []) }
        let lean = catalog.departmentLean(viewed: shopper.recentlyViewed, saved: shopper.saved, purchased: purchased)
        let mixed = catalog.reservingOtherDepartments(row, pool: found, lean: lean,
                                                      searched: catalog.searchedDepartments(shopper.recentSearches),
                                                      seeds: (shopper.saved + shopper.recentlyViewed + purchased).compactMap(catalog.product),
                                                      excluded: hidden.union(purchased), mix: mix)
        let products = mixed.products.distinctLooking()
        return (products, mixed.reserved.intersection(products.map(\.id)))
    }

    /// Re-reads the taste for "Picked for you right now". It goes on the page
    /// only where it can't be seen changing: Home off screen, the row's first
    /// fill into its held place, or pull-to-refresh (`force`). Otherwise the
    /// next fresh visit reads it again.
    private func refreshPicked(force: Bool = false) async {
        pickedStarted = true
        var found = await tastePicks()
        // The meaning vectors not read yet (a launch with nothing saved):
        // read them from disk and try once more.
        if found.products.count < 4, TasteProfile.shared.hasHistory, !MeaningIndex.shared.hasVectors,
           await MeaningIndex.shared.loadVectors() {
            found = await tastePicks()
        }
        guard force || !pickedSettled || !homeOnScreen else { return }
        // A read that came back short (the vectors still missing) keeps the
        // row that's there; no taste at all clears it.
        if found.products.count >= 4 || !TasteProfile.shared.hasHistory || !shopper.personalizationEnabled {
            picked = found.products
            pickedReserved = found.reserved
        }
        pickedSettled = true
        logPicked("read")
        saveRows()
    }

    /// The shopper's history changed. Behind a search, or from settings on
    /// another tab, Home is redone now. On screen — an account syncing in at
    /// launch, a product hidden from Home — only hidden products leave; the
    /// rows are redone at the next fresh visit, so nothing moves under the
    /// shopper.
    private func historyChanged() {
        guard !page.categories.isEmpty else { return }
        // Not marked as built from while on screen: a change held back while
        // Home was hidden lands here on return, and catchUp() redoes it.
        guard !homeOnScreen else {
            let kept = currentRows.hiding(Set(shopper.hidden))
            if kept != currentRows {
                if page.personal { show(kept, includingPicked: true) } else { picked = kept.picked; pickedReserved = Set(kept.pickedReserved) }
            }
            personalStale = true
            return
        }
        rebuild(why: "history changed while hidden")
        Task { await refreshPicked(force: true) }
    }

    /// Back on Home after a search elsewhere: add the rows that search earns
    /// ("Inspired by your search for …"). Only the personal rows: a whole
    /// rebuild here held the tap 360–460 ms in the simulator (owner,
    /// 2026-11-11: "i think there is a delay when i touch on the home
    /// button"), and the shared rows didn't change. One yield first, so the
    /// tab switch draws before the rows are worked out.
    private func catchUp() {
        guard let seen = builtFrom, seen != shopper.recentSearches, !page.categories.isEmpty, catalog.isComplete else { return }
        builtFrom = shopper.recentSearches
        Task { @MainActor in
            await Task.yield()
            let started = Date()
            var next = page
            next.setPersonal(personalRows())
            page = next
            personalStale = false
            LaunchTiming.log.notice("home: personal rows caught up in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms at \(LaunchTiming.sinceStart(), privacy: .public) ms")
            logPersonal("caught up after a search")
            await refreshPicked(force: true)
        }
    }

    /// The shopper went to another tab: Home's next visit is fresh.
    ///
    /// Not inside the tap. After a launch the rows are the ones saved last
    /// session, so the first tab switch rebuilt them, on the main thread, as
    /// the tap landed: the app froze before the other tab appeared (owner,
    /// 2026-11-20: "when the app first loads up and I touch on another tab
    /// bar button the app freezes for a second"; 0.6 s in the simulator for
    /// a shopper with two small recent searches, 3.6 s with "candle" among
    /// them). The other tab draws first; the recent
    /// searches the rows are made from run on a background thread
    /// (`warmSearches`), and only then are the rows built, while Home is
    /// still out of sight. Back on Home before that, they wait for the next
    /// time it is left.
    private func leftHome() {
        if personalStale, catalog.isComplete, !rebuildingOffHome {
            rebuildingOffHome = true
            Task { @MainActor in
                defer { rebuildingOffHome = false }
                try? await Task.sleep(for: .milliseconds(300))
                await catalog.warmSearches(CatalogStore.searchRowQueries(shopper.recentSearches, memory: SearchMemory.load()))
                guard personalStale, catalog.isComplete, nav.tab != .home else { return }
                let started = Date()
                var next = page
                next.setPersonal(personalRows())
                page = next
                personalStale = false
                LaunchTiming.log.notice("home: personal rows rebuilt off Home in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms at \(LaunchTiming.sinceStart(), privacy: .public) ms")
                logPersonal("rebuilt after leaving")
            }
        }
        Task { await refreshPicked() }
    }

    /// A new visit (VisitClock): the pull-to-refresh swap, from the top, and
    /// "New since your last visit" worked out again. Only while Home isn't
    /// mid-browse on a pushed screen; there the next return to Home catches up.
    private func newVisit() {
        guard nav.routers[.home]?.path.isEmpty ?? true else { personalStale = true; return }
        nav.scrollHomeToTop()
        mix.next()
        rebuild(why: "new visit")
        buildNewSince(force: true)
        Task { await refreshPicked(force: true) }
    }

    /// Products the brands added since the last visit; brands this shopper
    /// looked at, saved or bought from first.
    private func buildNewSince(force: Bool = false) {
        guard catalog.isComplete, let since = VisitClock.since() else { return }
        guard force || newSinceBuiltFor != since else { return }
        newSinceBuiltFor = since
        let bought = shopper.checkouts.flatMap(\.productIDs)
        let favored = Set((shopper.recentlyViewed + shopper.saved + bought).compactMap { catalog.product($0)?.brand })
        newSince = shopper.personalizationEnabled || favored.isEmpty
            ? VisitClock.newSince(since, candidates: catalog.newArrivals, favoredBrands: shopper.personalizationEnabled ? favored : [],
                                  hidden: Set(shopper.hidden), mix: mix)
            : []
    }

    /// The app is going to the background: the rows the next launch opens on,
    /// built now and saved, without touching the page the shopper comes back to.
    private func saveFreshRows() {
        guard catalog.isComplete, page.personal else { return }
        let fresh = personalRows()
        let app = UIApplication.shared
        var id = UIBackgroundTaskIdentifier.invalid
        id = app.beginBackgroundTask(withName: "home-rows") { app.endBackgroundTask(id); id = .invalid }
        Task {
            let found = await tastePicks()
            var rows = HomeRows(restock: fresh.restock, rows: fresh.rows.map(HomeRows.Row.init), keepShopping: fresh.keepShopping,
                                restockFirst: fresh.restockFirst)
            let keepOld = found.products.count < 4 && TasteProfile.shared.hasHistory && shopper.personalizationEnabled
            rows.picked = keepOld ? picked : found.products
            rows.pickedReserved = (keepOld ? pickedReserved : found.reserved).sorted()
            HomeRowsCache.save(shopper.personalizationEnabled ? rows : HomeRows())
            if id != .invalid { app.endBackgroundTask(id); id = .invalid }
        }
    }

    // MARK: Personal rows

    fileprivate struct Personal {
        var rows: [ForYouRow] = []
        var keepShopping: [Product] = []
        var restock: [Product] = []
        /// An aisle is due by this shopper's rhythm (ShoppingRhythm): the
        /// restock row leads Home.
        var restockFirst = false
    }

    /// This shopper's rows from the whole catalog. Nothing on the feed that
    /// can't be bought: a sold-out row is a dead end, and "Keep shopping for"
    /// was showing items that had gone out of stock since they were viewed.
    private func personalRows() -> Personal {
        let rows = shopper.personalizationEnabled ? catalog.forYou(searches: shopper.recentSearches, viewed: shopper.recentlyViewed,
                                  saved: shopper.saved, hidden: shopper.hidden,
                                  purchased: shopper.checkouts.flatMap(\.productIDs), mix: mix,
                                  memory: SearchMemory.load()) : []
        let keepShopping = Array(shopper.recentlyViewed.compactMap(catalog.product)
            .filter { $0.available && !shopper.hidden.contains($0.id) }.distinctLooking().prefix(12))
        // Aisles due by when this shopper usually shops them, then the
        // products bought before that are running out.
        let rhythmic = shopper.personalizationEnabled
            ? ShoppingRhythm.shared.dueProducts(catalog: catalog, bought: shopper.checkouts.reversed().flatMap(\.productIDs),
                                                touched: TasteProfile.shared.recentProducts, hidden: Set(shopper.hidden))
            : []
        var seen = Set<String>()
        let restock = Array((rhythmic + Replenishment.due(checkouts: shopper.checkouts, catalog: catalog))
            .filter { seen.insert($0.id).inserted }.prefix(12))
        return Personal(rows: rows, keepShopping: keepShopping, restock: restock, restockFirst: !rhythmic.isEmpty)
    }

    /// What's on the page now, as saved.
    private var currentRows: HomeRows {
        HomeRows(picked: picked, pickedReserved: pickedReserved.sorted(), restock: page.restock,
                 rows: page.rows.map(HomeRows.Row.init),
                 keepShopping: page.keepShopping, restockFirst: page.restockFirst)
    }

    /// Puts saved rows on the page in one assignment.
    private func show(_ rows: HomeRows, includingPicked: Bool) {
        var next = page
        next.setPersonal(Personal(rows: rows.rows.map { ForYouRow(id: $0.id, title: $0.title, products: $0.products, reserved: Set($0.reserved)) },
                                  keepShopping: rows.keepShopping, restock: rows.restock, restockFirst: rows.restockFirst ?? false))
        page = next
        if includingPicked {
            picked = rows.picked
            pickedReserved = Set(rows.pickedReserved)
        }
    }

    /// Saves the rows on the page once both halves are real: the personal
    /// rows (built or saved) and the picked row's first read.
    private func saveRows() {
        guard shopper.personalizationEnabled else { HomeRowsCache.clear(); return }
        guard page.personal, pickedSettled else { return }
        HomeRowsCache.save(currentRows)
    }

    /// The rows saved last session, once, as the page is first drawn.
    private func takeLaunchRows() -> HomeRows? {
        guard let saved = catalog.launchHomeRows else { return nil }
        catalog.launchHomeRows = nil
        guard shopper.personalizationEnabled else { HomeRowsCache.clear(); return nil }
        let rows = saved.hiding(Set(shopper.hidden))
        return rows.isEmpty ? nil : rows
    }

    private func logPicked(_ how: String) {
        LaunchTiming.log.notice("home: picked row (\(how, privacy: .public)) \(picked.prefix(3).map(\.title).joined(separator: " | "), privacy: .public) at \(LaunchTiming.sinceStart(), privacy: .public) ms")
    }

    private func logPersonal(_ how: String) {
        LaunchTiming.log.notice("home: personal rows (\(how, privacy: .public)) [\(page.rows.map(\.title).joined(separator: ", "), privacy: .public)] at \(LaunchTiming.sinceStart(), privacy: .public) ms")
    }

    /// Reads the shopper's history once and freezes the result into `page`.
    private func rebuild(completing: Bool = false, affinity given: [String: Float]? = nil, why: String = "") {
        let started = Date()
        // What catchUp() compares against: the history this build read.
        builtFrom = shopper.recentSearches
        let first = page.categories.isEmpty
        // From Home's slice, only the rows every shopper sees: this shopper's
        // rows search or score the whole catalog. Until it lands they're the
        // ones saved last session, or held places.
        let complete = catalog.isComplete
        var personal: Personal?
        var launchRows: HomeRows?
        if complete, !(completing && page.personal) {
            personal = personalRows()
            personalStale = false
        } else if first, catalog.isReady, let saved = takeLaunchRows() {
            launchRows = saved
            personalStale = true
        }
        // Departments this shopper leans toward come first: their history,
        // then how close each department sits to their taste (on-device AI).
        let affinity = given ?? (complete ? MeaningPicks.categoryAffinity(catalog: catalog) : [:])
        let personalRowsNow = personal?.rows ?? launchRows.map { $0.rows.map { ForYouRow(id: $0.id, title: $0.title, products: $0.products) } } ?? page.rows
        let keepNow = personal?.keepShopping ?? launchRows?.keepShopping ?? page.keepShopping
        // Departments this shopper has shown interest in: Top picks and the
        // deals row show only these (owner, 2026-11-09: "if they never
        // purchase dog food or search for it we should never show it"). Read
        // from the whole catalog, else as saved last time.
        let touched = Self.touchedDepartments(complete ? catalog.touchedDepartments(of: shopper) : nil)
        let ordered = orderedCategories(personalRowsNow, keepShopping: keepNow, affinity: affinity)
        let categories = ordered.filter { touched.contains($0.id) } + ordered.filter { !touched.contains($0.id) }
        // The page's other rows, worked out here once instead of in `body`,
        // which redraws for many reasons (the tab bar, a scroll request) and
        // filtered whole departments of the 120k-product catalog each time.
        let hidden = Set(shopper.hidden)
        func picks(_ c: Category, _ limit: Int) -> [Product] {
            catalog.spread(catalog.homePicks(in: c.id).filter { !hidden.contains($0.id) }, limit: limit, mix: mix)
        }
        defer {
            LaunchTiming.log.notice("home: page built in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms [\(why, privacy: .public)] (\(complete ? "whole catalog" : "slice", privacy: .public)\(completing ? ", kept the shared rows" : "", privacy: .public)) at \(LaunchTiming.sinceStart(), privacy: .public) ms")
            if personal != nil { logPersonal("built") } else if launchRows != nil { logPersonal("saved") }
        }
        // The whole catalog landing behind a page drawn from Home's slice: the
        // rows every shopper sees come out the same from either
        // (HomeSliceTests), so they're kept instead of being worked out again
        // over all 146k products on the main thread just as Home is on screen.
        // This shopper's rows were saved last session and stay until the next
        // fresh visit; only the order of the departments below them is new.
        if completing, !page.categories.isEmpty {
            var next = page
            next.complete = true
            if let personal { next.setPersonal(personal) }
            next.categories = categories
            // The deals row is this shopper's too. The slice's page chose it
            // by the departments saved at the last build; a shopper who has
            // touched something since (their first search or like, then a
            // relaunch) got every department's deals for the whole visit: a
            // skincare set, a knife and a styling gel, to someone who had
            // only looked at laundry detergent (2026-11-22).
            if touched != page.touched {
                let theirs = catalog.deals.filter { !hidden.contains($0.id) && (touched.isEmpty || touched.contains($0.category)) }
                next.deals = catalog.spread(theirs, limit: 12, mix: mix)
            }
            next.touched = touched
            for c in categories.prefix(8) where next.topPicks[c.id] == nil { next.topPicks[c.id] = picks(c, 12) }
            page = next
            saveRows()
            return
        }
        let deals = catalog.deals.filter { !hidden.contains($0.id) }
        let theirDeals = deals.filter { touched.isEmpty || touched.contains($0.category) }
        var next = HomePage(complete: complete, categories: categories,
                            deals: catalog.spread(theirDeals, limit: 12, mix: mix),
                            topPicks: Dictionary(categories.prefix(8).map { ($0.id, picks($0, 12)) }, uniquingKeysWith: { a, _ in a }),
                            newArrivals: catalog.spread(catalog.newArrivals.filter { !hidden.contains($0.id) }, limit: 4, mix: mix),
                            dealsQuad: catalog.spread(deals, limit: 4, mix: mix),
                            shopQuads: catalog.categories.compactMap { c in
                                let p = picks(c, 4)
                                return p.count == 4 ? (c, p) : nil
                            })
        next.touched = touched
        if let personal {
            next.setPersonal(personal)
        } else if page.personal {
            // A rebuild before the whole catalog is in keeps the rows shown.
            next.setPersonal(Personal(rows: page.rows, keepShopping: page.keepShopping, restock: page.restock, restockFirst: page.restockFirst))
        }
        page = next
        if let launchRows {
            show(launchRows, includingPicked: false)
            if launchRows.picked.count >= 4 {
                picked = launchRows.picked
                pickedReserved = Set(launchRows.pickedReserved)
                pickedSettled = true
                pickedStarted = true
                logPicked("saved")
            }
        }
        // No saved row: read the taste as soon as there's a catalog to pick
        // from, into the place held for it.
        if catalog.isReady, !pickedStarted {
            pickedStarted = true
            Task { await refreshPicked() }
        }
        saveRows()
    }

    /// The shopper's departments, saved for the next launch's first page (built
    /// from Home's slice, which can't read the whole history). `nil` reads the
    /// saved set; a set saves it.
    private static func touchedDepartments(_ fresh: Set<String>?) -> Set<String> {
        let key = "home.touchedDepartments"
        if let fresh {
            UserDefaults.standard.set(fresh.sorted(), forKey: key)
            return fresh
        }
        return Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// "Top picks" rows for categories this shopper has shown interest in move
    /// up the page; the rest keep their usual order.
    private func orderedCategories(_ rows: [ForYouRow], keepShopping: [Product], affinity: [String: Float] = [:]) -> [Category] {
        var weight: [String: Double] = [:]
        for p in rows.flatMap(\.products) + keepShopping { weight[p.category, default: 0] += 1 }
        // Affinity is a cosine (about -0.2 to 0.6 here): scaled so a strong lean
        // counts like a few products of history.
        for (c, a) in affinity { weight[c, default: 0] += Double(a) * 8 }
        return catalog.categories.enumerated().sorted { a, b in
            let wa = weight[a.element.id, default: 0], wb = weight[b.element.id, default: 0]
            return wa != wb ? wa > wb : a.offset < b.offset
        }.map(\.element)
    }

    private var quadRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy: a card per category (29) with four photos each, built as
            // they scroll in rather than all under the launch splash.
            LazyHStack(alignment: .top, spacing: 10) {
                QuadCard(title: String(localized: "New arrivals", comment: "Home card title"), products: page.newArrivals, route: .newArrivals)
                if catalog.deals.count >= 4 {
                    QuadCard(title: String(localized: "Deals for you", comment: "Home card title"), products: page.dealsQuad, route: .deals)
                }
                ForEach(page.shopQuads, id: \.category.id) { quad in
                    QuadCard(title: String(localized: "Shop \(quad.category.name)", comment: "Home card title"), products: quad.products, route: .category(quad.category.id))
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var discoverMore: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discover more").brandFont(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Widths.gridTile), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(catalog.discoverRow(mix: mix, hidden: Set(shopper.hidden), limit: 40, departments: page.touched)) { ProductTile(product: $0) }
            }
        }
        .padding(12)
        .background(Theme.surface)
    }
}

private extension HomeRows.Row {
    init(_ r: ForYouRow) { self.init(id: r.id, title: r.title, products: r.products, reserved: r.reserved.sorted()) }
}

/// Home's personalized sections, held still while the shopper browses.
private struct HomePage {
    /// Built from the whole catalog, not Home's slice of it.
    var complete = false
    var rows: [ForYouRow] = []
    var keepShopping: [Product] = []
    var categories: [Category] = []
    var deals: [Product] = []
    var topPicks: [String: [Product]] = [:]
    var newArrivals: [Product] = []
    var dealsQuad: [Product] = []
    var restock: [Product] = []
    var restockFirst = false
    var shopQuads: [(category: Category, products: [Product])] = []
    /// The departments this shopper has shown interest in (empty: all).
    var touched: Set<String> = []
    /// Top picks rows: the shopper's departments only, once they have any.
    var topPickCategories: ArraySlice<Category> {
        (touched.isEmpty ? categories : categories.filter { touched.contains($0.id) }).prefix(8)
    }
    /// `rows`, `keepShopping` and `restock` are this shopper's: built from the
    /// whole catalog, or saved by the last session (HomeRowsCache).
    var personal = false

    fileprivate mutating func setPersonal(_ p: HomeView.Personal) {
        rows = p.rows; keepShopping = p.keepShopping; restock = p.restock; restockFirst = p.restockFirst && !p.restock.isEmpty
        personal = true
    }
}

/// A row's place while its products are worked out, at the height the row
/// will have, so nothing below it moves when they arrive.
private struct RowPlaceholder: View {
    var title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let title { SectionHeader(title: title) } else { SectionHeader(title: String(localized: "Inspired by your search", comment: "Home row title: products like a past search")).redacted(reason: .placeholder) }
            }
            .padding(.horizontal, 12)
            // In a disabled horizontal ScrollView, as ProductRow lays its cards
            // out: the row then takes the width it's offered. A bare HStack of
            // cards reports its whole width, wider than any iPhone, and
            // Home laid out past the screen's edges until the rows landed
            // (owner, build 131 first launch).
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: ProductRow.spacing) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(spacing: ProductRow.spacing) {
                        ForEach(0..<2, id: \.self) { _ in
                            ProductCardShell {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.tile)
                            } price: {
                                Text(verbatim: "$00.00").brandFont(.subheadline).redacted(reason: .placeholder)
                            } note: {
                                Text(verbatim: "Brand").brandFont(.footnote).redacted(reason: .placeholder)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            }
            .scrollDisabled(true)
        }
        .padding(.vertical, 14)
        .background(Theme.canvas)
        // One element, so VoiceOver reads a single "Loading" (and UI tests
        // can measure the row) instead of the redacted stand-in text.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityIdentifier("rowPlaceholder")
    }
}

private struct CategoryChips: View {
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "Deals", comment: "Home shortcut chip"), color: Theme.chipColors[0], route: .deals)
                ForEach(Array(catalog.categories.enumerated()), id: \.element.id) { i, c in
                    chip(c.name, color: Theme.chipColors[i % Theme.chipColors.count], route: .category(c.id))
                }
                chip(String(localized: "All brands", comment: "Home shortcut chip"), color: Theme.chipColors[3], route: .brands)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.headerGradient)
        .accessibilityIdentifier("homeChips")
    }

    private func chip(_ name: String, color: Color, route: Route) -> some View {
        NavigationLink(value: route) {
            Text(name)
                .brandFont(.subheadline.bold())
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(color))
        }
        .buttonStyle(.plain)
    }
}

/// The images Home opens on, at the sizes the views ask for: every hero page,
/// then the premier brands' circles. The launch splash warms these.
enum HomeImages {
    static func urls(_ catalog: CatalogStore, mix: BrandMix) -> [URL] {
        let hero = HeroCarousel.spotlights(catalog, mix: mix).compactMap { sizedImageURL($0.image, width: HeroCarousel.imageWidth) }
        let circles = catalog.premierBrands.compactMap {
            sizedImageURL(mix.featured(catalog.products(for: $0.id), brand: $0.id)?.images.first, width: BrandCircles.imageWidth)
        }
        return hero + circles
    }
}

/// Paged brand spotlights — the Amazon hero carousel, one page per brand.
struct HeroCarousel: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.horizontalSizeClass) private var sizeClass
    let mix: BrandMix
    /// One page per premier brand and nothing else (owner, 2026-11-04: "remove
    /// these 3 … 7 slots only"): the three pages that rotated through other
    /// brands are gone. Premier brands never take more than these slots; a
    /// longer list would reshuffle each refresh through the same slots.
    private static let premierPages = 7
    static let imageWidth = 800

    struct Spotlight {
        let brand: Brand
        let image: String?
        let product: String?
        /// Set on a boosted page: it opens the product and says Sponsored.
        var productID: String? = nil
        var sponsored: String? = nil
    }

    private var spotlights: [Spotlight] { Self.spotlights(catalog, mix: mix, boosted: BoostStore.shared.premier) }

    static func spotlights(_ catalog: CatalogStore, mix: BrandMix, boosted: [String] = []) -> [Spotlight] {
        // Up to three premier pages go to Spotlight boosts (owner,
        // 2026-10-04); premier brands fill whatever boosts leave.
        let sponsored: [Spotlight] = boosted.prefix(3).compactMap { target in
            if target.hasPrefix("product:"), let p = catalog.product(String(target.dropFirst(8))), let b = catalog.brand(p.brand) {
                return Spotlight(brand: b, image: p.images.first, product: p.title, productID: p.id, sponsored: target)
            }
            if target.hasPrefix("brand:"), let b = catalog.brand(String(target.dropFirst(6))) {
                let product = mix.featured(catalog.products(for: b.id), brand: b.id)
                return Spotlight(brand: b, image: product?.images.first ?? b.image, product: product?.title, sponsored: target)
            }
            return nil
        }
        let taken = Set(sponsored.map(\.brand.id))
        // A permanent brand remains visible even without an imported product
        // feed; use its own brand artwork in that case. Premier brands come in
        // a new order and with the next product from their catalog each refresh.
        let premier = sponsored + mix.premierOrder(catalog.premierBrands.filter { !taken.contains($0.id) }, id: \.id)
            .prefix(premierPages - sponsored.count).map { b in
            let product = mix.featured(catalog.products(for: b.id), brand: b.id)
            return Spotlight(brand: b, image: product?.images.first ?? b.image, product: product?.title)
        }
        return premier
    }

    /// A full-width iPad window: a taller page and a wider text panel, so the
    /// product photo isn't a thin strip across a 13-inch screen.
    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        TabView {
            ForEach(spotlights, id: \.brand.id) { item in
                NavigationLink(value: item.productID.map(Route.product) ?? Route.brand(item.brand.id)) {
                    // Text on a solid panel, product on white — never text over a photo.
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.brand.name)
                                .brandFont(wide ? .largeTitle.bold() : .title2.bold()).lineLimit(2).minimumScaleFactor(0.75)
                            if let t = item.brand.tagline {
                                Text(t).brandFont(.subheadline).foregroundStyle(Color.primary.opacity(0.85)).lineLimit(4)
                            }
                            Spacer(minLength: 0)
                            Text("Shop now")
                                .brandFont(.footnote.bold()).foregroundStyle(Theme.onGold)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Theme.gold))
                        }
                        .foregroundStyle(.primary)
                        .padding(16)
                        .frame(width: wide ? 280 : 160, alignment: .leading)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(Theme.cocoa)
                        ZStack {
                            Theme.tile
                            if let image = item.image {
                                RemoteImage(url: image, width: Self.imageWidth).padding(12)
                            } else {
                                BrandArtwork(brand: item.brand, size: 140)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    // Paid placement, said plainly (FTC): top right of the page.
                    .overlay(alignment: .topTrailing) {
                        if item.sponsored != nil {
                            Text("Sponsored").brandFont(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(.black.opacity(0.7)))
                                .padding(8)
                                .accessibilityIdentifier("sponsoredLabel")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 30)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { if let t = item.sponsored { BoostStore.shared.record(t, tap: true) } })
                .onAppear { if let t = item.sponsored { BoostStore.shared.record(t) } }
                .accessibilityLabel(item.sponsored != nil ? String(localized: "Sponsored: \(item.brand.name)", comment: "VoiceOver label for a sponsored brand tile; the argument is a brand name") : item.brand.name)
                .accessibilityValue(item.product ?? "")
                .accessibilityHint("Shop this brand")
                .accessibilityIdentifier("heroBrand")
            }
        }
        // A refresh starts the new spotlights from the first page.
        .id(mix.round)
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .frame(height: wide ? 420 : 270)
        .padding(.top, 4)
        .background(LinearGradient(colors: [Theme.headerSoft, Theme.canvas], startPoint: .top, endPoint: .bottom))
    }
}

struct BrandCircles: View {
    @Environment(CatalogStore.self) private var catalog
    let mix: BrandMix
    static let imageWidth = 200

    private var brandOrder: [Brand] {
        let premier = mix.premierOrder(catalog.premierBrands, id: \.id)
        // A brand that leads with a sex toy (its first product, which is always
        // in Home's slice) has no circle: the circle shows that product.
        let rest = catalog.brands.filter { !catalog.isPremier($0.id) && catalog.products(for: $0.id).first?.keptOffHome != true }
        return premier + mix.arrange(rest, id: \.id, step: 8)
    }

    /// A premier brand's circle shows the same product as its carousel page
    /// this round; everyone else shows their first product.
    private func circleImage(_ b: Brand) -> String? {
        let products = catalog.products(for: b.id)
        return catalog.isPremier(b.id)
            ? mix.featured(products, brand: b.id)?.images.first
            : products.first?.images.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: String(localized: "Shop by brand", comment: "Home section title"), route: .brands).padding(.horizontal, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: this row holds every brand (~1,000). Built eagerly it
                // held the main thread for half a second as the catalog landed,
                // which the launch splash waited out.
                LazyHStack(alignment: .top, spacing: 14) {
                    // Premier brands first, then the rest rotate 8 per refresh —
                    // more than a screen's worth of circles.
                    ForEach(brandOrder) { b in
                        NavigationLink(value: Route.brand(b.id)) {
                            VStack(spacing: 6) {
                                Group {
                                    if let img = circleImage(b) {
                                        Circle().fill(Theme.tile)
                                            .overlay { RemoteImage(url: img, width: Self.imageWidth).padding(10) }
                                    } else {
                                        // No imported products: the brand's share image, or a monogram.
                                        BrandArtwork(brand: b, size: 76)
                                    }
                                }
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                                Text(b.name).brandFont(.caption).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .frame(width: 84)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(b.name)
                        .accessibilityIdentifier("brandCircle")
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 14)
        .background(Theme.surface)
    }
}
