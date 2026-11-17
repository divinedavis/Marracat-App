import Foundation
import Observation
import Security
import UIKit
import UserNotifications

/// One "tell me when it's back" request: a product, or one option of it.
struct RestockAlert: Codable, Hashable, Identifiable {
    let productID: String
    let variantID: String?
    var id: String { productID + "|" + (variantID ?? "") }
}

/// "Notify me when it's back" (owner, 2026-09-30). The shopper taps it on a
/// sold-out product page; that tap is the only place notification permission
/// is asked for. marracat.com checks watched products against the brand's own
/// store and, when one is back, emails the account and pushes to every phone
/// signed in to it (web/server/restock.js).
///
/// Signed-in shoppers only (owner, 2026-10-02): alerts belong to the account.
/// The phone is known by a random key kept in the keychain and sent as
/// X-Marracat-Device; signing out unlinks it, so it stops getting the pushes.
@MainActor
@Observable
final class RestockStore {
    static let shared = RestockStore()

    private(set) var alerts: [RestockAlert] = []
    /// Products whose request is in flight, so the button can't be tapped twice.
    private(set) var busy: Set<String> = []
    /// Why the last tap didn't work, for the page to show.
    var message: String?
    /// A product whose notification was tapped, waiting for the app to open it.
    var openRequest: String?

    private let defaults: UserDefaults
    private let session: URLSession
    /// UI tests pass -RESTOCK_STUB: alerts toggle locally, with no permission
    /// prompt and no network.
    private let stubbed = ProcessInfo.processInfo.arguments.contains("-RESTOCK_STUB")
    /// UI tests can't sign in to Apple or Google; with the stub, this stands in.
    let stubSignedIn = ProcessInfo.processInfo.arguments.contains("-RESTOCK_SIGNED_IN")
    /// Set by AccountStore.attach: alerts are made and read as this account.
    @ObservationIgnored weak var account: AccountStore?
    /// Whether the last alert also gets a push (notifications on), for the caption.
    private(set) var pushOn = true
    private var token: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private static let storeKey = "restockAlerts"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        if let data = defaults.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([RestockAlert].self, from: data) { alerts = saved }
    }

    func isWatching(_ productID: String, variantID: String?) -> Bool {
        alerts.contains(RestockAlert(productID: productID, variantID: variantID))
    }

    func toggle(_ productID: String, variantID: String?) async {
        let key = RestockAlert(productID: productID, variantID: variantID)
        guard !busy.contains(key.id) else { return }
        busy.insert(key.id); defer { busy.remove(key.id) }
        let was = isWatching(productID, variantID: variantID)
        if was { await remove(key) } else { await add(key) }
        if isWatching(productID, variantID: variantID) != was {
            Analytics.shared.track(was ? "alert_off" : "alert_on", ["kind": .string("restock"), "product": .string(productID)])
        }
    }

    func remove(_ alert: RestockAlert) async {
        if stubbed { set(alerts.filter { $0 != alert }); return }
        let body = try? JSONSerialization.data(withJSONObject: ["productID": alert.productID, "variantID": alert.variantID ?? ""])
        guard let (status, data) = try? await call("alerts", method: "DELETE", body: body), status == 200 else {
            message = String(localized: "That alert couldn't be removed. Try again.", comment: "Restock alert error")
            return
        }
        apply(data)
    }

    private func add(_ alert: RestockAlert) async {
        if stubbed { set([alert] + alerts); return }
        guard account?.signedIn == true else { message = String(localized: "Sign in to get restock alerts.", comment: "Restock alert error"); return }
        // The email goes either way; a push too when notifications are on.
        var push = false
        if await allowed(), let token = await deviceToken() { push = await register(token) }
        pushOn = push
        var fields: [String: String] = ["productID": alert.productID]
        if let v = alert.variantID { fields["variantID"] = v }
        let body = try? JSONSerialization.data(withJSONObject: fields)
        guard let (status, data) = try? await call("alerts", method: "POST", body: body) else {
            message = String(localized: "That alert couldn't be saved. Try again.", comment: "Restock alert error")
            return
        }
        switch status {
        case 201: apply(data)
        case 401: message = String(localized: "Sign in again to get restock alerts.", comment: "Restock alert error")
        case 422: message = String(localized: "Restock alerts aren't available for this store yet.", comment: "Restock alert error")
        case 429: message = String(localized: "You're watching as many items as you can. Remove one in You → Restock alerts.", comment: "Restock alert error")
        default: message = String(localized: "That alert couldn't be saved. Try again.", comment: "Restock alert error")
        }
    }

    /// Drops alerts the server has already sent (or no longer has).
    /// The account's alerts, from any phone it's signed in on. Also tells the
    /// server this phone is signed in to it, which is where pushes go.
    func refresh() async {
        guard !stubbed, account?.signedIn == true,
              let (status, data) = try? await call("alerts"), status == 200 else { return }
        apply(data)
    }

    /// Signing out: forget the account's alerts here and stop this phone
    /// getting their pushes. The device key alone unlinks it.
    func signedOut() {
        set([])
        guard !stubbed else { return }
        Task { _ = try? await call("link", method: "DELETE") }
    }

    /// At launch, with alerts outstanding and permission already given, pick
    /// up a new token (a restored or reinstalled phone gets a different one).
    /// Never asks for permission.
    func renewToken() async {
        guard !stubbed, !alerts.isEmpty else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        if let token = await deviceToken() { _ = await register(token) }
    }

    /// The order email's delivery updates use the same push registration as
    /// restock alerts. Asked only when the shopper taps to turn them on.
    func enableOrderUpdates() async -> Bool {
        guard !stubbed else { return true }
        guard await allowed(), let token = await deviceToken() else { return false }
        return await register(token)
    }
    var orderUpdatesAllowed: Bool {
        get async {
            if stubbed { return true }
            return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized
        }
    }
    /// The install's key, so the order email can find this phone's push token.
    static var installKey: String { RestockDeviceKey.value }

    // MARK: Push registration

    func didRegister(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        token = hex
        waiters.forEach { $0.resume(returning: hex) }
        waiters = []
    }

    func didFailToRegister() {
        waiters.forEach { $0.resume(returning: nil) }
        waiters = []
    }

    private func allowed() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: return false
        }
    }

    private func deviceToken() async -> String? {
        if let token { return token }
        return await withCheckedContinuation { c in
            waiters.append(c)
            UIApplication.shared.registerForRemoteNotifications()
            // APNs normally answers in a second; don't hang the button on it.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                if self?.token == nil { self?.didFailToRegister() }
            }
        }
    }

    private func register(_ token: String) async -> Bool {
        // The time zone: "Arriving today" goes out at 8 am here (relay.js).
        let body = try? JSONSerialization.data(withJSONObject: ["token": token, "environment": APNsEnvironment.current,
                                                                "timeZone": TimeZone.current.identifier])
        guard let (status, _) = try? await call("device", method: "PUT", body: body) else { return false }
        return status == 204
    }

    // MARK: Storage and network

    private func apply(_ data: Data) {
        struct Response: Decodable { let alerts: [RestockAlert] }
        guard let r = try? JSONDecoder().decode(Response.self, from: data) else { return }
        set(r.alerts)
    }

    private func set(_ next: [RestockAlert]) {
        alerts = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.storeKey)
    }

    private func call(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "https://marracat.com/api/restock/" + path)!)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockDeviceKey.value, forHTTPHeaderField: "X-Marracat-Device")
        account?.authorize(&request)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Which APNs this build registers with. TestFlight and App Store builds are
