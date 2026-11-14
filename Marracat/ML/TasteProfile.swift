import Foundation
import Observation

/// What this shopper is drawn to, as a point in the meaning space
/// (MeaningIndex), learned on the iPhone and never sent anywhere (owner,
/// 2026-10-02: on-device personalization, real-time re-ranking).
///
/// Every product looked at (weighted by how long the page stayed open), saved,
/// put in the cart or bought pulls the taste toward that product. Two clocks
/// blend: this session (half-life 30 minutes), so what was just browsed counts
/// most, and the longer run (half-life two weeks). The "Personalized
/// recommendations" switch in account settings turns it off and clears it.
@MainActor
@Observable
final class TasteProfile {
    static let shared = TasteProfile()

    enum Signal: String, Codable {
        case view, save, cart, purchase
        var weight: Float {
            switch self { case .view: 1; case .save: 3; case .cart: 4; case .purchase: 5 }
        }
    }
    private struct Event: Codable { let product: String; let weight: Float; let at: Date }

    /// Bumped on every signal, so views that follow the taste can update.
    private(set) var revision = 0
    @ObservationIgnored var enabled = true { didSet { if !enabled { clear() } } }
    @ObservationIgnored private var events: [Event] = []
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "taste.events.v1"
    private static let sessionHalfLife: TimeInterval = 30 * 60
    private static let longHalfLife: TimeInterval = 14 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Event].self, from: data) {
            events = saved
        }
        muted = defaults.stringArray(forKey: Self.mutedKey) ?? []
        notMeStyles = defaults.stringArray(forKey: Self.notMeKey) ?? []
    }

    /// A product page open for `dwell` seconds: a glance (under 3 s) counts a
    /// little, a long look up to three times a plain view.
    func viewed(_ productID: String, dwell: TimeInterval) {
        record(productID, weight: Signal.view.weight * Float(min(max(dwell / 10, 0.2), 3)))
    }

    func record(_ productID: String, _ signal: Signal) { record(productID, weight: signal.weight) }

    private func record(_ productID: String, weight: Float, at: Date = .now) {
        guard enabled else { return }
        events.append(Event(product: productID, weight: weight, at: at))
        if events.count > 400 { events.removeFirst(events.count - 400) }
        defaults.set(try? JSONEncoder().encode(events), forKey: Self.key)
        revision += 1
    }

    /// Everything learned: the taste, what was muted or marked "Not me",
    /// sizes and the Women / Men lean.
    func clear() {
        events = []; muted = []; notMeStyles = []
        for k in [Self.key, Self.mutedKey, Self.notMeKey] { defaults.removeObject(forKey: k) }
        SizeMemory.clear(defaults)
        GenderLean.clear(defaults)
        revision += 1
    }

    /// Anything to read a taste from: Home holds "Picked for you right now"'s
    /// place while it's worked out.
    var hasHistory: Bool { enabled && !events.isEmpty }

    /// Products touched lately, most recent first.
    var recentProducts: [String] {
        var seen = Set<String>()
        return events.reversed().map(\.product).filter { seen.insert($0).inserted }
    }

    /// Each product touched, with its weight now (both clocks blended),
    /// heaviest first.
    func weightedProducts(now: Date = .now) -> [(id: String, weight: Float)] {
        guard enabled else { return [] }
        var by: [String: Float] = [:]
        for e in events {
            let age = now.timeIntervalSince(e.at)
            let w = e.weight * Float(2 * pow(0.5, age / Self.sessionHalfLife) + pow(0.5, age / Self.longHalfLife))
            guard w > 0.01 else { continue }
            by[e.product, default: 0] += w
        }
        return by.map { ($0.key, $0.value) }.sorted { ($0.weight, $1.id) > ($1.weight, $0.id) }
    }

    /// The taste right now, or nil with too little to go on (or before the
    /// meaning vectors have arrived).
    func vector(now: Date = .now) -> [Float]? {
        let touched = weightedProducts(now: now)
        guard !touched.isEmpty else { return nil }
        return MeaningIndex.shared.centroid(of: touched.map(\.id), weights: touched.map(\.weight))
    }

    /// The taste as up to three interests (TasteMath.interests), biggest first.
    func interests(now: Date = .now) -> [TasteInterest] {
        let items = weightedProducts(now: now).prefix(200).compactMap { t in
            MeaningIndex.shared.vector(for: t.id).map { (id: t.id, vector: $0, weight: t.weight) }
        }
        return TasteMath.interests(Array(items))
    }

    // MARK: What pushes away (owner, 2026-11-08: "6: lets do it")

    private static let mutedKey = "taste.muted.v1"
    private static let notMeKey = "taste.notMeStyles.v1"

    /// Products from interests the shopper muted on the Your taste screen:
    /// their events are gone, and picks steer away from them.
    private(set) var muted: [String] = []
    /// Shop by Style styles marked "Not me".
    private(set) var notMeStyles: [String] = []

    /// "Less of this" on an interest.
    func mute(_ productIDs: [String]) {
        let ids = Set(productIDs)
        events.removeAll { ids.contains($0.product) }
        defaults.set(try? JSONEncoder().encode(events), forKey: Self.key)
        muted = Array((productIDs + muted.filter { !ids.contains($0) }).prefix(300))
        defaults.set(muted, forKey: Self.mutedKey)
        revision += 1
    }

    func setNotMe(_ styleID: String, _ notMe: Bool) {
        notMeStyles.removeAll { $0 == styleID }
        if notMe { notMeStyles.insert(styleID, at: 0) }
        defaults.set(notMeStyles, forKey: Self.notMeKey)
        revision += 1
    }

    /// How close a product (or a group's centroid) is to the taste: -1...1.
    nonisolated static func affinity(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
}
