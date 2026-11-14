import SwiftUI
import UIKit

/// What shoppers do in the app, counted on Marracat's own server (owner,
/// 2026-10-10: "are we detecting everything a user is doing on the app? …
/// make our analytics more robust"). Screens, product views, searches,
/// saves, follows, alerts, cart and checkout steps, shares, sign-ins, and
/// which recommendation rows are seen and tapped.
///
/// - Batched: sent every 20 seconds and when the app goes to the background,
///   at most 50 events a request, never on the main thread's critical path.
/// - Offline: unsent events are kept on the phone (500 at most) and sent later.
/// - Private: no names, emails, addresses or free text other than a search
///   query; guests are counted by the per-install key restock alerts use, a
///   signed-in shopper only adds a flag (the server keeps a one-way hash).
/// - Off switch: "Share usage analytics" in account settings stops all of it
///   and clears the queue. Recommendation counting also stops when
///   "Personalized recommendations" is off.
@MainActor
final class Analytics {
    static let shared = Analytics()

    /// One property value: the server takes strings, numbers and booleans.
    enum Value: Codable, Equatable, Sendable {
        case string(String), int(Int), double(Double), bool(Bool)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let i = try? c.decode(Int.self) { self = .int(i) }
            else if let d = try? c.decode(Double.self) { self = .double(d) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    /// Sent flat: {"name": …, "platform": "ios", …props}.
    struct Event: Codable, Equatable, Sendable {
        let name: String
        var props: [String: Value]

        private struct Key: CodingKey {
            var stringValue: String
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }
        init(name: String, props: [String: Value]) { self.name = name; self.props = props }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            name = try c.decode(String.self, forKey: Key("name"))
            var p: [String: Value] = [:]
            for k in c.allKeys where k.stringValue != "name" { p[k.stringValue] = try c.decode(Value.self, forKey: k) }
            props = p
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(name, forKey: Key("name"))
            for (k, v) in props { try c.encode(v, forKey: Key(k)) }
        }
        subscript(_ key: String) -> Value? { props[key] }
    }

    static let maxBatch = 50
    static let maxQueue = 500
    static let flushInterval: TimeInterval = 20
    static let enabledKey = "analytics.enabled"
    private static let queueKey = "analytics.queue.v1"

    private(set) var queue: [Event] = []
    private var seenRows: Set<String> = []
    private var timer: Timer?
    private var sessionStart: Date?
    /// False until the first app_open of this process (app_open "cold").
    private var openedBefore = false
    /// The row or screen the next product view came from.
    private var pendingSource: String?
    private(set) var currentScreen = ""
    /// Screen and row views from before the app came to the foreground. iOS
    /// launches the app in the background (catalog refresh every few hours)
    /// and SwiftUI still lays out Home, so until 2026-11-09 each of those
    /// launches logged a Home view: 45 of 74 iPhone visitor-days in two weeks
    /// were a lone Home view at 2 AM with no app_open, and read as returning
    /// shoppers. Held here, sent only if app_open follows within
    /// `heldViewWindow` (a real cold launch lays Home out a moment before
    /// the scene goes active), dropped otherwise.
    private(set) var heldViews: [(at: Date, event: Event)] = []
    static let heldViewWindow: TimeInterval = 30

    let defaults: UserDefaults
    /// Recommendation rows also need "Personalized recommendations" on.
    var personalizationEnabled: () -> Bool = { true }
    /// The signed-in session token, sent as a Bearer header so the server can
    /// mark the events signed in (it stores only a keyed hash of the account).
    var sessionToken: () -> String? = { nil }
    /// Sends one batch. Replaced in tests and UI tests.
    var transport: ([Event]) -> Void = Analytics.sendsToServer ? Analytics.post : { _ in }

