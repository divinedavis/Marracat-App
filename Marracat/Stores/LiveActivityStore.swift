import Foundation
import Observation
import ActivityKit
import os
import CryptoKit

/// Today's deliveries in the Dynamic Island (owner, 2026-10-13). The server
/// (web/server/live-activity.js) decides when an order arrives today and
/// starts, updates and ends ONE Live Activity per phone with ActivityKit
/// pushes; this store hands it the tokens to do that:
///
/// - the push-to-start token (iOS 17.2+), so it can start one at all;
/// - each running activity's update token, so it can move it on;
/// - the shopper's switch (You › Notifications), and a swiped-away activity,
///   so it stops.
///
/// Keyed by the per-install device key, like order tracking: no account
/// needed. Tokens are sent once per change and never logged.
@MainActor
@Observable
final class LiveActivityStore {
    static let shared = LiveActivityStore()

    /// The shopper's switch. On by default (the system's own Live Activities
    /// setting still applies on top).
    private(set) var enabled: Bool
    /// The signed-in account is an owner: You › Notifications offers the test.
    private(set) var isOwner = false
    private(set) var demoRunning = false
    var message: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let args = ProcessInfo.processInfo.arguments
    /// UI tests: no network and no ActivityKit; -LIVE_ACTIVITY_OWNER stands in an owner.
    /// Unit tests (inside the app on the simulator) never reach the server either.
    @ObservationIgnored private var stubbed: Bool { args.contains("-LIVE_ACTIVITY_STUB") || !Analytics.sendsToServer }
    @ObservationIgnored private let log = Logger(subsystem: "com.divinedavis.marracat", category: "liveactivity")
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watched = Set<String>()
    /// Cards taken down for a newer one: their dismissal isn't the shopper's.
    @ObservationIgnored private var replaced = Set<String>()
    private static let enabledKey = "liveActivities.enabled"
    private static let sentStartKey = "liveActivities.startTokenSent"

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if ProcessInfo.processInfo.arguments.contains("-LIVE_ACTIVITY_OWNER") { isOwner = true }
    }

    /// At launch: listen for the tokens and for activities the server starts.
    func start() {
        // UI tests: -LIVE_ACTIVITY_PREVIEW starts the demo's three orders
        // locally (no server), so the island and ‹ › can be checked.
        // A card left by an earlier run (cards stay up all day now) goes back
        // to the first order, or a retry opens on wherever that run flipped to.
        if args.contains("-LIVE_ACTIVITY_PREVIEW") {
            if let running = ActivityKit.Activity<DeliveryActivityAttributes>.activities.first {
                Task { await running.update(ActivityContent(state: Self.previewState, staleDate: nil)) }
            } else {
                _ = try? ActivityKit.Activity.request(attributes: DeliveryActivityAttributes(kind: "deliveries"),
                                                      content: ActivityContent(state: Self.previewState, staleDate: nil))
            }
        }
        guard !started, !stubbed else { return }
        started = true
        if #available(iOS 17.2, *) {
            Task {
                for await data in ActivityKit.Activity<DeliveryActivityAttributes>.pushToStartTokenUpdates {
                    await sendStartToken(Self.hex(data))
                }
            }
        }
        Task {
            for await activity in ActivityKit.Activity<DeliveryActivityAttributes>.activityUpdates {
                watch(activity)
                await endOlder(than: activity)
            }
        }
        for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities { watch(activity) }
        Task { await reportRunning() }
    }

    /// Tells the server which activities are really on screen. An app update
    /// ends them all without a word, and a swipe while the app isn't running
    /// goes unreported; either way the server went on "running" one and never
    /// started another (owner, 2026-10-17). A swiped one still listed here is
    /// reported as dismissed, so it doesn't come back today.
    /// Also whether iOS allows Live Activities at all: the server only lets
    /// the card stand in for an order's ordinary notification when it can
    /// actually appear (owner, 2026-10-17: one notification, not two).
    private func reportRunning() async {
        let authorized = ActivityAuthorizationInfo().areActivitiesEnabled
        var running: [String] = []
        for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities {
            switch activity.activityState {
            case .active, .stale: running.append(activity.id)
            case .dismissed: _ = try? await call("activity", method: "DELETE", body: ["activityID": activity.id])
            default: break
            }
        }
        let status = (try? await call("running", method: "PUT", body: ["activityIDs": running, "authorized": authorized]))?.0 ?? 0
        log.info("live activity: \(running.count) running, reported HTTP \(status)")
    }

    private func watch(_ activity: ActivityKit.Activity<DeliveryActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        let id = activity.id
        Task {
            for await data in activity.pushTokenUpdates {
                let body: [String: Any] = ["activityID": id, "token": Self.hex(data), "environment": APNsEnvironment.current]
                let status = (try? await call("activity", method: "PUT", body: body))?.0 ?? 0
                log.info("live activity: update token sent, HTTP \(status)")
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .dismissed {
                // Swiped away (or ended and removed): no new one today.
                guard !replaced.contains(id) else { continue }
                _ = try? await call("activity", method: "DELETE", body: ["activityID": id])
            }
        }
    }

    /// One card per phone: a new one (the server's replacement at Apple's 8
    /// hours, or a restart) takes any older one down at once (owner,
    /// 2026-10-25: two "Delivery problem" cards for one order).
    private func endOlder(than newest: ActivityKit.Activity<DeliveryActivityAttributes>) async {
        for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities where activity.id != newest.id {
            replaced.insert(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Dismiss on a delivered order: off today's card for good (server).
    func hide(orderID: String) async {
        guard !stubbed else { return }
        let status = (try? await call("hide", method: "PUT", body: ["orderID": orderID]))?.0 ?? 0
        log.info("live activity: order dismissed, HTTP \(status)")
    }

    private func sendStartToken(_ token: String) async {
        // Only when it changes: the stream repeats the same token every launch.
        guard defaults.string(forKey: Self.sentStartKey) != Self.fingerprint(token) else { return }
        let body: [String: Any] = ["token": token, "environment": APNsEnvironment.current]
        guard let (status, _) = try? await call("start-token", method: "PUT", body: body) else { return }
        if status == 204 { defaults.set(Self.fingerprint(token), forKey: Self.sentStartKey) }
        log.info("live activity: start token sent, HTTP \(status)")
    }

    /// You › Notifications. Off ends a running one on this phone at once and
    /// tells the server to stop.
    func setEnabled(_ on: Bool) async {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        Analytics.shared.track(on ? "alert_on" : "alert_off", ["kind": .string("live_activity")])
        guard !stubbed else { return }
        if !on {
            for activity in ActivityKit.Activity<DeliveryActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        _ = try? await call("settings", method: "PUT", body: ["enabled": on])
    }

    /// Whether the signed-in account is an owner (the server decides).
    func refresh(account: AccountStore) async {
        guard !stubbed else { return }
        guard account.signedIn, let (status, data) = try? await call("status", account: account), status == 200,
              let reply = try? JSONDecoder().decode(Status.self, from: data) else { isOwner = false; return }
        isOwner = reply.owner
        // The server's switch follows the phone's.
        if reply.enabled != enabled { _ = try? await call("settings", method: "PUT", body: ["enabled": enabled]) }
    }

    /// The owner's test: three made-up orders, out for delivery → nearby →
    /// delivered over about two minutes, pushed by the server to this phone.
    func runDemo(account: AccountStore) async {
        message = nil
        if stubbed { message = String(localized: "Test started. Lock your iPhone or go Home to watch it.", comment: "Live Activity test started"); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = String(localized: "Live Activities are off for Marracat in Settings › Marracat.", comment: "Live Activity test error")
            return
        }
        guard #available(iOS 17.2, *) else { message = String(localized: "The test needs iOS 17.2 or later.", comment: "Live Activity test error"); return }
        demoRunning = true
        defer { demoRunning = false }
        // A start token from this launch, in case the last one never arrived.
        defaults.removeObject(forKey: Self.sentStartKey)
        if let data = ActivityKit.Activity<DeliveryActivityAttributes>.pushToStartToken { await sendStartToken(Self.hex(data)) }
        guard let (status, data) = try? await call("demo", method: "POST", body: [:], account: account) else {
            message = String(localized: "Couldn't reach Marracat. Try again.", comment: "Network error")
            return
        }
        switch status {
        case 202: message = String(localized: "Test started. Lock your iPhone or go Home to watch it.", comment: "Live Activity test started")
        default: message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? String(localized: "The test couldn't start (\(status)).", comment: "Live Activity test error; the argument is an HTTP status code")
        }
    }

    /// The owner's test as it first appears (web/server/live-activity.js demoSteps).
    static let previewState = DeliveryActivityAttributes.ContentState(orders: [
        DeliveryOrder(id: "demo-ripl", brand: "Ripl Efek", item: "Laundry Detergent", status: "out_for_delivery", carrier: "UPS", eta: "By 2:30 PM", link: "marracat://orders"),
        DeliveryOrder(id: "demo-koba", brand: "KOBA", item: "Keep It Together Headband", status: "nearby", carrier: "USPS", eta: "2 stops away", link: "marracat://orders"),
        DeliveryOrder(id: "demo-telfar", brand: "Telfar", item: "Medium Shopping Bag", status: "out_for_delivery", carrier: "FedEx", eta: "By 8 PM", link: "marracat://orders"),
    ], index: 0)

    private struct Status: Decodable { let enabled: Bool; let owner: Bool }

    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    /// Remembers which token was sent without keeping the token itself.
    nonisolated static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, account: AccountStore? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "https://marracat.com/api/live-activity/" + path)!)
        request.httpMethod = method; request.timeoutInterval = 20
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        account?.authorize(&request)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// marracat://… links from the Live Activity.
enum DeliveryLink: Equatable {
    /// An order the app tracks (order-tracking.js): brand + Shopify order number.
    case tracked(brandID: String, orderNumber: String?)
    /// An order from the brand's email (relay.js).
    case email(brandDomain: String, orderName: String?)
    /// Your Orders.
    case orders

    init?(_ url: URL) {
        guard url.scheme == "marracat", let host = url.host else { return nil }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in q.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        switch host {
        case "orders": self = .orders
        case "order":
            if let brand = value("brand") {
                let number = value("order").flatMap { $0.allSatisfy(\.isNumber) ? $0 : nil }
                self = .tracked(brandID: brand, orderNumber: number)
            } else if let domain = value("domain") {
                self = .email(brandDomain: domain, orderName: value("name"))
            } else { self = .orders }
        default: return nil
        }
    }
}
