import ShopifyCheckoutSheetKit
import StoreKit
import SwiftUI

/// One brand's checkout: its Shopify cart permalink (or WooCommerce checkout
/// link) and the cart lines in it.
struct CheckoutRequest: Identifiable {
    let id = UUID()
    let brand: Brand
    let lines: [CartLine]
    let url: URL
}

/// Presents a brand's Shopify checkout inside the app with Checkout Kit — a
/// native sheet running the store's own checkout, with Apple Pay / Shop Pay.
/// Our cart permalinks are valid checkout URLs for it (per the Checkout Kit
/// README), so brands need no setup.
///
/// If Checkout Kit can't load a store but reports the error as recoverable,
/// the same URL opens in Safari so the buyer is never stuck; otherwise the
/// buyer gets a plain explanation and a way to the brand's site.
struct CheckoutReceipt {
    var orderID: String? = nil
    var total: Double? = nil
    var currency: String? = nil
    var subtotal: Double? = nil
    var items: [PurchasedItem]? = nil
}

struct BrandCheckout: ViewModifier {
    @Environment(CatalogStore.self) private var catalog
    @Environment(BuyerStore.self) private var buyer
    @Environment(AccountStore.self) private var account
    @Binding var request: CheckoutRequest?
    let onCompleted: (CheckoutRequest, CheckoutReceipt) -> Void

    @State private var fallback: CheckoutRequest?
    @State private var failed: CheckoutRequest?
    @State private var failureMessage = ""
    /// Set when an order completes and the rating prompt is due; the prompt
    /// waits until the checkout sheet has closed (ReviewPrompt).
    @State private var askForReview = false
    @Environment(\.requestReview) private var requestReview

    /// UI tests pass -CHECKOUT_STUB: the flow runs end to end without opening
    /// real checkout sessions on brands' stores.
    private static let stub = ProcessInfo.processInfo.arguments.contains("-CHECKOUT_STUB")

    /// The checkout open now, for checkout_start / _complete / _abandon.
    @State private var open: (req: CheckoutRequest, done: Bool)?
    /// How far a Shopify checkout got, from Checkout Kit's standard pixel
    /// events, and the shipping it quoted (owner, 2026-11-08: "lets find which
    /// step" carts were left at). Sent with checkout_abandon / _complete.
    @State private var reached: CheckoutStep?
    @State private var shippingQuoted: Double?

    /// The furthest of Checkout Kit's standard events; `opened` until the
    /// store's page reports loading.
    enum CheckoutStep: Int, Comparable {
        case opened, started, contact, address, shipping, payment
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var id: String { ["opened", "started", "contact", "address", "shipping", "payment"][rawValue] }
        init?(pixel name: String) {
            switch name {
            case "checkout_started": self = .started
            case "checkout_contact_info_submitted": self = .contact
            case "checkout_address_info_submitted": self = .address
            case "checkout_shipping_info_submitted": self = .shipping
            case "payment_info_submitted": self = .payment
            default: return nil
            }
        }
    }

    private func stepProps(_ req: CheckoutRequest) -> [String: Analytics.Value] {
        var props = checkoutProps(req)
        guard req.brand.isShopify, !Self.stub else { return props }
        props["step"] = .string((reached ?? .opened).id)
        if let shippingQuoted { props["shipping"] = .int(Int(shippingQuoted.rounded(.down))) }
        return props
    }

    private func noted(_ event: PixelEvent) {
        guard case .standardEvent(let e) = event, let name = e.name, let step = CheckoutStep(pixel: name) else { return }
        let shipping = e.data?.checkout?.shippingLine?.price?.amount
        DispatchQueue.main.async {
            if step > (reached ?? .opened) { reached = step }
            if let shipping { shippingQuoted = shipping }
        }
    }

    /// How the brand's checkout is reached, for Analytics ("via", EVENTS.md).
    static func via(_ brand: Brand) -> String {
        if brand.checksOutByUCP { return "ucp" }
        if brand.checksOutBySwell { return "swell" }
        if brand.checksOutByBigCartel { return "bigcartel" }
        if brand.isShopify { return "cart" }
        return "brand_site"
    }

