import SwiftUI

/// Search, IMDb-style (owner, 2026-10-20): opened from the bar floating on
/// Browse, it fills the screen with Recent and Advanced Search tabs at the
/// top and the field down on the keyboard, an ✕ beside it to close. Recent
/// holds one Featured banner cycling through the premier brands and the last
/// three searches; typing turns it into live suggestions. Advanced narrows
/// the search by department, price, offers and sort before it runs.
struct SearchOverlay: View {
    let request: SearchRequest
    @Environment(AppNav.self) private var nav
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper
    @State private var text: String
    @State private var shown = false
    /// How far a left-edge swipe has dragged the overlay aside.
    @State private var dragX: CGFloat = 0
    /// The overlay's width — the window's, which on iPad isn't the screen's.
    @State private var width: CGFloat = 390
    /// The Featured banner's brands, worked out once per open (and again when
    /// the whole catalog lands), not in `body`: the drag below redraws the
    /// overlay every frame.
    @State private var featured: [FeaturedBanner.Slide] = []
    /// The rows for what's typed, worked out once per keystroke after a short
    /// pause, not in `body`: body runs on every redraw (each frame of the
    /// swipe back too), and each run walked thousands of title words.
    @State private var suggestions: [SearchSuggestion] = []
    @FocusState private var focused: Bool
    @State private var mode: Mode = .recent
    /// What Advanced search has picked so far.
    @State private var advanced = ProductFilters()

    enum Mode: Hashable { case recent, advanced }