/// production; only a development-signed build is sandbox. The provisioning
/// profile says which; App Store builds carry none, so a Release build without
/// one is production. Never default to sandbox: a wrong environment makes
/// every push fail silently.
enum APNsEnvironment {
    static let current: String = {
        if let value = fromProfile() { return value == "development" ? "sandbox" : "production" }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }()

    static func fromProfile(_ url: URL? = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")) -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return environment(inProfile: data)
    }

    /// The profile is a signed CMS blob with a plist inside.
    static func environment(inProfile data: Data) -> String? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}

/// The install's random key for restock alerts, kept in the keychain.
private enum RestockDeviceKey {
    static let value: String = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.divinedavis.marracat.restock",
                                    kSecAttrAccount as String: "device"]
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let key = String(data: data, encoding: .utf8), key.count == 64 { return key }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        var add = query; add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        return key
    }()
}

/// Push callbacks: the token, a banner while the app is open, and opening the
/// product when a notification is tapped.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // The shopping alerts' press-and-hold card and its buttons (InAppAlerts.swift).
        AlertCategories.register()
        BackgroundRefresh.register()
        // A Live Activity's Dismiss can launch the app in the background.
        DeliveryDismissal.report = { id in await LiveActivityStore.shared.hide(orderID: id) }
        // UI tests only (MarracatUITestCase): UIKit's transitions off.
        // SwiftUI's are dropped at the root (MarracatApp.noAnimations).
        if MarracatApp.noAnimations { UIView.setAnimationsEnabled(false) }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in RestockStore.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in RestockStore.shared.didFailToRegister() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A shopping alert with a card: our own banner instead of Apple's
        // (owner, 2026-11-15); it still goes in Notification Center.
        if let card = AlertCard(userInfo: notification.request.content.userInfo) {
            await MainActor.run { InAppAlerts.shared.show(card) }
            return [.list]
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // A shopping alert with a card: a tap or one of its buttons.
        if let card = AlertCard(userInfo: info) {
            let action = AlertCategories.action(for: response.actionIdentifier)
            await MainActor.run {
                Analytics.shared.track("notification_open", ["kind": .string("alert_" + card.k.rawValue), "action": .string(action.rawValue)])
                InAppAlerts.shared.request = AlertRequest(card: card, action: action)
            }
            return
        }
        let kind = info["trackedOrder"] != nil ? "order_tracking" : info["orderEvent"] != nil ? "order_email"
            : info["brandID"] != nil ? "brand_sale" : info["productID"] != nil ? "restock" : "other"
        await MainActor.run { Analytics.shared.track("notification_open", ["kind": .string(kind)]) }
        // A delivery update (order-tracking.js): open that order.
        if let order = info["trackedOrder"] as? [String: Any], let brandID = order["brandID"] as? String {
            let id = order["orderID"] as? String
            await MainActor.run {
                OrderTrackingStore.shared.openRequest = TrackedOrderRequest(orderID: id, brandID: brandID)
                Task { await OrderTrackingStore.shared.refresh() }
            }
            return
        }
        // A delivery update from the brand's own email (relay.js): open that order.
        if let event = info["orderEvent"] as? [String: Any], let domain = event["brandDomain"] as? String {
            let name = event["orderName"] as? String
            // Its events first, so the order the email names can be found.
            await RelayStore.shared.refresh()
            await MainActor.run { RelayStore.shared.openRequest = OrderEventRequest(brandDomain: domain, orderName: name) }
            return
        }
        // A brand sale (deal-alerts.js): open that brand.
        if let brand = info["brandID"] as? String {
            await MainActor.run { DealAlertStore.shared.openBrandRequest = brand }
            return
        }
        guard let id = info["productID"] as? String else { return }
        await MainActor.run {
            RestockStore.shared.openRequest = id
            Task { await RestockStore.shared.refresh() }
        }
    }
}
