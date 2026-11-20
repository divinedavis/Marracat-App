import SwiftUI
import UIKit

// Your Orders and Order details, laid out after Amazon's (owner, 2026-09-30):
// a search field and filter, Buy again, then one row per item bought, each
// opening its order. Everything shows inside the app, from what Checkout Kit
// reported when the order was placed ("we dont need to go to the shopify site
// if we can get all order details in our app"). Marracat only knows the order
// was placed — the brand ships it — so statuses say "Ordered" and the tracker
// fills its first step only. Rows we have no data for are left out.

/// One item bought, as a Your Orders row shows it.
struct OrderItem: Identifiable {
    let id: String
    let record: CheckoutRecord
    let title: String
    let quantity: Int
    let product: Product?
    let line: OrderExtras.Line?

    /// The catalog's photo where it shows what was bought: it is full size,
    /// while Checkout Kit's line photo is a thumbnail that Order details
    /// stretched to the screen's width, pixelated (owner, 2026-11-11, build
    /// 183). The line photo stays for a colour the bundled catalog has no
    /// photo of, and for a product that has left the catalog.
    var image: String? {
        guard let p = product, let first = p.images.first else { return line?.image }
        guard let variant = line?.variantID.flatMap({ v in p.variants.first { $0.id == v } }),
              let index = variant.image else { return first }
        return p.images.indices.contains(index) ? p.images[index] : (line?.image ?? first)
    }
}

extension CheckoutRecord {
    var currencyCode: String { subtotalCurrency ?? currency ?? "USD" }
}

@MainActor
func orderItems(_ record: CheckoutRecord, catalog: CatalogStore, extras: OrderExtras?) -> [OrderItem] {
    let bought = record.productIDs.compactMap(catalog.product)
    func match(_ title: String) -> Product? {
        bought.first { $0.title == title } ?? catalog.products(for: record.brandID).first { $0.title == title }
            ?? (bought.count == 1 ? bought.first : nil)
    }
    if let lines = extras?.lines, !lines.isEmpty {
        return lines.enumerated().map { i, l in
            OrderItem(id: "\(record.id)#\(i)", record: record, title: l.title, quantity: l.quantity, product: match(l.title), line: l)
        }
    }
    if let items = record.items, !items.isEmpty {
        return items.enumerated().map { i, it in
            OrderItem(id: "\(record.id)#\(i)", record: record, title: it.title, quantity: it.quantity, product: match(it.title), line: nil)
        }
    }
    return bought.enumerated().map { i, p in
        OrderItem(id: "\(record.id)#\(i)", record: record, title: p.title, quantity: 1, product: p, line: nil)
    }
}

enum OrderRange: String, CaseIterable, Identifiable {
    case threeMonths = "Past three months"
    case sixMonths = "Past six months"
    case year = "Past year"
    case all = "All orders"
    var id: String { rawValue }
    /// rawValue is the stable id; this is the label in the range menu.
    var title: String {
        switch self {
        case .threeMonths: String(localized: "Past three months", comment: "Orders date range menu option")
        case .sixMonths: String(localized: "Past six months", comment: "Orders date range menu option")
        case .year: String(localized: "Past year", comment: "Orders date range menu option")
        case .all: String(localized: "All orders", comment: "Orders date range menu option")
        }
    }
    /// Shown when the range holds no orders.
    var emptyMessage: String {
        switch self {
        case .threeMonths: String(localized: "No orders in the past three months.", comment: "Orders list empty state for the chosen date range")
        case .sixMonths: String(localized: "No orders in the past six months.", comment: "Orders list empty state for the chosen date range")
        case .year: String(localized: "No orders in the past year.", comment: "Orders list empty state for the chosen date range")
        case .all: String(localized: "No orders in the all orders.", comment: "Orders list empty state when every order is shown (English wording kept as shipped)")
        }
    }
    func contains(_ date: Date, now: Date = .now) -> Bool {
        let cal = Calendar.current
        switch self {
        case .threeMonths: return date >= cal.date(byAdding: .month, value: -3, to: now)!
        case .sixMonths: return date >= cal.date(byAdding: .month, value: -6, to: now)!
        case .year: return date >= cal.date(byAdding: .year, value: -1, to: now)!
        case .all: return true
        }
    }
}

// MARK: - Your Orders

struct CheckoutsView: View {
    @Environment(ShopperStore.self) private var shopper
    @Environment(CatalogStore.self) private var catalog
    @State private var query = ""
    @State private var range: OrderRange = .threeMonths

    private var allItems: [OrderItem] {
        shopper.checkouts.flatMap { r in
            orderItems(r, catalog: catalog, extras: OrderExtrasStore.shared.extras(brandID: r.brandID, orderID: r.orderID))
        }
    }

    private var shown: [OrderItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Order numbers come from the brand's emails or status page; work
        // them out once per order, not once per item.
        var numbers: [UUID: [String]] = [:]
        if !q.isEmpty {
            for r in shopper.checkouts {
                let events = RelayStore.shared.events(for: r, brand: catalog.brand(r.brandID), allOrders: shopper.checkouts)
                    + OrderTrackingStore.shared.events(for: r)
                numbers[r.id] = events.compactMap(\.orderName) + [r.orderID.flatMap(OrderTrackingStore.number)].compactMap { $0 }
            }
        }
        return allItems.filter { item in
            range.contains(item.record.date) && (q.isEmpty
                || OrderSearch.matches(q, title: item.title, brand: catalog.brand(item.record.brandID)?.name ?? "",
                                       numbers: numbers[item.record.id] ?? [], date: item.record.date))
        }
    }