    private func checkoutProps(_ req: CheckoutRequest) -> [String: Analytics.Value] {
        let subtotal = req.lines.reduce(0.0) { sum, line in
            sum + (line.unitPrice ?? catalog.product(line.productID)?.price ?? 0) * Double(line.quantity)
        }
        return ["brand": .string(req.brand.id), "via": .string(Self.via(req.brand)),
                "item_count": .int(req.lines.reduce(0) { $0 + $1.quantity }),
                "subtotal": .int(Analytics.subtotalBucket(subtotal))]
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $request, onDismiss: {
                if let o = open, !o.done { Analytics.shared.track("checkout_abandon", stepProps(o.req)) }
                open = nil
                reached = nil
                shippingQuoted = nil
                reviewAfterPurchase()
            }) { req in sheet(for: req) }
            .onChange(of: request?.id) { _, id in
                guard id != nil, let req = request, open?.req.id != req.id else { return }
                open = (req, false)
                reached = nil
                shippingQuoted = nil
                Analytics.shared.track("checkout_start", checkoutProps(req))
            }
            .sheet(item: $fallback) { req in SafariView(url: req.url).ignoresSafeArea() }
            .alert("Checkout isn't available",
                   isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                if let req = failed {
                    Button("Open \(req.brand.domain)") { fallback = req; failed = nil }
                }
                Button("OK", role: .cancel) { failed = nil }
            } message: {
                Text(failureMessage)
            }
    }

    /// The address the store's checkout shipped to becomes the saved one when
    /// none was saved, so the next brand's checkout opens filled in
    /// (BuyerDetails.filling(shippedTo:)).
    private func remember(shippedTo address: OrderAddress?, email: String?, phone: String?) {
        let base = (buyer.details ?? BuyerDetails()).filling(name: account.user?.name, email: account.user?.email)
        let next = base.filling(shippedTo: address, orderEmail: email, orderPhone: phone)
        if next != buyer.details, next.hasAddress { buyer.save(next) }
    }

    /// Every completed order passes through here on its way to the caller.
    private func completed(_ req: CheckoutRequest, _ receipt: CheckoutReceipt) {
        if ReviewPrompt.shouldAsk() { askForReview = true }
        open = (req, true)
        Analytics.shared.track("checkout_complete", stepProps(req))
        onCompleted(req, receipt)
    }

    /// The first purchase on this phone asks for a rating once the checkout
    /// is out of the way, not on top of the brand's own confirmation.
    private func reviewAfterPurchase() {
        guard askForReview else { return }
        askForReview = false
        ReviewPrompt.markAsked()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { requestReview() }
    }

    @ViewBuilder
    private func sheet(for req: CheckoutRequest) -> some View {
        if Self.stub {
            VStack(spacing: 16) {
                // The id sits on the title, not the VStack: an identifier on a
                // container overrides its children's, which hid the button's.
                Text("Checkout · \(req.brand.name)").brandFont(.headline)
                    .accessibilityIdentifier("checkoutSheet")
                // What a brand's checkout would open filled in with: the cart
                // link's shipping fields read back out of the URL (so UI tests
                // see them survive encoding), or the UCP checkout built for it.
                if let filled = Self.prefillSummary(req.url) {
                    Text(filled).brandFont(.footnote).multilineTextAlignment(.center)
                        .accessibilityIdentifier("checkoutPrefill")
                }
                Button("Simulate order placed") {
                    // A made-up order number and price breakdown, so UI tests
                    // reach the order details the way a real order does.
                    let orderID = "gid://shopify/OrderIdentity/\(Int64.random(in: 1_000_000_000...9_999_999_999))"
                    let lines = req.lines.map { line in
                        OrderExtras.Line(title: catalog.product(line.productID)?.title ?? String(localized: "Item", comment: "Fallback name for an ordered item"), quantity: line.quantity,
                                         price: (line.unitPrice ?? catalog.product(line.productID)?.price).map { $0 * Double(line.quantity) },
                                         currency: line.currency ?? req.brand.currencyCode, variantID: line.variantID,
                                         option: line.option, image: catalog.product(line.productID)?.images.first)
                    }
                    let subtotal = lines.compactMap(\.price).reduce(0, +)
                    OrderExtrasStore.shared.save(OrderExtras(lines: lines, subtotal: subtotal, shipping: 0, taxes: 0, total: subtotal,
                                                             currency: req.brand.currencyCode, deliveryMethod: "Standard shipping",
                                                             payment: "Apple Pay",
                                                             email: RelayStore.shared.enabled ? RelayStore.shared.address : nil),
                                                 brandID: req.brand.id, orderID: orderID)
                    // With -RELAY_STUB, the brand's emails "arrive": a
                    // confirmation naming the order, then a shipment.
                    RelayStore.shared.stubOrderEmails(brand: req.brand)
                    // The store's checkout "shipped" to the address it was
                    // given, else to a stand-in, as a real one asks for it.
                    let given = buyer.details
                    remember(shippedTo: OrderAddress(firstName: "Test", lastName: "Buyer", address1: given?.street.nilIfBlank ?? "1 Main St",
                                                     city: given?.city.nilIfBlank ?? "Brooklyn", zoneCode: given?.region.nilIfBlank ?? "NY",
                                                     postalCode: given?.postalCode.nilIfBlank ?? "11201", countryCode: "US", phone: "7185550100"),
                             email: nil, phone: nil)
                    completed(req, CheckoutReceipt(orderID: orderID, total: subtotal, currency: req.brand.currencyCode,
                                                     subtotal: subtotal, items: req.lines.compactMap { line in
                        catalog.product(line.productID).map { PurchasedItem(title: $0.title, quantity: line.quantity) }
                    }))
                    request = nil
                }
                .buttonStyle(PillButtonStyle(color: Theme.gold))
                .accessibilityIdentifier("stubCompleteOrder")
            }
            .padding(24)
        } else if !req.brand.isShopify {
            WooCheckoutSheet(request: req, onCompleted: { completed(req, $0) }, onClose: { request = nil })
        } else {
            CheckoutSheet(checkout: req.url)
                .title(req.brand.name)
                .colorScheme(.web)   // each brand's own checkout branding
                .onCancel { request = nil }
                .onPixelEvent { noted($0) }
                // Checkout Kit shows its own confirmation; the buyer closes it.
                .onComplete { event in
                    let order = event.orderDetails
                    let to = order.deliveries?.compactMap(\.details.location).first
                    remember(shippedTo: to.map { OrderAddress(firstName: $0.firstName, lastName: $0.lastName, name: $0.name,
                                                              address1: $0.address1, address2: $0.address2, city: $0.city,
                                                              zoneCode: $0.zoneCode, postalCode: $0.postalCode,
                                                              countryCode: $0.countryCode, phone: $0.phone) },
                             email: order.email, phone: order.phone)
                    if !order.id.isEmpty { OrderExtrasStore.shared.save(Self.extras(order, cartLines: req.lines), brandID: req.brand.id, orderID: order.id) }
                    completed(req, CheckoutReceipt(orderID: order.id.isEmpty ? nil : order.id,
                        total: order.cart.price.total?.amount, currency: order.cart.price.total?.currencyCode,
                        subtotal: order.cart.price.subtotal?.amount,
                        items: order.cart.lines.isEmpty ? nil : order.cart.lines.map { PurchasedItem(title: $0.title, quantity: $0.quantity) }))
                }
                .onFail { error in
                    request = nil
                    if error.isRecoverable {
                        // Let the failed sheet finish dismissing before presenting Safari.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { fallback = req }
                    } else {
                        failureMessage = message(for: error, brand: req.brand)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { failed = req }
                    }
                }
                .onLinkClick { url in UIApplication.shared.open(url) }
                .ignoresSafeArea()
        }
    }

    /// "Ships to Zoë O'Brien, 12 Main St, Apt 4B, Brooklyn NY 11201, +1 718…"
    /// from a cart link's checkout[shipping_address] fields; "Filled in by the
    /// store" for a UCP checkout (the stub's continue_url); nil otherwise.
    static func prefillSummary(_ url: URL) -> String? {
        if url.absoluteString.contains("#/stub-checkout/") { return String(localized: "Filled in by the store", comment: "Checkout summary when the store fills in the details") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func field(_ k: String) -> String? { items.first { $0.name == "checkout[shipping_address][\(k)]" }?.value }
        guard field("address1") != nil else { return nil }
        let name = [field("first_name"), field("last_name")].compactMap { $0 }.joined(separator: " ")
        let place = [field("city"), field("province"), field("zip")].compactMap { $0 }.joined(separator: " ")
        let address = [name, field("address1"), field("address2"), place, field("phone")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let ships = String(localized: "Ships to \(address)", comment: "Checkout summary; the argument is a postal address")
        // The Marracat order email, when the link carries it.
        guard let email = items.first(where: { $0.name == "checkout[email]" })?.value, RelayStore.isRelay(email) else { return ships }
        return String(localized: "\(ships) · order email \(email)", comment: "Checkout summary; the first argument is Ships to (address), the second the Marracat order email address")
    }

    /// The order's details from Checkout Kit, kept on this phone only. The
    /// basket supplies each line's chosen option, which the event doesn't carry.
    static func extras(_ order: CheckoutCompletedEvent.OrderDetails, cartLines: [CartLine]) -> OrderExtras {
        let price = order.cart.price
        let ship = order.deliveries?.first
        let place = ship?.details.location ?? nil
        let discounts = (price.discounts ?? []).compactMap { $0.amount?.amount }.reduce(0) { $0 + abs($1) }
        return OrderExtras(
            lines: order.cart.lines.map { l in
                let variant = ShopifyIDs.variant(l.merchandiseId)
                return OrderExtras.Line(title: l.title, quantity: l.quantity, price: l.price.amount, currency: l.price.currencyCode,
                                        variantID: variant, option: cartLines.first { $0.variantID == variant }?.option,
                                        image: l.image?.lg)  // the largest; Order details shows it full width
            },
            subtotal: price.subtotal?.amount, shipping: price.shipping?.amount, discounts: discounts > 0 ? discounts : nil,
            taxes: price.taxes?.amount, total: price.total?.amount,
            currency: price.total?.currencyCode ?? price.subtotal?.currencyCode,
            shipTo: place.flatMap { a in
                OrderExtras.summarize(address: (a.name, a.firstName, a.lastName, a.address1, a.address2,
                                                a.city, a.zoneCode, a.postalCode, a.countryCode))
            },
            deliveryMethod: ship.map { d in [d.method, d.details.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") },
            payment: order.paymentMethods?.first.map { OrderExtras.paymentLabel(type: $0.type, details: $0.details) },
            email: order.email)
    }

    private func message(for error: CheckoutError, brand: Brand) -> String {
        switch error {
        case .checkoutExpired:
            return String(localized: "This cart expired at \(brand.name). Tap checkout again to start a fresh one.", comment: "Checkout error; the argument is a brand name or its web domain")
        case .configurationError, .checkoutUnavailable:
            return String(localized: "\(brand.name)'s checkout can't open inside Marracat right now. You can still check out on \(brand.domain).", comment: "Checkout error; the argument is a brand name or its web domain")
        default:
            return String(localized: "Something went wrong opening \(brand.name)'s checkout. Please try again.", comment: "Checkout error; the argument is a brand name or its web domain")
        }
    }
}

extension View {
    func brandCheckout(_ request: Binding<CheckoutRequest?>,
                       onCompleted: @escaping (CheckoutRequest, CheckoutReceipt) -> Void) -> some View {
        modifier(BrandCheckout(request: request, onCompleted: onCompleted))
    }
}