    init(request: SearchRequest) {
        self.request = request
        _text = State(initialValue: request.initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Search", selection: $mode) {
                Text("Recent", comment: "Search screen tab: recent searches").tag(Mode.recent)
                Text("Advanced Search", comment: "Search screen tab: search with filters").tag(Mode.advanced)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16 + WindowControls.extraInset)
            .padding(.vertical, 8)
            .accessibilityIdentifier("searchMode")
            .opacity(shown ? 1 : 0)

            ScrollView {
                if mode == .advanced {
                    advancedForm
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    idle
                } else {
                    VStack(spacing: 0) {
                        if SearchWords.saysOwnership(SearchWords.tokens(text)) {
                            OwnershipNotice(compact: true).padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        ForEach(suggestions) { s in
                            suggestionRow(s)
                            Divider().padding(.leading, 72)
                        }
                    }
                }
            }
            // Typing fast skips the keystrokes in between: each new one cancels
            // the wait. The list also fills in when the background index lands.
            .task(id: "\(text)|\(catalog.searchIndexWarming)|\(catalog.isComplete)") {
                let q = text
                if q.trimmingCharacters(in: .whitespaces).isEmpty { suggestions = []; return }
                if !suggestions.isEmpty { try? await Task.sleep(for: .milliseconds(40)) }
                guard !Task.isCancelled else { return }
                suggestions = catalog.suggestions(q)
            }
            // The keyboard goes the moment a thumb starts moving the list, so
            // the suggestions under it can be reached.
            .scrollDismissesKeyboard(.immediately)
            // A tap anywhere that isn't a banner or button (the empty space
            // under the recent searches, between rows) closes search: the keyboard drops
            // and the page underneath comes back. Buttons inside win their taps.
            // Not on Advanced, where a tap between chips is a near miss.
            .contentShape(Rectangle())
            .onTapGesture { if mode == .recent { close() } }
            // Swipe-back lives on a thin strip at the left edge, not on the
            // whole overlay. On the whole overlay (as a high-priority gesture,
            // so an edge drag didn't open the row it started on) it took every
            // drag, and the suggestions couldn't be scrolled at all.
            .overlay(alignment: .leading) {
                // High priority on the strip alone: as a plain gesture, the
                // suggestion list's own scrolling sometimes won a drag that
                // began on a row, and search stayed open (the edge-swipe UI
                // test failed in full-suite runs, 2026-10-04). Scrolling
                // anywhere right of the strip is untouched.
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .highPriorityGesture(edgeSwipeBack)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
        }
        // The field rides on the keyboard, an ✕ beside it, as on IMDb.
        .safeAreaInset(edge: .bottom, spacing: 0) { field }
        .background { Theme.canvas.opacity(shown ? 1 : 0).ignoresSafeArea() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .offset(x: dragX)
        // Opened in the moment before the whole catalog lands, the banner
        // reads Home's slice, which holds every premier brand's products.
        .onChange(of: catalog.isComplete) { featured = FeaturedBanner.slides(catalog) }
        .onAppear {
            featured = FeaturedBanner.slides(catalog)
            focused = true
            // A plain ease, not a spring: nothing should bounce while the keyboard rises.
            withAnimation(.easeOut(duration: 0.22)) { shown = true }
        }
    }

    /// The field and its ✕, at the foot of the screen (on the keyboard while
    /// it's up). The ✕ closes search, as Back did.
    private var field: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                // The placeholder in a grey that reads on the dark field: the
                // system's placeholder colour failed the contrast audit.
                TextField("Search Marracat", text: $text,
                          prompt: Text("Search Marracat").foregroundStyle(Theme.textSecondary))
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { mode == .advanced ? submitAdvanced() : submit(text) }
                    .accessibilityIdentifier("searchInput")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Theme.field))
            .overlay(Capsule().stroke(Theme.hairline))
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.field))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("searchBack")
        }
        .padding(.horizontal, 16 + WindowControls.extraInset)
        .padding(.vertical, 8)
        .background(Theme.canvas.opacity(shown ? 1 : 0))
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 20)
    }

    /// Advanced Search: the words go in the field below; these narrow them.
    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Type what you're looking for below, then narrow it here.", comment: "Advanced search hint")
                .font(.subheadline).foregroundStyle(.secondary)
            group(String(localized: "Department", comment: "Advanced search heading")) {
                ForEach(catalog.categories) { c in
                    chip(c.name, on: advanced.categories.contains(c.id)) { advanced.categories.formSymmetricDifference([c.id]) }
                }
            }
            group(String(localized: "Price", comment: "Advanced search heading")) {
                ForEach(PriceBand.all.map { $0.name }, id: \.self) { name in
                    chip(PriceBand.title(name), on: advanced.priceBands.contains(name)) { advanced.priceBands.formSymmetricDifference([name]) }
                }
            }
            group(String(localized: "Show only", comment: "Advanced search heading")) {
                ForEach(ProductFilters.Offer.allCases) { o in
                    chip(o.title, on: advanced.offers.contains(o)) { advanced.offers.formSymmetricDifference([o]) }
                }
            }
            group(String(localized: "Sort by", comment: "Advanced search heading")) {
                ForEach(ProductSort.allCases) { sort in
                    chip(sort.shortName, on: advanced.sort == sort) { advanced.sort = sort }
                }
            }
            Button { submitAdvanced() } label: {
                Text("Search", comment: "Advanced search button").font(.headline).frame(maxWidth: .infinity).frame(height: 48)
            }
            .buttonStyle(PillButtonStyle(color: Theme.gold))
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("advancedSearchGo")
        }
        .padding(16)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ChipFlow { chips() }
        }
    }

    private func chip(_ title: String, on: Bool, _ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Text(title)
                .font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.black : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(on ? Theme.gold : Theme.field))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func submitAdvanced() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Analytics.shared.searchSource = "advanced"
        shopper.searched(q)
        nav.routers[request.tab]?.path.append(advanced == ProductFilters() ? .search(q) : .advancedSearch(q, advanced))
        close()
    }

    /// Search opens as an overlay, not a pushed screen, so iOS has nothing to
    /// pop and the edge swipe did nothing. This gives it the same gesture by
    /// hand: drag from the left edge and the whole overlay follows your thumb,
    /// keyboard dropping as it goes; let go past a quarter of the screen (or
    /// flick) and it leaves, otherwise it springs back.
    private var edgeSwipeBack: some Gesture {
        // Global space: the overlay moves with the drag, so local positions
        // would slide under the thumb.
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard value.translation.width > 0 else { return }
                if focused { focused = false }
                // The tab bar comes back under the thumb, as on a pushed
                // screen, instead of popping in once the overlay has gone.
                if nav.tabBarHidden { nav.setTabBarHidden(false) }
                dragX = value.translation.width
            }
            .onEnded { value in
                let flicked = value.predictedEndTranslation.width > width * 0.5
                if dragX > width * 0.25 || (dragX > 40 && flicked) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragX = width
                        shown = false
                    } completion: {
                        nav.search = nil
                    }
                } else {
                    nav.setTabBarHidden(true)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragX = 0 }
                }
            }
    }

    /// Before typing: the Featured banner, then the last three searches.
    private var idle: some View {
        return VStack(alignment: .leading, spacing: 0) {
            if !featured.isEmpty {
                FeaturedBanner(slides: featured) { push(.brand($0)) }
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
            ForEach(Array(shopper.recentSearches.prefix(3)), id: \.self) { q in
                Divider().padding(.horizontal, 8)
                HStack(spacing: 12) {
                    Button { submit(q, source: "recent") } label: {
                        HStack(spacing: 18) {
                            Image(systemName: "clock.arrow.circlepath").font(.title3)
                            Text(q).font(.body.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(q)
                    .accessibilityIdentifier("recentSearch")
                    Button { withAnimation(.snappy) { shopper.removeSearch(q) } } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().stroke(.primary, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(q) from recent searches")
                    .accessibilityIdentifier("removeSearch")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    /// Amazon-style: a thumbnail, the typed part plain and the rest bold, a
    /// flame on trending picks, and a "+" that puts the phrase in the field so
    /// the shopper can keep typing.
    private func suggestionRow(_ s: SearchSuggestion) -> some View {
        HStack(spacing: 12) {
            Button { choose(s) } label: {
                HStack(spacing: 12) {
                    Theme.tile
                        .frame(width: 44, height: 44)
                        .overlay {
                            if s.image == nil {
                                // Nothing to show a photo of yet, so say what
                                // the row does instead of leaving a blank tile.
                                Image(systemName: "magnifyingglass")
                                    .font(.headline).foregroundStyle(Color.black.opacity(0.55))
                            } else {
                                RemoteImage(url: s.image, width: 120).padding(4)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlighted(s.text)).lineLimit(1)
                        if s.trending {
                            Label("Trending", systemImage: "flame.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.deal)
                        } else if let subtitle = s.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(s.text)
            .accessibilityIdentifier(s.searchesAll ? "searchAllSuggestion"
                                        : (s.trending ? "trendingSuggestion" : "suggestion"))
            // "+" means keep typing from here. On the echo of what was already
            // typed it would add nothing, so it doesn't appear.
            if !s.searchesAll {
                Button { text = s.text + " " } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().stroke(.primary, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refine with \(s.text)")
                .accessibilityIdentifier("suggestionFill")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The part already typed stays regular; what the suggestion adds is bold.
    private func highlighted(_ phrase: String) -> AttributedString {
        var a = AttributedString(phrase)
        a.font = .body.weight(.bold)
        let typed = text.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, let r = a.range(of: typed, options: .caseInsensitive) { a[r].font = .body }
        return a
    }

    private func choose(_ s: SearchSuggestion) {
        switch s.kind {
        case .category(let id): push(.category(id))
        case .subcategory(let id): push(.subcategory(id))
        case .brand(let id): push(.brand(id))
        case .query: submit(s.text, source: "suggestion")
        }
    }

    private func push(_ route: Route) {
        nav.routers[request.tab]?.path.append(route)
        close()
    }

    /// Plays the open animation backwards, then removes the overlay.
    private func close() {
        focused = false
        nav.setTabBarHidden(false)
        withAnimation(.easeIn(duration: 0.18)) {
            shown = false
        } completion: {
            nav.search = nil
        }
    }

    private func open(_ productID: String) {
        nav.routers[request.tab]?.path.append(.product(productID))
        close()
    }

    private func submit(_ raw: String, source: String = "typed") {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Analytics.shared.searchSource = source
        shopper.searched(q)
        nav.routers[request.tab]?.path.append(.search(q))
        close()
    }
}

/// Amazon's list-style search results: image left, details right.
struct SearchResultsView: View {
    let query: String
    @Environment(CatalogStore.self) private var catalog
    @Environment(AppNav.self) private var nav
    @Environment(ShopperStore.self) private var shopper
    @Environment(\.currentTab) private var currentTab
    @State private var filters: ProductFilters
    /// What the search probably meant when it found nothing as typed
    /// (CatalogStore.alternatives); the first is shown when nothing else is.
    @State private var guesses: [String] = []
    /// "Picked for you": a product or two matching this search and what the
    /// shopper has been looking at (CatalogStore.personalPicks).
    @State private var picks: CatalogStore.PersonalPicks?

    /// `filters`: what Advanced search picked (department, price, offers,
    /// sort), applied from the start and changeable here as usual.
    init(query: String, filters: ProductFilters = .starting) {
        self.query = query
        _filters = State(initialValue: filters)
    }
    /// Search by meaning (on-device AI): products about what was typed even
    /// when they don't use its words. Shown under the word matches.
    @State private var meaning: [Product] = []
    /// Up to two sponsored products that fit the search (SponsoredStore).
    @State private var sponsored: [SponsoredStore.Item] = []

    var body: some View {
        let exact = catalog.search(query)
        // Nothing for the whole phrase: show what the closest shorter search
        // finds and say so, rather than a dead end.
        let relaxed = exact.isEmpty ? catalog.relaxedSearch(query) : nil
        // Not even that: the best guess at what was meant, shown in its place
        // (owner, 2026-11-03: suggestions, not "no matches").
        // A brand spelled closer to what was typed beats a shortened search
        // ("brandon blakwod" is Brandon Blackwood, not "brandon").
        let brandGuess = guesses.first.flatMap { g in catalog.brands.contains { $0.name == g } ? g : nil }
        let preferGuess = brandGuess != nil && relaxed != nil && SearchWords.prefersGuess(query, guess: brandGuess!, over: relaxed!.query)
        let guessed: String? = exact.isEmpty && (relaxed == nil || preferGuess) ? guesses.first : nil
        let showing = guessed ?? relaxed?.query
        let otherGuesses = Array(((preferGuess ? [relaxed!.query] : []) + guesses).filter { $0 != guessed }.prefix(3))
        let all = guessed.map { catalog.search($0) } ?? relaxed?.results ?? exact
        let unfiltered = filters == ProductFilters()
        let picked = unfiltered ? picks : nil
        let pickedIDs = Set(picked?.products.map(\.id) ?? [])
        // Sold-out results go to the bottom whatever the sort or relevance.
        // By the freshest stock this phone has, as the cards show it.
        let shown = catalog.inStockFirst(filters.apply(FreshCatalog.shared.current(all))).filter { !pickedIDs.contains($0.id) }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if SearchWords.saysOwnership(SearchWords.tokens(query)) {
                    OwnershipNotice().padding([.horizontal, .top], 12)
                }
                HStack {
                    if let showing {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Showing results for “\(showing)”", comment: "Search header when the search as typed found nothing; the argument is what we think was meant")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(shown.count) results for “\(showing)”", comment: "Search result count (plural variations in the catalog); the argument after is the search")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("resultsHeader")
                    } else {
                        Text("\(shown.count) results for “\(query)”", comment: "Search result count (plural variations in the catalog); the argument after is the search")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("resultsHeader")
                    }
                    Spacer()
                }
                .padding(12)
                if !otherGuesses.isEmpty && (showing != nil || exact.isEmpty) {
                    DidYouMeanRow(guesses: otherGuesses).padding(.bottom, 10)
                }
                FilterBar(products: all, filters: $filters).padding(.bottom, 10)
                if let picked {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Picked for you", comment: "Heading over one or two search results chosen from what the shopper has been looking at").font(.headline)
                        Group {
                            if picked.searched {
                                Text("Because you searched “\(picked.phrase)”", comment: "Why these were picked; the argument is an earlier search")
                            } else {
                                Text("Because you looked at \(picked.phrase.lowercased())", comment: "Why these were picked; the argument is a kind of product, e.g. keychains")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("personalPicksHeader")
                    .padding(.horizontal, 12)
                    ForEach(picked.products) { p in
                        SearchResultRow(product: p)
                        Divider()
                    }
                }
                if shown.isEmpty {
                    if filters.offers.contains(.clean) && !all.isEmpty {
                        CleanEmptyState(filters: $filters).padding(.top, 20)
                    } else if meaning.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    }
                }
                ForEach(sponsored, id: \.self) { it in
                    if let p = catalog.product(it.productID) {
                        SearchResultRow(product: p)
                            .overlay(alignment: .topLeading) { SponsoredTag().padding(8) }
                            .simultaneousGesture(TapGesture().onEnded { SponsoredStore.tap(it, placement: "search") })
                        Divider()
                    }
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, p in
                    SearchResultRow(product: p)
                        .onAppear { ImageLoader.shared.prefetch(after: i, in: shown, width: 300) }
                    Divider()
                }
                if !meaning.isEmpty && filters.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.isEmpty ? "Nothing uses those words. These match what you mean:" : "Matches what you mean")
                            .font(.headline)
                        Text("Found by meaning, on your iPhone").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .accessibilityIdentifier("meaningHeader")
                    ForEach(meaning) { p in
                        SearchResultRow(product: p)
                        Divider()
                    }
                }
            }
            .readableWidth()
        }
        .background(Theme.surface)
        .marracatChrome(query: query)
        // The bar no longer holds the query, so this reopens search with it
        // to change it.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { nav.openSearch(initial: query, from: currentTab, pushed: true) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Change search")
                .accessibilityIdentifier("editSearch")
            }
        }
        .task(id: query) {
            guesses = catalog.search(query).isEmpty ? catalog.alternatives(query, excluding: catalog.relaxedSearch(query)?.query) : []
            picks = catalog.personalPicks(query, recentSearches: shopper.recentSearches, recentlyViewed: shopper.recentlyViewed)
        }
        .task(id: query) { sponsored = await SponsoredStore.items("search", q: query, catalog: catalog) }
        // Counted once the results are known (n = word matches for the whole phrase).
        .task(id: query) {
            let source = Analytics.shared.searchSource
            Analytics.shared.searchSource = "typed"
            Analytics.shared.search(query, results: exact.count, source: source)
            // Which aisle this search was for, and when (ShoppingRhythm).
            ShoppingRhythm.shared.searched(exact)
        }
        .task(id: query) {
            let words = Set(catalog.search(query).prefix(400).map(\.id))
            meaning = await MeaningPicks.meaning(of: query, catalog: catalog, excluding: words)
        }
    }
}

/// Shown above the results of a search saying "independent" anywhere in it,
/// before or after other words (owner, 2026-11-03: "a prompt that tells them
/// all items on this site are independent"; 2026-11-08 picked the headline
/// card, option 2 of five, and asked for it with any words around "black
/// owned"). `compact` is the one-line version over the typing suggestions.
/// Since 2026-11-13 (owner) the notice itself says "independent" too, like
/// the rest of the app: "Every brand on Marracat is independent".
struct OwnershipNotice: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private var body_: Text {
        let n = catalog.brands.count
        return n >= 100
            ? Text("Every one of our \(n.formatted()) brands is independent, so here’s everything that matches.", comment: "Under 'You’re in the right place.' on a search asking who owns the brands; the argument is the number of brands")
            : Text("Every brand on Marracat is independent, so here’s everything that matches.", comment: "Under 'You’re in the right place.' on a search asking who owns the brands, before the brand count is known")
    }

    var body: some View {
        let dark = scheme == .dark
        HStack(alignment: compact ? .center : .top, spacing: 12) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: compact ? 13 : 16, weight: .semibold))
                .foregroundStyle(dark ? Color(red: 0.11, green: 0.10, blue: 0.09) : Color(red: 0.91, green: 0.78, blue: 0.44))
                .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)
                .background(Circle().fill(dark ? Color.white : Color.black))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You’re in the right place.", comment: "Headline of the notice on a search asking who owns the brands")
                    .font(.subheadline.weight(.bold))
                if !compact {
                    body_.font(.footnote).foregroundStyle(dark ? Color(white: 0.73) : Color(red: 0.36, green: 0.34, blue: 0.31))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Every brand on Marracat is independent.", comment: "One-line notice over search suggestions while typing a search asking who owns the brands")
                        .font(.caption).foregroundStyle(dark ? Color(white: 0.73) : Color(red: 0.36, green: 0.34, blue: 0.31))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: compact ? 12 : 16)
            .fill(dark ? Color(red: 0.11, green: 0.10, blue: 0.09) : Color(red: 0.965, green: 0.953, blue: 0.925)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 16)
            .strokeBorder(dark ? Color(red: 0.17, green: 0.16, blue: 0.13) : Color(red: 0.925, green: 0.898, blue: 0.839)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ownershipNotice")
    }
}

/// "Did you mean" chips: other searches that find products, each opening its results.
struct DidYouMeanRow: View {
    let guesses: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Did you mean", comment: "Before suggested searches").font(.subheadline).foregroundStyle(.secondary)
                ForEach(guesses, id: \.self) { g in
                    NavigationLink(value: Route.search(g)) {
                        Text(g).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("didYouMean")
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

struct SearchResultRow: View {
    let product: Product
    @Environment(CatalogStore.self) private var catalog
    @Environment(CartStore.self) private var cart
    @Environment(ShopperStore.self) private var shopper
    @State private var added = false
    @State private var toast: ActionToastMessage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NavigationLink(value: Route.product(product.id)) {
                ProductImageWell(url: product.images.first, width: 300).frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 5) {
                NavigationLink(value: Route.product(product.id)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(product.title).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                        Text("by \(catalog.brand(product.brand)?.name ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    // The title and byline form one tap target, including the
                    // gap between them where the link's activation point sits.
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier(product.available ? "resultTitle" : "resultTitleSoldOut")
                if product.isCertifiedOrganic { OrganicBadge() }
                if product.isMarracatClean { CleanBadge() }
                if product.isMarracatTrueMetal { TrueMetalBadge(ethical: product.isEthicallySourced) }
                ForEach(QualityLabelBadge.Label.all(for: product)) { QualityLabelBadge(label: $0) }
                if let off = product.percentOff, product.available { DealBadge(percent: off) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PriceView(product.price, currency: product.currencyCode, size: 22)
                    if let c = product.compareAt, product.percentOff != nil {
                        Text(Money.leading(c, currency: product.currencyCode)).font(.caption).strikethrough().foregroundStyle(.secondary)
                    }
                }
                if product.available {
                    actions
                } else {
                    Text("Currently unavailable").font(.caption).foregroundStyle(Theme.deal)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .actionToast($toast)
    }

    /// Three chips: See options OR Add to cart (never both), Track price, and
    /// Add to List (owner, 2026-10-17). Options go to the product page; so
    /// does a brand whose checkout isn't Marracat's cart.
    private var actions: some View {
        HStack(spacing: 8) {
            if product.hasOptions || !(catalog.brand(product.brand)?.usesMarracatCart ?? true) {
                NavigationLink(value: Route.product(product.id)) {
                    IconChipLabel(title: String(localized: "See options", comment: "Search result button: open the product to pick a size or colour"), tint: .primary) { OptionsGlyph() }
                }
                .buttonStyle(ActionChipStyle())
                .accessibilityIdentifier("resultSeeOptions")
            } else if let v = product.firstAvailableVariant {
                Button {
                    cart.add(productID: product.id, variantID: v.id,
                             option: v.isDefault ? nil : v.title, unitPrice: v.price,
                             currency: product.currencyCode)
                    added = true
                    toast = .init(text: String(localized: "Added to cart", comment: "Toast after adding a search result to the cart"), symbol: "cart.fill")
                } label: {
                    IconChipLabel(title: added ? String(localized: "Added", comment: "Button state: the item is in the cart") : String(localized: "Add to cart", comment: "Button: add the item to the cart"),
                                  symbol: added ? "checkmark" : "cart.badge.plus", tint: .primary, on: added)
                }
                .buttonStyle(ActionChipStyle())
                .accessibilityIdentifier("resultAddToCart")
            }
            TrackPriceButton(productID: product.id, compact: true) { toast = $0 }
                .buttonStyle(ActionChipStyle())
                .accessibilityIdentifier("resultTrackPrice")
            Button {
                shopper.toggleSaved(product.id)
                toast = shopper.isSaved(product.id) ? .init(text: String(localized: "Added to Your List", comment: "Toast"), symbol: "heart.fill")
                                                    : .init(text: String(localized: "Removed from Your List", comment: "Toast"), symbol: "heart")
            } label: {
                let saved = shopper.isSaved(product.id)
                IconChipLabel(title: saved ? String(localized: "Saved", comment: "Button state: the product is in Your List") : String(localized: "Add to List", comment: "Button: save the product to Your List"),
                              symbol: saved ? "heart.fill" : "heart", tint: .pink, on: saved)
            }
            .buttonStyle(ActionChipStyle())
            .accessibilityIdentifier("resultAddToList")
        }
    }
}
