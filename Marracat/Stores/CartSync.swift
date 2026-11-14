import Foundation

/// The cart follows the account between the app and marracat.com
/// (web/server/cart-sync.js; owner, 2026-10-05: "our cart online should carry
/// over to the app"). On sign-in, launch and coming back to the app, the
/// account's cart is read: with nothing unsent on this phone it replaces the
/// cart here; with unsent changes the two merge (larger quantity wins) and
/// the result is sent. A change made here is sent a moment later.
@MainActor
enum CartSync {
    struct Line: Codable {
        let productID: String
        let variantID: String
        let quantity: Int
        var option: String?
        var unitPrice: Double?
        var currency: String?
    }
    private struct Reply: Decodable { let lines: [Line]; let updated: Double }
    private static var pushTask: Task<Void, Never>?
    private static var testing: Bool { ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") }

    static func toServer(_ lines: [CartLine]) -> [Line] {
        lines.map { Line(productID: $0.productID, variantID: String($0.variantID), quantity: min($0.quantity, 99),
                         option: $0.option, unitPrice: $0.unitPrice, currency: $0.currency) }
    }
    static func fromServer(_ lines: [Line]) -> [CartLine] {
        lines.compactMap { l in
            Int64(l.variantID).map { CartLine(productID: l.productID, variantID: $0, quantity: min(l.quantity, 10),
                                              option: l.option, unitPrice: l.unitPrice, currency: l.currency) }
        }
    }

    static func pull(account: AccountStore, cart: CartStore) async {
        guard !testing, account.signedIn,
              let (status, data) = try? await call(account: account), status == 200,
              let remote = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        let theirs = fromServer(remote.lines)
        if cart.syncState.dirty {
            cart.applyRemote(CartStore.merge(theirs, cart.lines))
            await push(account: account, cart: cart)
        } else if remote.updated == 0 {
            // The account has no cart yet: this one becomes it.
            if !cart.lines.isEmpty { await push(account: account, cart: cart) }
        } else if remote.updated != cart.syncState.updated {
            cart.applyRemote(theirs)
            cart.syncState = .init(updated: remote.updated, dirty: false)
        }
    }

    /// Sends this phone's cart shortly after a change.
    static func schedulePush(account: AccountStore, cart: CartStore) {
        guard !testing, account.signedIn else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await push(account: account, cart: cart)
        }
    }

    static func push(account: AccountStore, cart: CartStore) async {
        guard let body = try? JSONEncoder().encode(["lines": toServer(cart.lines)]),
              let (status, data) = try? await call(account: account, method: "PUT", body: body), status == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        cart.syncState = .init(updated: reply.updated, dirty: false)
    }

    private static func call(account: AccountStore, method: String = "GET", body: Data? = nil) async throws -> (Int, Data) {
        var r = URLRequest(url: URL(string: "https://marracat.com/api/cart")!)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        account.authorize(&r)
        let (data, response) = try await URLSession.shared.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