    private var buyAgain: [Product] {
        var seen = Set<String>()
        return allItems.compactMap(\.product).filter { $0.available && seen.insert($0.id).inserted }
    }

    private var moreFromBrands: [Product] {
        let bought = Set(allItems.compactMap(\.product?.id))
        var brands: [String] = []
        for r in shopper.checkouts where !brands.contains(r.brandID) { brands.append(r.brandID) }
        return brands.flatMap { catalog.products(for: $0).filter { $0.available && !bought.contains($0.id) }.prefix(2) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your Orders").font(.title2.bold()).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                filterBar
                Divider().overlay(Theme.hairline)

                if shopper.checkouts.isEmpty {
                    ContentUnavailableView("No orders yet", systemImage: "bag",
                                           description: Text("Orders you place in the app appear here. Purchases made on a brand's website aren't reported to Marracat."))
                        .padding(.top, 40)
                } else {
                    if query.isEmpty && (!buyAgain.isEmpty || !moreFromBrands.isEmpty) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                if !buyAgain.isEmpty { OrdersQuad(title: String(localized: "Buy again", comment: "Orders screen section of products bought before"), products: buyAgain) }
                                if !moreFromBrands.isEmpty { OrdersQuad(title: String(localized: "More from brands you've bought", comment: "Orders screen section of other products from brands already bought"), products: moreFromBrands) }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 14)
                        Divider().overlay(Theme.hairline)
                    }

                    Text("Purchase history").font(.title3.bold())
                        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

                    LazyVStack(spacing: 10) {
                        ForEach(shown) { item in
                            NavigationLink(value: Route.order(item.record.id.uuidString)) {
                                OrderItemRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("orderRow")
                        }
                    }
                    .padding(.horizontal, 16)

                    if shown.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(query.isEmpty ? range.emptyMessage : String(localized: "No orders match “\(query)”.", comment: "Orders search found nothing; the argument is what the shopper typed"))
                                .font(.subheadline).foregroundStyle(.secondary)
                            if range != .all {
                                Button("See all orders") { range = .all }.font(.subheadline.bold())
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    Text("Orders are placed on each brand's own store. Shipping updates and returns come from the brand.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(16)
                }
            }
            .frame(maxWidth: Widths.readable)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .onAppear {
            // Someone whose orders are all older than three months shouldn't land on an empty list.
            if range == .threeMonths, !shopper.checkouts.contains(where: { OrderRange.threeMonths.contains($0.date) }) { range = .all }
        }
        .navigationTitle("Your Orders")
        // The bar searches your orders here, not the store (owner, 2026-10-02);
        // it replaced the "Search all orders" field that sat under the title.
        .marracatChrome(localSearch: LocalSearch(text: $query, prompt: String(localized: "Search orders", comment: "Search field placeholder on the Orders screen"), identifier: "ordersSearch"))
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            Text(range.title).font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 12)
            Spacer()
            Menu {
                Picker("Orders placed in", selection: $range) {
                    ForEach(OrderRange.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Filter")
                    Image(systemName: "chevron.right").font(.caption.bold())
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
            }
            .accessibilityIdentifier("ordersFilter")
        }
    }
}

/// Amazon's "Buy again" card: a title over a 2×2 grid of photos.
private struct OrdersQuad: View {
    let title: String
    let products: [Product]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).lineLimit(2, reservesSpace: true)
            LazyVGrid(columns: [GridItem(.fixed(74), spacing: 6), GridItem(.fixed(74), spacing: 6)], spacing: 6) {
                ForEach(products.prefix(4)) { p in
                    NavigationLink(value: Route.product(p.id)) {
                        ProductImageWell(url: p.images.first, width: 200, padding: 4).frame(width: 74, height: 74)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.title)
                }
            }
        }
        .padding(12)
        .frame(width: 184, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .accessibilityIdentifier("ordersBuyAgain")
    }
}

private struct OrderItemRow: View {
    let item: OrderItem
    @Environment(CatalogStore.self) private var catalog
    @Environment(ShopperStore.self) private var shopper

    /// "Delivered October 3" once the brand's emails or the carrier say so.
    private var status: String {
        let events = RelayStore.shared.events(for: item.record, brand: catalog.brand(item.record.brandID), allOrders: shopper.checkouts)
            + OrderTrackingStore.shared.events(for: item.record)
        let step = RelayStore.step(events)
        let text = OrderDetailView.headline(step: step, events: events, placed: item.record.date)
        return step == 0 ? String(localized: "Ordered \(item.record.date.formatted(.dateTime.month(.wide).day()))", comment: "Order status; the argument is the order date") : text
    }

    var body: some View {
        HStack(spacing: 0) {
            ProductImageWell(url: item.image, width: 240, padding: 6)
                .frame(width: 84, height: 84)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10))
                .accessibilityLabel("Purchased item image")
                .accessibilityIdentifier("orderProductImage")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.quantity > 1 ? "\(item.title) (×\(item.quantity))" : item.title)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(status)
                    .font(.subheadline).foregroundStyle(Theme.stock)
                Text(catalog.brand(item.record.brandID)?.name ?? String(localized: "Brand", comment: "Fallback when a brand name is unknown"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Theme.textSecondary).padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .contentShape(Rectangle())
    }
}

// MARK: - Order details

