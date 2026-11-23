import SwiftUI
import WebKit

/// A WooCommerce brand's own checkout, opened from its shareable checkout link
/// with the cart already filled. Checkout Kit only runs Shopify stores, so this
/// is a plain web view: the brand's page, its payment methods, its order.
///
/// WooCommerce has no completion callback for an outside app. The one signal it
/// does give is the page every order lands on — `/checkout/order-received/<id>/
/// ?key=wc_order_…` — so reaching that counts as the order being placed. A store
/// that renames that page or pays off-site just won't be recorded; the order
/// itself is unaffected.
struct WooCheckoutSheet: View {
    let request: CheckoutRequest
    let onCompleted: (CheckoutReceipt) -> Void
    let onClose: () -> Void

    @State private var loading = true
    @State private var placed = false
    /// The page's host, always on show (audit 2026-10-07): a web view has no
    /// address bar, so the shopper couldn't tell whose page asks for a card.
    @State private var host: String?

    var body: some View {
        let steps = CartStore.cartSteps(brand: request.brand, lines: request.lines)
        NavigationStack {
            WooCheckoutWebView(steps: steps, url: request.url,
                               allowed: CheckoutNavigationPolicy(brand: request.brand, start: [request.url] + steps.compactMap(\.url)),
                               loading: $loading, host: $host) { orderID in
                guard !placed else { return }
                placed = true
                onCompleted(CheckoutReceipt(orderID: orderID))
            }
            .overlay { if loading { ProgressView() } }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").brandFont(.caption2)
                    Text(host ?? request.url.host() ?? "").brandFont(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Secure page on \(host ?? request.url.host() ?? "")")
                .accessibilityIdentifier("wooCheckoutHost")
            }
            .ignoresSafeArea(edges: .bottom)
            .barTitle(request.brand.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(placed ? "Done" : "Close", action: onClose)
                        .accessibilityIdentifier("wooCheckoutClose")
                }
            }
        }
        .accessibilityIdentifier("wooCheckoutSheet")
    }
}

private struct WooCheckoutWebView: UIViewRepresentable {
    /// Requests to make first, in order: an older WooCommerce store's
    /// add-to-cart links or a Big Cartel cart's form posts.
    let steps: [URLRequest]
    let url: URL
    let allowed: CheckoutNavigationPolicy
    @Binding var loading: Bool
    @Binding var host: String?
    let onOrderReceived: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Its own cookie jar, like a private tab: the brand's cart session
        // lives here and nowhere else.
        config.websiteDataStore = .nonPersistent()
        // Keep the store's page inside the sheet's width. Aqua Equity's
        // checkout had an element wider than the phone, and the page sat
        // scrolled sideways with the left edge of every field cut off.
        let fit = """
        var s = document.createElement('style');
        s.textContent = 'html, body { max-width: 100vw !important; overflow-x: hidden !important; }';
        document.documentElement.appendChild(s);
        """
        config.userContentController.addUserScript(
            WKUserScript(source: fit, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.scrollView.alwaysBounceHorizontal = false
        // The app is dark; the store's checkout is designed light. Inheriting
        // dark mode rendered its text fields as empty-looking dark boxes.
        view.overrideUserInterfaceStyle = .light
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        context.coordinator.pending = steps + [URLRequest(url: url)]
        context.coordinator.loadNext(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: WooCheckoutWebView
        /// What's left to load before the shopper sees checkout.
        var pending: [URLRequest] = []
        init(_ parent: WooCheckoutWebView) { self.parent = parent }

        func loadNext(_ view: WKWebView) {
            guard !pending.isEmpty else { return }
            view.load(pending.removeFirst())
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.host = webView.url?.host()
        }

        /// The sheet stays on the brand's own site and known payment
        /// providers; any other page opens in Safari, where the shopper sees
        /// its address. Frames inside a page (card fields, 3-D Secure) are
        /// left alone.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true else {
                decisionHandler(.allow); return
            }
            switch parent.allowed.decision(for: url) {
            case .allow: decisionHandler(.allow)
            case .openOutside:
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            case .block: decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !pending.isEmpty { loadNext(webView); return }   // still filling the cart
            parent.loading = false
            if let url = webView.url, let order = Self.orderReceived(url) { parent.onOrderReceived(order.id) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !pending.isEmpty { loadNext(webView); return }
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !pending.isEmpty { loadNext(webView); return }
            parent.loading = false
        }

        /// Payment pop-ups (PayPal and the like) open in this same view rather
        /// than vanishing, since a sheet has nowhere to put a second window.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// `/checkout/order-received/1234/?key=wc_order_…` → order 1234. The
        /// checkout page's own slug varies by store (2T Water's is
        /// `checkout-2`), so only the order-received part is matched.
        static func orderReceived(_ url: URL) -> (id: String?, key: String?)? {
            let parts = url.pathComponents
            guard let i = parts.firstIndex(of: "order-received") else { return nil }
            let id = parts.indices.contains(i + 1) ? parts[i + 1] : nil
            let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "key" }?.value
            return (id: id?.allSatisfy(\.isNumber) == true ? id : nil, key: key)
        }
    }
}

/// Where a brand's web checkout may go inside the app (audit 2026-10-07): the
/// brand's own domain (and the hosts the cart was filled on), plus payment
/// providers stores hand off to. Other https pages open in Safari; anything
/// that isn't http(s) or about: is blocked.
struct CheckoutNavigationPolicy {
    enum Decision: Equatable { case allow, openOutside, block }

    static let paymentProviders = [
        "paypal.com", "paypalobjects.com", "venmo.com", "stripe.com", "stripe.network", "link.com",
        "klarna.com", "klarnaservices.com", "afterpay.com", "clearpay.co.uk", "affirm.com", "sezzle.com", "zip.co",
        "shopify.com", "myshopify.com", "shop.app", "shopifycs.com", "apple.com", "pay.google.com",
        "squareup.com", "square.site", "bigcartel.com", "pay.amazon.com", "payments.amazon.com",
        "cardinalcommerce.com", "braintreegateway.com", "braintree-api.com", "authorize.net", "wepay.com",
    ]

    let hosts: [String]

    init(brand: Brand, start: [URL]) {
        hosts = ([brand.domain] + start.compactMap { $0.host() }).map(Self.bare)
    }

    static func bare(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// `host` is `domain` or a subdomain of it.
    static func within(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .block }
        if scheme == "about" || scheme == "blob" { return .allow }
        guard scheme == "https" || scheme == "http", let raw = url.host(), !raw.isEmpty else { return .block }
        let host = Self.bare(raw)
        if hosts.contains(where: { Self.within(host, $0) }) || Self.paymentProviders.contains(where: { Self.within(host, $0) }) {
            return scheme == "https" || hosts.contains(where: { Self.within(host, $0) }) ? .allow : .openOutside
        }
        return .openOutside
    }
}
