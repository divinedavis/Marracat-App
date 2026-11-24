import SwiftUI

/// The top of Home while a holiday's event runs (owner, 2026-10-27: "a row
/// or two in the app that has products that match the event"): a banner in
/// the day's colours, then each of its `rows` collections. Nothing shows on
/// other days. The rows come from the catalog this phone has (the bundled
/// slice first, the whole catalog once it lands), filtered off the main
/// thread.
///
/// The rows follow the shopper like the rest of Home's picks (owner,
/// 2026-11-23, asked whether Black Friday's rows should: "only departments
/// they touched"): someone with a history sees an event's products from
/// their departments only, and a row with too few of those isn't shown.
/// The banner stays either way and opens the event's whole list. A shopper
/// with no history sees the whole event.
struct HolidayEventRows: View {
    /// The departments this shopper has shown interest in (empty: all).
    var touched: Set<String> = []
    @Environment(CatalogStore.self) private var catalog
    @State private var built: [Built] = []
    @State private var builtFor = ""

    struct Built: Identifiable {
        let holiday: Holiday
        let rows: [(collection: HolidayCollection, products: [Product])]
        /// What the banner opens: the first row shown, else the event's
        /// first collection with anything in it.
        let opens: HolidayCollection
        var id: String { holiday.id }
    }

    /// A row needs this many products to show; fewer looks broken.
    static let minimum = 4

    /// Each event's banner and rows for a shopper. Pure, so Home can run it
    /// off the main thread.
    static func build(_ events: [Holiday], products: [Product], touched: Set<String>) -> [Built] {
        let theirs = touched.isEmpty ? products : products.filter { touched.contains($0.category) }
        return events.compactMap { h in
            let collections = (h.rows ?? []).compactMap { HolidayCalendar.collection($0) }
            let rows = collections.compactMap { c -> (collection: HolidayCollection, products: [Product])? in
                let picks = c.picks(from: theirs, limit: 12)
                return picks.count >= minimum ? (c, picks) : nil
            }
            guard let opens = rows.first?.collection
                    ?? collections.first(where: { $0.picks(from: products, limit: 12).count >= minimum }) else { return nil }
            return Built(holiday: h, rows: rows, opens: opens)
        }
    }

    var body: some View {
        let events = HolidayCalendar.events()
        let key = events.map(\.id).joined(separator: ",") + "|\(catalog.catalog.generatedAt)|\(catalog.catalog.products.count)|"
            + touched.sorted().joined(separator: ",")
        VStack(spacing: 0) {
            ForEach(built) { b in
                EventBanner(holiday: b.holiday, route: .collection(b.opens.id))
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
            let touched = touched
            built = await Task.detached(priority: .userInitiated) { Self.build(events, products: products, touched: touched) }.value
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