struct OrderDetailView: View {
    let recordID: String
    @Environment(ShopperStore.self) private var shopper
    @Environment(CatalogStore.self) private var catalog
    @Environment(CartStore.self) private var cart
    @Environment(Router.self) private var router
    @Environment(AccountStore.self) private var account
    @State private var web: IdentifiedURL?
    @State private var added: String?
    @State private var pushAllowed = true
    @State private var receipt: OrderReceipt?
    @State private var scroll = OrderScroll()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var relay: RelayStore { RelayStore.shared }

    private var record: CheckoutRecord? { shopper.checkouts.first { $0.id.uuidString == recordID } }

    var body: some View {
        ScrollView {
            if let record {
                content(record)
                    .frame(maxWidth: Widths.readable)
                    .frame(maxWidth: .infinity)
                    // Where the page's top is: 0 at rest, below 0 once scrolled.
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { scroll.top(at: $0) }
            } else {
                ContentUnavailableView("Order not found", systemImage: "bag").padding(.top, 60)
            }
        }
        .background(Theme.canvas)
        // On the screen, not at the end of the scrolling content, so it shows
        // wherever the button was tapped.
        .overlay(alignment: .bottom) {
            if let added {
                Text(added).font(.subheadline.bold()).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.gold, in: Capsule())
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("orderAddedToast")
            }
        }
        // Buy it again, at the bottom above the tab bar. Like the Filters and
        // Sort pill (owner, 2026-11-14: "when i scroll down, the buy again
        // button should hide and when i scroll up it should show again"): it
        // steps aside on the way down, so it stops covering the rows being
        // read, and is back after a short scroll up or at the top. VoiceOver
        // keeps it, since a swipe through the page isn't a scroll to undo.
        .overlay(alignment: .bottom) {
            // The screen already ends above the tab bar: a small gap is all.
            if let record, scroll.buyAgainShown || voiceOver {
                buyAgainBar(record).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $web) { SafariView(url: $0.url).ignoresSafeArea() }
        .sheet(isPresented: Binding(get: { receipt != nil }, set: { if !$0 { receipt = nil } })) {
            if let receipt { ReceiptSheet(receipt: receipt).presentationDragIndicator(.visible).presentationBackground(Theme.surface) }
        }
        .task { pushAllowed = await RestockStore.shared.orderUpdatesAllowed; await relay.refresh(); await OrderTrackingStore.shared.refresh() }
        .navigationTitle("Order details")
        .marracatChrome()
    }

