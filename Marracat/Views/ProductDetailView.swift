import SwiftUI

struct ProductDetailView: View {
    let productID: String
    @Environment(CatalogStore.self) private var catalog
    @Environment(ProductDetailStore.self) private var details
    @Environment(CartStore.self) private var cart
    @Environment(ShopperStore.self) private var shopper
    @Environment(AppNav.self) private var nav
    @State private var variantID: Int64?
    @State private var sizes = SizeMemory.load()
    @State private var saveToList = false
    @State private var quantity = 1
    @State private var browser: IdentifiedURL?
    @State private var gallery: GalleryStart?
    @State private var checkout: CheckoutRequest?
    @State private var showAdded = false
    @State private var showCleanStandard = false
    @State private var showTrueMetalStandard = false
    @State private var labelStandard: QualityLabelBadge.Label?
    @Environment(BuyerStore.self) private var buyer
    /// Buy Now: the store's checkout is being built; or details are needed first.
    @State private var buyBusy = false
    /// The UCP checkout Buy Now built, so a paid order can be tracked.
    @State private var buyNowCheckoutID: String?
    @State private var toast: ActionToastMessage?
    @State private var showLists = false
    /// Sponsored products beside this one (SponsoredStore).
    @State private var sponsoredNear: [SponsoredStore.Item] = []
    @State private var addPressed = false
    @State private var addAnchor: CGRect = .zero
    @Environment(AccountStore.self) private var account
    /// When this page came on screen, for how long it was looked at (TasteProfile).
    @State private var openedAt: Date?
    /// The product's name has scrolled up under the bar, which then carries
    /// it (owner, 2026-11-01, approved from a preview: "as i slide up, the
    /// product name should appear in the header").
    @State private var titleInBar = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    @MainActor static func labelOpened(_ label: String) {
        Analytics.shared.track("label_sheet_open", ["label": .string(Analytics.rowID(label))])
    }

