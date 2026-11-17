import SwiftUI

/// Sponsored products from verified brands (web/server/sponsored.js; owner,
/// 2026-10-06). The server picks them and decides whether a tap is charged;
/// the app shows them labeled "Sponsored" and reports taps.
@MainActor
enum SponsoredStore {
    /// `impression`: the server's signed id for this showing; a tap is
    /// charged only when it comes back with one (audit 2026-10-07).
    struct Item: Decodable, Hashable { let brandID: String; let productID: String; var impression: String? = nil }
    private struct Reply: Decodable { let items: [Item] }
    private static var testing: Bool { ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") }
    /// UI tests: -SPONSORED_STUB <productID> stands in for the server.
    private static var stub: String? {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "-SPONSORED_STUB").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
    }
    static weak var account: AccountStore?

    static func items(_ placement: String, q: String = "", category: String = "", product: String = "", catalog: CatalogStore) async -> [Item] {
        if let id = stub, let p = catalog.product(id) { return [Item(brandID: p.brand, productID: id)] }
        guard !testing else { return [] }
        var c = URLComponents(string: "https://marracat.com/api/ads/serve")!
        c.queryItems = [.init(name: "placement", value: placement), .init(name: "q", value: q),
                        .init(name: "category", value: category), .init(name: "product", value: product)]
        guard let url = c.url, let (data, response) = try? await URLSession.shared.data(for: request(url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return [] }
        return reply.items.filter { catalog.product($0.productID)?.available == true }
    }

    static func tap(_ item: Item, placement: String) {
        guard !testing, stub == nil else { return }
        var r = request(URL(string: "https://marracat.com/api/ads/tap")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["brandID": item.brandID, "productID": item.productID, "placement": placement]
        if let impression = item.impression { body["impression"] = impression }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task.detached { _ = try? await URLSession.shared.data(for: r) }
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        r.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        account?.authorize(&r)
        return r
    }
}

/// The small "Sponsored" tag on a sponsored product.
struct SponsoredTag: View {
    var body: some View {
        Text("Sponsored")
            .font(.caption2.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.72)))
            .foregroundStyle(.white)
            .accessibilityIdentifier("sponsoredTag")
    }
}

/// "Sponsored products": a row of sponsored tiles, each tagged.
struct SponsoredProductRow: View {
    let items: [SponsoredStore.Item]
    let placement: String
    @Environment(CatalogStore.self) private var catalog

    var body: some View {
        let shown = items.compactMap { it in catalog.product(it.productID).map { (it, $0) } }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sponsored products").font(.title3.bold()).padding(.horizontal, 12)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(shown, id: \.0) { it, p in
                            ProductTile(product: p, imageSide: ProductRow.tileWidth)
                                .frame(width: ProductRow.tileWidth)
                                .overlay(alignment: .topLeading) { SponsoredTag().padding(6) }
                                .simultaneousGesture(TapGesture().onEnded { SponsoredStore.tap(it, placement: placement) })
                        }
                    }
                    .modifier(TileRowHeight(products: shown.map(\.1), width: ProductRow.tileWidth))
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 14)
            .background(Theme.surface)
            .accessibilityIdentifier("sponsoredRow")
        }
    }
}