    @ViewBuilder
    private func content(_ record: CheckoutRecord) -> some View {
        let brand = catalog.brand(record.brandID)
        let extras = OrderExtrasStore.shared.extras(brandID: record.brandID, orderID: record.orderID)
        let items = orderItems(record, catalog: catalog, extras: extras)
        let brandName = brand?.name ?? String(localized: "the brand", comment: "Fallback used inside sentences when the brand name is unknown")
        // What the brand's emails said, through the Marracat order email.
        // …and what the brand's own status page says (OrderTrackingStore),
        // which works when Apple Pay gave the brand the wallet's email.
        let tracked = OrderTrackingStore.shared.tracked(for: record)
        let events = relay.events(for: record, brand: brand, allOrders: shopper.checkouts) + OrderTrackingStore.shared.events(for: record)
        let step = RelayStore.step(events)
        let orderName = events.compactMap(\.orderName).first
        let tracking = events.last { $0.trackingNumber != nil }
        let viaRelay = RelayStore.isRelay(extras?.email)
        let lead = items.first

        // "The product, big" (owner, 2026-11-10, picked from ten previews):
        // the thing you bought fills the top with where it is on it, a filled
        // bar, one row of actions, then the details in quiet lists, and Buy it
        // again kept at the bottom. Only the bar's own back button and title
        // (owner, 2026-10-26: no second back button or heading here).
        VStack(alignment: .leading, spacing: 0) {
            hero(lead, step: step, events: events, record: record)

            VStack(alignment: .leading, spacing: 4) {
                Text(items.count > 1
                     ? String(localized: "\(items.count) items from \(brandName)", comment: "Order details title for an order of several products; arguments: count, brand")
                     : lead?.title ?? brandName)
                    .font(.title2.bold()).lineLimit(2)
                Text(subtitle(lead, items: items, record: record, extras: extras, brandName: brandName))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                Text(viaRelay ? "Updates from \(brandName) show here and arrive in your inbox."
                     : tracked != nil ? "Updates from \(brandName)'s order page show here."
                     : extras?.email.map { "\(brandName) emails shipping updates to \($0)" } ?? "\(brandName) emails shipping updates.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityIdentifier("orderShippingNote")
            }
            .padding(.top, 14)

            OrderTracker(step: step).padding(.top, 14)

            if step < 3, let day = events.compactMap(\.estDelivery).last, let label = Self.arrivalLabel(day) {
                Label(label, systemImage: "calendar")
                    .font(.subheadline.bold())
                    .padding(.top, 10)
                    .accessibilityIdentifier("orderArrival")
            }
            if let tracking, let number = tracking.trackingNumber {
                Button { copy(number, String(localized: "Tracking number copied", comment: "Toast after copying")) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                        Text("\(Self.carrierName(tracking.carrier)) tracking \(number)").lineLimit(1).truncationMode(.middle)
                            .font(.caption.monospaced())
                        Spacer()
                        Text("Copy", comment: "Copies the tracking number").font(.caption.bold()).foregroundStyle(Theme.clean)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .accessibilityIdentifier("orderTracking")
            }
            // A delivery problem, explained here, open (owner, 2026-10-21):
            // what the carrier said, what it means, what to do.
            if step < 3, let problem = DeliveryProblem.of(tracked: tracked, events: events, brand: brandName) {
                DeliveryProblemPanel(problem: problem).padding(.top, 12)
            }

            // The actions: a round icon button with a short word under it
            // (owner, 2026-11-13, picked from ten previews: "i like this
            // one"; the outlined pills before it wrapped onto a second line).
            // They share the width equally, so all five fit before delivery;
            // fewer than three keep a third each instead of spreading out.
            // VoiceOver hears the full name. Buy it again is the bar at the bottom.
            let trackPage = tracked?.trackPage
            let onlyProduct = items.count == 1 ? lead?.product : nil
            let offersPush = (viaRelay || tracked != nil) && !pushAllowed && step < 3
            let shown = [trackPage != nil, onlyProduct != nil, brand != nil, step < 3, offersPush].filter { $0 }.count
            HStack(alignment: .top, spacing: 0) {
                // The brand's official tracking page, in the in-app browser.
                if let trackPage {
                    Button { web = IdentifiedURL(url: trackPage) } label: {
                        Label { Text("Track", comment: "Order details round button, one short word: opens the package's tracking page") } icon: { Image(systemName: "shippingbox") }
                    }
                    .buttonStyle(OrderAction())
                    .accessibilityLabel(Text("Track package"))
                    .accessibilityIdentifier("orderTrackPackage")
                }
                if let onlyProduct {
                    NavigationLink(value: Route.product(onlyProduct.id)) {
                        Label { Text("Product", comment: "Order details round button, one short word: opens the product that was bought") } icon: { Image(systemName: "tag") }
                    }
                    .buttonStyle(OrderAction())
                    .accessibilityLabel(Text("View product"))
                    .accessibilityIdentifier("orderViewProduct")
                }
                if let brand {
                    NavigationLink(value: Route.brand(brand.id)) {
                        Label { Text("Store", comment: "Order details round button, one short word: opens the brand's shop in the app") } icon: { Image(systemName: "storefront") }
                    }
                    .buttonStyle(OrderAction())
                    .accessibilityLabel(Text("View \(brand.name) store"))
                    .accessibilityIdentifier("orderViewStore")
                }
                // Before it arrives, Late shipment sits with the actions; once
                // delivered it moves under Help.
                if step < 3 { lateShipmentButton(record) }
                if offersPush {
                    Button {
                        Task {
                            pushAllowed = await RestockStore.shared.enableOrderUpdates()
                            if pushAllowed { await relay.linkDevice(RestockStore.installKey) }
                        }
                    } label: {
                        Label { Text("Notify me", comment: "Order details round button, short: turns on delivery notifications for this order") } icon: { Image(systemName: "bell") }
                    }
                    .buttonStyle(OrderAction())
                    .accessibilityLabel(Text("Get delivery notifications"))
                    .accessibilityIdentifier("orderEnableUpdates")
                }
                ForEach(0..<max(0, 3 - shown), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
            }
            .padding(.top, 16)
            lateShipmentNote(record).padding(.top, 8)

            // Several products: each with its own Buy it again and links.
            if items.count > 1 {
                section(String(localized: "In this order", comment: "Order details section listing the products"))
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(items) { item in itemBlock(item, record: record, brand: brand) }
                }
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            }

            section(String(localized: "Summary", comment: "Order details section: totals"))
            summary(record, extras: extras, orderName: orderName)

            section(String(localized: "Payment and delivery", comment: "Order details section"))
            VStack(spacing: 0) {
                if let payment = extras?.payment {
                    listRow { Label(payment, systemImage: "creditcard") } trailing: { EmptyView() }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("orderPayment")
                    rowDivider
                }
                // The receipt, printed in a sheet (ReceiptSheet; owner, 2026-10-23).
                Button { receipt = OrderReceipt(record: record, brand: brandName, extras: extras, items: items, orderName: orderName) } label: {
                    listRow { Label { Text("Receipt", comment: "Button on Order details: opens the order's receipt") } icon: { Image(systemName: "receipt") } }
                        trailing: { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Theme.textSecondary) }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("orderReceipt")
                if let ship = extras?.shipTo {
                    rowDivider
                    listRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ship to").foregroundStyle(Theme.textSecondary)
                            if let name = ship.name { Text(name) }
                            ForEach(ship.lines, id: \.self) { Text($0) }
                        }
                    } trailing: { EmptyView() }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("orderShipTo")
                }
                if let method = extras?.deliveryMethod, !method.isEmpty {
                    rowDivider
                    listRow { Text("Delivery").foregroundStyle(Theme.textSecondary) } trailing: { Text(method) }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("orderDelivery")
                }
                if let email = extras?.email {
                    rowDivider
                    Button { copy(email, String(localized: "Email copied", comment: "Toast after copying")) } label: {
                        listRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Email on this order").foregroundStyle(Theme.textSecondary)
                                Text(email).lineLimit(1).truncationMode(.middle)
                                if viaRelay {
                                    Text("\(brandName) knows you by this Marracat address. Give it to them if you contact them about this order.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } trailing: { Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("orderEmail")
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            section(String(localized: "Help", comment: "Order details section"))
            VStack(spacing: 0) {
                // Manage your order (owner, 2026-11-19, after Shop's own
                // button): cancelling, changing the address or starting a
                // return happen on the brand's order page, which signs the
                // shopper in by the order's email. A Marracat order email is
                // copied first, as that's the address to type there; the sign-in
                // code it sends is forwarded to the shopper's inbox.
                if let managePage = Self.managePage(tracked: tracked, brand: brand) {
                    Button {
                        if viaRelay, let email = extras?.email { UIPasteboard.general.string = email }
                        web = IdentifiedURL(url: managePage)
                    } label: {
                        listRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Manage your order", systemImage: "slider.horizontal.3")
                                Text(viaRelay
                                     ? "Cancel, change or return it at \(brandName). Sign in with your Marracat order email (we copy it for you); the code arrives in your inbox."
                                     : "Cancel, change or return it at \(brandName).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } trailing: { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("orderManage")
                    rowDivider
                }
                // Returns and shipping problems are the brand's to handle.
                if let brand {
                    Button { web = IdentifiedURL(url: brand.storeURL) } label: {
                        listRow { Label("Get help from \(brand.name)", systemImage: "questionmark.circle") }
                            trailing: { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.textSecondary) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("orderContactBrand")
                    rowDivider
                }
                if step >= 3 {
                    lateShipmentButton(record, asRow: true)
                    rowDivider
                }
                Button { copy(Self.detailsText(record: record, brandName: brandName, extras: extras, items: items, orderName: orderName, tracking: tracking), String(localized: "Order details copied", comment: "Toast after copying")) } label: {
                    listRow { Label("Copy order details", systemImage: "doc.on.doc") } trailing: { EmptyView() }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("orderCopyDetails")
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

            more(record, brand: brand, bought: Set(items.compactMap(\.product?.id)))
                .padding(.top, 14)
        }
        .padding(16)
        // Room for the Buy it again bar and the tab bar under it.
        .padding(.bottom, lead?.product != nil && items.count == 1 ? 76 : 0)
    }

    /// The product you bought, big, with where it is on it.
    private func hero(_ lead: OrderItem?, step: Int, events: [RelayEvent], record: CheckoutRecord) -> some View {
        Theme.tile
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .overlay {
                // Tapping the photo opens the product (owner, 2026-11-19), the
                // same page as the round Product button.
                if let product = lead?.product {
                    NavigationLink(value: Route.product(product.id)) {
                        Group {
                            if let image = lead?.image { RemoteImage(url: image, width: 900).padding(24) }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("View \(product.title)", comment: "Order details: the big product photo, which opens the product"))
                    .accessibilityIdentifier("orderHeroProduct")
                } else if let image = lead?.image {
                    RemoteImage(url: image, width: 900).padding(24).accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Label {
                    Text(Self.headline(step: step, events: events, placed: record.date))
                        .accessibilityIdentifier("orderStatus")
                } icon: {
                    Image(systemName: step >= 3 ? "checkmark.circle.fill" : step >= 1 ? "shippingbox.fill" : "bag.fill")
                }
                .font(.subheadline.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(step >= 3 ? Theme.delivered : Color.white, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func subtitle(_ lead: OrderItem?, items: [OrderItem], record: CheckoutRecord, extras: OrderExtras?, brandName: String) -> String {
        let code = extras?.currency ?? record.currencyCode
        if items.count > 1, let total = extras?.total ?? record.total {
            return String(localized: "Total \(total.formatted(.currency(code: code)))", comment: "Order details subtitle for several products")
        }
        var parts = [brandName, String(localized: "Qty \(lead?.quantity ?? 1)", comment: "Quantity on Order details")]
        if let price = lead?.line?.price { parts.append(price.formatted(.currency(code: lead?.line?.currency ?? code))) }
        return parts.joined(separator: " · ")
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 4).padding(.top, 24).padding(.bottom, 8)
    }

    private var rowDivider: some View { Divider().overlay(Theme.hairline).padding(.leading, 16) }

    private func listRow<L: View, T: View>(@ViewBuilder _ leading: () -> L, @ViewBuilder trailing: () -> T) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// Buy it again, by the thumb: the bar over the tab bar.
    @ViewBuilder
    private func buyAgainBar(_ record: CheckoutRecord) -> some View {
        let items = orderItems(record, catalog: catalog, extras: OrderExtrasStore.shared.extras(brandID: record.brandID, orderID: record.orderID))
        if items.count == 1, let item = items.first, let product = item.product {
            Button { buyAgain(item, product: product) } label: {
                Text(item.line?.price.map { "Buy it again · \($0.formatted(.currency(code: item.line?.currency ?? record.currencyCode)))" } ?? String(localized: "Buy it again", comment: "Order details button"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.black)
                    .background(Color.white, in: Capsule())
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("orderBuyAgain")
        }
    }

    /// Every order can be marked late; the dashboard counts which brands get
    /// it most (LateShipmentStore). Tapping again takes it back. A round
    /// button with the actions before delivery, a row under Help after.
    @ViewBuilder
    private func lateShipmentButton(_ record: CheckoutRecord, asRow: Bool = false) -> some View {
        let late = LateShipmentStore.shared.isReported(record)
        let label = Label(late ? "Late shipment reported" : (asRow ? "Report a late or missing package" : "Late shipment"),
                          systemImage: late ? "checkmark.circle.fill" : "clock.badge.exclamationmark")
        Group {
            if asRow {
                Button { Task { await LateShipmentStore.shared.toggle(record, account: account) } } label: {
                    listRow { label } trailing: { EmptyView() }
                }
                .buttonStyle(.plain)
            } else {
                Button { Task { await LateShipmentStore.shared.toggle(record, account: account) } } label: {
                    Label {
                        if late { Text("Reported", comment: "Order details round button, one word: this order was reported as late; tapping undoes it") }
                        else { Text("Late", comment: "Order details round button, one short word: report that the package is late") }
                    } icon: { Image(systemName: late ? "checkmark.circle.fill" : "clock.badge.exclamationmark") }
                }
                .buttonStyle(OrderAction())
                .accessibilityLabel(late ? Text("Late shipment reported") : Text("Late shipment"))
            }
        }
        .accessibilityIdentifier("orderLateShipment")
        .accessibilityValue(late ? "Reported" : "Not reported")
    }

    @ViewBuilder
    private func lateShipmentNote(_ record: CheckoutRecord) -> some View {
        if LateShipmentStore.shared.isReported(record) {
            Text("Thanks. This helps Marracat see which brands ship late. Tap again to undo.")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("orderLateShipmentNote")
        }
    }

    private func itemBlock(_ item: OrderItem, record: CheckoutRecord, brand: Brand?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProductImageWell(url: item.image, width: 240, padding: 4).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let brand {
                        HStack(spacing: 4) {
                            Text("Sold by:").foregroundStyle(.secondary)
                            NavigationLink(value: Route.brand(brand.id)) { Text(brand.name).foregroundStyle(Theme.clean) }
                                .buttonStyle(.plain)
                        }
                        .font(.caption)
                    }
                    if let option = item.line?.option ?? item.product.flatMap({ p in
                        item.line?.variantID.flatMap { id in p.variants.first { $0.id == id } }.flatMap { $0.isDefault ? nil : $0.title }
                    }) {
                        Text(option).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Qty: \(item.quantity)").font(.caption).foregroundStyle(.secondary)
                    if let price = item.line?.price {
                        Text(price.formatted(.currency(code: item.line?.currency ?? record.currencyCode))).font(.subheadline)
                    }
                }
            }
            ChipFlow(spacing: 8) {
                if let product = item.product {
                    Button { buyAgain(item, product: product) } label: { Text("Buy it again") }
                        .buttonStyle(OrderPill(primary: true))
                        .accessibilityIdentifier("orderBuyAgain")
                    NavigationLink(value: Route.product(product.id)) { Text("View product") }
                        .buttonStyle(OrderPill())
                        .accessibilityIdentifier("orderViewProduct")
                }
                if let brand {
                    NavigationLink(value: Route.brand(brand.id)) { Text("View \(brand.name) store") }
                        .buttonStyle(OrderPill(primary: item.product == nil))
                        .accessibilityIdentifier("orderViewStore")
                }
            }
        }
    }

    private func summary(_ record: CheckoutRecord, extras: OrderExtras?, orderName: String?) -> some View {
        let code = extras?.currency ?? record.currencyCode
        func money(_ v: Double) -> String { v.formatted(.currency(code: code)) }
        let subtotal = extras?.subtotal ?? record.subtotal
        let total = extras?.total ?? record.total
        return VStack(alignment: .leading, spacing: 6) {
            Text("Order placed \(record.date.formatted(date: .long, time: .omitted))").font(.subheadline)
            if let orderName {
                Text("Order \(orderName)").font(.subheadline).textSelection(.enabled).accessibilityIdentifier("orderName")
            }
            if let number = ShopifyIDs.number(record.orderID) {
                // Shopify's internal id, not the "#1042" in the brand's email.
                Text("Shopify order ID \(number)").font(orderName == nil ? .subheadline : .caption)
                    .foregroundStyle(orderName == nil ? Color.primary : Theme.textSecondary)
                    .textSelection(.enabled).accessibilityIdentifier("orderNumber")
            }
            VStack(spacing: 4) {
                summaryRow(String(localized: "Item(s) Subtotal:", comment: "Order summary row label"), money(subtotal))
                if let s = extras?.shipping { summaryRow(String(localized: "Shipping & Handling:", comment: "Order summary row label"), s == 0 ? String(localized: "Free", comment: "Shipping cost is zero") : money(s)) }
                if let d = extras?.discounts { summaryRow(String(localized: "Discounts:", comment: "Order summary row label"), "-" + money(d)) }
                if let t = extras?.taxes { summaryRow(String(localized: "Tax:", comment: "Order summary row label"), money(t)) }
                if let total { summaryRow(String(localized: "Grand Total:", comment: "Order summary row label"), money(total), bold: true) }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("orderSummary")
    }

    private func summaryRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
        }
        .font(bold ? .subheadline.bold() : .subheadline)
    }

    @ViewBuilder
    private func more(_ record: CheckoutRecord, brand: Brand?, bought: Set<String>) -> some View {
        let picks = catalog.products(for: record.brandID).filter { $0.available && !bought.contains($0.id) }.prefix(10)
        if let brand, !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("More from \(brand.name)").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(picks)) { p in ProductTile(product: p, imageSide: 140).frame(width: 140) }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    /// Where "Manage your order" goes: the brand's own page for this order
    /// (the link its emails carry), else a Shopify brand's account page,
    /// which lists the shopper's orders there once they sign in.
    static func managePage(tracked: TrackedOrder?, brand: Brand?) -> URL? {
        if let page = tracked?.statusPage { return page }
        guard let brand, brand.isShopify else { return nil }
        return brand.storeURL.appending(path: "account")
    }

    private func copy(_ text: String, _ toast: String) {
        UIPasteboard.general.string = text
        withAnimation { added = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { added = nil } }
    }

    /// "Arriving today", "Arriving tomorrow", "Arriving Thursday, Oct 9".
    static func arrivalLabel(_ day: String, now: Date = .now) -> String? {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: day) else { return nil }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "Arriving today", comment: "Delivery estimate") }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return String(localized: "Arriving tomorrow", comment: "Delivery estimate") }
        if date < cal.startOfDay(for: now) { return nil }
        let when = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return String(localized: "Arriving \(when)", comment: "Delivery estimate; the argument is a date like Thursday, Oct 16")
    }

    static func headline(step: Int, events: [RelayEvent], placed: Date) -> String {
        let kinds = ["", "shipped", "out_for_delivery", "delivered"]
        let when = events.last { $0.kind == kinds[min(step, 3)] || $0.trackingStep == kinds[min(step, 3)] }?.date ?? placed
        let day = when.formatted(.dateTime.weekday(.wide).month(.wide).day())
        switch step {
        case 3: return String(localized: "Delivered \(day)", comment: "Order status; the argument is a date like Friday, October 3")
        case 2: return String(localized: "Out for delivery", comment: "Order status")
        case 1: return String(localized: "Shipped \(day)", comment: "Order status; the argument is a date like Friday, October 3")
        default: return String(localized: "Ordered \(placed.formatted(.dateTime.weekday(.wide).month(.wide).day()))", comment: "Order status; the argument is the order date")
        }
    }

    static func carrierName(_ c: String?) -> String {
        switch c { case "USPS"?: "USPS"; case "UPS"?: "UPS"; case "FedEx"?: "FedEx"; case "DHLExpress"?: "DHL"; case "OnTrac"?: "OnTrac"; default: String(localized: "Carrier", comment: "Fallback when the shipping company is unknown") }
    }

    /// Everything a brand needs to find the order, ready to paste. Stays in
    /// English on purpose: it is pasted to the brand, not read in the app.
    static func detailsText(record: CheckoutRecord, brandName: String, extras: OrderExtras?, items: [OrderItem], orderName: String?, tracking: RelayEvent?) -> String {
        var lines = ["\(brandName) order"]
        if let orderName { lines.append("Order \(orderName)") }
        lines.append("Placed \(record.date.formatted(date: .long, time: .shortened))")
        if let email = extras?.email { lines.append("Email on the order: \(email)") }
        if let ship = extras?.shipTo { lines.append("Ship to: " + ([ship.name].compactMap { $0 } + ship.lines).joined(separator: ", ")) }
        for item in items { lines.append("\(item.quantity) × \(item.title)" + (item.line?.option.map { " (\($0))" } ?? "")) }
        let code = extras?.currency ?? record.currencyCode
        if let total = extras?.total ?? record.total { lines.append("Total: " + total.formatted(.currency(code: code))) }
        if let number = tracking?.trackingNumber { lines.append("\(carrierName(tracking?.carrier)) tracking: \(number)") }
        if let id = ShopifyIDs.number(record.orderID) { lines.append("Shopify order ID: \(id)") }
        return lines.joined(separator: "\n")
    }

    private func buyAgain(_ item: OrderItem, product: Product) {
        let variant = item.line?.variantID.flatMap { id in product.variants.first { $0.id == id } }
            ?? (product.variants.count == 1 ? product.variants.first : nil)
        guard let variant, variant.available || product.available else {
            // Options we can't tell apart: pick them on the product page.
            router.path.append(Route.product(product.id))
            return
        }
        cart.add(productID: product.id, variantID: variant.id, quantity: 1,
                 option: variant.isDefault ? nil : variant.title, unitPrice: variant.price, currency: product.currencyCode)
        withAnimation { added = String(localized: "Added to cart", comment: "Toast after adding a product to the cart") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation { added = nil } }
    }
}

/// Ordered → Shipped → Out for delivery → Delivered. Steps past Ordered fill
/// only when the brand's emails (through the Marracat order email) or the
/// carrier say so; otherwise they stay open.
private struct OrderTracker: View {
    var step = 0
    private let steps = [String(localized: "Ordered", comment: "Order tracker step"),
                         String(localized: "Shipped", comment: "Order tracker step"),
                         String(localized: "Out for\ndelivery", comment: "Order tracker step, on two lines under a narrow dot"),
                         String(localized: "Delivered", comment: "Order tracker step")]
    private static let spoken = [String(localized: "Ordered", comment: "Order tracker step"),
                                 String(localized: "Shipped", comment: "Order tracker step"),
                                 String(localized: "Out for delivery", comment: "Order status"),
                                 String(localized: "Delivered", comment: "Order tracker step")]

    var body: some View {
        // Four segments that fill as the order moves (owner, 2026-11-10:
        // the old dots stayed grey even on a delivered order).
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Theme.delivered : Theme.field)
                        .frame(height: 5)
                }
            }
            HStack(alignment: .top) {
                ForEach(steps.indices, id: \.self) { i in
                    Text(steps[i])
                        .font(.caption2)
                        .foregroundStyle(i == step ? (step >= 3 ? Theme.delivered : Color.primary) : i < step ? Color.primary : Theme.textSecondary)
                        .fontWeight(i == step ? .semibold : .regular)
                        .multilineTextAlignment(i == 0 ? .leading : i == steps.count - 1 ? .trailing : .center)
                        .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : i == steps.count - 1 ? .trailing : .center)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step == 0 ? String(localized: "Ordered. Shipping updates come from the brand.", comment: "VoiceOver: order tracker before shipping") : Self.spoken[min(step, 3)])
        .accessibilityValue("\(step)")
        .accessibilityIdentifier("orderTracker")
    }
}

/// Amazon's rounded action buttons: a filled primary, outlined others.
/// Order details' scroll, kept out of the screen's own state (as BrandScroll
/// is): only the Buy it again bar redraws, and only when it comes or goes.
@Observable @MainActor
private final class OrderScroll {
    /// The Buy it again bar is up above the tab bar.
    private(set) var buyAgainShown = true
    @ObservationIgnored private var quick = QuickReturn()

    /// `y`: where the page's top is (below 0: scrolled).
    func top(at y: CGFloat) {
        quick.update(offset: -y)
        if quick.shown != buyAgainShown { withAnimation(.snappy(duration: 0.25)) { buyAgainShown = quick.shown } }
    }
}

/// Order details' actions: the icon in a circle, a short word under it, each
/// taking an equal share of the row (see the call site for the owner's pick).
private struct OrderAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(Circled())
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }

    private struct Circled: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 7) {
                configuration.icon
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 56, height: 56)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 1))
                configuration.title
                    .font(.caption.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Color.primary)
        }
    }
}

/// The pills on each product of a several-product order.
private struct OrderPill: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(primary ? Color.black : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(primary ? Theme.gold : Theme.surface))
            .overlay(Capsule().stroke(primary ? Color.clear : Theme.amber, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Your Orders' search (owner, 2026-10-20): by product, brand, order number
/// ("#1417" or "1417") or date ("Oct 3", "October", "10/3", "2026"). Every
/// word typed has to appear in one of them.
enum OrderSearch {
    static func matches(_ query: String, title: String, brand: String, numbers: [String], date: Date,
                        calendar: Calendar = .current, locale: Locale = .current) -> Bool {
        let typed = SearchWords.fold(query).split(separator: " ").map { $0.replacingOccurrences(of: "#", with: "") }.filter { !$0.isEmpty }
        guard !typed.isEmpty else { return true }
        let dates = ["MMMM d yyyy", "MMM d", "M/d/yyyy", "M/d", "yyyy-MM-dd"].map { fmt -> String in
            let f = DateFormatter(); f.calendar = calendar; f.locale = locale; f.timeZone = calendar.timeZone
            f.dateFormat = fmt
            return f.string(from: date)
        }
        let haystack = SearchWords.fold(([title, brand] + numbers.map { $0.replacingOccurrences(of: "#", with: "") } + dates).joined(separator: " "))
        return typed.allSatisfy { haystack.contains($0) }
    }
}

/// A carrier-reported problem with an order, in words a shopper can act on.
struct DeliveryProblem: Equatable {
    enum Kind: Equatable { case failed, returning, stopped }
    let kind: Kind
    let carrierSaid: String?
    let carrier: String?
    let brand: String

    /// EasyPost's words for a problem (relay.js stepForTrackerStatus).
    static func kind(_ status: String?) -> Kind? {
        switch status {
        case "failure": .failed
        case "return_to_sender": .returning
        case "cancelled", "error": .stopped
        default: nil
        }
    }

    /// The order's problem, if its latest tracking is one: the tracked
    /// order's own status first, else the order email's latest tracking.
    static func of(tracked: TrackedOrder?, events: [RelayEvent], brand: String) -> DeliveryProblem? {
        if let t = tracked, let k = kind(t.trackingStatus) {
            return DeliveryProblem(kind: k, carrierSaid: t.trackingDetail, carrier: t.carrier, brand: brand)
        }
        if let e = events.last(where: { $0.trackingStatus != nil }), let k = kind(e.trackingStatus) {
            return DeliveryProblem(kind: k, carrierSaid: e.trackingDetail, carrier: e.carrier, brand: brand)
        }
        return nil
    }

    var title: String {
        switch kind {
        case .failed: String(localized: "The carrier couldn't deliver it", comment: "Delivery problem title")
        case .returning: String(localized: "It's on its way back to \(brand)", comment: "Delivery problem title; the argument is a brand name")
        case .stopped: String(localized: "The carrier stopped tracking it", comment: "Delivery problem title")
        }
    }

    var meaning: String {
        switch kind {
        case .failed: String(localized: "The delivery didn't happen. Carriers usually try again the next business day or hold the package for pickup.", comment: "Delivery problem explanation")
        case .returning: String(localized: "The carrier is sending the package back to the brand, often after failed delivery attempts or an address problem.", comment: "Delivery problem explanation")
        case .stopped: String(localized: "The carrier's tracking ended without a delivery. The package may still be moving, or it may be lost.", comment: "Delivery problem explanation")
        }
    }

    var whatToDo: String {
        switch kind {
        case .failed: String(localized: "Open Track package below for the carrier's next step, like redelivery or pickup. If nothing moves in a day or two, contact \(brand): the order is theirs to fix.", comment: "Delivery problem advice; the argument is a brand name")
        case .returning: String(localized: "Contact \(brand) about a refund or a new shipment. Returns and shipping problems are the brand's to handle.", comment: "Delivery problem advice; the argument is a brand name")
        case .stopped: String(localized: "Check Track package below. If it hasn't moved, contact \(brand) about where your order is.", comment: "Delivery problem advice; the argument is a brand name")
        }
    }
}

/// The problem, explained and open: the carrier's own words, what they mean,
/// what to do.
struct DeliveryProblemPanel: View {
    let problem: DeliveryProblem
    @State private var open = true

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                if let said = problem.carrierSaid {
                    Text("\(OrderDetailView.carrierName(problem.carrier)) said: “\(said)”",
                         comment: "Delivery problem: the carrier's own message; the arguments are the carrier and its words")
                        .font(.subheadline.italic())
                        .accessibilityIdentifier("deliveryProblemCarrier")
                }
                Text(problem.meaning).font(.subheadline)
                Text(problem.whatToDo).font(.subheadline.weight(.semibold))
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(problem.title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(Theme.deal)
                // On the heading, not the group: a group's id hides what's inside.
                .accessibilityIdentifier("deliveryProblem")
        }
        .tint(.primary)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.deal.opacity(0.12)))
    }
}
