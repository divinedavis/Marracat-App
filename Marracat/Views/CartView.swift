import SwiftUI

/// The bag (owner, 2026-10-14, after ASOS's): what's in it grouped by brand,
/// one total up top with each brand's standard shipping, and a hovering
/// Checkout. No checkout button per brand: Checkout pays the brands one at a
/// time, each on its own store's checkout, where the delivery speed can be
/// changed; the continue card leads from one brand to the next.
struct CartView: View {
    @Environment(CatalogStore.self) private var catalog
    @Environment(CartStore.self) private var cart
    @Environment(ShopperStore.self) private var shopper
    @Environment(AppNav.self) private var nav
    @Environment(BuyerStore.self) private var buyer
    @Environment(AccountStore.self) private var account
    @State private var checkout: CheckoutRequest?
    /// The order just placed: a passing note when it was the last brand,
    /// the continue card when brands are still waiting.
    @State private var placed: PlacedOrder?
    @State private var run = CheckoutRun()
    /// The brand whose checkout is being built (the button shows a spinner).
    @State private var opening: String?
    /// Checkouts built over UCP, by brand: the order is followed by it.
    @State private var built: [String: String] = [:]
    @State private var failure: String?
    @State private var quotes = ShippingQuoteStore.shared

    private var zip: String? { quotes.zip(details: buyer.details) }

    var body: some View {
        ScrollView {
            Group { if cart.lines.isEmpty { empty } else { filled } }.readableWidth()
        }
        .background(Theme.canvas)
        // A cart link is built on the tap, so the order email (signed in or
        // not) is set up while the cart is open.
        .task(id: cart.lines.isEmpty) { if !cart.lines.isEmpty { await RelayStore.shared.ensureAddress() } }
        // Standard shipping from each brand's store, again when the bag or
        // the ZIP changes.
        .task(id: QuoteKey(lines: cart.lines.map { "\($0.id):\($0.quantity)" }, zip: zip)) {
            await quotes.refresh(cart.groups(catalog: catalog), zip: zip, details: buyer.details, catalog: catalog)
        }
        // Checkout runs inside the app (Shopify Checkout Kit). When the order
        // goes through, it's recorded and that brand's items leave the cart.
        .brandCheckout($checkout) { req, receipt in
            shopper.recordCheckout(brandID: req.brand.id, lines: req.lines,
                                   subtotal: receipt.subtotal ?? cart.subtotal(req.lines, catalog: catalog),
                                   orderID: receipt.orderID, total: receipt.total, currency: receipt.currency ?? req.brand.currencyCode,
                                   subtotalCurrency: receipt.subtotal == nil ? req.brand.currencyCode : (receipt.currency ?? req.brand.currencyCode), items: receipt.items)
            // Every Shopify order is followed to "Delivered" (owner,
            // 2026-10-13): by the checkout built here when there is one,
            // else by the order id alone.
            let builtID = built.removeValue(forKey: req.brand.id)
            if req.brand.isShopify, builtID != nil || receipt.orderID != nil {
                let orderID = receipt.orderID, items = PurchasedItem.titles(receipt.items, lines: req.lines, catalog: catalog)
                Task { await OrderTrackingStore.shared.register(brandID: req.brand.id, checkoutID: builtID, orderID: orderID, items: items) }
            }
            // The paid brand leaves the cart now, before the card shows.
            cart.remove(brand: req.brand.id, catalog: catalog)
            let order = run.placed(brand: req.brand.name, orderID: receipt.orderID, remaining: cart.groups(catalog: catalog).map(\.brand))
            withAnimation { placed = order }
        }
        .overlay(alignment: .bottom) {
            if let placed, let next = placed.next {
                ContinueCard(order: placed, busy: opening == next.brandID, onContinue: continueToNext, onLater: later)
            } else if let placed {
                Label(placed.title, systemImage: "checkmark.circle.fill")
                    .brandFont(.subheadline.bold())
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().stroke(Theme.hairline))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("orderPlaced")
                    // Keyed on the brand: paying a second brand within four
                    // seconds restarts the timer instead of letting the first
                    // brand's clear the second one's message.
                    .task(id: placed) {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        withAnimation { self.placed = nil }
                    }
            } else if !cart.lines.isEmpty {
                checkoutBar
            }
        }
        // The cart emptied some other way (swipes, another device): no brand
        // is waiting, so neither is the card.
        .onChange(of: cart.lines.isEmpty) { _, empty in
            if empty, placed?.next != nil { withAnimation { placed = nil }; run.reset() }
        }
        .alert("Checkout isn't available", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        // No top bar, as on Home and Browse (owner, 2026-10-21: "remove the
        // cart header too").
        .marracatChromeHidden()
    }