    var body: some View {
        Group {
            if let p = catalog.product(productID), let brand = catalog.brand(p.brand) {
                content(p, brand)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            // Only there once the name has gone, so VoiceOver and
                            // the UI tests don't find a second, invisible title.
                            if titleInBar {
                                CenteredBarTitle {
                                    VStack(spacing: 1) {
                                        MarqueeText(text: p.title)
                                        Text(brand.name).brandFont(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                }
                                .transition(.opacity)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("productBarTitle")
                            }
                        }
                    }
                    .onAppear { shopper.viewed(p.id); openedAt = .now; Analytics.shared.productViewed(p); FreshCatalog.shared.productViewed(p) }
                    .task(id: p.id) { await FreshCatalog.shared.refreshIfDue(p.brand, catalog: catalog) }
                    .onDisappear {
                        if let openedAt { TasteProfile.shared.viewed(p.id, dwell: Date().timeIntervalSince(openedAt)) }
                        openedAt = nil
                        Analytics.shared.productLeft(p)
                    }
                    // The description and the rest of the gallery aren't in
                    // the catalog any more; they arrive while the page is read.
                    .task(id: p.id) { await details.load(p.id) }
                    // The brand's own stock right now; the catalog's can be a day old.
                    .task(id: p.id) { await details.loadStock(p.id) }
                    // On the page, not the row: an empty row never runs a task.
                    .task(id: p.id) { sponsoredNear = await SponsoredStore.items("product", product: p.id, catalog: catalog) }
            } else {
                ContentUnavailableView("Item not found", systemImage: "questionmark.circle")
            }
        }
        // "View on <brand>.com" is browsing, so it stays in Safari; Buy Now is
        // checkout, so it runs in the app.
        .sheet(item: $browser) { SafariView(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: $showCleanStandard) { CleanStandardSheet().onAppear { Self.labelOpened("clean") } }
        .sheet(isPresented: $showTrueMetalStandard) { TrueMetalStandardSheet().onAppear { Self.labelOpened("trueMetal") } }
        .sheet(item: $labelStandard) { label in QualityLabelStandardSheet(label: label).onAppear { Self.labelOpened(label.id) } }
        .fullScreenCover(item: $gallery) { start in
            ProductGallery(images: images(catalog.product(productID)), startAt: start.index, productID: productID)
        }
        .brandCheckout($checkout) { req, receipt in
            toast = .init(text: String(localized: "Order placed with \(req.brand.name)", comment: "Toast after paying; the argument is a brand name"), symbol: "checkmark.circle.fill")
            // Every Shopify order is followed (owner, 2026-10-13): by its UCP
            // checkout when Buy Now built one, else by the order id alone.
            if req.brand.isShopify, buyNowCheckoutID != nil || receipt.orderID != nil {
                let id = buyNowCheckoutID, orderID = receipt.orderID, items = PurchasedItem.titles(receipt.items, lines: req.lines, catalog: catalog)
                Task { await OrderTrackingStore.shared.register(brandID: req.brand.id, checkoutID: id, orderID: orderID, items: items) }
            }
            buyNowCheckoutID = nil
            shopper.recordCheckout(brandID: req.brand.id, lines: req.lines,
                                   subtotal: receipt.subtotal ?? cart.subtotal(req.lines, catalog: catalog),
                                   orderID: receipt.orderID, total: receipt.total, currency: receipt.currency ?? req.brand.currencyCode,
                                   subtotalCurrency: receipt.subtotal == nil ? req.brand.currencyCode : (receipt.currency ?? req.brand.currencyCode), items: receipt.items)
        }
        .overlay {
            if showLists, let p = catalog.product(productID) {
                QuickListFan(product: p, anchor: addAnchor, choices: listChoices(p),
                             pick: { pickList($0, p) }, close: { showLists = false })
            }
        }
        .coordinateSpace(.named("productPage"))
        .actionToast($toast)
        .marracatChrome()
    }

    /// The catalog carries one photo a product; the rest arrive with the
    /// description. Until they do, the one photo is what the pager shows, so
    /// the page never waits on the network to draw.
    private func images(_ p: Product?) -> [String] {
        guard let p else { return [] }
        let fetched = details.detail(p.id)?.images ?? []
        return fetched.count > p.images.count ? fetched : p.images
    }

    /// The catalog carries variants only for single-variant products; anything
    /// with sizes or colours gets its list from the page's own fetch. Reading
    /// only the catalog made 40% of products say "Currently unavailable" with
    /// Add to Cart disabled (build 70).
    /// Then the store's live stock goes over them, when it has answered.
    /// "Color: ", "Color / Size: " — what the store calls its options, in the
    /// order the option's title lists them (owner, 2026-10-16: "Option:"
    /// left a shopper looking for a size that SK 01 doesn't come in).
    private func optionLabel(_ p: Product) -> String {
        Self.optionLabel(details.detail(p.id)?.optionNames)
    }

    static func optionLabel(_ names: [String]?) -> String {
        let names = (names ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if names.isEmpty { return String(localized: "Option: ", comment: "Product page: before the chosen option") }
        return names.joined(separator: " / ") + ": "
    }

    /// The photo of the colour the shopper picked, once they pick one: the
    /// store's own photo for it, from the page's fetch (the bundled variants
    /// don't carry it). The pager turns to it, like the brand's own site.
    private func variantImage(_ p: Product) -> Int? {
        guard let variantID, let fetched = details.detail(p.id) else { return nil }
        guard let i = fetched.variants?.first(where: { $0.id == variantID })?.image,
              i < images(p).count else { return nil }
        return i
    }

    private func variants(_ p: Product) -> [Variant] {
        let base = p.variants.isEmpty ? (details.detail(p.id)?.variants ?? []) : p.variants
        return LiveStock.overlay(base, live: details.liveStock(p.id), fallbackPrice: p.price)
    }

    private func selected(_ p: Product) -> Variant? {
        let all = variants(p)
        return all.first { $0.id == variantID } ?? usualSize(p, all) ?? all.first(where: \.available) ?? all.first
    }

    /// The shopper's usual size for this brand or department, in stock
    /// (SizeMemory; owner, 2026-11-08: "lets remember the sizes").
    private func usualSize(_ p: Product, _ all: [Variant]) -> Variant? {
        guard TasteProfile.shared.enabled, SizeMemory.departments.contains(p.category) else { return nil }
        return sizes.variant(in: all, department: p.category, brand: p.brand, optionNames: details.detail(p.id)?.optionNames)
    }

    /// A chosen size goes into SizeMemory when it goes in the bag or is bought.
    private func rememberSize(_ v: Variant, _ p: Product) {
        SizeMemory.record(v, of: p, optionNames: details.detail(p.id)?.optionNames)
        sizes = SizeMemory.load()
    }

    /// No variants yet, and the fetch that brings them hasn't finished.
    /// Or it reads sold out and the store is being asked right now: say so
    /// rather than flash "Currently unavailable" over an item that's back.
    private func checkingStock(_ p: Product) -> Bool {
        let all = variants(p)
        if all.isEmpty && p.available && details.detail(p.id) == nil { return true }
        return details.isCheckingStock(p.id) && !(selected(p)?.available ?? false)
    }

    private func content(_ p: Product, _ brand: Brand) -> some View {
        let v = selected(p)
        let price = v?.price ?? p.price
        let compare = v?.compareAt ?? p.compareAt
        let inStock = v?.available ?? false

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink(value: Route.brand(brand.id)) { StoreCard(brand: brand) }
                    .buttonStyle(ActionChipStyle())
                    .accessibilityIdentifier("visitStore")
                Text(p.title).brandFont(.body)
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).maxY < 8 } action: { gone in
                        withAnimation(.easeInOut(duration: 0.2)) { titleInBar = gone }
                    }
                ImagePager(images: images(p), productID: p.id, openGallery: {
                    gallery = GalleryStart(index: $0)
                    Analytics.shared.track("gallery_open", ["product": .string(p.id)])
                }, show: variantImage(p))
                    .frame(height: sizeClass == .regular ? 560 : 380)

                // The price, and across from it the product's badges (owner,
                // 2026-11-20: "put the badge on the same row as the price but
                // on the opposite side"; they sat under the name, centred,
                // for an hour that day and in rows of text before it).
                HStack(alignment: .center, spacing: 12) {
                    priceBlock(price: price, compare: compare, currency: p.currencyCode)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("productPrice")
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    // Smaller when a product carries more than fit beside its price.
                    ViewThatFits(in: .horizontal) {
                        badgeSeals(p, size: 52)
                        badgeSeals(p, size: 44)
                        badgeSeals(p, size: 34)
                    }
                }
                if let origin = brand.shipsFromLabel {
                    Label(origin, systemImage: "airplane").brandFont(.subheadline).foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("shipsFrom")
                }
                if p.currencyCode != "USD" {
                    Text("Store prices in \(p.currencyCode). Final currency and shipping are confirmed at checkout.")
                        .brandFont(.caption).foregroundStyle(Theme.secondary)
                }

                if p.hasOptions {
                    VStack(alignment: .leading, spacing: 8) {
                        (Text(optionLabel(p)).foregroundStyle(Theme.secondary) + Text(v?.title ?? "").fontWeight(BrandFont.heaviest))
                            .brandFont(.subheadline)
                        if variantID == nil, let v, let usual = usualSize(p, variants(p)), usual.id == v.id,
                           let size = SizeMemory.size(in: v.title, optionNames: details.detail(p.id)?.optionNames) {
                            Label(String(localized: "Your usual size, \(size)", comment: "Product page: the shopper's remembered size was picked for them; the argument is a size"),
                                  systemImage: "ruler")
                                .brandFont(.caption).foregroundStyle(Theme.secondary)
                                .accessibilityIdentifier("usualSize")
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(variants(p)) { opt in
                                    Button { variantID = opt.id } label: {
                                        Text(opt.title)
                                            .brandFont(.subheadline)
                                            .strikethrough(!opt.available)
                                            .foregroundStyle(opt.available ? Color.primary : Theme.secondary)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                                            .overlay(RoundedRectangle(cornerRadius: 8)
                                                .stroke(opt.id == v?.id ? Theme.link : Theme.hairline,
                                                        lineWidth: opt.id == v?.id ? 2 : 1))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(2)
                        }
                    }
                }

                Group {
                    if checkingStock(p) {
                        Text("Checking availability…").foregroundStyle(Theme.secondary)
                    } else {
                        Text(inStock ? "In Stock" : "Currently unavailable")
                            .foregroundStyle(inStock ? Theme.stock : Theme.deal)
                    }
                }
                .brandFont(.title3)
                .accessibilityIdentifier("stockStatus")

                // Sold out: the shopper can ask to hear when it's back. Only
                // Shopify stores have the live stock the server checks.
                if !inStock && !checkingStock(p) && brand.isShopify {
                    RestockButton(productID: p.id, variantID: p.hasOptions ? v.map { String($0.id) } : nil,
                                  option: p.hasOptions ? v?.title : nil)
                }

                if inStock {
                    Menu {
                        Picker("Quantity", selection: $quantity) {
                            ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                        }
                    } label: {
                        HStack {
                            Text("Quantity: \(quantity)").foregroundStyle(.primary)
                            Image(systemName: "chevron.down").brandFont(.caption).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
                    }
                }

                // Brands without a verified cart hand-off (most WooCommerce
                // stores) stay out of the Marracat cart; Buy Now opens their site.
                if brand.usesMarracatCart {
                    Button {
                        guard let v else { return }
                        rememberSize(v, p)
                        cart.add(productID: p.id, variantID: v.id, quantity: quantity,
                                 option: v.isDefault ? nil : v.title, unitPrice: v.price, currency: p.currencyCode)
                        withAnimation { showAdded = true }
                    } label: { Text("Add to Cart") }
                        .buttonStyle(PillButtonStyle(color: Theme.gold))
                        .disabled(!inStock)
                        .accessibilityIdentifier("addToCart")
                }

                Button {
                    if brand.usesMarracatCart || brand.checksOutByUCP {
                        // Straight to the brand's own payment page for this
                        // item, not the cart (owner, 2026-10-05).
                        Task { await buyNow(p, brand) }
                    } else if let url = p.productURL {
                        // A Woo store without a verified checkout link (Ten To
                        // One's sits behind an age gate): open the product where
                        // the brand expects it.
                        browser = IdentifiedURL(url: url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if buyBusy { ProgressView().tint(Color.primary) }
                        Text(buyBusy ? "Opening checkout…" : brand.usesMarracatCart || brand.checksOutByUCP ? "Buy Now" : "Buy at \(brand.name)")
                    }
                }
                    .disabled(buyBusy)
                    .buttonStyle(PillButtonStyle(color: Theme.orange, text: .primary))
                    .disabled(!inStock)
                    .accessibilityIdentifier("buyNow")

                // Every action as a symbol in one bar of equal parts (owner,
                // 2026-11-01, picked from previews: "just have the buttons and
                // have the buttons layed out symmetrically"). The names stay
                // for VoiceOver; the bar was chips with names before.
                ActionBar {
                    if inStock {
                        TrackPriceButton(productID: p.id) { toast = $0 }
                        ActionBarDivider()
                    }
                    // Tap saves; hold fans out the lists (QuickListFan;
                    // "Save to a list" was its own chip until 2026-10-05).
                    ActionChipLabel(title: shopper.isSaved(p.id) ? String(localized: "Saved", comment: "Button state: the product is in Your List") : String(localized: "Add to List", comment: "Button: save the product to Your List"),
                                    symbol: shopper.isSaved(p.id) ? ListsIcon.filled : ListsIcon.name, tint: .pink, on: shopper.isSaved(p.id))
                        .scaleEffect(addPressed ? 0.95 : 1)
                        .brightness(addPressed ? 0.12 : 0)
                        .animation(.spring(duration: 0.2), value: addPressed)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("productPage")) } action: { addAnchor = $0 }
                        .onTapGesture { toggleSaved(p) }
                        .onLongPressGesture(minimumDuration: 0.4, pressing: { addPressed = $0 }) { showLists = true }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { toggleSaved(p) }
                        .accessibilityAction(named: "Choose a list") { showLists = true }
                        .accessibilityIdentifier("addToList")
                        .accessibilityHint("Touch and hold to choose a list")
                    ActionBarDivider()
                    Button {
                        let hidden = shopper.hidden.contains(p.id)
                        if hidden { shopper.unhide(p.id) } else { shopper.hide(p.id) }
                        toast = hidden ? .init(text: String(localized: "Back in your recommendations", comment: "Toast after undoing Not interested"), symbol: "hand.thumbsup")
                                       : .init(text: String(localized: "Got it. We'll show fewer like this", comment: "Toast after tapping Not interested"), symbol: "hand.thumbsdown.fill")
                    } label: {
                        let hidden = shopper.hidden.contains(p.id)
                        ActionChipLabel(title: String(localized: "Not interested", comment: "Button: show fewer products like this"),
                                        symbol: hidden ? "hand.thumbsdown.fill" : "hand.thumbsdown", tint: .purple, on: hidden)
                    }
                    .accessibilityIdentifier("notInterested")
                    .accessibilityHint(shopper.hidden.contains(p.id) ? "Shows it in recommendations again" : "Shows fewer like this")
                    ActionBarDivider()
                    ShareActions(product: p)
                    if BoostStore.shared.enabled {
                        ActionBarDivider()
                        BoostLink(target: .product(p), chip: true)
                    }
                }
                .buttonStyle(ActionChipStyle())
                .sheet(isPresented: $saveToList) { SaveToListSheet(productID: p.id) }

                if let d = p.description ?? details.detail(p.id)?.description, !d.isEmpty {
                    Divider()
                    Text("About this item").brandFont(.headline)
                    Text(d).brandFont(.subheadline)
                }

                if let url = p.productURL {
                    Button { browser = IdentifiedURL(url: url) } label: {
                        Label("View on \(brand.domain)", systemImage: "safari").brandFont(.subheadline)
                    }
                }

                CommentsSection(productID: p.id)
            }
            .padding(12)
            .readableWidth()

            SponsoredProductRow(items: sponsoredNear, placement: "product")
            let more = Array(catalog.products(for: brand.id).filter { $0.id != p.id && $0.available }.prefix(12))
            if !more.isEmpty {
                ProductRow(title: String(localized: "More from \(brand.name)", comment: "Product row title; the argument is a brand name"), products: more, route: .brand(brand.id), track: "brand_more")
            }
            // On-device AI (MeaningFeatures.swift): the same look, then what
            // goes with it from other departments. Each row skips what a row
            // above it already shows (owner, 2026-11-17).
            let moreIDs = Set(more.map(\.id))
            AsyncProductRow(title: String(localized: "Similar look", comment: "Product row title: products that look like this one"), key: p.id, identifier: "similarLook", track: "similar") {
                await MeaningPicks.similar(to: p, catalog: catalog, excluding: moreIDs)
            }
            PairingsRow(product: p, shownAbove: moreIDs)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if showAdded {
                AddedToast { nav.tab = .cart } dismiss: { withAnimation { showAdded = false } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Buy Now opens the brand's own Shopify payment page for this one item,
    /// built over UCP when its store can (filled in with whatever is saved,
    /// followed to "Delivered"). No Marracat form first (owner, 2026-11-02):
    /// the store's checkout asks for what's missing, and the first order's
    /// address is saved for the next one (BrandCheckout). Brands without UCP
    /// (Big Cartel, Woo) open their cart link, where the store asks.
    private func buyNow(_ p: Product, _ brand: Brand) async {
        guard let v = selected(p) else { return }
        rememberSize(v, p)
        let lines = [CartLine(productID: p.id, variantID: v.id, quantity: quantity,
                              option: v.isDefault ? nil : v.title, unitPrice: v.price, currency: p.currencyCode)]
        buyNowCheckoutID = nil
        if brand.ucpEndpoint != nil {
            buyBusy = true
            defer { buyBusy = false }
            let line = UCPLineRequest(variantID: v.id, quantity: quantity, unitPriceMinor: Int((v.price * 100).rounded()))
            if let c = await UCPClient.buildCheckout(brand: brand, lines: [line], saved: buyer.details,
                                                     accountName: account.user?.name, accountEmail: account.user?.email),
               let url = c.continueURL {
                buyNowCheckoutID = c.id
                checkout = CheckoutRequest(brand: brand, lines: lines, url: url)
                return
            }
        }
        await RelayStore.shared.ensureAddress()
        if let url = CartStore.checkoutURL(brand: brand, lines: lines, checkoutEmail: buyer.details?.email, buyer: buyer.details) {
            checkout = CheckoutRequest(brand: brand, lines: lines, url: url)
        } else {
            toast = .init(text: String(localized: "\(brand.name)'s checkout couldn't open. Try again.", comment: "Error toast; the argument is a brand name"), symbol: "exclamationmark.triangle")
        }
    }

    private func toggleSaved(_ p: Product) {
        shopper.toggleSaved(p.id)
        toast = shopper.isSaved(p.id) ? .init(text: String(localized: "Added to Your List", comment: "Toast"), symbol: ListsIcon.filled)
                                      : .init(text: String(localized: "Removed from Your List", comment: "Toast"), symbol: ListsIcon.name)
    }

    private func listChoices(_ p: Product) -> [QuickListFan.Choice] {
        let quick = shopper.quickLists(for: p, catalog: catalog)
        let department = catalog.category(p.category)?.name ?? String(localized: "Saved", comment: "Button state: the product is in Your List")
        var out = quick.recent.map { QuickListFan.Choice(kind: .list($0)) }
        if let list = quick.sameCategory { out.append(.init(kind: .list(list))) }
        else if !shopper.lists.contains(where: { $0.name == department }) { out.append(.init(kind: .newList(department))) }
        out.append(.init(kind: .all))
        return out
    }

    private func pickList(_ choice: QuickListFan.Choice, _ p: Product) {
        switch choice.kind {
        case .list(let list):
            if list.items.contains(p.id) {
                shopper.remove(p.id, from: list.id)
                toast = .init(text: String(localized: "Removed from \(list.name)", comment: "Toast; the argument is a saved list name"), symbol: "folder")
            } else {
                shopper.add(p.id, to: list.id)
                toast = .init(text: String(localized: "Added to \(list.name)", comment: "Toast; the argument is a saved list name"), symbol: "folder.fill")
            }
        case .newList(let name):
            if let id = shopper.createList(named: name) {
                shopper.add(p.id, to: id)
                toast = .init(text: String(localized: "Added to \(name)", comment: "Toast; the argument is a saved list name"), symbol: "folder.fill")
            }
        case .all:
            Task { try? await Task.sleep(for: .milliseconds(250)); saveToList = true }
        }
    }

    /// One seal per badge (owner, 2026-10-31, from the B3 preview), side by
    /// side with no text beside them (owner, 2026-11-20: "we only need to
    /// have the badges we don't need the text. When someone clicks on the
    /// badge it'll show them what the badge means"); each seal is the button
    /// to that badge's standard.
    @ViewBuilder
    private func badgeSeals(_ p: Product, size: CGFloat) -> some View {
        if p.isCertifiedOrganic || p.isMarracatClean || p.isMarracatTrueMetal
            || !QualityLabelBadge.Label.all(for: p).isEmpty {
            HStack(spacing: size * 0.18) {
                if p.isCertifiedOrganic {
                    BadgeSealMark(color: Theme.organic, symbol: "leaf.fill", name: "Certified organic",
                                  summary: "Certified organic by the brand\u{2019}s certifier.", explains: false, size: size)
                        .accessibilityIdentifier("organicSeal")
                }
                if p.isMarracatClean {
                    Button { showCleanStandard = true } label: {
                        BadgeSealMark(color: Theme.clean, symbol: "checkmark.shield.fill", name: "Marracat Clean",
                                      summary: "Its ingredient list is published, with nothing on it banned in any major market.", size: size)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cleanBadgeButton")
                }
                if p.isMarracatTrueMetal {
                    Button { showTrueMetalStandard = true } label: {
                        BadgeSealMark(color: Theme.metal, symbol: "checkmark.seal.fill", name: "Marracat True Metal",
                                      tier: p.isEthicallySourced ? "Ethically Sourced" : nil,
                                      summary: String(localized: "Every metal the brand names is the real thing, and it\u{2019}s safe on skin."), size: size)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("trueMetalBadgeButton")
                }
                ForEach(QualityLabelBadge.Label.all(for: p), id: \.self) { label in
                    let parts = label.title.components(separatedBy: " · ")
                    Button { labelStandard = label } label: {
                        BadgeSealMark(color: label.color, symbol: label.icon, name: parts[0],
                                      tier: parts.count > 1 ? parts[1] : nil, summary: label.summary, size: size)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(label.id)BadgeButton")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("badgeSeals")
        }
    }

    @ViewBuilder
    private func priceBlock(price: Double, compare: Double?, currency: String) -> some View {
        if let c = compare, c > price {
            let off = Int(((c - price) / c * 100).rounded())
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("-\(off)%").brandFont(.title.weight(.light)).foregroundStyle(Theme.deal)
                    PriceView(price, currency: currency, size: 30)
                }
                Text("List: \(Text(Money.leading(c, currency: currency)).strikethrough())").brandFont(.caption).foregroundStyle(Theme.secondary)
            }
        } else {
            PriceView(price, currency: currency, size: 30)
        }
    }
}

/// "Notify me when it's back" / "We'll notify you". The first tap is where
/// notification permission is asked for, never earlier. Signed out, it asks
/// the shopper to sign in instead: alerts belong to an account (owner, 2026-10-02).
private struct RestockButton: View {
    let productID: String
    let variantID: String?
    let option: String?
    @Environment(RestockStore.self) private var restock
    @Environment(AccountStore.self) private var account

    var body: some View {
        if account.signedIn || restock.stubSignedIn { watchButton } else { signInButton }
    }

    private var signInButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: Route.accountSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "bell")
                    Text("Sign in to get restock alerts")
                }
            }
            .buttonStyle(PillButtonStyle(color: Theme.gold, text: Theme.onGold))
            .accessibilityIdentifier("notifyRestockSignIn")
            Text("We'll email you, and notify this iPhone, when it's back.")
                .brandFont(.caption).foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private var watchButton: some View {
        let watching = restock.isWatching(productID, variantID: variantID)
        let key = RestockAlert(productID: productID, variantID: variantID).id
        Button {
            Task { await restock.toggle(productID, variantID: variantID) }
        } label: {
            HStack(spacing: 8) {
                if restock.busy.contains(key) { ProgressView().controlSize(.small) }
                else { Image(systemName: watching ? "bell.fill" : "bell") }
                Text(watching ? "We'll notify you" : "Notify me when it's back")
            }
        }
        .buttonStyle(PillButtonStyle(color: watching ? Theme.surface : Theme.gold, text: watching ? .primary : Theme.onGold))
        .disabled(restock.busy.contains(key))
        .accessibilityIdentifier("notifyRestock")
        .accessibilityHint(watching ? "Stops the alert" : "Emails you and sends a notification when this is back in stock")
        .alert("Restock alert", isPresented: Binding(get: { restock.message != nil }, set: { if !$0 { restock.message = nil } })) {
            if restock.message?.contains("Settings") == true {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(restock.message ?? "") }
        if watching {
            Text(Self.restockNote(push: restock.pushOn, option: option))
                .brandFont(.caption).foregroundStyle(Theme.secondary)
        }
    }
}

extension RestockButton {
    /// Whole sentences, so each language can order them its own way.
    static func restockNote(push: Bool, option: String?) -> String {
        switch (push, option) {
        case (true, let o?): String(localized: "We'll email you and send a notification when \(o) is back. Tap again to cancel.", comment: "Restock alert is on; the argument is a size or colour option")
        case (false, let o?): String(localized: "We'll email you when \(o) is back. Tap again to cancel.", comment: "Restock alert is on; the argument is a size or colour option")
        case (true, nil): String(localized: "We'll email you and send a notification when this is back. Tap again to cancel.", comment: "Restock alert is on")
        case (false, nil): String(localized: "We'll email you when this is back. Tap again to cancel.", comment: "Restock alert is on")
        }
    }
}

private struct ImagePager: View {
    let images: [String]
    var productID: String? = nil
    /// The gallery is presented by the product page, not from here: this view
    /// is rebuilt as the page scrolls, which took its own cover down with it.
    var openGallery: (Int) -> Void = { _ in }
    /// The photo to turn to: the picked colour's. Changes animate the pager.
    var show: Int? = nil
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(images.enumerated()), id: \.offset) { i, url in
                ZoomableImage(url: url, productID: productID)
                    .tag(i)
                    // A tap opens the whole set full screen, the way Amazon's
                    // product gallery does; pinching still zooms in place.
                    .onTapGesture { openGallery(i) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Theme.tile)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: show) { _, i in if let i { withAnimation { page = i } } }
        .accessibilityIdentifier("imagePager")
        .accessibilityValue("Photo \(page + 1) of \(images.count)")
    }
}

/// Every photo of the product, stacked and scrollable, opened from the pager.
/// One column rather than a carousel: people scroll a product's photos the way
/// they scroll everything else, and the detail shots are usually further down
/// the set than anyone swipes.
/// Which photo the gallery opens on.
private struct GalleryStart: Identifiable, Hashable {
    let index: Int
    var id: Int { index }
}

private struct ProductGallery: View {
    let images: [String]
    let startAt: Int
    var productID: String? = nil
    @Environment(\.dismiss) private var dismiss
    /// How far the gallery has been pulled down; a hard swipe sends it away
    /// and shows the product page behind it (owner, 2026-10-10).
    @State private var pull: CGFloat = 0
    @State private var leaving = false
    @State private var zoomed = false
    @State private var atTop = true
    /// Whether the drag in progress began with the column at its top. Decided
    /// once per drag: a swipe down from further along scrolls the column back
    /// up, and must not turn into a dismiss when it reaches the top mid-swipe
    /// (owner, 2026-10-11). Gesture state, so a cancelled drag resets it too,
    /// read at touch-down (minimumDistance 0): by a fast swipe's first move
    /// the column may already have scrolled back up to its top.
    @GestureState private var pullAllowed: Bool?

    private static let slop: CGFloat = 12
    private static let dismissDistance: CGFloat = 140
    private static let dismissFling: CGFloat = 420

    var body: some View {
        GeometryReader { screen in
            gallery
                .offset(y: pull)
                .simultaneousGesture(pullDown(height: screen.size.height))
        }
        .background(Theme.canvas.opacity(leaving ? 0 : 1 - min(pull / 600, 0.85)).ignoresSafeArea())
        .presentationBackground(.clear)
    }

    /// A downward drag that starts while the column is at its top (and no
    /// photo is zoomed) pulls the whole gallery; let go far or fast enough and it
    /// slides off the bottom, otherwise it springs back.
    private func pullDown(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pullAllowed) { _, allowed, _ in
                if allowed == nil { allowed = atTop && !zoomed }
            }
            .onChanged { value in
                // The first 12 pt are slop, so a tap or a sideways nudge
                // doesn't move the gallery.
                guard pullAllowed == true, !zoomed, value.translation.height > Self.slop,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                pull = value.translation.height - Self.slop
            }
            .onEnded { value in
                guard pull > 0 else { return }
                if pull > Self.dismissDistance || value.predictedEndTranslation.height > Self.dismissFling {
                    leaving = true
                    withAnimation(.easeIn(duration: 0.22)) { pull = height }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { dismiss() }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
                }
            }
    }

    private var gallery: some View {
        VStack(spacing: 0) {
            HStack {
                // The identifier sits on the title, not the container: an
                // identifier on a container hides its children's.
                Text("Product gallery").brandFont(.headline)
                    .accessibilityIdentifier("productGallery")
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .brandFont(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close gallery")
                .accessibilityIdentifier("closeGallery")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.header)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, url in
                            ZoomableImage(url: url, onZoomChange: { zoomed = $0 }, productID: productID)
                                .frame(height: 460)
                                .background(Theme.tile)
                                .id(i)
                        }
                    }
                    .padding(.vertical, 12)
                    // Where the column's top sits as it scrolls. (A preference
                    // from a background GeometryReader reported only once, so
                    // the gallery always thought it was at the top.)
                    // Opening scrolls photo 0 flush to the top, which hides
                    // the 12 pt padding above it: that still counts as the top.
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .scrollView).minY >= -13 } action: { atTop = $0 }
                }
                // While the gallery is being pulled down, the column holds still.
                .scrollDisabled(pull > 0)
                // Open on the photo they tapped, not back at the first one.
                .onAppear { proxy.scrollTo(startAt, anchor: .top) }
            }
        }
        .background(Theme.canvas.opacity(pull > 0 || leaving ? 0 : 1))
    }
}

