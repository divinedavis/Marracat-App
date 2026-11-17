import SwiftUI
import UserNotifications
import os

/// Interests (owner, 2026-10-02): a shopper describes what they're into in
/// their own words ("gold jewelry for a summer wedding", "candles that smell
/// like a bakery"). Each description becomes a point in the meaning space on
/// the iPhone, and every time a new catalog arrives (at launch, or in the
/// background refresh) its new arrivals and restocks are checked against it;
/// a strong match sends one notification. What's written never leaves the phone.
struct Interest: Codable, Identifiable, Hashable {
    let id: UUID
    var text: String
    var vector: [Float]?
    /// MeaningIndex's space the vector was made in; remade when it differs.
    var space: String?
    var created: Date
    var lastNotified: Date?
}

enum InterestsStore {
    private static let key = "interests.v1"
    private static let log = Logger(subsystem: "com.divinedavis.marracat", category: "interests")
    /// The ranking score (similarity less the hub penalty). On the
    /// 2026-10-02 evaluation, on-topic products for 15 shopper phrases scored
    /// 0.30-0.63 at the top, the 20th best 0.23-0.59, a typical product -0.08.
    /// 0.33 for MobileCLIP2-S4 (2026-10-24): the score that lets through the
    /// same share of the catalog per phrase as 0.30 did for S0, over the 26
    /// shopper phrases in catalog/ml_model_gate.py (0.058% vs 0.063%).
    static let matchThreshold: Float = 0.33

    static func load() -> [Interest] {
        (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([Interest].self, from: $0) } ?? []
    }

    static func save(_ interests: [Interest]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(interests), forKey: key)
    }

    /// Fill in any interest still without a vector (the model may have
    /// arrived after it was written).
    static func embedMissing() async -> [Interest] {
        var all = load()
        guard await MeaningIndex.shared.prepare(), let space = MeaningIndex.shared.space else { return all }
        guard all.contains(where: { $0.vector == nil || $0.space != space }) else { return all }
        for i in all.indices where all[i].vector == nil || all[i].space != space {
            all[i].vector = MeaningIndex.shared.embed(all[i].text)
            all[i].space = space
        }
        save(all)
        return all
    }

    /// Each product's stock, by id; the first of a repeated id wins.
    static func availability(_ c: Catalog) -> [String: Bool] {
        Dictionary(c.products.map { ($0.id, $0.available) }, uniquingKeysWith: { a, _ in a })
    }

    /// New arrivals and restocks between two catalogs that match an interest:
    /// at most one notification per interest a day, for its best match.
    /// `before` is each product's stock in the previous catalog, by id
    /// (`availability`): all a scan needs of it, so the background refresh no
    /// longer holds two whole catalogs at once (2026-10-11).
    static func scan(before: [String: Bool], current: Catalog) async {
        let interests = await embedMissing().filter { $0.vector != nil }
        guard !interests.isEmpty else { return }
        await MeaningIndex.shared.refreshVectors()
        let candidates = current.products.filter { p in p.available && (before[p.id] == nil || before[p.id] == false) }
        guard !candidates.isEmpty else { return }
        let brands = Dictionary(current.brands.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var updated = load()
        for interest in interests {
            if let last = interest.lastNotified, Date().timeIntervalSince(last) < 20 * 3600 { continue }
            var matches: [(Product, Float)] = []
            for p in candidates {
                guard let s = MeaningIndex.shared.score(interest.vector!, productID: p.id), s >= matchThreshold else { continue }
                matches.append((p, s))
            }
            matches.sort { $0.1 > $1.1 }
            guard let (p, score) = matches.first else { continue }
            let title = String(localized: "New for “\(interest.text)”", comment: "Notification title; the argument is an interest the shopper typed")
            let body = Self.matchBody(product: p.title, brand: brands[p.brand], restocked: before[p.id] == false)
            await LocalAlert.schedule(id: "interest-\(interest.id)-\(p.id)", title: title, body: body,
                                      card: Self.card(interest: interest.text, matches: matches.map(\.0), brands: brands))
            log.info("interests: matched \(p.id, privacy: .public) at \(score)")
            if let i = updated.firstIndex(where: { $0.id == interest.id }) { updated[i].lastNotified = .now }
        }
        save(updated)
    }
}