    private struct QuoteKey: Equatable { let lines: [String]; let zip: String? }

    // MARK: - Paying, one brand at a time

    /// The next brand in the bag, on its own store's checkout: built over
    /// UCP when its store can (followed to "Delivered"), else its cart link.
    /// No Marracat form first (owner, 2026-11-02): the store's checkout asks
    /// for what isn't saved, and the first order's address is saved for the
    /// next brand (BrandCheckout).
    private func payNext() async {
        guard opening == nil, let next = cart.groups(catalog: catalog).first else { return }
        let brand = next.brand, lines = next.lines
        if brand.ucpEndpoint != nil {
            opening = brand.id
            defer { opening = nil }
            let request = lines.map { UCPLineRequest.make($0, catalog: catalog) }
            if let c = await UCPClient.buildCheckout(brand: brand, lines: request, saved: buyer.details,
                                                     accountName: account.user?.name, accountEmail: account.user?.email),
               let url = c.continueURL {
                built[brand.id] = c.id
                checkout = CheckoutRequest(brand: brand, lines: lines, url: url)
                return
            }
        }
        await RelayStore.shared.ensureAddress()
        if let url = CartStore.checkoutURL(brand: brand, lines: lines, buyer: buyer.details) {
            checkout = CheckoutRequest(brand: brand, lines: lines, url: url)
        } else {
            failure = String(localized: "\(brand.name)'s checkout didn't open. Try again in a moment.", comment: "Bag error; the argument is a brand name")
        }
    }

    /// Continue: the next brand's checkout, as Checkout opens it.
    private func continueToNext() {
        guard !cart.lines.isEmpty else { withAnimation { placed = nil }; run.reset(); return }
        Task {
            await payNext()
            withAnimation { placed = nil }
        }
    }

    /// Later: the card goes, the unpaid brands stay in the cart.
    private func later() {
        withAnimation { placed = nil }
        run.reset()
    }

    // MARK: - Totals

    /// Subtotal, quoted standard shipping and the total, by currency. Only
    /// the total and the shipping show (owner, 2026-10-16: the subtotal row
    /// repeated the total, and the tax and "added at checkout" notes went).
    private struct Totals {
        var subtotal: [String: Double] = [:]
        var shipping: [String: Double] = [:]
        var loading = false
        var items = 0
        /// Brands whose shipping is only known at their own checkout.
        var atCheckout = 0
        var currencies: [String] { Set(subtotal.keys).union(shipping.keys).sorted() }
        func total(_ c: String) -> Double { (subtotal[c] ?? 0) + (shipping[c] ?? 0) }
    }

    private func totals(_ groups: [(brand: Brand, lines: [CartLine])]) -> Totals {
        var t = Totals()
        for (currency, amount) in cart.subtotalsByCurrency(cart.lines, catalog: catalog) { t.subtotal[currency] = amount }
        t.items = cart.lines.reduce(0) { $0 + $1.quantity }
        for g in groups {
            switch quotes.state(brand: g.brand, lines: g.lines, zip: zip) {
            case .quoted(let q): t.shipping[q.currency, default: 0] += q.amount
            case .loading: t.loading = true
            case .atCheckout: t.atCheckout += 1
            case nil: break
            }
        }
        return t
    }

    private func money(_ amounts: [String: Double]) -> String {
        amounts.keys.sorted().map { Money.string(amounts[$0]!, currency: $0) }.joined(separator: " + ")
    }