/// A product photo you can pinch into where it sits — the fabric and the
/// stitching are the reason to buy, and sending people to a separate viewer
/// to see them is a detour. Pinch or double-tap to zoom, drag to move around
/// once zoomed, and it springs back when you let go at life size. The pan
/// gesture is only live while zoomed, so a swipe at 1× still pages the
/// gallery.
private struct ZoomableImage: View {
    let url: String
    /// Tells the gallery when this photo is zoomed, so a drag pans the photo
    /// instead of pulling the gallery down.
    var onZoomChange: (Bool) -> Void = { _ in }
    /// For gallery_zoom; nil leaves the zoom uncounted.
    var productID: String? = nil

    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    private static let maxScale: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            RemoteImage(url: url, width: 1000)
                .padding(8)
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(pinch(in: geo.size))
                .highPriorityGesture(pan(in: geo.size), including: scale > 1 ? .gesture : .none)
                // Double-tap zooms in on the spot tapped; a second double-tap
                // zooms back out (owner, 2026-10-10). A single tap still
                // belongs to whatever presents this.
                .onTapGesture(count: 2, coordinateSpace: .local) { point in
                    withAnimation(.easeOut(duration: 0.22)) {
                        if scale > 1 { reset() } else { zoomIn(at: point, in: geo.size) }
                    }
                }
                .onChange(of: scale > 1) { _, zoomed in
                    onZoomChange(zoomed)
                    if zoomed, let productID { Analytics.shared.galleryZoomed(product: productID, photo: url) }
                }
                .accessibilityIdentifier("productImage")
                .accessibilityValue("zoom \(Int((scale * 100).rounded()))")
        }
    }

    private func pinch(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(pinchStart * value.magnification, 0.8), Self.maxScale)
                offset = clamp(offset, in: size)
            }
            .onEnded { _ in
                if scale <= 1 { reset() } else { pinchStart = scale }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamp(CGSize(width: dragStart.width + value.translation.width,
                                      height: dragStart.height + value.translation.height), in: size)
            }
            .onEnded { _ in dragStart = offset }
    }

    private static let doubleTapScale: CGFloat = 2.5

    /// Zooms so the tapped point stays under the finger.
    private func zoomIn(at point: CGPoint, in size: CGSize) {
        scale = Self.doubleTapScale
        pinchStart = scale
        let fromCenter = CGSize(width: point.x - size.width / 2, height: point.y - size.height / 2)
        offset = clamp(CGSize(width: -fromCenter.width * (scale - 1), height: -fromCenter.height * (scale - 1)), in: size)
        dragStart = offset
    }

    private func reset() {
        scale = 1
        pinchStart = 1
        offset = .zero
        dragStart = .zero
    }

    /// Keeps the zoomed photo from being dragged off its frame.
    private func clamp(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let slackX = max(0, (size.width * scale - size.width) / 2)
        let slackY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(width: min(max(proposed.width, -slackX), slackX),
                      height: min(max(proposed.height, -slackY), slackY))
    }
}

