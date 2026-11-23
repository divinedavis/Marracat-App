import Foundation
import SwiftUI

/// What shoppers and brands have boosted (web/server/boosts.js; owner,
/// 2026-10-04): "Spotlight" boosts take up to three of the Home carousel's
/// premier pages, $20+ boosts fill "Boosted picks". Every boosted spot is
/// labeled Sponsored. Paying happens on marracat.com (Stripe), which the app
/// links out to; the Boost button shows only when the server says boosts are
/// open (to everyone once Stripe is live, to the owner while it's in test mode).
@MainActor
@Observable
final class BoostStore {
    static let shared = BoostStore()

    /// "product:<id>" / "brand:<id>", biggest first.
    private(set) var premier: [String] = []
    private(set) var picks: [String] = []
    private(set) var enabled = false
    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var seen = Set<String>()

    private var args: [String] { ProcessInfo.processInfo.arguments }
    /// UI tests get no network boosts; -BOOST_STUB gives them a fixed set.
    private var testing: Bool { args.contains("-UITEST_RESET") || args.contains("-OFFLINE_CATALOG") }

    func refresh(account: AccountStore, force: Bool = false) async {
        if force { lastFetch = nil }
        if args.contains("-BOOST_STUB") {
            premier = ["brand:" + (args.firstIndex(of: "-BOOST_STUB").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "")]
            picks = premier
            enabled = true
            return
        }
        guard !testing else { return }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 60 { return }
        lastFetch = .now
        struct Active: Decodable { let premier: [String]; let picks: [String] }
        struct Status: Decodable { let enabled: Bool }
        if let a: Active = await get("active", account: account) { premier = a.premier; picks = a.picks }
        if let s: Status = await get("status", account: account) { enabled = s.enabled }
    }

    /// Seen or tapped, at most once per spot per launch (the server keeps one
    /// a day per install).
    func record(_ target: String, tap: Bool = false) {
        guard !testing, tap || seen.insert(target).inserted else { return }
        var request = Self.request("events")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["events": [["target": target, "kind": tap ? "tap" : "view"]]])
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }

    /// A Stripe Checkout page for this boost, from the server (which checks
    /// the target and fixes the price), or nil.
    func checkoutURL(type: String, id: String, tier: Int, account: AccountStore) async -> URL? {
        var r = Self.request("checkout")
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["type": type, "id": id, "tier": tier])
        account.authorize(&r)
        struct Reply: Decodable { let url: URL }
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 201,
              let reply = try? JSONDecoder().decode(Reply.self, from: data),
              reply.url.host?.hasSuffix("stripe.com") == true else { return nil }
        return reply.url
    }

    /// The website page that opens the Boost choices for a product or brand.
    static func boostURL(product id: String) -> URL { URL(string: "https://marracat.com/#/product?id=\(id)&boost=1")! }
    static func boostURL(brand id: String) -> URL { URL(string: "https://marracat.com/#/shop?brand=\(id)&boost=1")! }

    private static func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://marracat.com/api/boosts/\(path)")!)
        r.timeoutInterval = 15
        r.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        return r
    }

    private func get<T: Decodable>(_ path: String, account: AccountStore) async -> T? {
        var r = Self.request(path)
        account.authorize(&r)
        guard let (data, response) = try? await URLSession.shared.data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// "Boost": opens the Boost screen (BoostSheet). Hidden unless the server
/// has boosts open for this shopper.
struct BoostLink: View {
    let target: BoostSheet.Target
    var compact = false
    /// The product page's chip look (ActionChips.swift).
    var chip = false
    @State private var open = false

    var body: some View {
        if BoostStore.shared.enabled && chip {
            Button { open = true } label: { ActionChipLabel(title: String(localized: "Boost", comment: "Button: pay to promote a brand"), symbol: "flame.fill", tint: .orange) }
                .accessibilityHint("Promote this on Marracat's Home")
                .accessibilityIdentifier("boostLink")
                .sheet(isPresented: $open) { BoostSheet(target: target) }
        } else if BoostStore.shared.enabled {
            Button { open = true } label: {
                Label("Boost", systemImage: "flame")
                    .brandFont(compact ? .footnote.bold() : .subheadline)
                    .foregroundStyle(compact ? Theme.onGold : Color.primary)
                    .padding(.horizontal, compact ? 12 : 0).padding(.vertical, compact ? 6 : 0)
                    .background { if compact { Capsule().fill(Theme.inverse) } }
            }
            .accessibilityHint("Promote this on Marracat's Home")
            .accessibilityIdentifier("boostLink")
            .sheet(isPresented: $open) { BoostSheet(target: target) }
        }
    }
}
