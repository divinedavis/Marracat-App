import SwiftUI

/// The top of Home while a holiday's event runs (owner, 2026-10-27: "a row
/// or two in the app that has products that match the event"): a banner in
/// the day's colours, then each of its `rows` collections. Nothing shows on
/// other days. The rows come from the catalog this phone has (the bundled
/// slice first, the whole catalog once it lands), filtered off the main
/// thread.
struct HolidayEventRows: View {
    @Environment(CatalogStore.self) private var catalog
    @State private var built: [Built] = []
    @State private var builtFor = ""

    struct Built: Identifiable {
        let holiday: Holiday
        let rows: [(collection: HolidayCollection, products: [Product])]
        var id: String { holiday.id }
    }

    /// A row needs this many products to show; fewer looks broken.
    static let minimum = 4

    var body: some View {
        let events = HolidayCalendar.events()
        let key = events.map(\.id).joined(separator: ",") + "|\(catalog.catalog.generatedAt)|\(catalog.catalog.products.count)"
        VStack(spacing: 0) {
            ForEach(built) { b in
                if let first = b.rows.first {
                    EventBanner(holiday: b.holiday, route: .collection(first.collection.id))
                }
                ForEach(b.rows, id: \.collection.id) { row in
                    ProductRow(title: row.collection.title, products: row.products,
                               route: .collection(row.collection.id), track: "event", accent: b.holiday.banner?.first.map(Color.init(hex:)))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("eventRow")
                }
            }
        }
        .task(id: key) {
            guard key != builtFor else { return }
            guard !events.isEmpty else { built = []; builtFor = key; return }
            let products = catalog.catalog.products
            let made = await Task.detached(priority: .userInitiated) {
                events.map { h in
                    Built(holiday: h, rows: (h.rows ?? []).compactMap { id in
                        guard let c = HolidayCalendar.collection(id) else { return nil }
                        let picks = c.picks(from: products, limit: 12)
                        return picks.count >= Self.minimum ? (c, picks) : nil
                    })
                }.filter { !$0.rows.isEmpty }
            }.value
            built = made
            builtFor = key
        }
    }
}

/// "SPECIAL EVENT · OCT 21 – 31", the event's name and line, on the day's
/// colours. Opens the first row's full list.
struct EventBanner: View {
    let holiday: Holiday
    let route: Route

    private var days: String {
        let cal = Calendar.holidays
        let year = cal.component(.year, from: .now)
        guard let range = [year - 1, year, year + 1].lazy.compactMap({ holiday.eventDays(in: $0) })
            .first(where: { $0.upperBound >= cal.startOfDay(for: .now) }) else { return "" }
        let f = DateIntervalFormatter()
        f.dateTemplate = "MMMd"
        return f.string(from: range.lowerBound, to: range.upperBound)
    }

    var body: some View {
        let colors = (holiday.banner ?? holiday.tab).map(Color.init(hex:))
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(holiday.event?.badge ?? String(localized: "Special Event", comment: "Holiday banner kicker")) · \(days)".uppercased())
                    .brandFont(.caption2.weight(.bold)).tracking(1.2).opacity(0.9)
                Text(holiday.event?.name ?? holiday.name).brandFont(.title2.bold())
                if let short = holiday.event?.short { Text(short).brandFont(.subheadline) }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            // Darkened a quarter so white type keeps 4.5:1 on the light
            // colours (Halloween orange, Black Friday gold).
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.25)))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("eventBanner")
    }
}
