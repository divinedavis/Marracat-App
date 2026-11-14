import Foundation
import AuthenticationServices
import Observation
import GoogleSignIn
import Security
import UIKit

struct AccountUser: Codable {
    let id: String; let name: String?; let email: String?; let generation: String
    /// One account can be opened by Apple and by Google with the same email
    /// (web/server/identities.js, 2026-10-02). `id` is the account; these say
    /// which sign-in this phone used ("apple:<sub>") and which one confirms a
    /// deletion ("apple" whenever an Apple sign-in is on the account, so its
    /// access is revoked). Sessions saved before then have neither.
    var signedInWith: String? = nil
    var confirmWith: String? = nil
    var storageID: String { id + ":" + generation }
    /// This phone signed in with Apple: its credential state is checked, and
    /// signing in again uses Apple.
    var usesApple: Bool { (signedInWith ?? id).hasPrefix("apple:") }
    var appleUserID: String? { usesApple ? String((signedInWith ?? id).dropFirst("apple:".count)) : nil }
    var providerName: String { usesApple ? "Apple" : "Google" }
    var deletesWithApple: Bool { confirmWith.map { $0 == "apple" } ?? id.hasPrefix("apple:") }
    var deletionProviderName: String { deletesWithApple ? "Apple" : "Google" }
}
private struct AccountReply: Decodable {
    var token: String?; var user: AccountUser?; let profile: ShopperProfile
    /// Sent by the server when this sign-in made the account (optional).
    var created: Bool? = nil
}
private enum AccountError: LocalizedError {
    case unauthorized, unavailable, keychain
    var errorDescription: String? {
        switch self {
        case .unauthorized: return String(localized: "Please sign in again to sync your account.", comment: "Account sync error")
        case .unavailable: return String(localized: "We couldn't reach your account. Your changes are saved on this device. Try again.", comment: "Account sync error")
        case .keychain: return String(localized: "Your sign-in could not be saved securely. Please try again.", comment: "Account sync error")
        }
    }
}

@MainActor @Observable
final class AccountStore {
    private(set) var user: AccountUser?
    private(set) var busy = false
    private(set) var syncing = false
    var message: String?
    private(set) var lastSynced: Date?
    var needsAuthentication: Bool { token == nil }
    @ObservationIgnored private var token: String?
    @ObservationIgnored private weak var shopper: ShopperStore?
    @ObservationIgnored private weak var cart: CartStore?
    @ObservationIgnored private weak var buyer: BuyerStore?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var appleAuthorization: AppleAuthorization?
    /// Runs while still signed in, just before signing out, so the social
    /// layer can retire this phone's sharing key with the server.
    @ObservationIgnored var willSignOut: (() async -> Void)?
    private let defaults: UserDefaults
    private let session = URLSession(configuration: .ephemeral)

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func attach(_ shopper: ShopperStore, cart: CartStore, buyer: BuyerStore? = nil) async {
        guard self.shopper == nil else { return }
        self.shopper = shopper; self.cart = cart; self.buyer = buyer
        RestockStore.shared.account = self
        SponsoredStore.account = self
        shopper.onChange = { [weak self] in Task { @MainActor in self?.scheduleSync() } }
        cart.onChange = { [weak self, weak cart] in
            Task { @MainActor in if let self, let cart { CartSync.schedulePush(account: self, cart: cart) } }
        }
        if !ProcessInfo.processInfo.arguments.contains("-UITEST_RESET"),
           let data = SecureSession.read(), let saved = try? JSONDecoder().decode(SavedSession.self, from: data) {
            token = saved.token; user = saved.user; shopper.activate(saved.user.storageID); cart.activate(saved.user.storageID); buyer?.activate(saved.user.storageID)
            await foreground()
            await RestockStore.shared.refresh()
        }
    }
    private struct SavedSession: Codable { let token: String; let user: AccountUser }
    private struct TokenBody: Encodable { let idToken: String }
    private struct ActivityBody: Encodable { let operations: [ActivityChange] }