    /// The same amounts in words, for VoiceOver ("375 dollars").
    private func spoken(_ amounts: [String: Double]) -> String {
        amounts.keys.sorted().map { Money.spoken(amounts[$0]!, currency: $0) }.joined(separator: ", ")
    }

    /// The summary's shipping figure: "$13.00", "Free" when every quote is
    /// free, "Add a ZIP" before there's one, "—" while nothing is quoted yet.
    private func shippingText(_ t: Totals, brands: Int) -> String {
        if zip == nil, t.atCheckout < brands {
            return String(localized: "Add a ZIP", comment: "Bag: shipping can't be priced until a ZIP is given")
        }
        if t.shipping.isEmpty { return "—" }
        if t.shipping.values.allSatisfy({ $0 == 0 }) {
            return String(localized: "Free", comment: "Shipping price when it costs nothing")
        }
        return money(t.shipping)
    }

    private var filled: some View {
        let groups = cart.groups(catalog: catalog)
        return VStack(alignment: .leading, spacing: 12) {
            summary(groups)
            ForEach(groups, id: \.brand.id) { group in
                BrandCartSection(brand: group.brand, lines: group.lines,
                                 shipping: quotes.state(brand: group.brand, lines: group.lines, zip: zip))
            }
        }
        // Room under the last item for the hovering Checkout.
        .padding(.bottom, 96)
    }