    /// False while XCTest is running: unit tests run inside the app on the
    /// simulator, and their direct calls into ShopperStore / CartStore were
    /// posting to marracat.com (2026-10-13: SavedListsTests' "at most 50
    /// folders" case showed up as one visitor making 52 lists in a second).
    /// UI tests launch with -UITEST_RESET and are silenced in start().
    nonisolated static var sendsToServer: Bool {
        let p = ProcessInfo.processInfo
        return p.environment["XCTestConfigurationFilePath"] == nil && p.environment["XCTestBundlePath"] == nil
            && NSClassFromString("XCTestCase") == nil && !p.arguments.contains("-UITEST_RESET")
    }
    var now: () -> Date = { .now }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        queue = defaults.data(forKey: Self.queueKey).flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
    }

    /// "Share usage analytics" in account settings; on unless turned off.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { queue = []; persist() }
        }
    }

    func start(personalization: @escaping () -> Bool, sessionToken: @escaping () -> String?) {
        personalizationEnabled = personalization
        self.sessionToken = sessionToken
        // UI tests drive the app against the live catalog; their taps must
        // not land in the owner's numbers.
        if ProcessInfo.processInfo.arguments.contains("-UITEST_RESET") { transport = { _ in } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.flushInterval, repeats: true) { _ in
            Task { @MainActor in Analytics.shared.flush() }
        }
    }

    // MARK: Sessions

    func appOpened() {
        guard sessionStart == nil else { return }
        sessionStart = now()
        seenRows = []
        track("app_open", ["cold": .bool(!openedBefore)])
        openedBefore = true
        let fresh = heldViews.filter { sessionStart!.timeIntervalSince($0.at) <= Self.heldViewWindow }.map(\.event)
        heldViews = []
        for event in fresh {
            if event.name == "rec_view", case .string(let row)? = event["row"] { seenRows.insert(row) }
            enqueue(event)
        }
    }

    func appBackgrounded() {
        if let open = openProduct { productLeft(open.product) }
        if let start = sessionStart {
            track("session_end", ["duration_s": .int(max(0, Int(now().timeIntervalSince(start))))])
        }
        sessionStart = nil
        heldViews = []
        flush()
    }

    // MARK: Events

    /// From code that isn't on the main actor (ShopperStore, CartStore).
    nonisolated static func log(_ name: String, _ props: [String: Value] = [:]) {
        Task { @MainActor in shared.track(name, props) }
    }

    /// Where the next search came from: typed, a suggestion, or a recent one.
    var searchSource = "typed"

    func track(_ name: String, _ props: [String: Value] = [:]) {
        guard isEnabled else { return }
        enqueue(event(name, props))
    }

    private func event(_ name: String, _ props: [String: Value]) -> Event {
        var p = props
        p["platform"] = .string("ios")
        return Event(name: name, props: p)
    }

    private func enqueue(_ event: Event) {
        queue.append(event)
        if queue.count > Self.maxQueue { queue.removeFirst(queue.count - Self.maxQueue) }
        if queue.count % 10 == 0 { persist() }
    }

    /// A screen or row view: queued in a session, held before one (heldViews).
    private func trackView(_ name: String, _ props: [String: Value]) {
        guard isEnabled else { return }
        if sessionStart != nil { return enqueue(event(name, props)) }
        heldViews.append((now(), event(name, props)))
        if heldViews.count > 20 { heldViews.removeFirst(heldViews.count - 20) }
    }

    func screen(_ name: String) {
        currentScreen = name
        trackView("screen_view", ["screen": .string(name)])
    }

    private var openProduct: (product: Product, source: String, at: Date)?

    /// A product page opened. Counted once, as the shopper leaves it, so the
    /// event carries how long they stayed (dwell_s).
    func productViewed(_ product: Product) {
        if let open = openProduct, open.product.id != product.id { productLeft(open.product) }
        let source = pendingSource ?? (currentScreen.isEmpty ? "unknown" : currentScreen)
        pendingSource = nil
        openProduct = (product, source, now())
        zoomedPhotos = []
    }

    private var zoomedPhotos: Set<String> = []

    /// gallery_zoom, once per photo per product visit.
    func galleryZoomed(product: String, photo: String) {
        guard zoomedPhotos.insert(product + "|" + photo).inserted else { return }
        track("gallery_zoom", ["product": .string(product)])
    }

    func productLeft(_ product: Product) {
        guard let open = openProduct, open.product.id == product.id else { return }
        openProduct = nil
        track("product_view", ["product": .string(product.id), "brand": .string(product.brand),
                               "source": .string(open.source),
                               "dwell_s": .int(max(0, Int(now().timeIntervalSince(open.at).rounded())))])
    }

    func search(_ q: String, results: Int, source: String) {
        let query = String(q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !query.isEmpty else { return }
        track("search", ["q": .string(query), "n": .int(results), "source": .string(source)])
    }

    /// Order totals leave the phone as the low edge of the server's bucket
    /// (0, 25, 50, 100, 250, 500), never the exact amount.
    static func subtotalBucket(_ amount: Double) -> Int {
        [500, 250, 100, 50, 25].first { amount >= Double($0) } ?? 0
    }

    /// A row-shaped id for the server ("trueMetal" → "true_metal").
    static func rowID(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase, !out.isEmpty { out.append("_") }
            out.append(ch.isLetter || ch.isNumber ? Character(ch.lowercased()) : "_")
        }
        return String(out.prefix(40))
    }

    // MARK: Recommendation rows

    func rowViewed(_ row: String, first product: Product?) {
        guard personalizationEnabled(), seenRows.insert(row).inserted else { return }
        var p: [String: Value] = ["row": .string(row)]
        if let product { p["product"] = .string(product.id); p["brand"] = .string(product.brand) }
        trackView("rec_view", p)
    }

    func tapped(row: String, product: Product, position: Int) {
        pendingSource = row
        guard personalizationEnabled() else { return }
        track("rec_tap", ["row": .string(row), "product": .string(product.id), "brand": .string(product.brand),
                          "position": .int(position)])
    }

    // MARK: Sending

    func flush() {
        guard !queue.isEmpty else { return }
        guard isEnabled else { queue = []; persist(); return }
        let pending = queue
        queue = []
        persist()
        stride(from: 0, to: pending.count, by: Self.maxBatch).forEach { start in
            transport(Array(pending[start..<min(start + Self.maxBatch, pending.count)]))
        }
    }

    /// Keeps unsent events across launches.
    func persist() {
        if queue.isEmpty { defaults.removeObject(forKey: Self.queueKey) }
        else if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: Self.queueKey) }
    }

    private static func post(_ events: [Event]) {
        struct Body: Encodable { let events: [Event] }
        guard let body = try? JSONEncoder().encode(Body(events: events)) else { return }
        var request = URLRequest(url: URL(string: "https://marracat.com/api/events")!)
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppChannel.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(RestockStore.installKey, forHTTPHeaderField: "X-Marracat-Device")
        if let token = Analytics.shared.sessionToken() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        Task.detached(priority: .background) {
            let ok = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            // Offline or a server error: put the batch back for the next flush.
            if !ok { await MainActor.run { Analytics.shared.requeue(events) } }
        }
    }

    func requeue(_ events: [Event]) {
        guard isEnabled else { return }
        queue = Array((events + queue).suffix(Self.maxQueue))
        persist()
    }
}

/// Counts a recommendation row as seen once half of it is on screen (iOS 18
/// reports scroll visibility; on iOS 17 it counts when the row is laid out).
struct RecRowTracking: ViewModifier {
    let row: String?
    let first: Product?

    func body(content: Content) -> some View {
        if let row {
            if #available(iOS 18.0, *) {
                content.onScrollVisibilityChange(threshold: 0.5) { visible in
                    if visible { Analytics.shared.rowViewed(row, first: first) }
                }
            } else {
                content.onAppear { Analytics.shared.rowViewed(row, first: first) }
            }
        } else {
            content
        }
    }
}

extension View {
    /// Counts a screen view each time this screen appears.
    func analyticsScreen(_ name: String) -> some View {
        onAppear { Analytics.shared.screen(name) }
    }
}