    private func googleToken() async throws -> String {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { throw AccountError.unavailable }
        while let presented = presenter.presentedViewController { presenter = presented }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        let refreshed = try await result.user.refreshTokensIfNeeded()
        guard let idToken = refreshed.idToken?.tokenString else { throw AccountError.unauthorized }
        return idToken
    }
    func signIn(importGuest: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        Analytics.shared.track("sign_in_start", ["provider": .string("google")])
        var step = SignInStep.provider
        do {
            let idToken = try await googleToken()
            step = .exchange
            let data = try await request("auth/google", method: "POST", body: JSONEncoder().encode(TokenBody(idToken: idToken)), authenticated: false)
            try await acceptSignIn(data, importGuest: importGuest, provider: "google")
        } catch {
            let cancelled = step == .provider && (error as NSError).code == GIDSignInError.canceled.rawValue
            Self.trackStop(provider: "google", step: step, error: error, cancelled: cancelled)
            if !cancelled { message = String(localized: "Google sign-in didn't finish. Please try again.", comment: "Sign-in error") }
        }
    }
    private func acceptSignIn(_ data: Data, importGuest: Bool, provider: String) async throws {
        let reply = try JSONDecoder().decode(AccountReply.self, from: data)
        guard let token = reply.token, let user = reply.user else { throw AccountError.unavailable }
        Analytics.shared.track("sign_in_complete", ["provider": .string(provider)])
        // A brand-new account: the server says so, or it comes back with no history at all.
        let p = reply.profile
        if reply.created ?? (p.saved.isEmpty && p.recentlyViewed.isEmpty && p.recentSearches.isEmpty && p.checkouts.isEmpty && p.lists.isEmpty) {
            Analytics.shared.track("sign_up_complete", ["provider": .string(provider)])
        }
        try SecureSession.save(JSONEncoder().encode(SavedSession(token: token, user: user)))
        generation = UUID(); self.token = token; self.user = user
        let guestCart = importGuest ? (cart?.lines ?? []) : []
        shopper?.activate(user.storageID); cart?.activate(user.storageID); buyer?.activate(user.storageID); shopper?.accept(reply.profile)
        if importGuest { shopper?.importGuestActivity() }
        // The guest cart joins the account's (marked unsent, so the pull
        // below merges it with the one on the server).
        cart?.mergeIn(guestCart)
        await sync()
        if let cart { await CartSync.pull(account: self, cart: cart) }
        await RestockStore.shared.refresh()
    }
    private func appleToken(challenged: () -> Void = {}) async throws -> AppleTokenBody {
        let data = try await request("auth/apple/challenge", method: "POST", authenticated: false)
        let challenge = try JSONDecoder().decode(AppleChallenge.self, from: data)
        challenged()
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) else { throw AccountError.unavailable }
        let authorization = AppleAuthorization(challenge: challenge, window: window)
        appleAuthorization = authorization
        defer { appleAuthorization = nil }
        return try await authorization.signIn()
    }
    func signInWithApple(importGuest: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        Analytics.shared.track("sign_in_start", ["provider": .string("apple")])
        var step = SignInStep.challenge
        do {
            let body = try await appleToken { step = .provider }
            step = .exchange
            let data = try await request("auth/apple", method: "POST", body: JSONEncoder().encode(body), authenticated: false)
            try await acceptSignIn(data, importGuest: importGuest, provider: "apple")
        } catch {
            let cancelled = step == .provider && (error as? ASAuthorizationError)?.code == .canceled
            Self.trackStop(provider: "apple", step: step, error: error, cancelled: cancelled)
            if !cancelled { message = String(localized: "Apple sign-in didn't finish. Please try again.", comment: "Sign-in error") }
        }
    }
    /// Where a sign-in stopped (owner, 2026-11-08: 6 started, 2 finished;
    /// "lets find which step"): our server's Apple challenge, the provider's
    /// own sheet, or our exchange of its token for a session.
    enum SignInStep: String { case challenge, provider, exchange }

    /// sign_in_cancel when the shopper closed the provider's sheet, else
    /// sign_in_fail with why: no connection, our server, or anything else.
    static func stopEvent(step: SignInStep, error: Error, cancelled: Bool) -> (name: String, reason: String?) {
        if cancelled { return ("sign_in_cancel", nil) }
        if error is URLError { return ("sign_in_fail", "network") }
        return ("sign_in_fail", step == .provider ? "error" : "server")
    }

    private static func trackStop(provider: String, step: SignInStep, error: Error, cancelled: Bool) {
        let (name, reason) = stopEvent(step: step, error: error, cancelled: cancelled)
        var props: [String: Analytics.Value] = ["provider": .string(provider), "step": .string(step.rawValue)]
        if let reason { props["reason"] = .string(reason) }
        Analytics.shared.track(name, props)
    }

    func foreground() async {
        if let user, let appleID = user.appleUserID, token != nil {
            let run = generation
            do {
                let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleID)
                guard run == generation else { return }
                if state != .authorized {
                    _ = try? await request("signout", method: "POST")
                    guard run == generation else { return }
                    token = nil; SecureSession.remove()
                    message = String(localized: "Please sign in with Apple again to reconnect your account.", comment: "Sign-in prompt after Apple revoked access")
                    return
                }
            } catch { /* Transient Apple errors retain the isolated session for retry. */ }
        }
        await sync()
        if let cart { await CartSync.pull(account: self, cart: cart) }
    }
    func scheduleSync() {
        guard user != nil else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }
    func sync() async {
        guard token != nil, let shopper else { return }
        if syncing { syncAgain = true; return }
        syncing = true
        let run = generation
        defer { syncing = false; if syncAgain { syncAgain = false; scheduleSync() } }
        do {
            // GET first refreshes remote changes without overwriting the local
            // outbox; accept replays changes made while the request was in flight.
            if shopper.pending.isEmpty {
                let data = try await request("me")
                guard generation == run else { return }
                let reply = try JSONDecoder().decode(AccountReply.self, from: data)
                shopper.accept(reply.profile)
                // Which sign-in this phone used, and which confirms a deletion,
                // can change as sign-ins are linked; keep the saved session current.
                if let fresh = reply.user, let current = user, let token, fresh.id == current.id, fresh.generation == current.generation,
                   fresh.signedInWith != current.signedInWith || fresh.confirmWith != current.confirmWith {
                    user = fresh
                    try? SecureSession.save(JSONEncoder().encode(SavedSession(token: token, user: fresh)))
                }
            }
            while !shopper.pending.isEmpty {
                let batch = Array(shopper.pending.prefix(100))
                let data = try await request("activity", method: "POST", body: JSONEncoder().encode(ActivityBody(operations: batch)))
                guard generation == run else { return }
                let reply = try JSONDecoder().decode(AccountReply.self, from: data)
                shopper.accept(reply.profile, acknowledged: Set(batch.map(\.id)))
            }
            lastSynced = .now; message = nil
        } catch {
            guard generation == run else { return }
            if case AccountError.unauthorized = error {
                // Keep the isolated account cache for reauthentication; don't
                // copy it into the guest profile or lose unsent activity.
                token = nil; SecureSession.remove(); message = error.localizedDescription
            } else { message = AccountError.unavailable.localizedDescription }
        }
    }
    func signOut() async {
        guard !busy else { return }
        busy = true
        scheduled?.cancel()
        await sync()
        await willSignOut?()
        _ = try? await request("signout", method: "POST")
        clearSession(eraseCache: false)
        busy = false
    }
    func deleteAccount() async {
        guard !busy, let user else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            if user.deletesWithApple {
                let body = try await appleToken()
                _ = try await request("account", method: "DELETE", body: JSONEncoder().encode(body))
                clearSession(eraseCache: true)
                message = String(localized: "Your Marracat account has been deleted and Apple sign-in access revoked.", comment: "Account deleted confirmation")
            } else {
                let idToken = try await googleToken()
                _ = try await request("account", method: "DELETE", body: JSONEncoder().encode(TokenBody(idToken: idToken)))
                let disconnected = (try? await GIDSignIn.sharedInstance.disconnect()) != nil
                clearSession(eraseCache: true)
                message = disconnected ? String(localized: "Your Marracat account has been deleted.", comment: "Account deleted confirmation") : String(localized: "Your Marracat account has been deleted. You can also remove Marracat's access in your Google Account settings.", comment: "Account deleted confirmation")
            }
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled || (!user.deletesWithApple && (error as NSError).code == GIDSignInError.canceled.rawValue) { return }
            message = String(localized: "Account deletion didn't finish. Sign in to the same \(user.deletionProviderName) account and try again.", comment: "Account deletion error; the argument is Apple or Google")
        }
    }
    private func clearSession(eraseCache: Bool) {
        generation = UUID(); scheduled?.cancel()
        SecureSession.remove(); GIDSignIn.sharedInstance.signOut()
        token = nil; user = nil; lastSynced = nil; message = nil
        RelayStore.shared.clear()
        RestockStore.shared.signedOut()
        DealAlertStore.shared.signedOut()
        // This account's saves and follows come out of Spotlight (SpotlightSync).
        SpotlightSync.shared.removeAll()
        // And the widgets' snapshot in the App Group (WidgetSync).
        WidgetSync.shared.clear()
        if eraseCache { shopper?.eraseAccountCache(); cart?.eraseAccountCache(); buyer?.eraseAccountCache(); OrderExtrasStore.shared.removeAll(); OrderTrackingStore.shared.clear(); LateShipmentStore.shared.clear() }
        else { shopper?.activate(nil); cart?.activate(nil); buyer?.activate(nil) }
    }
    /// A call to /api/social as this account, or signed out when there isn't
    /// one. Returns the status with the body so callers can show the server's
    /// own message ("That handle is taken", a filter refusal, a rate limit).
    func social(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "https://marracat.com/api/social/" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.unavailable }
        return (http.statusCode, data)
    }
    var signedIn: Bool { token != nil && user != nil }
    /// The session token for Analytics' Bearer header (marracat.com only).
    var analyticsToken: String? { signedIn ? token : nil }

    /// Signs a request as this account when there is one. Late-shipment
    /// reports use it so the owner's own taps stay off the dashboard.
    func authorize(_ request: inout URLRequest) {
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    }

    /// A call to /api/mobile as this account (the order email uses it).
    /// `deviceKey` links the install's push token for order updates.
    func mobile(_ path: String, method: String = "GET", body: Data? = nil, deviceKey: String? = nil) async throws -> (status: Int, data: Data) {
        guard let token else { throw AccountError.unauthorized }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/mobile/" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let deviceKey { request.setValue(deviceKey, forHTTPHeaderField: "X-Marracat-Device") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.unavailable }
        return (http.statusCode, data)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://marracat.com/api/mobile/" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        if authenticated {
            guard let token else { throw AccountError.unauthorized }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AccountError.unavailable }
        if http.statusCode == 401 { throw AccountError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw AccountError.unavailable }
        return data
    }
}

private enum SecureSession {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.divinedavis.marracat.account", kSecAttrAccount as String: "session"] }
    static func read() -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data) throws {
        remove()
        var q = query; q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AccountError.keychain }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}