private struct AddedToast: View {
    let goToCart: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.stock).brandFont(.title3)
            Text("Added to Cart").brandFont(.subheadline.bold())
            Spacer()
            Button("Go to Cart", action: goToCart)
                .brandFont(.subheadline.bold())
                .accessibilityIdentifier("goToCart")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(radius: 8, y: 2))
        .padding(12)
        .task {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}

/// "Track price" / "Tracking price": an email, and a push to this iPhone, when
/// the price drops 5% or more (web/server/deal-alerts.js). `compact` is the
/// symbol-only chip under a search result.
struct TrackPriceButton: View {
    let productID: String
    var compact = false
    var done: (ActionToastMessage) -> Void = { _ in }
    @Environment(AccountStore.self) private var account
    private var store: DealAlertStore { .shared }
    /// Only the button that was tapped shows the store's message: a search
    /// page has one of these per result, all watching the same store.
    @State private var asked = false

    var body: some View {
        let on = store.prices.contains(productID)
        Button {
            asked = true
            Task {
                await store.togglePrice(productID, account: account)
                guard store.message == nil else { return }
                done(store.prices.contains(productID) ? .init(text: String(localized: "Tracking the price", comment: "Toast after turning on price tracking"), symbol: "tag.fill")
                                                      : .init(text: String(localized: "Price tracking off", comment: "Toast after turning off price tracking"), symbol: "tag"))
            }
        } label: {
            let title = on ? String(localized: "Tracking price", comment: "Button state: price tracking is on") : (account.signedIn || store.stubbed ? String(localized: "Track price", comment: "Button: turn on price tracking") : String(localized: "Sign in to track", comment: "Button: price tracking needs an account"))
            if compact {
                IconChipLabel(title: title, symbol: on ? "tag.fill" : "tag", tint: .green, on: on, busy: store.busy.contains(productID))
            } else {
                ActionChipLabel(title: title, symbol: on ? "tag.fill" : "tag", tint: .green, on: on, busy: store.busy.contains(productID))
            }
        }
        .disabled(store.busy.contains(productID))
        .accessibilityIdentifier("trackPrice")
        .accessibilityHint(on ? "Stops price-drop alerts" : "Emails you and notifies this iPhone if the price drops")
        .alert("Price alerts", isPresented: Binding(get: { asked && store.message != nil }, set: { if !$0 { store.message = nil; asked = false } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.message ?? "") }
    }
}

/// The product page's way to the brand (owner, 2026-11-01, picked from
/// previews: "Store card"): the brand's photo, its name, "Visit the store ·
/// N items" and a chevron, in a full-width card. It was a grey line of text
/// that read like a caption. VoiceOver still hears "Visit the … Store".
private struct StoreCard: View {
    let brand: Brand
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        let products = Array(catalog.products(for: brand.id))
        HStack(spacing: 12) {
            Group {
                if let photo = BrandStoreView.heroPhoto(brand, products) {
                    Theme.tile.overlay { RemoteImage(url: photo, width: 200, contentMode: .fill) }
                } else {
                    BrandArtwork(brand: brand, size: 50)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(brand.name).brandFont(.headline).foregroundStyle(.primary).lineLimit(1)
                Text("Visit the store · \(products.count) items", comment: "Under the brand's name on a product page; the argument is how many products the brand has")
                    .brandFont(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").brandFont(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.field))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        // "Visit The Blackest Co Store", not "Visit the The Blackest Co Store".
        .accessibilityLabel(brand.name.hasPrefix("The ") ? "Visit \(brand.name) Store" : "Visit the \(brand.name) Store")
        .accessibilityValue("\(products.count) items")
        .accessibilityAddTraits(.isButton)
    }
}