extension InterestsStore {
    /// The card for an interest's matches (owner, 2026-11-15, design C05):
    /// the two best side by side; "Show matches" opens all of them.
    static func card(interest: String, matches: [Product], brands: [String: String]) -> AlertCard {
        var card = AlertCard(k: .interest, t: String(localized: "Matches “\(interest)”", comment: "Alert card title; the argument is an interest the shopper typed"))
        let best = matches.first
        let brand = best.flatMap { brands[$0.brand] }
        let n = matches.count
        card.s = [brand, n == 1 ? String(localized: "1 new today", comment: "Alert card line") : String(localized: "\(n) new today", comment: "Alert card line; the argument is a count")]
            .compactMap { $0 }.joined(separator: " · ")
        card.items = matches.prefix(2).map { p in
            AlertCard.Item(id: p.id, t: p.title, p: Money.string(p.price, currency: p.currencyCode), img: AlertImage.small(p.images.first))
        }
        card.pid = best?.id
        card.bid = best?.brand
        card.open = n > 1
            ? AppDestination.picks(String(localized: "“\(interest)”", comment: "Screen title: an interest's matches"), matches.prefix(AppDestination.maxPicks).map(\.id)).url.absoluteString
            : best.map { AppDestination.product($0.id).url.absoluteString }
        return card
    }

    /// Whole sentences, so each language can order product, brand and
    /// restock its own way. Product and brand names stay as the brand wrote them.
    static func matchBody(product: String, brand: String?, restocked: Bool) -> String {
        switch (brand, restocked) {
        case (let b?, true): String(localized: "\(product) at \(b) is back in stock", comment: "Notification body; the arguments are a product name and a brand name")
        case (let b?, false): String(localized: "\(product) at \(b)", comment: "Notification body; the arguments are a product name and a brand name")
        case (nil, true): String(localized: "\(product) is back in stock", comment: "Notification body; the argument is a product name")
        case (nil, false): product
        }
    }
}

struct InterestsScreen: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var interests: [Interest] = InterestsStore.load()
    @State private var draft = ""
    @State private var matches: [UUID: [Product]] = [:]
    @State private var ready = MeaningIndex.shared.isReady

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("e.g. gold jewelry for a summer wedding", text: $draft)
                        .submitLabel(.done).onSubmit(add)
                        .accessibilityIdentifier("interestField")
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).count < 3)
                        .accessibilityIdentifier("interestAdd")
                }
            } footer: {
                Text("Describe what you're into, in your own words. When new arrivals or restocks match, we'll send a notification. Your interests stay on this iPhone.")
            }
            ForEach(interests) { interest in
                Section(interest.text) {
                    if let ps = matches[interest.id], !ps.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(ps) { ProductTile(product: $0, imageSide: 110).frame(width: 110) }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } else {
                        Text(ready ? "No matches right now — we'll keep looking." : "Getting matches ready…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions { Button(role: .destructive) { remove(interest) } label: { Label("Remove", systemImage: "trash") } }
                .accessibilityIdentifier("interest")
            }
        }
        .task(id: interests.map(\.id)) { await refreshMatches() }
        .navigationTitle("Interests")
        .marracatChrome()
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, interests.count < 20 else { return }
        interests.insert(Interest(id: UUID(), text: String(text.prefix(120)), vector: nil, space: nil, created: .now), at: 0)
        InterestsStore.save(interests)
        Analytics.shared.track("alert_on", ["kind": .string("interest")])
        draft = ""
        // Asked here, when someone sets up an alert, never earlier.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    private func remove(_ interest: Interest) {
        interests.removeAll { $0.id == interest.id }
        InterestsStore.save(interests)
        Analytics.shared.track("alert_off", ["kind": .string("interest")])
    }

    private func refreshMatches() async {
        interests = await InterestsStore.embedMissing()
        ready = MeaningIndex.shared.isReady
        for i in interests {
            guard let v = i.vector else { continue }
            matches[i.id] = await MeaningPicks.products(near: v, catalog: catalog, limit: 10)
        }
    }
}