    private func summary(_ groups: [(brand: Brand, lines: [CartLine])]) -> some View {
        let t = totals(groups)
        let total = Dictionary(uniqueKeysWithValues: t.currencies.map { ($0, t.total($0)) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(t.items) items: Total", comment: "Bag summary; the argument is the item count (plural variations in the catalog)")
                    .brandFont(.subheadline)
                Spacer()
                if t.loading { ProgressView().controlSize(.small) }
                Text(money(total)).brandFont(.title3.bold())
                    .accessibilityLabel(spoken(total))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cartTotal")
            HStack {
                Text("Standard shipping")
                Spacer()
                Text(shippingText(t, brands: groups.count))
                    .accessibilityLabel(t.shipping.isEmpty || t.shipping.values.allSatisfy { $0 == 0 }
                                        ? shippingText(t, brands: groups.count) : spoken(t.shipping))
            }
            .brandFont(.footnote).foregroundStyle(Theme.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cartShipping")
            zipRow
            Text(groups.count > 1
                 ? "Checkout pays one brand at a time on its own checkout, where you can pick faster delivery."
                 : "You can pick faster delivery at checkout.")
                .brandFont(.caption).foregroundStyle(Theme.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
    }

    /// Where shipping is priced to: the saved address (owner, 2026-10-16:
    /// the address itself, not just its ZIP), else a ZIP typed here. Never
    /// asked for in a pop-up (no prompts on entry).
    @ViewBuilder private var zipRow: some View {
        if let details = buyer.details, ShippingQuoteStore.isZIP(details.postalCode) {
            Text("Shipping to \(Self.address(details))", comment: "Bag: the address shipping is priced to")
                .brandFont(.caption).foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("cartShipTo")
        } else {
            @Bindable var quotes = quotes
            HStack(spacing: 8) {
                Text("Ship to ZIP").brandFont(.caption).foregroundStyle(Theme.secondary)
                TextField("ZIP", text: $quotes.typedZIP)
                    .keyboardType(.numberPad).textContentType(.postalCode)
                    .brandFont(.footnote)
                    .padding(.horizontal, 10).frame(width: 96, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .accessibilityIdentifier("cartZIP")
            }
        }
    }

    /// "12 Main St, Apt 4, Brooklyn, NY 11201": the parts that are filled in.
    static func address(_ d: BuyerDetails) -> String {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let place = [trim(d.region), trim(d.postalCode)].filter { !$0.isEmpty }.joined(separator: " ")
        return [trim(d.street), trim(d.extended), trim(d.city), place].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Checkout, hovering over the bag just above the tab bar: the total, and
    /// with several brands which one is paid first. The bottom padding is 12
    /// alone: `marracatChrome()` already insets the screen by the tab bar's
    /// height, and adding it again left the pill floating ~90 pt up, over the
    /// items (owner screenshot, 2026-10-15).
    private var checkoutBar: some View {
        let groups = cart.groups(catalog: catalog)
        let t = totals(groups)
        let total = t.currencies.count == 1 ? t.currencies.first.map { Money.string(t.total($0), currency: $0) } : nil
        return Button { Task { await payNext() } } label: {
            VStack(spacing: 2) {
                HStack(spacing: 8) {
                    if opening != nil { ProgressView().tint(Theme.onGold) }
                    Text(total.map { String(localized: "Checkout · \($0)", comment: "Bag button; the argument is the total") }
                         ?? String(localized: "Checkout", comment: "Bag button"))
                        .brandFont(.headline)
                }
                if groups.count > 1, let first = groups.first {
                    Text("\(first.brand.name) first, then \(groups.count - 1) more", comment: "Under the bag's Checkout: the first brand paid, then how many brands follow")
                        .brandFont(.caption)
                }
            }
        }
        .buttonStyle(PillButtonStyle(color: Theme.gold))
        .disabled(opening != nil)
        .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("cartCheckout")
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var empty: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                // The cart's own 3D picture (owner, 2026-11-26, of this empty state:
                // "Make sure this has an icon").
                ArtIcon(name: "cart", symbol: "cart", size: 64, tint: Theme.amber).brandFont(.system(size: 52))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Marracat Cart is empty").brandFont(.title3.bold())
                    Text("Good stuff goes in here").brandFont(.subheadline).foregroundStyle(Theme.secondary)
                    Button { nav.tab = .home } label: {
                        Text("Continue shopping").frame(minHeight: 44).contentShape(Rectangle())   // 44 pt target
                    }.brandFont(.subheadline)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)

            let recent = shopper.recentlyViewed.compactMap(catalog.product)
            if !recent.isEmpty {
                ProductRow(title: String(localized: "Keep shopping for", comment: "Product row title: recently viewed products"), products: Array(recent.prefix(12)))
            }
        }
        .padding(.vertical, 12)
    }
}

private struct BrandCartSection: View {
    let brand: Brand
    let lines: [CartLine]
    let shipping: ShippingQuoteStore.State?
    @Environment(CatalogStore.self) private var catalog
    @Environment(CartStore.self) private var cart

    var body: some View {
        let subtotal = cart.subtotal(lines, catalog: catalog)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                NavigationLink(value: Route.brand(brand.id)) {
                    Label(brand.name, systemImage: "storefront").brandFont(.headline).foregroundStyle(.primary)
                }
                Spacer()
                Text(Money.string(subtotal, currency: brand.currencyCode)).brandFont(.subheadline.bold())
                    .accessibilityLabel(Money.spoken(subtotal, currency: brand.currencyCode))
            }
            shippingLine
            if let origin = brand.shipsFromLabel {
                Label(origin, systemImage: "airplane").brandFont(.caption).foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("cartBrandShipsFrom")
            }
            ForEach(lines) { line in
                Divider()
                CartLineRow(line: line)
                    .swipeToRemove { withAnimation { cart.remove(line) } }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cartLine")
            }
        }
        .padding(12)
        .background(Theme.surface)
    }

    /// "Standard shipping $8.00 · Est. arrives Oct 17–20", "Free standard
    /// shipping", or "Shipping at checkout".
    @ViewBuilder private var shippingLine: some View {
        Group {
            switch shipping {
            case .quoted(let q):
                let price = q.isFree ? String(localized: "Free standard shipping", comment: "Bag: a brand's standard shipping costs nothing")
                    : String(localized: "Standard shipping \(Money.string(q.amount, currency: q.currency))", comment: "Bag: a brand's standard shipping; the argument is a price")
                Text([price, q.estimate].compactMap { $0 }.joined(separator: " · "))
            case .loading:
                Text("Getting shipping from \(brand.name)…", comment: "Bag; the argument is a brand name")
            case .atCheckout:
                Text("Shipping at checkout", comment: "Bag: the brand's store prices shipping only at its checkout")
            case nil:
                EmptyView()
            }
        }
        .brandFont(.caption).foregroundStyle(Theme.secondary)
        .accessibilityIdentifier("cartBrandShipping")
    }
}

private struct CartLineRow: View {
    let line: CartLine
    @Environment(CatalogStore.self) private var catalog
    @Environment(CartStore.self) private var cart
    @Environment(AppNav.self) private var nav
    @Environment(ProductDetailStore.self) private var details

    // Taps, not NavigationLinks: a link is a button, and a button still fires
    // when a finger slides across it, so swiping a row to remove it would
    // open the product instead. A tap gesture gives up once the finger moves.
    private func open(_ id: String) { nav.routers[nav.tab]?.path.append(.product(id)) }

    // Without the variant in the catalog, the product's own stock is what we
    // know; a sold-out variant of a product still listed shows at checkout on
    // the brand's store. A live answer from the product page
    // (ProductDetailStore) is newer than the catalog's, when there is one.
    private func isInStock(_ p: Product, _ v: Variant?) -> Bool {
        let live = details.liveStock(p.id)
        let liveOption = live?.variants?.first { $0.id == line.variantID }
        return liveOption?.available ?? (live?.variants == nil ? live?.available : nil) ?? v?.available ?? p.available
    }

    private func inStockText(_ p: Product, _ v: Variant?) -> String {
        isInStock(p, v) ? String(localized: "In Stock", comment: "Bag row: the item is available")
            : String(localized: "Currently unavailable", comment: "Bag row: the item is sold out")
    }

    var body: some View {
        if let p = catalog.product(line.productID) {
            // The catalog only carries variants for single-variant products;
            // a line remembers what was chosen and what it cost.
            let v = p.variants.first { $0.id == line.variantID }
            let option = line.option ?? (v.map { $0.isDefault ? "" : $0.title } ?? "")
            let unit = CartStore.unitPrice(line, catalog: catalog)
            HStack(alignment: .top, spacing: 12) {
                ProductImageWell(url: p.images.first, width: 240).frame(width: 100)
                    .contentShape(Rectangle())
                    .onTapGesture { open(p.id) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(p.title)
                VStack(alignment: .leading, spacing: 5) {
                    Text(p.title).brandFont(.subheadline).lineLimit(2)
                        .multilineTextAlignment(.leading).foregroundStyle(.primary)
                        .contentShape(Rectangle())
                        .onTapGesture { open(p.id) }
                        .accessibilityAddTraits(.isButton)
                    PriceView(unit, currency: line.currency ?? p.currencyCode, size: 18)
                    if !option.isEmpty {
                        Text(option).brandFont(.caption).foregroundStyle(Theme.secondary)
                    }
                    let inStock = isInStock(p, v)
                    Text(inStockText(p, v))
                        .brandFont(.caption)
                        .foregroundStyle(inStock ? Theme.stock : Theme.deal)
                    QuantityPill(quantity: line.quantity) { cart.setQuantity($0, for: line) }
                        .padding(.top, 4)
                }
            }
            .buttonStyle(.plain)
            // One VoiceOver element per item (the bag's accessibility audit,
            // 2026-10-14): the row's swipe gesture made every caption inside
            // it count as a too-small tap target, and the price read as
            // "$375.00". Opening and the quantity are actions on the row.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([p.title, option.isEmpty ? nil : option,
                                 Money.spoken(unit, currency: line.currency ?? p.currencyCode),
                                 inStockText(p, v), String(localized: "Quantity \(line.quantity)", comment: "Bag row, read by VoiceOver")]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(p.id) }
            .accessibilityAction(named: Text("Increase quantity")) { if line.quantity < 10 { cart.setQuantity(line.quantity + 1, for: line) } }
            .accessibilityAction(named: Text(line.quantity == 1 ? "Delete" : "Decrease quantity")) { cart.setQuantity(line.quantity - 1, for: line) }
        }
    }
}
